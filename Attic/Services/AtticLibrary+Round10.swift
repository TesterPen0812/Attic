import Foundation

/// Round 10's task commands (the capability audit): Duplicate, edits and
/// Delete on the Done page, and a subtask's move in the quick look. Each is
/// one undoable step in the history it names, recorded only after the store
/// confirmed the save.
extension AtticLibrary {
    /// Duplicates main tasks as one step (`TaskStore.duplicate`): undo
    /// moves the copies (with their subtasks) to Recently Deleted, redo
    /// brings them back, as undoing an add does. Returns the copies.
    @discardableResult
    func duplicateTasks(_ ids: [UUID], in history: UndoHistoryID = .tasks) -> [TaskItem]? {
        var created: [TaskItem]?
        let serial = tasks.errorSerial
        defer { if created == nil { _ = taskOutcome(false, since: serial, ids: ids) } }
        undo.perform(in: history) {
            guard let copies = self.tasks.duplicate(taskIDs: ids), !copies.isEmpty else { return nil }
            created = copies
            let newIDs = copies.map(\.id)
            // The copies and the subtasks they were made with.
            let owned = itemOwnership(liveFamilyMembers(of: newIDs), deleted: false)
            return UndoStep(
                name: ids.count == 1 ? "Duplicate Task" : "Duplicate \(ids.count) Tasks",
                items: { owned.itemRefs },
                undoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.deleteFamiliesFromHistory(newIDs, owning: owned)
                },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.restoreFamiliesFromHistory(newIDs, owning: owned)
                }
            )
        }
        return created
    }

    /// Title, priority, tags or due date on tasks wherever they are listed,
    /// the Done log included, as one step; their state never changes.
    @discardableResult
    func updateListedTasks(
        _ ids: [UUID],
        title: String? = nil,
        priority: TaskPriority? = nil,
        tags: [String]? = nil,
        isFlagged: Bool? = nil,
        url: String?? = nil,
        dueDay: DueDay?? = nil,
        addingTag: String? = nil,
        removingTag: String? = nil,
        in history: UndoHistoryID = .tasks
    ) -> CommandOutcome {
        let requested = ids
        let ids = ids.filter { tasks.listedTask(withID: $0) != nil }
        guard !ids.isEmpty else { return taskOutcome(false, since: tasks.errorSerial, ids: requested) }
        func capture(_ id: UUID) -> TaskEditableState? {
            isFlagged != nil || url != nil ? tasks.reminderEditableState(of: id, listed: true) : tasks.listedEditableState(of: id)
        }
        var succeeded = false
        let serial = tasks.errorSerial
        undo.perform(in: history) {
            let before = ids.compactMap(capture)
            guard before.count == ids.count, tasks.updateListed(ids, title: title, priority: priority, tags: tags, isFlagged: isFlagged, url: url, dueDay: dueDay,
                                     addingTag: addingTag, removingTag: removingTag) else { return nil }
            succeeded = true
            let beforeByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let after = ids.compactMap { id -> TaskEditableState? in
                guard let scalar = tasks.listedEditableState(of: id), let old = beforeByID[id] else { return nil }
                return scalar.withReminderReplicas(from: old, editingFlag: isFlagged != nil, editingURL: url != nil)
            }
            guard after.count == ids.count, before != after else { return nil }
            return UndoStep(
                name: ids.count == 1 ? "Edit Task" : "Edit Tasks",
                items: { Set((before + after).map { AtticItemRef(.task, $0.id) }) },
                undoOutcome: { [tasks = self.tasks] in tasks.applyEditableTransition(from: after, to: before) },
                redoOutcome: { [tasks = self.tasks] in tasks.applyEditableTransition(from: before, to: after) }
            )
        }
        return taskOutcome(succeeded, since: serial, ids: ids)
    }

    /// Deletes tasks wherever they are listed, the Done log included (Done's
    /// Delete), as one step: each with its family to Recently Deleted; undo
    /// brings them all back where they were (a Done log task to the log).
    @discardableResult
    func deleteListedTasks(_ ids: [UUID], in history: UndoHistoryID = .tasks) -> CommandOutcome {
        let serial = tasks.errorSerial
        let deleted = undo.perform(in: history) {
            guard deleteFamiliesNow(ids, includingDoneLog: true) else { return nil }
            // What this delete took, to keep Redo from taking more.
            let owned = itemOwnership(recordedMembers(of: ids), deleted: true)
            return UndoStep(
                name: ids.count == 1 ? "Delete Task" : "Delete \(ids.count) Tasks",
                items: { owned.itemRefs },
                undoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.restoreFamiliesFromHistory(ids, owning: owned)
                },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.deleteFamiliesFromHistory(ids, owning: owned, includingDoneLog: true)
                }
            )
        }
        return taskOutcome(deleted, since: serial, ids: ids)
    }

    /// A subtask one place up or down among its siblings, as one step.
    @discardableResult
    func moveSubtask(_ id: UUID, by offset: Int, in history: UndoHistoryID = .tasks) -> CommandOutcome {
        var succeeded = false
        let serial = tasks.errorSerial
        undo.perform(in: history) {
            guard let task = tasks.task(withID: id), let parentID = task.parentID else { return nil }
            let family = tasks.subtasks(of: parentID).map(\.id)
            let before = family.compactMap(tasks.editableState(of:))
            guard tasks.moveSubtask(taskID: id, by: offset) else { return nil }
            succeeded = true
            let after = family.compactMap(tasks.editableState(of:))
            subtaskOrderChanges.send(parentID)
            guard before != after else { return nil }
            return UndoStep(
                name: "Move Subtask",
                items: { Set((before + after).map { AtticItemRef(.task, $0.id) }) },
                undoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    let outcome = self.tasks.applyEditableTransition(from: after, to: before)
                    if outcome == .applied { self.subtaskOrderChanges.send(parentID) }
                    return outcome
                },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    let outcome = self.tasks.applyEditableTransition(from: before, to: after)
                    if outcome == .applied { self.subtaskOrderChanges.send(parentID) }
                    return outcome
                }
            )
        }
        return taskOutcome(succeeded, since: serial, ids: [id])
    }
}
