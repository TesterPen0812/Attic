import Foundation
import Observation

/// Shared command/history engine; the two backends expose exactly the same API.
@MainActor @Observable
class DrawStore: DrawStoreProtocol {
    static let maxHistorySteps = 100
    static let maxCachedStates = 8
    private(set) var revision: UInt64 = 0
    private(set) var lastDelta: DrawDelta?
    private(set) var pendingEdits: [UUID: DrawPendingEdit] = [:]
    private(set) var recoveryIssue: String?
    var hasUnsettledEdits: Bool { !pendingEdits.isEmpty || recoveryIssue != nil }

    @ObservationIgnored private let repository: any DrawRepository
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let recovery: DrawRecoveryJournal?
    @ObservationIgnored private var recoveredCanvasIDs = Set<UUID>()
    @ObservationIgnored private var states: [UUID: State] = [:]
    /// The canvases the menu and search list, newest first, with each one's
    /// position, so a lookup by id is not a scan.
    private struct SearchSnapshot {
        var revision: UInt64
        var canvases: [DrawCanvas]
        var ids: [UUID]
        var positions: [UUID: Int]
    }
    /// Rows hydrated per batched thumbnail read: the initial viewport plus a
    /// prefetch margin. One constant for the menu's window and search's.
    static let thumbnailWindow = 12
    @ObservationIgnored private var searchSnapshot: SearchSnapshot?
    /// Hydrated canvases by id. A change to one canvas (a thumbnail write, an
    /// edit, Undo or Redo) drops only its own entry; any other change drops
    /// them all.
    @ObservationIgnored private var searchThumbnails: [UUID: DrawCanvas] = [:]
    /// The last search result's order, which batches follow while its rows
    /// are on screen; otherwise batches follow the library order.
    @ObservationIgnored private var searchOrder: [UUID] = []
    @ObservationIgnored private var searchOrderPositions: [UUID: Int] = [:]
    @ObservationIgnored private var searchOrderIsCurrent = false
    var searchThumbnailCacheCount: Int { searchThumbnails.count }
    @ObservationIgnored private var histories: [UUID: History] = [:]
    /// The current in-memory head left by our own recovered inverse. A newer
    /// owner edit replaces that head and must still block earlier agent Undo.
    @ObservationIgnored private var agentReplayHeads: [UUID: UUID] = [:]
    @ObservationIgnored private var activeCanvasID: UUID?
    @ObservationIgnored private var stateAccess: [UUID: UInt64] = [:]
    @ObservationIgnored private var accessSequence: UInt64 = 0
    var cachedCanvasIDs: Set<UUID> { Set(states.keys) }
    /// Per canvas, the edits not yet saved, oldest first. Only the first
    /// has been tried; the rest wait behind it and are already on show.
    @ObservationIgnored private var pending: [UUID: [Pending]] = [:]
    /// A failed checkpoint can leave no journal record at all. Remember
    /// that this head has never entered the repository, independently of disk.
    @ObservationIgnored private var unsubmittedHeads = Set<UUID>()
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
    struct Step: Codable {
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
    private struct History { var undo: [Step] = []; var redo: [Step] = [] }
    enum Action: String, Codable { case edit, undo, redo }
    struct Pending: Codable { var step: Step; var action: Action }
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

    /// Every change publishes a new revision. A change that names its canvas
    /// (a thumbnail write, an edit, Undo or Redo) drops only that canvas's
    /// cached thumbnail; the others stay valid. Anything else drops all.
    private func bumpRevision(changed id: UUID? = nil) {
        revision &+= 1
        if let id {
            searchThumbnails[id] = nil
        } else {
            searchThumbnails.removeAll()
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

    /// The menu's canvases from the cached metadata snapshot: one read per
    /// revision, however often the list asks. Rows read their own thumbnail
    /// (`searchThumbnail`) when they are built, so nothing is hydrated here.
    func presentationLibrary() throws -> [DrawCanvas] {
        searchOrderIsCurrent = false
        return try searchMetadata()
    }

    func search(_ query: String) throws -> [DrawSearchMatch] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let rawTags = tokens.filter { $0.hasPrefix("#") }
        let tags = rawTags.compactMap(AtticTag.normalize)
        guard tags.count == rawTags.count else { return [] }
        let words = tokens.filter { !$0.hasPrefix("#") }
        let candidates: [DrawSearchMatch] = try searchMetadata().compactMap { canvas in
            guard tags.allSatisfy({ tag in canvas.tags.contains { $0.lowercased() == tag } }),
                  words.allSatisfy({ canvas.name.localizedStandardContains($0) || canvas.textIndex.localizedStandardContains($0) }) else { return nil }
            let textWords = words.filter { canvas.textIndex.localizedStandardContains($0) }
            let ids = textWords.isEmpty ? [] : try repository.textMatches(textWords, in: canvas.id)
            return DrawSearchMatch(canvas: canvas, matchingTextBoxIDs: ids)
        }
        searchOrder = candidates.map(\.canvas.id)
        searchOrderPositions = Dictionary(uniqueKeysWithValues: searchOrder.enumerated().map { ($1, $0) })
        searchOrderIsCurrent = true
        guard !candidates.isEmpty else { return [] }
        let hydrated = try hydratedPresentation(candidates.map(\.canvas))
        return zip(candidates, hydrated).map { match, canvas in
            DrawSearchMatch(canvas: canvas, matchingTextBoxIDs: match.matchingTextBoxIDs)
        }
    }

    /// The results with the stored thumbnails of the rows the search shows
    /// first. They come through the per-canvas cache, so an edit to one match
    /// re-reads only that match; the remaining rows hydrate as they are built.
    private func hydratedPresentation(_ canvases: [DrawCanvas]) throws -> [DrawCanvas] {
        let window = canvases.prefix(Self.thumbnailWindow).filter { needsThumbnailRead($0.id) }
        try loadThumbnails(Array(window))
        return canvases.map { canvas in
            recoveredCanvasIDs.contains(canvas.id) ? canvas : searchThumbnails[canvas.id] ?? canvas
        }
    }

    func searchThumbnail(_ id: UUID) throws -> DrawCanvas? {
        if recoveredCanvasIDs.contains(id) { return states[id]?.canvas }
        // The summary only names the canvas, so a stale snapshot is enough
        // and a write on another canvas costs no metadata read.
        let snapshot = try searchSnapshot ?? currentSearchSnapshot()
        guard let position = snapshot.positions[id] else { return nil }
        let metadata = snapshot.canvases[position]
        if let cached = searchThumbnails[id] { return cached }
        // A miss reads the uncached rows from this one to the end of its
        // window (a page of `thumbnailWindow` rows in the order the caller
        // lists them) in one batch: one context, two fetches.
        let inSearch = searchOrderIsCurrent ? searchOrderPositions[id] : nil
        let order = inSearch == nil ? snapshot.ids : searchOrder
        let start = inSearch ?? snapshot.positions[id]!
        let end = min((start / Self.thumbnailWindow + 1) * Self.thumbnailWindow, order.count)
        let batch: [DrawCanvas] = order[start..<end].compactMap { rowID in
            guard rowID == id || needsThumbnailRead(rowID), let at = snapshot.positions[rowID] else { return nil }
            return snapshot.canvases[at]
        }
        return try loadThumbnails(batch, requested: id) ?? metadata
    }

    private func needsThumbnailRead(_ id: UUID) -> Bool {
        searchThumbnails[id] == nil && !recoveredCanvasIDs.contains(id)
    }

    /// Reads the batch into the cache and returns the row for `requested`.
    @discardableResult
    private func loadThumbnails(_ batch: [DrawCanvas], requested: UUID? = nil) throws -> DrawCanvas? {
        guard !batch.isEmpty else { return nil }
        for row in try repository.hydrateSearchThumbnails(batch) { searchThumbnails[row.id] = row }
        return requested.flatMap { searchThumbnails[$0] }
    }

    private func searchMetadata() throws -> [DrawCanvas] { try currentSearchSnapshot().canvases }

    private func currentSearchSnapshot() throws -> SearchSnapshot {
        if let searchSnapshot, searchSnapshot.revision == revision { return searchSnapshot }
        var byID = Dictionary(uniqueKeysWithValues: try repository.searchMetadata().map { ($0.id, $0) })
        for id in recoveredCanvasIDs {
            if let draft = states[id]?.canvas { byID[id] = draft }
        }
        let canvases = byID.values.filter { $0.deletedAt == nil }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let snapshot = SearchSnapshot(revision: revision, canvases: canvases, ids: canvases.map(\.id),
                                      positions: Dictionary(uniqueKeysWithValues: canvases.enumerated().map { ($1.id, $0) }))
        searchSnapshot = snapshot
        return snapshot
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
            histories[key] = nil
            stateAccess[key] = nil
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
            stateAccess[id] = nil
        }
        for objectID in result.removedImages {
            guard let canvasID = images[objectID]?.canvas else { continue }
            states[canvasID]?.objects[objectID] = nil
            // Its steps (placing, moving, deleting it) can't be undone any
            // more, and history is a chain: the canvas starts afresh.
            histories[canvasID] = nil
        }
        let removed = result.removedCanvases.count + result.removedImages.count
        if removed > 0 { bumpRevision() }
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
        do {
            guard let step = try prepare(command, on: id) else { return .unchanged }
            guard pending[id] != nil else { return execute(step, action: .edit) }
            // An earlier edit isn't saved yet: this one shows at once and
            // waits behind it (never lost), then everything is tried again.
            let queued = stamped(step)
            show(queued)
            pending[id]?.append(Pending(step: queued, action: .edit))
            publishPending(id, outcome: pendingEdits[id]?.outcome ?? .retry(""))
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
            typingStepsPending[id, default: [:]][merged.id] = steps
            if let recovery {
                unsubmittedHeads.insert(id)
                do {
                    try recovery.update(id, edits: [Pending(step: merged, action: .edit)], proof: nil, unattempted: true)
                } catch {
                    pending[id] = [Pending(step: merged, action: .edit)]
                    return publishPending(id, outcome: .held("The text cannot be saved until its recovery checkpoint is written: \(error.localizedDescription)"))
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
        guard recoveryIssue == nil, let edits = pending[id], let last = edits.last,
              last.action == .edit, last.step.before.name == original, last.step.after.name == name,
              last.step.change.objectsBefore.isEmpty, last.step.change.objectsAfter.isEmpty else { return false }
        var renamed = last.step.before
        renamed.name = name
        renamed.updatedAt = last.step.after.updatedAt
        guard renamed == last.step.after else { return false }

        // Only the head can have been attempted. A queued tail is still a
        // draft; an attempted head can be dropped only after read-back proof.
        if edits.count == 1, recovery?.records[id]?.unattempted != true {
            guard case .retry = repository.reconcile(last.step.change) else { return false }
        }
        let remaining = Array(edits.dropLast())
        do {
            try recovery?.update(id, edits: remaining.isEmpty ? nil : remaining,
                                 proof: remaining.isEmpty ? nil : repository.recoveryProof(for: id),
                                 unattempted: recovery?.records[id]?.unattempted ?? false)
        } catch { return false }

        states[id]?.canvas = last.step.before
        states[id]?.persisted = last.step.beforePersisted
        pending[id] = remaining.isEmpty ? nil : remaining
        if let preceding = remaining.last, let outcome = pendingEdits[id]?.outcome {
            pendingEdits[id] = DrawPendingEdit(canvas: preceding.step.after,
                                               objects: states[id]?.snapshot.objects ?? [],
                                               outcome: outcome, count: remaining.count)
        } else {
            pendingEdits[id] = nil
            recoveredCanvasIDs.remove(id)
            repository.discardAttempt(for: id)
        }
        bumpRevision()
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
        return IdleLatencyTrace.span("draw_store_undo") { execute(step.reversed, action: .undo) }
    }
    func redo(on id: UUID) -> DrawSaveResult {
        guard canRedo(on: id), let step = histories[id]?.redo.last else { return .unchanged }
        return execute(step, action: .redo)
    }

    /// Read-only copies of the sparse history used to preview several rapid
    /// Undo/Redo actions. The page cannot change these store-owned stacks;
    /// every action still executes through the durable engine in FIFO order.
    func historyChanges(on id: UUID) -> (undo: [DrawChange], redo: [DrawChange])? {
        guard pending[id] == nil, recoveryIssue == nil else { return nil }
        return (histories[id]?.undo.map(\.change) ?? [], histories[id]?.redo.map(\.change) ?? [])
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
        touch(id)
        trimCachedStates(protecting: id)
        bumpRevision()
    }

    private func state(_ id: UUID) throws -> State {
        if let state = states[id] { touch(id); return state }
        guard let snapshot = try repository.load(id) else { throw DrawStoreError.missingCanvas }
        let state = State(canvas: snapshot.canvas, objects: Dictionary(uniqueKeysWithValues: snapshot.objects.map { ($0.id, $0) }), persisted: true)
        states[id] = state
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
            bumpRevision(changed: id)
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
            bumpRevision(changed: id)
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
        let id = step.change.canvasID
        states[id]?.canvas = step.after
        states[id]?.persisted = step.afterPersisted
        for objectID in step.change.objectIDs { states[id]?.objects[objectID] = step.change.objectsAfter[objectID] }
    }

    private func execute(_ step: Step, action: Action) -> DrawSaveResult {
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
                    "The drawing cannot be saved until its crash-recovery checkpoint can be written: \(error.localizedDescription)"
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
                if let recovery {
                    unsubmittedHeads.insert(id)
                    do {
                        try recovery.update(id, edits: pending[id], proof: repository.recoveryProof(for: id),
                                            unattempted: true)
                    } catch {
                        return publishPending(id, outcome: .held(
                            "The Draw recovery checkpoint could not be written before saving: \(error.localizedDescription)"
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
                            return publishPending(id, outcome: .held("The Draw recovery checkpoint could not be updated: \(error.localizedDescription)"))
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
        case .edit: appendUndo(step, on: id); histories[id]?.redo = []
        case .undo:
            if let original = histories[id]?.undo.popLast() { histories[id, default: History()].redo.append(original) }
        case .redo:
            _ = histories[id]?.redo.popLast()
            appendUndo(step, on: id)
        }
        bumpRevision(changed: id)
        let delta = DrawDelta(canvas: step.after,
                              upserted: step.change.objectsAfter.values.filter { $0.deletedAt == nil }.sorted(by: Self.objectOrder),
                              removedIDs: step.change.objectIDs.filter { step.change.objectsAfter[$0]?.deletedAt != nil || step.change.objectsAfter[$0] == nil }.sorted { $0.uuidString < $1.uuidString },
                              revision: revision)
        lastDelta = delta
        trimCachedStates(protecting: id)
        return delta
    }

    private func appendUndo(_ step: Step, on id: UUID) {
        histories[id, default: History()].undo.append(step)
        if let excess = histories[id]?.undo.count, excess > Self.maxHistorySteps {
            histories[id]?.undo.removeFirst(excess - Self.maxHistorySteps)
        }
    }

    @discardableResult
    private func publishPending(_ id: UUID, outcome: DrawSaveResult) -> DrawSaveResult {
        guard let edits = pending[id], let last = edits.last else { return outcome }
        var published = outcome
        if let recovery {
            do {
                try recovery.update(id, edits: edits, proof: repository.recoveryProof(for: id),
                                    unattempted: unsubmittedHeads.contains(id))
            }
            catch {
                published = .held("The drawing is held because its crash-recovery checkpoint could not be written: \(error.localizedDescription)")
            }
        }
        pendingEdits[id] = DrawPendingEdit(canvas: last.step.after, objects: states[id]?.snapshot.objects ?? [],
                                           outcome: published, count: edits.count)
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
