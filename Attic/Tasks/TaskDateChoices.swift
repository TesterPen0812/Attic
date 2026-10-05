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

    // MARK: - The date card

    /// The calendar the date card lays its month out in: the stored days'
    /// calendar, with the locale's first weekday and the locale's names.
    var cardCalendar: Calendar {
        var cal = calendar
        cal.firstWeekday = parser.calendar.firstWeekday
        cal.locale = parser.locale
        return cal
    }
}
