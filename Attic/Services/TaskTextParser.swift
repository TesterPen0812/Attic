import Foundation

/// A piece of typed text the parser recognised. The UI turns each into a
/// chip; Backspace on a chip turns it back into its text (`range`).
struct ParsedTaskToken: Equatable {
    enum Value: Equatable {
        case tag(String)
        case dueDay(DueDay)
        case priority(TaskPriority)
    }

    let value: Value
    /// Where the token is in the parsed text.
    let range: Range<String.Index>

    /// The same range in UTF-16 units, for AppKit text views.
    func utf16Range(in text: String) -> NSRange {
        NSRange(range, in: text)
    }
}

struct ParsedTaskText: Equatable {
    let text: String
    /// Recognised tokens in text order.
    let tokens: [ParsedTaskToken]
    /// The text with every token removed and whitespace tidied.
    let title: String

    var tags: [String] {
        tokens.compactMap { if case let .tag(tag) = $0.value { tag } else { nil } }
    }

    var dueDay: DueDay? {
        tokens.lazy.compactMap { if case let .dueDay(day) = $0.value { day } else { nil } }.first
    }

    var priority: TaskPriority? {
        tokens.lazy.compactMap { if case let .priority(priority) = $0.value { priority } else { nil } }.first
    }
}

/// Understands the add bar's shorthand, for people and agents alike. Pure:
/// the calendar, locale and "now" are injected, so the same text always
/// parses the same way in tests.
///
/// - `#tag`: at the start of a word, letters, numbers, `-` and `_`, with at
///   least one letter ("#42" stays text, like an issue number).
/// - Dates in English: today, tomorrow, weekday names (the next one, never
///   today), "next week" (the next Monday), "next friday", "sep 30",
///   "30 september 2027", "30/9" and "9/30" (the region decides when both
///   readings are valid), "2026-09-30", "in 3 days", "in 2 weeks",
///   "in 1 month". A month name counts only with a day number, so "the may
///   release" stays text. A date without a year that has passed this year
///   means next year. Only the first date is recognised; later ones stay text.
///   The short weekday forms that are everyday words ("sun", "sat", "wed")
///   are not dates; their full names are.
/// - Priority: a standalone `!` (medium) or `!!` (high). "Call mom!" stays
///   text, and `!` inside a word is ignored. Only the first one counts.
struct TaskTextParser {
    var calendar: Calendar
    var locale: Locale
    var now: () -> Date

    init(
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.calendar = calendar
        self.locale = locale
        self.now = now
    }

    func parse(_ text: String) -> ParsedTaskText {
        let words = Self.words(in: text)
        var tokens: [ParsedTaskToken] = []
        let today = DueDay(date: now(), calendar: calendar)

        var index = 0
        var foundDate = false
        var foundPriority = false
        while index < words.count {
            let word = words[index]
            if !foundPriority, let priority = Self.priority(word.raw) {
                tokens.append(ParsedTaskToken(value: .priority(priority), range: word.rawRange))
                foundPriority = true
                index += 1
                continue
            }
            if let tag = Self.tag(word.core) {
                tokens.append(ParsedTaskToken(value: .tag(tag), range: word.coreRange))
                index += 1
                continue
            }
            if !foundDate, let (day, length) = date(at: index, in: words, today: today) {
                let range = word.coreRange.lowerBound..<words[index + length - 1].coreRange.upperBound
                tokens.append(ParsedTaskToken(value: .dueDay(day), range: range))
                foundDate = true
                index += length
                continue
            }
            index += 1
        }

        return ParsedTaskText(text: text, tokens: tokens, title: Self.title(text, removing: tokens.map(\.range)))
    }

    /// A due date given on its own (an agent's `due` argument): the whole
    /// phrase must be one date, in any form `parse` understands.
    func parseDueDay(_ phrase: String) -> DueDay? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if let iso = DueDay(rawValue: trimmed) { return iso }
        let words = Self.words(in: trimmed)
        guard !words.isEmpty,
              let (day, length) = date(at: 0, in: words, today: DueDay(date: now(), calendar: calendar)),
              length == words.count else { return nil }
        return day
    }

    // MARK: - Words

    struct Word {
        /// The whitespace-delimited word as typed.
        let raw: Substring
        let rawRange: Range<String.Index>
        /// Lowercased, without trailing punctuation such as "," or ".".
        let core: String
        let coreRange: Range<String.Index>
    }

    static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            let raw = text[index..<end]
            var coreEnd = end
            while coreEnd > index, ",.;:?)!\"'”’".contains(text[text.index(before: coreEnd)]) {
                coreEnd = text.index(before: coreEnd)
            }
            if coreEnd == index { coreEnd = end }
            words.append(Word(
                raw: raw,
                rawRange: index..<end,
                core: text[index..<coreEnd].lowercased(),
                coreRange: index..<coreEnd
            ))
            index = end
        }
        return words
    }

    // MARK: - Tags and priority

    static func tag(_ core: String) -> String? {
        guard core.hasPrefix("#"), !core.hasPrefix("##") else { return nil }
        let body = core.dropFirst()
        guard !body.isEmpty,
              body.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              body.contains(where: \.isLetter) else { return nil }
        return AtticTag.normalize(String(body))
    }

    static func priority(_ raw: Substring) -> TaskPriority? {
        switch raw {
        case "!": .medium
        case "!!": .high
        default: nil
        }
    }

    // MARK: - Dates

    /// The date starting at `index`, and how many words it spans.
    private func date(at index: Int, in words: [Word], today: DueDay) -> (DueDay, Int)? {
        let word = words[index].core
        let next = index + 1 < words.count ? words[index + 1].core : nil
        let afterNext = index + 2 < words.count ? words[index + 2].core : nil

        // "in 3 days", "in 2 weeks", "in 1 month", "in a week"
        if word == "in", let next, let afterNext,
           let amount = next == "a" || next == "an" ? 1 : Int(next), (0...3650).contains(amount),
           let unit = Self.relativeUnit(afterNext),
           let date = calendar.date(byAdding: unit, value: amount, to: now()) {
            return (DueDay(date: date, calendar: calendar), 3)
        }
        if word == "next", let next {
            if next == "week", let monday = nextOccurrence(ofWeekday: 2, after: today) {
                return (monday, 2)
            }
            if let weekday = Self.weekday(next, allowingAmbiguousShortForms: true),
               let day = nextOccurrence(ofWeekday: weekday, after: today) {
                return (day, 2)
            }
        }
        if word == "today" { return (today, 1) }
        if word == "tomorrow" {
            return offset(today, days: 1).map { ($0, 1) }
        }
        if let weekday = Self.weekday(word, allowingAmbiguousShortForms: false),
           let day = nextOccurrence(ofWeekday: weekday, after: today) {
            return (day, 1)
        }
        // "sep 30", "sep 30th 2027"
        if let month = Self.month(word), let next, let dayNumber = Self.dayNumber(next) {
            let year = afterNext.flatMap(Self.year)
            if let day = resolve(month: month, day: dayNumber, year: year, today: today) {
                return (day, year == nil ? 2 : 3)
            }
        }
        // "30 sep", "30th september 2027"
        if let dayNumber = Self.dayNumber(word), let next, let month = Self.month(next) {
            let year = afterNext.flatMap(Self.year)
            if let day = resolve(month: month, day: dayNumber, year: year, today: today) {
                return (day, year == nil ? 2 : 3)
            }
        }
        if let iso = DueDay(rawValue: word) { return (iso, 1) }
        if let numeric = numericDate(word, today: today) { return (numeric, 1) }
        return nil
    }

    private func offset(_ day: DueDay, days: Int) -> DueDay? {
        guard let start = day.startDate(in: calendar),
              let date = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        return DueDay(date: date, calendar: calendar)
    }

    /// The first day strictly after `today` that falls on `weekday`
    /// (1 = Sunday … 7 = Saturday).
    private func nextOccurrence(ofWeekday weekday: Int, after today: DueDay) -> DueDay? {
        guard let start = today.startDate(in: calendar) else { return nil }
        let current = calendar.component(.weekday, from: start)
        var delta = (weekday - current + 7) % 7
        if delta == 0 { delta = 7 }
        return offset(today, days: delta)
    }

    private func resolve(month: Int, day: Int, year: Int?, today: DueDay) -> DueDay? {
        if let year { return DueDay(year: year, month: month, day: day) }
        if let thisYear = DueDay(year: today.year, month: month, day: day), thisYear >= today {
            return thisYear
        }
        return DueDay(year: today.year + 1, month: month, day: day)
            // 29 February: the next year that has one.
            ?? (2...8).lazy.compactMap { DueDay(year: today.year + $0, month: month, day: day) }.first
    }

    /// "30/9", "9/30", "30/9/2026", "9/30/26". The region's order wins when
    /// both readings are valid; otherwise the valid reading is used.
    private func numericDate(_ word: String, today: DueDay) -> DueDay? {
        let parts = word.split(separator: "/", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts[0].count <= 2, parts[1].count <= 2,
              let first = Int(parts[0]), let second = Int(parts[1]) else { return nil }
        var year: Int?
        if parts.count == 3 {
            guard parts[2].count == 2 || parts[2].count == 4, let value = Int(parts[2]) else { return nil }
            year = parts[2].count == 2 ? 2000 + value : value
        }
        let dayFirst = Self.prefersDayFirst(locale: locale)
        let readings = dayFirst ? [(first, second), (second, first)] : [(second, first), (first, second)]
        for (day, month) in readings {
            // 2000 is a leap year, so only impossible days fail here.
            if DueDay(year: year ?? 2000, month: month, day: day) != nil,
               let resolved = resolve(month: month, day: day, year: year, today: today) {
                return resolved
            }
        }
        return nil
    }

    /// Whether the region writes the day before the month (30/9).
    static func prefersDayFirst(locale: Locale) -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "dM", options: 0, locale: locale) ?? "M/d"
        guard let day = format.firstIndex(of: "d"), let month = format.firstIndex(of: "M") else { return false }
        return day < month
    }

    private static func relativeUnit(_ word: String) -> Calendar.Component? {
        switch word {
        case "day", "days": .day
        case "week", "weeks": .weekOfYear
        case "month", "months": .month
        default: nil
        }
    }

    /// 1 = Sunday … 7 = Saturday.
    static func weekday(_ word: String, allowingAmbiguousShortForms: Bool) -> Int? {
        switch word {
        case "sunday": 1
        case "monday", "mon": 2
        case "tuesday", "tue", "tues": 3
        case "wednesday": 4
        case "thursday", "thu", "thur", "thurs": 5
        case "friday", "fri": 6
        case "saturday": 7
        case "sun" where allowingAmbiguousShortForms: 1
        case "wed" where allowingAmbiguousShortForms: 4
        case "sat" where allowingAmbiguousShortForms: 7
        default: nil
        }
    }

    static func month(_ word: String) -> Int? {
        switch word {
        case "jan", "january": 1
        case "feb", "february": 2
        case "mar", "march": 3
        case "apr", "april": 4
        case "may": 5
        case "jun", "june": 6
        case "jul", "july": 7
        case "aug", "august": 8
        case "sep", "sept", "september": 9
        case "oct", "october": 10
        case "nov", "november": 11
        case "dec", "december": 12
        default: nil
        }
    }

    /// "30", "30th", "1st", "2nd", "3rd".
    static func dayNumber(_ word: String) -> Int? {
        var digits = Substring(word)
        for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) {
            digits = digits.dropLast(2)
            break
        }
        guard (1...2).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits), (1...31).contains(value) else { return nil }
        return value
    }

    static func year(_ word: String) -> Int? {
        guard word.count == 4, word.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(word), (1900...2999).contains(value) else { return nil }
        return value
    }

    // MARK: - Title

    static func title(_ text: String, removing ranges: [Range<String.Index>]) -> String {
        var kept = ""
        var index = text.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= index {
            kept += text[index..<range.lowerBound]
            kept += " "
            index = range.upperBound
        }
        kept += text[index...]
        var words = kept.split(whereSeparator: \.isWhitespace).map(String.init)
        // Punctuation left behind by a removed token attaches to the word
        // before it ("Call mom , today" → "Call mom,") or is dropped when it
        // stands alone at either end.
        var tidied: [String] = []
        for word in words {
            if word.allSatisfy({ ",.;:".contains($0) }) {
                if var last = tidied.popLast() { last += word; tidied.append(last) }
                continue
            }
            tidied.append(word)
        }
        words = tidied
        var result = words.joined(separator: " ")
        while let last = result.last, ",;:".contains(last) { result.removeLast() }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
