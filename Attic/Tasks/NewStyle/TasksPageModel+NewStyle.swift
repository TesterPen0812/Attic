import Foundation

/// Where ⌘N, the quick-entry hotkey and a click below the list send the
/// keyboard. New has one way to add a task: the add bar (FINAL § 2.12).
enum TasksCaptureTarget: Equatable {
    case addBar
    /// The Reminders replica's new-reminder row.
    case replicaRow
}

extension TasksPageModel {
    // MARK: Capture (§ 2.12)

    /// ⌘N, the hotkey or a click below the rows. In New the add bar takes
    /// the keyboard with its draft as it was (a failed save kept it); the
    /// replica opens its new-reminder row; Attic's own routes are its own.
    @discardableResult
    func beginCapture() -> TasksCaptureTarget {
        if listStyle.isReplica {
            beginReplicaRow()
            return .replicaRow
        }
        if listStyle.isNew {
            clearSelection()
            newAddBarRequest &+= 1
        }
        return .addBar
    }

    // MARK: The column that takes turns

    /// A ticked row kept in its place (4A) until the panel closes or the
    /// list changes.
    func isKeptDone(_ id: UUID) -> Bool {
        held[id] != nil && store.listedTask(withID: id)?.status == .done
    }

    /// What a New row's column shows.
    func newColumn(for id: UUID, isHovered: Bool, isKeyboardSelected: Bool) -> TasksNewColumn {
        let task = store.listedTask(withID: id)
        return TasksNewColumn.resolve(isDone: task?.status == .done, isKept: isKeptDone(id), isHovered: isHovered,
                                      isKeyboardSelected: isKeyboardSelected, hasDate: task?.dueDay != nil,
                                      actionsAvailable: tab != .done)
    }

    /// A New row's short date (§ 2.4).
    func newDate(for id: UUID) -> (text: String, tone: TasksNewText.Tone)? {
        guard let day = store.listedTask(withID: id)?.dueDay ?? doneLogTasks.first(where: { $0.id == id })?.dueDay else { return nil }
        return TasksNewText.shortDate(day, today: DueDay(date: services.now(), calendar: services.calendar()),
                                      calendar: services.calendar(), locale: services.locale)
    }

    /// Undo in a kept row's column: the tick is taken back (as a click on
    /// the ring again or ⌘Z).
    @discardableResult
    func undoKeptTick(_ id: UUID) -> CommandOutcome {
        guard isKeptDone(id) else { return .failed(.taskGone) }
        return toggleDone(id)
    }

    // MARK: Single keys (6B)

    /// Space, L and 1–3 on the selected task (D and T open the pickers, in
    /// the page). Each is one undoable step through the write gate.
    func newKey(_ key: TasksNewKey, on ids: [UUID]) -> CommandOutcome? {
        guard listStyle.isNew, tab != .done, !ids.isEmpty else { return nil }
        switch key {
        case .complete:
            return toggleDone(ids)
        case .move:
            return tab == .backlog ? moveToNow(ids) : moveToBacklog(ids)
        case let .priority(level):
            let current = ids.count == 1 ? store.listedTask(withID: ids[0])?.priority ?? .none : .none
            return setPriority(TasksNewKey.priority(level, current: current), for: ids)
        case .date, .tags:
            return nil
        }
    }

    // MARK: Tab and ⇧Tab (§ 2.14)

    /// Tab makes the selected task a subtask of the task above it (one
    /// level, Attic's nesting rules: `TaskStore.nestTask`); ⇧Tab makes a
    /// subtask a task again (Make Standalone Task). A refusal says why.
    func newIndent(_ command: RemindersReplicaIndent, row: UUID?, above: UUID?) -> ReplicaIndentResult? {
        guard listStyle.isNew, tab != .done else { return nil }
        if let subtask = focusedSubtaskID, store.task(withID: subtask)?.parentID != nil {
            switch command {
            case .outdent: return .done(makeStandalone(subtask))
            case .indent: return .done(.applied)
            }
        }
        guard let row, let task = store.task(withID: row) else { return nil }
        switch command {
        case .outdent:
            if task.parentID != nil { return .done(makeStandalone(row)) }
            return .done(.applied)
        case .indent:
            guard let above, above != row else {
                let reason = String(localized: "There's no task above to put it under.")
                showToast(reason)
                return .refused(reason)
            }
            let outcome = library.indentTask(row, under: above)
            if outcome.isApplied {
                setExpanded(above, true)
                selectOnly(above)
            }
            return .done(report(outcome, on: row) { [weak self] in self?.library.indentTask(row, under: above) ?? .failed(.taskGone) })
        }
    }

    // MARK: Honest states (§ 2.16)

    /// What an empty list says: "Nothing in Now" is not the same as a
    /// list whose filters or Find hide everything.
    enum NewEmptyState: Equatable {
        case nothing(TasksTab)
        case noMatches
    }

    func newEmptyState(for tab: TasksTab) -> NewEmptyState? {
        guard rows(for: tab).isEmpty else { return nil }
        return narrows(tab) ? .noMatches : .nothing(tab)
    }
}
