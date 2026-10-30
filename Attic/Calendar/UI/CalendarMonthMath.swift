import Foundation

// The Calendar page's month grid as values (owner's panel design, 28 Oct:
// "Calendar month grid: Keys", option 3d). Days are `DueDay`s, the same day
// identity tasks use, so a task's due day and a grid key compare directly.
// Weeks start on Monday, as the design draws them.

/// A month on the grid.
struct CalendarMonth: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        // Normalise 0 and 13 into the neighbouring years.
        let index = year * 12 + (month - 1)
        self.year = Int((Double(index) / 12).rounded(.down))
        self.month = index - self.year * 12 + 1
    }

    init(_ day: DueDay) { self.init(year: day.year, month: day.month) }

    func adding(months n: Int) -> CalendarMonth { CalendarMonth(year: year, month: month + n) }

    var firstDay: DueDay { DueDay(year: year, month: month, day: 1) ?? DueDay(year: 2000, month: 1, day: 1)! }

    static func < (lhs: CalendarMonth, rhs: CalendarMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

/// How a day's key is drawn (Accepted 2026-10-30, "Calendar page: Grid"):
/// the grid is flat in every month and the selected day is the only key.
enum CalendarKeyStyle: Equatable, Sendable {
    /// No key: the number alone on the panel.
    case plain
    /// The selected day: a grey key.
    case selected
}

/// The colour of a day's number: today red (selected or not), past days
/// grey, the rest ink.
enum CalendarKeyNumber: Equatable, Sendable {
    case red, ink, grey
}

/// The marks under a day's number: up to three event dots in the calendars'
/// colours, then a hollow ring when the day has open tasks.
struct CalendarDayMarks: Equatable, Sendable {
    var eventColours: [CalendarEventColour] = []
    var hasOpenTasks = false
    var isEmpty: Bool { eventColours.isEmpty && !hasOpenTasks }
}

struct CalendarGridDay: Identifiable, Equatable, Sendable {
    var id: DueDay { day }
    let day: DueDay
    /// In the month shown. Days of the neighbouring months are hidden while
    /// the whole month shows, and shown in the week view.
    let isInMonth: Bool
    let isToday: Bool
    let isPast: Bool
    let isSelected: Bool
    var marks = CalendarDayMarks()

    var style: CalendarKeyStyle { isSelected ? .selected : .plain }

    var number: CalendarKeyNumber {
        if isToday { return .red }
        return isPast && !isSelected ? .grey : .ink
    }
}

struct CalendarGridWeek: Identifiable, Equatable, Sendable {
    /// The week's Monday.
    var id: DueDay { days[0].day }
    var days: [CalendarGridDay]
    var containsSelection: Bool { days.contains(where: \.isSelected) }
}

enum CalendarMonthMath {
    /// The Gregorian calendar the page counts days in: the person's time
    /// zone, weeks from Monday (the design's order).
    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// `day` moved by `n` days.
    static func adding(days n: Int, to day: DueDay, calendar: Calendar) -> DueDay {
        guard n != 0, let start = day.startDate(in: calendar),
              let moved = calendar.date(byAdding: .day, value: n, to: start) else { return day }
        return DueDay(date: moved, calendar: calendar)
    }

    /// Whole days from `from` to `to`.
    static func days(from: DueDay, to: DueDay, calendar: Calendar) -> Int {
        guard let a = from.startDate(in: calendar), let b = to.startDate(in: calendar) else { return 0 }
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// 0 for Monday … 6 for Sunday.
    static func weekdayIndex(of day: DueDay, calendar: Calendar) -> Int {
        guard let start = day.startDate(in: calendar) else { return 0 }
        return (calendar.component(.weekday, from: start) + 5) % 7
    }

    /// The Monday on or before `day`.
    static func weekStart(of day: DueDay, calendar: Calendar) -> DueDay {
        adding(days: -weekdayIndex(of: day, calendar: calendar), to: day, calendar: calendar)
    }

    static func numberOfDays(in month: CalendarMonth, calendar: Calendar) -> Int {
        guard let start = month.firstDay.startDate(in: calendar),
              let range = calendar.range(of: .day, in: .month, for: start) else { return 30 }
        return range.count
    }

    /// The month's weeks, Monday first: 4 to 6 rows of 7 days.
    static func weeks(for month: CalendarMonth, today: DueDay, selected: DueDay, calendar: Calendar) -> [CalendarGridWeek] {
        let first = month.firstDay
        let lead = weekdayIndex(of: first, calendar: calendar)
        let count = Int((Double(lead + numberOfDays(in: month, calendar: calendar)) / 7).rounded(.up))
        let start = adding(days: -lead, to: first, calendar: calendar)
        return (0..<count).map { w in
            CalendarGridWeek(days: (0..<7).map { d in
                let day = adding(days: w * 7 + d, to: start, calendar: calendar)
                return CalendarGridDay(day: day, isInMonth: day.year == month.year && day.month == month.month,
                                       isToday: day == today, isPast: day < today, isSelected: day == selected)
            })
        }
    }

    /// The row that pins under the weekday letters: the selected day's week.
    static func pinnedWeekIndex(_ weeks: [CalendarGridWeek]) -> Int? {
        weeks.firstIndex(where: \.containsSelection)
    }

    /// Where the page scrolls to show only the selected week: every week
    /// above the last has scrolled away (the selected one is pinned), so the
    /// agenda starts right under the pinned week.
    static func weekViewOffset(weekCount: Int) -> CGFloat {
        CGFloat(max(0, weekCount - 1)) * CalendarDesign.weekPitch + CalendarDesign.agendaTop
    }

    /// The week view shows once the page has scrolled (nearly) that far.
    static func isWeekView(offset: CGFloat, weekCount: Int) -> Bool {
        offset >= weekViewOffset(weekCount: weekCount) - 2
    }

    /// The selected week is pinned once its row reaches the weekday letters.
    static func isPinned(offset: CGFloat, pinnedIndex: Int?) -> Bool {
        guard let pinnedIndex else { return false }
        return offset > CGFloat(pinnedIndex) * CalendarDesign.weekPitch + 0.5
    }

    /// Previous and next: a month (to its first day, or today in today's
    /// month), or in the week view a week.
    static func shifted(_ selected: DueDay, by n: Int, weekView: Bool, today: DueDay, calendar: Calendar) -> DueDay {
        if weekView { return adding(days: 7 * n, to: selected, calendar: calendar) }
        let month = CalendarMonth(selected).adding(months: n)
        return month == CalendarMonth(today) ? today : month.firstDay
    }

    /// The day's start and the next day's start.
    static func interval(of day: DueDay, calendar: Calendar) -> DateInterval? {
        guard let start = day.startDate(in: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// From the start of `from` to the end of `through`.
    static func interval(from: DueDay, through: DueDay, calendar: Calendar) -> DateInterval? {
        guard let start = from.startDate(in: calendar),
              let last = interval(of: max(from, through), calendar: calendar) else { return nil }
        return DateInterval(start: start, end: last.end)
    }
}
