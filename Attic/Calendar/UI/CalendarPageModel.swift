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
    /// `searchDelay`; live occurrence I/O runs on the source's worker.
    @Published private(set) var searchText = ""
    static let searchDelay: Duration = .milliseconds(150)

    let store: TaskStore
    /// The agenda's task rows' selection and rename (kept across Back).
    let taskRows = CalendarTaskRowState()
    let eventRows: CalendarEventRowState
    private(set) var source: CalendarEventSource
    /// Production reads the current zone on demand; tests may pin a calendar.
    private let pinnedCalendar: Calendar?
    var calendar: Calendar { pinnedCalendar ?? CalendarMonthMath.calendar(timeZone: .current) }
    private let now: () -> Date
    private let pinnedLocale: Locale?
    private var locale: Locale { pinnedLocale ?? .current }
    private var dateEnvironment: DatePresentationEnvironment
    private let resumeDefaults: UserDefaults?
    private var hasRequestedAccess = false
    private var searchTask: Task<Void, Never>?
    /// The last range fetched from the source, and the last search: reused
    /// until the source reports a change.
    private var eventCache: (interval: DateInterval, events: [CalendarEvent])?
    private var searchCache: (query: String, interval: DateInterval, events: [CalendarEvent])?
    private var searchCacheComplete = true
    private var sourceGeneration = 0
    @Published private(set) var isLoadingEvents = false
    /// The ••• menu's Day: the selected day by the clock (Accepted 2026-11-09).
    @Published private(set) var isDayView = false
    private var eventRequest: DateInterval? {
        didSet { isLoadingEvents = eventRequest != nil }
    }
    private var searchRequest: (query: String, interval: DateInterval)?
    private var eventTask: Task<Void, Never>?
    private var eventSearchTask: Task<Void, Never>?
    private var cachedTasks: (revision: UInt64, today: DueDay, environment: DatePresentationEnvironment,
                              entries: [CalendarTaskEntry])?
    private var isVisible = false
    /// Exactly one clock tick source, owned by the retained model only while
    /// its page is on screen (including when the shell keeps it mounted).
    private var nowPositionTimer: Timer?
    private var needsVisibleRebuild = false
    private var taskRebuildQueued = false
    private var cancellables: Set<AnyCancellable> = []

    #if DEBUG
    /// Test seam: how many snapshots the page has published.
    private(set) var publishCount = 0
    /// Work done even if the resulting snapshot is unchanged.
    private(set) var rebuildCount = 0
    var nowTimerForTesting: Timer? { nowPositionTimer }
    /// Test seam: how many times the page asked the source for events.
    private(set) var sourceFetches = 0
    /// A deterministic test boundary for the currently requested event snapshot.
    func waitForEventReadsForTesting() async {
        let events = eventTask, search = eventSearchTask
        await events?.value
        await search?.value
    }
    #endif

    init(store: TaskStore, source: CalendarEventSource, calendar: Calendar? = nil,
         locale: Locale? = nil, now: @escaping () -> Date = Date.init,
         makeWriter: (() throws -> CalendarEventWriter)? = nil, resumeDefaults: UserDefaults? = nil) {
        self.resumeDefaults = resumeDefaults
        self.store = store
        self.eventRows = CalendarEventRowState(makeWriter: makeWriter)
        self.source = source
        self.pinnedCalendar = calendar
        self.pinnedLocale = locale
        let currentCalendar = calendar ?? CalendarMonthMath.calendar(timeZone: .current)
        dateEnvironment = DatePresentationEnvironment(calendar: currentCalendar, locale: locale ?? .current)
        self.now = now
        let today = DueDay(date: now(), calendar: currentCalendar)
        let selected = resumeDefaults?.data(forKey: "AtticCalendar.selectedDay")
            .flatMap { try? JSONDecoder().decode(DueDay.self, from: $0) }
            .flatMap { DueDay(year: $0.year, month: $0.month, day: $0.day) } ?? today
        snapshot = CalendarPageSnapshot(today: today, selected: selected, month: CalendarMonth(selected), weeks: [],
                                        groups: [], query: "", access: source.accessState)
        rebuild()
        observe()
    }

    deinit {
        nowPositionTimer?.invalidate()
        searchTask?.cancel()
        eventTask?.cancel()
        eventSearchTask?.cancel()
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

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            if needsVisibleRebuild {
                needsVisibleRebuild = false
                rebuild()
            } else {
                refreshToday()
            }
            startNowPositionTimer()
        } else {
            nowPositionTimer?.invalidate()
            nowPositionTimer = nil
        }
    }

    private func startNowPositionTimer() {
        guard nowPositionTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNowPosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        nowPositionTimer = timer
    }

    func select(_ day: DueDay) {
        guard day != snapshot.selected else { return }
        rebuild(selected: day)
        if let data = try? JSONEncoder().encode(day) { resumeDefaults?.set(data, forKey: "AtticCalendar.selectedDay") }
    }

    func goToToday() {
        refreshToday()
        select(snapshot.today)
    }

    /// Previous (-1) and next (1): a month, or a week in the week view.
    func shift(by n: Int, weekView: Bool) {
        select(CalendarMonthMath.shifted(snapshot.selected, by: n, weekView: weekView, today: snapshot.today, calendar: calendar))
    }

    func setDayView(_ on: Bool) {
        if isDayView != on { isDayView = on }
    }

    /// The Day view's ‹ ›: one day.
    func shiftDay(by n: Int) {
        select(CalendarMonthMath.adding(days: n, to: snapshot.selected, calendar: calendar))
    }

    /// The model's clock (a pinned one in tests).
    var currentTime: Date { now() }

    /// Typing in the search: the agenda follows after `searchDelay`;
    /// clearing it (or ending the search) follows at once.
    func setQuery(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        searchTask?.cancel()
        searchTask = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            eventSearchTask?.cancel()
            eventSearchTask = nil
            searchRequest = nil
            if !searchCacheComplete { searchCache = nil }
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
        if refreshDateEnvironment() { rebuild(); return }
        let today = DueDay(date: now(), calendar: calendar)
        if today != snapshot.today { rebuild() }
    }

    /// Calendar and locale may change while this model stays retained.
    /// Invalidate interval and formatted-task projections before using either.
    @discardableResult
    private func refreshDateEnvironment() -> Bool {
        let current = DatePresentationEnvironment(calendar: calendar, locale: locale)
        guard current != dateEnvironment else { return false }
        dateEnvironment = current
        cachedTasks = nil
        sourceGeneration &+= 1
        eventTask?.cancel()
        eventSearchTask?.cancel()
        eventRequest = nil
        searchRequest = nil
        eventCache = nil
        searchCache = nil
        return true
    }

    /// The clock changes the line's chronological position without fetching
    /// tasks, marking grid days or re-requesting Calendar events.
    func refreshNowPosition() {
        if refreshDateEnvironment() { rebuild(); return }
        let moment = now()
        guard DueDay(date: moment, calendar: calendar) == snapshot.today else {
            rebuild()
            return
        }
        let groups = snapshot.groups.map { CalendarAgenda.advancingNow(in: $0, to: moment, calendar: calendar) }
        guard groups != snapshot.groups else { return }
        snapshot.groups = groups
        #if DEBUG
        publishCount += 1
        #endif
    }

    func rebuild(selected: DueDay? = nil, query: String? = nil) {
        #if DEBUG
        rebuildCount += 1
        #endif
        refreshDateEnvironment()
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
        if let eventCache, eventCache.interval == interval {
            if eventRequest != interval { eventTask?.cancel(); eventRequest = nil }
            return eventCache.events
        }
        if let reader = source as? AsyncCalendarEventReading {
            if eventRequest != interval {
                eventTask?.cancel()
                eventRequest = interval
                let epoch = sourceGeneration
                eventTask = Task { [weak self] in
                    let events = await reader.loadEvents(in: interval)
                    guard !Task.isCancelled, let self, epoch == self.sourceGeneration,
                          self.eventRequest == interval else { return }
                    self.eventCache = (interval, events)
                    self.eventRequest = nil
                    self.rebuildOrDefer()
                }
                #if DEBUG
                sourceFetches += 1
                #endif
            }
            return []
        }
        let events = source.events(in: interval)
        eventCache = (interval, events)
        #if DEBUG
        sourceFetches += 1
        #endif
        return events
    }

    private func search(_ query: String, in interval: DateInterval) -> [CalendarEvent] {
        if let searchCache, searchCache.query == query, searchCache.interval == interval,
           searchCacheComplete || (searchRequest?.query == query && searchRequest?.interval == interval) {
            if searchRequest?.query != query || searchRequest?.interval != interval {
                eventSearchTask?.cancel(); searchRequest = nil
            }
            return searchCache.events
        }
        if let reader = source as? AsyncCalendarEventSearching {
            if searchRequest?.query != query || searchRequest?.interval != interval {
                eventSearchTask?.cancel()
                searchCache = nil
                searchCacheComplete = false
                searchRequest = (query, interval)
                let epoch = sourceGeneration
                eventSearchTask = Task { [weak self] in
                    var matches: [CalendarEvent] = []
                    var seen = Set<CalendarEvent>()
                    for await batch in reader.searchEvents(query, in: interval, around: self?.now() ?? Date()) {
                        guard !Task.isCancelled, let self, epoch == self.sourceGeneration,
                              self.searchRequest?.query == query, self.searchRequest?.interval == interval else { return }
                        for event in batch where seen.insert(event).inserted { matches.append(event) }
                        self.searchCache = (query, interval, EventKitCalendarEventSource.uniquingIDs(matches.sortedForAgenda()))
                        self.rebuildOrDefer()
                    }
                    guard !Task.isCancelled, let self, epoch == self.sourceGeneration,
                          self.searchRequest?.query == query, self.searchRequest?.interval == interval else { return }
                    self.searchCache = (query, interval, EventKitCalendarEventSource.uniquingIDs(matches.sortedForAgenda()))
                    self.searchCacheComplete = true
                    self.searchRequest = nil
                    self.rebuildOrDefer()
                }
                #if DEBUG
                sourceFetches += 1
                #endif
            }
            return []
        }
        if let reader = source as? AsyncCalendarEventReading {
            if searchRequest?.query != query || searchRequest?.interval != interval {
                eventSearchTask?.cancel()
                searchRequest = (query, interval)
                let epoch = sourceGeneration
                eventSearchTask = Task { [weak self] in
                    let events = await reader.loadEvents(in: interval).filter { $0.matches(query) }
                    guard !Task.isCancelled, let self, epoch == self.sourceGeneration,
                          self.searchRequest?.query == query, self.searchRequest?.interval == interval else { return }
                    self.searchCache = (query, interval, events)
                    self.searchCacheComplete = true
                    self.searchRequest = nil
                    self.rebuildOrDefer()
                }
                #if DEBUG
                sourceFetches += 1
                #endif
            }
            return []
        }
        let events = source.search(query, in: interval)
        searchCache = (query, interval, events)
        searchCacheComplete = true
        #if DEBUG
        sourceFetches += 1
        #endif
        return events
    }

    /// The source changed: what was fetched is stale.
    private func sourceChanged() {
        sourceGeneration += 1
        eventTask?.cancel()
        eventSearchTask?.cancel()
        eventRequest = nil
        searchRequest = nil
        eventCache = nil
        searchCache = nil
        rebuildOrDefer()
    }

    private func rebuildOrDefer() {
        if isVisible { rebuild() }
        else { needsVisibleRebuild = true }
    }

    /// Every listed task with a due day (subtasks too): open ones show on
    /// their day and in search; done ones show on their day, done.
    private func taskEntries(today: DueDay) -> [CalendarTaskEntry] {
        if let cachedTasks, cachedTasks.revision == store.revision,
           cachedTasks.today == today, cachedTasks.environment == dateEnvironment {
            return cachedTasks.entries
        }
        let entries: [CalendarTaskEntry] = store.tasks.compactMap { task -> CalendarTaskEntry? in
            guard task.deletedAt == nil, let due = task.dueDay else { return nil }
            let subtasks = task.parentID == nil ? store.subtasks(of: task.id) : []
            var row = TaskRowPresentation.row(for: task, subtasks: subtasks, today: today, calendar: calendar, locale: locale)
            // The design names the day only when the task is overdue: on its
            // own day the tile already says when it is due.
            let isOpen = task.status != .done
            if !(isOpen && due < today) { row.due = nil }
            return CalendarTaskEntry(id: task.id, title: task.title, due: due, isOpen: isOpen, row: row, dueTimeMinutes: task.dueTimeMinutes)
        }
        cachedTasks = (store.revision, today, dateEnvironment, entries)
        return entries
    }

    // MARK: Observation

    private func observe() {
        store.$revision
            .dropFirst()
            .sink { [weak self] _ in
                // `$revision` sends before its value is stored. One next-turn
                // drain sees the final revision and all published task arrays.
                guard let self else { return }
                if !self.isVisible { self.needsVisibleRebuild = true; return }
                guard !self.taskRebuildQueued else { return }
                self.taskRebuildQueued = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.taskRebuildQueued = false
                    if self.isVisible { self.rebuild() }
                    else { self.needsVisibleRebuild = true }
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cachedTasks = nil
                self?.rebuildOrDefer()
            }
            .store(in: &cancellables)
        for name in [Notification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    _ = self?.refreshDateEnvironment()
                    self?.cachedTasks = nil
                    self?.rebuildOrDefer()
                }
                .store(in: &cancellables)
        }
        observeSource()
    }

    private func observeSource() {
        source.onChange = { [weak self] in self?.sourceChanged() }
    }
}
