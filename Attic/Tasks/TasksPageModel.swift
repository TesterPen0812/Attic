import AppKit
import Combine
import SwiftUI

/// Where the Tasks page is: Now (in progress and to do, then "Completed
/// today"), Later (the backlog), or the Done log. Direction A shows them as
/// tabs; "Later" is only the display name: the model, storage and agent
/// tools still call it `backlog`.
enum TasksTab: Int, CaseIterable, Hashable, Identifiable {
    case now, backlog, done

    var id: Int { rawValue }

    /// The tab's name ("Now · Later · Done").
    var title: String {
        switch self {
        case .now: String(localized: "Now")
        case .backlog: String(localized: "Later")
        case .done: String(localized: "Done")
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

/// What the page needs from outside itself. The shell (or the preview)
/// supplies it; tests supply fixed clocks.
struct TasksPageServices {
    /// ⌘Return, "Open page", VoiceOver "Open page": the task's page. Task
    /// pages arrive in Phase 3; until then the host opens today's detail
    /// panel (the subtask panel, which also holds the task's files).
    var openPage: (UUID) -> Void = { _ in }
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

    static func == (lhs: TasksListRow, rhs: TasksListRow) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.model.title == rhs.model.title
            && lhs.model.state == rhs.model.state && lhs.model.priority == rhs.model.priority
            && lhs.model.due?.text == rhs.model.due?.text && lhs.model.tags == rhs.model.tags
            && lhs.model.attachments == rhs.model.attachments
            && lhs.model.subtasks?.done == rhs.model.subtasks?.done
            && lhs.model.subtasks?.total == rhs.model.subtasks?.total
            && lhs.subtasks.map(\.id) == rhs.subtasks.map(\.id)
            && lhs.subtasks.map(\.isDone) == rhs.subtasks.map(\.isDone)
            && lhs.subtasks.map(\.title) == rhs.subtasks.map(\.title)
    }
}

/// A list as the page shows it: the open rows (with any finished row still
/// held in place), and on Now the rows finished today, which show under
/// "Completed today" when it is open.
struct TasksSections: Equatable {
    var open: [TasksListRow] = []
    var done: [TasksListRow] = []
}

/// A day of the Done log.
struct TasksDoneDay: Identifiable, Equatable {
    let id: Date
    let title: String
    let rows: [TasksListRow]
}

/// The add bar's text and insertion point. Only the add bar observes it.
@MainActor
final class TasksAddBarState: ObservableObject {
    @Published var text = TaskAddBarText()
    @Published var caret: Int?
    /// The suggestion list's highlighted choice (owner fix 5 B).
    @Published var highlighted = 0
    /// The piece whose suggestions Esc hid; the next edit shows them again.
    @Published var hiddenSuggestion: NSRange?
    /// The draft's undo history, text and pieces together (round 4).
    var history = TaskDraftHistory()

    /// The owner's side of the token field's undo: text and pieces step
    /// back together; nil when the draft has nothing to undo.
    func undoDraft() -> (text: String, caret: Int)? {
        guard let entry = history.undo(current: text, caret: caret) else { return nil }
        text = entry.text
        caret = entry.caret
        return (entry.text.text, entry.caret)
    }

    func redoDraft() -> (text: String, caret: Int)? {
        guard let entry = history.redo(current: text, caret: caret) else { return nil }
        text = entry.text
        caret = entry.caret
        return (entry.text.text, entry.caret)
    }

    /// The draft is gone (added, or cleared on purpose).
    func clearDraft() {
        text.clear()
        history.reset()
        hiddenSuggestion = nil
        highlighted = 0
    }
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

    @Published var tab: TasksTab = .now
    @Published private(set) var selection: Set<UUID> = []
    private var selectionAnchor: UUID?
    /// Rows whose quick look is open (remembered per row for the session).
    @Published private(set) var expanded: Set<UUID> = []
    @Published private(set) var editingTitleID: UUID?
    /// The title being edited, with its shorthand (owner fix 4): what is
    /// typed as `#tag`, a date or `!` becomes a chip and applies on save.
    @Published var titleEdit = TaskAddBarText()
    @Published var titleEditCaret: Int?
    /// The title editor's undo history, text and pieces together (round 4).
    var titleHistory = TaskDraftHistory()

    func undoTitleEdit() -> (text: String, caret: Int)? {
        guard let entry = titleHistory.undo(current: titleEdit, caret: titleEditCaret) else { return nil }
        titleEdit = entry.text
        titleEditCaret = entry.caret
        return (entry.text.text, entry.caret)
    }

    func redoTitleEdit() -> (text: String, caret: Int)? {
        guard let entry = titleHistory.redo(current: titleEdit, caret: titleEditCaret) else { return nil }
        titleEdit = entry.text
        titleEditCaret = entry.caret
        return (entry.text.text, entry.caret)
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
    @Published var newSubtaskTitle = ""
    /// Finished rows held where they were for about a second, with the
    /// list and index they held (spec: "stays in place, then slides").
    @Published private(set) var held: [UUID: HeldPlace] = [:]

    struct HeldPlace: Equatable {
        let tab: TasksTab
        let index: Int
    }

    /// Whether Now's "Completed today" shows its rows (remembered for the
    /// session: the model lives as long as the panel).
    @Published var completedTodayExpanded = false
    /// Search (the menu-bar item) asked for the Done page's search field;
    /// the page puts the keyboard there and clears it.
    @Published var pendingSearchFocus = false
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
    @Published var doneSearch = ""
    /// Loaded pages of the Done log (lazily, a page at a time).
    @Published private(set) var doneLogTasks: [TaskItem] = []
    @Published private(set) var doneLogHasMore = false
    /// A Done log read failed (Astra 18): what was loaded stays, and the
    /// page offers "Couldn't load more · Retry" instead of claiming there
    /// is nothing more.
    @Published private(set) var doneLogFailure: String?
    /// The loaded Done log tasks' subtasks, read with their page (Astra 19):
    /// an archived row shows its checklist from its archived family.
    private var doneLogChildren: [UUID: [TaskItem]] = [:]
    private var doneLogQuery: String?
    private var doneLogRevision: UInt64?
    private var doneLogCursor = TaskStore.DoneLogCursor()

    let parser: TaskTextParser
    /// Where the page's Undo toast shows: the shell's one toast host (the
    /// panel supplies its own; the page alone gets a private one).
    let toasts: PanelToastCenter
    private var holdTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellables: Set<AnyCancellable> = []

    static let doneLogPageSize = 80

    init(library: AtticLibrary, services: TasksPageServices = TasksPageServices(), toasts: PanelToastCenter? = nil) {
        self.library = library
        self.services = services
        self.toasts = toasts ?? PanelToastCenter()
        parser = TaskTextParser(calendar: services.calendar(), locale: services.locale, now: services.now)
        // A task that left the list (deleted, cleaned up) leaves the
        // selection and the quick look too.
        library.tasks.$revision
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pruneMissing() } }
            .store(in: &cancellables)
        // `$revision` publishes before the history changes: check after it.
        library.undo.$revision
            .sink { [weak self] _ in DispatchQueue.main.async { self?.dismissToastIfSuperseded() } }
            .store(in: &cancellables)
    }

    // MARK: - Lists

    private var today: DueDay { DueDay(date: services.now(), calendar: services.calendar()) }

    func rowModel(for task: TaskItem) -> TasksListRow {
        let subtasks: [TaskItem]
        if store.parent(of: task) != nil {
            subtasks = []
        } else if store.task(withID: task.id) != nil {
            subtasks = store.subtasks(of: task.id)
        } else {
            // A Done log task: its family left the list with it.
            subtasks = doneLogChildren[task.id] ?? []
        }
        let open = expanded.contains(task.id)
        return TasksListRow(
            id: task.id,
            model: TaskRowPresentation.row(for: task, subtasks: subtasks, today: today,
                                           calendar: services.calendar(), locale: services.locale),
            status: task.status,
            subtasks: open ? quickLookSubtasks(of: task.id, subtasks).map { AtticSubtaskModel(id: $0.id, title: $0.title, isDone: $0.status == .done) } : []
        )
    }

    private struct RowsKey: Equatable {
        let tab: TasksTab
        let revision: UInt64
        let held: [UUID: HeldPlace]
        let expanded: Set<UUID>
        let completedExpanded: Bool
        let today: DueDay
    }

    /// Rows are rebuilt only when something they show changed: SwiftUI asks
    /// for them many times per change.
    private var rowsCache: [TasksTab: (key: RowsKey, sections: TasksSections, rows: [TasksListRow])] = [:]

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

    private func cached(_ tab: TasksTab) -> (key: RowsKey, sections: TasksSections, rows: [TasksListRow]) {
        let key = RowsKey(tab: tab, revision: store.revision, held: held.filter { $0.value.tab == tab }, expanded: expanded,
                          completedExpanded: tab == .now && completedTodayExpanded, today: today)
        if let cached = rowsCache[tab], cached.key == key { return cached }
        let all = buildRows(for: tab)
        var sections = TasksSections()
        for row in all {
            if row.status == .done, held[row.id]?.tab != tab { sections.done.append(row) } else { sections.open.append(row) }
        }
        let rows = key.completedExpanded ? sections.open + sections.done : sections.open
        let entry = (key, sections, rows)
        rowsCache[tab] = entry
        return entry
    }

    private func buildRows(for tab: TasksTab) -> [TasksListRow] {
        let scope: TaskScope = tab == .backlog ? .backlog : .tasks
        var tasks = store.snapshot(for: scope).sections.flatMap(\.tasks)
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
        return tasks.map(rowModel(for:))
    }

    /// The library's tags, most used first, read once per store change
    /// (the suggestions look at them on every keystroke).
    var cachedTags: [String] {
        if let tagsCache, tagsCache.revision == store.revision { return tagsCache.tags }
        let tags = library.tags.counts().map(\.name)
        tagsCache = (store.revision, tags)
        return tags
    }

    private var tagsCache: (revision: UInt64, tags: [String])?

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
    /// Later has tasks, and otherwise invites the first task.
    var emptyMessage: [TasksTab: String] {
        [
            .now: hasDoneToday ? String(localized: "You’re caught up")
                : (backlogCount > 0 ? String(localized: "Nothing active") : String(localized: "Add your first task")),
            .backlog: String(localized: "Nothing for later")
        ]
    }

    // MARK: - Done log

    /// The Done page: today's finished tasks (still in Now until the daily
    /// cleanup) and the Done log, grouped by the day they were finished,
    /// newest first; filtered by the search.
    func doneDays() -> [TasksDoneDay] {
        let key = DoneKey(revision: store.revision, loaded: doneLogTasks.map(\.id), search: doneSearch,
                          today: DueDay(date: services.now(), calendar: services.calendar()))
        if let doneCache, doneCache.key == key { return doneCache.days }
        let days = buildDoneDays()
        doneCache = (key, days)
        return days
    }

    private struct DoneKey: Equatable {
        let revision: UInt64
        let loaded: [UUID]
        let search: String
        let today: DueDay
    }

    private var doneCache: (key: DoneKey, days: [TasksDoneDay])?

    private func buildDoneDays() -> [TasksDoneDay] {
        let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let today = store.snapshot(for: .tasks).sections.first { $0.status == .done }?.tasks ?? []
        let finished = (today.filter { query.isEmpty || $0.title.localizedStandardContains(query) } + doneLogTasks)
        let calendar = services.calendar()
        let now = services.now()
        var days: [TasksDoneDay] = []
        var current: (day: Date, rows: [TasksListRow])?
        for task in finished {
            let day = calendar.startOfDay(for: task.completedAt ?? task.updatedAt)
            let row = rowModel(for: task)
            if current?.day == day {
                current?.rows.append(row)
            } else {
                if let current {
                    days.append(TasksDoneDay(id: current.day, title: TaskRowPresentation.doneDayTitle(
                        current.day, today: now, calendar: calendar, locale: services.locale), rows: current.rows))
                }
                current = (day, [row])
            }
        }
        if let current {
            days.append(TasksDoneDay(id: current.day, title: TaskRowPresentation.doneDayTitle(
                current.day, today: now, calendar: calendar, locale: services.locale), rows: current.rows))
        }
        return days
    }

    /// Loads the Done log's first page for the current search, if the store
    /// or the search changed since.
    func loadDoneLogIfNeeded() {
        let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard doneLogQuery != query || doneLogRevision != store.revision else { return }
        let page = store.doneLogPage(limit: max(Self.doneLogPageSize, doneLogTasks.count), matching: query)
        if let failure = page.failure {
            // Keep what the page showed for this search; a new search shows
            // what was read. Not marked as loaded, so Retry reads again.
            if doneLogQuery != query { setDoneLog(page.tasks) }
            doneLogCursor = page.next
            doneLogHasMore = true
            doneLogFailure = failure
            return
        }
        doneLogQuery = query
        doneLogRevision = store.revision
        setDoneLog(page.tasks)
        doneLogCursor = page.next
        doneLogHasMore = page.hasMore
        doneLogFailure = nil
    }

    /// The next page, when the last loaded row comes on screen. The cursor
    /// walks physical rows, so duplicates and superseded copies never stop it.
    /// A failed read keeps what loaded and stops until Retry.
    func loadMoreDoneLog() {
        guard doneLogHasMore, doneLogFailure == nil else { return }
        let page = store.doneLogPage(from: doneLogCursor, limit: Self.doneLogPageSize, matching: doneLogQuery,
                                     excluding: Set(doneLogTasks.map(\.id)))
        setDoneLog(doneLogTasks + page.tasks)
        doneLogCursor = page.next
        doneLogHasMore = page.hasMore
        doneLogFailure = page.failure
    }

    /// "Couldn't load more · Retry": the same read again, from where it
    /// stopped (or the first page, when that was what failed).
    func retryDoneLog() {
        doneLogFailure = nil
        if doneLogQuery != doneSearch.trimmingCharacters(in: .whitespacesAndNewlines) || doneLogRevision != store.revision {
            loadDoneLogIfNeeded()
        } else {
            loadMoreDoneLog()
        }
    }

    /// Loaded Done log tasks, in the log's order by the replica each shows
    /// (pages are merged, so a divergent copy never splits a day), with
    /// their families read in one go.
    private func setDoneLog(_ tasks: [TaskItem]) {
        doneLogTasks = tasks.sorted(by: TaskStore.doneLogOrder)
        doneLogChildren = store.doneLogSubtasks(ofParents: doneLogTasks.map(\.id))
    }

    // MARK: - Tabs

    /// Tasks always opens on Now (spec § The shell), except when it was
    /// opened to search or to show a task: then it stays where that put it
    /// until the panel hides.
    ///
    /// Unsaved work is never dropped: a title or new subtask that was
    /// changed, or whose save failed, keeps its text and "Not saved ·
    /// Retry", and the page stays where that row is.
    func resetForReveal() {
        if hasUnsavedEdit { return }
        // Assign only what changes: every assignment redraws the page.
        let target = revealTab ?? .now
        if tab != target { tab = target }
        if revealTab == nil, !selection.isEmpty { selection = [] }
        if editingTitleID != nil || newSubtaskParentID != nil { cancelEditing() }
    }

    /// A title or new subtask holds text that is not saved: it was changed,
    /// or its save failed.
    var hasUnsavedEdit: Bool {
        switch failedSave {
        case .title?, .newSubtask?: return true
        case .paste?, nil: break
        }
        if let id = editingTitleID, let task = store.task(withID: id), titlePatch(for: task) != nil {
            return true
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

    /// Where the current reveal opened the page (Search, an agent's `show`);
    /// nil opens on Now. Cleared when the panel hides or the person moves.
    private var revealTab: TasksTab?

    /// The panel hid: the next reveal opens on Now again, and the page
    /// ends a drag or an open row picker (`hides` changes).
    func pageDidHide() {
        revealTab = nil
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
    /// earlier failure when it applied). Returns the outcome.
    @discardableResult
    func report(_ outcome: CommandOutcome, on id: UUID, retry: @escaping () -> CommandOutcome) -> CommandOutcome {
        if let failure = outcome.failure {
            rowFailure = RowFailure(id: id, message: failure.message, canRetry: failure.canRetry)
            rowRetry = failure.canRetry ? retry : nil
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

    /// Runs a picker's change; true when it saved (the caller may close).
    @discardableResult
    func pickerChange(on id: UUID, _ change: @escaping () -> CommandOutcome) -> Bool {
        let outcome = change()
        if let failure = outcome.failure {
            pickerFailure = RowFailure(id: id, message: failure.message, canRetry: failure.canRetry)
            pickerRetry = failure.canRetry ? change : nil
            return false
        }
        pickerFailure = nil
        pickerRetry = nil
        return true
    }

    /// Retry in the picker; true when it saved.
    @discardableResult
    func retryPickerChange() -> Bool {
        guard let failure = pickerFailure, let retry = pickerRetry else { clearPickerFailure(); return false }
        return pickerChange(on: failure.id, retry)
    }

    func clearPickerFailure() {
        pickerFailure = nil
        pickerRetry = nil
    }

    /// Moving to another page saves an open edit first; if that save
    /// fails, the page stays with the text and Retry (Esc discards it).
    func select(tab: TasksTab) {
        guard tab != self.tab else { return }
        guard finishEditing() else { return }
        revealTab = nil
        selection = []
        self.tab = tab
    }

    /// One "finish or keep the current edit" for every way out of it
    /// (review 2): a title or new subtask with changes is saved; a failed
    /// save keeps the editor, its text and "Not saved · Retry", and the
    /// caller stays put (returns false). Nothing typed is ever dropped
    /// here; Esc in the field is the only discard.
    @discardableResult
    func finishEditing() -> Bool {
        if hasUnsavedEdit {
            guard commitTitle(), commitNewSubtask() else { return false }
        }
        cancelEditing()
        return true
    }

    /// Search (the menu-bar item): the Done page, with the keyboard in the
    /// search field at the top of its list.
    func beginSearch() {
        guard finishEditing() else { return }
        selection = []
        tab = .done
        revealTab = .done
        pendingSearchFocus = true
    }

    /// An agent's `show` of a task: the tab that lists it, the row selected
    /// and scrolled into view. Returns false when no list shows it.
    @discardableResult
    func show(_ id: UUID) -> Bool {
        guard let found = store.listedTask(withID: id) else { return false }
        // A subtask shows in its parent's quick look (live) or its parent's
        // details (in the Done log).
        let parent = found.parentID.flatMap { store.listedTask(withID: $0) }
        let task = parent ?? found
        let archived = store.task(withID: task.id) == nil
        let target: TasksTab = task.status == .backlog ? .backlog : (archived ? .done : .now)
        // An edit that can't be saved keeps the page where it is: the
        // request is deferred (review 2) and the caller keeps it.
        guard finishEditing() else { return false }
        tab = target
        revealTab = target
        // Establish what the destination needs before revealing it (round
        // 4): an open Completed today, no Done search that hides it, its
        // page of the Done log loaded, its parent's quick look or details.
        if target == .now, task.status == .done { completedTodayExpanded = true }
        if target == .done {
            let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty, !task.title.localizedStandardContains(query) { doneSearch = "" }
            revealInDoneLog(task.id)
            if parent != nil { doneDetailID = task.id }
        } else if parent != nil {
            expanded.insert(task.id)
        }
        selectOnly(task.id)
        scrollRequest = ScrollRequest(id: task.id)
        return true
    }

    /// Loads the Done log until `id`'s page is in (bounded by the log's
    /// own end), so a task finished long ago can be shown.
    private func revealInDoneLog(_ id: UUID) {
        loadDoneLogIfNeeded()
        let isTodays = store.task(withID: id) != nil
        var pages = 0
        while !isTodays, !doneLogTasks.contains(where: { $0.id == id }), doneLogHasMore, doneLogFailure == nil, pages < 200 {
            loadMoreDoneLog()
            pages += 1
        }
    }

    /// A row to bring into view (an agent's `show`); each request is new.
    struct ScrollRequest: Equatable {
        let id: UUID
        let token = UUID()
    }

    @Published private(set) var scrollRequest: ScrollRequest?

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

    /// ⇧↑ ⇧↓: grow the selection from the anchor to `id`.
    func extendSelection(to id: UUID, visible: [UUID]) {
        let anchor = selectionAnchor ?? id
        selectionAnchor = anchor
        guard let from = visible.firstIndex(of: anchor), let to = visible.firstIndex(of: id) else { return }
        selection = Set(visible[min(from, to)...max(from, to)])
    }

    func clearSelection() { selection = [] }

    /// What a key or menu command on `id` acts on: the whole selection when
    /// the row is part of a multi-selection, otherwise the row.
    func targets(for id: UUID) -> [UUID] {
        selection.count > 1 && selection.contains(id) ? orderedSelection() : [id]
    }

    func orderedSelection() -> [UUID] {
        let visible = rows(for: tab).map(\.id)
        return visible.filter(selection.contains) + selection.subtracting(visible).sorted { $0.uuidString < $1.uuidString }
    }

    private func pruneMissing() {
        let live = { (id: UUID) in self.store.task(withID: id) != nil || self.tab == .done }
        let keptSelection = selection.filter(live)
        if keptSelection != selection { selection = keptSelection }
        if let editingTitleID, store.task(withID: editingTitleID) == nil, tab != .done { cancelEditing() }
        if let newSubtaskParentID, store.task(withID: newSubtaskParentID) == nil { self.newSubtaskParentID = nil }
    }

    // MARK: - State changes

    /// The circle's click and Space (Direction A: one-click completion):
    /// an open task (to do, in progress or Later) is done; a done task goes
    /// back to what it was.
    @discardableResult
    func toggleDone(_ id: UUID) -> CommandOutcome {
        guard let task = store.listedTask(withID: id) else { return .failed(.taskGone) }
        return task.status == .done ? reopen(id) : complete(id)
    }

    /// The right-click menu on several tasks: all done, or (when all are
    /// done already) all back, each as one step.
    @discardableResult
    func toggleDone(_ ids: [UUID]) -> CommandOutcome {
        let tasks = ids.compactMap { store.listedTask(withID: $0) }
        if !tasks.isEmpty, tasks.allSatisfy({ $0.status == .done }) {
            return tasks.count == 1 ? reopen(tasks[0].id) : library.reopenTasks(tasks.map(\.id))
        } else if ids.count == 1 {
            return complete(ids[0])
        } else {
            return library.updateTasks(tasks.filter { $0.status != .done }.map(\.id), status: .done)
        }
    }

    /// ⇧Space and the right-click menu: start working on the tasks (the
    /// circle's centre dot), or stop when every one is already started.
    @discardableResult
    func toggleWorking(_ ids: [UUID]) -> CommandOutcome {
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
        guard let task = store.task(withID: id) else { return .failed(.taskGone) }
        guard task.status != .done else { return .applied }
        let holdTab: TasksTab? = tab == .done ? nil : tab
        let index = holdTab.flatMap { holdTab in rows(for: holdTab).firstIndex { $0.id == id } }
        let outcome = library.completeTask(id)
        if outcome.isApplied, let holdTab, let index { hold(id, tab: holdTab, at: index) }
        return outcome
    }

    /// A done task back to what it was before the circle finished it
    /// (Astra 20): the state and place the store recorded when it was
    /// finished, with the subtasks finished along with it, whatever the undo
    /// history holds and across relaunches (to do when unknown). A Done log
    /// task comes back with its family.
    @discardableResult
    func reopen(_ id: UUID) -> CommandOutcome {
        let outcome = library.reopenTasks([id])
        if outcome.isApplied {
            cancelHold(id)
            reloadDoneLogAfterChange()
        }
        return outcome
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
        guard held[id] != nil else { return }
        // Reduce Motion: no travel at all (review 22); a shorter slide is
        // still a slide.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? nil : AtticMotionPreset.doneSlide.animation(reduceMotion: false)) {
            _ = held.removeValue(forKey: id)
        }
    }

    @discardableResult
    func setStatus(_ status: TaskStatus, for ids: [UUID]) -> CommandOutcome {
        if status == .done {
            return ids.count == 1 ? complete(ids[0]) : library.updateTasks(ids, status: .done)
        }
        let loggedOrDone = ids.filter { store.task(withID: $0)?.status == .done || store.task(withID: $0) == nil }
        if loggedOrDone == ids, status == .todo {
            return restoreToNow(ids)
        }
        if ids.count == 1 {
            return library.updateTask(ids[0], status: status, allowingUnfinishedSubtasks: true)
        }
        return library.updateTasks(ids, status: status)
    }

    /// Priority from the menu or the selection bar: one step, and an Undo
    /// toast once it saved (owner fix 5: every change to existing tasks has
    /// one). Nothing to change is not a change.
    @discardableResult
    func setPriority(_ priority: TaskPriority, for ids: [UUID]) -> CommandOutcome {
        let changing = ids.filter { store.task(withID: $0).map { $0.priority != priority } == true }
        guard !changing.isEmpty else { return .applied }
        let outcome = changing.count == 1
            ? library.updateTask(changing[0], priority: priority)
            : library.updateTasks(changing, priority: priority)
        guard outcome.isApplied else { return outcome }
        let name = priority.spokenTitle
        showToast(changing.count == 1 ? name : String(localized: "\(changing.count) tasks: \(name)"))
        return outcome
    }

    /// ⌘B and the menu: to Later (the backlog), with an Undo toast (a move).
    @discardableResult
    func moveToBacklog(_ ids: [UUID]) -> CommandOutcome {
        let movable = ids.filter { store.task(withID: $0).map { $0.status != .backlog } == true }
        guard !movable.isEmpty else { return .applied }
        let succeeded = movable.count == 1
            ? library.updateTask(movable[0], status: .backlog, allowingUnfinishedSubtasks: true)
            : library.updateTasks(movable, status: .backlog)
        guard succeeded.isApplied else { return succeeded }
        selection.subtract(movable)
        showToast(movable.count == 1 ? String(localized: "Moved to Later") : String(localized: "Moved \(movable.count) tasks to Later"))
        return succeeded
    }

    /// Back to Now as to do (from Later), with an Undo toast.
    @discardableResult
    func moveToNow(_ ids: [UUID]) -> CommandOutcome {
        let movable = ids.filter { store.task(withID: $0)?.status == .backlog }
        guard !movable.isEmpty else { return .applied }
        let succeeded = movable.count == 1
            ? library.updateTask(movable[0], status: .todo)
            : library.updateTasks(movable, status: .todo)
        guard succeeded.isApplied else { return succeeded }
        selection.subtract(movable)
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
        guard !ids.isEmpty else { return .applied }
        let outcome = library.restoreToNow(ids)
        guard outcome.isApplied else { return outcome }
        selection.subtract(ids)
        if tab == .done {
            showToast(ids.count == 1 ? String(localized: "Restored to Now") : String(localized: "Restored \(ids.count) tasks to Now"))
        }
        doneLogRevision = nil
        loadDoneLogIfNeeded()
        return outcome
    }

    /// Delete: to Recently Deleted, with the Undo toast (6 s; ⌘Z works too).
    /// Selection, the quick look and the toast change only once the delete
    /// saved; the caller moves focus only then (Astra 6).
    @discardableResult
    func delete(_ ids: [UUID]) -> CommandOutcome {
        let live = ids.filter { store.task(withID: $0) != nil }
        guard !live.isEmpty else { return .failed(.taskGone) }
        let title = live.count == 1 ? store.task(withID: live[0])?.title : nil
        let outcome = library.deleteTasks(live)
        guard outcome.isApplied else { return outcome }
        selection.subtract(live)
        expanded.subtract(live)
        if let title {
            showToast(String(localized: "Deleted “\(title)”"))
        } else {
            showToast(String(localized: "Deleted \(live.count) tasks"))
        }
        return outcome
    }

    // MARK: - Order

    /// ⌘↑ ⌘↓: one place up or down within the task's group. At either end
    /// of the group nothing moves (`.applied`: nothing needed to change).
    @discardableResult
    func moveBy(_ id: UUID, offset: Int) -> CommandOutcome {
        guard let task = store.task(withID: id) else { return .failed(.taskGone) }
        let group = store.orderGroup(of: task)
        guard let index = group.firstIndex(where: { $0.id == id }) else { return .failed(.taskGone) }
        let destination = index + offset
        guard group.indices.contains(destination) else { return .applied }
        var outcome = CommandOutcome.applied
        // Reduce Motion: the row is simply in its new place (no travel).
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? nil : AtticMotionPreset.settle.animation(reduceMotion: false)) {
            outcome = library.moveTask(id, toIndex: destination)
        }
        return outcome
    }

    /// A drag reorder: the row lands at `index` within its group.
    @discardableResult
    func move(_ id: UUID, toGroupIndex index: Int) -> CommandOutcome {
        library.moveTask(id, toIndex: index)
    }

    // MARK: - Title and subtasks

    func beginEditingTitle(_ id: UUID) {
        guard let task = store.task(withID: id), editingTitleID != id else { return }
        // Another editor's changes are saved first (review 2).
        guard finishEditing() else { return }
        // The words the title already has stay words: only shorthand typed
        // now applies (review 17: a rename never re-reads "today").
        var edit = TaskAddBarText(text: task.title)
        edit.dismissAllRecognised(parser: parser)
        titleEdit = edit
        titleEditCaret = nil
        titleHistory.reset()
        editingTitleID = id
    }

    /// Return (or leaving the field) saves the title. The editor closes only
    /// once the save succeeded: a failed save keeps the field open with the
    /// text and "Not saved · Retry". Returns whether the edit is finished.
    @discardableResult
    func commitTitle() -> Bool {
        guard let id = editingTitleID else { return true }
        guard let task = store.task(withID: id), let patch = titlePatch(for: task) else {
            editingTitleID = nil
            clearFailure(.title(id))
            return true
        }
        guard library.updateTask(id, title: patch.title, priority: patch.priority, tags: patch.tags,
                                 dueDay: patch.dueDay.map { .some($0) }).isApplied else {
            failedSave = .title(id)
            return false
        }
        editingTitleID = nil
        clearFailure(.title(id))
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
        var priority: TaskPriority?
    }

    func titlePatch(for task: TaskItem) -> TitlePatch? {
        let parts = titleEdit.parts(parser: parser)
        let title = TaskDraftBuilder.collapsed(parts.title)
        var patch = TitlePatch()
        // Only shorthand ("#home" alone) keeps the title it had.
        if !title.isEmpty, title != task.title { patch.title = title }
        let tags = AtticTag.normalizedSet(task.tags + parts.tags)
        if Set(tags.map { $0.lowercased() }) != Set(task.tags.map { $0.lowercased() }) { patch.tags = tags }
        if let day = parts.dueDay, day != task.dueDay { patch.dueDay = day }
        if let priority = parts.priority, priority != task.priority { patch.priority = priority }
        guard patch != TitlePatch() else { return nil }
        if title.isEmpty, patch.tags == nil, patch.dueDay == nil, patch.priority == nil { return nil }
        return patch
    }

    private func clearFailure(_ failure: FailedSave) {
        if failedSave == failure { failedSave = nil }
    }

    func cancelEditing() {
        if case .title? = failedSave { failedSave = nil }
        if case .newSubtask? = failedSave { failedSave = nil }
        editingTitleID = nil
        newSubtaskParentID = nil
        newSubtaskTitle = ""
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

    func setExpanded(_ id: UUID, _ open: Bool) {
        if open != expanded.contains(id) { toggleExpanded(id) }
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
        guard let task = store.task(withID: id) else { return .failed(.taskGone) }
        return library.updateTask(id, status: task.status == .done ? .todo : .done)
    }

    // MARK: - Add bar

    /// The add bar always adds (Direction A): to Later on Later, to Now on
    /// Now and on Done.
    var addStatus: TaskStatus { tab == .backlog ? .backlog : .todo }

    var addPlaceholder: String {
        switch tab {
        case .now, .done: String(localized: "Add a task")
        case .backlog: String(localized: "Add to later")
        }
    }

    /// The Done page's search field.
    var searchPlaceholder: String { String(localized: "Search done tasks") }

    var addBarChips: [NSRange] {
        addBar.chips(parser: parser, caret: addBarCaret)
    }

    /// Return adds and keeps the bar focused; ⌘Return adds and opens the
    /// task's page. Returns the new task.
    @discardableResult
    func submitAddBar(openingPage: Bool = false) -> UUID? {
        guard let draft = addBar.draft(parser: parser, status: addStatus),
              let task = library.createTasks([draft])?.first else { return nil }
        addBarState.clearDraft()
        if openingPage { services.openPage(task.id) }
        selectOnly(nil)
        addedRequest = ScrollRequest(id: task.id)
        // Added from Done, the task goes to Now, out of sight: say where.
        if tab == .done, !openingPage { showToast(String(localized: "Added to Now")) }
        return task.id
    }

    /// Pasted lines: one task per line, or all of them as one task.
    /// The offer stays (with "Not saved · Retry") until the tasks exist.
    func acceptPaste(asOne: Bool) {
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
    @Published private(set) var addedRequest: ScrollRequest?

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
        let outcome = library.undo(in: .tasks)
        if outcome.isApplied { dismissToast() }
        return outcome
    }

    @discardableResult
    func redo() -> CommandOutcome {
        library.redo(in: .tasks)
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

    /// "Open page" (⌘Return, the menu, VoiceOver). A task in the lists goes
    /// to the host's detail route; a task in the Done log, which that route
    /// can't show, opens its read-only details here: its subtasks and the
    /// files it kept.
    func openPage(_ id: UUID) {
        if store.task(withID: id) != nil {
            services.openPage(id)
        } else if store.listedTask(withID: id) != nil {
            doneDetailID = id
        }
    }

    /// The Done log task whose details are open.
    @Published var doneDetailID: UUID?

    struct DoneDetail: Equatable {
        let title: String
        let finished: String
        let subtasks: [AtticSubtaskModel]
        let files: [TaskImageReference]

        static func == (lhs: DoneDetail, rhs: DoneDetail) -> Bool {
            lhs.title == rhs.title && lhs.finished == rhs.finished && lhs.files == rhs.files
                && lhs.subtasks.map(\.id) == rhs.subtasks.map(\.id)
        }
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
            subtasks: children.map { AtticSubtaskModel(id: $0.id, title: $0.title, isDone: $0.status == .done) },
            files: task.attachments
        )
    }
}
