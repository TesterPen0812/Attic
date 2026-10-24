import SwiftUI

/// The Phase 1 follow-up (control audit item 5): a subtask moved to another
/// task, or made a task of its own, from the quick look. Each is one step in
/// the Tasks history with an Undo toast; the menus, the keys and VoiceOver
/// all call these.
extension TasksPageModel {
    /// Move to Task…'s list: every unfinished main task in Now and Later
    /// except the subtask's own, in list order, each with where it is.
    /// Grouped under Now, then Later (Dropdown content: answers, owner,
    /// 2026-10-24, sheet 3), each group in the store's order.
    func moveChoices(forSubtask id: UUID) -> [AtticTaskPicker.Choice] {
        let targets = store.moveTargets(forSubtask: id)
        let now = targets.filter { $0.status != .backlog }, later = targets.filter { $0.status == .backlog }
        return now.map { AtticTaskPicker.Choice(id: $0.id, title: $0.title, group: String(localized: "Now")) }
            + later.map { AtticTaskPicker.Choice(id: $0.id, title: $0.title, group: String(localized: "Later")) }
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
