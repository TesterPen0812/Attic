import Foundation

@MainActor
extension DrawStore {
    func perform(_ command: DrawCommand, on id: UUID) -> DrawSaveResult {
        if let recoveryIssue { return .held(recoveryIssue) }
        if case .thumbnail(let bytes, let dark) = command { return writeThumbnail(bytes, dark: dark, on: id) }
        if case .rename = command, pending[id]?.contains(where: { $0.action != .edit }) == true {
            return historyMustResume()
        }
        do {
            guard let step = try prepare(command, on: id) else { return .unchanged }
            guard pending[id] != nil else { return execute(step, action: .edit) }
            let queued = stamped(step)
            expireRedoOffers(on: id)
            show(queued)
            pending[id]?.append(Pending(step: queued, action: .edit))
            let published = publishPending(id, outcome: pendingEdits[id]?.outcome ?? .retry(""))
            guard !checkpointDirty.contains(id) else { return published }
            return flush(id, head: .auto)
        } catch { return .held("Could not prepare the edit: \(error)") }
    }

    /// A short same-box burst has one physical save and per-key session Undo.
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

    /// Sparse before/after values, never a full object dictionary in history.
    func prepare(_ command: DrawCommand, on id: UUID) throws -> Step? {
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
        case .tags(let tags): after.tags = AtticTag.normalizedSet(tags)
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

    /// Quiet thumbnails do not create Undo steps or change the canvas date.
    func writeThumbnail(_ bytes: Data?, dark: Bool?, on id: UUID) -> DrawSaveResult {
        let dark = bytes == nil ? nil : dark
        guard pending[id] == nil, let current = try? state(id),
              current.canvas.thumbnail != bytes || current.canvas.thumbnailDark != dark else { return .unchanged }
        var after = current.canvas
        after.thumbnail = bytes
        after.thumbnailDark = dark
        guard current.canvas.deletedAt == nil else { return .unchanged }
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

    func duplicate(_ id: UUID, name: String? = nil) throws -> DrawCanvas? {
        let source = try open(id)
        guard pending[id] == nil, source.canvas.deletedAt == nil else { throw DrawStoreError.pendingEdit }
        let copy = create(name: name ?? source.canvas.name + " copy")
        states[copy.id]?.canvas.tags = source.canvas.tags
        states[copy.id]?.canvas.thumbnail = source.canvas.thumbnail
        states[copy.id]?.canvas.thumbnailDark = source.canvas.thumbnailDark
        let objects = source.objects.map { $0.translated(by: DrawPoint()) }
        let result = perform(.put(objects), on: copy.id)
        return result.isSaved || objects.isEmpty || pending[copy.id] != nil ? states[copy.id]?.canvas : nil
    }

    struct Clipboard: Codable { var version = 1; var objects: [DrawObject] }
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
}
