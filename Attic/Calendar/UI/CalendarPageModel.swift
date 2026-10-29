import Combine
import Foundation

/// What the Calendar page draws, as one value: the page publishes a new
/// snapshot only when something it shows changed, so the view updates once
/// per change (never per scroll frame).
struct CalendarPageSnapshot: Equatable {
    var today: DueDay
    var selected: DueDay
    var month: CalendarMonth
    var weeks: [CalendarGridWeek]
    var groups: [CalendarAgendaGroup]
    var query: String
    var access: CalendarAccessState

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var showsNoMatches: Bool { isSearching && groups.isEmpty }
    var pinnedWeekIndex: Int? { CalendarMonthMath.pinnedWeekIndex(weeks) }
}

/// The Calendar page's state: the selected day, the month shown, the search,
/// and the events and tasks they show. Events come only through the
/// injected `CalendarEventSource`, so the source can be swapped without
/// touching the page; tasks come from the task store.
@MainActor
final class CalendarPageModel: ObservableObject {
    @Published private(set) var snapshot: CalendarPageSnapshot
    /// The search field's text, as typed. The agenda follows it after
    /// `searchDelay`: the source searches synchronously on the main actor.
    @Published private(set) var searchText = ""
    static let searchDelay: Duration = .milliseconds(150)

    let store: TaskStore
    private(set) var source: CalendarEventSource
    let calendar: Calendar
    private let now: () -> Date
    private let locale: Locale
    private var hasRequestedAccess = false
    private var searchTask: Task<Void, Never>?
    /// The last range fetched from the source, and the last search: reused
    /// until the source reports a change.
    private var eventCache: (interval: DateInterval, events: [CalendarEvent])?
    private var searchCache: (query: String, interval: DateInterval, events: [CalendarEvent])?
    private var cancellables: Set<AnyCancellable> = []

    #if DEBUG
    /// Test seam: how many snapshots the page has published.
    private(set) var publishCount = 0
    /// Test seam: how many times the page asked the source for events.
    private(set) var sourceFetches = 0
    #endif

    init(store: TaskStore, source: CalendarEventSource, calendar: Calendar = CalendarMonthMath.calendar(),
         locale: Locale = .current, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.source = source
        self.calendar = calendar
        self.locale = locale
        self.now = now
        let today = DueDay(date: now(), calendar: calendar)
        snapshot = CalendarPageSnapshot(today: today, selected: today, month: CalendarMonth(today), weeks: [],
                                        groups: [], query: "", access: source.accessState)
        rebuild()
        observe()
    }

    // MARK: Actions

    /// Asks for calendar access the first time the page appears.
    func pageAppeared() {
        refreshToday()
        guard !hasRequestedAccess else { return }
        hasRequestedAccess = true
        guard source.accessState == .notDetermined else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.source.requestAccess()
            self.sourceChanged()
        }
    }

    func select(_ day: DueDay) {
        guard day != snapshot.selected else { return }
        rebuild(selected: day)
    }

    func goToToday() {
        refreshToday()
        select(snapshot.today)
    }

    /// Previous (-1) and next (1): a month, or a week in the week view.
    func shift(by n: Int, weekView: Bool) {
        select(CalendarMonthMath.shifted(snapshot.selected, by: n, weekView: weekView, today: snapshot.today, calendar: calendar))
    }

    /// Typing in the search: the agenda follows after `searchDelay`;
    /// clearing it (or ending the search) follows at once.
    func setQuery(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        searchTask?.cancel()
        searchTask = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rebuild(query: text)
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled, let self else { return }
            self.rebuild(query: self.searchText)
        }
    }

    /// Applies the typed search now (tests, and Return in the field).
    func commitSearch() {
        searchTask?.cancel()
        searchTask = nil
        rebuild(query: searchText)
    }

    /// The day a new task gets from the footer's "+".
    var newTaskDay: DueDay { snapshot.selected }

    /// Swaps the event source (the EventKit source replaces the stub).
    func replaceSource(_ newSource: CalendarEventSource) {
        source.onChange = nil
        source = newSource
        hasRequestedAccess = false
        observeSource()
        sourceChanged()
    }

    // MARK: Building

    private func refreshToday() {
        let today = DueDay(date: now(), calendar: calendar)
        if today != snapshot.today { rebuild() }
    }

    func rebuild(selected: DueDay? = nil, query: String? = nil) {
        let today = DueDay(date: now(), calendar: calendar)
        let selected = selected ?? snapshot.selected
        let query = query ?? snapshot.query
        let month = CalendarMonth(selected)
        let tasks = taskEntries(today: today)
        var weeks = CalendarMonthMath.weeks(for: month, today: today, selected: selected, calendar: calendar)
        let gridStart = weeks.first?.days.first?.day ?? selected
        let gridEnd = weeks.last?.days.last?.day ?? selected
        let agendaEnd = CalendarMonthMath.adding(days: CalendarAgenda.dayCount - 1, to: selected, calendar: calendar)
        let events = CalendarMonthMath.interval(from: min(gridStart, selected), through: max(gridEnd, agendaEnd), calendar: calendar)
            .map(events(in:)) ?? []
        let marks = CalendarAgenda.marks(for: weeks.flatMap { $0.days.map(\.day) }, events: events, tasks: tasks, calendar: calendar)
        for w in weeks.indices {
            for d in weeks[w].days.indices {
                weeks[w].days[d].marks = marks[weeks[w].days[d].day] ?? CalendarDayMarks()
            }
        }
        let clock = CalendarAgenda.Clock(today: today, now: now())
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups: [CalendarAgendaGroup]
        if trimmed.isEmpty {
            groups = CalendarAgenda.groups(selected: selected, clock: clock, events: events, tasks: tasks, calendar: calendar)
        } else {
            let matching = CalendarAgenda.searchInterval(today: today, calendar: calendar)
                .map { search(trimmed, in: $0) } ?? []
            groups = CalendarAgenda.searchGroups(query: trimmed, clock: clock, matchingEvents: matching, tasks: tasks, calendar: calendar)
        }
        let next = CalendarPageSnapshot(today: today, selected: selected, month: month, weeks: weeks, groups: groups,
                                        query: query, access: source.accessState)
        guard next != snapshot else { return }
        snapshot = next
        #if DEBUG
        publishCount += 1
        #endif
    }

    /// The source's occurrences in `interval`, fetched once per range.
    private func events(in interval: DateInterval) -> [CalendarEvent] {
        if let eventCache, eventCache.interval == interval { return eventCache.events }
        let events = source.events(in: interval)
        eventCache = (interval, events)
        #if DEBUG
        sourceFetches += 1
        #endif
        return events
    }

    private func search(_ query: String, in interval: DateInterval) -> [CalendarEvent] {
        if let searchCache, searchCache.query == query, searchCache.interval == interval { return searchCache.events }
        let events = source.search(query, in: interval)
        searchCache = (query, interval, events)
        #if DEBUG
        sourceFetches += 1
        #endif
        return events
    }

    /// The source changed: what was fetched is stale.
    private func sourceChanged() {
        eventCache = nil
        searchCache = nil
        rebuild()
    }

    /// Every listed task with a due day (subtasks too): open ones show on
    /// their day and in search; done ones show on their day, done.
    private func taskEntries(today: DueDay) -> [CalendarTaskEntry] {
        store.tasks.compactMap { task -> CalendarTaskEntry? in
            guard task.deletedAt == nil, let due = task.dueDay else { return nil }
            let subtasks = task.parentID == nil ? store.subtasks(of: task.id) : []
            var row = TaskRowPresentation.row(for: task, subtasks: subtasks, today: today, calendar: calendar, locale: locale)
            // The design names the day only when the task is overdue: on its
            // own day the tile already says when it is due.
            let isOpen = task.status != .done
            if !(isOpen && due < today) { row.due = nil }
            return CalendarTaskEntry(id: task.id, title: task.title, due: due, isOpen: isOpen, row: row)
        }
    }

    // MARK: Observation

    private func observe() {
        store.$revision
            .dropFirst()
            .sink { [weak self] _ in
                // `$revision` is sent before the store's lists change.
                DispatchQueue.main.async { self?.rebuild() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        observeSource()
    }

    private func observeSource() {
        source.onChange = { [weak self] in self?.sourceChanged() }
    }
}
