import Foundation
import Observation

/// Shared command/history engine; the two backends expose exactly the same API.
@MainActor @Observable
class DrawStore: DrawStoreProtocol {
    static let maxHistorySteps = 100
    static let maxProtectedHistoryBytes = 128 * 1024 * 1024
    static let maxCachedStates = 8
    static let maxEvictedHistoryBytes = 32 * 1024 * 1024
    var revision: UInt64 = 0
    var pendingGeneration: UInt64 = 0
    var lastDelta: DrawDelta?
    var pendingEdits: [UUID: DrawPendingEdit] = [:]
    var recoveryIssue: String?
    var hasUnsettledEdits: Bool { !pendingEdits.isEmpty || recoveryIssue != nil }

    @ObservationIgnored let repository: any DrawRepository
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored let recovery: DrawRecoveryJournal?
    @ObservationIgnored var recoveredCanvasIDs = Set<UUID>()
    @ObservationIgnored var recoveryLoadFailures: [UUID: String] = [:]
    @ObservationIgnored var states: [UUID: State] = [:]
    @ObservationIgnored var histories: [UUID: History] = [:]
    @ObservationIgnored var agentReplayHeads: [UUID: UUID] = [:]
    @ObservationIgnored var activeCanvasID: UUID?
    @ObservationIgnored var stateAccess: [UUID: UInt64] = [:]
    @ObservationIgnored var accessSequence: UInt64 = 0
    @ObservationIgnored var evictedAt: [UUID: UInt64] = [:]
    @ObservationIgnored var evictedLedger = HistoryLedger()
    @ObservationIgnored var ledgered: [UUID: LedgeredHistory] = [:]
    @ObservationIgnored var ledgerGeneration = 0
    @ObservationIgnored var saturatedLedgerGeneration = -1
    @ObservationIgnored var saturatedPinRevision: UInt64 = 0
    @ObservationIgnored let pins = DrawStepPins()
    var cachedCanvasIDs: Set<UUID> { Set(states.keys) }
    @ObservationIgnored var pending: [UUID: [Pending]] = [:]
    @ObservationIgnored var pendingAvailability: [UUID: (count: Int, last: UUID?, undo: Bool, redo: Bool)] = [:]
    @ObservationIgnored var unsubmittedHeads = Set<UUID>()
    @ObservationIgnored var checkpointDirty = Set<UUID>()
    @ObservationIgnored var typingStepsPending: [UUID: [UUID: [Step]]] = [:]

    struct State {
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
    struct History {
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
    enum Head { case write, reconcile, auto }

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

    func library(deleted: Bool = false) throws -> [DrawCanvas] {
        _ = revision
        var byID = Dictionary(uniqueKeysWithValues: try repository.library().map { ($0.id, $0) })
        // Recovery metadata can make an unreadable first-save canvas
        // discoverable without pretending to have loaded its object body.
        for id in recoveredCanvasIDs {
            if let draft = states[id]?.canvas ?? recovery?.records[id]?.edits.last?.step.after { byID[id] = draft }
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

    func touch(_ id: UUID) {
        accessSequence &+= 1
        stateAccess[id] = accessSequence
    }

    /// Only durably persisted, inactive canvases may be reloaded later.
    func trimCachedStates(protecting id: UUID? = nil) {
        guard states.count > Self.maxCachedStates else { return }
        let candidates = states.keys.filter { key in
            key != id && key != activeCanvasID && pending[key] == nil && states[key]?.persisted == true
        }.sorted { (stateAccess[$0] ?? 0) < (stateAccess[$1] ?? 0) }
        for key in candidates.prefix(states.count - Self.maxCachedStates) {
            states[key] = nil
            stateAccess[key] = nil
            accessSequence &+= 1
            evictedAt[key] = accessSequence
        }
        boundEvictedHistories()
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
        if recoveryIssue != nil { return DrawPurgeReport(removed: 0, kept: Set(targets).count) }
        var canvases: [UUID: Date] = [:], images: [UUID: DrawImageTarget] = [:], kept = 0
        for target in Set(targets) {
            switch target {
            case let .canvas(id, deletedAt):
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

    func state(_ id: UUID) throws -> State {
        if let message = recoveryLoadFailures[id] { throw RecoveryLoadError(message: message) }
        if let state = states[id] { touch(id); return state }
        guard let snapshot = try repository.load(id) else { throw DrawStoreError.missingCanvas }
        let state = State(canvas: snapshot.canvas, objects: Dictionary(uniqueKeysWithValues: snapshot.objects.map { ($0.id, $0) }), persisted: true)
        states[id] = state
        removeLedgered(id)
        touch(id)
        trimCachedStates(protecting: id)
        return state
    }

    static func name(_ value: String?) -> String {
        let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Untitled" : name
    }
    nonisolated static func objectOrder(_ lhs: DrawObject, _ rhs: DrawObject) -> Bool {
        lhs.zIndex == rhs.zIndex ? lhs.id.uuidString < rhs.id.uuidString : lhs.zIndex < rhs.zIndex
    }
    static func isRestore(_ command: DrawCommand) -> Bool { if case .restoreCanvas = command { true } else { false } }
    static func validate(_ object: DrawObject) throws {
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
