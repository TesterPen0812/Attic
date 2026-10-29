import Foundation

// The agenda under the grid (owner's panel design, 28 Oct): each day has a
// date tile on the left and its events and tasks on the right. Without a
// search it shows the selected day and the six after it; with one, only the
// days that have matching events or open tasks, in date order.

/// A task as the agenda needs it. `row` is the real Tasks row's model.
struct CalendarTaskEntry: Equatable, Sendable {
    let id: UUID
    let title: String
    let due: DueDay
    let isOpen: Bool
    var row: AtticTaskRowModel

    init(id: UUID, title: String, due: DueDay, isOpen: Bool, row: AtticTaskRowModel? = nil) {
        self.id = id
        self.title = title
        self.due = due
        self.isOpen = isOpen
        self.row = row ?? AtticTaskRowModel(id: id, title: title)
    }

    func matches(_ text: String) -> Bool { title.localizedStandardContains(text) }
}

enum CalendarAgendaItem: Identifiable, Equatable, Sendable {
    case event(CalendarEvent)
    case task(CalendarTaskEntry)
    /// The red line at the current time, among today's timed events.
    case now

    var id: String {
        switch self {
        case let .event(event): "event-" + event.id
        case let .task(task): "task-" + task.id.uuidString
        case .now: "now"
        }
    }
}

struct CalendarAgendaGroup: Identifiable, Equatable, Sendable {
    enum Relative: Equatable, Sendable { case today, tomorrow, yesterday }

    var id: DueDay { day }
    let day: DueDay
    let relative: Relative?
    var items: [CalendarAgendaItem]

    var isToday: Bool { relative == .today }
    /// Only the now line: the day shows its tile and no rows.
    var hasRows: Bool { items.contains { $0 != .now } }
}

enum CalendarAgenda {
    /// Days the agenda lists without a search: the selected day and six more.
    static let dayCount = 7

    /// Today's start, for the now line: minutes since midnight.
    struct Clock: Equatable, Sendable {
        let today: DueDay
        let now: Date
    }

    /// The agenda without a search: `dayCount` days from `selected`.
    /// Each day lists its all-day events, then its tasks (on today, the open
    /// overdue tasks first), then its timed events in order, with the now
    /// line among today's.
    static func groups(selected: DueDay, clock: Clock, events: [CalendarEvent], tasks: [CalendarTaskEntry],
                       calendar: Calendar) -> [CalendarAgendaGroup] {
        (0..<dayCount).map { offset in
            let day = CalendarMonthMath.adding(days: offset, to: selected, calendar: calendar)
            let isToday = day == clock.today
            var dayTasks = tasks.filter { $0.due == day }
            if isToday {
                dayTasks = tasks.filter { $0.isOpen && $0.due < day } + dayTasks
            }
            return group(day: day, clock: clock, events: Self.events(on: day, in: events, calendar: calendar),
                         tasks: dayTasks, showsNow: isToday, calendar: calendar)
        }
    }

    /// The agenda while searching: every day with a matching event or open
    /// task, in date order. Events come from the source's search (already
    /// matched); tasks are the open tasks whose title matches.
    static func searchGroups(query: String, clock: Clock, matchingEvents: [CalendarEvent],
                             tasks: [CalendarTaskEntry], calendar: Calendar) -> [CalendarAgendaGroup] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let openTasks = tasks.filter { $0.isOpen && $0.matches(text) }
        var byDay: [DueDay: (events: [CalendarEvent], tasks: [CalendarTaskEntry])] = [:]
        for event in matchingEvents {
            let day = DueDay(date: event.start, calendar: calendar)
            byDay[day, default: ([], [])].events.append(event)
        }
        for task in openTasks { byDay[task.due, default: ([], [])].tasks.append(task) }
        return byDay.keys.sorted().map { day in
            let entry = byDay[day] ?? ([], [])
            return group(day: day, clock: clock, events: entry.events.sortedForAgenda(), tasks: entry.tasks,
                         showsNow: false, calendar: calendar)
        }
    }

    /// The occurrences on `day` (overlapping its interval), in agenda order.
    static func events(on day: DueDay, in events: [CalendarEvent], calendar: Calendar) -> [CalendarEvent] {
        guard let interval = CalendarMonthMath.interval(of: day, calendar: calendar) else { return [] }
        return events.filter { $0.overlaps(interval) }.sortedForAgenda()
    }

    static func relative(_ day: DueDay, today: DueDay, calendar: Calendar) -> CalendarAgendaGroup.Relative? {
        switch CalendarMonthMath.days(from: today, to: day, calendar: calendar) {
        case 0: .today
        case 1: .tomorrow
        case -1: .yesterday
        default: nil
        }
    }

    private static func group(day: DueDay, clock: Clock, events: [CalendarEvent], tasks: [CalendarTaskEntry],
                              showsNow: Bool, calendar: Calendar) -> CalendarAgendaGroup {
        let allDay = events.filter(\.isAllDay)
        let timed = events.filter { !$0.isAllDay }
        var items = allDay.map(CalendarAgendaItem.event) + tasks.map(CalendarAgendaItem.task)
        var nowPlaced = !showsNow
        for event in timed {
            if !nowPlaced, event.start > clock.now {
                items.append(.now)
                nowPlaced = true
            }
            items.append(.event(event))
        }
        if !nowPlaced { items.append(.now) }
        let group = CalendarAgendaGroup(day: day, relative: relative(day, today: clock.today, calendar: calendar), items: items)
        // A day with nothing on it shows its tile alone (no lone now line).
        return group.hasRows ? group : CalendarAgendaGroup(day: day, relative: group.relative, items: [])
    }

    /// The marks under each grid day: up to three event dots (all-day
    /// first, then by start) and a ring when the day has open tasks.
    static func marks(for days: [DueDay], events: [CalendarEvent], tasks: [CalendarTaskEntry],
                      calendar: Calendar) -> [DueDay: CalendarDayMarks] {
        let openDays = Set(tasks.filter(\.isOpen).map(\.due))
        var result: [DueDay: CalendarDayMarks] = [:]
        for day in days {
            let dayEvents = Self.events(on: day, in: events, calendar: calendar)
            let ordered = dayEvents.filter(\.isAllDay) + dayEvents.filter { !$0.isAllDay }
            let marks = CalendarDayMarks(eventColours: ordered.prefix(CalendarDesign.maxEventDots).map(\.colour),
                                         hasOpenTasks: openDays.contains(day))
            if !marks.isEmpty { result[day] = marks }
        }
        return result
    }

    /// The search's window around today: a year back, two years ahead.
    static func searchInterval(today: DueDay, calendar: Calendar) -> DateInterval? {
        guard let start = today.startDate(in: calendar),
              let from = calendar.date(byAdding: .year, value: -CalendarDesign.searchYearsBack, to: start),
              let to = calendar.date(byAdding: .year, value: CalendarDesign.searchYearsAhead, to: start) else { return nil }
        return DateInterval(start: from, end: to)
    }
}
