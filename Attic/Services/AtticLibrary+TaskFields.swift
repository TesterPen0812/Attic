import Foundation

extension AtticLibrary {
    /// Date and tags on one or several tasks (the right-click menu, a
    /// row's popovers; owner fixes 3 and 5) as one step: every task
    /// changes or none does, and one undo takes them all back.
    @discardableResult
    func updateTaskFields(
        _ ids: [UUID],
        dueDay: DueDay?? = nil,
        addingTag: String? = nil,
        removingTag: String? = nil,
        in history: UndoHistoryID = .tasks
    ) -> CommandOutcome {
        let requested = ids
        let ids = ids.filter { tasks.task(withID: $0) != nil }
        guard !ids.isEmpty else { return taskOutcome(false, since: tasks.errorSerial, ids: requested) }
        var succeeded = false
        let serial = tasks.errorSerial
        undo.perform(in: history) {
            let before = ids.compactMap(tasks.editableState(of:))
            guard tasks.updateBatchFields(ids, dueDay: dueDay, addingTag: addingTag, removingTag: removingTag) else { return nil }
            succeeded = true
            let after = ids.compactMap(tasks.editableState(of:))
            guard before != after else { return nil }
            return UndoStep(
                name: ids.count == 1 ? "Edit Task" : "Edit Tasks",
                undoOutcome: { [tasks = self.tasks] in tasks.applyEditableTransition(from: after, to: before) },
                redoOutcome: { [tasks = self.tasks] in tasks.applyEditableTransition(from: before, to: after) }
            )
        }
        return taskOutcome(succeeded, since: serial, ids: ids)
    }
}
