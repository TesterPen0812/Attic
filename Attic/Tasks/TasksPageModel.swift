import AppKit
import Combine
import SwiftUI

/// Where the Tasks page is: Now (in progress and to do, then "Completed
/// today"), Backlog, or the Done log. Direction A shows them as tabs. The
/// model, storage and agent tools have always called it `backlog`; the
/// `later` names left in code (the ⌘B shortcut, `tasks-choose-from-later`)
/// are from when it was shown as Later, and are never displayed.
enum TasksTab: Int, CaseIterable, Hashable, Identifiable {
    case now, backlog, done

    var id: Int { rawValue }

    /// The tab's name ("Now · Backlog · Done").
    var title: String {
        switch self {
        case .now: String(localized: "Now")
        case .backlog: String(localized: "Backlog")
        case .done: String(localized: "Done")
        }
    }

    /// The tab's icon on the top row's switch: Move to Now's and Move to
    /// Backlog's, and a bare check beside them (a circled one would read
    /// as the clock's twin and repeat the island's Tasks).
    var systemName: String {
        switch self {
        case .now: "sun.max"
        case .backlog: "clock"
        case .done: "checkmark"
        }
    }

    /// For UI tests and automation.
    var identifier: String {
        switch self {
        case .now: "now"
        case .backlog: "backlog"
        case .done: "done"
        }
    }
}

/// One row as one page draws it (round 12). A finished task is drawn twice
/// at once, by Now's "Completed today" and by Done, so a task's id alone
/// is not one row: geometry, focus, editors, pickers and menu targets are
/// keyed by the page too.
struct TasksRowID: Hashable {
    let tab: TasksTab
    let id: UUID
}

/// What the page needs from outside itself. The shell (or the preview)
/// supplies it; tests supply fixed clocks.
struct TasksPageServices {
    /// "Attach file…": the host's file picker for the task (it keeps the
    /// panel open while the picker is up). Nil where the page has none.
    var chooseFiles: ((UUID) -> Void)?
    /// The add bar's Attach (O17-06): the same picker, for the task being
    /// written. Nil where the page has none.
    var chooseComposerFiles: (() -> Void)?
    /// Open Task Note (Phase 3: a title click, ⌘Return, the menu and
    /// VoiceOver): the host shows the task's page over the list. Nil where
    /// the page has none (the preview, tests): the row's files open instead.
    var openTaskNote: ((UUID) -> Void)?
    /// Files dropped on a row go into the task's note (Phase 3, `p3-22`
    /// row 4). The receiver owns the staging and discards it once the
    /// import is done. Nil: they attach to the task as before.
    var addFilesToTaskNote: ((UUID, TaskAttachmentStaging) -> Void)?
    /// Add Files to Note… (§ 2.4): the picker, then `addFilesToTaskNote`.
    var chooseFilesForNote: ((UUID) -> Void)?
    var removeFromTasks: ((UUID) -> Void)?
    var canRemoveFromTasks: ((UUID) -> Bool)?
    /// Make Checkbox on a subtask row (One item: owner answers,
    /// 2026-10-23, answer 3): the subtask goes into its item's writing
    /// through the page's producer. Nil where the host has no task pages:
    /// the command is hidden.
    var makeCheckbox: ((UUID) -> Void)?
    /// The next event's row (Accepted 2026-10-29): the host shows that day
    /// on the Calendar page. Nil where the page has no Calendar.
    var openCalendarDay: ((DueDay) -> Void)?
    var now: () -> Date = Date.init
    var calendar: () -> Calendar = { Calendar.autoupdatingCurrent }
    var locale: Locale = .autoupdatingCurrent
    /// How long a finished row stays in place before it slides to the done
    /// group (spec: about a second).
    var doneHold: Duration = .seconds(AtticMotionPreset.doneHold)
}

/// One row of a list: a main task with what its row and quick look show.
struct TasksListRow: Identifiable, Equatable {
    let id: UUID
    let model: AtticTaskRowModel
    let status: TaskStatus
    /// Only when the quick look is open.
    let subtasks: [AtticSubtaskModel]
    /// The task's due day (the date groups, owner's panel design).
    var due: DueDay? = nil

    static func == (lhs: TasksListRow, rhs: TasksListRow) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.model.title == rhs.model.title
            && lhs.model.state == rhs.model.state && lhs.model.priority == rhs.model.priority
            && lhs.model.due?.text == rhs.model.due?.text && lhs.model.tags == rhs.model.tags
            && lhs.model.attachments == rhs.model.attachments && lhs.model.titleMatch == rhs.model.titleMatch
            // Phase 3: the note glyph (a list skips rows that compare equal).
            && lhs.model.hasPage == rhs.model.hasPage
            && lhs.model.subtasks?.done == rhs.model.subtasks?.done
            && lhs.model.subtasks?.total == rhs.model.subtasks?.total
            && lhs.subtasks.map(\.id) == rhs.subtasks.map(\.id)
            && lhs.subtasks.map(\.isDone) == rhs.subtasks.map(\.isDone)
            && lhs.subtasks.map(\.title) == rhs.subtasks.map(\.title)
            && lhs.due == rhs.due && lhs.model.tileFiles == rhs.model.tileFiles
    }
}

/// Stable siblings in the lazy list: a task keeps its identity when its
/// due day moves it across headers, rather than being reparented between
/// nested dynamic ForEach collections.
struct TasksDateListEntry: Identifiable {
    let group: TasksPanelDesign.Group
    let row: TasksListRow?
    var reorderIDs: [UUID] = []
    let id: String

    init(group: TasksPanelDesign.Group, row: TasksListRow?, reorderIDs: [UUID] = []) {
        self.group = group
        self.row = row
        self.reorderIDs = reorderIDs
        id = row.map { "task:" + $0.id.uuidString } ?? "group:" + group.key
    }

    static func entries(_ sections: TasksSections) -> [Self] {
        sections.groups.flatMap { group in
            let rows = sections.groupRows[group.key] ?? []
            let byStatus = Dictionary(grouping: rows, by: \.status).mapValues { $0.map(\.id) }
            return [Self(group: group, row: nil)] + rows.map {
                Self(group: group, row: $0, reorderIDs: byStatus[$0.status] ?? [])
            }
        }
    }
}

/// A list as the page shows it: the open rows (with any finished row still
/// held in place), and on Now the rows finished today, which show under
/// "Completed today" when it is open.
struct TasksSections: Equatable {
    var open: [TasksListRow] = []
    var done: [TasksListRow] = []
    /// The open rows' date groups, in the order drawn (owner's panel
    /// design): every group, folded ones included (their rows are left out
    /// of `open`).
    var groups: [TasksPanelDesign.Group] = []
    /// Each group's rows as drawn (none while it is folded).
    var groupRows: [String: [TasksListRow]] = [:]
}

/// A day of the Done log.
struct TasksDoneDay: Identifiable, Equatable {
    let id: Date
    let title: String
    /// None while the day is folded.
    let rows: [TasksListRow]
    /// The day's tasks, folded or not.
    var total: Int = 0
    var folded = false

    /// The fold's key (the owner's panel design).
    var key: String { TasksPanelDesign.GroupKind.finished(id).key }
}

/// A signal a task row's cell redraws on (see `TasksPageModel.cellUpdates`).
@MainActor
final class TasksCellUpdates: ObservableObject {
    /// Never fires: the rows of a page kept built but not drawn.
    static let quiet = TasksCellUpdates()
}

/// Only the quick look with the active editor observes its draft keys.
@MainActor
final class TasksSubtaskDraftState: ObservableObject {
    static let quiet = TasksSubtaskDraftState()
    @Published var newTitle = ""
    @Published var rename = ""
}

/// The add bar's text and insertion point. Only the add bar observes it.
@MainActor
final class TasksAddBarState: ObservableObject {
    @Published var text = TaskAddBarText()
    @Published var caret: Int?
    /// The whole selection, for the draft history (not observed: only
    /// undo reads it).
    var selection: NSRange?
    /// The suggestion list's highlighted choice (owner fix 5 B).
    @Published var highlighted = 0
    /// The piece whose suggestions Esc hid; the next edit shows them again.
    @Published var hiddenSuggestion: NSRange?
    /// The draft's undo history, text and pieces together (round 4).
    var history = TaskDraftHistory()
    /// Files waiting for the new task (O17-06), and batches still being
    /// staged. Kept when the text is cleared; they go with the task added,
    /// or the strip's × removes them.
    @Published var files: [TasksComposerFiles] = []
    @Published var stagingFiles = 0
    /// Clear invalidates providers still staging for this draft.
    var filesGeneration = UUID()

    /// The owner's side of the token field's undo: text and pieces step
    /// back together; nil when the draft has nothing to undo.
    /// The selection now: the field's last report while it agrees with
    /// the caret, else the caret alone.
    var currentSelection: NSRange? { TaskDraftHistory.selection(selection, caret: caret) }

    func undoDraft() -> (text: String, selection: NSRange)? {
        guard let entry = history.undo(current: text, selection: currentSelection) else { return nil }
        apply(entry)
        return (entry.text.text, entry.selection)
    }

    func redoDraft() -> (text: String, selection: NSRange)? {
        guard let entry = history.redo(current: text, selection: currentSelection) else { return nil }
        apply(entry)
        return (entry.text.text, entry.selection)
    }

    private func apply(_ entry: TaskDraftHistory.Entry) {
        text = entry.text
        caret = entry.selection.location
        selection = entry.selection
    }

    /// The draft is gone (added, or cleared on purpose).
    func clearDraft() {
        text.clear()
        history.reset()
        selection = nil
        hiddenSuggestion = nil
        highlighted = 0
    }
}

/// A rename's draft is observed only by the row being edited. Page state
/// still publishes begin/commit/cancel, but typing and caret movement do not
/// invalidate the page, other rows, or the kept pager pages.
@MainActor
final class TasksTitleDraftState: ObservableObject {
    @Published var text = TaskAddBarText()
    @Published var caret: Int?
}

/// The Tasks page's state and every action it takes. All changes go through
/// `AtticLibrary`, so each is one undoable step in the Tasks history (the
/// same route ⌘Z, the toast and agents use). Lives as long as the panel
/// (the shell keeps it in `TasksPageState`), so switching pages keeps what
/// was typed, selected and expanded.
@MainActor
final class TasksPageModel: ObservableObject {
    let library: AtticLibrary
    var store: TaskStore { library.tasks }
    var services: TasksPageServices

    @Published var tab: TasksTab = .now {
        // Remembered across relaunch (L7), where the page has a memory.
        didSet { if tab != oldValue { memory?.savePage(tab) } }
    }
    @Published private(set) var selection: Set<UUID> = [] {
        didSet { if selection != oldValue { selectionRevision += 1 } }
    }
    private var selectionRevision = 0
    private var keyboardFocusSelectionRevision: Int?
    /// The row a Shift-extension grows from (readable for the tests).
    private(set) var selectionAnchor: UUID?
    /// Rows whose quick look is open (remembered per row for the session).
    @Published private(set) var expanded: Set<UUID> = []
    @Published private(set) var editingTitleID: UUID?
    /// The title being edited, with its shorthand (owner fix 4): what is
    /// typed as `#tag`, a date or `!` becomes a chip and applies on save.
    let titleDraft = TasksTitleDraftState()
    var titleEdit: TaskAddBarText {
        get { titleDraft.text }
        set { titleDraft.text = newValue }
    }
    var titleEditCaret: Int? {
        get { titleDraft.caret }
        set { titleDraft.caret = newValue }
    }
    /// The title editor's undo history, text and pieces together (round 4).
    var titleHistory = TaskDraftHistory()

    /// The title editor's whole selection (for its undo history only).
    var titleEditSelection: NSRange?
    var titleEditCurrentSelection: NSRange? { TaskDraftHistory.selection(titleEditSelection, caret: titleEditCaret) }

    func undoTitleEdit() -> (text: String, selection: NSRange)? {
        guard let entry = titleHistory.undo(current: titleEdit, selection: titleEditCurrentSelection) else { return nil }
        applyTitle(entry)
        return (entry.text.text, entry.selection)
    }

    func redoTitleEdit() -> (text: String, selection: NSRange)? {
        guard let entry = titleHistory.redo(current: titleEdit, selection: titleEditCurrentSelection) else { return nil }
        applyTitle(entry)
        return (entry.text.text, entry.selection)
    }

    private func applyTitle(_ entry: TaskDraftHistory.Entry) {
        titleEdit = entry.text
        titleEditCaret = entry.selection.location
        titleEditSelection = entry.selection
    }
    /// The plain text being edited.
    var editingTitle: String {
        get { titleEdit.text }
        set { titleEdit.text = newValue }
    }
    /// A title, subtask or paste whose save failed: the text stays where it
    /// was typed and the row offers "Not saved · Retry" until a save works.
    @Published private(set) var failedSave: FailedSave?

    enum FailedSave: Equatable {
        case title(UUID)
        case newSubtask(UUID)
        case paste
    }
    @Published private(set) var newSubtaskParentID: UUID?
    let subtaskDraft = TasksSubtaskDraftState()
    var newSubtaskTitle: String {
        get { subtaskDraft.newTitle }
        set { subtaskDraft.newTitle = newValue }
    }
    /// A quick-look subtask being renamed in place (round 10), its text,
    /// and whether its save failed ("Not saved · Retry").
    @Published var renamingSubtaskID: UUID?
    /// A rename belongs to the quick look it opened in. A move elsewhere
    /// cannot leave its editor holding that original page's keys.
    var renamingSubtaskParentID: UUID?
    var subtaskRename: String {
        get { subtaskDraft.rename }
        set { subtaskDraft.rename = newValue }
    }
    @Published var subtaskRenameFailed = false
    /// The subtask line that has the keyboard (round 10b). Not published: it
    /// only steers which row a shortcut targets, and never redraws.
    var focusedSubtaskID: UUID?
    /// The task row that has the keyboard: the page's focus, copied here as
    /// it changes so the rows' cells read it as they draw (deep review
    /// P2-04). Not published: the page tells the cells (`cellUpdates`).
    var keyboardFocus: AtticRowFocusID?

    /// Shared by native focus observation and the headless regression tests.
    func receiveKeyboardFocus(_ focus: AtticRowFocusID?, keyboardDriving: Bool) {
        if let focus, focus.page == tab.rawValue, keyboardDriving,
           selection.count == 1, !selection.contains(focus.id) { selectOnly(focus.id) }
        keyboardFocus = focus
        keyboardFocusSelectionRevision = focus?.page == tab.rawValue && keyboardDriving ? selectionRevision : nil
    }

    func keyboardRow(focused: UUID?, visible: [UUID]) -> UUID? {
        let live = Set(visible)
        let selected = selection.intersection(live)
        let focusIsLater = keyboardFocus?.id == focused && keyboardFocus?.page == tab.rawValue
            && keyboardFocusSelectionRevision == selectionRevision
        if let focused, live.contains(focused), focusIsLater || selected.isEmpty || selected.contains(focused) { return focused }
        return selected.count == 1 ? selected.first : nil
    }
    /// Finished rows held where they were for about a second, with the
    /// list and index they held (spec: "stays in place, then slides").
    @Published private(set) var held: [UUID: HeldPlace] = [:]
    /// A row can acknowledge a press before its family transaction runs.
    /// Retain the intent until that transaction has settled, including failure.
    private var completingAfterAcknowledgement: [(id: UUID, settled: (CommandOutcome) -> Void)] = []
    /// Transient value copies for a command awaiting its durable family
    /// transaction. The store's SwiftData instances are never modified by
    /// this preview, so rollback only removes the copies.
    private var acknowledgedRows: [UUID: TaskItem] = [:]
    private var acknowledgedDeleted: Set<UUID> = []
    private var acknowledgedCreated: [TaskItem] = []
    @Published private(set) var acknowledgementRevision: UInt64 = 0
    private var acknowledgedTaskCommand: (() -> Bool)?
    private var acknowledgedTaskToken: UUID?

    struct HeldPlace: Equatable {
        let tab: TasksTab
        let index: Int
    }

    /// Whether Now's "Completed today" shows its rows (remembered for the
    /// session: the model lives as long as the panel).
    @Published var completedTodayExpanded = false
    /// A row is being dragged on Now (Adaptive picks, "Drag a task into
    /// another day"): Today and Tomorrow show as empty headers to drop
    /// under. Set when the drag lifts and cleared when it ends.
    @Published var dayDragLive = false
    /// Today's next event (`TasksNextEventFeed`), shown at the top of Now's
    /// Today; nil without Calendar access, with the switch off, or with no
    /// event still ahead today.
    @Published var nextEvent: TasksNextEvent?
    /// The date groups folded, per page (the owner's panel design: a
    /// header's click folds or unfolds its group).
    @Published private(set) var foldedGroups: [TasksTab: Set<String>] = [:]

    func folded(on tab: TasksTab) -> Set<String> { foldedGroups[tab] ?? [] }

    /// The next event as `tab` shows it: on Now only, and not while Find or
    /// a tag chip narrows the list (the design's `nextToday` rule).
    func nextEvent(on tab: TasksTab) -> TasksNextEvent? {
        guard tab == .now, let nextEvent, trimmedQuery(for: tab).isEmpty, tagPicks(on: tab).isEmpty else { return nil }
        return nextEvent
    }

    /// The next event's row: that day on the Calendar page.
    func openNextEvent() {
        guard let day = nextEvent(on: .now)?.day else { return }
        services.openCalendarDay?(day)
    }

    /// Giving a Later task a date moves it to Now under that day (the
    /// store's rule), and the page follows it there, as the design does.
    func followDatedOutOfLater(_ ids: [UUID]) {
        guard tab == .backlog, ids.contains(where: { store.task(withID: $0)?.listedStatus == .todo }) else { return }
        let keep = selection
        select(tab: .now)
        guard self.tab == .now else { return }
        for id in keep where store.task(withID: id) != nil { selection.insert(id) }
    }

    func foldAllGroups(_ keys: [String], folded: Bool, on tab: TasksTab) {
        var set = foldedGroups[tab] ?? []
        if folded { set.formUnion(keys) } else { set.subtract(keys) }
        foldedGroups[tab] = set
        if folded { pruneInvisibleSelection(on: tab) }
    }

    func toggleGroup(_ key: String, on tab: TasksTab) {
        var set = foldedGroups[tab] ?? []
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        foldedGroups[tab] = set
        if set.contains(key) { pruneInvisibleSelection(on: tab) }
    }

    /// A fold, filter, completion, or edit can remove a row from the current
    /// page. Don't leave a hidden row selected or holding keyboard shortcuts.
    func pruneInvisibleSelection(on tab: TasksTab) {
        guard self.tab == tab else { return }
        guard !selection.isEmpty || keyboardFocus?.page == tab.rawValue else { return }
        let visible = Set(tab == .done
            ? doneDays().flatMap { $0.rows.map(\.id) }
            : rows(for: tab).map(\.id))
        if !selection.isSubset(of: visible) {
            selection.formIntersection(visible)
            if let anchor = selectionAnchor, !selection.contains(anchor) {
                selectionAnchor = selection.first
            }
        }
        if let focus = keyboardFocus, focus.page == tab.rawValue, !visible.contains(focus.id) {
            receiveKeyboardFocus(nil, keyboardDriving: false)
        }
    }
    /// Search (the menu-bar item) asked for the Done page's search field;
    /// the page puts the keyboard there and clears it.
    @Published var pendingSearchFocus = false
    /// A date group (or a Done day) folding or unfolding, while it turns
    /// (fix round 2, `TasksFoldTurn`). Published on the model, as the
    /// folds themselves are, because the pager rebuilds its pages for the
    /// model's changes and not for the page's own state (on the Air a fold
    /// kept in the page's state jumped closed and an unfold stayed closed).
    @Published var foldTurn: TasksFoldTurn?
    /// What is typed in the add bar, kept apart from the page's published
    /// state: typing redraws the bar, not the list.
    let addBarState = TasksAddBarState()
    var addBar: TaskAddBarText {
        get { addBarState.text }
        set { addBarState.text = newValue }
    }
    var addBarCaret: Int? {
        get { addBarState.caret }
        set { addBarState.caret = newValue }
    }
    @Published var pasteOffer: TaskPasteOffer?
    /// The applied result query. Typing lives in its own small field state
    /// so it does not invalidate the page and its rows on every key; the
    /// applied query and its results are published to the Done page alone
    /// (`doneResults`), so the first results do not redraw the whole page.
    var doneSearch = "" {
        willSet { doneResults.objectWillChange.send() }
        didSet {
            doneSearchTask?.cancel()
            doneSearchInput.replace(doneSearch)
        }
    }
    let doneSearchInput = TasksDoneSearchInput()
    /// What the Done page shows for its query: `doneSearch`, the loaded log
    /// and its paging state. Only the Done page and Done's query watcher
    /// observe it, not the Tasks page (the results frame: CI measured
    /// 86–116 ms when the whole page redrew for the first results).
    let doneResults = TasksDoneResults()
    private var doneSearchTask: Task<Void, Never>?

    func typeDoneSearch(_ text: String, nativeEdit: Bool = false) {
        // Native edits already changed the editor. Keyboard fallback letters
        // must publish to the input view so the next native edit retains them.
        if nativeEdit { doneSearchInput.edit(text) }
        else { doneSearchInput.replace(text) }
        doneSearchTask?.cancel()
        doneSearchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(75)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flushDoneSearchInput()
        }
    }

    /// Keyboard navigation must use the latest field text, including a
    /// query typed just before Down; Escape/programmatic searches cancel
    /// a pending publication through doneSearch's setter above.
    func flushDoneSearchInput() {
        doneSearchTask?.cancel()
        let query = doneSearchInput.text
        if doneSearch != query { doneSearch = query }
        loadDoneLogIfNeeded()
    }
    /// Now's and Later's Find, per page (follow-up part 2, item 6; Done's
    /// is `doneSearch`). Read through `searchQuery(for:)`.
    @Published var listSearch: [TasksTab: String] = [:]
    /// Now's and Later's View Options, per page (item 6); a page with the
    /// default view has none. Read through `viewOptions(for:)`.
    @Published var viewOptionsByTab: [TasksTab: TasksViewOptions] = [:]
    /// The tags picked in the tag bar (owner, 2026-10-28; several since
    /// Accepted 2026-11-13, 2B), shared by Now, Backlog and Done (T6), for
    /// the app's session (not remembered across launches). None is All.
    @Published var tagPicks: TagPicks = .none {
        // Done draws from its own results (T6). A shared tag change while
        // Now or Later is active must not wake the retained offscreen Done
        // list; opening Done reads the current tags and rebuilds its cache.
        willSet { if newValue != tagPicks && tab == .done { doneResults.objectWillChange.send() } }
    }
    /// Bumped when the library's tags change (their order, a rename): the
    /// tag chips are rebuilt.
    var tagInventoryRevision: UInt64 = 0
    /// The tag chips, built once per change (`tagChips()`).
    var tagChipsCache: (revision: UInt64, inventory: UInt64, tags: [String])?
    /// Find's counts on the other tabs (T3), built once per query, tag and
    /// change (`searchMatchesElsewhere(from:)`).
    var elsewhereCountsCache: (key: TasksElsewhereKey, counts: [TasksElsewhereCount])?
    /// Where the page and the views are remembered across relaunch (L7).
    var memory: TasksPageMemory?
    /// Loaded pages of the Done log (lazily, a page at a time). Published
    /// through `doneResults`, as `doneSearch` is.
    private(set) var doneLogTasks: [TaskItem] = [] {
        willSet { doneResults.objectWillChange.send() }
    }
    private(set) var doneLogHasMore = false {
        willSet { doneResults.objectWillChange.send() }
    }
    /// A Done log read failed (Astra 18): what was loaded stays, and the
    /// page offers "Couldn't load more · Retry" instead of claiming there
    /// is nothing more.
    private(set) var doneLogFailure: String? {
        willSet { doneResults.objectWillChange.send() }
    }
    /// The loaded Done log tasks' subtasks, read with their page (Astra 19):
    /// an archived row shows its checklist from its archived family.
    private var doneLogChildren: [UUID: [TaskItem]] = [:]
    private var doneLogQuery: String?
    /// The tag the loaded Done log pages were read for (T6).
    private var doneLogTag: TagPicks?
    private var doneLogRevision: UInt64?
    private var doneLogCursor = TaskStore.DoneLogCursor()

    var dateEnvironmentDidPublish: ((Notification) -> Void)?
    /// Resolve the calendar when shorthand is used: the retained page can
    /// outlive a system time-zone change or a change in the injected calendar.
    var parser: TaskTextParser {
        TaskTextParser(calendar: services.calendar(), locale: services.locale, now: services.now)
    }
    /// Where the page's Undo toast shows: the shell's one toast host (the
    /// panel supplies its own; the page alone gets a private one).
    let toasts: PanelToastCenter
    private var holdTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// About three screens of the Done log: more load as its last row
    /// comes on screen. Each search hydrates one page in the keystroke's
    /// budget (16 ms with matching and grouping), and 80 rows took a third
    /// of it on a CI runner (PR prep: 16.0–16.4 ms queries at 80).
    static let doneLogPageSize = 40

    init(library: AtticLibrary, services: TasksPageServices = TasksPageServices(), toasts: PanelToastCenter? = nil,
         memory: TasksPageMemory? = nil) {
        self.library = library
        self.services = services
        self.toasts = toasts ?? PanelToastCenter()
        self.memory = memory
        Publishers.MergeMany(DatePresentationEnvironment.notifications.map {
            NotificationCenter.default.publisher(for: $0)
        }).sink { [weak self] notification in
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
                self?.cellUpdates.objectWillChange.send()
                self?.dateEnvironmentDidPublish?(notification)
            }
        }.store(in: &cancellables)
        // A task that left the list (deleted, cleaned up) leaves the
        // selection and the quick look too.
        library.tasks.$revision
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pruneMissing() } }
            .store(in: &cancellables)
        library.tags.inventoryChanges
            .sink { [weak self] in
                self?.tagInventoryRevision &+= 1
                self?.objectWillChange.send()
                DispatchQueue.main.async { self?.pruneTagPicks() }
            }
            .store(in: &cancellables)
        // A rename or merge of a picked tag: the pick follows it.
        library.tags.renames
            .sink { [weak self] change in
                guard let self else { return }
                let next = self.tagPicks.renaming(change.sources, to: change.target)
                if next != self.tagPicks { self.tagPicks = next }
            }
            .store(in: &cancellables)
        // Slice 2: a family's files moved into its note (or back).
        library.tasks.fileMigration.$statuses.dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.noteOwnersRevision &+= 1
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
        // A subtask moved, or a move undone or redone (from here or the
        // shared history): the open quick look takes the new order.
        library.subtaskOrderChanges
            .sink { [weak self] parentID in self?.releaseQuickLookOrder(of: parentID) }
            .store(in: &cancellables)
        // `$revision` publishes before the history changes: check after it.
        library.undo.$revision
            .sink { [weak self] _ in DispatchQueue.main.async { self?.dismissToastIfSuperseded() } }
            .store(in: &cancellables)
        // The page and the views it was left with (L7).
        if let memory {
            tab = memory.page ?? .now
            viewOptionsByTab = memory.viewOptions
            scrollOffsets = memory.scrollOffsets
        }
    }

    // MARK: - Lists

    private var today: DueDay { DueDay(date: services.now(), calendar: services.calendar()) }
    private var dateEnvironment: DatePresentationEnvironment {
        DatePresentationEnvironment(calendar: services.calendar(), locale: services.locale)
    }

    func rowModel(for task: TaskItem, match: String? = nil) -> TasksListRow {
        let subtasks: [TaskItem]
        if task.doneLoggedAt != nil {
            // Archived families are loaded with the page. Looking these up
            // in the live-family index needlessly builds all active tasks.
            subtasks = doneLogChildren[task.id] ?? []
        } else if store.parent(of: task) != nil {
            subtasks = []
        } else if store.task(withID: task.id) != nil {
            subtasks = store.subtasks(of: task.id)
        } else {
            // A Done log task: its family left the list with it.
            subtasks = doneLogChildren[task.id] ?? []
        }
        let open = expanded.contains(task.id)
        var model = TaskRowPresentation.row(for: task, subtasks: subtasks, today: today,
                                            calendar: services.calendar(), locale: services.locale)
        // The tick is the acknowledgement of the press. The durable store
        // can be slow; a failed save cancels the hold and restores this row.
        if held[task.id] != nil, task.status != .done { model.state = .done }
        // Find's matches are marked in the title (item 6, as on Done).
        if let match, !match.isEmpty { model.titleMatch = match }
        // Phase 3 (`p3-06`, D11): the note glyph after the subtask count.
        model.hasPage = noteOwners.contains(task.id)
        // Slice 2 (§ 2.4, D11): a family whose files are in its note shows
        // no paperclip, unless Earlier files remain; others as on main.
        let files = store.fileMigration.rowFiles(for: task)
        model.attachments = files.count
        // The owner's panel design: the files as tiles, all of them (the
        // strip scrolls sideways when they overflow).
        model.tileFiles = files
        return TasksListRow(
            id: task.id,
            model: model,
            status: task.listedStatus,
            subtasks: open ? quickLookSubtasks(of: task.id, subtasks).map { AtticSubtaskModel(id: $0.id, title: $0.title, isDone: $0.status == .done) } : [],
            due: task.dueDay
        )
    }

    private struct RowsKey: Equatable {
        let tab: TasksTab
        let revision: UInt64
        let acknowledgementRevision: UInt64
        let noteOwners: UInt64
        let held: [UUID: HeldPlace]
        let expanded: Set<UUID>
        let completedExpanded: Bool
        let today: DueDay
        let dateEnvironment: DatePresentationEnvironment
        let view: TasksViewOptions
        let search: String
        let tag: TagPicks
        let folded: Set<String>
        let nextEvent: TasksNextEvent?
        /// A row is being dragged on Now: Today and Tomorrow show.
        let dayDrag: Bool
    }

    /// What a page kept built but not drawn shows (round 11): while it is
    /// the same, the page is not redrawn when the model changes elsewhere (a
    /// selection, a keystroke), only when its own rows could have.
    struct PageToken: Equatable {
        let tab: TasksTab
        let revision: UInt64
        let acknowledgementRevision: UInt64
        let noteOwners: UInt64
        let held: [UUID: HeldPlace]
        let expanded: Set<UUID>
        let completedExpanded: Bool
        let today: DueDay
        let dateEnvironment: DatePresentationEnvironment
        let doneLog: [UUID]
        let search: String
        /// Now's and Later's view (item 6).
        let view: TasksViewOptions
        /// The chosen tag chip (Now and Later).
        let tag: TagPicks
        /// The date groups folded on this page.
        let folded: Set<String>
        /// The next event at the top of Today (Now only).
        let nextEvent: TasksNextEvent?
        /// A row is being dragged on Now (its Today and Tomorrow show).
        let dayDrag: Bool
        /// Whether this page is the one that answers the user (the tab
        /// shown, on screen): it gains and loses editors, focus and popovers
        /// with it (round 12).
        let owner: Bool
    }

    func pageToken(_ tab: TasksTab) -> PageToken {
        PageToken(tab: tab, revision: store.revision, acknowledgementRevision: acknowledgementRevision, noteOwners: noteOwnersRevision, held: held.filter { $0.value.tab == tab }, expanded: expanded,
                  completedExpanded: tab == .now && completedTodayExpanded, today: today, dateEnvironment: dateEnvironment,
                  doneLog: tab == .done ? doneLogTasks.map(\.id) : [], search: searchQuery(for: tab),
                  view: viewOptions(for: tab), tag: self.tab == tab ? tagPicks(on: tab) : .none,
                  folded: folded(on: tab), nextEvent: nextEvent(on: tab),
                  dayDrag: tab == .now && dayDragLive, owner: self.tab == tab && isPageShown)
    }

    /// Rows are rebuilt only when something they show changed: SwiftUI asks
    /// for them many times per change.
    private struct RowsSnapshot {
        let key: RowsKey
        let sections: TasksSections
        let rows: [TasksListRow]
        let entries: [TasksDateListEntry]
        let ids: [UUID]
        let idsByStatus: [TaskStatus: [UUID]]
        let eligibleIDs: Set<UUID>
        var selectedForRuns: Set<UUID>?
        var expandedForRuns: Set<UUID>?
        var selectionRuns: [UUID: AtticSelectionRun] = [:]
    }

    private var rowsCache: [TasksTab: RowsSnapshot] = [:]
    #if DEBUG
    private(set) var selectionRunRebuildCount = 0
    #endif

    /// The rows a list shows, in order (the keyboard walks them): Now's
    /// open rows (in progress, then to do), then today's done rows when
    /// "Completed today" is open; Later's tasks. A task just finished
    /// holds its place for about a second.
    func rows(for tab: TasksTab) -> [TasksListRow] {
        cached(tab).rows
    }

    /// The open rows and today's done rows, apart (the page draws
    /// "Completed today" between them).
    func sections(for tab: TasksTab) -> TasksSections {
        cached(tab).sections
    }

    /// The flattened list's sibling entries change with its rows, folds and
    /// date groups, not with the selected row. Reuse their identities and
    /// reorder groups when a selection redraws the page.
    func listSnapshot(for tab: TasksTab) -> (rows: [TasksListRow], sections: TasksSections, entries: [TasksDateListEntry],
                                              ids: [UUID], idsByStatus: [TaskStatus: [UUID]], selectionRuns: [UUID: AtticSelectionRun]) {
        var snapshot = cached(tab)
        if snapshot.selectedForRuns != selection || snapshot.expandedForRuns != expanded {
            snapshot.selectionRuns = TasksSelectionRuns.make(ids: snapshot.ids, selected: selection, expanded: expanded)
            snapshot.selectedForRuns = selection
            snapshot.expandedForRuns = expanded
            rowsCache[tab] = snapshot
            #if DEBUG
            selectionRunRebuildCount += 1
            #endif
        }
        return (snapshot.rows, snapshot.sections, snapshot.entries, snapshot.ids, snapshot.idsByStatus, snapshot.selectionRuns)
    }

    /// File-drag hover uses the current snapshot's membership; it never
    /// walks the task list just because the pointer moved.
    func eligibleRowIDs(for tab: TasksTab) -> Set<UUID> { cached(tab).eligibleIDs }

    private func cached(_ tab: TasksTab) -> RowsSnapshot {
        let key = RowsKey(tab: tab, revision: store.revision, acknowledgementRevision: acknowledgementRevision, noteOwners: noteOwnersRevision, held: held.filter { $0.value.tab == tab }, expanded: expanded,
                          completedExpanded: tab == .now && completedTodayExpanded, today: today, dateEnvironment: dateEnvironment,
                          view: viewOptions(for: tab), search: tab == .done ? "" : trimmedQuery(for: tab), tag: tagPicks(on: tab),
                          folded: folded(on: tab), nextEvent: nextEvent(on: tab), dayDrag: tab == .now && dayDragLive)
        if let cached = rowsCache[tab], cached.key == key {
            IdleLatencyTrace.count("task_rows_cache_hit", 1)
            return cached
        }
        IdleLatencyTrace.count("task_rows_cache_miss", 1)
        let all = IdleLatencyTrace.span("task_rows_build") { buildRows(for: tab) }
        IdleLatencyTrace.count("task_rows", all.count)
        var sections = TasksSections()
        var open: [TasksListRow] = []
        for row in all {
            if row.status == .done, held[row.id]?.tab != tab {
                // The owner's panel design (2026-10-27): a finished task
                // leaves Now once its hold ends and lives in Done; Now has
                // no "Completed today".
                if tab != .now { sections.done.append(row) }
            } else {
                open.append(row)
            }
        }
        // The date groups (owner's panel design): Overdue · Today · each
        // later day · No date, clocks first within each day, stable ties. Built
        // here, so only when the rows change (or the day does: `today` is
        // in the key). A folded group's rows are left out of the list.
        let times = Dictionary(store.tasks.compactMap { task in task.dueTimeMinutes.map { (task.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        // Backlog rows retain their dates (Accepted 2026-11-05). Now's
        // Today also shows for the next event alone.
        var groups = tab == .backlog
            ? TasksPanelDesign.backlogGroups(open.map { (id: $0.id, due: $0.due) })
            : TasksPanelDesign.groups(open.map { ($0.id, $0.due) }, times: times, today: key.today,
                                      calendar: services.calendar(), locale: services.locale)
        if key.nextEvent != nil { groups = TasksPanelDesign.withTodayForNextEvent(groups) }
        if key.dayDrag { groups = TasksPanelDesign.withDropDays(groups, today: key.today, calendar: services.calendar()) }
        let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for group in groups where !key.folded.contains(group.key) {
            var drawn: [TasksListRow] = []
            defer { sections.groupRows[group.key] = drawn }
            for id in group.ids {
                guard var row = byID[id] else { continue }
                // The header names the date. Time display stays deferred.
                if !group.rowsShowDate, row.model.due != nil {
                    var model = row.model
                    model.hidesDue = true
                    row = TasksListRow(id: row.id, model: model, status: row.status, subtasks: row.subtasks, due: row.due)
                }
                sections.open.append(row)
                drawn.append(row)
            }
        }
        sections.groups = groups
        let rows = key.completedExpanded ? sections.open + sections.done : sections.open
        let ids = rows.map(\.id)
        let entry = RowsSnapshot(key: key, sections: sections, rows: rows, entries: TasksDateListEntry.entries(sections),
                                 ids: ids, idsByStatus: Dictionary(grouping: rows, by: \.status).mapValues { $0.map(\.id) },
                                 eligibleIDs: Set(ids))
        rowsCache[tab] = entry
        return entry
    }

    /// The projected tasks in the order the settled snapshot gives them:
    /// by state in the scope's order, then the store's section order
    /// (manual order, newest change, id), so a row moved or restated on
    /// the first frame is where it will settle. `created`: tasks that go
    /// first in their state (made, or arriving from another state).
    static func inSnapshotOrder(_ tasks: [TaskItem], scope: TaskScope, created: Set<UUID>) -> [TaskItem] {
        let rank = Dictionary(uniqueKeysWithValues: scope.statuses.enumerated().map { ($1, $0) })
        return tasks.sorted { lhs, rhs in
            let left = rank[lhs.listedStatus] ?? Int.max, right = rank[rhs.listedStatus] ?? Int.max
            if left != right { return left < right }
            let lhsNew = created.contains(lhs.id), rhsNew = created.contains(rhs.id)
            if lhsNew != rhsNew { return lhsNew }
            switch (lhs.manualOrder, rhs.manualOrder) {
            case let (.some(l), .some(r)) where l != r: return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func buildRows(for tab: TasksTab) -> [TasksListRow] {
        let scope: TaskScope = tab == .backlog ? .backlog : .tasks
        // The view (item 6): each state's tasks filtered and ordered, the
        // states in their order. Find shows the open tasks whose title
        // matches (the finished ones are Done's to find). Work done only
        // when the rows are rebuilt (the cache's key holds the view).
        let view = viewOptions(for: tab)
        let query = trimmedQuery(for: tab)
        // The picked tags (owner, 2026-10-28; several since 13 Nov): only
        // their tasks, with the view and the search (all must match).
        let picks = tagPicks(on: tab)
        let day = today
        let sections = store.snapshot(for: scope).sections
        // The tab's tasks as they will settle: the snapshot with the
        // acknowledged command applied (ack-latency-2). The first frame
        // goes through the same filters below as settled data, so it shows
        // the rows the settled snapshot will. A moved row is eligible on
        // its destination tab at once; a delete is absent until the
        // transaction saves or rolls back.
        var universe = sections.flatMap(\.tasks)
        let projecting = !acknowledgedRows.isEmpty || !acknowledgedDeleted.isEmpty || !acknowledgedCreated.isEmpty
        if projecting {
            universe = universe.filter { !acknowledgedDeleted.contains($0.id) }.map { acknowledgedRows[$0.id] ?? $0 }
            let already = Set(universe.map(\.id))
            let additions = (Array(acknowledgedRows.values) + acknowledgedCreated)
                .filter { !already.contains($0.id) && !acknowledgedDeleted.contains($0.id) }
            universe = (additions + universe).filter { tab == .backlog ? $0.status == .backlog : $0.status != .backlog }
            // A new task, and a task changing state, go first in their
            // state, as the store places them.
            let arriving = Set(acknowledgedCreated.map(\.id)).union(acknowledgedRows.values.filter {
                store.task(withID: $0.id)?.listedStatus != $0.listedStatus
            }.map(\.id))
            universe = Self.inSnapshotOrder(universe, scope: scope, created: arriving)
        }
        // A task the person changed while filtered stays where it is until
        // the view changes (Accepted 2026-11-13, "Changed while filtered"):
        // what this same view showed last time is still shown, and a task
        // "+" is making stays as it will once made (`keepInView`).
        let filtering = query.isEmpty && (view.filters || !picks.isEmpty)
        let stayKey = TasksStayKey(view: view, picks: picks)
        var staying: Set<UUID> = filtering && filterStay[tab]?.key == stayKey ? filterStay[tab]?.ids ?? [] : []
        if filtering { staying.formUnion(acknowledgedCreated.map(\.id)) }
        var tasks: [TaskItem]
        if view.isDefault, query.isEmpty, picks.isEmpty {
            tasks = universe
        } else if !query.isEmpty {
            // Find: the open tasks whose title matches (the finished ones
            // are Done's to find), the picked tags too.
            tasks = view.sorted(universe.filter { $0.status != .done && store.matchesItemSearch($0, query: query) && picks.matches($0.tags) })
        } else {
            tasks = view.sorted(universe.filter {
                (view.includes($0, today: day) && picks.matches($0.tags)) || staying.contains($0.id)
            })
        }
        if filtering {
            filterStay[tab] = (stayKey, Set(tasks.map(\.id)))
            // The view line's "9 hidden": the open tasks this view leaves out.
            let open = universe.filter { $0.status != .done }.count
            filterHidden[tab] = max(0, open - tasks.filter { $0.status != .done }.count)
        } else {
            filterStay[tab] = nil
            filterHidden[tab] = nil
        }
        let holding = held.filter { $0.value.tab == tab }.sorted { $0.value.index < $1.value.index }
        if !holding.isEmpty {
            // A task finished on Later has left the backlog list: the held
            // row is the task as it is now.
            let heldTasks = holding.compactMap { id, _ in tasks.first { $0.id == id } ?? store.task(withID: id) }
            tasks.removeAll { held[$0.id]?.tab == tab }
            for task in heldTasks {
                tasks.insert(task, at: min(held[task.id]?.index ?? 0, tasks.count))
            }
        }
        return tasks.map { rowModel(for: $0, match: query.isEmpty ? nil : query) }
    }

    /// The shared value-only inventory: Notes changes reach the add bar too.
    var cachedTags: [String] { library.tags.names }

    /// Now is empty and Later has tasks: the empty line offers "Choose
    /// from Later" (review 24).
    var offersLater: Bool { !hasDoneToday && backlogCount > 0 }

    var nowCount: Int { store.snapshot(for: .tasks).activeCount }
    var backlogCount: Int { store.snapshot(for: .backlog).visibleCount }
    var hasDoneToday: Bool { store.snapshot(for: .tasks).sections.contains { $0.status == .done } }
    /// "Completed today · N": the done rows no longer held in place.
    var completedTodayCount: Int { sections(for: .now).done.count }

    func toggleCompletedToday() {
        completedTodayExpanded.toggle()
    }

    /// What an empty list says (Direction A): Now with nothing open is
    /// caught up when something was finished today, points to Later when
    /// Later has tasks, and otherwise invites the first task. Every empty
    /// and no-match line is one short sentence with its full stop (U-11).
    var emptyMessage: [TasksTab: String] {
        [
            .now: hasDoneToday ? String(localized: "You’re caught up.")
                : (backlogCount > 0 ? String(localized: "Nothing active.") : String(localized: "Add your first task.")),
            .backlog: String(localized: "Nothing in Backlog.")
        ]
    }

    // MARK: - Done log

    /// The Done page: today's finished tasks (still in Now until the daily
    /// cleanup) and the Done log, grouped by the day they were finished,
    /// newest first; filtered by the search.
    func doneDays() -> [TasksDoneDay] {
        let key = DoneKey(revision: store.revision, loaded: doneLogTasks.map(\.id), search: doneSearch, tag: tagPicks,
                          today: DueDay(date: services.now(), calendar: services.calendar()), dateEnvironment: dateEnvironment,
                          folded: folded(on: .done))
        if let doneCache, doneCache.key == key { return doneCache.days }
        let days = buildDoneDays().map { day in
            let folded = key.folded.contains(day.key)
            return TasksDoneDay(id: day.id, title: day.title, rows: folded ? [] : day.rows, total: day.rows.count, folded: folded)
        }
        doneCache = (key, days)
        return days
    }

    private struct DoneKey: Equatable {
        let revision: UInt64
        let loaded: [UUID]
        let search: String
        let tag: TagPicks
        let today: DueDay
        let dateEnvironment: DatePresentationEnvironment
        let folded: Set<String>
    }

    private var doneCache: (key: DoneKey, days: [TasksDoneDay])?

    /// What a filtered view showed last, per page (`buildRows`).
    private var filterStay: [TasksTab: (key: TasksStayKey, ids: Set<UUID>)] = [:]
    /// How many open tasks a filtered view leaves out, per page.
    private var filterHidden: [TasksTab: Int] = [:]

    /// The view line's hidden count on Now or Backlog (nil: not filtered).
    func filterHiddenCount(for tab: TasksTab) -> Int? {
        guard tab != .done else { return doneFilterHiddenCount() }
        _ = cached(tab)
        return filterHidden[tab]
    }

    /// Done's: the finished tasks (today's and the log's) the picked tags
    /// leave out, from the index (no page is read).
    private func doneFilterHiddenCount() -> Int? {
        let picks = tagPicks
        guard !picks.isEmpty else { return nil }
        let today = store.doneTodayTasks()
        let hiddenToday = today.filter { !picks.matches($0.tags) }.count
        return hiddenToday + max(0, store.indexedDoneLogCount() - store.indexedDoneLogCount(tags: picks))
    }

    /// A task just made or changed on a filtered page stays in view until
    /// the view changes ("+" while filtered; Accepted 2026-11-13).
    func keepInView(_ id: UUID, on tab: TasksTab) {
        guard tab != .done, var stay = filterStay[tab] else { return }
        stay.ids.insert(id)
        filterStay[tab] = stay
        rowsCache[tab] = nil
    }

    /// The view changed for the person (the panel hid, another tab): what
    /// a filter kept in view leaves.
    func releaseFilterStay() {
        guard !filterStay.isEmpty else { return }
        for tab in filterStay.keys { rowsCache[tab] = nil }
        filterStay = [:]
        objectWillChange.send()
    }

    private func buildDoneDays() -> [TasksDoneDay] {
        let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let today = store.doneTodayTasks()
        let picks = tagPicks
        let finished = (today.filter { store.matchesItemSearch($0, query: query) && picks.matches($0.tags) } + doneLogTasks)
        let calendar = services.calendar()
        let now = services.now()
        var days: [TasksDoneDay] = []
        var current: (day: Date, rows: [TasksListRow])?
        for task in finished {
            let day = calendar.startOfDay(for: task.completedAt ?? task.updatedAt)
            var row = rowModel(for: task)
            if !query.isEmpty {
                // The match is highlighted in the title (owner item 17).
                var model = row.model
                model.titleMatch = query
                row = TasksListRow(id: row.id, model: model, status: row.status, subtasks: row.subtasks)
            }
            if current?.day == day {
                current?.rows.append(row)
            } else {
                if let current {
                    days.append(TasksDoneDay(id: current.day, title: TasksPanelDesign.doneDayTitle(
                        current.day, today: now, calendar: calendar, locale: services.locale), rows: current.rows))
                }
                current = (day, [row])
            }
        }
        if let current {
            days.append(TasksDoneDay(id: current.day, title: TasksPanelDesign.doneDayTitle(
                current.day, today: now, calendar: calendar, locale: services.locale), rows: current.rows))
        }
        return days
    }

    /// The Done search's quiet count (owner item 17): how many done tasks
    /// match, of how many there are (today's done group and the Done log).
    /// Nil with no search, or when the log could not be counted.
    func doneSearchCount() -> (matches: Int, total: Int)? {
        let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let key = DoneCountKey(revision: store.revision, query: query, tag: tagPicks)
        if let doneCountCache, doneCountCache.key == key { return doneCountCache.count }
        let tag = tagPicks
        let today = store.doneTodayTasks().filter { tag.matches($0.tags) }
        var count: (matches: Int, total: Int)?
        if doneLogFailure == nil {
            let logMatches = store.indexedDoneLogCount(matching: query, tags: tag)
            let logTotal = store.indexedDoneLogCount(tags: tag)
            count = (today.filter { store.matchesItemSearch($0, query: query) }.count + logMatches, today.count + logTotal)
        }
        doneCountCache = (key, count)
        return count
    }

    private struct DoneCountKey: Equatable {
        let revision: UInt64
        let query: String
        let tag: TagPicks
    }

    private var doneCountCache: (key: DoneCountKey, count: (matches: Int, total: Int)?)?

    /// Loads the Done log's first page for the current search, if the store
    /// or the search changed since.
    func loadDoneLogIfNeeded() {
        let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = tagPicks
        let same = doneLogQuery == query && doneLogTag == tag
        guard !same || doneLogRevision != store.revision else { return }
        let limit = same ? max(Self.doneLogPageSize, doneLogTasks.count) : Self.doneLogPageSize
        let page = IdleLatencyTrace.span("task_done_load") {
            store.indexedDoneLogPage(limit: limit, matching: query, tags: tag)
        }
        IdleLatencyTrace.count("task_done_reads", page.tasks.count)
        if let failure = page.failure {
            // Keep what the page showed for this search; a new search shows
            // what was read. Not marked as loaded, so Retry reads again.
            if !same { setDoneLog(page.tasks) }
            doneLogCursor = page.next
            doneLogHasMore = true
            doneLogFailure = failure
            return
        }
        doneLogQuery = query
        doneLogTag = tag
        doneLogRevision = store.revision
        setDoneLog(page.tasks)
        doneLogCursor = page.next
        doneLogHasMore = page.hasMore
        doneLogFailure = nil
    }

    /// The next page, when the last loaded row comes on screen. The cursor
    /// walks canonical matching IDs, so duplicate replicas never stop it.
    /// A failed read keeps what loaded and stops until Retry.
    func loadMoreDoneLog(limit: Int = doneLogPageSize) {
        guard doneLogHasMore, doneLogFailure == nil else { return }
        let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if doneLogQuery != query || doneLogTag != tagPicks { loadDoneLogIfNeeded(); return }
        if doneLogRevision != store.revision {
            loadDoneLogIfNeeded()
            guard doneLogHasMore, doneLogFailure == nil else { return }
        }
        let page = store.indexedDoneLogPage(from: doneLogCursor, limit: limit, matching: doneLogQuery ?? "", tags: doneLogTag ?? .none)
        doneCountCache = nil
        // The indexed cursor supplies canonical IDs in completion order.
        // Existing families remain valid for this store revision.
        doneLogTasks.append(contentsOf: page.tasks)
        doneLogChildren.merge(store.doneLogSubtasks(ofParents: page.tasks.map(\.id))) { _, new in new }
        doneLogCursor = page.next
        doneLogHasMore = page.hasMore
        doneLogFailure = page.failure
        // Scrolling on reaches a `show` the paging bound held back.
        if !isRevealing, pendingReveal != nil, doneLogFailure == nil { resumePendingReveal() }
    }

    /// While `revealInDoneLog` pages, loading a page does not resume it again.
    private var isRevealing = false

    /// "Couldn't load more · Retry": the same read again, from where it
    /// stopped (or the first page, when that was what failed).
    func retryDoneLog() {
        doneLogFailure = nil
        if doneLogQuery != doneSearch.trimmingCharacters(in: .whitespacesAndNewlines) || doneLogTag != tagPicks
            || doneLogRevision != store.revision {
            loadDoneLogIfNeeded()
        } else {
            loadMoreDoneLog()
        }
        // A `show` the failed read held goes on from here.
        if doneLogFailure == nil { resumePendingReveal() }
    }

    /// Loaded Done log tasks, in the log's order by the replica each shows
    /// (pages are merged, so a divergent copy never splits a day), with
    /// their families read in one go.
    private func setDoneLog(_ tasks: [TaskItem]) {
        doneCountCache = nil
        doneLogTasks = tasks.sorted(by: TaskStore.doneLogOrder)
        doneLogChildren = store.doneLogSubtasks(ofParents: doneLogTasks.map(\.id))
    }

    // MARK: - Tabs

    /// Tasks opens on Now (spec § The shell), except when it was opened to
    /// search or to show a task: then it stays where that put it until the
    /// panel hides. With a memory (the app's panel, L7) it opens on the page
    /// last used, after a relaunch too.
    ///
    /// Unsaved work is never dropped: a title or new subtask that was
    /// changed, or whose save failed, keeps its text and "Not saved ·
    /// Retry", and the page stays where that row is.
    func resetForReveal() {
        isHidden = false
        // The page is on its tab at once, never sliding in (round 10); the
        // pages beside it are built once it is idle (round 11).
        defer {
            showPagerPage(animated: false)
            warmPager()
        }
        if hasUnsavedEdit { return }
        // Assign only what changes: every assignment redraws the page.
        let target = revealTab ?? (memory != nil ? tab : .now)
        pagerSwipe.cancel()
        if tab != target { tab = target }
        if revealTab == nil, !selection.isEmpty { selection = [] }
        if editingTitleID != nil || newSubtaskParentID != nil || renamingSubtaskID != nil { cancelEditing() }
    }

    /// The page shows again after another page (Notes, Canvas) had the
    /// panel: it is where it was, on the tab it was left on (round 12, CU
    /// bug 3: it returned to Now). Only a reveal of the panel starts on Now
    /// (`resetForReveal`).
    /// The tasks with a live note of their own (Phase 3): their rows show
    /// the note glyph, and deleting one says the note is kept (§ 2.7.1).
    @Published private(set) var noteOwners: Set<UUID> = []
    private(set) var noteOwnersRevision: UInt64 = 0

    private var noteOwnersObservation: AnyCancellable?

    func observeNoteOwners(_ owners: AnyPublisher<Set<UUID>, Never>) {
        noteOwnersObservation = owners.receive(on: DispatchQueue.main).sink { [weak self] in self?.setNoteOwners($0) }
    }

    func setNoteOwners(_ owners: Set<UUID>) {
        guard owners != noteOwners else { return }
        noteOwners = owners
        noteOwnersRevision &+= 1
    }

    /// Back from a task's page: the anchor row takes the keyboard again
    /// (UX plan § 5.3). The page observes the count.
    @Published private(set) var returnFocusRequest: UInt64 = 0
    private(set) var returnFocusRow: UUID?

    func requestReturnFocus(_ id: UUID?) {
        guard let id else { return }
        returnFocusRow = id
        returnFocusRequest &+= 1
    }

    func pageDidReturn() {
        isHidden = false
        defer {
            showPagerPage(animated: false)
            warmPager()
        }
        // An editor with nothing changed does not wait behind the page; one
        // holding text keeps it, as a reveal does.
        if !hasUnsavedEdit, editingTitleID != nil || newSubtaskParentID != nil || renamingSubtaskID != nil { cancelEditing() }
    }

    /// A title, new subtask or subtask rename holds text that is not saved:
    /// it was changed, or its save failed.
    var hasUnsavedEdit: Bool {
        switch failedSave {
        case .title?, .newSubtask?: return true
        case .paste?, nil: break
        }
        if let id = editingTitleID, let task = store.listedTask(withID: id), titlePatch(for: task) != nil {
            return true
        }
        if subtaskRenameFailed { return true }
        if let id = renamingSubtaskID, let task = store.task(withID: id) {
            let draft = subtaskRename.trimmingCharacters(in: .whitespacesAndNewlines)
            if !draft.isEmpty, draft != task.title { return true }
        }
        return newSubtaskParentID != nil && !newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    #if DEBUG
    /// Capture seam (`ATTIC_UI_TEST_TASKS_TAB`): open on `tab` for this reveal.
    func openForCapture(_ tab: TasksTab) {
        self.tab = tab
        revealTab = tab
    }
    #endif

    /// Emits whenever no title, new subtask or subtask rename is being
    /// edited: the moment a `show` an unsaved edit blocked can run again
    /// (round 10b: a rename's Retry or Esc counts, as the older editors').
    var editorsIdle: AnyPublisher<Void, Never> {
        Publishers.CombineLatest3($editingTitleID, $newSubtaskParentID, $renamingSubtaskID)
            .filter { title, subtask, renaming in title == nil && subtask == nil && renaming == nil }
            .map { _, _, _ in () }
            .eraseToAnyPublisher()
    }

    /// Where the current reveal opened the page (Search, an agent's `show`);
    /// nil opens on Now. Cleared when the panel hides or the person moves.
    private var revealTab: TasksTab?

    /// The panel hid: the next reveal opens on Now again, and the page
    /// ends a drag or an open row picker (`hides` changes).
    func pageDidHide() {
        revealTab = nil
        releaseFilterStay()
        isHidden = true
        suspendPager()
        hides &+= 1
    }

    /// Counts the panel's hides, for the page's own transient state.
    @Published private(set) var hides = 0

    // MARK: - A failed change, where it was made (review 6)

    /// A change to a row (its circle, a subtask's box, a delete, a move)
    /// that did not save: "Not saved · Retry" under that row, with the
    /// store's own sentence when retrying can't help.
    struct RowFailure: Equatable {
        let id: UUID
        let message: String
        let canRetry: Bool
        let token = UUID()
    }

    @Published private(set) var rowFailure: RowFailure?
    private var rowRetry: (() -> CommandOutcome)?

    /// Shows `outcome` under row `id` when it failed (and clears that row's
    /// earlier failure when it applied). Returns the outcome. The stored retry
    /// must capture the model weakly and keep only the command's value inputs.
    @discardableResult
    func report(_ outcome: CommandOutcome, on id: UUID, retry: @escaping () -> CommandOutcome) -> CommandOutcome {
        if let failure = outcome.failure {
            rowFailure = RowFailure(id: id, message: failure.message, canRetry: failure.canRetry)
            rowRetry = failure.canRetry ? retry : nil
            AtticSounds.play(.failed)
        } else if rowFailure?.id == id {
            rowFailure = nil
            rowRetry = nil
        }
        return outcome
    }

    func retryRowFailure() {
        guard let failure = rowFailure, let retry = rowRetry else { dismissRowFailure(); return }
        report(retry(), on: failure.id, retry: retry)
    }

    func dismissRowFailure() {
        rowFailure = nil
        rowRetry = nil
    }

    /// A change made in an open picker (a row's date or tag list) that did
    /// not save: the picker stays open with what was chosen and shows
    /// "Not saved · Retry" inside itself (round 4).
    @Published private(set) var pickerFailure: RowFailure?
    private var pickerRetry: (() -> CommandOutcome)?
    /// What the picker finishes when a retried change saves (a new tag's
    /// typed name is cleared, as a first-time save clears it).
    private var pickerRetrySaved: (() -> Void)?

    /// Runs a picker's change; true when it saved (the caller may close
    /// or finish its input). `onSaved` runs if a later Retry saves it.
    @discardableResult
    func pickerChange(on id: UUID, onSaved: (() -> Void)? = nil, _ change: @escaping () -> CommandOutcome) -> Bool {
        pickerResult(change(), on: id, onSaved: onSaved, retry: change)
    }

    /// A picker shows the new value immediately, but keeps its Retry route
    /// until the deferred family transaction has actually settled.
    @discardableResult
    func pickerResult(_ outcome: CommandOutcome, on id: UUID, onSaved: (() -> Void)? = nil,
                      retry: @escaping () -> CommandOutcome) -> Bool {
        if let failure = outcome.failure {
            pickerFailure = RowFailure(id: id, message: failure.message, canRetry: failure.canRetry)
            pickerRetry = failure.canRetry ? retry : nil
            pickerRetrySaved = failure.canRetry ? onSaved : nil
            AtticSounds.play(.failed)
            return false
        }
        clearPickerFailure()
        return true
    }

    /// Retry in the picker; true when it saved, and then the input the
    /// failed change left pending is finished (round 5, F5).
    @discardableResult
    func retryPickerChange() -> Bool {
        guard let failure = pickerFailure, let retry = pickerRetry else { clearPickerFailure(); return false }
        let saved = pickerRetrySaved
        guard pickerChange(on: failure.id, onSaved: saved, retry) else { return false }
        saved?()
        return true
    }

    func clearPickerFailure() {
        pickerFailure = nil
        pickerRetry = nil
        pickerRetrySaved = nil
    }

    /// The pager's swipe (owner items 21, 22, 24 and 25; round 9: the page
    /// owns the gesture, `TasksPager.swift`). Every explicit way of
    /// choosing a page (a tab, a key, `show`, Search, a reveal) cancels a
    /// swipe in progress, even when it chooses the page already shown
    /// (round 7, R5).
    let pagerSwipe = TasksPagerSwipe(count: TasksTab.allCases.count)

    /// What the rows of a drawn page observe (round 11): every change to
    /// this model. A page kept built but not drawn gives its rows
    /// `TasksCellUpdates.quiet` instead, so they do no work until it is
    /// drawn (or its own rows change, which redraws the page).
    lazy var cellUpdates: TasksCellUpdates = {
        let updates = TasksCellUpdates()
        objectWillChange
            .sink { [weak updates] _ in updates?.objectWillChange.send() }
            .store(in: &cancellables)
        return updates
    }()

    /// Whether the shell shows the Tasks page (not kept built behind Notes
    /// or Canvas): only then does it answer page shortcuts such as ⌘F
    /// (round 7, R2).
    /// Where the page's rows are, for the agent chat's motion. It reads the
    /// frames the list already measures, so a row's body does no more work.
    weak var rowPointer: TasksPointer?

    @Published var isPageShown = true {
        didSet {
            guard isPageShown != oldValue else { return }
            // Left for Notes or Canvas: the pager lets go (round 10); back
            // on Tasks, the page is on its tab without travel.
            if isPageShown {
                showPagerPage(animated: false)
                warmPager()
            } else {
                suspendPager()
            }
        }
    }

    /// The panel is hidden (between `pageDidHide` and the next reveal).
    private(set) var isHidden = false

    /// Moving to another page saves an open edit first; if that save
    /// fails, the page stays with the text and Retry (Esc discards it).
    /// `bySwipe`: a swipe's own choice, live as its page crosses halfway
    /// (it cancels nothing).
    func select(tab: TasksTab, bySwipe: Bool = false) {
        if !bySwipe { pagerSwipe.cancel() }
        guard tab != self.tab else { return }
        guard IdleLatencyTrace.span("task_finish_editing", { finishEditing() }) else { return }
        revealTab = nil
        // The person went elsewhere: a `show` still waiting for its Done log
        // page is dropped, never finished later by a scroll (round 5, F3).
        pendingReveal = nil
        if !selection.isEmpty { selection = [] }
        if !bySwipe { PerformanceSignposts.beginPageChoice() }
        // Another page is another view: what a filter kept in view leaves.
        releaseFilterStay()
        self.tab = tab
        IdleLatencyTrace.point("task_tab_selected")
    }

    /// One "finish or keep the current edit" for every way out of it
    /// (review 2): a title or new subtask with changes is saved; a failed
    /// save keeps the editor, its text and "Not saved · Retry", and the
    /// caller stays put (returns false). Nothing typed is ever dropped
    /// here; Esc in the field is the only discard.
    @discardableResult
    func finishEditing() -> Bool {
        guard commitSubtaskRename() else { return false }
        if hasUnsavedEdit {
            guard commitTitle(), commitNewSubtask() else { return false }
        }
        cancelEditing()
        return true
    }

    /// Search (the menu-bar item): the Done page, with the keyboard in the
    /// search field at the top of its list.
    func beginSearch() {
        pagerSwipe.cancel()
        guard finishEditing() else { return }
        selection = []
        tab = .done
        revealTab = .done
        pendingSearchFocus = true
    }

    /// What became of a `show` request.
    enum ShowOutcome: Equatable {
        /// The row is selected, scrolled to and given the keyboard.
        case shown
        /// Its Done log page could not be read yet (a failed read, or the
        /// paging bound): the page holds the request and finishes it when
        /// that page loads (Retry, or scrolling on) (round 5, F3).
        case pending
        /// An edit that can't be saved kept the page where it is: the
        /// caller keeps the request and asks again (review 2).
        case blocked
        /// No list shows the task.
        case missing
    }

    /// An agent's `show` of a task: the tab that lists it, the row selected,
    /// scrolled into view and focused.
    @discardableResult
    func show(_ id: UUID) -> ShowOutcome {
        guard let found = store.listedTask(withID: id) else { return .missing }
        pagerSwipe.cancel()
        // A subtask shows in its parent's quick look (live) or its parent's
        // details (in the Done log).
        let parent = found.parentID.flatMap { store.listedTask(withID: $0) }
        let task = parent ?? found
        let archived = store.task(withID: task.id) == nil
        // The owner's panel design: a task finished today lives in Done too.
        let finishedToday = !archived && task.status == .done && held[task.id] == nil
        let target: TasksTab = task.listedStatus == .backlog ? .backlog : (archived || finishedToday ? .done : .now)
        // An edit that can't be saved keeps the page where it is: the
        // request is deferred (review 2) and the caller keeps it.
        guard finishEditing() else { return .blocked }
        pendingReveal = nil
        tab = target
        revealTab = target
        // Establish what the destination needs before revealing it (round
        // 4): an open Completed today, no Done search that hides it, its
        // page of the Done log loaded, its parent's quick look or details.
        if target == .now, task.status == .done { completedTodayExpanded = true }
        if target == .done, finishedToday {
            if doneSearch != doneSearchInput.text { doneSearch = doneSearchInput.text }
            let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty, !task.title.localizedStandardContains(query) { doneSearch = "" }
            if !tagPicks.matches(task.tags) { tagPicks = .none }
            if parent != nil { doneDetailID = task.id }
            unfoldDoneDay(of: task.id)
        } else if target == .done {
            if doneSearch != doneSearchInput.text { doneSearch = doneSearchInput.text }
            let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty, !store.matchesItemSearch(task, query: query) { doneSearch = "" }
            if !tagPicks.matches(task.tags) { tagPicks = .none }
            if parent != nil { doneDetailID = task.id }
            guard revealInDoneLog(task.id) else {
                // Not loaded: nothing is selected or scrolled to until it is.
                selection = []
                pendingReveal = task.id
                return .pending
            }
        } else if parent != nil {
            expanded.insert(task.id)
        }
        // A view or a Find that hides the task gives way (item 6): its
        // filters and query go, its order stays.
        if target != .done, !rows(for: target).contains(where: { $0.id == task.id }) {
            setSearchQuery("", for: target)
            showAll(on: target)
        }
        // A folded date group opens to show it (the owner's panel design).
        if target != .done, let key = groupKey(of: task.id, on: target), folded(on: target).contains(key) {
            toggleGroup(key, on: target)
        }
        if target == .done { unfoldDoneDay(of: task.id) }
        reveal(task.id)
        return .shown
    }

    /// Opens the folded Done day that holds `id` (a `show`).
    private func unfoldDoneDay(of id: UUID) {
        guard !folded(on: .done).isEmpty,
              let task = store.listedTask(withID: id), let finished = task.completedAt ?? Optional(task.updatedAt) else { return }
        let key = TasksPanelDesign.GroupKind.finished(services.calendar().startOfDay(for: finished)).key
        if folded(on: .done).contains(key) { toggleGroup(key, on: .done) }
    }

    private func reveal(_ id: UUID) {
        pendingReveal = nil
        selectOnly(id)
        scrollRequest = ScrollRequest(id: id, tab: tab)
    }

    /// How far an explicit reveal reads into the Done log: 16,080 rows, the
    /// reach it had with 80-row pages (the first page and 200 more). It is
    /// counted in rows, so the browsing page size never shortens it
    /// (GPT-6.1's PR prep review, P3: 40-row pages halved it to 8,040).
    static let doneRevealReach = 80 + 200 * 80
    /// Keep the established reveal page boundary when seeking directly.
    static let doneRevealStep = 80

    /// Loads the Done log until `id`'s page is in, and says whether it is.
    /// A failed read or the reach (`doneRevealReach` rows) is an incomplete
    /// result, never taken for success.
    private func revealInDoneLog(_ id: UUID) -> Bool {
        isRevealing = true
        defer { isRevealing = false }
        loadDoneLogIfNeeded()
        if !doneLogTasks.contains(where: { $0.id == id }), doneLogHasMore, doneLogFailure == nil,
           doneLogTasks.count < Self.doneRevealReach {
            let offset = store.indexedDoneLogOffset(of: id, matching: doneLogQuery ?? "", tags: doneLogTag ?? .none) ?? (Self.doneRevealReach - 1)
            let remaining = max(0, offset + 1 - doneLogTasks.count)
            let pages = max(1, (remaining + Self.doneRevealStep - 1) / Self.doneRevealStep)
            loadMoreDoneLog(limit: min(pages * Self.doneRevealStep, Self.doneRevealReach - doneLogTasks.count))
        }
        return doneLogTasks.contains { $0.id == id }
    }

    /// A `show` whose Done log page had not loaded (round 5, F3).
    private(set) var pendingReveal: UUID?

    /// A Done log page loaded: a pending `show` whose task it holds is
    /// finished now; one still out of reach keeps paging towards it.
    private func resumePendingReveal() {
        guard let id = pendingReveal else { return }
        guard store.listedTask(withID: id) != nil, tab == .done else {
            pendingReveal = nil
            return
        }
        guard revealInDoneLog(id) else { return }
        reveal(id)
    }

    /// A row to bring into view (an agent's `show`); each request is new.
    struct ScrollRequest: Equatable {
        let id: UUID
        /// The page the request is for: a task can be listed by two pages
        /// (Now's kept "Completed today" and Done), and only the destination's
        /// list acts on it (round 12).
        var tab: TasksTab?
        let token = UUID()
    }

    @Published private(set) var scrollRequest: ScrollRequest?

    /// The last `scrollRequest` a list acted on. A list built after the
    /// request (a page that was not on screen when `show` chose it) acts on
    /// it as it appears, once (round 10, Astra's round 9 check).
    private var handledScrollToken: UUID?

    /// Takes the current scroll request for a list holding `ids`, once:
    /// the request, or nil when there is none, it was acted on, or the
    /// list does not hold its row.
    func claimScrollRequest(holding ids: some Collection<UUID>, in tab: TasksTab) -> ScrollRequest? {
        guard let request = scrollRequest, request.token != handledScrollToken, ids.contains(request.id),
              request.tab == nil || request.tab == tab else { return nil }
        handledScrollToken = request.token
        // The reveal wins over the list's remembered place.
        scrollOffsets[tab] = nil
        return request
    }

    /// Each list's scroll position while it is not on screen (its page is
    /// not built then): restored when it is built again (round 10). Not
    /// published: saving it redraws nothing.
    var scrollOffsets: [TasksTab: CGFloat] = [:] {
        didSet { memory?.saveScrollOffsets(scrollOffsets) }
    }

    // MARK: - Selection

    /// A click: ⌘ toggles, ⇧ extends from the last clicked row, otherwise
    /// the row alone is selected.
    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags, visible: [UUID]) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor,
                  let from = visible.firstIndex(of: anchor), let to = visible.firstIndex(of: id) {
            selection = Set(visible[min(from, to)...max(from, to)])
        } else {
            selection = [id]
            selectionAnchor = id
        }
    }

    func selectOnly(_ id: UUID?) {
        selection = id.map { [$0] } ?? []
        selectionAnchor = id
    }

    /// ⇧↑ ⇧↓: grow the selection from the anchor to `id`. `current` is the
    /// row the keyboard is on. The anchor holds only while it is a visible
    /// row of the selection; when it is not (a delete removed it, the
    /// selection came from a menu, a restore), or the selection is one row,
    /// it is the keyboard's row, never a row remembered from before
    /// (round 12, CU bug 2: an old anchor grew a selection of eleven).
    func extendSelection(to id: UUID, visible: [UUID], from current: UUID? = nil) {
        var anchor = selectionAnchor
        if let held = anchor, !(selection.contains(held) && visible.contains(held)) { anchor = nil }
        if selection.count <= 1 { anchor = selection.first.flatMap { visible.contains($0) ? $0 : nil } ?? current }
        let start = anchor ?? current ?? id
        selectionAnchor = start
        guard let from = visible.firstIndex(of: start), let to = visible.firstIndex(of: id) else { return }
        selection = Set(visible[min(from, to)...max(from, to)])
    }

    /// The anchor of the current selection (tests).
    var selectionAnchorForTesting: UUID? { selectionAnchor }

    func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

    /// Duplicate's copies become the selection (round 10).
    func selectCopies(_ ids: [UUID]) {
        selection = Set(ids)
        selectionAnchor = ids.first
    }

    /// What a key or menu command on `id` acts on: the whole selection when
    /// the row is part of a multi-selection, otherwise the row.
    func targets(for id: UUID) -> [UUID] {
        selection.count > 1 && selection.contains(id) ? orderedSelection() : [id]
    }

    /// The row ⌘C, ⌘D and ⇧⌘I act on: the focused row, else the first
    /// selected. While a subtask line has the keyboard there is none (round
    /// 10b): the parent is selected, but the key is not about it.
    func shortcutRow(focusedRow: UUID?, visible: Set<UUID>) -> UUID? {
        guard focusedSubtaskID == nil else { return nil }
        return (focusedRow ?? orderedSelection().first).flatMap { visible.contains($0) ? $0 : nil }
    }

    func orderedSelection() -> [UUID] {
        // In list order: the Done page's is its days' rows (round 6: a
        // restore of a selection there keeps the log's order).
        let visible = tab == .done ? doneDays().flatMap { $0.rows.map(\.id) } : rows(for: tab).map(\.id)
        return visible.filter(selection.contains) + selection.subtracting(visible).sorted { $0.uuidString < $1.uuidString }
    }

    private func pruneMissing() {
        pruneTagPicks()
        let live = { (id: UUID) in
            self.tab == .done ? self.store.listedTask(withID: id) != nil : self.store.task(withID: id) != nil
        }
        let keptSelection = selection.filter(live)
        if keptSelection != selection { selection = keptSelection }
        if let anchor = selectionAnchor, !live(anchor) { selectionAnchor = nil }
        // Check logical ownership, not the anchor's one-/two-line view
        // lifetime. Done-log rows remain valid while they are listed.
        func hasRow(_ id: UUID) -> Bool {
            guard live(id) else { return false }
            // Done reloads its paged projection asynchronously. An empty
            // intermediate page is not evidence that a listed task vanished.
            if tab == .done { return store.listedTask(withID: id)?.status == .done }
            return rows(for: tab).contains { $0.id == id }
        }
        if let editingTitleID, !hasRow(editingTitleID) { cancelEditing() }
        if let newSubtaskParentID, !hasRow(newSubtaskParentID) { cancelEditing() }
        if let id = renamingSubtaskID {
            let parent = store.task(withID: id)?.parentID
            let hasOwner = parent.map { $0 == renamingSubtaskParentID && hasRow($0) } ?? false
            if !hasOwner { cancelSubtaskRename() }
        }
    }

    // MARK: - State changes

    /// The page's immediate, read-only projection of a pending command.
    /// Durable edits and Undo still go through the original command layer,
    /// after a chance to paint. A second command forces settlement first.
    private static func acknowledgementCopy(_ task: TaskItem) -> TaskItem {
        let copy = TaskItem(id: task.id, title: task.title, status: task.status, priority: task.priority,
                            createdAt: task.createdAt, updatedAt: task.updatedAt,
                            completedAt: task.completedAt, manualOrder: task.manualOrder, parentID: task.parentID)
        copy.tagsRaw = task.tagsRaw
        copy.dueDayRaw = task.dueDayRaw
        copy.dueTimeMinutesRaw = task.dueTimeMinutesRaw
        copy.imageReferencesData = task.imageReferencesData
        copy.doneLoggedAt = task.doneLoggedAt
        copy.completedFromRaw = task.completedFromRaw
        copy.completedFromOrder = task.completedFromOrder
        copy.listOrderVersion = task.listOrderVersion
        return copy
    }

    func acknowledgeCommand(_ ids: [UUID], deleting: Bool = false,
                            preview: (TaskItem) -> Void = { _ in },
                            command: @escaping () -> CommandOutcome,
                            settled: @escaping (CommandOutcome) -> Void) {
        settlePendingCompletionAcknowledgements()
        var proposed: [UUID: TaskItem] = [:]
        for task in ids.compactMap({ store.listedTask(withID: $0) }) {
            let copy = Self.acknowledgementCopy(task)
            preview(copy)
            proposed[task.id] = copy
        }
        guard !proposed.isEmpty else { settled(command()); return }
        if deleting { acknowledgedDeleted = Set(proposed.keys) }
        else { acknowledgedRows = proposed }
        acknowledgementRevision &+= 1
        let token = UUID()
        acknowledgedTaskToken = token
        acknowledgedTaskCommand = { [self] in
            let outcome = command()
            acknowledgedRows = [:]
            acknowledgedDeleted = []
            acknowledgementRevision &+= 1
            if !outcome.isApplied { ids.forEach(cancelHold) }
            settled(outcome)
            return outcome.isApplied
        }
        Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(20))
            if acknowledgedTaskToken == token { _ = settlePendingTaskAcknowledgement() }
        }
    }

    @discardableResult
    private func settlePendingTaskAcknowledgement() -> Bool {
        guard let command = acknowledgedTaskCommand else { return false }
        acknowledgedTaskCommand = nil
        acknowledgedTaskToken = nil
        return command()
    }

    func setStatusAcknowledged(_ status: TaskStatus, for ids: [UUID],
                               settled: @escaping (CommandOutcome) -> Void) {
        _ = settlePendingTaskAcknowledgement()
        if status == .done, tab != .done {
            let visible = rows(for: tab)
            for id in ids {
                if let index = visible.firstIndex(where: { $0.id == id }) { hold(id, tab: tab, at: index) }
            }
        }
        acknowledgeCommand(ids, preview: { $0.status = status },
                           command: { [self] in setStatus(status, for: ids) }, settled: settled)
    }

    func toggleDoneAcknowledged(_ ids: [UUID], settled: @escaping (CommandOutcome) -> Void) {
        _ = settlePendingTaskAcknowledgement()
        let tasks = ids.compactMap { store.listedTask(withID: $0) }
        let reopening = !tasks.isEmpty && tasks.allSatisfy { $0.status == .done }
        if !reopening, tab != .done {
            let visible = rows(for: tab)
            for id in ids {
                if let index = visible.firstIndex(where: { $0.id == id }) { hold(id, tab: tab, at: index) }
            }
        }
        acknowledgeCommand(ids, preview: { task in
            task.status = reopening
                ? (TaskStatus(rawValue: task.completedFromRaw ?? "") ?? .todo) : .done
        }, command: { [self] in toggleDone(ids) }, settled: settled)
    }

    func moveToBacklogAcknowledged(_ ids: [UUID], settled: @escaping (CommandOutcome) -> Void) {
        acknowledgeCommand(ids, preview: { $0.status = .backlog },
                           command: { [self] in moveToBacklog(ids) }, settled: settled)
    }

    func moveToNowAcknowledged(_ ids: [UUID], settled: @escaping (CommandOutcome) -> Void) {
        acknowledgeCommand(ids, preview: { $0.status = .todo },
                           command: { [self] in moveToNow(ids) }, settled: settled)
    }

    func restoreToNowAcknowledged(_ ids: [UUID], settled: @escaping (CommandOutcome) -> Void) {
        acknowledgeCommand(ids, preview: { $0.status = .todo },
                           command: { [self] in restoreToNow(ids) }, settled: settled)
    }

    func setPriorityAcknowledged(_ priority: TaskPriority, for ids: [UUID],
                                 settled: @escaping (CommandOutcome) -> Void) {
        acknowledgeCommand(ids, preview: { $0.priority = priority },
                           command: { [self] in setPriority(priority, for: ids) }, settled: settled)
    }

    func setDueDayAcknowledged(_ day: DueDay?, for ids: [UUID],
                               settled: @escaping (CommandOutcome) -> Void) {
        acknowledgeCommand(ids, preview: { $0.dueDay = day },
                           command: { [self] in setDueDay(day, for: ids) }, settled: settled)
    }

    func toggleTagAcknowledged(_ tag: String, for ids: [UUID],
                               settled: @escaping (CommandOutcome) -> Void) {
        let removing = tagState(tag, for: ids) == .on
        acknowledgeCommand(ids, preview: { task in
            if removing { task.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            else if !task.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                task.tags.append(tag)
            }
        }, command: { [self] in toggleTag(tag, for: ids) }, settled: settled)
    }

    func deleteAcknowledged(_ ids: [UUID], settled: @escaping (CommandOutcome) -> Void) {
        acknowledgeCommand(ids, deleting: true, command: { [self] in delete(ids) }, settled: settled)
    }

    func toggleWorkingAcknowledged(_ ids: [UUID], settled: @escaping (CommandOutcome) -> Void) {
        _ = settlePendingTaskAcknowledgement()
        let tasks = ids.compactMap { store.task(withID: $0) }
        let target: TaskStatus = !tasks.isEmpty && tasks.allSatisfy { $0.status == .inProgress } ? .todo : .inProgress
        acknowledgeCommand(ids, preview: { $0.status = target },
                           command: { [self] in toggleWorking(ids) }, settled: settled)
    }

    /// The title field leaves the list immediately. Its original text and
    /// chips are restored before the transaction; a failed save reopens the
    /// editor with exactly what was submitted and its existing Retry line.
    func commitTitleAcknowledged(settled: @escaping (Bool) -> Void = { _ in }) -> Bool {
        _ = settlePendingTaskAcknowledgement()
        guard let id = editingTitleID, let task = store.listedTask(withID: id),
              let patch = titlePatch(for: task) else { return commitTitle() }
        let input = titleEdit
        editingTitleID = nil
        acknowledgeCommand([id], preview: { task in
            if let title = patch.title { task.title = title }
            if let priority = patch.priority { task.priority = priority }
            if let tags = patch.tags { task.tags = tags }
            if let day = patch.dueDay { task.dueDay = day }
            if let time = patch.dueTimeMinutes { task.dueTimeMinutes = time }
        }, command: { [self] in
            editingTitleID = id
            titleEdit = input
            return commitTitle() ? .applied : .failed(CommandFailure(library.lastErrorMessage ?? "Couldn’t save the title."))
        }, settled: { outcome in settled(outcome.isApplied) })
        return true
    }

    /// Composer creation has a stable logical UUID during the optimistic
    /// frame and its eventual all-or-nothing task+writing save. The preview
    /// never enters the physical store or Undo history.
    @discardableResult
    func createAcknowledged(_ draft: TaskDraft, save: @escaping (UUID) -> TaskItem?,
                            settled: @escaping (TaskItem?) -> Void) -> UUID {
        settlePendingCompletionAcknowledgements()
        let id = UUID()
        let copy = TaskItem(id: id, title: draft.title, status: draft.status, priority: draft.priority)
        copy.tags = draft.tags
        copy.dueDay = draft.dueDay
        copy.dueTimeMinutes = draft.dueTimeMinutes
        acknowledgedCreated = [copy]
        acknowledgementRevision &+= 1
        let token = UUID()
        acknowledgedTaskToken = token
        acknowledgedTaskCommand = { [self] in
            let created = save(id)
            acknowledgedCreated = []
            acknowledgementRevision &+= 1
            settled(created)
            return created != nil
        }
        Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(20))
            if acknowledgedTaskToken == token { _ = settlePendingTaskAcknowledgement() }
        }
        return id
    }

    /// The circle's click and Space (Direction A: one-click completion):
    /// an open task (to do, in progress or Later) is done; a done task goes
    /// back to what it was.
    @discardableResult
    func toggleDone(_ id: UUID) -> CommandOutcome {
        IdleLatencyTrace.span("task_toggle") {
            settlePendingCompletionAcknowledgements()
            guard let task = store.listedTask(withID: id) else { return .failed(.taskGone) }
            return task.status == .done ? reopen(id) : complete(id)
        }
    }

    /// The right-click menu on several tasks: all done, or (when all are
    /// done already) all back, each as one step.
    @discardableResult
    func toggleDone(_ ids: [UUID]) -> CommandOutcome {
        IdleLatencyTrace.span("task_toggle") {
            settlePendingCompletionAcknowledgements()
            let tasks = ids.compactMap { store.listedTask(withID: $0) }
            let reopeningAll = !tasks.isEmpty && tasks.allSatisfy { $0.status == .done }
            let outcome: CommandOutcome
            if reopeningAll {
                outcome = tasks.count == 1 ? reopen(tasks[0].id) : AtticSounds.play(.undone, after: library.reopenTasks(tasks.map(\.id)))
            } else if ids.count == 1 {
                outcome = complete(ids[0])
            } else {
                outcome = AtticSounds.play(.done, after: library.updateTasks(tasks.filter { $0.status != .done }.map(\.id), status: .done))
            }
            if outcome.isApplied {
                if reopeningAll && tasks.count > 1 {
                    for task in tasks { cancelHold(task.id) }
                    reloadDoneLogAfterChange()
                }
                pruneInvisibleSelection(on: tab)
            }
            return outcome
        }
    }

    /// ⇧Space and the right-click menu: start working on the tasks (the
    /// circle's centre dot), or stop when every one is already started.
    @discardableResult
    func toggleWorking(_ ids: [UUID]) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        let tasks = ids.compactMap { store.task(withID: $0) }
        guard !tasks.isEmpty else { return ids.isEmpty ? .applied : .failed(.taskGone) }
        let target: TaskStatus = tasks.allSatisfy { $0.status == .inProgress } ? .todo : .inProgress
        return setStatus(target, for: tasks.map(\.id))
    }

    /// Done in one step, with any open subtasks. The row holds its place
    /// for about a second, then slides into "Completed today". The store
    /// records where the task was finished from, in the same save.
    @discardableResult
    func complete(_ id: UUID) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        guard let task = store.task(withID: id) else { return .failed(.taskGone) }
        guard task.status != .done else { return .applied }
        let holdTab: TasksTab? = tab == .done ? nil : tab
        let index = holdTab.flatMap { holdTab in rows(for: holdTab).firstIndex { $0.id == id } }
        if let holdTab, let index { hold(id, tab: holdTab, at: index) }
        return finishCompletion(id)
    }

    /// Row/keyboard acknowledgement: give AppKit a frame opportunity before
    /// the synchronous, duplicate-safe family transaction. Other callers keep
    /// complete(_:) and its immediate CommandOutcome/Undo semantics.
    func completionAcknowledgementPending(for id: UUID) -> Bool {
        completingAfterAcknowledgement.contains(where: { $0.id == id })
    }

    func completeAcknowledged(_ id: UUID, settled: @escaping (CommandOutcome) -> Void) {
        guard let task = store.task(withID: id) else { settled(.failed(.taskGone)); return }
        guard task.status != .done else { settled(.applied); return }
        guard !completingAfterAcknowledgement.contains(where: { $0.id == id }) else { return }
        let holdTab: TasksTab? = tab == .done ? nil : tab
        let index = holdTab.flatMap { rows(for: $0).firstIndex { $0.id == id } }
        if let holdTab, let index { hold(id, tab: holdTab, at: index) }
        completingAfterAcknowledgement.append((id, settled))
        Task { @MainActor [self] in
            // The next main-queue callback is not necessarily a drawn frame.
            // Allow at least one display interval before the blocking save.
            try? await Task.sleep(for: .milliseconds(20))
            guard completingAfterAcknowledgement.contains(where: { $0.id == id }) else { return }
            settlePendingCompletionAcknowledgements(through: id)
        }
    }

    /// Serialize acknowledged clicks with the next command's Undo history.
    /// An immediate Undo or a following edit must not jump past a tick whose
    /// durable completion has not yet entered the history. A scheduled task
    /// for an already-settled click has no remaining work to do.
    @discardableResult
    func settlePendingCompletionAcknowledgements(through id: UUID? = nil) -> Bool {
        var savedAny = settlePendingTaskAcknowledgement()
        while !completingAfterAcknowledgement.isEmpty {
            let next = completingAfterAcknowledgement.removeFirst()
            let outcome = finishCompletion(next.id)
            savedAny = savedAny || outcome.isApplied
            next.settled(outcome)
            if next.id == id { break }
        }
        return savedAny
    }

    private func finishCompletion(_ id: UUID) -> CommandOutcome {
        let outcome = AtticSounds.play(.done, after: library.completeTask(id))
        if !outcome.isApplied { cancelHold(id) }
        return outcome
    }

    /// A done task back to what it was before the circle finished it
    /// (Astra 20): the state and place the store recorded when it was
    /// finished, with the subtasks finished along with it, whatever the undo
    /// history holds and across relaunches (to do when unknown). A Done log
    /// task comes back with its family.
    @discardableResult
    func reopen(_ id: UUID) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        let outcome = AtticSounds.play(.undone, after: library.reopenTasks([id]))
        if outcome.isApplied {
            cancelHold(id)
            reloadDoneLogAfterChange()
            pruneInvisibleSelection(on: tab)
        }
        return outcome
    }

    /// The Done log's loaded pages after a change to a task in it.
    func reloadDoneLogAfterEdit() {
        doneLogRevision = nil
        loadDoneLogIfNeeded()
    }

    /// Whether an edit to `ids` touched the Done log's loaded tasks.
    func reachesDoneLogAfterEdit(_ ids: [UUID]) -> Bool {
        ids.contains { id in doneLogTasks.contains { $0.id == id } }
    }

    /// The Done log's loaded pages after a task left it.
    private func reloadDoneLogAfterChange() {
        guard doneLogQuery != nil else { return }
        doneLogRevision = nil
        loadDoneLogIfNeeded()
    }

    private func cancelHold(_ id: UUID) {
        holdTasks[id]?.cancel()
        holdTasks[id] = nil
        held[id] = nil
    }

    private func hold(_ id: UUID, tab: TasksTab, at index: Int) {
        held[id] = HeldPlace(tab: tab, index: index)
        holdTasks[id]?.cancel()
        let delay = services.doneHold
        holdTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.releaseHold(id)
        }
    }

    func releaseHold(_ id: UUID) {
        holdTasks[id] = nil
        guard let place = held[id] else { return }
        // Reduce Motion: no travel at all (review 22); a shorter slide is
        // still a slide.
        let reduceMotion = AtticMotionPreference.reducesMotion
        withAnimation(reduceMotion ? AtticMotionScale.reducedChange : AtticMotionPreset.doneSlide.animation(reduceMotion: false)) {
            _ = held.removeValue(forKey: id)
        }
        pruneInvisibleSelection(on: place.tab)
    }

    @discardableResult
    func setStatus(_ status: TaskStatus, for ids: [UUID]) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        if status == .done {
            let outcome = ids.count == 1 ? complete(ids[0]) : AtticSounds.play(.done, after: library.updateTasks(ids, status: .done))
            if outcome.isApplied { pruneInvisibleSelection(on: tab) }
            return outcome
        }
        let loggedOrDone = ids.filter { store.task(withID: $0)?.status == .done || store.task(withID: $0) == nil }
        if loggedOrDone == ids, status == .todo {
            return restoreToNow(ids)
        }
        if ids.count == 1 {
            let outcome = library.updateTask(ids[0], status: status, allowingUnfinishedSubtasks: true)
            if outcome.isApplied { pruneInvisibleSelection(on: tab) }
            return outcome
        }
        let outcome = library.updateTasks(ids, status: status)
        if outcome.isApplied { pruneInvisibleSelection(on: tab) }
        return outcome
    }

    /// Priority from the menu or the selection bar: one step, and an Undo
    /// toast once it saved (owner fix 5: every change to existing tasks has
    /// one). Nothing to change is not a change.
    @discardableResult
    func setPriority(_ priority: TaskPriority, for ids: [UUID]) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        let changing = ids.filter { store.listedTask(withID: $0).map { $0.priority != priority } == true }
        guard !changing.isEmpty else { return .applied }
        let outcome = reachesDoneLog(changing)
            ? library.updateListedTasks(changing, priority: priority)
            : changing.count == 1
                ? library.updateTask(changing[0], priority: priority)
                : library.updateTasks(changing, priority: priority)
        if reachesDoneLogAfterEdit(changing) { reloadDoneLogAfterEdit() }
        guard outcome.isApplied else { return outcome }
        pruneInvisibleSelection(on: tab)
        let name = priority.spokenTitle
        showToast(changing.count == 1 ? name : String(localized: "\(changing.count) tasks: \(name)"))
        return outcome
    }

    /// ⌘B and the menu: to Later (the backlog), with an Undo toast (a move).
    @discardableResult
    func moveToBacklog(_ ids: [UUID]) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        let movable = ids.filter { store.task(withID: $0).map { $0.listedStatus != .backlog } == true }
        guard !movable.isEmpty else { return .applied }
        let succeeded = movable.count == 1
            ? library.updateTask(movable[0], status: .backlog, allowingUnfinishedSubtasks: true)
            : library.updateTasks(movable, status: .backlog)
        guard succeeded.isApplied else { return succeeded }
        selection.subtract(movable)
        pruneInvisibleSelection(on: tab)
        showToast(movable.count == 1 ? String(localized: "Moved to Backlog") : String(localized: "Moved \(movable.count) tasks to Backlog"))
        return succeeded
    }

    /// Back to Now as to do (from Later), with an Undo toast.
    @discardableResult
    func moveToNow(_ ids: [UUID]) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        let movable = ids.filter { store.task(withID: $0)?.listedStatus == .backlog }
        guard !movable.isEmpty else { return .applied }
        let succeeded = movable.count == 1
            ? library.updateTask(movable[0], status: .todo)
            : library.updateTasks(movable, status: .todo)
        guard succeeded.isApplied else { return succeeded }
        selection.subtract(movable)
        pruneInvisibleSelection(on: tab)
        showToast(movable.count == 1 ? String(localized: "Moved to Now") : String(localized: "Moved \(movable.count) tasks to Now"))
        return succeeded
    }

    /// A finished task (today's or the Done log's) back to Now as to do.
    @discardableResult
    func restoreToNow(_ id: UUID) -> CommandOutcome {
        restoreToNow([id])
    }

    /// Restore to Now for the menu's targets: one step, one save, one
    /// count-aware toast, and the restored rows leave the selection, only
    /// once it saved (round 4).
    @discardableResult
    func restoreToNow(_ ids: [UUID]) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        guard !ids.isEmpty else { return .applied }
        let outcome = library.restoreToNow(ids)
        guard outcome.isApplied else { return outcome }
        selection.subtract(ids)
        if tab == .done {
            showToast(ids.count == 1 ? String(localized: "Restored to Now") : String(localized: "Restored \(ids.count) tasks to Now"))
        }
        doneLogRevision = nil
        loadDoneLogIfNeeded()
        pruneInvisibleSelection(on: tab)
        return outcome
    }

    /// Delete: to Recently Deleted, with the Undo toast (6 s; ⌘Z works too).
    /// Selection, the quick look and the toast change only once the delete
    /// saved; the caller moves focus only then (Astra 6).
    @discardableResult
    func delete(_ ids: [UUID]) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        // Done's rows too (round 10): a Done log task goes to Recently
        // Deleted with its family, and Undo puts it back in the log.
        let live = ids.filter { store.listedTask(withID: $0) != nil }
        guard !live.isEmpty else { return .failed(.taskGone) }
        let title = live.count == 1 ? store.listedTask(withID: live[0])?.title : nil
        let archived = reachesDoneLog(live)
        let outcome = archived ? library.deleteListedTasks(live) : library.deleteTasks(live)
        guard outcome.isApplied else { return outcome }
        AtticSounds.play(.trashed)
        if archived || tab == .done { reloadDoneLogAfterEdit() }
        if doneDetailID.map(live.contains) == true { doneDetailID = nil }
        selection.subtract(live)
        if let anchor = selectionAnchor, live.contains(anchor) { selectionAnchor = nil }
        expanded.subtract(live)
        pruneInvisibleSelection(on: tab)
        // Orchestrator decision 2026-10-23: deletion includes each task's writing.
        let withWriting = live.filter(noteOwners.contains).count
        if let title {
            showToast(String(localized: "“\(title)” deleted"))
        } else if withWriting > 0 {
            showToast(String(localized: "\(live.count) tasks deleted, \(withWriting) with writing"))
        } else {
            showToast(String(localized: "\(live.count) tasks deleted"))
        }
        return outcome
    }

    // MARK: - Order

    /// ⌘↑ ⌘↓: one place up or down within the task's group. At either end
    /// of the group nothing moves (`.applied`: nothing needed to change).
    @discardableResult
    func moveBy(_ id: UUID, offset: Int) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        guard let task = store.task(withID: id) else { return .failed(.taskGone) }
        let group = store.orderGroup(of: task)
        guard let index = group.firstIndex(where: { $0.id == id }) else { return .failed(.taskGone) }
        let destination = index + offset
        guard group.indices.contains(destination) else { return .applied }
        // How the rows take their places is the page's to decide (its list
        // animates a reorder, or dissolves the two rows that exchanged
        // places, `TasksPage.reorderWithoutCrossing`): a transaction opened
        // here would override that choice.
        return library.moveTask(id, toIndex: destination)
    }

    /// A drag reorder: the row lands at `index` within its group.
    @discardableResult
    func move(_ id: UUID, toGroupIndex index: Int) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        return library.moveTask(id, toIndex: index)
    }

    // MARK: - Title and subtasks

    func beginEditingTitle(_ id: UUID) {
        settlePendingCompletionAcknowledgements()
        // A Done log task's title too (round 10: Done's Edit Title).
        guard let task = store.listedTask(withID: id), editingTitleID != id else { return }
        // Another editor's changes are saved first (review 2).
        guard finishEditing() else { return }
        // The words the title already has stay words: only shorthand typed
        // now applies (review 17: a rename never re-reads "today").
        var edit = TaskAddBarText(text: task.title)
        edit.dismissAllRecognised(parser: parser)
        titleEdit = edit
        titleEditCaret = nil
        titleEditSelection = nil
        titleHistory.reset()
        editingTitleID = id
    }

    /// Return (or leaving the field) saves the title. The editor closes only
    /// once the save succeeded: a failed save keeps the field open with the
    /// text and "Not saved · Retry". Returns whether the edit is finished.
    @discardableResult
    func commitTitle() -> Bool {
        settlePendingCompletionAcknowledgements()
        guard let id = editingTitleID else { return true }
        guard let task = store.listedTask(withID: id), let patch = titlePatch(for: task) else {
            editingTitleID = nil
            clearFailure(.title(id))
            return true
        }
        let saved = store.task(withID: id) == nil
            ? library.updateListedTasks([id], title: patch.title, priority: patch.priority, tags: patch.tags,
                                        dueDay: patch.dueDay.map { .some($0) },
                                        dueTimeMinutes: patch.dueTimeMinutes.map { .some($0) })
            : library.updateTask(id, title: patch.title, priority: patch.priority, tags: patch.tags,
                                 dueDay: patch.dueDay.map { .some($0) },
                                        dueTimeMinutes: patch.dueTimeMinutes.map { .some($0) })
        if store.task(withID: id) == nil { reloadDoneLogAfterEdit() }
        guard saved.isApplied else {
            failedSave = .title(id)
            return false
        }
        editingTitleID = nil
        clearFailure(.title(id))
        if patch.dueDay != nil { followDatedOutOfLater([id]) }
        pruneInvisibleSelection(on: tab)
        return true
    }

    /// What saving the title edit changes (review 17: a patch, never a
    /// rebuild): the title without its new shorthand; new tags added to the
    /// task's; a new date or priority replacing the old. Anything not typed
    /// stays as it was. Nil when nothing changes (or the title is empty).
    struct TitlePatch: Equatable {
        var title: String?
        var tags: [String]?
        var dueDay: DueDay?
        var dueTimeMinutes: Int?
        var priority: TaskPriority?
    }

    func titlePatch(for task: TaskItem) -> TitlePatch? {
        let parts = titleEdit.parts(parser: parser, existingDay: task.dueDay)
        let title = TaskDraftBuilder.collapsed(parts.title)
        var patch = TitlePatch()
        // Only shorthand ("#home" alone) keeps the title it had.
        if !title.isEmpty, title != task.title { patch.title = title }
        let tags = AtticTag.normalizedSet(task.tags + parts.tags)
        if Set(tags.map { $0.lowercased() }) != Set(task.tags.map { $0.lowercased() }) { patch.tags = tags }
        if let day = parts.dueDay, day != task.dueDay { patch.dueDay = day }
        if let time = parts.dueTimeMinutes, time != task.dueTimeMinutes { patch.dueTimeMinutes = time }
        if let priority = parts.priority, priority != task.priority { patch.priority = priority }
        guard patch != TitlePatch() else { return nil }
        if title.isEmpty, patch.tags == nil, patch.dueDay == nil, patch.dueTimeMinutes == nil, patch.priority == nil { return nil }
        return patch
    }

    private func clearFailure(_ failure: FailedSave) {
        if failedSave == failure { failedSave = nil }
    }

    func cancelEditing() {
        if renamingSubtaskID != nil { cancelSubtaskRename() }
        if case .title? = failedSave { failedSave = nil }
        if case .newSubtask? = failedSave { failedSave = nil }
        // Only what changes (round 11): each assignment redraws every row
        // of the page shown, and a tab click came through here.
        if editingTitleID != nil { editingTitleID = nil }
        if newSubtaskParentID != nil { newSubtaskParentID = nil }
        if !newSubtaskTitle.isEmpty { newSubtaskTitle = "" }
    }

    func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) {
            // Closing the quick look saves a subtask being written; if that
            // fails it stays open with the text and Retry (review 2).
            if newSubtaskParentID == id {
                guard commitNewSubtask() else { return }
                newSubtaskParentID = nil
                newSubtaskTitle = ""
            }
            // Likewise a subtask being renamed here: a failed save keeps
            // the quick look open with the text and Retry (round 10b).
            if let renaming = renamingSubtaskID, store.task(withID: renaming)?.parentID == id {
                guard commitSubtaskRename() else { return }
            }
            expanded.remove(id)
            quickLookOrder[id] = nil
        } else {
            expanded.insert(id)
        }
    }

    /// While a quick look is open its subtasks keep the order they had when
    /// it opened (review 21): ticking several never moves one away from the
    /// pointer. New ones join at the end; closing it lets the order settle.
    private var quickLookOrder: [UUID: [UUID]] = [:]

    func quickLookSubtasks(of id: UUID, _ subtasks: [TaskItem]) -> [TaskItem] {
        guard let order = quickLookOrder[id] else {
            quickLookOrder[id] = subtasks.map(\.id)
            return subtasks
        }
        let known = subtasks.filter { order.contains($0.id) }
            .sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        let new = subtasks.filter { !order.contains($0.id) }
        if !new.isEmpty { quickLookOrder[id] = order + new.map(\.id) }
        return known + new
    }

    /// A subtask moved on purpose (round 10; also its Undo and Redo, round
    /// 10b): the open quick look takes the family's order again, and the
    /// rows built with the held order are dropped. (Ticking a box does not
    /// come here: it keeps the hold.)
    func releaseQuickLookOrder(of id: UUID) {
        quickLookOrder[id] = nil
        rowsCache = [:]
    }

    func setExpanded(_ id: UUID, _ open: Bool) {
        if open != expanded.contains(id) { toggleExpanded(id) }
    }

    /// An empty editor's Backspace removes its own line, then edits the
    /// previous visible sibling at its end. Store deletion remains the
    /// library's duplicate-safe, fallible, undoable operation.
    @discardableResult
    func backspaceEmptySubtask() -> Bool {
        settlePendingCompletionAcknowledgements()
        if let parent = newSubtaskParentID {
            guard newSubtaskTitle.isEmpty else { return false }
            let previous = quickLookSubtasks(of: parent, store.subtasks(of: parent)).last?.id
            newSubtaskParentID = nil
            if let previous { beginRenamingSubtask(previous) }
            library.undo.record(UndoStep(name: String(localized: "Remove empty subtask"), undoOutcome: { [weak self] in
                guard let self, self.store.task(withID: parent) != nil else { return .obsolete }
                guard self.canRestoreEmptySubtaskLine else { return .failed }
                self.cancelEditing()
                self.beginAddingSubtask(to: parent)
                return .applied
            }, redoOutcome: { [weak self] in
                guard let self, self.store.task(withID: parent) != nil else { return .obsolete }
                guard self.canRestoreEmptySubtaskLine else { return .failed }
                self.cancelEditing()
                if let previous { self.beginRenamingSubtask(previous) }
                return .applied
            }), in: .tasks)
            return true
        }
        guard let id = renamingSubtaskID, subtaskRename.isEmpty,
              let parent = store.task(withID: id)?.parentID else { return false }
        let siblings = quickLookSubtasks(of: parent, store.subtasks(of: parent))
        let previous = siblings.firstIndex(where: { $0.id == id }).flatMap { $0 > 0 ? siblings[$0 - 1].id : nil }
        guard deleteSubtask(id).isApplied else { return false }
        if let previous { beginRenamingSubtask(previous) }
        return true
    }

    /// Undo closures must never save/record another history step while
    /// UndoRoute is applying one. Dirty native typing keeps its own Undo
    /// first; a direct page Undo also preserves that draft and its history.
    private var canRestoreEmptySubtaskLine: Bool {
        if hasUnsavedEdit { return false }
        if let id = renamingSubtaskID, subtaskRename != store.task(withID: id)?.title { return false }
        return newSubtaskTitle.isEmpty
    }

    func beginAddingSubtask(to id: UUID) {
        guard newSubtaskParentID != id else { return }
        guard finishEditing() else { return }
        expanded.insert(id)
        newSubtaskTitle = ""
        newSubtaskParentID = id
    }

    /// Return in the new-subtask field: adds it (shorthand understood) and
    /// keeps the field for the next one.
    @discardableResult
    func commitNewSubtask() -> Bool {
        settlePendingCompletionAcknowledgements()
        guard let parentID = newSubtaskParentID else { return true }
        let text = TaskAddBarText(text: newSubtaskTitle)
        guard let draft = text.draft(parser: parser, status: .todo, parentID: parentID) else {
            newSubtaskParentID = nil
            return true
        }
        guard library.createTasks([draft]) != nil else {
            failedSave = .newSubtask(parentID)
            return false
        }
        clearFailure(.newSubtask(parentID))
        newSubtaskTitle = ""
        return true
    }

    /// A subtask's box in the quick look. The outcome carries the store's
    /// reason on failure, also for failures the store files under the
    /// family (Astra 6): the quick look shows it where the box is.
    @discardableResult
    func toggleSubtask(_ id: UUID) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        guard let task = store.task(withID: id) else { return .failed(.taskGone) }
        let isDone = task.status == .done
        return AtticSounds.play(isDone ? .undone : .done, after: library.updateTask(id, status: isDone ? .todo : .done))
    }

    // MARK: - Add bar

    /// The add bar always adds (Direction A): to Later on Later, to Now on
    /// Now and on Done.
    var addStatus: TaskStatus { tab == .backlog ? .backlog : newOpenStatus(from: tab) }

    /// A new open task's state from `tab`: In Progress while Now shows only
    /// in-progress tasks (Accepted 2026-11-13, "+" while filtered), so it
    /// doesn't vanish as you make it; otherwise to do.
    func newOpenStatus(from tab: TasksTab) -> TaskStatus {
        tab == .now && viewOptions(for: .now).status == .inProgress ? .inProgress : .todo
    }

    /// "+" while tags are picked: an empty draft starts with them (as the
    /// strip's Tags would add them), so the new task stays in view.
    func startDraftFromFilter() {
        let picks = tagPicks(on: tab)
        guard !picks.isEmpty, addBar == TaskAddBarText() else { return }
        addBar.picked.tags = picks.tags
    }

    var addPlaceholder: String {
        switch tab {
        case .now, .done: String(localized: "Add a task")
        case .backlog: String(localized: "Add to Backlog")
        }
    }

    /// The Done page's search field.
    var searchPlaceholder: String { String(localized: "Search done tasks") }


    /// Return adds and keeps the bar focused; ⌘Return also reveals the new
    /// task. Returns the new task.
    @discardableResult
    func submitAddBar(openingPage: Bool = false) -> UUID? {
        settlePendingCompletionAcknowledgements()
        guard composerFilesReadyForSubmission() else { return nil }
        // Submitting finishes the words at the end (round 8, G1): a date or
        // priority typed after a pick, still at the caret (`Call !` then
        // Return), replaces the pick as a finished one does. Words that are
        // no piece (`friend`, `money`) stay words. Only the saved task sees
        // it: a failed save keeps the draft exactly as it was.
        var finished = addBar
        finished.typedReplacesPicks(parser: parser, caret: nil)
        guard let draft = finished.draft(parser: parser, status: addStatus),
              let task = library.createTasks([draft])?.first else { return nil }
        addBarState.clearDraft()
        keepInView(task.id, on: tab)
        startDraftFromFilter()
        AtticSounds.play(.created)
        // Files added while it was written go onto it (O17-06).
        attachComposerFiles(to: task.id)
        selectOnly(nil)
        var revealed = false
        if openingPage {
            revealed = show(task.id) == .shown
        }
        addedRequest = ScrollRequest(id: task.id)
        // A requested reveal can be blocked by another unsaved edit. Only
        // suppress the out-of-view feedback once the task is actually shown.
        if tab == .done, !revealed { showToast(String(localized: "Added to Now")) }
        // Added where the view or a Find hides it (item 6): say so.
        else if !revealed, narrows(tab), !rows(for: tab).contains(where: { $0.id == task.id }) {
            showToast(String(localized: "Added · hidden by this view"))
        }
        return task.id
    }

    /// Preparing a provider cannot consume this draft yet. Keep the choice
    /// explicit: a later file callback must never submit a changed draft.
    func composerFilesReadyForSubmission() -> Bool {
        guard addBarState.stagingFiles > 0 else { return true }
        toasts.show(String(localized: "Preparing files · try again in a moment"),
                    actionTitle: String(localized: "OK"), answersUndoKey: false, action: {})
        return false
    }

    /// Pasted lines: one task per line, or all of them as one task.
    /// The offer stays (with "Not saved · Retry") until the tasks exist.
    func acceptPaste(asOne: Bool) {
        settlePendingCompletionAcknowledgements()
        guard composerFilesReadyForSubmission() else { return }
        guard let offer = pasteOffer else { return }
        let builder = TaskDraftBuilder(parser: parser, status: addStatus)
        let drafts = builder.drafts(from: offer.text, mode: asOne ? .single : .onePerLine)
        guard let created = library.createTasks(drafts) else {
            failedSave = .paste
            lastPasteAsOne = asOne
            return
        }
        clearFailure(.paste)
        pasteOffer = nil
        // The bar is empty once the tasks exist, as after a single add (round
        // 12, CU: the draft stayed behind the batch).
        addBarState.clearDraft()
        // A paste consumes the same draft as Return. For one-per-line,
        // its files belong to the first task, which the page reveals.
        if let first = created.first { attachComposerFiles(to: first.id) }
        // The same observable success as a single add (round 4): the first
        // new row comes into view; from Done, a toast says where they went;
        // VoiceOver hears how many were added.
        if let first = created.first { addedRequest = ScrollRequest(id: first.id) }
        let message = created.count == 1
            ? (tab == .done ? String(localized: "Added to Now") : String(localized: "Added 1 task"))
            : (tab == .done ? String(localized: "Added \(created.count) tasks to Now") : String(localized: "Added \(created.count) tasks"))
        if tab == .done { showToast(message) }
        AccessibilityNotification.Announcement(message).post()
    }

    /// A task (or the first of pasted tasks) just added: the list brings it
    /// into view without selecting it.
    @Published var addedRequest: ScrollRequest?

    private var lastPasteAsOne = false

    /// "Retry" after a failed paste: the same choice again.
    func retryPaste() {
        acceptPaste(asOne: lastPasteAsOne)
    }

    func dismissPasteOffer() {
        pasteOffer = nil
        clearFailure(.paste)
    }

    // MARK: - Undo and the toast

    /// ⌘Z with no text being edited (a field's own typing comes first).
    /// The toast goes only once the undo applied; a failure is the store's
    /// notice (Astra 23).
    @discardableResult
    func undo() -> CommandOutcome {
        let hadPending = acknowledgedTaskCommand != nil || !completingAfterAcknowledgement.isEmpty
        let savedPending = settlePendingCompletionAcknowledgements()
        // A failed acknowledged click never acquired an Undo step. Do not
        // let ⌘Z reach back into an unrelated earlier saved task edit.
        if hadPending && !savedPending { return .applied }
        let outcome = library.undo(in: .tasks)
        if outcome.isApplied {
            // Undo may restore a still-held completed row. Show its genuine
            // status immediately instead of keeping a false checked tick.
            for id in Array(held.keys) where store.task(withID: id)?.status != .done { cancelHold(id) }
            dismissToast()
            reloadDoneLogAfterChange()
            pruneInvisibleSelection(on: tab)
            // The step is undone: the next ⌘Z is the field's typing again,
            // and ⇧⌘Z brings the step back.
            stepAtLastTextEdit = library.undo.undoStepID(in: .tasks)
            taskRedoIsNext = true
        }
        return outcome
    }

    @discardableResult
    func redo() -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        let outcome = library.redo(in: .tasks)
        if outcome.isApplied {
            reloadDoneLogAfterChange()
            pruneInvisibleSelection(on: tab)
            stepAtLastTextEdit = library.undo.undoStepID(in: .tasks)
        }
        return outcome
    }

    // MARK: Who owns ⌘Z while a field has the keyboard (round 13)

    /// The newest Tasks step when the user last edited a draft (the add bar
    /// or a title editor). A step recorded after that is a change made
    /// elsewhere since (a row menu, a click) and is what ⌘Z reverses first,
    /// though a draft is still on screen (round 13, review 61: ⌘Z after a
    /// task-menu change edited the composer). Typing again gives ⌘Z back to
    /// the field.
    private var stepAtLastTextEdit: UUID?
    private var taskRedoIsNext = false

    /// A draft was edited: text Undo is the field's until a task change
    /// happens after this.
    func noteTextEdit() {
        settlePendingCompletionAcknowledgements()
        stepAtLastTextEdit = library.undo.undoStepID(in: .tasks)
        taskRedoIsNext = false
    }

    /// A task change is newer than the draft's last edit: ⌘Z belongs to it.
    var taskChangeOwnsUndo: Bool {
        if acknowledgedTaskCommand != nil || !completingAfterAcknowledgement.isEmpty { return true }
        guard let top = library.undo.undoStepID(in: .tasks) else { return false }
        return top != stepAtLastTextEdit
    }

    /// The step a claimed ⌘Z just undid is waiting for ⇧⌘Z.
    var taskChangeOwnsRedo: Bool {
        acknowledgedTaskCommand == nil && completingAfterAcknowledgement.isEmpty && taskRedoIsNext && library.undo.canRedo(in: .tasks)
    }

    /// Posts "… · Undo" to the shell's toast host (6 s, held while the
    /// pointer rests on it); its button undoes the step it announced, and
    /// only that step: a newer change (a task added, a title edited, an
    /// agent's edit) takes the toast away, and its button never reaches
    /// past the step it names.
    func showToast(_ message: String) {
        let step = library.undo.undoStepID(in: .tasks)
        postedToastStep = step
        postedToastID = toasts.show(message, performing: { [weak self] in
            // Only the step the toast named: anything newer makes it stale.
            self?.settlePendingCompletionAcknowledgements()
            guard let self, let step, self.library.undo.undoStepID(in: .tasks) == step else { return .applied }
            let outcome = self.library.undo(in: .tasks)
            // The toast says it where the Undo was pressed; the same
            // sentence is not repeated in the panel's notice.
            if let failure = outcome.failure, self.store.lastErrorMessage == failure.message { self.store.dismissError() }
            return outcome
        }).id
    }

    /// A change after the toast's step (or an undo of it) makes the toast
    /// stale: it goes.
    private func dismissToastIfSuperseded() {
        guard postedToastID != nil, library.undo.undoStepID(in: .tasks) != postedToastStep else { return }
        // A failed Undo's message stays until its own button (Retry, which
        // then finds nothing to do, or OK) or a newer toast.
        guard toasts.current?.isFailure != true else { return }
        dismissToast()
        postedToastID = nil
    }

    private var postedToastStep: UUID?

    /// Dismisses the toast only when it is this page's (another page's
    /// toast is not the Tasks history's to take away).
    func dismissToast() {
        guard let current = toasts.current, current.id == postedToastID else { return }
        toasts.dismiss()
    }

    private var postedToastID: UUID?

    /// Without the host's task pages (previews, tests): a task in the Done
    /// log opens its read-only details here, its subtasks and the files it
    /// kept. A task in the lists has nothing to open (its files show as
    /// its tiles; Accepted 2026-11-01 "Task rows: no paperclip count").
    func openPage(_ id: UUID) {
        guard store.task(withID: id) == nil, store.listedTask(withID: id) != nil else { return }
        doneDetailID = id
    }

    /// The Done log task whose details are open.
    @Published var doneDetailID: UUID?

    struct DoneDetail: Equatable {
        let title: String
        let finished: String
        /// What the task still carries (follow-up part 2, L6): its due date,
        /// priority and tags, which its Done row does not show ("Due Tue 30
        /// Sep · !! High · #launch"); nil when it has none.
        var metadata: String? = nil
        let subtasks: [AtticSubtaskModel]
        let files: [TaskImageReference]

        static func == (lhs: DoneDetail, rhs: DoneDetail) -> Bool {
            lhs.title == rhs.title && lhs.finished == rhs.finished && lhs.metadata == rhs.metadata && lhs.files == rhs.files
                && lhs.subtasks.map(\.id) == rhs.subtasks.map(\.id)
        }
    }

    /// A finished task's metadata line for its details (L6): the due date
    /// in the row's words, the priority with its mark, then its tags.
    func doneMetadata(for task: TaskItem) -> String? {
        var parts: [String] = []
        if let day = task.dueDay {
            parts.append(String(localized: "Due \(dueText(day))"))
        }
        if task.priority != .none, let mark = task.priority.mark {
            parts.append("\(mark) \(task.priority.detailTitle)")
        }
        if !task.tags.isEmpty {
            parts.append(task.tags.map { "#" + $0 }.joined(separator: " "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func doneDetail(for id: UUID) -> DoneDetail? {
        guard let task = store.listedTask(withID: id) else { return nil }
        let calendar = services.calendar()
        let finished = task.completedAt.map {
            String(localized: "Finished \(TaskRowPresentation.doneDayTitle($0, today: services.now(), calendar: calendar, locale: services.locale))")
        } ?? String(localized: "Finished")
        let children = store.task(withID: id) != nil ? store.subtasks(of: id) : (doneLogChildren[id] ?? store.doneLogSubtasks(of: id))
        return DoneDetail(
            title: task.title,
            finished: finished,
            metadata: doneMetadata(for: task),
            subtasks: children.map { AtticSubtaskModel(id: $0.id, title: $0.title, isDone: $0.status == .done) },
            files: store.fileMigration.rowFiles(for: task)
        )
    }
}
