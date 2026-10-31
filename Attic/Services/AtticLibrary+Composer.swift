import Foundation

/// What the "+" card creates (Accepted 2026-10-29, "The '+' card"): a task
/// with its writing, or a quick note, each as one undoable step in the
/// history of the page it was made on.
extension AtticLibrary {
    /// A task and the writing typed under its title are one item (One
    /// Item): one save each, recorded as one step. Undo moves both to
    /// Recently Deleted; Redo brings both back. With no writing it is
    /// `createTasks` exactly.
    @discardableResult
    func createTask(_ draft: TaskDraft, writing: String, in history: UndoHistoryID) -> TaskItem? {
        let body = writing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let notes else { return createTasks([draft], in: history)?.first }
        var created: TaskItem?
        let serial = tasks.errorSerial
        defer { if created == nil { _ = taskOutcome(false, since: serial, ids: []) } }
        undo.perform(in: history) {
            guard let task = self.tasks.commit([draft])?.first else { return nil }
            guard let document = try? NoteAgentTextParser.document(title: task.title, body: body, base: .blank)
                    .taskSnapshot(title: task.title),
                  case .success = notes.createDocumentNote(id: UUID(), document: document, taskOwner: task.id) else {
                // Never a task without the writing it was given: the half
                // that saved goes again, and the draft stays in the card.
                _ = deleteFamiliesFromHistory([task.id], owning: itemOwnership(liveFamilyMembers(of: [task.id]), deleted: false))
                refreshItemStores()
                return nil
            }
            created = task
            let ids = [task.id]
            let owned = itemOwnership(liveFamilyMembers(of: ids), deleted: false)
            return UndoStep(
                name: "Add Task",
                items: { owned.itemRefs },
                undoOutcome: { [weak self] in self?.deleteFamiliesFromHistory(ids, owning: owned) ?? .obsolete },
                redoOutcome: { [weak self] in self?.restoreFamiliesFromHistory(ids, owning: owned) ?? .obsolete }
            )
        }
        return created
    }

    /// A quick note: title, writing, tags and pin in one step. Undo moves it
    /// to Recently Deleted; Redo restores it. Nil when nothing was saved.
    @discardableResult
    func createNote(title: String, body: String, tags: [String], pinned: Bool, in history: UndoHistoryID) -> UUID? {
        guard let notes else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else { return nil }
        var created: UUID?
        undo.perform(in: history) {
            guard let document = try? NoteAgentTextParser.document(title: trimmedTitle, body: trimmedBody, base: .blank),
                  case let .success((noteID, _)) = notes.createDocumentNote(
                    id: UUID(), document: document, tags: tags.isEmpty ? nil : AtticTag.normalizedSet(tags)) else { return nil }
            if pinned { _ = notes.setPinnedOutcome(true, noteID: noteID) }
            created = noteID
            let ref = AtticItemRef(.note, noteID)
            let owned = itemOwnership(ownedMembers(of: ref), deleted: false, noteID: noteID)
            return UndoStep(
                name: "Add Note",
                items: { owned.itemRefs.union([ref]) },
                undoOutcome: { [weak self] in self?.deleteOutcome(ref, owning: owned) ?? .obsolete },
                redoOutcome: { [weak self] in self?.restoreOutcome(ref, owning: owned) ?? .obsolete }
            )
        }
        return created
    }
}
