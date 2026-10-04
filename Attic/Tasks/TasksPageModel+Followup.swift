import SwiftUI

/// The Phase 1 follow-up (control audit item 5): a subtask moved to another
/// task, or made a task of its own, from the quick look. Each is one step in
/// the Tasks history with an Undo toast; the menus, the keys and VoiceOver
/// all call these.
extension TasksPageModel {
    /// Move to Task…'s list: every unfinished main task in Now and Later
    /// except the subtask's own, in list order, each with where it is.
    func moveChoices(forSubtask id: UUID) -> [AtticTaskPicker.Choice] {
        store.moveTargets(forSubtask: id).map { task in
            AtticTaskPicker.Choice(
                id: task.id,
                title: task.title,
                detail: task.status == .backlog ? String(localized: "Later") : String(localized: "Now")
            )
        }
    }

    /// Chosen in Move to Task…: the subtask goes to the end of that task's
    /// subtasks. The toast names where it went, with Undo.
    @discardableResult
    func moveSubtask(_ id: UUID, toTask parentID: UUID) -> CommandOutcome {
        guard let task = store.task(withID: id), task.parentID != nil else { return .failed(.taskGone) }
        let destination = store.task(withID: parentID)?.title ?? ""
        let title = task.title
        if renamingSubtaskID == id { cancelSubtaskRename() }
        let outcome = library.moveSubtask(id, toTask: parentID)
        guard outcome.isApplied else { return outcome }
        showToast(String(localized: "Moved “\(title)” to “\(destination)”"))
        return outcome
    }

    /// Make Standalone Task: the subtask becomes a main task (see
    /// `TaskStore.reparentSubtask` for where), keeping its id and all it
    /// holds. It is selected and brought into view; the toast says so.
    @discardableResult
    func makeStandalone(_ id: UUID) -> CommandOutcome {
        guard let task = store.task(withID: id), task.parentID != nil else { return .failed(.taskGone) }
        let title = task.title
        if renamingSubtaskID == id { cancelSubtaskRename() }
        let outcome = library.moveSubtask(id, toTask: nil)
        guard outcome.isApplied else { return outcome }
        if focusedSubtaskID == id { focusedSubtaskID = nil }
        selectOnly(id)
        addedRequest = ScrollRequest(id: id)
        let listed = store.task(withID: id)?.status == .backlog ? String(localized: "Later") : String(localized: "Now")
        showToast(String(localized: "“\(title)” is now a task in \(listed)"))
        return outcome
    }
}
