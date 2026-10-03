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
            && lhs.model.attachments == rhs.model.attachments && lhs.model.titleMatch == rhs.model.titleMatch
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

/// A signal a task row's cell redraws on (see `TasksPageModel.cellUpdates`).
@MainActor
final class TasksCellUpdates: ObservableObject {
    /// Never fires: the rows of a page kept built but not drawn.
    static let quiet = TasksCellUpdates()
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
    @Published private(set) var selection: Set<UUID> = []
    /// The row a Shift-extension grows from (readable for the tests).
    private(set) var selectionAnchor: UUID?
    /// Rows whose quick look is open (remembered per row for the session).
    @Published private(set) var expanded: Set<UUID> = []
    @Published private(set) var editingTitleID: UUID?
    /// The title being edited, with its shorthand (owner fix 4): what is
    /// typed as `#tag`, a date or `!` becomes a chip and applies on save.
    @Published var titleEdit = TaskAddBarText()
    @Published var titleEditCaret: Int?
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
    @Published var newSubtaskTitle = ""
    /// A quick-look subtask being renamed in place (round 10), its text,
    /// and whether its save failed ("Not saved · Retry").
    @Published var renamingSubtaskID: UUID?
    @Published var subtaskRename = ""
    @Published var subtaskRenameFailed = false
    /// The subtask line that has the keyboard (round 10b). Not published: it
    /// only steers which row a shortcut targets, and never redraws.
    var focusedSubtaskID: UUID?
    /// The task row that has the keyboard: the page's focus, copied here as
    /// it changes so the rows' cells read it as they draw (deep review
    /// P2-04). Not published: the page tells the cells (`cellUpdates`).
    var keyboardFocus: AtticRowFocusID?
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
    /// The applied result query. Typing lives in its own small field state
    /// so it does not invalidate the page and its rows on every key.
    @Published var doneSearch = "" {
        didSet {
            doneSearchTask?.cancel()
            doneSearchInput.replace(doneSearch)
        }
    }
    let doneSearchInput = TasksDoneSearchInput()
    private var doneSearchTask: Task<Void, Never>?

    func typeDoneSearch(_ text: String) {
        doneSearchInput.edit(text)
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
    /// Where the page and the views are remembered across relaunch (L7).
    var memory: TasksPageMemory?
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

    init(library: AtticLibrary, services: TasksPageServices = TasksPageServices(), toasts: PanelToastCenter? = nil,
         memory: TasksPageMemory? = nil) {
        self.library = library
        self.services = services
        self.toasts = toasts ?? PanelToastCenter()
        self.memory = memory
        parser = TaskTextParser(calendar: services.calendar(), locale: services.locale, now: services.now)
        // A task that left the list (deleted, cleaned up) leaves the
        // selection and the quick look too.
        library.tasks.$revision
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pruneMissing() } }
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
        }
    }

    // MARK: - Lists

    private var today: DueDay { DueDay(date: services.now(), calendar: services.calendar()) }

    func rowModel(for task: TaskItem, match: String? = nil) -> TasksListRow {
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
        var model = TaskRowPresentation.row(for: task, subtasks: subtasks, today: today,
                                            calendar: services.calendar(), locale: services.locale)
        // Find's matches are marked in the title (item 6, as on Done).
        if let match, !match.isEmpty { model.titleMatch = match }
        return TasksListRow(
            id: task.id,
            model: model,
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
        let view: TasksViewOptions
        let search: String
    }

    /// What a page kept built but not drawn shows (round 11): while it is
    /// the same, the page is not redrawn when the model changes elsewhere (a
    /// selection, a keystroke), only when its own rows could have.
    struct PageToken: Equatable {
        let tab: TasksTab
        let revision: UInt64
        let held: [UUID: HeldPlace]
        let expanded: Set<UUID>
        let completedExpanded: Bool
        let today: DueDay
        let doneLog: [UUID]
        let search: String
        /// Now's and Later's view (item 6).
        let view: TasksViewOptions
        /// Whether this page is the one that answers the user (the tab
        /// shown, on screen): it gains and loses editors, focus and popovers
        /// with it (round 12).
        let owner: Bool
    }

    func pageToken(_ tab: TasksTab) -> PageToken {
        PageToken(tab: tab, revision: store.revision, held: held.filter { $0.value.tab == tab }, expanded: expanded,
                  completedExpanded: tab == .now && completedTodayExpanded, today: today,
                  doneLog: tab == .done ? doneLogTasks.map(\.id) : [], search: searchQuery(for: tab),
                  view: viewOptions(for: tab), owner: self.tab == tab && isPageShown)
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
                          completedExpanded: tab == .now && completedTodayExpanded, today: today,
                          view: viewOptions(for: tab), search: tab == .done ? "" : trimmedQuery(for: tab))
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
        // The view (item 6): each state's tasks filtered and ordered, the
        // states in their order. Find shows the open tasks whose title
        // matches (the finished ones are Done's to find). Work done only
        // when the rows are rebuilt (the cache's key holds the view).
        let view = viewOptions(for: tab)
        let query = trimmedQuery(for: tab)
        let day = today
        var tasks: [TaskItem]
        if view.isDefault, query.isEmpty {
            tasks = store.snapshot(for: scope).sections.flatMap(\.tasks)
        } else {
            tasks = store.snapshot(for: scope).sections.flatMap { section -> [TaskItem] in
                if !query.isEmpty {
                    guard section.status != .done else { return [] }
                    return view.sorted(section.tasks.filter { $0.title.localizedStandardContains(query) })
                }
                return view.sorted(section.tasks.filter { view.includes($0, today: day) })
            }
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

    /// The Done search's quiet count (owner item 17): how many done tasks
    /// match, of how many there are (today's done group and the Done log).
    /// Nil with no search, or when the log could not be counted.
    func doneSearchCount() -> (matches: Int, total: Int)? {
        let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let key = DoneCountKey(revision: store.revision, query: query)
        if let doneCountCache, doneCountCache.key == key { return doneCountCache.count }
        let today = store.snapshot(for: .tasks).sections.first { $0.status == .done }?.tasks ?? []
        var count: (matches: Int, total: Int)?
        if doneLogFailure == nil {
            let logMatches = store.indexedDoneLogCount(matching: query)
            let logTotal = store.indexedDoneLogCount()
            count = (today.filter { $0.title.localizedStandardContains(query) }.count + logMatches, today.count + logTotal)
        }
        doneCountCache = (key, count)
        return count
    }

    private struct DoneCountKey: Equatable {
        let revision: UInt64
        let query: String
    }

    private var doneCountCache: (key: DoneCountKey, count: (matches: Int, total: Int)?)?

    /// Loads the Done log's first page for the current search, if the store
    /// or the search changed since.
    func loadDoneLogIfNeeded() {
        let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard doneLogQuery != query || doneLogRevision != store.revision else { return }
        let limit = doneLogQuery == query ? max(Self.doneLogPageSize, doneLogTasks.count) : Self.doneLogPageSize
        let page = store.indexedDoneLogPage(limit: limit, matching: query)
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
    /// walks canonical matching IDs, so duplicate replicas never stop it.
    /// A failed read keeps what loaded and stops until Retry.
    func loadMoreDoneLog() {
        guard doneLogHasMore, doneLogFailure == nil else { return }
        let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if doneLogQuery != query { loadDoneLogIfNeeded(); return }
        if doneLogRevision != store.revision {
            loadDoneLogIfNeeded()
            guard doneLogHasMore, doneLogFailure == nil else { return }
        }
        let page = store.indexedDoneLogPage(from: doneLogCursor, limit: Self.doneLogPageSize, matching: doneLogQuery ?? "")
        setDoneLog(doneLogTasks + page.tasks)
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
        if doneLogQuery != doneSearch.trimmingCharacters(in: .whitespacesAndNewlines) || doneLogRevision != store.revision {
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
    /// What the picker finishes when a retried change saves (a new tag's
    /// typed name is cleared, as a first-time save clears it).
    private var pickerRetrySaved: (() -> Void)?

    /// Runs a picker's change; true when it saved (the caller may close
    /// or finish its input). `onSaved` runs if a later Retry saves it.
    @discardableResult
    func pickerChange(on id: UUID, onSaved: (() -> Void)? = nil, _ change: @escaping () -> CommandOutcome) -> Bool {
        let outcome = change()
        if let failure = outcome.failure {
            pickerFailure = RowFailure(id: id, message: failure.message, canRetry: failure.canRetry)
            pickerRetry = failure.canRetry ? change : nil
            pickerRetrySaved = failure.canRetry ? onSaved : nil
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
        guard finishEditing() else { return }
        revealTab = nil
        // The person went elsewhere: a `show` still waiting for its Done log
        // page is dropped, never finished later by a scroll (round 5, F3).
        pendingReveal = nil
        if !selection.isEmpty { selection = [] }
        if !bySwipe { PerformanceSignposts.beginPageChoice() }
        self.tab = tab
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
        let target: TasksTab = task.status == .backlog ? .backlog : (archived ? .done : .now)
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
        if target == .done {
            if doneSearch != doneSearchInput.text { doneSearch = doneSearchInput.text }
            let query = doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty, !task.title.localizedStandardContains(query) { doneSearch = "" }
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
        reveal(task.id)
        return .shown
    }

    private func reveal(_ id: UUID) {
        pendingReveal = nil
        selectOnly(id)
        scrollRequest = ScrollRequest(id: id, tab: tab)
    }

    /// Loads the Done log until `id`'s page is in, and says whether it is.
    /// A failed read or the paging bound (200 pages) is an incomplete
    /// result, never taken for success.
    private func revealInDoneLog(_ id: UUID) -> Bool {
        isRevealing = true
        defer { isRevealing = false }
        loadDoneLogIfNeeded()
        var pages = 0
        while !doneLogTasks.contains(where: { $0.id == id }), doneLogHasMore, doneLogFailure == nil, pages < 200 {
            loadMoreDoneLog()
            pages += 1
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
    var scrollOffsets: [TasksTab: CGFloat] = [:]

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
        let live = { (id: UUID) in self.store.task(withID: id) != nil || self.tab == .done }
        let keptSelection = selection.filter(live)
        if keptSelection != selection { selection = keptSelection }
        if let anchor = selectionAnchor, !live(anchor) { selectionAnchor = nil }
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
        guard held[id] != nil else { return }
        // Reduce Motion: no travel at all (review 22); a shorter slide is
        // still a slide.
        let reduceMotion = AtticMotionPreference.reducesMotion
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
        let changing = ids.filter { store.listedTask(withID: $0).map { $0.priority != priority } == true }
        guard !changing.isEmpty else { return .applied }
        let outcome = reachesDoneLog(changing)
            ? library.updateListedTasks(changing, priority: priority)
            : changing.count == 1
                ? library.updateTask(changing[0], priority: priority)
                : library.updateTasks(changing, priority: priority)
        if reachesDoneLogAfterEdit(changing) { reloadDoneLogAfterEdit() }
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
        // Done's rows too (round 10): a Done log task goes to Recently
        // Deleted with its family, and Undo puts it back in the log.
        let live = ids.filter { store.listedTask(withID: $0) != nil }
        guard !live.isEmpty else { return .failed(.taskGone) }
        let title = live.count == 1 ? store.listedTask(withID: live[0])?.title : nil
        let archived = reachesDoneLog(live)
        let outcome = archived ? library.deleteListedTasks(live) : library.deleteTasks(live)
        guard outcome.isApplied else { return outcome }
        if archived || tab == .done { reloadDoneLogAfterEdit() }
        if doneDetailID.map(live.contains) == true { doneDetailID = nil }
        selection.subtract(live)
        if let anchor = selectionAnchor, live.contains(anchor) { selectionAnchor = nil }
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
        // How the rows take their places is the page's to decide (its list
        // animates a reorder, or dissolves the two rows that exchanged
        // places, `TasksPage.reorderWithoutCrossing`): a transaction opened
        // here would override that choice.
        return library.moveTask(id, toIndex: destination)
    }

    /// A drag reorder: the row lands at `index` within its group.
    @discardableResult
    func move(_ id: UUID, toGroupIndex index: Int) -> CommandOutcome {
        library.moveTask(id, toIndex: index)
    }

    // MARK: - Title and subtasks

    func beginEditingTitle(_ id: UUID) {
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
        guard let id = editingTitleID else { return true }
        guard let task = store.listedTask(withID: id), let patch = titlePatch(for: task) else {
            editingTitleID = nil
            clearFailure(.title(id))
            return true
        }
        let saved = store.task(withID: id) == nil
            ? library.updateListedTasks([id], title: patch.title, priority: patch.priority, tags: patch.tags,
                                        dueDay: patch.dueDay.map { .some($0) })
            : library.updateTask(id, title: patch.title, priority: patch.priority, tags: patch.tags,
                                 dueDay: patch.dueDay.map { .some($0) })
        if store.task(withID: id) == nil { reloadDoneLogAfterEdit() }
        guard saved.isApplied else {
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
        if openingPage { services.openPage(task.id) }
        selectOnly(nil)
        addedRequest = ScrollRequest(id: task.id)
        // Added from Done, the task goes to Now, out of sight: say where.
        if tab == .done, !openingPage { showToast(String(localized: "Added to Now")) }
        // Added where the view or a Find hides it (item 6): say so.
        else if !openingPage, narrows(tab), !rows(for: tab).contains(where: { $0.id == task.id }) {
            showToast(String(localized: "Added · hidden by this view"))
        }
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
        // The bar is empty once the tasks exist, as after a single add (round
        // 12, CU: the draft stayed behind the batch).
        addBarState.clearDraft()
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
        let outcome = library.undo(in: .tasks)
        if outcome.isApplied {
            dismissToast()
            // The step is undone: the next ⌘Z is the field's typing again,
            // and ⇧⌘Z brings the step back.
            stepAtLastTextEdit = library.undo.undoStepID(in: .tasks)
            taskRedoIsNext = true
        }
        return outcome
    }

    @discardableResult
    func redo() -> CommandOutcome {
        let outcome = library.redo(in: .tasks)
        if outcome.isApplied { stepAtLastTextEdit = library.undo.undoStepID(in: .tasks) }
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
        stepAtLastTextEdit = library.undo.undoStepID(in: .tasks)
        taskRedoIsNext = false
    }

    /// A task change is newer than the draft's last edit: ⌘Z belongs to it.
    var taskChangeOwnsUndo: Bool {
        guard let top = library.undo.undoStepID(in: .tasks) else { return false }
        return top != stepAtLastTextEdit
    }

    /// The step a claimed ⌘Z just undid is waiting for ⇧⌘Z.
    var taskChangeOwnsRedo: Bool {
        taskRedoIsNext && library.undo.canRedo(in: .tasks)
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
            files: task.attachments
        )
    }
}
