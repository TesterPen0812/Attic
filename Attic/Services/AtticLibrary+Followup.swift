import Foundation

/// The Phase 1 follow-up (control audit items 5 and 11): a subtask moved to
/// another task or made a task of its own, and several Recently Deleted
/// items restored together. Each is one undoable step, recorded only after
/// the store confirmed the save.
extension AtticLibrary {
    // MARK: - Item 5: Move to Task… and Make Standalone Task

    /// Moves a subtask to another main task (`newParentID`), or makes it a
    /// main task of its own (nil), as one step (`TaskStore.reparentSubtask`
    /// says where it lands and what it keeps). Undo puts it back under its
    /// old main task, in its old place; redo moves it again. Both refuse,
    /// changing nothing, once the main task they need is gone, finished or
    /// in Recently Deleted.
    @discardableResult
    func moveSubtask(_ id: UUID, toTask newParentID: UUID?, in history: UndoHistoryID = .tasks) -> CommandOutcome {
        var succeeded = false
        let serial = tasks.errorSerial
        undo.perform(in: history) {
            guard let task = tasks.task(withID: id), let oldParentID = task.parentID else { return nil }
            let scope = Array(Set(tasks.reparentScope(of: id, to: newParentID) + [id]))
            let before = scope.compactMap(tasks.editableState(of:))
            guard tasks.reparentSubtask(id, to: newParentID) else { return nil }
            succeeded = true
            let after = scope.compactMap(tasks.editableState(of:))
            let families = [oldParentID] + (newParentID.map { [$0] } ?? [])
            for family in families { subtaskOrderChanges.send(family) }
            guard before != after else { return nil }
            return UndoStep(
                name: newParentID == nil ? "Make Standalone Task" : "Move to Task",
                undoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    let outcome = self.tasks.applyEditableTransition(from: after, to: before)
                    if outcome == .applied { for family in families { self.subtaskOrderChanges.send(family) } }
                    return outcome
                },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    let outcome = self.tasks.applyEditableTransition(from: before, to: after)
                    if outcome == .applied { for family in families { self.subtaskOrderChanges.send(family) } }
                    return outcome
                }
            )
        }
        return taskOutcome(succeeded, since: serial, ids: [id])
    }
}
