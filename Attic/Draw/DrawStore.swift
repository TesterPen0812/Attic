import Foundation
import Observation

/// Shared command/history engine; the two backends expose exactly the same API.
@MainActor @Observable
class DrawStore: DrawStoreProtocol {
    static let maxHistorySteps = 100
    /// An evicted offer may protect at most this shared footprint per chain.
    static let maxProtectedHistoryBytes = 128 * 1024 * 1024
    static let maxCachedStates = 8
    /// What canvases whose bodies were evicted may still hold in Undo/Redo
    /// steps (image bytes, stroke points, thumbnails), together.
    static let maxEvictedHistoryBytes = 32 * 1024 * 1024
    private(set) var revision: UInt64 = 0
    private(set) var pendingGeneration: UInt64 = 0
    private(set) var lastDelta: DrawDelta?
    private(set) var pendingEdits: [UUID: DrawPendingEdit] = [:]
    private(set) var recoveryIssue: String?
    var hasUnsettledEdits: Bool { !pendingEdits.isEmpty || recoveryIssue != nil }

    @ObservationIgnored private let repository: any DrawRepository
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let recovery: DrawRecoveryJournal?
    @ObservationIgnored private var recoveredCanvasIDs = Set<UUID>()
    @ObservationIgnored private var states: [UUID: State] = [:]
    @ObservationIgnored private var histories: [UUID: History] = [:]
    /// The current in-memory head left by our own recovered inverse. A newer
    /// owner edit replaces that head and must still block earlier agent Undo.
    @ObservationIgnored private var agentReplayHeads: [UUID: UUID] = [:]
    @ObservationIgnored private var activeCanvasID: UUID?
    @ObservationIgnored private var stateAccess: [UUID: UInt64] = [:]
    @ObservationIgnored private var accessSequence: UInt64 = 0
    @ObservationIgnored private var evictedAt: [UUID: UInt64] = [:]
    /// What the evicted canvases' retained Undo/Redo steps hold, kept between
    /// evictions (see `boundEvictedHistories`).
    @ObservationIgnored private var evictedLedger = HistoryLedger()
    @ObservationIgnored private var ledgered: [UUID: LedgeredHistory] = [:]
    @ObservationIgnored private var ledgerGeneration = 0
    /// The generation at which a pass could free no more (everything left is
    /// a head or pinned): nothing to do again until the ledger changes.
    @ObservationIgnored private var saturatedLedgerGeneration = -1
    @ObservationIgnored private var saturatedPinRevision: UInt64 = 0
    /// The steps live offers are bound to; a history holding one is never
    /// dropped for the budget.
    @ObservationIgnored private let pins = DrawStepPins()
    var cachedCanvasIDs: Set<UUID> { Set(states.keys) }
    /// Per canvas, the edits not yet saved, oldest first. Only the first
    /// has been tried; the rest wait behind it and are already on show.
    @ObservationIgnored private var pending: [UUID: [Pending]] = [:]
    @ObservationIgnored private var pendingAvailability: [UUID: (count: Int, last: UUID?, undo: Bool, redo: Bool)] = [:]
    /// A failed checkpoint can leave no journal record at all. Remember
    /// that this head has never entered the repository, independently of disk.
    @ObservationIgnored private var unsubmittedHeads = Set<UUID>()
    @ObservationIgnored private var checkpointDirty = Set<UUID>()
    /// If a burst failed, Retry must publish the original per-key Undo chain.
    /// Crash recovery is session-scoped and reopens the merged durable draft.
    @ObservationIgnored private var typingStepsPending: [UUID: [UUID: [Step]]] = [:]

    private struct State {
        var canvas: DrawCanvas
        var objects: [UUID: DrawObject] = [:]
        var persisted = false
        var snapshot: DrawSnapshot {
            DrawSnapshot(canvas: canvas, objects: objects.values.filter { $0.deletedAt == nil }.sorted(by: DrawStore.objectOrder))
        }
    }
    struct Step: Codable, Equatable {
        var id = UUID()
        var change: DrawChange
        var before: DrawCanvas
        var after: DrawCanvas
        var beforePersisted: Bool
        var afterPersisted: Bool
        var reversed: Self {
            Self(id: id, change: change.reversed, before: after, after: before,
                 beforePersisted: afterPersisted, afterPersisted: beforePersisted)
        }
    }
    private struct History {
        var undo: [Step] = []
        var redo: [Step] = []
    }
    enum Action: String, Codable { case edit, undo, redo }
    struct Pending: Codable, Equatable {
        var id: UUID
        var step: Step
        var action: Action
        init(id: UUID = UUID(), step: Step, action: Action) { self.id = id; self.step = step; self.action = action }
        private enum CodingKeys: String, CodingKey { case id, step, action }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                      step: try values.decode(Step.self, forKey: .step), action: try values.decode(Action.self, forKey: .action))
        }
    }
    /// How the first unsaved edit is settled: written again (Retry),
    /// reconciled with what the store holds, or whichever its outcome asks.
    private enum Head { case write, reconcile, auto }

    init(repository: any DrawRepository, now: @escaping () -> Date = Date.init,
         recovery: DrawRecoveryJournal? = nil) {
        self.repository = repository
        self.now = now
        self.recovery = recovery
        recoveryIssue = recovery?.issue
        recoverDrafts()
        pins.didRelease = { [weak self] in
            Task { @MainActor [weak self] in self?.reconsiderReleasedOffers() }
        }
    }

    /// Reconstruct the visible sparse edits before allowing another write.
    /// The repository reconciles the first attempt against fresh *physical*
    /// rows, including binary payload copies, before any retry is offered.
    private func recoverDrafts() {
        guard let recovery, recoveryIssue == nil else { return }
        for (id, record) in recovery.records {
            guard let first = record.edits.first else { continue }
            let saved = try? repository.load(id)
            let objects = saved.map { Dictionary(uniqueKeysWithValues: $0.objects.map { ($0.id, $0) }) }
                ?? first.step.change.objectsBefore
            states[id] = State(canvas: saved?.canvas ?? first.step.before,
                               objects: objects, persisted: saved != nil || first.step.beforePersisted)
            for edit in record.edits { show(edit.step) }
            pending[id] = record.edits
            if record.unattempted { unsubmittedHeads.insert(id) }
            recoveredCanvasIDs.insert(id)
            let result: DrawWriteOutcome = record.unattempted
                ? .retry("The recovered next edit has not been saved. Retry when ready.")
                : repository.reconcile(first.step.change)
            switch result {
            case .committed:
                pending[id]?.removeFirst()
                if pending[id]?.isEmpty == true {
                    pending[id] = nil
                    recoveredCanvasIDs.remove(id)
                } else {
                    unsubmittedHeads.insert(id)
                    let next = pending[id]!
                    pendingEdits[id] = DrawPendingEdit(
                        canvas: next.last!.step.after, objects: states[id]?.snapshot.objects ?? [],
                        outcome: .retry("The recovered next edit has not been saved. Retry when ready."), count: next.count
                    )
                }
                try? recovery.update(id, edits: pending[id], proof: nil, unattempted: pending[id] != nil)
            case let .retry(message):
                pendingEdits[id] = DrawPendingEdit(
                    canvas: record.edits.last!.step.after, objects: states[id]?.snapshot.objects ?? [],
                    outcome: .retry(message), count: record.edits.count
                )
            case let .held(message):
                pendingEdits[id] = DrawPendingEdit(
                    canvas: record.edits.last!.step.after, objects: states[id]?.snapshot.objects ?? [],
                    outcome: .held(message), count: record.edits.count
                )
            }
        }
    }

    func library(deleted: Bool = false) throws -> [DrawCanvas] {
        // Observe successful changes while keeping the query body-free.
        _ = revision
        var byID = Dictionary(uniqueKeysWithValues: try repository.library().map { ($0.id, $0) })
        // A first-save failure also needs a discoverable canvas after relaunch.
        for id in recoveredCanvasIDs {
            if let draft = states[id]?.canvas { byID[id] = draft }
        }
        return byID.values.filter { ($0.deletedAt != nil) == deleted }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func search(_ query: String) throws -> [DrawSearchMatch] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let rawTags = tokens.filter { $0.hasPrefix("#") }
        let tags = rawTags.compactMap(AtticTag.normalize)
        guard tags.count == rawTags.count else { return [] }
        let words = tokens.filter { !$0.hasPrefix("#") }
        return try library().compactMap { canvas in
            guard tags.allSatisfy({ tag in canvas.tags.contains { $0.lowercased() == tag } }),
                  words.allSatisfy({ canvas.name.localizedStandardContains($0) || canvas.textIndex.localizedStandardContains($0) }) else { return nil }
            let textWords = words.filter { canvas.textIndex.localizedStandardContains($0) }
            let ids = textWords.isEmpty ? [] : try repository.textMatches(textWords, in: canvas.id)
            return DrawSearchMatch(canvas: canvas, matchingTextBoxIDs: ids)
        }
    }

    func create(name: String? = nil) -> DrawCanvas {
        let date = now()
        let explicit = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved: String
        if explicit.isEmpty {
            let base = String(localized: "Untitled")
            let saved = (try? repository.library()) ?? []
            let names = Set((saved + states.values.map(\.canvas)).filter { $0.deletedAt == nil }.map(\.name))
            var next = base, suffix = 2
            while names.contains(next) { next = "\(base) \(suffix)"; suffix += 1 }
            resolved = next
        } else { resolved = explicit }
        let canvas = DrawCanvas(name: resolved, createdAt: date, updatedAt: date)
        states[canvas.id] = State(canvas: canvas)
        touch(canvas.id)
        trimCachedStates(protecting: canvas.id)
        return canvas
    }

    func activate(_ id: UUID) {
        activeCanvasID = id
        touch(id)
        trimCachedStates(protecting: id)
    }

    private func touch(_ id: UUID) {
        accessSequence &+= 1
        stateAccess[id] = accessSequence
    }

    /// Only durably persisted, inactive canvases may be reloaded later.
    /// Pending edits and drafts stay in memory until they are safely settled.
    private func trimCachedStates(protecting id: UUID? = nil) {
        guard states.count > Self.maxCachedStates else { return }
        let candidates = states.keys.filter { key in
            key != id && key != activeCanvasID && pending[key] == nil && states[key]?.persisted == true
        }.sorted { (stateAccess[$0] ?? 0) < (stateAccess[$1] ?? 0) }
        for key in candidates.prefix(states.count - Self.maxCachedStates) {
            states[key] = nil
            // Body snapshots are reconstructible; offered Undo/Redo steps are
            // not. A grouped restore may still refer to this canvas's head,
            // so the steps stay, within a byte budget.
            stateAccess[key] = nil
            accessSequence &+= 1
            evictedAt[key] = accessSequence
        }
        boundEvictedHistories()
    }

    /// Only eviction measures payloads. Legal candidates are whole oldest
    /// prefixes (stopping at a pin), or an entire unoffered history. Select
    /// enough real relief before touching small shared-buffer prefixes.
    private func boundEvictedHistories() {
        syncHistoryLedger()
        for id in ledgered.keys {
            if let history = histories[id], let entry = ledgered[id] {
                expireOversizedOffers(history: history, prints: entry.prints)
            }
        }
        let pinRevision = pins.revision
        guard saturatedLedgerGeneration != ledgerGeneration || saturatedPinRevision != pinRevision else { return }
        var protected = HistoryLedger()
        for (id, entry) in ledgered {
            guard let history = histories[id] else { continue }
            for stack in [history.undo, history.redo] {
                if let first = stack.firstIndex(where: { pins.isPinned($0.id) }) {
                    for step in stack[first...] { if let print = entry.prints[step.id] { protected.add(print) } }
                }
            }
        }
        // Protected memory adds its footprint to the reclaimable allowance
        // continuously, from its first byte. It never consumes unrelated Undo.
        let budget = Self.maxEvictedHistoryBytes + protected.total
        struct Candidate {
            var canvas: UUID
            var undo: Int
            var redo: Int
            var freed: Int
            var steps: Int { undo + redo }
        }
        while evictedLedger.total > budget {
            let deficit = evictedLedger.total - budget
            var candidates: [Candidate] = []
            for (id, entry) in ledgered {
                guard let history = histories[id] else { continue }
                for (isUndo, stack) in [(true, history.undo), (false, history.redo)] {
                    let prefix = stack.prefix { !pins.isPinned($0.id) }
                    let prints = prefix.compactMap { entry.prints[$0.id] }
                    for (offset, freed) in evictedLedger.freedByPrefixes(prints).enumerated() {
                        candidates.append(Candidate(canvas: id, undo: isUndo ? offset + 1 : 0,
                            redo: isUndo ? 0 : offset + 1, freed: freed))
                    }
                }
                if !(history.undo + history.redo).contains(where: { pins.isPinned($0.id) }) {
                    candidates.append(Candidate(canvas: id, undo: history.undo.count, redo: history.redo.count,
                        freed: evictedLedger.freed(by: Array(entry.prints.values))))
                }
            }
            let sufficient = candidates.filter { $0.freed >= deficit }
            let selected: Candidate?
            if !sufficient.isEmpty {
                // A decisive head beats cutting many shared-buffer steps.
                selected = sufficient.min {
                    if $0.steps != $1.steps { return $0.steps < $1.steps }
                    if $0.freed != $1.freed { return $0.freed < $1.freed }
                    return (evictedAt[$0.canvas] ?? 0) < (evictedAt[$1.canvas] ?? 0)
                }
            } else {
                selected = candidates.filter { $0.freed > 0 }.max {
                    if $0.freed != $1.freed { return $0.freed < $1.freed }
                    if $0.steps != $1.steps { return $0.steps > $1.steps }
                    return (evictedAt[$0.canvas] ?? 0) > (evictedAt[$1.canvas] ?? 0)
                }
            }
            guard let selected, var history = histories[selected.canvas], let entry = ledgered[selected.canvas] else { break }
            let removed = Array(history.undo.prefix(selected.undo)) + Array(history.redo.prefix(selected.redo))
            for step in removed { if let print = entry.prints[step.id] { evictedLedger.remove(print) } }
            history.undo.removeFirst(selected.undo); history.redo.removeFirst(selected.redo)
            if history.undo.isEmpty && history.redo.isEmpty {
                histories[selected.canvas] = nil
                ledgered[selected.canvas] = nil
                ledgerGeneration &+= 1
            } else {
                histories[selected.canvas] = history
                setLedgered(selected.canvas, history, measuring: entry)
            }
        }
        saturatedLedgerGeneration = ledgerGeneration
        saturatedPinRevision = pinRevision
    }

    private func reconsiderReleasedOffers() {
        pins.acknowledgeReleaseChange()
        for id in histories.keys { capUndo(on: id) }
        boundEvictedHistories()
    }

    private func removeLedgered(_ id: UUID) {
        guard let entry = ledgered.removeValue(forKey: id) else { return }
        for print in entry.prints.values { evictedLedger.remove(print) }
        ledgerGeneration &+= 1
    }

    private struct LedgeredHistory {
        /// Kept so the counted buffers stay alive, and their addresses stay theirs.
        var steps: [Step]
        var prints: [UUID: StepFootprint]
        var fingerprint: HistoryFingerprint
    }
    private struct HistoryFingerprint: Equatable {
        var undoCount: Int, redoCount: Int
        var undoFirst: UUID?, undoLast: UUID?, redoFirst: UUID?, redoLast: UUID?
        init(_ history: History) {
            undoCount = history.undo.count; redoCount = history.redo.count
            undoFirst = history.undo.first?.id; undoLast = history.undo.last?.id
            redoFirst = history.redo.first?.id; redoLast = history.redo.last?.id
        }
    }

    /// Records `history` as what the ledger holds for `key`. A step already
    /// measured (`measuring`) is not measured again.
    private func setLedgered(_ key: UUID, _ history: History, measuring earlier: LedgeredHistory? = nil) {
        var prints: [UUID: StepFootprint] = [:]
        for step in history.undo + history.redo {
            prints[step.id] = earlier?.prints[step.id] ?? HistoryLedger.measure(step)
        }
        let entry = LedgeredHistory(steps: history.undo + history.redo, prints: prints, fingerprint: HistoryFingerprint(history))
        if earlier == nil { for print in prints.values { evictedLedger.add(print) } }
        ledgered[key] = entry
        ledgerGeneration &+= 1
    }

    /// Brings the ledger in line with the evicted canvases: a history that
    /// is loaded again, changed or gone leaves it; a newly evicted one enters.
    private func syncHistoryLedger() {
        for (key, entry) in ledgered {
            if let history = histories[key], states[key] == nil, HistoryFingerprint(history) == entry.fingerprint { continue }
            for print in entry.prints.values { evictedLedger.remove(print) }
            ledgered[key] = nil
            ledgerGeneration &+= 1
        }
        for (key, history) in histories where states[key] == nil && ledgered[key] == nil {
            guard !history.undo.isEmpty || !history.redo.isEmpty else { continue }
            setLedgered(key, history)
        }
    }

    #if DEBUG
    /// Measure the former whole-ledger rebuild against the incremental
    /// maintenance on the same real retained histories, without changing
    /// their budget or dropping fixture steps before the measurement.
    func historyLedgerWorkForTesting(rebuild: Bool) -> (histories: Int, steps: Int, bytes: Int) {
        if !rebuild {
            boundEvictedHistories()
            return (ledgered.count, ledgered.values.reduce(0) { $0 + $1.steps.count }, evictedLedger.total)
        }
        var ledger = HistoryLedger()
        var count = 0, steps = 0
        for (id, history) in histories where states[id] == nil {
            count += 1
            for step in history.undo + history.redo { ledger.add(HistoryLedger.measure(step)); steps += 1 }
        }
        return (count, steps, ledger.total)
    }
    #endif

    private struct LedgerBuffer: Hashable { let address: UInt; let count: Int }

    /// What one step holds: bytes that are its own, and the shared buffers it
    /// refers to (how often, and how big each is).
    private struct StepFootprint {
        var inline = 0
        var buffers: [(buffer: LedgerBuffer, size: Int, refs: Int)] = []
    }

    /// What Undo/Redo steps hold in memory. A copy-on-write buffer (an
    /// image's bytes, a stroke's points, a canvas's text index, a thumbnail
    /// stamped onto several copies of a canvas) is counted once however many
    /// steps refer to it.
    private struct HistoryLedger {
        private var sizes: [LedgerBuffer: Int] = [:]
        private var references: [LedgerBuffer: Int] = [:]
        private(set) var total = 0

        mutating func add(_ print: StepFootprint) {
            total += print.inline
            for use in print.buffers {
                let held = references[use.buffer, default: 0]
                references[use.buffer] = held + use.refs
                if held == 0 { sizes[use.buffer] = use.size; total += use.size }
            }
        }

        mutating func remove(_ print: StepFootprint) {
            total -= print.inline
            for use in print.buffers {
                guard let held = references[use.buffer] else { continue }
                if held <= use.refs { references[use.buffer] = nil; total -= sizes.removeValue(forKey: use.buffer) ?? use.size }
                else { references[use.buffer] = held - use.refs }
            }
        }

        /// The bytes that go if all of `prints` (already in the ledger) are
        /// removed: their own bytes, and each buffer only they refer to.
        func freed(by prints: [StepFootprint]) -> Int {
            var freed = 0
            var local: [LedgerBuffer: Int] = [:]
            for print in prints {
                freed += print.inline
                for use in print.buffers { local[use.buffer, default: 0] += use.refs }
            }
            for (buffer, refs) in local where references[buffer] == refs { freed += sizes[buffer] ?? 0 }
            return freed
        }

        /// All legal prefix scores in one pass over the cached footprints,
        /// rather than rescanning an increasingly long prefix at each step.
        func freedByPrefixes(_ prints: [StepFootprint]) -> [Int] {
            var result: [Int] = [], local: [LedgerBuffer: Int] = [:], freed = 0
            for print in prints {
                freed += print.inline
                for use in print.buffers {
                    local[use.buffer, default: 0] += use.refs
                    if local[use.buffer] == references[use.buffer] { freed += sizes[use.buffer] ?? 0 }
                }
                result.append(freed)
            }
            return result
        }

        static func measure(_ step: Step) -> StepFootprint {
            #if DEBUG
            HistoryLedgerProbe.stepVisits += 1
            #endif
            var print = StepFootprint()
            var shared: [LedgerBuffer: (size: Int, refs: Int)] = [:]
            func record(_ buffer: LedgerBuffer?, _ bytes: Int) {
                guard let buffer else { print.inline += bytes; return }
                shared[buffer, default: (bytes, 0)].refs += 1
            }
            visit(step.before, record)
            visit(step.after, record)
            if let before = step.change.before { visit(before, record) }
            if let after = step.change.after { visit(after, record) }
            for object in step.change.objectsBefore.values { visit(object, record) }
            for object in step.change.objectsAfter.values { visit(object, record) }
            print.buffers = shared.map { (buffer: $0.key, size: $0.value.size, refs: $0.value.refs) }
            return print
        }

        private static func visit(_ canvas: DrawCanvas, _ body: (LedgerBuffer?, Int) -> Void) {
            body(nil, 256)
            visit(text: canvas.textIndex, body)
            if let data = canvas.thumbnail { body(buffer(data), data.count) }
        }

        private static func visit(_ object: DrawObject, _ body: (LedgerBuffer?, Int) -> Void) {
            #if DEBUG
            HistoryLedgerProbe.objectVisits += 1
            #endif
            body(nil, 256)
            switch object.content {
            case .stroke(let points):
                body(buffer(points), points.count * MemoryLayout<DrawPoint>.stride)
            case .text(let text): visit(text: text, body)
            case .image(let image): body(buffer(image.original), image.original.count)
            case .shape: break
            }
        }

        private static func visit(text: String, _ body: (LedgerBuffer?, Int) -> Void) {
            body(buffer(text), text.utf8.count)
        }

        private static func buffer(_ points: [DrawPoint]) -> LedgerBuffer? {
            guard points.count > 16 else { return nil }
            return points.withUnsafeBufferPointer { raw in
                raw.baseAddress.map { LedgerBuffer(address: UInt(bitPattern: $0), count: points.count) }
            }
        }

        /// Small payloads are copied inline, with no identity: count each.
        private static func buffer(_ data: Data) -> LedgerBuffer? {
            guard data.count > 64 else { return nil }
            return data.withUnsafeBytes { raw in
                raw.baseAddress.map { LedgerBuffer(address: UInt(bitPattern: $0), count: data.count) }
            }
        }

        /// A native string's storage is shared by its copies (a canvas's text
        /// index in the before, after and change of one step). A small string
        /// is inline, and a bridged one has no contiguous storage: each counts.
        private static func buffer(_ text: String) -> LedgerBuffer? {
            guard text.utf8.count > 15 else { return nil }
            return text.utf8.withContiguousStorageIfAvailable { raw in
                raw.baseAddress.map { LedgerBuffer(address: UInt(bitPattern: $0), count: raw.count) }
            } ?? nil
        }
    }

    func open(_ id: UUID) throws -> DrawSnapshot {
        _ = revision; _ = pendingEdits
        return try state(id).snapshot
    }
    func deletedImages(in id: UUID) throws -> [DrawObject] {
        _ = revision; _ = pendingEdits
        return try state(id).objects.values.filter { $0.isImage && $0.deletedAt != nil }.sorted(by: Self.objectOrder)
    }

    func deletedImages() throws -> [DrawDeletedImage] {
        _ = revision
        return try repository.deletedImageHeaders().sorted {
            ($0.object.deletedAt ?? .distantPast, $0.object.id.uuidString) > ($1.object.deletedAt ?? .distantPast, $1.object.id.uuidString)
        }
    }

    func purge(_ targets: [DrawPurgeTarget]) -> DrawPurgeReport {
        // A damaged recovery sidecar may conceal pending edits for any canvas.
        // Until it can be inspected, no Draw item is safe to remove for good.
        if recoveryIssue != nil { return DrawPurgeReport(removed: 0, kept: Set(targets).count) }
        var canvases: [UUID: Date] = [:], images: [UUID: DrawImageTarget] = [:], kept = 0
        for target in Set(targets) {
            switch target {
            case let .canvas(id, deletedAt):
                // A canvas with an unsettled edit stays until it settles.
                if pending[id] != nil { kept += 1 } else { canvases[id] = deletedAt }
            case let .image(canvas, object, deletedAt):
                if pending[canvas] != nil { kept += 1 } else { images[object] = DrawImageTarget(canvas: canvas, deletedAt: deletedAt) }
            }
        }
        guard !canvases.isEmpty || !images.isEmpty else { return DrawPurgeReport(removed: 0, kept: kept) }
        let result = repository.purge(canvases: canvases, images: images)
        for id in result.removedCanvases {
            states[id] = nil
            histories[id] = nil
            removeLedgered(id)
            stateAccess[id] = nil
        }
        for objectID in result.removedImages {
            guard let canvasID = images[objectID]?.canvas else { continue }
            states[canvasID]?.objects[objectID] = nil
            // Its steps (placing, moving, deleting it) can't be undone any
            // more, and history is a chain: the canvas starts afresh.
            histories[canvasID] = nil
            removeLedgered(canvasID)
        }
        let removed = result.removedCanvases.count + result.removedImages.count
        if removed > 0 { revision &+= 1 }
        return DrawPurgeReport(removed: removed, kept: kept + result.kept)
    }

    func purge(deletedBefore cutoff: Date) -> DrawPurgeReport {
        var targets: [DrawPurgeTarget] = []
        for canvas in (try? library(deleted: true)) ?? [] {
            if let deletedAt = canvas.deletedAt, deletedAt < cutoff { targets.append(.canvas(canvas.id, deletedAt: deletedAt)) }
        }
        for image in (try? deletedImages()) ?? [] {
            if let deletedAt = image.object.deletedAt, deletedAt < cutoff {
                targets.append(.image(canvas: image.canvas.id, object: image.object.id, deletedAt: deletedAt))
            }
        }
        return targets.isEmpty ? DrawPurgeReport() : purge(targets)
    }

    func perform(_ command: DrawCommand, on id: UUID) -> DrawSaveResult {
        if let recoveryIssue { return .held(recoveryIssue) }
        if case .thumbnail(let bytes, let dark) = command { return writeThumbnail(bytes, dark: dark, on: id) }
        if case .rename = command, pending[id]?.contains(where: { $0.action != .edit }) == true {
            return historyMustResume()
        }
        do {
            guard let step = try prepare(command, on: id) else { return .unchanged }
            guard pending[id] != nil else { return execute(step, action: .edit) }
            // An earlier edit isn't saved yet: this one shows at once and
            // waits behind it (never lost), then everything is tried again.
            let queued = stamped(step)
            expireRedoOffers(on: id)
            show(queued)
            pending[id]?.append(Pending(step: queued, action: .edit))
            let published = publishPending(id, outcome: pendingEdits[id]?.outcome ?? .retry(""))
            guard !checkpointDirty.contains(id) else { return published }
            return flush(id, head: .auto)
        } catch { return .held("Could not prepare the edit: \(error)") }
    }

    /// R-19: one physical save for a short burst of text commands. Each
    /// intermediate text change remains its own Undo step after the commit.
    /// The merged repository change still checks the original physical
    /// before-values and updates every replica in a single transaction.
    func performTypingBurst(_ commands: [DrawCommand], on id: UUID) -> DrawSaveResult {
        guard !commands.isEmpty else { return .unchanged }
        guard recoveryIssue == nil else { return .held(recoveryIssue!) }
        if pending[id] != nil {
            var result: DrawSaveResult = .unchanged
            for command in commands { result = perform(command, on: id) }
            return result
        }
        do {
            let original = try state(id)
            var steps: [Step] = []
            do {
                for command in commands {
                    guard let step = try prepare(command, on: id) else { continue }
                    let fresh = stamped(step)
                    show(fresh)
                    steps.append(fresh)
                }
            } catch {
                states[id] = original
                throw error
            }
            guard let first = steps.first, let last = steps.last else { return .unchanged }
            var merged = last
            merged.before = first.before
            merged.beforePersisted = first.beforePersisted
            merged.change.before = first.change.before
            merged.change.objectsBefore = first.change.objectsBefore
            // Text edits always touch one box. Never merge across distinct
            // object IDs: a sparse physical inverse must stay complete.
            guard steps.allSatisfy({ $0.change.objectIDs == merged.change.objectIDs }) else {
                states[id] = original
                return .held("Could not safely merge the text edits.")
            }
            expireRedoOffers(on: id)
            typingStepsPending[id, default: [:]][merged.id] = steps
            if let recovery {
                unsubmittedHeads.insert(id)
                do {
                    try recovery.update(id, edits: [Pending(step: merged, action: .edit)], proof: nil, unattempted: true)
                } catch {
                    pending[id] = [Pending(step: merged, action: .edit)]
                    return publishPending(id, outcome: .held("The text is not saved yet. Its recovery checkpoint could not be written: \(error.localizedDescription)"))
                }
            }
            unsubmittedHeads.remove(id)
            let outcome = write(merged)
            switch outcome {
            case .committed:
                try? recovery?.update(id, edits: nil, proof: nil)
                for step in steps { _ = commit(step, action: .edit) }
                typingStepsPending[id]?[merged.id] = nil
                return .saved(DrawDelta(canvas: merged.after,
                    upserted: merged.change.objectsAfter.values.filter { $0.deletedAt == nil }.sorted(by: Self.objectOrder),
                    removedIDs: merged.change.objectIDs.filter { merged.change.objectsAfter[$0]?.deletedAt != nil || merged.change.objectsAfter[$0] == nil }.sorted { $0.uuidString < $1.uuidString },
                    revision: revision))
            case .retry(let message):
                pending[id] = [Pending(step: merged, action: .edit)]
                return publishPending(id, outcome: .retry(message))
            case .held(let message):
                pending[id] = [Pending(step: merged, action: .edit)]
                return publishPending(id, outcome: .held(message))
            }
        } catch { return .held("Could not prepare the text edits: \(error)") }
    }

    func performAgent(_ command: DrawCommand, on id: UUID) -> DrawSaveResult {
        if let recoveryIssue { return .held(recoveryIssue) }
        guard pending[id] == nil else { return .held("Draw has an unsettled edit; resolve it before an agent change") }
        do {
            guard let step = try prepare(command, on: id) else { return .unchanged }
            guard repository.matchesAgentUndoPrestate(step.change) else {
                return .held("Draw has divergent physical replicas; reconcile them before an agent change")
            }
            return perform(command, on: id)
        } catch { return .held("Could not prepare the agent edit: \(error)") }
    }

    /// Read a sparse patch without copying the whole object dictionary into
    /// history. This read scope ends before settle mutates the cached state.
    private func prepare(_ command: DrawCommand, on id: UUID) throws -> Step? {
        let before = try state(id)
        guard before.canvas.deletedAt == nil || Self.isRestore(command) else { throw DrawStoreError.missingCanvas }
        var after = before.canvas
        var objects: [UUID: DrawObject] = [:]
        switch command {
        case .saveCanvas: break
        case .put(let values):
            guard Set(values.map(\.id)).count == values.count else { throw DrawStoreError.invalidObject }
            for object in values { try Self.validate(object); objects[object.id] = object }
        case .remove(let ids):
            for objectID in ids {
                guard var object = before.objects[objectID], object.deletedAt == nil else { continue }
                object.deletedAt = now(); objects[objectID] = object
            }
        case .restoreObjects(let ids):
            for objectID in ids {
                guard var object = before.objects[objectID] else { continue }
                object.deletedAt = nil; objects[objectID] = object
            }
        case .rename(let name): after.name = Self.name(name)
        case .tags(let tags):
            after.tags = AtticTag.normalizedSet(tags)
        case .thumbnail(let bytes, let dark): after.thumbnail = bytes; after.thumbnailDark = bytes == nil ? nil : dark
        case .deleteCanvas: after.deletedAt = now()
        case .restoreCanvas: after.deletedAt = nil
        }
        objects = objects.filter { before.objects[$0.key] != $0.value }
        let savingDraft: Bool
        if case .saveCanvas = command { savingDraft = !before.persisted }
        else { savingDraft = false }
        guard savingDraft || !objects.isEmpty || before.canvas != after else { return nil }
        var originals: [UUID: DrawObject] = [:]
        for id in objects.keys { originals[id] = before.objects[id] }
        if objects.keys.contains(where: { !(originals[$0]?.text ?? "").isEmpty || !(objects[$0]?.text ?? "").isEmpty }) {
            let unchangedText = before.objects.values.filter { objects[$0.id] == nil && $0.deletedAt == nil && !$0.text.isEmpty }
            let changedText = objects.values.filter { $0.deletedAt == nil && !$0.text.isEmpty }
            after.textIndex = (unchangedText + changedText).sorted(by: Self.objectOrder).map(\.text).joined(separator: "\n")
        }
        after.updatedAt = now()
        let persisted = before.persisted || !objects.isEmpty || savingDraft
        let change = DrawChange(canvasID: id, before: before.persisted ? before.canvas : nil,
                                after: persisted ? after : nil, objectsBefore: originals, objectsAfter: objects)
        return Step(change: change, before: before.canvas, after: after,
                    beforePersisted: before.persisted, afterPersisted: persisted)
    }

    func retry(on id: UUID) -> DrawSaveResult {
        guard pending[id] != nil else { return .unchanged }
        guard case .retry = pendingEdits[id]?.outcome else {
            return .held("The stored state needs reconciliation before Retry.")
        }
        return flush(id, head: .write)
    }

    func reconcile(on id: UUID) -> DrawSaveResult {
        guard pending[id] != nil else { return .unchanged }
        return flush(id, head: .reconcile)
    }

    /// Escape may discard an uncommitted rename, including one queued behind
    /// another failed edit. First prove that an attempted head did not reach
    /// any physical replica; a held/ambiguous outcome must remain recoverable.
    func abandonPendingRename(on id: UUID, named name: String, restoring original: String) -> Bool {
        guard let edit = pending[id]?.last(where: {
            $0.action == .edit && $0.step.before.name == original && $0.step.after.name == name
        }) else { return false }
        return abandonPendingRename(on: id, stepID: edit.step.id)
    }

    func pendingRename(on id: UUID, stepID: UUID) -> (before: String, after: String)? {
        guard let edit = pending[id]?.first(where: { $0.action == .edit && $0.step.id == stepID }),
              edit.step.change.objectsBefore.isEmpty, edit.step.change.objectsAfter.isEmpty,
              edit.step.before.name != edit.step.after.name else { return nil }
        var renamed = edit.step.before
        renamed.name = edit.step.after.name
        renamed.updatedAt = edit.step.after.updatedAt
        guard renamed == edit.step.after else { return nil }
        return (edit.step.before.name, edit.step.after.name)
    }

    func abandonPendingRename(on id: UUID, stepID: UUID) -> Bool {
        guard recoveryIssue == nil, pendingRename(on: id, stepID: stepID) != nil,
              let edits = pending[id], let index = edits.firstIndex(where: {
                  $0.action == .edit && $0.step.id == stepID
              }) else { return false }
        let rename = edits[index].step
        let removesHead = index == 0
        if removesHead && !unsubmittedHeads.contains(id) {
            guard case .retry = repository.reconcile(rename.change) else { return false }
        }

        // A history ID identifies the reversible command. Escape owns that
        // title command and its exact Undo/Redo operations, wherever queued.
        // A pure title edit changes no object, tag, or persistence identity.
        // Later commands only carry its metadata: rebase their prestate and
        // inherited name, preserving each command's own values and order.
        var remaining = Array(edits.prefix(index))
        var canvas = rename.before
        var persisted = rename.beforePersisted
        var rebased: [UUID: Step] = [:]
        for var edit in edits.dropFirst(index) where edit.step.id != stepID {
            if let reference = rebased[edit.step.id], edit.action != .edit {
                edit.step = edit.action == .undo ? reference.reversed : reference
            } else {
                let changesName = edit.step.before.name != edit.step.after.name
                edit.step.before = canvas
                edit.step.beforePersisted = persisted
                edit.step.change.before = persisted ? canvas : nil
                if !changesName { edit.step.after.name = canvas.name }
                edit.step.change.after = edit.step.afterPersisted ? edit.step.after : nil
                if edit.action != .undo { rebased[edit.step.id] = edit.step }
            }
            canvas = edit.step.after
            persisted = edit.step.afterPersisted
            remaining.append(edit)
        }
        let unattempted = removesHead || unsubmittedHeads.contains(id)
        var checkpointFailure: String?
        do {
            try recovery?.update(id, edits: remaining.isEmpty ? nil : remaining,
                                 proof: removesHead ? nil : repository.recoveryProof(for: id),
                                 unattempted: unattempted, replacing: true)
        } catch {
            checkpointFailure = "The cancelled name is not saved yet. Retry to save the drawing without it: \(error.localizedDescription)"
        }
        states[id]?.canvas = canvas
        states[id]?.persisted = persisted
        // An empty queue is a checkpoint-only cancellation when the disk is
        // refusing writes. It keeps quit unsettled without inventing Undo.
        pending[id] = remaining.isEmpty && checkpointFailure == nil ? nil : remaining
        pendingAvailability[id] = nil
        if removesHead { repository.discardAttempt(for: id) }
        if unattempted && pending[id] != nil { unsubmittedHeads.insert(id) }
        else if pending[id] == nil { unsubmittedHeads.remove(id) }
        if let checkpointFailure {
            pendingEdits[id] = DrawPendingEdit(canvas: canvas, objects: states[id]?.snapshot.objects ?? [],
                outcome: .held(checkpointFailure), count: remaining.count, lastStepID: remaining.last?.step.id)
        } else if let last = remaining.last, let outcome = pendingEdits[id]?.outcome {
            pendingEdits[id] = DrawPendingEdit(canvas: last.step.after, objects: states[id]?.snapshot.objects ?? [],
                outcome: outcome, count: remaining.count, lastStepID: last.step.id)
        } else {
            pendingEdits[id] = nil
            recoveredCanvasIDs.remove(id)
        }
        pendingGeneration &+= 1
        return true
    }

    func canUndo(on id: UUID) -> Bool {
        _ = revision; _ = pendingEdits
        return pending[id] == nil && !(histories[id]?.undo.isEmpty ?? true)
    }
    func canRedo(on id: UUID) -> Bool {
        _ = revision; _ = pendingEdits
        return pending[id] == nil && !(histories[id]?.redo.isEmpty ?? true)
    }

    /// Keeps an offered step reachable until its offer ends or exceeds the
    /// 100-step / 128 MiB evicted-chain bounds, when the offer expires.
    func pinHistoryStep(_ stepID: UUID) -> AnyObject? {
        let pin = pins.pin(stepID)
        func contains(_ history: History) -> Bool {
            history.undo.contains { $0.id == stepID } || history.redo.contains { $0.id == stepID }
        }
        if let id = lastDelta?.canvas.id, let history = histories[id], contains(history) { capUndo(on: id) }
        else if let entry = histories.first(where: { contains($0.value) }) { capUndo(on: entry.key) }
        return pin
    }

    private func historyMustResume() -> DrawSaveResult {
        .held(String(localized: "Undo and Redo are waiting for this drawing to finish saving."))
    }

    func undoStepID(on id: UUID) -> UUID? { histories[id]?.undo.last?.id }
    func redoStepID(on id: UUID) -> UUID? { histories[id]?.redo.last?.id }

    private struct AgentUndoSeal: Codable {
        let step: Step
        let saved: DrawSnapshot
    }

    func agentUndoProof(on id: UUID, stepID: UUID) -> Data? {
        guard pending[id] == nil, recoveryIssue == nil,
              let step = histories[id]?.undo.last, step.id == stepID,
              let saved = try? open(id) else { return nil }
        return try? JSONEncoder().encode(AgentUndoSeal(step: step, saved: saved))
    }

    func undoAgentStep(on id: UUID, proof: Data) -> DrawSaveResult {
        guard let seal = try? JSONDecoder().decode(AgentUndoSeal.self, from: proof),
              seal.step.change.canvasID == id, pending[id] == nil, recoveryIssue == nil else {
            return .held("Draw has changed or refused Undo")
        }
        // If an owner made a newer edit in this same session, never consume
        // that history step even if the visible object list looks unchanged.
        if let currentHead = undoStepID(on: id), currentHead != seal.step.id,
           currentHead != agentReplayHeads[id] {
            return .held("Draw has changed or refused Undo")
        }
        // A new DrawStore has no in-memory history. Load from the persistent
        // repository, including all replicas, before accepting its old step.
        guard let persisted = try? repository.load(id),
              persisted.canvas == seal.saved.canvas,
              persisted.objects.filter({ $0.deletedAt == nil }).sorted(by: Self.objectOrder) == seal.saved.objects
        else { return .held("Draw has changed or refused Undo") }
        guard repository.matchesAgentUndoPrestate(seal.step.change.reversed) else {
            return .held("Draw has divergent physical replicas; reconcile them before Undo")
        }
        // A saved agent inverse is a new owner-undoable step. Keep the earlier
        // same-session chain only when its cached state still matches storage,
        // including deleted objects that the visible snapshot omits.
        let cacheMatchesStore = states[id].map { cached in
            cached.persisted && cached.canvas == persisted.canvas &&
                cached.objects.count == persisted.objects.count &&
                persisted.objects.allSatisfy { cached.objects[$0.id] == $0 }
        } ?? false
        if !cacheMatchesStore {
            do { try reload(id) }
            catch { return .held("Draw has changed or refused Undo") }
            guard (try? open(id)) == seal.saved else { return .held("Draw has changed or refused Undo") }
        }
        // The inverse is the original sparse physical transition reversed;
        // repository.write again guards its expected physical before values.
        var inverse = seal.step.reversed
        inverse.id = UUID() // A new history entry must have its own head identity.
        let result = execute(inverse, action: .edit)
        if result.isSaved { agentReplayHeads[id] = undoStepID(on: id) }
        return result
    }

    func undo(on id: UUID) -> DrawSaveResult {
        guard canUndo(on: id), let step = histories[id]?.undo.last else { return .unchanged }
        // Restore the current metadata before stamping a retained history
        // step. The body cache may have been evicted while Undo was offered.
        guard (try? state(id)) != nil else { return .held("Could not reload this canvas for Undo.") }
        return IdleLatencyTrace.span("draw_store_undo") { execute(step.reversed, action: .undo) }
    }
    func redo(on id: UUID) -> DrawSaveResult {
        guard canRedo(on: id), let step = histories[id]?.redo.last else { return .unchanged }
        guard (try? state(id)) != nil else { return .held("Could not reload this canvas for Redo.") }
        return execute(step, action: .redo)
    }

    /// Sparse history after all checkpointed steps, including a failed head.
    private func projectedHistory(on id: UUID) -> History {
        var history = histories[id] ?? History()
        for edit in pending[id] ?? [] {
            switch edit.action {
            case .edit:
                for step in typingStepsPending[id]?[edit.step.id] ?? [edit.step] {
                    history.undo.append(step)
                    let excess = max(0, history.undo.count - Self.maxHistorySteps)
                    let discard = history.undo.prefix(excess).prefix { !pins.isPinned($0.id) }.count
                    history.undo.removeFirst(discard)
                }
                history.redo = []
            case .undo:
                _ = history.undo.popLast()
                history.redo.append(edit.step.reversed)
            case .redo:
                _ = history.redo.popLast()
                history.undo.append(edit.step)
                let excess = max(0, history.undo.count - Self.maxHistorySteps)
                let discard = history.undo.prefix(excess).prefix { !pins.isPinned($0.id) }.count
                history.undo.removeFirst(discard)
            }
        }
        return history
    }

    func historyChanges(on id: UUID) -> (undo: [DrawChange], redo: [DrawChange])? {
        guard recoveryIssue == nil else { return nil }
        let history = projectedHistory(on: id)
        return (history.undo.map(\.change), history.redo.map(\.change))
    }

    /// Keystrokes with an unchanged pending tail only read cached booleans;
    /// they never copy/project the history stacks to refresh toolbar state.
    func acknowledgedHistoryAvailability(on id: UUID) -> (undo: Bool, redo: Bool) {
        guard let edits = pending[id] else {
            pendingAvailability[id] = nil
            return (!(histories[id]?.undo.isEmpty ?? true), !(histories[id]?.redo.isEmpty ?? true))
        }
        if let cached = pendingAvailability[id], cached.count == edits.count, cached.last == edits.last?.id {
            return (cached.undo, cached.redo)
        }
        let history = projectedHistory(on: id)
        let value = (edits.count, edits.last?.id, !history.undo.isEmpty, !history.redo.isEmpty)
        pendingAvailability[id] = value
        return (value.2, value.3)
    }

    /// Only the page's acknowledged history route may append behind a failed
    /// write. Resolve its inverse now against the pending projection, then
    /// checkpoint it through exactly the ordinary pending path.
    func acknowledgeHistory(redo: Bool, on id: UUID) -> DrawSaveResult {
        guard recoveryIssue == nil else { return .held(recoveryIssue!) }
        guard pending[id] != nil else { return redo ? self.redo(on: id) : undo(on: id) }
        let history = projectedHistory(on: id)
        guard let next = redo ? history.redo.last : history.undo.last else { return .unchanged }
        let step = stamped(redo ? next : next.reversed)
        show(step)
        pending[id]?.append(Pending(step: step, action: redo ? .redo : .undo))
        let published = publishPending(id, outcome: pendingEdits[id]?.outcome ?? .retry(""))
        guard !checkpointDirty.contains(id) else { return published }
        return flush(id, head: .auto)
    }

    func duplicate(_ id: UUID, name: String? = nil) throws -> DrawCanvas? {
        let source = try open(id)
        guard pending[id] == nil, source.canvas.deletedAt == nil else { throw DrawStoreError.pendingEdit }
        let copy = create(name: name ?? source.canvas.name + " copy")
        states[copy.id]?.canvas.tags = source.canvas.tags
        states[copy.id]?.canvas.thumbnail = source.canvas.thumbnail
        states[copy.id]?.canvas.thumbnailDark = source.canvas.thumbnailDark
        let objects = source.objects.map { $0.translated(by: DrawPoint()) }
        let result = perform(.put(objects), on: copy.id)
        // Empty duplicates, like New, stay drafts. Failed copies remain visible
        // through pendingEdits and can be retried with the same logical IDs.
        return result.isSaved || objects.isEmpty || pending[copy.id] != nil ? states[copy.id]?.canvas : nil
    }

    private struct Clipboard: Codable { var version = 1; var objects: [DrawObject] }
    static let clipboardType = "com.taha.attic.draw-objects.v1"
    func copy(_ ids: [UUID], from id: UUID) throws -> Data {
        let wanted = Set(ids)
        return try JSONEncoder().encode(Clipboard(objects: open(id).objects.filter { wanted.contains($0.id) }))
    }
    func cut(_ ids: [UUID], from id: UUID) -> DrawSaveResult { perform(.remove(ids), on: id) }
    func paste(_ data: Data, into id: UUID, offset: DrawPoint = DrawPoint(x: 12, y: 12)) -> DrawSaveResult {
        do {
            let clipboard = try JSONDecoder().decode(Clipboard.self, from: data)
            guard clipboard.version == 1, offset.x.isFinite, offset.y.isFinite else { throw DrawStoreError.invalidClipboard }
            let top = try state(id).objects.values.map(\.zIndex).max() ?? -1
            guard top < Int64.max - Int64(clipboard.objects.count) else { throw DrawStoreError.invalidClipboard }
            let objects = clipboard.objects.enumerated().map { index, object in
                var copy = object.translated(by: offset)
                copy.zIndex = top + Int64(index) + 1
                return copy
            }
            return perform(.put(objects), on: id)
        } catch { return .held("Cannot paste these Draw objects: \(error)") }
    }

    func reload(_ id: UUID) throws {
        guard pending[id] == nil else { throw DrawStoreError.pendingEdit }
        guard let snapshot = try repository.load(id) else { throw DrawStoreError.missingCanvas }
        states[id] = State(canvas: snapshot.canvas, objects: Dictionary(uniqueKeysWithValues: snapshot.objects.map { ($0.id, $0) }), persisted: true)
        histories[id] = nil
        removeLedgered(id)
        touch(id)
        trimCachedStates(protecting: id)
        revision &+= 1
    }

    private func state(_ id: UUID) throws -> State {
        if let state = states[id] { touch(id); return state }
        guard let snapshot = try repository.load(id) else { throw DrawStoreError.missingCanvas }
        let state = State(canvas: snapshot.canvas, objects: Dictionary(uniqueKeysWithValues: snapshot.objects.map { ($0.id, $0) }), persisted: true)
        states[id] = state
        removeLedgered(id)
        touch(id)
        trimCachedStates(protecting: id)
        return state
    }
    /// A thumbnail is not an edit: no Undo step, no new date (so no move in
    /// the menu), and a failure leaves nothing waiting for Retry (the next
    /// settle renders it again). A draft has none until its first content.
    /// It records the appearance it was rendered for; the same bytes for
    /// another appearance still write (the record changes).
    private func writeThumbnail(_ bytes: Data?, dark: Bool?, on id: UUID) -> DrawSaveResult {
        let dark = bytes == nil ? nil : dark
        guard pending[id] == nil, let current = try? state(id),
              current.canvas.thumbnail != bytes || current.canvas.thumbnailDark != dark else { return .unchanged }
        var after = current.canvas
        after.thumbnail = bytes
        after.thumbnailDark = dark
        guard current.canvas.deletedAt == nil else { return .unchanged }
        // A draft keeps its thumbnail in memory until its first save.
        guard current.persisted else {
            states[id]?.canvas = after
            revision &+= 1
            return .saved(DrawDelta(canvas: after, upserted: [], removedIDs: [], revision: revision))
        }
        let change = DrawChange(canvasID: id, before: current.canvas, after: after, objectsBefore: [:], objectsAfter: [:])
        var outcome = repository.write(change)
        if case .committed = outcome {} else {
            outcome = repository.reconcile(change)
            if case .committed = outcome {} else { repository.discardAttempt(for: id) }
        }
        switch outcome {
        case .committed:
            states[id]?.canvas = after
            revision &+= 1
            return .saved(DrawDelta(canvas: after, upserted: [], removedIDs: [], revision: revision))
        case .retry(let message): return .retry(message)
        case .held(let message): return .held(message)
        }
    }

    /// History holds canvas metadata from when each step was made; the
    /// thumbnail is whatever was rendered last, never an older one.
    private func stamped(_ step: Step) -> Step {
        var step = step
        let thumbnail = states[step.change.canvasID]?.canvas.thumbnail
        let dark = states[step.change.canvasID]?.canvas.thumbnailDark
        step.before.thumbnail = thumbnail; step.before.thumbnailDark = dark
        step.after.thumbnail = thumbnail; step.after.thumbnailDark = dark
        if step.change.before != nil { step.change.before?.thumbnail = thumbnail; step.change.before?.thumbnailDark = dark }
        if step.change.after != nil { step.change.after?.thumbnail = thumbnail; step.change.after?.thumbnailDark = dark }
        return step
    }
    private func write(_ step: Step) -> DrawWriteOutcome {
        step.change.before == nil && step.change.after == nil ? .committed : repository.write(step.change)
    }
    /// The visible after-draft, saved or not.
    private func show(_ step: Step) {
        pendingGeneration &+= 1
        let id = step.change.canvasID
        states[id]?.canvas = step.after
        states[id]?.persisted = step.afterPersisted
        for objectID in step.change.objectIDs { states[id]?.objects[objectID] = step.change.objectsAfter[objectID] }
    }

    private func execute(_ step: Step, action: Action) -> DrawSaveResult {
        if action == .edit { expireRedoOffers(on: step.change.canvasID) }
        let step = stamped(step)
        if let recovery, step.change.before != nil || step.change.after != nil {
            unsubmittedHeads.insert(step.change.canvasID)
            do {
                try IdleLatencyTrace.span("draw_store_recovery") {
                    try recovery.update(step.change.canvasID, edits: [Pending(step: step, action: action)],
                                        proof: nil, unattempted: true)
                }
            } catch {
                show(step)
                pending[step.change.canvasID] = [Pending(step: step, action: action)]
                return publishPending(step.change.canvasID, outcome: .held(
                    "The drawing is not saved yet. Its crash-recovery checkpoint could not be written: \(error.localizedDescription)"
                ))
            }
        }
        unsubmittedHeads.remove(step.change.canvasID)
        let outcome = IdleLatencyTrace.span("draw_store_write") { write(step) }
        show(step)
        switch outcome {
        case .committed:
            try? recovery?.update(step.change.canvasID, edits: nil, proof: nil)
            return .saved(commit(step, action: action))
        case .retry(let message):
            pending[step.change.canvasID] = [Pending(step: step, action: action)]
            return publishPending(step.change.canvasID, outcome: .retry(message))
        case .held(let message):
            pending[step.change.canvasID] = [Pending(step: step, action: action)]
            return publishPending(step.change.canvasID, outcome: .held(message))
        }
    }

    /// Saves the canvas's unsaved edits in the order they were made,
    /// stopping at the first that still can't be saved (it and everything
    /// behind it stay, on show, for Retry or the next edit).
    private func flush(_ id: UUID, head: Head) -> DrawSaveResult {
        if pending[id]?.isEmpty == true {
            do { try recovery?.update(id, edits: nil, proof: nil) }
            catch { return .held("The cancelled name is not saved yet. Retry to save the drawing without it: \(error.localizedDescription)") }
            pending[id] = nil; pendingEdits[id] = nil
            pendingAvailability[id] = nil; unsubmittedHeads.remove(id); checkpointDirty.remove(id)
            recoveredCanvasIDs.remove(id)
            return .unchanged
        }

        var saved: [DrawDelta] = []
        var first = true
        while var edit = pending[id]?.first {
            var outcome: DrawWriteOutcome
            let reconcileFirst: Bool
            switch head {
            case .reconcile: reconcileFirst = first
            case .write: reconcileFirst = false
            case .auto: if first, case .held = pendingEdits[id]?.outcome { reconcileFirst = true } else { reconcileFirst = false }
            }
            if reconcileFirst && !unsubmittedHeads.contains(id) {
                // A held save is read back, never overwritten.
                outcome = repository.reconcile(edit.step.change)
            } else {
                edit.step = stamped(edit.step)
                pending[id]?[0] = edit
                if let recovery, unsubmittedHeads.contains(id) || checkpointDirty.contains(id) {
                    do {
                        try recovery.update(id, edits: pending[id], proof: repository.recoveryProof(for: id),
                                            unattempted: unsubmittedHeads.contains(id))
                        checkpointDirty.remove(id)
                    } catch {
                        return publishPending(id, outcome: .held(
                            "The drawing is not saved yet. The recovery checkpoint could not be written before saving: \(error.localizedDescription)"
                        ))
                    }
                }
                unsubmittedHeads.remove(id)
                outcome = write(edit.step)
            }
            first = false
            switch outcome {
            case .committed:
                pending[id]?.removeFirst()
                if pending[id]?.isEmpty == false { unsubmittedHeads.insert(id) }
                if pending[id]?.isEmpty == true {
                    pending[id] = nil
                    pendingAvailability[id] = nil
                    pendingEdits[id] = nil
                    recoveredCanvasIDs.remove(id)
                }
                if let steps = typingStepsPending[id]?[edit.step.id] {
                    for step in steps { saved.append(commit(step, action: edit.action)) }
                    typingStepsPending[id]?[edit.step.id] = nil
                } else {
                    saved.append(commit(edit.step, action: edit.action))
                }
                // Retire the proven head and its proof together; later edits
                // remain checkpointed until their own saves settle.
                if let recovery {
                    do { try recovery.update(id, edits: pending[id], proof: nil, unattempted: pending[id] != nil) }
                    catch {
                        if pending[id] != nil {
                            return publishPending(id, outcome: .held("The remaining drawing changes are not saved yet. The recovery checkpoint could not be updated: \(error.localizedDescription)"))
                        }
                        // The last save is proven; a stale file remains safe
                        // to reconcile after relaunch if cleanup failed.
                    }
                }
            case .retry(let message):
                return publishPending(id, outcome: .retry(message))
            case .held(let message):
                return publishPending(id, outcome: .held(message))
            }
        }
        guard let last = saved.last else { return .unchanged }
        guard saved.count > 1 else { return .saved(last) }
        // Several saved at once: one delta covering them, the latest winning.
        var upserted: [UUID: DrawObject] = [:], removed = Set<UUID>()
        for delta in saved {
            for object in delta.upserted { upserted[object.id] = object; removed.remove(object.id) }
            for objectID in delta.removedIDs { upserted[objectID] = nil; removed.insert(objectID) }
        }
        return .saved(DrawDelta(canvas: last.canvas, upserted: upserted.values.sorted(by: Self.objectOrder),
                                removedIDs: removed.sorted { $0.uuidString < $1.uuidString }, revision: last.revision))
    }

    /// A confirmed save: history moves on once and one delta is published.
    private func commit(_ step: Step, action: Action) -> DrawDelta {
        let id = step.change.canvasID
        switch action {
        case .edit:
            expireRedoOffers(on: id)
            appendUndo(step, on: id); histories[id]?.redo = []
        case .undo:
            _ = histories[id]?.undo.popLast()
            // Recovery may only know a merged typing head. The concrete
            // inverse that was actually saved is authoritative for Redo.
            histories[id, default: History()].redo.append(step.reversed)
        case .redo:
            _ = histories[id]?.redo.popLast()
            appendUndo(step, on: id)
        }
        capUndo(on: id)
        revision &+= 1
        let delta = DrawDelta(canvas: step.after,
                              upserted: step.change.objectsAfter.values.filter { $0.deletedAt == nil }.sorted(by: Self.objectOrder),
                              removedIDs: step.change.objectIDs.filter { step.change.objectsAfter[$0]?.deletedAt != nil || step.change.objectsAfter[$0] == nil }.sorted { $0.uuidString < $1.uuidString },
                              revision: revision)
        lastDelta = delta
        trimCachedStates(protecting: id)
        return delta
    }

    private func expireRedoOffers(on id: UUID) {
        for step in histories[id]?.redo ?? [] { pins.expire(step.id) }
    }

    private func appendUndo(_ step: Step, on id: UUID) {
        histories[id, default: History()].undo.append(step)
    }

    /// Count bounds apply everywhere. Byte bounds use the existing evicted
    /// ledger only; a never-evicted edit never walks payload footprints.
    private func expireOversizedOffers(history: History, prints: [UUID: StepFootprint]? = nil) {
        guard pins.hasPins else { return }
        for stack in [history.undo, history.redo] {
            while let first = stack.firstIndex(where: { pins.isPinned($0.id) }) {
                let suffix = stack[first...]
                if suffix.count > Self.maxHistorySteps { pins.expire(stack[first].id); continue }
                guard let prints else { break }
                var footprint = HistoryLedger()
                for step in suffix { if let measured = prints[step.id] { footprint.add(measured) } }
                if footprint.total > Self.maxProtectedHistoryBytes { pins.expire(stack[first].id); continue }
                break
            }
        }
    }

    private func capUndo(on id: UUID) {
        if let history = histories[id] { expireOversizedOffers(history: history) }
        let removable: Int = {
            guard let stack = histories[id]?.undo, stack.count > Self.maxHistorySteps else { return 0 }
            let excess = stack.count - Self.maxHistorySteps
            return stack.prefix(excess).prefix { !pins.isPinned($0.id) }.count
        }()
        if removable > 0 { histories[id]?.undo.removeFirst(removable) }
    }

    @discardableResult
    private func publishPending(_ id: UUID, outcome: DrawSaveResult) -> DrawSaveResult {
        guard let edits = pending[id], let last = edits.last else { return outcome }
        var published = outcome
        if let recovery {
            do {
                try recovery.update(id, edits: edits, proof: repository.recoveryProof(for: id),
                                    unattempted: unsubmittedHeads.contains(id))
                checkpointDirty.remove(id)
            }
            catch {
                checkpointDirty.insert(id)
                published = .held("The drawing is not saved yet. Its crash-recovery checkpoint could not be written: \(error.localizedDescription)")
            }
        }
        pendingEdits[id] = DrawPendingEdit(canvas: last.step.after, objects: states[id]?.snapshot.objects ?? [],
                                           outcome: published, count: edits.count, lastStepID: last.step.id)
        return published
    }
    private static func name(_ value: String?) -> String {
        let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Untitled" : name
    }
    nonisolated private static func objectOrder(_ lhs: DrawObject, _ rhs: DrawObject) -> Bool {
        lhs.zIndex == rhs.zIndex ? lhs.id.uuidString < rhs.id.uuidString : lhs.zIndex < rhs.zIndex
    }
    private static func isRestore(_ command: DrawCommand) -> Bool { if case .restoreCanvas = command { true } else { false } }
    private static func validate(_ object: DrawObject) throws {
        guard [object.frame.x, object.frame.y, object.frame.width, object.frame.height].allSatisfy(\.isFinite) else { throw DrawStoreError.invalidObject }
        switch object.content {
        case .stroke(let points):
            guard !points.isEmpty, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw DrawStoreError.invalidObject }
        case .image(let image):
            guard !image.original.isEmpty, image.pixelWidth > 0, image.pixelHeight > 0 else { throw DrawStoreError.invalidObject }
        default: break
        }
    }
}

// History IDs were added after D-02 recovery checkpoints first shipped.
// Existing pending edits have no ID, and must remain recoverable.
extension DrawStore.Step {
    private enum CodingKeys: String, CodingKey {
        case id, change, before, after, beforePersisted, afterPersisted
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            change: try values.decode(DrawChange.self, forKey: .change),
            before: try values.decode(DrawCanvas.self, forKey: .before),
            after: try values.decode(DrawCanvas.self, forKey: .after),
            beforePersisted: try values.decode(Bool.self, forKey: .beforePersisted),
            afterPersisted: try values.decode(Bool.self, forKey: .afterPersisted)
        )
    }
}

@MainActor
final class DrawInMemoryStore: DrawStore {
    init(now: @escaping () -> Date = Date.init) { super.init(repository: DrawMemoryRepository(), now: now) }
}

#if DEBUG
/// Tests only: how many history steps the budget ledger has visited.
enum HistoryLedgerProbe {
    static var stepVisits = 0
    static var objectVisits = 0
    static var footprintSets = 0
    static func reset() { stepVisits = 0; objectVisits = 0; footprintSets = 0 }
}
#endif

/// The history steps offers are bound to. A pin lives exactly as long as the
/// offer's closure that holds it, so no release call can be forgotten; the
/// book is lock-protected because a closure can be released from anywhere.
final class DrawStepPins: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UUID: Set<UUID>] = [:]
    private var generation: UInt64 = 0
    var didRelease: (@Sendable () -> Void)?
    private var notificationPending = false
    func acknowledgeReleaseChange() {
        lock.lock(); notificationPending = false; lock.unlock()
    }
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    var hasPins: Bool { lock.lock(); defer { lock.unlock() }; return !counts.isEmpty }
    func pin(_ step: UUID) -> Pin {
        let token = UUID()
        lock.lock(); counts[step, default: []].insert(token); generation &+= 1; lock.unlock()
        return Pin(book: self, step: step, token: token)
    }
    func isPinned(_ step: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return counts[step]?.isEmpty == false
    }
    private func contains(_ step: UUID, token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return counts[step]?.contains(token) == true
    }
    func expire(_ step: UUID) {
        lock.lock()
        guard counts.removeValue(forKey: step) != nil else { lock.unlock(); return }
        changedWhileLocked()
    }
    private func release(_ step: UUID, token: UUID) {
        lock.lock()
        guard var held = counts[step], held.remove(token) != nil else { lock.unlock(); return }
        counts[step] = held.isEmpty ? nil : held
        changedWhileLocked()
    }
    private func changedWhileLocked() {
        generation &+= 1
        let notify = !notificationPending
        notificationPending = true
        lock.unlock()
        if notify { didRelease?() }
    }
    final class Pin: @unchecked Sendable {
        let book: DrawStepPins
        let step: UUID
        private let token: UUID
        private let lock = NSLock()
        private var cancelled = false
        var isActive: Bool { book.contains(step, token: token) }
        init(book: DrawStepPins, step: UUID, token: UUID) { self.book = book; self.step = step; self.token = token }
        func cancel() {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            cancelled = true; lock.unlock()
            book.release(step, token: token)
        }
        deinit { cancel() }
    }
}
