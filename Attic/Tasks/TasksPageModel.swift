import AppKit
import Combine
import SwiftUI

/// Where the Tasks page is: Now (in progress, to do, and today's done),
/// Backlog, or the Done log.
enum TasksTab: Int, CaseIterable, Hashable, Identifiable {
    case now, backlog, done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .now: String(localized: "Now")
        case .backlog: String(localized: "Backlog")
        case .done: String(localized: "Done")
        }
    }

    /// The page's one title (v9): the Now list is the Tasks page itself.
    var pageTitle: String {
        switch self {
        case .now: String(localized: "Tasks")
        case .backlog: String(localized: "Backlog")
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

    /// The page pill's icon: the status circle's state for the page.
    var pillIcon: AtticPagePillIcon {
        switch self {
        case .now: .open
        case .backlog: .dashed
        case .done: .done
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
    @Published var editingTitle = ""
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
    /// index they held (spec: "stays in place, then slides").
    @Published private(set) var held: [UUID: Int] = [:]
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
    private var doneLogQuery: String?
    private var doneLogRevision: UInt64?
    private var doneLogCursor = TaskStore.DoneLogCursor()
    /// The tab a dragged row is over (Now or Backlog): it outlines.
    @Published var dropTargetTab: TasksTab?

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
        let subtasks = store.parent(of: task) == nil ? store.subtasks(of: task.id) : []
        let open = expanded.contains(task.id)
        return TasksListRow(
            id: task.id,
            model: TaskRowPresentation.row(for: task, subtasks: subtasks, today: today,
                                           calendar: services.calendar(), locale: services.locale),
            status: task.status,
            subtasks: open ? subtasks.map { AtticSubtaskModel(id: $0.id, title: $0.title, isDone: $0.status == .done) } : []
        )
    }

    private struct RowsKey: Equatable {
        let tab: TasksTab
        let revision: UInt64
        let held: [UUID: Int]
        let expanded: Set<UUID>
        let today: DueDay
    }

    /// Rows are rebuilt only when something they show changed: SwiftUI asks
    /// for them many times per change.
    private var rowsCache: [TasksTab: (key: RowsKey, rows: [TasksListRow])] = [:]

    /// Now: in progress, then to do, then today's done; Backlog: its tasks.
    /// Empty groups take no space. A task just finished holds its place.
    func rows(for tab: TasksTab) -> [TasksListRow] {
        let key = RowsKey(tab: tab, revision: store.revision, held: tab == .now ? held : [:], expanded: expanded, today: today)
        if let cached = rowsCache[tab], cached.key == key { return cached.rows }
        let rows = buildRows(for: tab)
        rowsCache[tab] = (key, rows)
        return rows
    }

    private func buildRows(for tab: TasksTab) -> [TasksListRow] {
        let scope: TaskScope = tab == .backlog ? .backlog : .tasks
        var tasks = store.snapshot(for: scope).sections.flatMap(\.tasks)
        if tab == .now, !held.isEmpty {
            let holding = held.sorted { $0.value < $1.value }
            let heldTasks = holding.compactMap { id, _ in tasks.first { $0.id == id } }
            tasks.removeAll { held[$0.id] != nil }
            for task in heldTasks {
                tasks.insert(task, at: min(held[task.id] ?? 0, tasks.count))
            }
        }
        return tasks.map(rowModel(for:))
    }

    var nowCount: Int { store.snapshot(for: .tasks).activeCount }
    var backlogCount: Int { store.snapshot(for: .backlog).visibleCount }
    var hasDoneToday: Bool { store.snapshot(for: .tasks).sections.contains { $0.status == .done } }

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
        doneLogQuery = query
        doneLogRevision = store.revision
        doneLogTasks = page.tasks
        doneLogCursor = page.next
        doneLogHasMore = page.hasMore
    }

    /// The next page, when the last loaded row comes on screen. The cursor
    /// walks physical rows, so duplicates and superseded copies never stop it.
    func loadMoreDoneLog() {
        guard doneLogHasMore else { return }
        let page = store.doneLogPage(from: doneLogCursor, limit: Self.doneLogPageSize, matching: doneLogQuery,
                                     excluding: Set(doneLogTasks.map(\.id)))
        doneLogTasks += page.tasks
        doneLogCursor = page.next
        doneLogHasMore = page.hasMore
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
        if let id = editingTitleID,
           editingTitle.trimmingCharacters(in: .whitespacesAndNewlines) != (store.task(withID: id)?.title ?? "") {
            return true
        }
        return newSubtaskParentID != nil && !newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where the current reveal opened the page (Search, an agent's `show`);
    /// nil opens on Now. Cleared when the panel hides or the person moves.
    private var revealTab: TasksTab?

    /// The panel hid: the next reveal opens on Now again.
    func pageDidHide() {
        revealTab = nil
    }

    /// Moving to another page saves an open edit first; if that save
    /// fails, the page stays with the text and Retry (Esc discards it).
    func select(tab: TasksTab) {
        guard tab != self.tab else { return }
        if hasUnsavedEdit {
            guard commitTitle(), commitNewSubtask() else { return }
        }
        revealTab = nil
        cancelEditing()
        selection = []
        self.tab = tab
    }

    /// Search (the menu-bar item): the Done page, whose bottom bar searches
    /// the Done log. The caller puts the keyboard in that bar.
    func beginSearch() {
        cancelEditing()
        selection = []
        tab = .done
        revealTab = .done
    }

    /// An agent's `show` of a task: the tab that lists it, the row selected
    /// and scrolled into view. Returns false when no list shows it.
    @discardableResult
    func show(_ id: UUID) -> Bool {
        guard let found = store.listedTask(withID: id) else { return false }
        // A subtask shows in its parent's quick look.
        let parent = store.task(withID: id).flatMap { store.parent(of: $0) }
        let task = parent ?? found
        let target: TasksTab = task.status == .backlog ? .backlog
            : (store.task(withID: task.id) == nil ? .done : .now)
        cancelEditing()
        tab = target
        revealTab = target
        if parent != nil { expanded.insert(task.id) }
        selectOnly(task.id)
        scrollRequest = ScrollRequest(id: task.id)
        return true
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

    /// The circle's click and Space (spec § The status circle): to do →
    /// in progress → done; done → to do; backlog → Now as to do.
    func advance(_ id: UUID) {
        guard let task = store.listedTask(withID: id) else { return }
        switch task.status {
        case .todo: library.updateTask(id, status: .inProgress)
        case .inProgress: complete(id)
        case .done: restoreToNow(id)
        case .backlog: library.updateTask(id, status: .todo)
        }
    }

    /// Option-click, ⇧Space (and ⌥Space): done in one step, with any open
    /// subtasks. The row holds its place for about a second, then slides.
    func complete(_ id: UUID) {
        guard let task = store.task(withID: id), task.status != .done else { return }
        let index = rows(for: .now).firstIndex { $0.id == id }
        guard library.completeTask(id) else { return }
        if tab == .now, let index { hold(id, at: index) }
    }

    private func hold(_ id: UUID, at index: Int) {
        held[id] = index
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
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(AtticMotionPreset.doneSlide.animation(reduceMotion: reduceMotion)) {
            _ = held.removeValue(forKey: id)
        }
    }

    func setStatus(_ status: TaskStatus, for ids: [UUID]) {
        if status == .done {
            if ids.count == 1 { complete(ids[0]) } else { library.updateTasks(ids, status: .done) }
            return
        }
        let loggedOrDone = ids.filter { store.task(withID: $0)?.status == .done || store.task(withID: $0) == nil }
        if ids.count == 1, loggedOrDone == ids, status == .todo {
            restoreToNow(ids[0])
            return
        }
        if ids.count == 1 {
            library.updateTask(ids[0], status: status, allowingUnfinishedSubtasks: true)
        } else {
            library.updateTasks(ids, status: status)
        }
    }

    func setPriority(_ priority: TaskPriority, for ids: [UUID]) {
        if ids.count == 1 {
            library.updateTask(ids[0], priority: priority)
        } else {
            library.updateTasks(ids, priority: priority)
        }
    }

    func addTag(_ tag: String, to ids: [UUID]) {
        guard let tag = AtticTag.normalize(tag) else { return }
        library.updateTasks(ids, addingTag: tag)
    }

    /// ⌘B and the menu: to Backlog, with an Undo toast (a move).
    func moveToBacklog(_ ids: [UUID]) {
        let movable = ids.filter { store.task(withID: $0).map { $0.status != .backlog } == true }
        guard !movable.isEmpty else { return }
        let succeeded = movable.count == 1
            ? library.updateTask(movable[0], status: .backlog, allowingUnfinishedSubtasks: true)
            : library.updateTasks(movable, status: .backlog)
        guard succeeded else { return }
        selection.subtract(movable)
        showToast(movable.count == 1 ? String(localized: "Moved to Backlog") : String(localized: "Moved \(movable.count) tasks to Backlog"))
    }

    /// Back to Now as to do (from Backlog), with an Undo toast.
    func moveToNow(_ ids: [UUID]) {
        let movable = ids.filter { store.task(withID: $0)?.status == .backlog }
        guard !movable.isEmpty else { return }
        let succeeded = movable.count == 1
            ? library.updateTask(movable[0], status: .todo)
            : library.updateTasks(movable, status: .todo)
        guard succeeded else { return }
        selection.subtract(movable)
        showToast(movable.count == 1 ? String(localized: "Moved to Now") : String(localized: "Moved \(movable.count) tasks to Now"))
    }

    /// A finished task (today's or the Done log's) back to Now as to do.
    func restoreToNow(_ id: UUID) {
        guard library.restoreToNow(id) else { return }
        if tab == .done { showToast(String(localized: "Restored to Now")) }
        doneLogRevision = nil
        loadDoneLogIfNeeded()
    }

    /// Delete: to Recently Deleted, with the Undo toast (6 s; ⌘Z works too).
    func delete(_ ids: [UUID]) {
        let live = ids.filter { store.task(withID: $0) != nil }
        guard !live.isEmpty else { return }
        let title = live.count == 1 ? store.task(withID: live[0])?.title : nil
        guard library.deleteTasks(live) else { return }
        selection.subtract(live)
        expanded.subtract(live)
        if let title {
            showToast(String(localized: "Deleted “\(title)”"))
        } else {
            showToast(String(localized: "Deleted \(live.count) tasks"))
        }
    }

    // MARK: - Order

    /// ⌘↑ ⌘↓: one place up or down within the task's group.
    func moveBy(_ id: UUID, offset: Int) {
        guard let task = store.task(withID: id) else { return }
        let group = store.orderGroup(of: task)
        guard let index = group.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard group.indices.contains(destination) else { return }
        withAnimation(AtticMotionPreset.settle.animation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
            _ = library.moveTask(id, toIndex: destination)
        }
    }

    /// A drag reorder: the row lands at `index` within its group.
    func move(_ id: UUID, toGroupIndex index: Int) {
        library.moveTask(id, toIndex: index)
    }

    // MARK: - Title and subtasks

    func beginEditingTitle(_ id: UUID) {
        guard let task = store.task(withID: id) else { return }
        newSubtaskParentID = nil
        editingTitle = task.title
        editingTitleID = id
    }

    /// Return (or leaving the field) saves the title. The editor closes only
    /// once the save succeeded: a failed save keeps the field open with the
    /// text and "Not saved · Retry". Returns whether the edit is finished.
    @discardableResult
    func commitTitle() -> Bool {
        guard let id = editingTitleID else { return true }
        let title = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let task = store.task(withID: id), task.title != title else {
            editingTitleID = nil
            clearFailure(.title(id))
            return true
        }
        guard library.updateTask(id, title: title) else {
            failedSave = .title(id)
            return false
        }
        editingTitleID = nil
        clearFailure(.title(id))
        return true
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
            expanded.remove(id)
            if newSubtaskParentID == id { newSubtaskParentID = nil }
        } else {
            expanded.insert(id)
        }
    }

    func setExpanded(_ id: UUID, _ open: Bool) {
        if open != expanded.contains(id) { toggleExpanded(id) }
    }

    func beginAddingSubtask(to id: UUID) {
        expanded.insert(id)
        editingTitleID = nil
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

    func toggleSubtask(_ id: UUID) {
        guard let task = store.task(withID: id) else { return }
        library.updateTask(id, status: task.status == .done ? .todo : .done)
    }

    // MARK: - Add bar

    var addStatus: TaskStatus { tab == .backlog ? .backlog : .todo }

    var addPlaceholder: String {
        switch tab {
        case .now: String(localized: "Add a task")
        case .backlog: String(localized: "Add to backlog")
        case .done: String(localized: "Search done tasks")
        }
    }

    var addBarChips: [NSRange] {
        addBar.chips(parser: parser, caret: addBarCaret)
    }

    /// Return adds and keeps the bar focused; ⌘Return adds and opens the
    /// task's page. Returns the new task.
    @discardableResult
    func submitAddBar(openingPage: Bool = false) -> UUID? {
        guard let draft = addBar.draft(parser: parser, status: addStatus),
              let task = library.createTasks([draft])?.first else { return nil }
        addBar.clear()
        if openingPage { services.openPage(task.id) }
        selectOnly(nil)
        return task.id
    }

    /// Pasted lines: one task per line, or all of them as one task.
    /// The offer stays (with "Not saved · Retry") until the tasks exist.
    func acceptPaste(asOne: Bool) {
        guard let offer = pasteOffer else { return }
        let builder = TaskDraftBuilder(parser: parser, status: addStatus)
        let drafts = builder.drafts(from: offer.text, mode: asOne ? .single : .onePerLine)
        guard library.createTasks(drafts) != nil else {
            failedSave = .paste
            lastPasteAsOne = asOne
            return
        }
        clearFailure(.paste)
        pasteOffer = nil
    }

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

    func undo() {
        _ = library.undo.undo(in: .tasks)
        dismissToast()
    }

    func redo() {
        _ = library.undo.redo(in: .tasks)
    }

    /// Posts "… · Undo" to the shell's toast host (6 s, held while the
    /// pointer rests on it); its button undoes the step it announced, and
    /// only that step: a newer change (a task added, a title edited, an
    /// agent's edit) takes the toast away, and its button never reaches
    /// past the step it names.
    func showToast(_ message: String) {
        let step = library.undo.undoStepID(in: .tasks)
        postedToastStep = step
        postedToastID = toasts.show(message) { [weak self] in
            guard let self, let step, self.library.undo.undoStepID(in: .tasks) == step else { return }
            _ = self.library.undo.undo(in: .tasks)
        }.id
    }

    /// A change after the toast's step (or an undo of it) makes the toast
    /// stale: it goes.
    private func dismissToastIfSuperseded() {
        guard postedToastID != nil, library.undo.undoStepID(in: .tasks) != postedToastStep else { return }
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
        let children = store.task(withID: id) != nil ? store.subtasks(of: id) : store.doneLogSubtasks(of: id)
        return DoneDetail(
            title: task.title,
            finished: finished,
            subtasks: children.map { AtticSubtaskModel(id: $0.id, title: $0.title, isDone: $0.status == .done) },
            files: task.attachments
        )
    }
}
