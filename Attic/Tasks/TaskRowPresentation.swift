import Foundation

/// How a task reads on a row: the design system's row model filled from the
/// store (spec § Tasks, § Dates). Pure, so the rules are tested directly.
enum TaskRowPresentation {
    static func state(_ status: TaskStatus) -> AtticTaskState {
        switch status {
        case .todo: .todo
        case .inProgress: .inProgress
        case .done: .done
        case .backlog: .backlog
        }
    }

    static func priority(_ priority: TaskPriority) -> AtticPriority {
        switch priority {
        case .none: .none
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    /// A due day as the row shows it: overdue and today in red; tomorrow,
    /// and the rest of this week, as the day's name; later as a short date
    /// (with the year only when it isn't this year).
    static func due(_ day: DueDay, today: DueDay, calendar: Calendar, locale: Locale) -> AtticTaskRowModel.Due {
        let gregorian = DueDay.storageCalendar(matching: calendar)
        guard let start = day.startDate(in: gregorian), let now = today.startDate(in: gregorian),
              let offset = gregorian.dateComponents([.day], from: now, to: start).day else {
            return AtticTaskRowModel.Due(text: day.rawValue, isUrgent: false)
        }
        switch offset {
        case ..<(-1):
            return AtticTaskRowModel.Due(text: shortDate(start, sameYear: day.year == today.year, calendar: gregorian, locale: locale), isUrgent: true)
        case -1:
            return AtticTaskRowModel.Due(text: String(localized: "Yesterday"), isUrgent: true)
        case 0:
            return AtticTaskRowModel.Due(text: String(localized: "Today"), isUrgent: true)
        case 1:
            return AtticTaskRowModel.Due(text: String(localized: "Tomorrow"), isUrgent: false)
        case 2...6:
            return AtticTaskRowModel.Due(text: format(start, template: "EEE", calendar: gregorian, locale: locale), isUrgent: false)
        default:
            return AtticTaskRowModel.Due(text: shortDate(start, sameYear: day.year == today.year, calendar: gregorian, locale: locale), isUrgent: false)
        }
    }

    static func shortDate(_ date: Date, sameYear: Bool, calendar: Calendar, locale: Locale) -> String {
        format(date, template: sameYear ? "dMMM" : "dMMMy", calendar: calendar, locale: locale)
    }

    static func format(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let key = "\(template)|\(locale.identifier)|\(calendar.timeZone.identifier)|\(calendar.identifier)" as NSString
        if let cached = formatters.object(forKey: key) { return cached.string(from: date) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters.setObject(formatter, forKey: key)
        return formatter.string(from: date)
    }

    /// Formatters are costly to make and a list formats hundreds of dates.
    private nonisolated(unsafe) static let formatters = NSCache<NSString, DateFormatter>()

    /// The row model for a main task. `subtasks` are its children in
    /// display order (the pie and "1/3" count), or empty.
    static func row(
        for task: TaskItem,
        subtasks: [TaskItem],
        today: DueDay,
        calendar: Calendar,
        locale: Locale
    ) -> AtticTaskRowModel {
        var model = AtticTaskRowModel(id: task.id, title: task.title)
        model.state = state(task.status)
        model.priority = priority(task.priority)
        model.due = task.dueDay.map { due($0, today: today, calendar: calendar, locale: locale) }
        model.tags = task.tags
        model.attachments = task.attachments.count
        if !subtasks.isEmpty {
            model.subtasks = (subtasks.filter { $0.status == .done }.count, subtasks.count)
        }
        return model
    }

    /// A Done log day heading: Today, Yesterday, then "Mon 21 Sep" (with the
    /// year when it isn't this year).
    static func doneDayTitle(_ day: Date, today: Date, calendar: Calendar, locale: Locale) -> String {
        let start = calendar.startOfDay(for: day)
        let todayStart = calendar.startOfDay(for: today)
        let offset = calendar.dateComponents([.day], from: start, to: todayStart).day ?? 0
        if offset == 0 { return String(localized: "Today") }
        if offset == 1 { return String(localized: "Yesterday") }
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: todayStart)
        return format(start, template: sameYear ? "EEEdMMM" : "EEEdMMMy", calendar: calendar, locale: locale)
    }
}
