import AppKit
import Combine
import SwiftUI
import SwiftData

/// A task's own note, the page (UX plan § 2.2, mockups `p3-20` 2b and
/// `p3-21`; owner's draft B, 2026-10-23): the live task head, the quiet
/// "Subtasks · n/m" label with the first three subtasks ("N more…" shows the
/// rest) and the note's writing in one scroll. This model owns the head's and the block's state;
/// the writing is the workspace session's engine (`TaskNoteComposedHost`).
///
/// Every task change goes through the command library into the workspace's
/// one history (S11), so ⌘Z in the page walks the head, the block and the
/// writing in the order they happened. Opening, expanding, ticking, adding,
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

    /// The page's regions in Tab order (§ 7): title → the subtask list (one
    /// stop) → Add subtask (when shown) → "N more…" / "Show less" (when
    /// shown) → writing.
    enum Region: Hashable { case title, list, add, more, writing }

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
    /// Draft B (owner, 2026-10-23): collapsed, the list shows its first
    /// three rows and "N more…"; expanded, every row, Add subtask and "Show
    /// less". Presentation state only, remembered per item.
    @Published private(set) var isExpanded: Bool
    /// The row the list's ring is on (arrows move it).
    @Published var focusedRowID: UUID?
    @Published private(set) var renamingID: UUID? {
        didSet { if renamingID == nil, history.hasPendingPublication { history.requestPublicationRetry() } }
    }
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
    @Published var newSubtaskText = "" {
        didSet { if newSubtaskText.isEmpty, history.hasPendingPublication { history.requestPublicationRetry() } }
    }
    @Published private(set) var isEditingTitle = false {
        didSet {
            if isEditingTitle != oldValue { onGeometryChange?() }
            if !isEditingTitle, history.hasPendingPublication { history.requestPublicationRetry() }
        }
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
    /// A native field of the page (a rename, Add subtask, the title) has
    /// marked text: an input method is composing in it.
    var isFieldComposing: (() -> Bool)?
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
        // Draft B: collapsed to three rows until the person expands it
        // (remembered per item; the old whole-block fold key is not read).
        isExpanded = defaults?.object(forKey: Self.expandKey(taskID)) as? Bool ?? false
        refresh()
        refreshEarlierFiles()
        observeStore()
    }

    private func observeStore() {
        guard observations.isEmpty else { return }
        // Only this task's family touches the page (§ 9: a task change
        // touches only its row, cards, head and block).
        store.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &observations)
        store.fileMigration.$statuses.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshEarlierFiles() }
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
        refreshEarlierFiles()
        observeStore()
    }

    func suspend() {
        observations.removeAll()
        // A reveal for the moment ends with the page (C1 review P2); a
        // section remount does not suspend, so it keeps the reveal. Fields
        // were resolved before the page closed.
        if isRevealedForTheMoment {
            isRevealedForTheMoment = false
            isExpanded = false
            if let id = focusedRowID, !isVisible(id) { focusedRowID = visibleRows.last?.id }
        }
        isFieldComposing = nil
        focusInside = false
        pointerInside = false
        heldOrder = nil
        onGeometryChange = nil
        onFocusWriting = nil
    }

    static func expandKey(_ id: UUID) -> String { "AtticTaskNote.subtasksExpanded.\(id.uuidString)" }

    /// Collapsed, the list shows this many rows (draft B).
    static let collapsedRowLimit = 3

    var historyID: UndoHistoryID { history.historyID }

    var hasFieldDrafts: Bool {
        isEditingTitle || renamingID != nil || !newSubtaskText.isEmpty || isFieldComposing?() == true
    }

    /// Pending publication may have released the writing as a fallback
    /// draft. Starting a new native field then would strand that draft on
    /// the retired head. Cancellation/clearing always remains available.
    func admitFieldInput() -> Bool {
        guard !history.isInputReserved, !history.hasPendingPublication else {
            return report(CommandFailure(String(localized: "Finish updating this item before editing its fields.")))
        }
        return true
    }

    func editNewSubtask(_ value: String) {
        guard value.isEmpty || admitFieldInput() else { return }
        newSubtaskText = value
    }

    func cancelNewSubtask() { newSubtaskText = "" }

    // MARK: Reading the store

    /// Re-reads the task and its subtasks. Publishes only what changed.
    func refresh(animated: Bool = false) {
        guard !history.hasPendingPublication || !hasFieldDrafts else { return }
        // A task moved to the Done log still has its page (`p3-22` row 3).
        let task = store.listedTask(withID: taskID)
        // Next-day cleanup moved the family to the Done log (§ 2.6): its
        // subtasks are read from there.
        let canonical = task?.doneLoggedAt != nil ? store.doneLogSubtasks(of: taskID) : store.subtasks(of: taskID)
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
        // A page opened on a task that is already deleted (from All notes,
        // § 2.7.2 row 1): the head and the block read as they were.
        if task == nil, !head.exists, rows.isEmpty, let deleted = store.deletedFamily(rootID: taskID) {
            var was = Head(title: deleted.root.title, state: TaskRowPresentation.state(deleted.root.status),
                           priority: TaskRowPresentation.priority(deleted.root.priority), due: nil,
                           tags: deleted.root.tags,
                           subtasks: (deleted.subtasks.filter { $0.status == .done }.count, deleted.subtasks.count),
                           exists: false)
            if let day = deleted.root.dueDay {
                was.due = TaskRowPresentation.due(day, today: DueDay(date: parser.now(), calendar: calendar),
                                                  calendar: calendar, locale: locale)
            }
            head = was
            rows = deleted.subtasks.map { Row(id: $0.id, title: $0.title, isDone: $0.status == .done) }
            onGeometryChange?()
            return
        }
        // Task deleted (`p3-22` row 1): the block keeps the subtasks as they
        // were, read only, until Restore brings the live head back.
        if task == nil, head.exists || !rows.isEmpty {
            let snapshot = head.subtasks
            next.subtasks = rows.isEmpty ? snapshot : (rows.filter(\.isDone).count, rows.count)
            if next != head { head = next; onGeometryChange?() }
            return
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
        // A reorder (⌘↓ past the third row, its Undo, a change elsewhere)
        // never takes the open rename or the keyboard's row out of sight:
        // the list shows for the moment (C1 review P2).
        let kept = [renamingID, focusInside ? focusedRowID : nil].compactMap { $0 }
        if !isExpanded, kept.contains(where: { !isVisible($0) }) { revealAll() }
        onGeometryChange?()
    }

    /// The block's height (`TaskNoteSubtasksBlock`): the 28 pt label, a
    /// 28 pt line per shown row, Add subtask when shown and "N more…" /
    /// "Show less" when shown. Arithmetic, so 50 rows are never measured.
    var blockHeight: CGFloat {
        let notice = CGFloat(noticeCount) * TaskNoteMetrics.noticeHeight
        let lines = visibleRowCount + (showsAddRow ? 1 : 0) + (showsDisclosure ? 1 : 0)
        return TaskNoteMetrics.blockHeader + CGFloat(lines) * TaskNoteMetrics.rowHeight + notice
    }

    // MARK: Draft B's three-row disclosure

    /// The rows on screen: all of them expanded, else the first three of
    /// the shown (held or canonical) order.
    var visibleRows: ArraySlice<Row> { isExpanded ? rows[...] : rows.prefix(Self.collapsedRowLimit) }
    var visibleRowCount: Int { isExpanded ? rows.count : min(rows.count, Self.collapsedRowLimit) }
    /// Rows behind "N more…".
    var hiddenRowCount: Int { rows.count - visibleRowCount }
    /// "N more…" (collapsed) or "Show less" (expanded), only when there is
    /// something to show or hide.
    var showsDisclosure: Bool { rows.count > Self.collapsedRowLimit }
    /// Add subtask: in the expanded list, and with 0–3 subtasks. A deleted
    /// task's snapshot has none.
    var showsAddRow: Bool { head.exists && (isExpanded || rows.count <= Self.collapsedRowLimit) }

    func isVisible(_ id: UUID) -> Bool { visibleRows.contains { $0.id == id } }

    /// "5 more…" or "Show less".
    var disclosureLabel: String {
        isExpanded ? String(localized: "Show less") : String(localized: "\(hiddenRowCount) more…")
    }

    /// VoiceOver's name for the same control.
    var disclosureSpokenLabel: String {
        isExpanded ? String(localized: "Show fewer subtasks") : String(localized: "Show \(hiddenRowCount) more subtasks")
    }

    /// The group's action (§ 8): expand or collapse, named as it reads.
    var disclosureActionName: String? {
        guard showsDisclosure else { return nil }
        return isExpanded ? String(localized: "Show Fewer Subtasks") : String(localized: "Show All Subtasks")
    }

    /// "Subtasks, 2 of 8 done" (§ 8).
    var spokenGroup: String {
        let count = head.subtasks
        let asItWas = head.exists ? "" : ", " + String(localized: "as it was")
        guard count.total > 0 else { return String(localized: "Subtasks") + asItWas }
        return String(localized: "Subtasks, \(count.done) of \(count.total) done") + asItWas
    }

    /// The task's note is in Recently Deleted (§ 5.6): a line under the
    /// block offers Restore Note; the writing below stays empty.
    @Published var deletedNote = false {
        didSet { if deletedNote != oldValue { onGeometryChange?() } }
    }

    /// S10: other live notes that claim this task ("Another note for this
    /// task · Review"), oldest first.
    @Published var alternateNotes: [UUID] = [] {
        didSet { if alternateNotes.isEmpty != oldValue.isEmpty { onGeometryChange?() } }
    }

    /// Earlier files (§ 2.4, § 13, § 5.6 "Migration incomplete"): legacy
    /// files the migration has not moved into this note, with the reason.
    /// Never hidden while they exist. A region of its own, apart from the
    /// writing (S8).
    @Published private(set) var earlierFiles: TaskFilesState.Status = .none {
        didSet { if (earlierFiles.earlier.isEmpty && earlierFiles.refusal == nil) != (oldValue.earlier.isEmpty && oldValue.refusal == nil) { onGeometryChange?() } }
    }

    func refreshEarlierFiles() {
        let next = store.fileMigration.status(of: taskID)
        if next != earlierFiles { earlierFiles = next }
    }

    /// How many quiet lines sit under the block.
    var noticeCount: Int {
        (deletedNote ? 1 : 0) + (alternateNotes.isEmpty ? 0 : 1) + (earlierFiles.earlier.isEmpty && earlierFiles.refusal == nil ? 0 : 1)
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

    /// Focus and the pointer have both left, or the page closed: rows settle into canonical order with the 220 ms move.
    func releaseHold() {
        guard heldOrder != nil else { return }
        heldOrder = nil
        refresh(animated: true)
    }

    // MARK: Expand and collapse (presentation state only: no history, no revision)

    @discardableResult
    func toggleExpanded() -> Bool { setExpanded(!isExpanded) }

    /// "N more…" and "Show less". `remember: false` reveals a row for the
    /// moment (a new or focused row) without changing how the item opens;
    /// that reveal ends when the page closes. Collapsing keeps the held
    /// order while the list is in use (owner answer 5: rows hold still
    /// while you work). Only an expanded item is stored (collapsed is the
    /// default). Returns false when a collapse is refused (see
    /// `resolveFieldsBeforeCollapse`).
    @discardableResult
    func setExpanded(_ expanded: Bool, remember: Bool = true) -> Bool {
        if !expanded, isExpanded, !resolveFieldsBeforeCollapse() { return false }
        if remember {
            isRevealedForTheMoment = false
            if expanded { defaults?.set(true, forKey: Self.expandKey(taskID)) } else { defaults?.removeObject(forKey: Self.expandKey(taskID)) }
        }
        guard expanded != isExpanded else { return true }
        if expanded, !remember { isRevealedForTheMoment = true }
        isExpanded = expanded
        // The ring stays on a row that is still shown.
        if !expanded, let id = focusedRowID, !isVisible(id) { focusedRowID = visibleRows.last?.id }
        onGeometryChange?()
        return true
    }

    /// A collapse never throws away a draft (C1 review P1): a rename on a
    /// row going out of sight is saved first, and a refused save keeps the
    /// list open with the editor and its draft. While an input method is
    /// composing, nothing that holds a field (the rename's row, Add
    /// subtask) goes out of sight.
    private func resolveFieldsBeforeCollapse() -> Bool {
        let shown = rows.prefix(Self.collapsedRowLimit)
        let hidesRename = renamingID.map { id in !shown.contains { $0.id == id } } ?? false
        let hidesAdd = showsAddRow && rows.count > Self.collapsedRowLimit
        guard hidesRename || hidesAdd else { return true }
        if isFieldComposing?() == true { return false }
        return hidesRename ? commitRename() : true
    }

    /// The expansion is a reveal for the moment (Add Subtask, a new fourth
    /// row, a reorder, ⌃⇧Tab), not the person's choice.
    private(set) var isRevealedForTheMoment = false

    /// Shows every row without remembering it, when rows would be hidden.
    func revealAll() {
        guard !isExpanded, hiddenRowCount > 0 else { return }
        setExpanded(true, remember: false)
    }

    // MARK: Subtask commands

    @discardableResult
    func toggle(_ id: UUID) -> Bool {
        guard let task = store.listedTask(withID: id) else { return report(.taskGone) }
        // § 2.6: unticking under a Done task asks Reopen Task and Continue.
        if needsReopen(toggling: id) {
            pendingReopen = .toggle(id)
            return false
        }
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
            cancelNewSubtask()
            focusWriting(atTop: true)
            return true
        }
        // § 2.6: an open subtask in a Done task asks first; the draft stays.
        if head.exists, head.state == .done {
            pendingReopen = .addSubtask
            return false
        }
        let created = library.createTasks([TaskDraft(title: title, status: .todo, parentID: taskID)], in: historyID)
        guard created != nil else {
            return report(library.lastFailure ?? CommandFailure(String(localized: "Couldn't add the subtask"))) { [weak self] in
                self?.commitNewSubtask()
            }
        }
        clearFailure()
        cancelNewSubtask()
        refresh()
        // The new row and the field stay in sight (draft B: Add subtask
        // shows with 0–3 rows, so a fourth row expands the list).
        revealAll()
        return true
    }

    func beginRename(_ id: UUID, undoManager: UndoManager? = nil) {
        guard admitFieldInput() else { return }
        guard rows.contains(where: { $0.id == id }), let task = store.listedTask(withID: id) else { return }
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
        guard admitFieldInput() else { return }
        renameHistory.willEdit(renameEdit, selection: nil, range: range, replacement: replacement)
        renameEdit.edited(range, replacement: replacement)
    }

    func undoRenameDraft() -> (text: String, selection: NSRange)? {
        guard admitFieldInput() else { return nil }
        guard let entry = renameHistory.undo(current: renameEdit, selection: nil) else { return nil }
        renameEdit = entry.text
        return (entry.text.text, entry.selection)
    }

    func redoRenameDraft() -> (text: String, selection: NSRange)? {
        guard admitFieldInput() else { return nil }
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
        guard let task = store.listedTask(withID: id), !title.isEmpty, title != task.title, title != renameBase else {
            cancelRename()
            return true
        }
        guard task.title == renameBase else {
            report(CommandFailure(String(localized: "This subtask changed elsewhere. Your rename draft is kept; press Esc to keep the newer title.")))
            renameConflictID = failure?.id
            return false
        }
        let outcome = fieldCommit(renameField) { [library, historyID] in
            library.updateListedTasks([id], title: title, in: historyID)
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
        guard let task = store.listedTask(withID: id), task.parentID == taskID else { return report(.taskGone) }
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
        let applied = settle(library.deleteListedTasks([id], in: historyID)) { [weak self] in self?.delete(id) }
        if applied, focusedRowID == id {
            let remaining = rows.filter { $0.id != id }
            focusedRowID = index.flatMap { remaining.indices.contains($0) ? remaining[$0].id : remaining.last?.id }
        }
        return applied
    }

    // MARK: Whole-item lifecycle (orchestrator decision 2026-10-23)

    /// Orchestrator decision 2026-10-23: Delete moves the whole item, including
    /// writing and files, in one step in the retained workspace history.
    @discardableResult
    func deleteTask() -> Bool {
        guard store.listedTask(withID: taskID) != nil else { return report(.taskGone) }
        guard resolveFieldDrafts() else { return false }
        return settle(library.deleteListedTasks([taskID], in: historyID)) { [weak self] in self?.deleteTask() }
    }

    /// "Task deleted · Restore": the live head comes back.
    @discardableResult
    func restoreTask() -> Bool {
        guard store.listedTask(withID: taskID) == nil else { return true }
        guard library.restore(AtticItemRef(.task, taskID), in: historyID) else {
            return report(CommandFailure(String(localized: "Couldn't restore the task")), retry: { [weak self] in self?.restoreTask() })
        }
        clearFailure()
        refresh()
        return true
    }

    /// The head's status circle: done, or back from done.
    @discardableResult
    func toggleTask() -> Bool {
        // A Done-log task keeps its page (`p3-22`): it can come back too.
        guard let task = store.listedTask(withID: taskID) else { return report(.taskGone) }
        guard task.status != .done else { return reopenTask() }
        // § 2.6: completing completes the open subtasks in the same
        // operation (today's family operation, as the Tasks circle).
        let open = store.subtasks(of: taskID).filter { $0.status != .done }.count
        guard settle(library.completeTask(taskID, in: historyID), retry: { [weak self] in self?.toggleTask() }) else { return false }
        onCompleted?(open, library.undo.undoStepID(in: historyID))
        return true
    }

    // MARK: The head's title (Tasks' title editor and its shorthand)

    func beginEditingTitle(undoManager: UndoManager? = nil) {
        guard admitFieldInput() else { return }
        guard let task = store.listedTask(withID: taskID), !isEditingTitle else { return }
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
        guard admitFieldInput() else { return }
        titleHistory.willEdit(titleEdit, selection: TaskDraftHistory.selection(titleEditSelection, caret: titleEditCaret),
                              range: range, replacement: replacement)
        titleEdit.edited(range, replacement: replacement)
    }

    func dismissTitleChip(_ range: NSRange) {
        guard admitFieldInput() else { return }
        titleHistory.checkpoint(titleEdit, selection: TaskDraftHistory.selection(titleEditSelection, caret: titleEditCaret))
        titleEdit.dismiss(range)
    }

    func undoTitleDraft() -> (text: String, selection: NSRange)? {
        guard admitFieldInput() else { return nil }
        guard let entry = titleHistory.undo(current: titleEdit, selection: TaskDraftHistory.selection(titleEditSelection, caret: titleEditCaret))
        else { return nil }
        applyTitleDraft(entry)
        return (entry.text.text, entry.selection)
    }

    func redoTitleDraft() -> (text: String, selection: NSRange)? {
        guard admitFieldInput() else { return nil }
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
        guard let task = store.listedTask(withID: taskID) else { return report(.taskGone) }
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
            library.updateListedTasks([taskID], title: newTitle, priority: newPriority, tags: newTags, dueDay: newDay, in: historyID)
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
        if region == .list, rows.isEmpty {
            requestFocus(head.exists ? .add : .writing)
            return
        }
        if region == .more, !showsDisclosure {
            requestFocus(.writing)
            return
        }
        // Add subtask is in the expanded list (or with 0–3 rows).
        if region == .add, !showsAddRow {
            guard head.exists else { requestFocus(.writing); return }
            revealAll()
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

    /// ⌃⇧Tab in the writing: the block's last focused row (shown, even if
    /// it was behind "N more…"), else Add subtask.
    func focusBlockFromWriting() {
        if let id = lastFocusedRowID, rows.contains(where: { $0.id == id }) {
            if !isVisible(id) { revealAll() }
            focusedRowID = id
            requestFocus(.list)
        } else {
            requestFocus(.add)
        }
    }

    /// Where Tab (or ⇧Tab) goes from a region of the block (§ 7). The list
    /// is one stop; Add subtask and "N more…" / "Show less" are stops when
    /// shown, so the keyboard (and Full Keyboard Access) reaches "N more…".
    func tabTarget(from region: Region, backwards: Bool = false) -> Region {
        var order: [Region] = [.title]
        if !rows.isEmpty { order.append(.list) }
        if showsAddRow { order.append(.add) }
        if showsDisclosure { order.append(.more) }
        order.append(.writing)
        guard let index = order.firstIndex(of: region) else { return backwards ? .title : .writing }
        let next = index + (backwards ? -1 : 1)
        return order.indices.contains(next) ? order[next] : region
    }

    /// The row the list's one Tab stop lands on (review P2-5): the ring's
    /// row, else the last focused row, else the first, all among the rows
    /// on screen.
    var listEntryRowID: UUID? {
        if let id = focusedRowID, isVisible(id) { return id }
        if let id = lastFocusedRowID, isVisible(id) { return id }
        return rows.first?.id
    }

    func noteRowFocused(_ id: UUID?) {
        if let id { lastFocusedRowID = id }
    }

    /// ↑↓ in the list: the ring moves among the rows on screen, holding
    /// still at either end.
    func moveRing(by offset: Int) {
        let shown = Array(visibleRows)
        guard !shown.isEmpty else { return }
        let index = focusedRowID.flatMap { id in shown.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : shown.count)
        let next = min(max(0, index + offset), shown.count - 1)
        focusedRowID = shown[next].id
        lastFocusedRowID = focusedRowID
    }

    // MARK: Failures (the Notes status slot; OD-4: no new Retry line)

    func retryFailure() {
        let action = retry
        clearFailure()
        action?()
    }

    /// A command that cannot run here says why in the slot (§ 6: a disabled
    /// command consumes its key and gives its reason).
    func reportUnavailable(_ reason: String) {
        _ = report(CommandFailure(reason))
    }

    /// Reopen Task and Continue (§ 2.6): a Done task goes back to To Do as
    /// one step in the page's history; what was asked then goes ahead.
    @discardableResult
    func reopenTask() -> Bool {
        guard let task = store.listedTask(withID: taskID) else { return report(.taskGone) }
        guard task.status == .done else { return true }
        // Back to what it was before it was finished, from the Done log too
        // (today's Reopen, as the Tasks circle).
        guard settle(library.reopenTasks([taskID], in: historyID), retry: { [weak self] in self?.reopenTask() }) else { return false }
        refresh()
        return true
    }

    /// What waits for Reopen Task and Continue (§ 2.6): writing, files and
    /// the title never reopen a Done task; these do, once asked.
    enum ReopenRequest: Equatable { case toggle(UUID), addSubtask }
    @Published var pendingReopen: ReopenRequest?

    func needsReopen(toggling id: UUID) -> Bool {
        guard head.exists, head.state == .done else { return false }
        return rows.first { $0.id == id }?.isDone ?? (store.listedTask(withID: id)?.status == .done)
    }

    /// The person chose Reopen Task and Continue: the task reopens, then
    /// what was asked goes ahead.
    func continueAfterReopen() {
        guard let request = pendingReopen else { return }
        pendingReopen = nil
        guard reopenTask() else { return }
        switch request {
        case let .toggle(id): _ = toggle(id)
        case .addSubtask: _ = commitNewSubtask()
        }
    }

    /// Completing from the head (circle, ⇧⌘↩): the toast names the scope
    /// ("Task and 2 subtasks completed"), with the step its Undo targets.
    var onCompleted: ((_ subtasks: Int, _ stepID: UUID?) -> Void)?

    func clearFailure() {
        failure = nil
        retry = nil
        titleConflictID = nil
        renameConflictID = nil
    }

    @discardableResult
    private func settle(_ outcome: CommandOutcome, retry: @escaping () -> Void) -> Bool {
        switch outcome {
        case .obsolete:
            return false
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

/// Read-only page metadata. Version bytes remain the exact writing document;
/// this optional snapshot is for historical presentation, never restoration.
struct TaskNotePageSnapshot: Codable, Equatable, Sendable {
    struct Child: Codable, Equatable, Sendable {
        let id: UUID
        let title: String
        let isDone: Bool
    }
    var format = 1
    let title: String
    let status: String
    let priority: String
    let dueDay: DueDay?
    let completedAt: Date?
    let tags: [String]
    let children: [Child]

    @MainActor
    static func capture(note: NoteItem, in context: ModelContext) throws -> Self? {
        guard let owner = note.taskID else { return nil }
        return try capture(taskID: owner, in: context)
    }

    @MainActor
    static func capture(taskID owner: UUID, in context: ModelContext) throws -> Self? {
        guard context.container.schema.entities.contains(where: { $0.name == "TaskItem" }) else { return nil }
        let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == owner || $0.parentID == owner }))
        let canonical = TaskStore.canonicalReplicas(from: rows)
        guard let task = canonical.first(where: { $0.id == owner }) else { return nil }
        let children = canonical.filter { $0.parentID == owner && $0.deletedAt == nil }.sorted {
            if ($0.status == .done) != ($1.status == .done) { return $0.status != .done }
            if $0.manualOrder != $1.manualOrder { return ($0.manualOrder ?? 0) > ($1.manualOrder ?? 0) }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return Self(title: task.title, status: task.statusRaw, priority: task.priorityRaw,
            dueDay: task.dueDay, completedAt: task.completedAt, tags: task.tags,
            children: children.map { Child(id: $0.id, title: $0.title, isDone: $0.status == .done) })
    }

    @MainActor
    static func data(note: NoteItem, in context: ModelContext) throws -> Data? {
        try capture(note: note, in: context).map { try WorkspaceModelFields.encode($0) }
    }

    static func decode(_ data: Data?) -> Self? {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data), value.format == 1 else { return nil }
        return value
    }

    /// One title, task details and subtasks, then the unmodified writing.
    func document(writing: NoteDocument) -> NoteDocument {
        var page = writing
        page.requires.removeAll { $0 == "taskNote" }
        page.blocks = [.text(title)] + detailBlocks + children.map {
            .checklist($0.title, id: $0.id, checked: $0.isDone)
        } + writing.blocks.dropFirst()
        return page
    }

    /// The history engine retains its body-only projection. A visible title
    /// belongs to this immutable historical head, not today's task model.
    func historyDocument(writing: NoteDocument) -> NoteDocument {
        var page = document(writing: writing)
        page.blocks.insert(.text(""), at: 0)
        page.blocks[1].style = "heading"
        page.blocks[1].level = 1
        page.requires.append("taskNote")
        return page
    }

    private var detailBlocks: [NoteBlock] {
        var lines = [TaskStatus(rawValue: status)?.title ?? status]
        if let value = TaskPriority(rawValue: priority), value != .none { lines.append("\(value.title) priority") }
        if let dueDay { lines.append("Due \(dueDay.rawValue)") }
        if let completedAt { lines.append("Completed \(completedAt.formatted(.dateTime.day().month(.abbreviated).year()))") }
        if !tags.isEmpty { lines.append(tags.map { "#" + $0 }.joined(separator: " ")) }
        return lines.map { .text($0) }
    }
}
