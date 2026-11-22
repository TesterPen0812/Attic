import Foundation
import Observation

/// What a task row's cell shows of the page's state (design note
/// `tasks-breadth.md`, slice 1b): its row as the tab's list holds it and
/// the page's state for it. A cell observes its own row's state, not every
/// change to the page's model, so a change runs the cells of the rows it
/// changed and no other.
///
/// The model works the value out in one place
/// (`TasksPageModel.derivedRowState`); every writer and the DEBUG oracle
/// call it, and no writer sets a field by hand.
struct TasksRowStateValue: Equatable {
    /// The row as its tab's list was last built (`TasksPageModel.keep`),
    /// brought up by `TasksPageModel.syncRowStates`.
    var row: TasksListRow
    var isSelected: Bool
    var run: AtticSelectionRun
    /// Its quick look is open (never on a done row).
    var isExpanded: Bool
    /// Its title editor is open (the cell opens it only on the active page).
    var isEditingTitle: Bool
    /// The page's keyboard focus is on this row of this tab (the model's
    /// copy, `TasksPageModel.keyboardFocus`); the cell draws the ring only
    /// on the active page.
    var isFocused: Bool
    var failure: TasksRowFailureState
    /// Done's details are open under it (Done's rows only).
    var isDoneDetailOpen: Bool
    var subtaskEditing: TasksRowSubtaskEditing

    static func == (lhs: Self, rhs: Self) -> Bool {
        Self.sameRow(lhs.row, rhs.row) && lhs.isSelected == rhs.isSelected && lhs.run == rhs.run
            && lhs.isExpanded == rhs.isExpanded && lhs.isEditingTitle == rhs.isEditingTitle
            && lhs.isFocused == rhs.isFocused && lhs.failure == rhs.failure
            && lhs.isDoneDetailOpen == rhs.isDoneDetailOpen && lhs.subtaskEditing == rhs.subtaskEditing
    }

    /// `TasksListRow.==` leaves out parts of the row's model (the due
    /// date's tone, whether it shows): the model is compared whole, as
    /// `TasksCellKey` does.
    static func sameRow(_ lhs: TasksListRow, _ rhs: TasksListRow) -> Bool {
        lhs == rhs && lhs.model == rhs.model
    }

    /// The fields that differ, by name (the oracle's report).
    func differences(from other: Self) -> [String] {
        var fields: [String] = []
        if !Self.sameRow(row, other.row) { fields.append("row") }
        if isSelected != other.isSelected { fields.append("isSelected") }
        if run != other.run { fields.append("run") }
        if isExpanded != other.isExpanded { fields.append("isExpanded") }
        if isEditingTitle != other.isEditingTitle { fields.append("isEditingTitle") }
        if isFocused != other.isFocused { fields.append("isFocused") }
        if failure != other.failure { fields.append("failure") }
        if isDoneDetailOpen != other.isDoneDetailOpen { fields.append("isDoneDetailOpen") }
        if subtaskEditing != other.subtaskEditing { fields.append("subtaskEditing") }
        return fields
    }
}

/// The "Not saved" lines under a row: its title, its new subtask, or a
/// row command (`TasksPageModel.rowFailure`).
struct TasksRowFailureState: Equatable {
    var titleNotSaved = false
    var newSubtaskNotSaved = false
    var row: TasksPageModel.RowFailure?
}

/// The row's quick look editors: a new subtask, a subtask renamed in place.
struct TasksRowSubtaskEditing: Equatable {
    /// `newSubtaskParentID` is this row.
    var isNewSubtaskParent = false
    /// `renamingSubtaskParentID` is this row.
    var isRenameParent = false
    /// The subtask being renamed, when it is one of this row's.
    var renamingID: UUID?
    /// That rename's save failed.
    var renameFailed = false
}

/// One row's state on one tab, kept by `TasksPageModel` while the row is in
/// its tab's list. Each field is stored apart, so a cell's body is run again
/// only by the fields it read that changed; a write that changes nothing
/// notifies nobody (`apply` compares first, whatever the macro does).
///
/// A cell on a page kept built but not drawn reads `value`, the untracked
/// mirror, and its state is frozen: writes reach only the mirror, so a
/// cell that observed the fields while drawn is not run while it is hidden.
/// Drawn again, the page's pass thaws the state (the fields catch up with
/// the mirror) and the cell, whose `drawn` input changed, reads them.
@MainActor @Observable
final class TasksRowState {
    let id: UUID
    let tab: TasksTab

    private(set) var row: TasksListRow
    private(set) var isSelected: Bool
    private(set) var run: AtticSelectionRun
    private(set) var isExpanded: Bool
    private(set) var isEditingTitle: Bool
    private(set) var isFocused: Bool
    private(set) var failure: TasksRowFailureState
    private(set) var isDoneDetailOpen: Bool
    private(set) var subtaskEditing: TasksRowSubtaskEditing

    /// The same values, read without being observed.
    @ObservationIgnored private(set) var value: TasksRowStateValue
    /// Its cell's page is kept built but not drawn: the fields wait.
    @ObservationIgnored private(set) var isFrozen = false

    init(id: UUID, tab: TasksTab, value: TasksRowStateValue) {
        self.id = id
        self.tab = tab
        self.value = value
        row = value.row
        isSelected = value.isSelected
        run = value.run
        isExpanded = value.isExpanded
        isEditingTitle = value.isEditingTitle
        isFocused = value.isFocused
        failure = value.failure
        isDoneDetailOpen = value.isDoneDetailOpen
        subtaskEditing = value.subtaskEditing
    }

    /// The values, observed (a drawn cell) or not (a cell kept built but not
    /// drawn).
    func read(drawn: Bool) -> TasksRowStateValue {
        guard drawn else { return value }
        return TasksRowStateValue(row: row, isSelected: isSelected, run: run, isExpanded: isExpanded,
                                  isEditingTitle: isEditingTitle, isFocused: isFocused, failure: failure,
                                  isDoneDetailOpen: isDoneDetailOpen, subtaskEditing: subtaskEditing)
    }

    /// Writes the fields that changed, and only those (only the mirror
    /// while frozen). Called only with `TasksPageModel.derivedRowState`'s
    /// value.
    func apply(_ new: TasksRowStateValue) {
        guard new != value else { return }
        #if DEBUG
        TasksRowStateCounts.noteWrite()
        #endif
        value = new
        if !isFrozen { writeFields(new) }
    }

    /// The page's pass that builds the cell says whether it is drawn: a
    /// hidden page's state freezes; drawn again, it catches up.
    func setDrawn(_ drawn: Bool) {
        if drawn {
            guard isFrozen else { return }
            #if DEBUG
            TasksRowStateCounts.noteWrite()
            #endif
            isFrozen = false
            writeFields(value)
        } else {
            isFrozen = true
        }
    }

    private func writeFields(_ new: TasksRowStateValue) {
        if !TasksRowStateValue.sameRow(row, new.row) { row = new.row }
        if isSelected != new.isSelected { isSelected = new.isSelected }
        if run != new.run { run = new.run }
        if isExpanded != new.isExpanded { isExpanded = new.isExpanded }
        if isEditingTitle != new.isEditingTitle { isEditingTitle = new.isEditingTitle }
        if isFocused != new.isFocused { isFocused = new.isFocused }
        if failure != new.failure { failure = new.failure }
        if isDoneDetailOpen != new.isDoneDetailOpen { isDoneDetailOpen = new.isDoneDetailOpen }
        if subtaskEditing != new.subtaskEditing { subtaskEditing = new.subtaskEditing }
    }
}

#if DEBUG
/// PR 48 round 3's two guards, both held at zero by the hosted tests.
@MainActor enum TasksRowStateCounts {
    /// Row-state writes made while a list read (`TasksPageModel.cached`,
    /// `doneDays`) was running. A read can run inside a view update, and a
    /// write to an observed field there aborts it ("setting value during
    /// update"): the read path writes none.
    static var writesDuringListRead = 0
    /// Catch-ups that came after a drawn cell had read its tab's states
    /// behind their list: a change no funnel announced before the frame.
    static var lateCatchUps = 0
    /// The list reads running now (`cached`, `doneDays`).
    static var listReadDepth = 0

    static func noteWrite() {
        if listReadDepth > 0 { writesDuringListRead += 1 }
    }

    static func reset() {
        writesDuringListRead = 0
        lateCatchUps = 0
    }
}

/// The DEBUG oracle's report (slice 1b): after a settle, every live row
/// state equals a fresh derivation from the model, and every drawn cell
/// holds its row's current state. A difference names the row and the field.
///
/// The unit test host points `report` at the running test
/// (`InvisibleHostObserver`); an app the UI-test targets launch with
/// `ATTIC_ROW_STATE_ORACLE=1` stops on the first difference, so the UI test
/// fails. Nothing else sets it: timed on-screen runs, probes and previews
/// (`ATTIC_UI_TESTING=1` alone, Local builds with DEBUG) check nothing.
@MainActor enum TasksRowStateOracle {
    static var report: ((String) -> Void)? = ProcessInfo.processInfo.environment["ATTIC_ROW_STATE_ORACLE"] == "1"
        ? { message in fatalError("Row state oracle: \(message)") }
        : nil

    /// Checks run after each settle while someone listens.
    static var isOn: Bool { report != nil }
}
#endif
