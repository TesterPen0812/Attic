import AppKit
import SwiftUI

/// Round 10 (the capability audit, owner-approved): Copy and Duplicate,
/// and managing a subtask where the quick look shows it. Each change is one
/// step in the Tasks history, with an Undo toast; nothing is only reachable
/// one way (the menus, the keys and VoiceOver call these).
extension TasksPageModel {
    // MARK: - Copy and Duplicate

    /// What ⌘C puts on the pasteboard as plain text: each task's title, one
    /// per line, in list order, so it pastes anywhere (and back into the
    /// add bar as one task per line).
    func copyText(_ ids: [UUID]) -> String? {
        export(ids)?.titles
    }

    /// The tasks as text for other apps (`TasksTextExport`): ⌘C and a drag
    /// out of the panel share it. Nil when none of them is listed.
    func export(_ ids: [UUID]) -> TasksTextExport? {
        var items: [TasksTextExport.Item] = []
        for id in ids {
            guard let task = store.listedTask(withID: id) else { continue }
            // A live family's subtasks, or a Done-log family's (they left
            // with it); one that cannot be read stops the whole export, so
            // no copy or drag goes out without its subtasks (GPT-6.1's
            // review). The store reports the failure.
            guard let subtasks = try? store.readListedSubtasks(of: id) else { return nil }
            items.append(TasksTextExport.Item(
                title: task.title,
                isDone: task.status == .done,
                due: task.dueDay.map { dueText($0) },
                tags: task.tags,
                priority: task.priority == .none ? nil : TasksTextExport.priorityName(task.priority),
                subtasks: subtasks.map { .init(title: $0.title, isDone: $0.status == .done) }
            ))
        }
        return items.isEmpty ? nil : TasksTextExport(items: items)
    }

    /// ⌘C and Copy: the tasks' titles on the general pasteboard as plain
    /// text, their full text as Markdown and RTF. Nothing in the store
    /// changes, so there is no toast; VoiceOver hears it.
    @discardableResult
    func copy(_ ids: [UUID], to pasteboard: NSPasteboard = .general) -> Bool {
        guard let export = export(ids) else { return false }
        export.write(to: pasteboard)
        AccessibilityNotification.Announcement(
            ids.count == 1 ? String(localized: "Copied") : String(localized: "Copied \(ids.count) tasks")
        ).post()
        return true
    }

    /// ⌘D and Duplicate: an unfinished copy of each task, with copies of
    /// its subtasks (their own ids), right below it (`TaskStore.duplicate`
    /// says where exactly, and what is copied: the date is kept, files
    /// stay with the original). One step, with an Undo toast; the copies
    /// are selected.
    @discardableResult
    func duplicate(_ ids: [UUID]) -> CommandOutcome {
        let sources = ids.compactMap { store.listedTask(withID: $0) }
        guard !sources.isEmpty else { return .failed(.taskGone) }
        guard let copies = library.duplicateTasks(sources.map(\.id)) else {
            return library.lastFailure.map { CommandOutcome.failed($0) } ?? .failed(.taskGone)
        }
        let hasFiles = sources.contains { !$0.attachments.isEmpty }
        let copyIDs = copies.map(\.id)
        // The copies are where the person is: selected, on their list's
        // page (a copy from Done goes to Now's to do).
        if let first = copies.first {
            let target: TasksTab = first.status == .backlog ? .backlog : .now
            if tab != target { select(tab: target) }
            selectCopies(copyIDs)
            addedRequest = ScrollRequest(id: first.id)
        }
        let message = copies.count == 1 ? String(localized: "Duplicated") : String(localized: "Duplicated \(copies.count) tasks")
        showToast(hasFiles ? String(localized: "\(message) · files stay with the original") : message)
        return .applied
    }

    // MARK: - Subtasks in the quick look

    /// Return on a subtask (or Rename): its title in place.
    func beginRenamingSubtask(_ id: UUID) {
        guard let task = store.task(withID: id), task.parentID != nil, renamingSubtaskID != id else { return }
        guard finishEditing() else { return }
        subtaskRename = task.title
        renamingSubtaskParentID = task.parentID
        renamingSubtaskID = id
    }

    /// Return in the subtask's field: saved as one step. A failed save
    /// keeps the field and its text ("Not saved · Retry"). Returns whether
    /// the rename is finished.
    @discardableResult
    func commitSubtaskRename() -> Bool {
        guard let id = renamingSubtaskID else { return true }
        let title = subtaskRename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let task = store.task(withID: id), !title.isEmpty, title != task.title else {
            // Nothing to save (put back to the original, emptied, or its
            // task is gone): a failure from an earlier try is over too
            // (round 12, P2-1: it kept the page's unsaved-edit hold).
            renamingSubtaskID = nil
            renamingSubtaskParentID = nil
            subtaskRenameFailed = false
            return true
        }
        guard library.updateTask(id, title: title).isApplied else {
            subtaskRenameFailed = true
            return false
        }
        subtaskRenameFailed = false
        renamingSubtaskID = nil
        renamingSubtaskParentID = nil
        return true
    }

    func cancelSubtaskRename() {
        renamingSubtaskID = nil
        renamingSubtaskParentID = nil
        subtaskRenameFailed = false
    }

    /// Delete on a subtask: to Recently Deleted, one step with an Undo
    /// toast. Returns the outcome (a failure shows under the parent).
    @discardableResult
    func deleteSubtask(_ id: UUID) -> CommandOutcome {
        guard let task = store.task(withID: id), task.parentID != nil else { return .failed(.taskGone) }
        let title = task.title
        let outcome = library.deleteTasks([id])
        guard outcome.isApplied else { return outcome }
        if renamingSubtaskID == id { cancelSubtaskRename() }
        showToast(String(localized: "Deleted “\(title)”"))
        return outcome
    }

    /// ⌘↑ ⌘↓ on a subtask: one place among its siblings in the same state,
    /// as one step. The open quick look shows the new order at once.
    @discardableResult
    func moveSubtask(_ id: UUID, by offset: Int) -> CommandOutcome {
        guard let task = store.task(withID: id), let parentID = task.parentID else { return .failed(.taskGone) }
        let siblings = store.subtasks(of: parentID).filter { ($0.status == .done) == (task.status == .done) }
        guard let index = siblings.firstIndex(where: { $0.id == id }),
              siblings.indices.contains(index + offset) else { return .applied }
        // The quick look keeps its order while open (review 21); a move is
        // the person's own choice of order, so it shows: the library tells
        // the page (`subtaskOrderChanges`), as for its Undo and Redo.
        return library.moveSubtask(id, by: offset)
    }

    func reorderSubtask(_ id: UUID, toGroupIndex destination: Int, group: [UUID]) -> CommandOutcome {
        guard let task = store.task(withID: id), let parent = task.parentID else { return .failed(.taskGone) }
        let siblings = quickLookSubtasks(of: parent, store.subtasks(of: parent))
            .filter { ($0.status == .done) == (task.status == .done) }.map(\.id)
        guard group == siblings, let start = siblings.firstIndex(of: id), siblings.indices.contains(destination) else {
            return .applied // The family changed during the drag: settle back.
        }
        return moveSubtask(id, by: destination - start)
    }

    /// The subtasks a quick look's keys and menu act on, in the order it
    /// shows them.
    func quickLookSubtaskIDs(of parentID: UUID) -> [UUID] {
        quickLookSubtasks(of: parentID, store.subtasks(of: parentID)).map(\.id)
    }
}
