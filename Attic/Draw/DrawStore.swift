import Foundation
import Observation

/// Shared command/history engine; the two backends expose exactly the same API.
@MainActor @Observable
class DrawStore: DrawStoreProtocol {
    private(set) var revision: UInt64 = 0
    private(set) var lastDelta: DrawDelta?
    private(set) var pendingEdits: [UUID: DrawPendingEdit] = [:]
    var hasUnsettledEdits: Bool { !pendingEdits.isEmpty }

    @ObservationIgnored private let repository: any DrawRepository
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var states: [UUID: State] = [:]
    @ObservationIgnored private var histories: [UUID: History] = [:]
    @ObservationIgnored private var pending: [UUID: Pending] = [:]

    private struct State {
        var canvas: DrawCanvas
        var objects: [UUID: DrawObject] = [:]
        var persisted = false
        var snapshot: DrawSnapshot {
            DrawSnapshot(canvas: canvas, objects: objects.values.filter { $0.deletedAt == nil }.sorted(by: DrawStore.objectOrder))
        }
    }
    private struct Step {
        var change: DrawChange
        var before: DrawCanvas
        var after: DrawCanvas
        var beforePersisted: Bool
        var afterPersisted: Bool
        var reversed: Self {
            Self(change: change.reversed, before: after, after: before,
                 beforePersisted: afterPersisted, afterPersisted: beforePersisted)
        }
    }
    private struct History { var undo: [Step] = []; var redo: [Step] = [] }
    private enum Action { case edit, undo, redo }
    private struct Pending { var step: Step; var action: Action }

    init(repository: any DrawRepository, now: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.now = now
    }

    func library(deleted: Bool = false) throws -> [DrawCanvas] {
        // Observe successful changes while keeping the query body-free.
        _ = revision
        return try repository.library().filter { ($0.deletedAt != nil) == deleted }.sorted {
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
        let canvas = DrawCanvas(name: Self.name(name), createdAt: date, updatedAt: date)
        states[canvas.id] = State(canvas: canvas)
        return canvas
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
        return []
    }

    func purge(_ targets: [DrawPurgeTarget]) -> DrawPurgeReport {
        DrawPurgeReport(removed: 0, kept: targets.count)
    }

    func purge(deletedBefore cutoff: Date) -> DrawPurgeReport { DrawPurgeReport() }

    func perform(_ command: DrawCommand, on id: UUID) -> DrawSaveResult {
        guard pending[id] == nil else { return pendingEdits[id]!.outcome }
        do {
            guard let step = try prepare(command, on: id) else { return .unchanged }
            return execute(step, action: .edit)
        } catch { return .held("Could not prepare the edit: \(error)") }
    }

    /// Read a sparse patch without copying the whole object dictionary into
    /// history. This read scope ends before settle mutates the cached state.
    private func prepare(_ command: DrawCommand, on id: UUID) throws -> Step? {
        let before = try state(id)
        guard before.canvas.deletedAt == nil || Self.isRestore(command) else { throw DrawStoreError.missingCanvas }
        var after = before.canvas
        var objects: [UUID: DrawObject] = [:]
        switch command {
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
        case .thumbnail(let bytes): after.thumbnail = bytes
        case .deleteCanvas: after.deletedAt = now()
        case .restoreCanvas: after.deletedAt = nil
        }
        objects = objects.filter { before.objects[$0.key] != $0.value }
        guard !objects.isEmpty || before.canvas != after else { return nil }
        var originals: [UUID: DrawObject] = [:]
        for id in objects.keys { originals[id] = before.objects[id] }
        if objects.keys.contains(where: { !(originals[$0]?.text ?? "").isEmpty || !(objects[$0]?.text ?? "").isEmpty }) {
            let unchangedText = before.objects.values.filter { objects[$0.id] == nil && $0.deletedAt == nil && !$0.text.isEmpty }
            let changedText = objects.values.filter { $0.deletedAt == nil && !$0.text.isEmpty }
            after.textIndex = (unchangedText + changedText).sorted(by: Self.objectOrder).map(\.text).joined(separator: "\n")
        }
        after.updatedAt = now()
        let persisted = before.persisted || !objects.isEmpty
        let change = DrawChange(canvasID: id, before: before.persisted ? before.canvas : nil,
                                after: persisted ? after : nil, objectsBefore: originals, objectsAfter: objects)
        return Step(change: change, before: before.canvas, after: after,
                    beforePersisted: before.persisted, afterPersisted: persisted)
    }

    func retry(on id: UUID) -> DrawSaveResult {
        guard let edit = pending[id] else { return .unchanged }
        guard case .retry = pendingEdits[id]?.outcome else {
            return .held("The stored state needs reconciliation before Retry.")
        }
        return execute(edit.step, action: edit.action)
    }

    func reconcile(on id: UUID) -> DrawSaveResult {
        guard let edit = pending[id] else { return .unchanged }
        return settle(repository.reconcile(edit.step.change), step: edit.step, action: edit.action)
    }

    func canUndo(on id: UUID) -> Bool {
        _ = revision; _ = pendingEdits
        return pending[id] == nil && !(histories[id]?.undo.isEmpty ?? true)
    }
    func canRedo(on id: UUID) -> Bool {
        _ = revision; _ = pendingEdits
        return pending[id] == nil && !(histories[id]?.redo.isEmpty ?? true)
    }

    func undo(on id: UUID) -> DrawSaveResult {
        guard canUndo(on: id), let step = histories[id]?.undo.last else { return .unchanged }
        return execute(step.reversed, action: .undo)
    }
    func redo(on id: UUID) -> DrawSaveResult {
        guard canRedo(on: id), let step = histories[id]?.redo.last else { return .unchanged }
        return execute(step, action: .redo)
    }

    func duplicate(_ id: UUID, name: String? = nil) throws -> DrawCanvas? {
        let source = try open(id)
        guard pending[id] == nil, source.canvas.deletedAt == nil else { throw DrawStoreError.pendingEdit }
        let copy = create(name: name ?? source.canvas.name + " copy")
        states[copy.id]?.canvas.tags = source.canvas.tags
        states[copy.id]?.canvas.thumbnail = source.canvas.thumbnail
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
        revision &+= 1
    }

    private func state(_ id: UUID) throws -> State {
        if let state = states[id] { return state }
        guard let snapshot = try repository.load(id) else { throw DrawStoreError.missingCanvas }
        let state = State(canvas: snapshot.canvas, objects: Dictionary(uniqueKeysWithValues: snapshot.objects.map { ($0.id, $0) }), persisted: true)
        states[id] = state
        return state
    }
    private func execute(_ step: Step, action: Action) -> DrawSaveResult {
        let outcome: DrawWriteOutcome = step.change.before == nil && step.change.after == nil
            ? .committed : repository.write(step.change)
        return settle(outcome, step: step, action: action)
    }
    private func settle(_ outcome: DrawWriteOutcome, step: Step, action: Action) -> DrawSaveResult {
        let id = step.change.canvasID
        states[id]?.canvas = step.after
        states[id]?.persisted = step.afterPersisted
        for objectID in step.change.objectIDs { states[id]?.objects[objectID] = step.change.objectsAfter[objectID] }
        switch outcome {
        case .committed:
            pending[id] = nil
            pendingEdits[id] = nil
            switch action {
            case .edit: histories[id, default: History()].undo.append(step); histories[id]?.redo = []
            case .undo:
                if let original = histories[id]?.undo.popLast() { histories[id, default: History()].redo.append(original) }
            case .redo:
                _ = histories[id]?.redo.popLast()
                histories[id, default: History()].undo.append(step)
            }
            revision &+= 1
            let delta = DrawDelta(canvas: step.after,
                                  upserted: step.change.objectsAfter.values.filter { $0.deletedAt == nil }.sorted(by: Self.objectOrder),
                                  removedIDs: step.change.objectIDs.filter { step.change.objectsAfter[$0]?.deletedAt != nil || step.change.objectsAfter[$0] == nil }.sorted { $0.uuidString < $1.uuidString },
                                  revision: revision)
            lastDelta = delta
            return .saved(delta)
        case .retry(let message): return retain(.retry(message), step: step, action: action)
        case .held(let message): return retain(.held(message), step: step, action: action)
        }
    }
    private func retain(_ outcome: DrawSaveResult, step: Step, action: Action) -> DrawSaveResult {
        pending[step.change.canvasID] = Pending(step: step, action: action)
        pendingEdits[step.change.canvasID] = DrawPendingEdit(canvas: step.after, objects: states[step.change.canvasID]?.snapshot.objects ?? [], outcome: outcome)
        return outcome
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

@MainActor
final class DrawInMemoryStore: DrawStore {
    init(now: @escaping () -> Date = Date.init) { super.init(repository: DrawMemoryRepository(), now: now) }
}
