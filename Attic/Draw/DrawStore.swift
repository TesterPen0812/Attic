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
    /// Per canvas, the edits not yet saved, oldest first. Only the first
    /// has been tried; the rest wait behind it and are already on show.
    @ObservationIgnored private var pending: [UUID: [Pending]] = [:]

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
    /// How the first unsaved edit is settled: written again (Retry),
    /// reconciled with what the store holds, or whichever its outcome asks.
    private enum Head { case write, reconcile, auto }

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
        return try repository.deletedImageHeaders().sorted {
            ($0.object.deletedAt ?? .distantPast, $0.object.id.uuidString) > ($1.object.deletedAt ?? .distantPast, $1.object.id.uuidString)
        }
    }

    func purge(_ targets: [DrawPurgeTarget]) -> DrawPurgeReport {
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
        }
        for objectID in result.removedImages {
            guard let canvasID = images[objectID]?.canvas else { continue }
            states[canvasID]?.objects[objectID] = nil
            // Its steps (placing, moving, deleting it) can't be undone any
            // more, and history is a chain: the canvas starts afresh.
            histories[canvasID] = nil
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
        if case .thumbnail(let bytes) = command { return writeThumbnail(bytes, on: id) }
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
    /// A thumbnail is not an edit: no Undo step, no new date (so no move in
    /// the menu), and a failure leaves nothing waiting for Retry (the next
    /// settle renders it again). A draft has none until its first content.
    private func writeThumbnail(_ bytes: Data?, on id: UUID) -> DrawSaveResult {
        guard pending[id] == nil, let current = try? state(id), current.canvas.thumbnail != bytes else { return .unchanged }
        var after = current.canvas
        after.thumbnail = bytes
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
        step.before.thumbnail = thumbnail
        step.after.thumbnail = thumbnail
        if step.change.before != nil { step.change.before?.thumbnail = thumbnail }
        if step.change.after != nil { step.change.after?.thumbnail = thumbnail }
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
        let outcome = write(step)
        show(step)
        switch outcome {
        case .committed: return .saved(commit(step, action: action))
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
            if reconcileFirst {
                // A held save is read back, never overwritten.
                outcome = repository.reconcile(edit.step.change)
            } else {
                edit.step = stamped(edit.step)
                pending[id]?[0] = edit
                outcome = write(edit.step)
            }
            first = false
            switch outcome {
            case .committed:
                pending[id]?.removeFirst()
                if pending[id]?.isEmpty == true {
                    pending[id] = nil
                    pendingEdits[id] = nil
                }
                saved.append(commit(edit.step, action: edit.action))
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
        return delta
    }

    @discardableResult
    private func publishPending(_ id: UUID, outcome: DrawSaveResult) -> DrawSaveResult {
        guard let edits = pending[id], let last = edits.last else { return outcome }
        pendingEdits[id] = DrawPendingEdit(canvas: last.step.after, objects: states[id]?.snapshot.objects ?? [],
                                           outcome: outcome, count: edits.count)
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
