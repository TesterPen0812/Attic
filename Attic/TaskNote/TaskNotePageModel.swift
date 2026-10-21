import AppKit
import Combine
import SwiftUI

/// A task's own note, the page (UX plan § 2.2, mockups `p3-20` 2b and
/// `p3-21`): the live task head, the "Subtasks · n/m" block and the note's
/// writing in one scroll. This model owns the head's and the block's state;
/// the writing is the workspace session's engine (`TaskNoteComposedHost`).
///
/// Every task change goes through the command library into the workspace's
/// one history (S11), so ⌘Z in the page walks the head, the block and the
/// writing in the order they happened. Opening, folding, ticking, adding,
/// renaming and reordering never create a note (§ 2.1).
@MainActor
final class TaskNotePageModel: ObservableObject {
    /// The head as it reads: the task's live fields.
    struct Head: Equatable {
        var title: String
        var state: AtticTaskState
        var priority: AtticPriority
        var due: AtticTaskRowModel.Due?
        var tags: [String]
        var subtasks: (done: Int, total: Int)
        var exists: Bool

        static func == (lhs: Head, rhs: Head) -> Bool {
            lhs.title == rhs.title && lhs.state == rhs.state && lhs.priority == rhs.priority
                && lhs.due == rhs.due && lhs.tags == rhs.tags && lhs.subtasks == rhs.subtasks
                && lhs.exists == rhs.exists
        }
    }

    struct Row: Identifiable, Equatable {
        let id: UUID
        var title: String
        var isDone: Bool
    }

    /// The page's regions in Tab order without Full Keyboard Access (§ 7):
    /// title → the subtask list (one stop) → Add subtask → writing.
    enum Region: Hashable { case title, list, add, writing }

    /// A task command that changed nothing (§ 5.6: the control springs back
    /// and the status slot says so, with Retry when it can help).
    struct Failure: Equatable {
        let id = UUID()
        let message: String
        let canRetry: Bool
        static func == (lhs: Failure, rhs: Failure) -> Bool { lhs.id == rhs.id }
    }

    let taskID: UUID
    let store: TaskStore
    let library: AtticLibrary
    /// The workspace's one history (the registry session's).
    let history: WorkspaceHistory
    let parser: TaskTextParser
    private let defaults: UserDefaults?
    private let calendar: Calendar
    private let locale: Locale

    @Published private(set) var head: Head
    @Published private(set) var rows: [Row] = []
    @Published private(set) var isFolded: Bool
    /// The row the list's ring is on (arrows move it).
    @Published var focusedRowID: UUID?
    @Published private(set) var renamingID: UUID?
    /// The rename field's draft (plain text: its pieces are never parsed).
    @Published var renameEdit = TaskAddBarText()
    var renameText: String {
        get { renameEdit.text }
        set { renameEdit.text = newValue }
    }
    /// Each open field owns its draft history and its `WorkspaceFieldUndo`
    /// for the whole edit (review P2-2): ⌘Z inside the field walks the
    /// draft; a successful commit, a cancel or a fold retires both; a
    /// refused commit keeps both, with the typed text.
    private(set) var renameHistory = TaskDraftHistory()
    private var renameField: WorkspaceFieldUndo?
    private var renameBase: String?
    private var renameConflictID: UUID?
    private(set) var titleHistory = TaskDraftHistory()
    private var titleField: WorkspaceFieldUndo?
    private var titleConflictID: UUID?
    private var titleBase: (title: String, priority: TaskPriority, dueDay: DueDay?)?
    /// The title editor's whole selection (its draft history only).
    var titleEditSelection: NSRange?
    /// Reduce Motion: the held rows settle at once (review P2-4).
    var reduceMotion = false
    @Published var newSubtaskText = ""
    @Published private(set) var isEditingTitle = false {
        didSet { if isEditingTitle != oldValue { onGeometryChange?() } }
    }
    @Published var titleEdit = TaskAddBarText()
    @Published var titleEditCaret: Int?
    @Published private(set) var failure: Failure?
    /// A region asked to take the keyboard; `focusRequestCount` changes
    /// with every request so asking twice for the same region still works.
    @Published private(set) var focusRequest: Region?
    @Published private(set) var focusRequestCount: UInt64 = 0

    /// The writing takes the keyboard (the host makes the text view first
    /// responder; `atTop` puts the caret at the start of the writing).
    var onFocusWriting: ((_ atTop: Bool) -> Void)?
    /// The head's or the block's height may have changed (the host restacks).
    var onGeometryChange: (() -> Void)?
    private var retry: (() -> Void)?

    // MARK: Held order (§ 2.3.1)

    /// The order the block had when the interaction began, kept while focus
    /// or the pointer is inside it. Nil when not in use: canonical order.
    private(set) var heldOrder: [UUID]?
    private var focusInside = false
    private var pointerInside = false
    var isInUse: Bool { focusInside || pointerInside }
    /// The last row that had the keyboard (⌃⇧Tab from the writing returns
    /// to it, else to Add subtask).
    private(set) var lastFocusedRowID: UUID?

    private var observations: Set<AnyCancellable> = []

    init(taskID: UUID, store: TaskStore, library: AtticLibrary, history: WorkspaceHistory,
         defaults: UserDefaults? = .standard, parser: TaskTextParser = TaskTextParser(),
         calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.taskID = taskID
        self.store = store
        self.library = library
        self.history = history
        self.defaults = defaults
        self.parser = parser
        self.calendar = calendar
        self.locale = locale
        head = Head(title: "", state: .todo, priority: .none, due: nil, tags: [], subtasks: (0, 0), exists: false)
        isFolded = false
        let canonical = store.subtasks(of: taskID)
        // P3: folded when there are more than 6 open subtasks, until the
        // person folds or unfolds it themselves (remembered per task).
        if let remembered = defaults?.object(forKey: Self.foldKey(taskID)) as? Bool {
            isFolded = remembered
        } else {
            isFolded = canonical.filter { $0.status != .done }.count > 6
        }
        refresh()
        observeStore()
    }

    private func observeStore() {
        guard observations.isEmpty else { return }
        // Only this task's family touches the page (§ 9: a task change
        // touches only its row, cards, head and block).
        store.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &observations)
        library.subtaskOrderChanges.filter { [taskID] in $0 == taskID }.sink { [weak self] _ in
            // A deliberate reorder (or its Undo) shows at once (round 10b).
            guard let self else { return }
            self.heldOrder = nil
            DispatchQueue.main.async { self.refresh(animated: true) }
        }.store(in: &observations)
    }

    func resume() {
        refresh()
        observeStore()
    }

    func suspend() {
        observations.removeAll()
        focusInside = false
        pointerInside = false
        heldOrder = nil
        onGeometryChange = nil
        onFocusWriting = nil
    }

    static func foldKey(_ id: UUID) -> String { "AtticTaskNote.folded.\(id.uuidString)" }

    var historyID: UndoHistoryID { history.historyID }

    // MARK: Reading the store

    /// Re-reads the task and its subtasks. Publishes only what changed.
    func refresh(animated: Bool = false) {
        let task = store.task(withID: taskID)
        let canonical = store.subtasks(of: taskID)
        let done = canonical.filter { $0.status == .done }.count
        var next = Head(title: task?.title ?? head.title,
                        state: task.map { TaskRowPresentation.state($0.status) } ?? head.state,
                        priority: task.map { TaskRowPresentation.priority($0.priority) } ?? head.priority,
                        due: nil, tags: task?.tags ?? head.tags,
                        subtasks: (done, canonical.count), exists: task != nil)
        if let day = task?.dueDay {
            let today = DueDay(date: parser.now(), calendar: calendar)
            next.due = TaskRowPresentation.due(day, today: today, calendar: calendar, locale: locale)
        }
        var shown = canonical
        if var order = heldOrder {
            // Held insertion: rows that arrived while the block is in use go
            // to the end of the held list, below any completed rows, so
            // nothing on screen moves.
            let byID = Dictionary(canonical.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let known = order.compactMap { byID[$0] }
            let arrivals = canonical.filter { !order.contains($0.id) }
            order = known.map(\.id) + arrivals.map(\.id)
            heldOrder = order
            shown = known + arrivals
        }
        let nextRows = shown.map { Row(id: $0.id, title: $0.title, isDone: $0.status == .done) }
        let changed = next != head || nextRows != rows
        guard changed else { return }
        let apply = {
            if next != self.head { self.head = next }
            if nextRows != self.rows { self.rows = nextRows }
        }
        if animated, !reduceMotion {
            withAnimation(AtticMotionPreset.expand.animation(reduceMotion: false)) { apply() }
        } else {
            apply()
        }
        if let id = focusedRowID, !nextRows.contains(where: { $0.id == id }) { focusedRowID = nil }
        onGeometryChange?()
    }

    /// The block's height: the 28 pt header; unfolded, a 28 pt line per row,
    /// Add subtask and the bottom padding (`TaskNoteSubtasksBlock`).
    var blockHeight: CGFloat {
        let header = TaskNoteMetrics.blockHeader
        guard !isFolded else { return header }
        return header + CGFloat(rows.count + 1) * TaskNoteMetrics.rowHeight + TaskNoteMetrics.blockBottomPadding
    }

    var countLabel: String {
        head.subtasks.total == 0 ? String(localized: "Subtasks")
            : String(localized: "Subtasks · \(head.subtasks.done)/\(head.subtasks.total)")
    }

    // MARK: In use (held order)

    func setFocusInside(_ inside: Bool) {
        guard focusInside != inside else { return }
        focusInside = inside
        updateHold()
    }

    func setPointerInside(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        updateHold()
    }

    private func updateHold() {
        if isInUse {
            if heldOrder == nil { heldOrder = rows.map(\.id) }
        } else {
            releaseHold()
        }
    }

    /// Focus and the pointer have both left, the block folded or the page
    /// closed: rows settle into canonical order with the 220 ms move.
    func releaseHold() {
        guard heldOrder != nil else { return }
        heldOrder = nil
        refresh(animated: true)
    }

    // MARK: Fold (presentation state only: no history, no revision)

    func toggleFold(undoManager: UndoManager? = nil) { setFolded(!isFolded) }

    func setFolded(_ folded: Bool) {
        guard folded != isFolded else { return }
        isFolded = folded
        defaults?.set(folded, forKey: Self.foldKey(taskID))
        if folded {
            focusInside = false
            releaseHold()
            // Folding cancels an open rename and retires its field Undo.
            if renamingID != nil { cancelRename() }
        }
        onGeometryChange?()
    }

    // MARK: Subtask commands

    @discardableResult
    func toggle(_ id: UUID) -> Bool {
        guard let task = store.task(withID: id) else { return report(.taskGone) }
        let next: TaskStatus = task.status == .done ? .todo : .done
        let outcome = library.updateTask(id, status: next, in: historyID)
        return settle(outcome) { [weak self] in self?.toggle(id) }
    }

    /// Return in Add subtask: adds the subtask and keeps the field ready.
    /// An empty Return leaves the list and puts the caret at the top of the
    /// writing. Titles are plain text (shorthand is not parsed).
    @discardableResult
    func commitNewSubtask() -> Bool {
        let title = TaskDraftBuilder.collapsed(newSubtaskText)
        guard !title.isEmpty else {
            newSubtaskText = ""
            focusWriting(atTop: true)
            return true
        }
        let created = library.createTasks([TaskDraft(title: title, status: .todo, parentID: taskID)], in: historyID)
        guard created != nil else {
            return report(library.lastFailure ?? CommandFailure(String(localized: "Couldn't add the subtask"))) { [weak self] in
                self?.commitNewSubtask()
            }
        }
        clearFailure()
        newSubtaskText = ""
        refresh()
        return true
    }

    func beginRename(_ id: UUID, undoManager: UndoManager? = nil) {
        guard rows.contains(where: { $0.id == id }), let task = store.task(withID: id) else { return }
        if renamingID != nil, renamingID != id { cancelRename() }
        guard renamingID != id else { return }
        renameBase = task.title
        renameEdit = TaskAddBarText(text: task.title)
        renameHistory.reset()
        renameField = WorkspaceFieldUndo(manager: undoManager ?? UndoManager())
        renamingID = id
    }

    /// The rename field replaced `range` with `replacement` (a draft step).
    func renameEdited(_ range: NSRange, replacement: String) {
        renameHistory.willEdit(renameEdit, selection: nil, range: range, replacement: replacement)
        renameEdit.edited(range, replacement: replacement)
    }

    func undoRenameDraft() -> (text: String, selection: NSRange)? {
        guard let entry = renameHistory.undo(current: renameEdit, selection: nil) else { return nil }
        renameEdit = entry.text
        return (entry.text.text, entry.selection)
    }

    func redoRenameDraft() -> (text: String, selection: NSRange)? {
        guard let entry = renameHistory.redo(current: renameEdit, selection: nil) else { return nil }
        renameEdit = entry.text
        return (entry.text.text, entry.selection)
    }

    /// Return saves the rename as one step in the workspace history; the
    /// field's own Undo retires with it (round 1's `WorkspaceFieldUndo`).
    @discardableResult
    func commitRename() -> Bool {
        guard let id = renamingID else { return true }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let task = store.task(withID: id), !title.isEmpty, title != task.title, title != renameBase else {
            cancelRename()
            return true
        }
        guard task.title == renameBase else {
            report(CommandFailure(String(localized: "This subtask changed elsewhere. Your rename draft is kept; press Esc to keep the newer title.")))
            renameConflictID = failure?.id
            return false
        }
        let outcome = fieldCommit(renameField) { [library, historyID] in
            library.updateTask(id, title: title, in: historyID)
        }
        // Refused: the field, its text and its draft Undo stay.
        guard outcome.isApplied else {
            return settle(outcome) { [weak self] in _ = self?.commitRename() }
        }
        clearFailure()
        renameHistory.reset()
        renameField = nil
        renameBase = nil
        renamingID = nil
        return true
    }

    func cancelRename() {
        if let renameConflictID, failure?.id == renameConflictID { clearFailure() }
        renameConflictID = nil
        renameField?.cancel()
        renameField = nil
        renameHistory.reset()
        renameBase = nil
        renamingID = nil
    }

    /// ⌘↑ ⌘↓: one place within the row's state group, as one step.
    @discardableResult
    func move(_ id: UUID, by offset: Int) -> Bool {
        guard let task = store.task(withID: id), task.parentID == taskID else { return report(.taskGone) }
        let group = store.subtasks(of: taskID).filter { ($0.status == .done) == (task.status == .done) }
        // A tick holds the visible row still, even though its new state
        // group is already sorted differently in the store. Move relative
        // to the visible neighbour, not the canonical row's old index.
        let shown = rows.filter { $0.isDone == (task.status == .done) }
        guard let index = shown.firstIndex(where: { $0.id == id }), shown.indices.contains(index + offset),
              let canonicalIndex = group.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let neighbour = shown[index + offset].id
        let withoutMovingRow = group.filter { $0.id != id }
        guard let neighbourIndex = withoutMovingRow.firstIndex(where: { $0.id == neighbour }) else { return false }
        let destination = neighbourIndex + (offset > 0 ? 1 : 0)
        return settle(library.moveSubtask(id, by: destination - canonicalIndex, in: historyID)) { [weak self] in self?.move(id, by: offset) }
    }

    /// ⌫: to Recently Deleted, one step (Undo brings it back).
    @discardableResult
    func delete(_ id: UUID) -> Bool {
        let index = rows.firstIndex(where: { $0.id == id })
        let applied = settle(library.deleteTasks([id], in: historyID)) { [weak self] in self?.delete(id) }
        if applied, focusedRowID == id {
            let remaining = rows.filter { $0.id != id }
            focusedRowID = index.flatMap { remaining.indices.contains($0) ? remaining[$0].id : remaining.last?.id }
        }
        return applied
    }

    /// The head's status circle: done, or back from done.
    @discardableResult
    func toggleTask() -> Bool {
        guard let task = store.task(withID: taskID) else { return report(.taskGone) }
        let next: TaskStatus = task.status == .done ? .todo : .done
        return settle(library.updateTask(taskID, status: next, in: historyID)) { [weak self] in self?.toggleTask() }
    }

    // MARK: The head's title (Tasks' title editor and its shorthand)

    func beginEditingTitle(undoManager: UndoManager? = nil) {
        guard let task = store.task(withID: taskID), !isEditingTitle else { return }
        titleBase = (task.title, task.priority, task.dueDay)
        titleHistory.reset()
        titleField = WorkspaceFieldUndo(manager: undoManager ?? UndoManager())
        titleEditSelection = nil
        var edit = TaskAddBarText(text: task.title)
        // Words already in the title stay words: only shorthand typed now
        // applies.
        edit.dismissAllRecognised(parser: parser)
        titleEdit = edit
        titleEditCaret = nil
        isEditingTitle = true
    }

    /// The title field replaced `range` with `replacement` (a draft step).
    func titleEdited(_ range: NSRange, replacement: String) {
        titleHistory.willEdit(titleEdit, selection: TaskDraftHistory.selection(titleEditSelection, caret: titleEditCaret),
                              range: range, replacement: replacement)
        titleEdit.edited(range, replacement: replacement)
    }

    func dismissTitleChip(_ range: NSRange) {
        titleHistory.checkpoint(titleEdit, selection: TaskDraftHistory.selection(titleEditSelection, caret: titleEditCaret))
        titleEdit.dismiss(range)
    }

    func undoTitleDraft() -> (text: String, selection: NSRange)? {
        guard let entry = titleHistory.undo(current: titleEdit, selection: TaskDraftHistory.selection(titleEditSelection, caret: titleEditCaret))
        else { return nil }
        applyTitleDraft(entry)
        return (entry.text.text, entry.selection)
    }

    func redoTitleDraft() -> (text: String, selection: NSRange)? {
        guard let entry = titleHistory.redo(current: titleEdit, selection: TaskDraftHistory.selection(titleEditSelection, caret: titleEditCaret))
        else { return nil }
        applyTitleDraft(entry)
        return (entry.text.text, entry.selection)
    }

    private func applyTitleDraft(_ entry: TaskDraftHistory.Entry) {
        titleEdit = entry.text
        titleEditCaret = entry.selection.location
        titleEditSelection = entry.selection
    }

    /// ⌘Z past a field's own draft: the workspace's history.
    func undoWorkspace() { _ = library.undo.undo(in: historyID) }
    func redoWorkspace() { _ = library.undo.redo(in: historyID) }

    /// Return commits and moves the keyboard to the block (§ 7).
    @discardableResult
    func commitTitle() -> Bool {
        guard isEditingTitle else { return true }
        guard let task = store.task(withID: taskID) else { return report(.taskGone) }
        let parts = titleEdit.parts(parser: parser)
        let title = TaskDraftBuilder.collapsed(parts.title)
        let tags = AtticTag.normalizedSet(task.tags + parts.tags)
        let editsTitle = !title.isEmpty && title != titleBase?.title
        guard (!editsTitle || task.title == titleBase?.title || title == task.title),
              (parts.priority == nil || task.priority == titleBase?.priority || parts.priority == task.priority),
              (parts.dueDay == nil || task.dueDay == titleBase?.dueDay || parts.dueDay == task.dueDay) else {
            report(CommandFailure(String(localized: "This task changed elsewhere. Your title draft is kept; press Esc to keep the newer values.")))
            titleConflictID = failure?.id
            return false
        }
        let newTitle: String? = editsTitle && title != task.title ? title : nil
        let newTags: [String]? = Set(tags.map { $0.lowercased() }) != Set(task.tags.map { $0.lowercased() }) ? tags : nil
        let newDay: DueDay?? = parts.dueDay.flatMap { $0 != task.dueDay ? .some($0) : nil }
        let newPriority: TaskPriority? = parts.priority.flatMap { $0 != task.priority ? $0 : nil }
        guard newTitle != nil || newTags != nil || newDay != nil || newPriority != nil else {
            cancelTitle()
            requestFocus(.list)
            return true
        }
        let outcome = fieldCommit(titleField) { [library, taskID, historyID] in
            library.updateTask(taskID, title: newTitle, priority: newPriority, tags: newTags, dueDay: newDay, in: historyID)
        }
        // Refused: the editor, its text and its draft Undo stay.
        guard outcome.isApplied else {
            return settle(outcome) { [weak self] in _ = self?.commitTitle() }
        }
        clearFailure()
        titleHistory.reset()
        titleField = nil
        titleBase = nil
        isEditingTitle = false
        requestFocus(.list)
        return true
    }

    func cancelTitle() {
        if let titleConflictID, failure?.id == titleConflictID { clearFailure() }
        titleConflictID = nil
        titleField?.cancel()
        titleField = nil
        titleHistory.reset()
        titleBase = nil
        isEditingTitle = false
    }

    /// Navigation commits native fields before relinquishing the workspace.
    /// Conflicts and save refusals keep the surface and its field Undo alive.
    func resolveFieldDrafts() -> Bool {
        guard commitTitle(), commitRename() else { return false }
        if !newSubtaskText.isEmpty, !commitNewSubtask() { return false }
        return true
    }

    // MARK: Focus routing (§ 7)

    func requestFocus(_ region: Region) {
        if region == .writing { focusWriting(atTop: false); return }
        if region == .list, rows.isEmpty || isFolded {
            requestFocus(isFolded ? .writing : .add)
            return
        }
        if region == .list { focusedRowID = listEntryRowID }
        focusRequest = region
        focusRequestCount &+= 1
    }

    func focusWriting(atTop: Bool) {
        focusRequest = .writing
        focusRequestCount &+= 1
        onFocusWriting?(atTop)
    }

    /// ⌃⇧Tab in the writing: the block's last focused row, else Add subtask.
    func focusBlockFromWriting() {
        if isFolded { setFolded(false) }
        if let id = lastFocusedRowID, rows.contains(where: { $0.id == id }) {
            focusedRowID = id
            requestFocus(.list)
        } else {
            requestFocus(.add)
        }
    }

    /// The row the list's one Tab stop lands on (review P2-5): the ring's
    /// row, else the last focused row, else the first.
    var listEntryRowID: UUID? {
        if let id = focusedRowID, rows.contains(where: { $0.id == id }) { return id }
        if let id = lastFocusedRowID, rows.contains(where: { $0.id == id }) { return id }
        return rows.first?.id
    }

    func noteRowFocused(_ id: UUID?) {
        if let id { lastFocusedRowID = id }
    }

    /// ↑↓ in the list: the ring moves, holding still at either end.
    func moveRing(by offset: Int) {
        guard !rows.isEmpty else { return }
        let index = focusedRowID.flatMap { id in rows.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : rows.count)
        let next = min(max(0, index + offset), rows.count - 1)
        focusedRowID = rows[next].id
        lastFocusedRowID = focusedRowID
    }

    // MARK: Failures (the Notes status slot; OD-4: no new Retry line)

    func retryFailure() {
        let action = retry
        clearFailure()
        action?()
    }

    func clearFailure() {
        failure = nil
        retry = nil
        titleConflictID = nil
        renameConflictID = nil
    }

    @discardableResult
    private func settle(_ outcome: CommandOutcome, retry: @escaping () -> Void) -> Bool {
        switch outcome {
        case .applied:
            clearFailure()
            // The control shows the store's truth at once (a refused tick
            // springs back).
            refresh()
            return true
        case let .failed(failure):
            refresh()
            return report(failure, retry: retry)
        }
    }

    @discardableResult
    private func report(_ failure: CommandFailure, retry: (() -> Void)? = nil) -> Bool {
        self.failure = Failure(message: failure.message, canRetry: failure.canRetry && retry != nil)
        self.retry = failure.canRetry ? retry : nil
        return false
    }

    /// A field's commit: the library's step goes into the workspace history
    /// as exactly one entry, and the field's own Undo targets retire.
    private func fieldCommit(_ owned: WorkspaceFieldUndo?, _ operation: @escaping () -> CommandOutcome) -> CommandOutcome {
        var outcome = CommandOutcome.failed(CommandFailure(String(localized: "Finish the change in progress first")))
        let field = owned ?? WorkspaceFieldUndo(manager: UndoManager())
        let recorded = field.commit(to: history) {
            library.undo.capturingSteps { outcome = operation() }.first
        }
        if !recorded, outcome.isApplied { field.cancel() }
        return outcome
    }
}
