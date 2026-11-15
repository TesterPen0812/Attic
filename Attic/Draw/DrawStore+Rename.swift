import Foundation

@MainActor
extension DrawStore {
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
}
