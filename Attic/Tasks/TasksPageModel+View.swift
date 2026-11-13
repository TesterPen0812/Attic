import SwiftUI

/// What Now or Later shows and in what order (follow-up part 2, item 6,
/// option A): a filter by date, a filter by priority, and the order. Each
/// page keeps its own; Done has none (its log is by day). The store's
/// manual order is never changed by a sort: choosing Manual Order again
/// shows it as it was.
struct TasksViewOptions: Equatable, Codable, Sendable {
    /// The Date group ("Show" until 13 Nov): Any Date, Due or Overdue,
    /// Overdue Only.
    enum Show: String, Codable, CaseIterable, Sendable {
        case all, dueOrOverdue, overdueOnly
    }

    /// The Status group (Accepted 2026-11-13, 3A), on Now only: Any Status,
    /// In Progress, To Do. It combines with the date and the priority.
    enum Status: String, Codable, CaseIterable, Sendable {
        case any, inProgress, toDo
    }

    enum Priority: String, Codable, CaseIterable, Sendable {
        case any, mediumAndHigh, highOnly
    }

    enum Sort: String, Codable, CaseIterable, Sendable {
        case manual, dueDate, priority
    }

    var status = Status.any
    var show = Show.all
    var priority = Priority.any
    var sort = Sort.manual

    init(status: Status = .any, show: Show = .all, priority: Priority = .any, sort: Sort = .manual) {
        self.status = status
        self.show = show
        self.priority = priority
        self.sort = sort
    }

    private enum CodingKeys: String, CodingKey { case status, show, priority, sort }

    /// A view saved before a group existed reads that group as its default
    /// (views remembered before 13 Nov have no status).
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decodeIfPresent(Status.self, forKey: .status) ?? .any
        show = try values.decodeIfPresent(Show.self, forKey: .show) ?? .all
        priority = try values.decodeIfPresent(Priority.self, forKey: .priority) ?? .any
        sort = try values.decodeIfPresent(Sort.self, forKey: .sort) ?? .manual
    }

    /// Something is hidden: the button's dot and the "Show All" line.
    var filters: Bool { status != .any || show != .all || priority != .any }
    var isDefault: Bool { self == TasksViewOptions() }

    /// The view with its filters gone and its order kept (Show All, Clear
    /// Filters).
    var unfiltered: TasksViewOptions { TasksViewOptions(sort: sort) }

    /// Whether an open task is shown. Finished tasks (Now's "Completed
    /// today") are never filtered: the view is about what is left to do.
    func includes(_ task: TaskItem, today: DueDay) -> Bool {
        guard task.status != .done else { return true }
        switch status {
        case .any: break
        case .inProgress: guard task.status == .inProgress else { return false }
        case .toDo: guard task.status == .todo else { return false }
        }
        switch show {
        case .all: break
        case .dueOrOverdue: guard task.dueDay != nil else { return false }
        case .overdueOnly: guard let day = task.dueDay, day < today else { return false }
        }
        switch priority {
        case .any: return true
        case .mediumAndHigh: return task.priority == .medium || task.priority == .high
        case .highOnly: return task.priority == .high
        }
    }

    /// One state's tasks in this view's order. Stable: ties keep the manual
    /// order, and started tasks stay above the rest (the list is sorted by
    /// state first, as always).
    func sorted(_ tasks: [TaskItem]) -> [TaskItem] {
        switch sort {
        case .manual:
            return tasks
        case .dueDate:
            // Earliest first; tasks with no date after every dated one.
            return tasks.enumerated().sorted { lhs, rhs in
                switch (lhs.element.dueDay, rhs.element.dueDay) {
                case let (left?, right?) where left != right: return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.offset < rhs.offset
                }
            }.map(\.element)
        case .priority:
            return tasks.enumerated().sorted { lhs, rhs in
                let left = lhs.element.priority.rank, right = rhs.element.priority.rank
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        }
    }

    /// The quiet line under the tabs while something is filtered ("Due or
    /// overdue · by due date"), and what VoiceOver hears.
    var summary: String {
        var parts = filterWords
        if parts.isEmpty { parts.append(String(localized: "All tasks")) }
        if let order = orderWords { parts.append(order) }
        return parts.joined(separator: " · ")
    }

    /// Each filter that is on, in the menu's order ("In progress", "Due or
    /// overdue", "High priority only").
    var filterWords: [String] {
        var parts: [String] = []
        switch status {
        case .any: break
        case .inProgress: parts.append(String(localized: "In progress"))
        case .toDo: parts.append(String(localized: "To do"))
        }
        switch show {
        case .all: break
        case .dueOrOverdue: parts.append(String(localized: "Due or overdue"))
        case .overdueOnly: parts.append(String(localized: "Overdue only"))
        }
        switch priority {
        case .any: break
        case .mediumAndHigh: parts.append(String(localized: "Medium and high priority"))
        case .highOnly: parts.append(String(localized: "High priority only"))
        }
        return parts
    }

    /// The order, when it is not the manual one ("by due date").
    var orderWords: String? {
        switch sort {
        case .manual: nil
        case .dueDate: String(localized: "by due date")
        case .priority: String(localized: "by priority")
        }
    }

    /// The View Options button's VoiceOver value ("All tasks, manual
    /// order"; "Due or overdue, by due date").
    var spokenValue: String {
        let summary = summary.replacingOccurrences(of: " · ", with: ", ")
        return sort == .manual ? String(localized: "\(summary), manual order") : summary
    }
}

extension TaskPriority {
    /// High first when sorting by priority.
    var rank: Int {
        switch self {
        case .none: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }
}

/// Find and View Options on Now and Later (follow-up part 2, item 6).
extension TasksPageModel {
    /// The page's view (Now and Later; Done's is always the default).
    func viewOptions(for tab: TasksTab) -> TasksViewOptions {
        guard tab != .done else { return TasksViewOptions() }
        var options = viewOptionsByTab[tab] ?? TasksViewOptions()
        // Status is on Now only: Backlog holds only backlog tasks.
        if tab == .backlog { options.status = .any }
        return options
    }

    /// A choice in View Options (or Show All, Reset View): only that page
    /// changes. Rows the view hides leave the selection; VoiceOver hears
    /// what is shown now. Remembered with the page (L7).
    /// ••• on Done (Accepted 2026-11-05, "Page-specific options"): Done has
    /// no view options (its log is by day), so it offers what its days do.
    func doneCommands() -> [AtticMenuCommand] {
        let days = doneDays()
        let folded = days.filter(\.folded).count
        return [
            AtticMenuCommand(verbatim: String(localized: "Collapse All Days"), isDisabled: folded == days.count) { [weak self] in
                self?.setDoneDaysFolded(true)
            },
            AtticMenuCommand(verbatim: String(localized: "Expand All Days"), isDisabled: folded == 0) { [weak self] in
                self?.setDoneDaysFolded(false)
            }
        ]
    }

    private func setDoneDaysFolded(_ folded: Bool) {
        foldAllGroups(doneDays().map(\.key), folded: folded, on: .done)
    }

    func setViewOptions(_ options: TasksViewOptions, for tab: TasksTab) {
        var options = options
        if tab == .backlog { options.status = .any }
        guard tab != .done, options != viewOptions(for: tab) else { return }
        viewOptionsByTab[tab] = options.isDefault ? nil : options
        memory?.saveViewOptions(viewOptionsByTab)
        pruneInvisibleSelection(on: tab)
        announceView(on: tab)
    }

    /// What VoiceOver hears after the view changed: "Showing in-progress
    /// tasks in work or home" (the drawing's line), or "Showing all tasks".
    func announceView(on tab: TasksTab) {
        AccessibilityNotification.Announcement(spokenView(on: tab)).post()
    }

    func spokenView(on tab: TasksTab) -> String {
        let options = viewOptions(for: tab), picks = tagPicks(on: tab)
        guard options.filters || options.sort != .manual || !picks.isEmpty else { return String(localized: "Showing all tasks") }
        var words: String
        switch options.status {
        case .any: words = String(localized: "tasks")
        case .inProgress: words = String(localized: "in-progress tasks")
        case .toDo: words = String(localized: "to-do tasks")
        }
        if !picks.isEmpty { words += " " + String(localized: "in \(picks.spokenPhrase)") }
        var rest = options.filterWords
        if options.status != .any { rest.removeFirst() }
        if let order = options.orderWords { rest.append(order) }
        let detail = ([words] + rest.map { $0.lowercased() }).joined(separator: ", ")
        return String(localized: "Showing \(detail)")
    }

    /// "Show All" and Clear Filters: the filters and the picked tags go,
    /// the order stays.
    func showAll(on tab: TasksTab) {
        let options = viewOptions(for: tab).unfiltered
        if !tagPicks.isEmpty { tagPicks = .none }
        if options != viewOptions(for: tab) {
            setViewOptions(options, for: tab)
        } else {
            pruneInvisibleSelection(on: tab)
            announceView(on: tab)
        }
    }

    /// Reset View (•••): everything back, the order and the tags too.
    func resetView(on tab: TasksTab) {
        if !tagPicks.isEmpty { tagPicks = .none }
        if tab != .done, !viewOptions(for: tab).isDefault {
            setViewOptions(TasksViewOptions(), for: tab)
        } else {
            announceView(on: tab)
        }
    }

    /// Done's view line: tags picked and no search (the search has its count).
    var showsDoneViewLine: Bool {
        !tagPicks.isEmpty && doneSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether anything filters the page (the view line, ••• dot).
    func filtered(on tab: TasksTab) -> Bool {
        viewOptions(for: tab).filters || !tagPicks(on: tab).isEmpty
    }

    /// Drag, ⌘↑ ⌘↓ and Move Up/Down work only in Manual Order: a sorted
    /// list has no place to move a task to.
    func reorders(on tab: TasksTab) -> Bool {
        tab != .done && viewOptions(for: tab).sort == .manual
    }

    /// Whether the page shows fewer tasks than it has (a filter or a Find):
    /// a reorder then moves among what is shown (`moveVisible`).
    func narrows(_ tab: TasksTab) -> Bool {
        viewOptions(for: tab).filters || !searchQuery(for: tab).isEmpty || !tagPicks(on: tab).isEmpty
    }

    // MARK: Tag chips (owner, 2026-10-28)

    /// The tags filtering `tab`: the same for every tab, Done included (T6,
    /// Accepted 2026-11-01, which removed Done's exception).
    func tagPicks(on tab: TasksTab) -> TagPicks {
        tagPicks
    }

    /// The chips after All: the tags on the tasks that exist (Now's,
    /// Later's and, since T6, Done's: today's and the Done log's, from its
    /// index), in the library's order (most used first). Built once per
    /// change.
    func tagChips() -> [String] {
        let revision = store.revision, inventory = tagInventoryRevision
        if let cache = tagChipsCache, cache.revision == revision, cache.inventory == inventory { return cache.tags }
        var inUse = Set<String>()
        var firstSeen: [String] = []
        for scope in [TaskScope.tasks, .backlog] {
            for section in store.snapshot(for: scope).sections {
                for task in section.tasks {
                    for tag in task.tags where inUse.insert(tag).inserted { firstSeen.append(tag) }
                }
            }
        }
        for tag in store.indexedDoneLogTags().sorted() where inUse.insert(tag).inserted { firstSeen.append(tag) }
        let ordered = library.tags.names.filter { inUse.contains($0) }
        let listed = Set(ordered)
        let tags = ordered + firstSeen.filter { !listed.contains($0) }
        tagChipsCache = (revision, inventory, tags)
        return tags
    }

    /// A click on a pill (Accepted 2026-11-13, 2B): a tag joins the pick or
    /// leaves it; All (nil) clears it. Rows it hides leave the selection.
    func chooseTagChip(_ tag: String?) {
        setTagPicks(tagPicks.toggling(tag))
    }

    /// The Any · All switch, shown with two or more tags picked.
    func setTagMatch(_ match: TagPicks.Match) {
        setTagPicks(tagPicks.matching(match))
    }

    func setTagPicks(_ picks: TagPicks) {
        guard picks != tagPicks else { return }
        tagPicks = picks
        pruneInvisibleSelection(on: tab)
        announceView(on: tab)
    }

    /// A picked tag that left every task (deleted, removed, or renamed and
    /// then undone) drops out of the pick, one by one; with none left the
    /// filter ends, so the list never waits on a tag that no longer exists.
    func pruneTagPicks() {
        guard !tagPicks.isEmpty else { return }
        let kept = tagPicks.keeping(tagChips())
        if kept != tagPicks { tagPicks = kept }
    }

    // MARK: Find

    /// The page's Find (Done's is its search): what is typed, per page.
    func searchQuery(for tab: TasksTab) -> String {
        tab == .done ? doneSearchInput.text : (listSearch[tab] ?? "")
    }

    func setSearchQuery(_ text: String, for tab: TasksTab) {
        if tab == .done {
            if doneSearch != text || doneSearchInput.text != text { doneSearch = text }
        } else if (listSearch[tab] ?? "") != text {
            listSearch[tab] = text.isEmpty ? nil : text
        }
    }

    /// The trimmed query that filters the page.
    func trimmedQuery(for tab: TasksTab) -> String {
        (tab == .done ? doneSearch : searchQuery(for: tab)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Find field's placeholder.
    func searchPlaceholder(for tab: TasksTab) -> String {
        switch tab {
        case .now: String(localized: "Search Now")
        case .backlog: String(localized: "Search Backlog")
        case .done: String(localized: "Search done tasks")
        }
    }

    /// Find's quiet count on Now and Later ("1 of 5 tasks on Now"): the
    /// open tasks that match, of all the page's open tasks.
    func listSearchCount(for tab: TasksTab) -> (matches: Int, total: Int)? {
        guard tab != .done, !trimmedQuery(for: tab).isEmpty else { return nil }
        let scope: TaskScope = tab == .backlog ? .backlog : .tasks
        let total = store.snapshot(for: scope).sections.filter { $0.status != .done }.reduce(0) { $0 + $1.tasks.count }
        return (sections(for: tab).open.count, total)
    }

    /// T3 (Accepted 2026-11-01): while you search on `tab`, how many tasks
    /// match the same query (and tag) on each other tab, in the switch's
    /// order, leaving out a tab with none. Now and Later count their open
    /// tasks as their Find does; Done counts today's finished tasks and the
    /// Done log through its index (no page is read), as its own count does.
    func searchMatchesElsewhere(from tab: TasksTab) -> [TasksElsewhereCount] {
        let query = trimmedQuery(for: tab)
        guard !query.isEmpty else { return [] }
        let key = TasksElsewhereKey(revision: store.revision, query: query, tag: tagPicks, from: tab)
        if let cache = elsewhereCountsCache, cache.key == key { return cache.counts }
        let tag = tagPicks
        let tagged: (TaskItem) -> Bool = { task in tag.matches(task.tags) }
        var counts: [TasksElsewhereCount] = []
        for other in TasksTab.allCases where other != tab {
            let count: Int
            switch other {
            case .now, .backlog:
                let scope: TaskScope = other == .backlog ? .backlog : .tasks
                count = store.snapshot(for: scope).sections.filter { $0.status != .done }.reduce(0) { total, section in
                    total + section.tasks.filter { tagged($0) && store.matchesItemSearch($0, query: query) }.count
                }
            case .done:
                count = store.doneTodayTasks().filter { tagged($0) && store.matchesItemSearch($0, query: query) }.count
                    + store.indexedDoneLogCount(matching: query, tags: tag)
            }
            if count > 0 { counts.append(TasksElsewhereCount(tab: other, count: count)) }
        }
        elsewhereCountsCache = (key, counts)
        return counts
    }

    /// A click on "2 in Later" (T3): that tab, with the query kept.
    func followSearch(from tab: TasksTab, to target: TasksTab) {
        let query = trimmedQuery(for: tab)
        guard !query.isEmpty, target != tab else { return }
        setSearchQuery(query, for: target)
        select(tab: target)
    }

    /// A reorder while the page shows only some tasks (a filter or Find, in
    /// Manual Order): `id` takes the place of the shown task at `index` of
    /// `shown` (its state's rows as the page shows them), among all of
    /// them. The hidden ones keep their places around it.
    @discardableResult
    /// The date group a row is drawn in (nil for a done row under
    /// "Completed today").
    func groupKey(of id: UUID, on tab: TasksTab) -> String? {
        sections(for: tab).groups.first { $0.ids.contains(id) }?.key
    }

    /// The rows of one state in `id`'s date group, as drawn: where a
    /// keyboard or drag reorder can take it.
    func shownGroup(of id: UUID, status: TaskStatus, on tab: TasksTab) -> [UUID] {
        let sections = sections(for: tab)
        guard let key = groupKey(of: id, on: tab) else {
            return rows(for: tab).filter { $0.status == status }.map(\.id)
        }
        return (sections.groupRows[key] ?? []).filter { $0.status == status }.map(\.id)
    }

    func moveVisible(_ id: UUID, toShownIndex index: Int, in shown: [UUID]) -> CommandOutcome {
        settlePendingCompletionAcknowledgements()
        guard let task = store.task(withID: id) else { return .failed(.taskGone) }
        guard shown.indices.contains(index), shown[index] != id else { return .applied }
        let group = store.orderGroup(of: task).map(\.id)
        guard let destination = group.firstIndex(of: shown[index]) else { return .applied }
        return library.moveTask(id, toIndex: destination)
    }
}

/// Where the Tasks page remembers its place across relaunch (L7): the page
/// shown and each page's view. One per panel (the shell's one panel);
/// nil in tests that don't ask for it.
struct TasksPageMemory {
    let defaults: UserDefaults
    var key = "AtticTasksPanel"

    private var pageKey: String { key + ".page" }
    private var viewKey: String { key + ".views" }

    static let removedKeys = ["AtticTasksPanel.page", "AtticTasksPanel.views", "AtticTasksPanel.scroll"]

    var scrollOffsets: [TasksTab: CGFloat] {
        let stored = defaults.dictionary(forKey: key + ".scroll") ?? [:]
        var result: [TasksTab: CGFloat] = [:]
        for (raw, value) in stored {
            if let raw = Int(raw), let tab = TasksTab(rawValue: raw), let y = value as? Double,
               y.isFinite, abs(y) < 10_000_000 { result[tab] = CGFloat(y) }
        }
        return result
    }

    func saveScrollOffsets(_ offsets: [TasksTab: CGFloat]) {
        defaults.set(Dictionary(uniqueKeysWithValues: offsets.compactMap { tab, y in
            y.isFinite ? (String(tab.rawValue), Double(y)) : nil
        }), forKey: key + ".scroll")
    }

    var page: TasksTab? {
        (defaults.object(forKey: pageKey) as? Int).flatMap(TasksTab.init(rawValue:))
    }

    func savePage(_ tab: TasksTab) {
        if (defaults.object(forKey: pageKey) as? Int) != tab.rawValue { defaults.set(tab.rawValue, forKey: pageKey) }
    }

    var viewOptions: [TasksTab: TasksViewOptions] {
        guard let data = defaults.data(forKey: viewKey),
              let stored = try? JSONDecoder().decode([Int: TasksViewOptions].self, from: data) else { return [:] }
        var result: [TasksTab: TasksViewOptions] = [:]
        for (raw, options) in stored {
            if let tab = TasksTab(rawValue: raw), tab != .done, !options.isDefault { result[tab] = options }
        }
        return result
    }

    func saveViewOptions(_ options: [TasksTab: TasksViewOptions]) {
        let stored = Dictionary(uniqueKeysWithValues: options.map { ($0.key.rawValue, $0.value) })
        if stored.isEmpty {
            defaults.removeObject(forKey: viewKey)
        } else if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: viewKey)
        }
    }
}

/// One part of Find's count line on another tab ("2 in Later", T3).
struct TasksElsewhereCount: Equatable {
    let tab: TasksTab
    let count: Int
}

struct TasksElsewhereKey: Equatable {
    let revision: UInt64
    let query: String
    let tag: TagPicks
    let from: TasksTab
}

extension TasksPageModel {
    /// The rows on show on the current tab, top to bottom, in the window's
    /// coordinates: `ids` only, or every row. Rows out of view are left out.
    func agentRowFrames(_ ids: Set<UUID>?) -> [(id: UUID, frame: CGRect)] {
        guard let pointer = rowPointer, let view = pointer.view, view.window != nil else { return [] }
        let listed = TasksMarqueeSelection.rowIDs(in: self, tab: tab)
        return listed.compactMap { id -> (id: UUID, frame: CGRect)? in
            guard ids?.contains(id) ?? true, let frame = pointer.frames[TasksRowID(tab: tab, id: id)],
                  frame.intersects(view.bounds) else { return nil }
            return (id, view.convert(frame, to: nil))
        }
    }
}

/// A filtered view, as far as "stays until the view changes" goes: its
/// filters, its order and its tags (`TasksPageModel.buildRows`).
struct TasksStayKey: Equatable {
    let view: TasksViewOptions
    let picks: TagPicks
}
