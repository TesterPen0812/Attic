import Foundation

/// One date model for every place a due date is chosen (owner fix 5, review
/// 16): the add bar's strip, a row's date popover and the right-click
/// menu. A choice is an exact `DueDay`; its words ("tomorrow", "30 Sep")
/// are only how the add bar shows it. The quick days resolve through the
/// same parser the shorthand uses, so "Next week" means the same day
/// whether it was typed or picked. Pure: tested directly.
struct TaskDateChoices {
    let parser: TaskTextParser

    /// A quick choice: its name and the day it means today.
    struct Quick: Identifiable, Equatable {
        enum Kind: String, CaseIterable { case today, tomorrow, nextWeek }
        let kind: Kind
        let day: DueDay
        var id: String { kind.rawValue }

        var title: String {
            switch kind {
            case .today: String(localized: "Today")
            case .tomorrow: String(localized: "Tomorrow")
            case .nextWeek: String(localized: "Next week")
            }
        }

        /// The menu's capitalisation ("Next Week").
        var menuTitle: String {
            switch kind {
            case .today: String(localized: "Today")
            case .tomorrow: String(localized: "Tomorrow")
            case .nextWeek: String(localized: "Next Week")
            }
        }

        /// The words the add bar inserts for it (the shorthand for it).
        var shorthand: String {
            switch kind {
            case .today: "today"
            case .tomorrow: "tomorrow"
            case .nextWeek: "next week"
            }
        }
    }

    private var calendar: Calendar { DueDay.storageCalendar(matching: parser.calendar) }

    var today: DueDay { DueDay(date: parser.now(), calendar: calendar) }

    /// Today, Tomorrow and Next week, resolved now.
    var quick: [Quick] {
        Quick.Kind.allCases.compactMap { kind in
            let day: DueDay? = switch kind {
            case .today: today
            case .tomorrow: parser.parseDueDay("tomorrow")
            case .nextWeek: parser.parseDueDay("next week")
            }
            return day.map { Quick(kind: kind, day: $0) }
        }
    }

    /// The day a quick choice shows on its right (v17): the weekday for
    /// today and tomorrow ("Wed", "Thu"), the weekday and date further on
    /// ("Mon 5 Oct").
    func detail(for day: DueDay) -> String {
        guard let date = day.startDate(in: calendar), let offset = offset(to: day) else { return day.rawValue }
        let template = (0...1).contains(offset) ? "EEE" : (day.year == today.year ? "EEEdMMM" : "EEEdMMMy")
        return TaskRowPresentation.format(date, template: template, calendar: calendar, locale: parser.locale)
    }

    /// The resolved day in full, for a suggestion ("Thu 1 Oct").
    func longDetail(for day: DueDay) -> String {
        guard let date = day.startDate(in: calendar) else { return day.rawValue }
        return TaskRowPresentation.format(date, template: day.year == today.year ? "EEEdMMM" : "EEEdMMMy",
                                          calendar: calendar, locale: parser.locale)
    }

    func offset(to day: DueDay) -> Int? {
        guard let start = day.startDate(in: calendar), let now = today.startDate(in: calendar) else { return nil }
        return calendar.dateComponents([.day], from: now, to: start).day
    }

    /// The words the add bar shows for a chosen day: a quick day's own
    /// shorthand, otherwise a short date ("30 Sep", with the year when it
    /// is not this year). The chip keeps the exact day whatever it says.
    func shorthand(for day: DueDay) -> String {
        if let quick = quick.first(where: { $0.day == day }) { return quick.shorthand }
        guard let date = day.startDate(in: calendar) else { return day.rawValue }
        return TaskRowPresentation.shortDate(date, sameYear: day.year == today.year, calendar: calendar, locale: parser.locale)
    }

    // MARK: - The month

    /// One month as the picker lays it out: whole weeks starting on the
    /// locale's first weekday, with the neighbouring months' days in place.
    struct Month: Equatable {
        let year: Int
        let month: Int
        /// Seven per week.
        let days: [Day]
        /// The weekday initials in column order ("M T W T F S S").
        let weekdaySymbols: [String]
        let title: String

        struct Day: Equatable, Identifiable {
            let day: DueDay
            let inMonth: Bool
            var id: String { day.rawValue }
        }
    }

    /// The month holding `day`.
    func month(containing day: DueDay) -> Month {
        month(year: day.year, month: day.month)
    }

    func month(year: Int, month: Int) -> Month {
        var cal = calendar
        cal.firstWeekday = parser.calendar.firstWeekday
        cal.locale = parser.locale
        let first = DueDay(year: year, month: month, day: 1) ?? today
        let firstDate = first.startDate(in: cal) ?? parser.now()
        let weekday = cal.component(.weekday, from: firstDate)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        let count = cal.range(of: .day, in: .month, for: firstDate)?.count ?? 30
        let weeks = Int(ceil(Double(lead + count) / 7))
        var days: [Month.Day] = []
        for index in 0..<(weeks * 7) {
            guard let date = cal.date(byAdding: .day, value: index - lead, to: firstDate) else { continue }
            let due = DueDay(date: date, calendar: cal)
            days.append(Month.Day(day: due, inMonth: due.month == month && due.year == year))
        }
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let ordered = (0..<7).map { symbols[(cal.firstWeekday - 1 + $0) % 7] }
        let title = TaskRowPresentation.format(firstDate, template: "MMMMy", calendar: cal, locale: parser.locale)
        return Month(year: year, month: month, days: days, weekdaySymbols: ordered, title: title)
    }

    /// The month before or after (`step` −1 or 1).
    func month(after month: Month, by step: Int) -> Month {
        var m = month.month + step
        var y = month.year
        while m < 1 { m += 12; y -= 1 }
        while m > 12 { m -= 12; y += 1 }
        return self.month(year: y, month: m)
    }

    /// The same day `months` months on, clamped to that month's length
    /// (31 Jan + 1 month = 28 or 29 Feb).
    func day(_ day: DueDay, movedByMonths months: Int) -> DueDay {
        guard let date = day.startDate(in: calendar),
              let moved = calendar.date(byAdding: .month, value: months, to: date) else { return day }
        return DueDay(date: moved, calendar: calendar)
    }

    /// Keyboard travel in the grid: ← → a day, ↑ ↓ a week.
    func day(_ day: DueDay, movedBy days: Int) -> DueDay {
        guard let date = day.startDate(in: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return day }
        return DueDay(date: moved, calendar: calendar)
    }
}

/// The date picker's active day (round 4, Astra's final review 4): the
/// month shown is always the active day's month, so the day Return picks is
/// the one the person sees. Arrows move it by days and weeks, Page Up/Down
/// and the chevrons by months (the day clamped to the month's length).
struct TaskDateCursor: Equatable {
    private(set) var active: DueDay
    /// The keyboard has moved it: the grid draws it.
    private(set) var isKeyboardActive = false

    init(start: DueDay) { active = start }

    mutating func move(days: Int, in choices: TaskDateChoices) {
        active = choices.day(active, movedBy: days)
        isKeyboardActive = true
    }

    mutating func move(months: Int, in choices: TaskDateChoices, byKeyboard: Bool) {
        active = choices.day(active, movedByMonths: months)
        if byKeyboard { isKeyboardActive = true }
    }

    func month(in choices: TaskDateChoices) -> TaskDateChoices.Month {
        choices.month(containing: active)
    }
}

