import Foundation

/// A frozen key for date presentation. Autoupdating Calendar/Locale values
/// themselves must not be stored as cache keys: their old values would move
/// with the system and conceal the change.
struct DatePresentationEnvironment: Equatable {
    let calendar: Calendar.Identifier
    let timeZone: String
    let locale: String
    let firstWeekday: Int
    let minimumDaysInFirstWeek: Int

    init(calendar: Calendar, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar.identifier
        timeZone = calendar.timeZone.identifier
        self.locale = locale.identifier
        firstWeekday = calendar.firstWeekday
        minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
    }

    static let notifications: [Notification.Name] = [
        .NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange,
        NSLocale.currentLocaleDidChangeNotification
    ]
}

/// A single cached template formatter for Tasks, Calendar and other date
/// presentations. Calendar/time-zone/locale are part of the cache identity;
/// the caller still decides which template its own row should show.
enum AtticDateFormatting {
    static func template(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
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

    private nonisolated(unsafe) static let formatters = NSCache<NSString, DateFormatter>()
}

/// Shared edit-timestamp wording for Notes and Draw libraries. The local
/// calendar's day boundary determines the label, including across years.
enum AtticRelativeDateFormatting {
    static func editTime(_ date: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        if date >= today {
            style = style.hour().minute()
        } else if let weekStart = calendar.date(byAdding: .day, value: -6, to: today), date >= weekStart {
            style = style.weekday(.abbreviated)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            style = style.day().month(.abbreviated)
        } else {
            style = style.day().month(.abbreviated).year()
        }
        return date.formatted(style)
    }
}
