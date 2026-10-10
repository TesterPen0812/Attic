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
        .NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
        NSLocale.currentLocaleDidChangeNotification
    ]
}
