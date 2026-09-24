import Foundation

/// A due date is a calendar day, not an instant. It is stored as
/// `yyyy-MM-dd` so it reads the same in every time zone and never shifts
/// when the Mac travels; it becomes an instant only when compared with "now"
/// in the current calendar.
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

    /// The day `date` falls on in `calendar` (its time zone decides).
    init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        // A Gregorian-compatible calendar always yields these components.
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

    /// Midnight at the start of this day in `calendar`.
    func startDate(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func < (lhs: DueDay, rhs: DueDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
