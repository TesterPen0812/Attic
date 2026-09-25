import Foundation

/// A due date is a calendar day, not an instant. It is stored as
/// `yyyy-MM-dd` so it reads the same in every time zone and never shifts
/// when the Mac travels; it becomes an instant only when compared with "now"
/// in the current time zone.
///
/// The stored form is an ISO (Gregorian) date whatever calendar the Mac is
/// set to: a Buddhist or Japanese system calendar numbers years differently
/// (2569, or 8 for Reiwa 8), and those numbers must never become the stored
/// year. Conversions to and from instants therefore always use a Gregorian
/// calendar in the supplied calendar's time zone.
struct DueDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    /// Only real calendar days are accepted (no 31 September, no 29 February
    /// outside leap years).
    init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = gregorian.date(from: DateComponents(year: year, month: month, day: day)),
              gregorian.component(.day, from: date) == day,
              gregorian.component(.month, from: date) == month else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar`'s time zone. Only the time zone
    /// is taken from `calendar`; the day is always read in the Gregorian
    /// calendar the stored form uses.
    init(date: Date, calendar: Calendar) {
        let components = Self.storageCalendar(matching: calendar).dateComponents([.year, .month, .day], from: date)
        // The Gregorian calendar always yields these components.
        self.year = components.year ?? 1970
        self.month = components.month ?? 1
        self.day = components.day ?? 1
    }

    /// Parses the stored form, `yyyy-MM-dd`, and nothing else.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var rawValue: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var description: String { rawValue }

    /// Midnight at the start of this day in `calendar`'s time zone.
    func startDate(in calendar: Calendar) -> Date? {
        Self.storageCalendar(matching: calendar).date(from: DateComponents(year: year, month: month, day: day))
    }

    /// A Gregorian calendar in `calendar`'s time zone (and locale, which only
    /// affects week numbering): the calendar every due-day conversion uses.
    static func storageCalendar(matching calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale
        gregorian.firstWeekday = calendar.firstWeekday
        gregorian.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        return gregorian
    }

    static func < (lhs: DueDay, rhs: DueDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
