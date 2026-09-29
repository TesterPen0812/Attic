import Foundation

/// What the date card's field understands (p2-03 #3: "fri"): today,
/// tomorrow, yesterday, a weekday or its first letters (the next one,
/// today included), "next fri", "in 3 days", "+3", "-2", a day of the month
/// ("12": this month, or next month once it has passed), then whatever the
/// system's date detector reads ("2 Oct", "10/2/2026", "next Tuesday").
enum NoteDateQuery {
    static func parse(_ text: String, today: Date, calendar: Calendar = .current, locale: Locale = .current) -> Date? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let start = calendar.startOfDay(for: today)
        guard !query.isEmpty else { return nil }
        func days(_ value: Int) -> Date? { calendar.date(byAdding: .day, value: value, to: start) }

        let todayWords = [String(localized: "today").lowercased(), "today", "tod", "now"]
        if todayWords.contains(query) { return start }
        if ["tomorrow", "tom", "tmr", "tmrw", String(localized: "tomorrow").lowercased()].contains(query) { return days(1) }
        if ["yesterday", "yest", String(localized: "yesterday").lowercased()].contains(query) { return days(-1) }

        // "+3", "-2", "in 3 days", "3 days", "in 2 weeks".
        if let signed = Int(query), query.hasPrefix("+") || query.hasPrefix("-") { return days(signed) }
        let words = query.split(separator: " ").map(String.init)
        let counted = words.first == "in" ? Array(words.dropFirst()) : words
        if counted.count == 2, let count = Int(counted[0]) {
            if counted[1].hasPrefix("day") { return days(count) }
            if counted[1].hasPrefix("week") { return days(count * 7) }
        }

        // A weekday, optionally after "next" (a week later than the plain one).
        var weekdayWord = query
        var skipWeek = false
        if words.count == 2, words[0] == "next" { weekdayWord = words[1]; skipWeek = true }
        if let weekday = weekday(matching: weekdayWord, calendar: calendar, locale: locale) {
            let current = calendar.component(.weekday, from: start)
            var ahead = (weekday - current + 7) % 7
            if skipWeek && ahead == 0 { ahead = 7 } else if skipWeek { ahead += 7 }
            return days(ahead)
        }

        // A day of this month, or of next month once it has passed.
        if let day = Int(query), (1...31).contains(day) {
            var components = calendar.dateComponents([.year, .month], from: start)
            for _ in 0..<3 {
                components.day = day
                if let date = calendar.date(from: components), calendar.component(.day, from: date) == day, date >= start {
                    return date
                }
                components.day = 1
                guard let first = calendar.date(from: components),
                      let next = calendar.date(byAdding: .month, value: 1, to: first) else { break }
                components = calendar.dateComponents([.year, .month], from: next)
            }
            return nil
        }

        return detected(text, today: start, calendar: calendar)
    }

    /// 1 (Sunday) … 7, for a weekday name or its first two or more letters.
    static func weekday(matching word: String, calendar: Calendar, locale: Locale) -> Int? {
        guard word.count >= 2 else { return nil }
        var names = calendar.weekdaySymbols.map { $0.lowercased() }
        var english = Calendar(identifier: .gregorian)
        english.locale = Locale(identifier: "en_US_POSIX")
        let fallback = english.weekdaySymbols.map { $0.lowercased() }
        if names.count != 7 { names = fallback }
        for index in 0..<7 where names[index].hasPrefix(word) || fallback[index].hasPrefix(word) {
            return index + 1
        }
        return nil
    }

    private static func detected(_ text: String, today: Date, calendar: Calendar) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range), let date = match.date else { return nil }
        return calendar.startOfDay(for: date)
    }
}
