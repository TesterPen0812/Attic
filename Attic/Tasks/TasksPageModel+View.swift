import SwiftUI

/// What Now or Later shows and in what order (follow-up part 2, item 6,
/// option A): a filter by date, a filter by priority, and the order. Each
/// page keeps its own; Done has none (its log is by day). The store's
/// manual order is never changed by a sort: choosing Manual Order again
/// shows it as it was.
struct TasksViewOptions: Equatable, Codable, Sendable {
    enum Show: String, Codable, CaseIterable, Sendable {
        case all, dueOrOverdue, overdueOnly
    }

    enum Priority: String, Codable, CaseIterable, Sendable {
        case any, mediumAndHigh, highOnly
    }

    enum Sort: String, Codable, CaseIterable, Sendable {
        case manual, dueDate, priority
    }

    var show = Show.all
    var priority = Priority.any
    var sort = Sort.manual

    /// Something is hidden: the button's dot and the "Show All" line.
    var filters: Bool { show != .all || priority != .any }
    var isDefault: Bool { self == TasksViewOptions() }

    /// Whether an open task is shown. Finished tasks (Now's "Completed
    /// today") are never filtered: the view is about what is left to do.
    func includes(_ task: TaskItem, today: DueDay) -> Bool {
        guard task.status != .done else { return true }
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
        var parts: [String] = []
        switch show {
        case .all: if priority == .any { parts.append(String(localized: "All tasks")) }
        case .dueOrOverdue: parts.append(String(localized: "Due or overdue"))
        case .overdueOnly: parts.append(String(localized: "Overdue only"))
        }
        switch priority {
        case .any: break
        case .mediumAndHigh: parts.append(String(localized: "Medium and high priority"))
        case .highOnly: parts.append(String(localized: "High priority only"))
        }
        switch sort {
        case .manual: break
        case .dueDate: parts.append(String(localized: "by due date"))
        case .priority: parts.append(String(localized: "by priority"))
        }
        return parts.joined(separator: " · ")
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
        tab == .done ? TasksViewOptions() : (viewOptionsByTab[tab] ?? TasksViewOptions())
    }

    /// A choice in View Options (or Show All, Reset View): only that page
    /// changes. Rows the view hides leave the selection; VoiceOver hears
    /// what is shown now. Remembered with the page (L7).
    func setViewOptions(_ options: TasksViewOptions, for tab: TasksTab) {
        guard tab != .done, options != viewOptions(for: tab) else { return }
        viewOptionsByTab[tab] = options.isDefault ? nil : options
        memory?.saveViewOptions(viewOptionsByTab)
        if tab == self.tab {
            let shown = Set(rows(for: tab).map(\.id))
            let kept = selection.intersection(shown)
            if kept != selection { selectCopies(orderedSelection().filter(kept.contains)) }
        }
        AccessibilityNotification.Announcement(options.filters || options.sort != .manual
            ? String(localized: "Showing \(options.spokenValue)")
            : String(localized: "Showing all tasks")).post()
    }

    /// "Show All": the filters go, the order stays.
    func showAll(on tab: TasksTab) {
        var options = viewOptions(for: tab)
        options.show = .all
        options.priority = .any
        setViewOptions(options, for: tab)
    }

    /// Drag, ⌘↑ ⌘↓ and Move Up/Down work only in Manual Order: a sorted
    /// list has no place to move a task to.
    func reorders(on tab: TasksTab) -> Bool {
        tab != .done && viewOptions(for: tab).sort == .manual
    }

    /// Whether the page shows fewer tasks than it has (a filter or a Find):
    /// a reorder then moves among what is shown (`moveVisible`).
    func narrows(_ tab: TasksTab) -> Bool {
        viewOptions(for: tab).filters || !searchQuery(for: tab).isEmpty
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
        case .backlog: String(localized: "Search Later")
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

    /// A reorder while the page shows only some tasks (a filter or Find, in
    /// Manual Order): `id` takes the place of the shown task at `index` of
    /// `shown` (its state's rows as the page shows them), among all of
    /// them. The hidden ones keep their places around it.
    @discardableResult
    func moveVisible(_ id: UUID, toShownIndex index: Int, in shown: [UUID]) -> CommandOutcome {
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

    static let removedKeys = ["AtticTasksPanel.page", "AtticTasksPanel.views"]

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
