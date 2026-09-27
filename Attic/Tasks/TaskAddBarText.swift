import Foundation

/// The add bar's understanding of what was typed: the Phase 0 parser, minus
/// the pieces the person turned back into text (Backspace on a chip), plus
/// the pieces picked from the strip or a suggestion (their exact value,
/// whatever their words say), and the chips to draw while typing. Pure:
/// tested directly. The title editor uses it too (owner fix 4).
///
/// Three kinds of state, kept apart (review 3): what a piece *means* (the
/// parser, `dismissed`, `pinned`), and what is *drawn* (`shown`): a piece
/// becomes a chip once its word is finished, and stays one when the caret
/// comes back to its end, so Backspace there always finds the chip it sees.
struct TaskAddBarText: Equatable {
    var text = ""
    /// Recognised pieces the person turned back into plain text (UTF-16
    /// ranges in `text`); edits move them along or forget them.
    var dismissed: [NSRange] = []
    /// Pieces chosen from the strip, a picker or a suggestion: their exact
    /// value (a picked calendar day stays that day, whatever "30 Sep"
    /// would parse to next year). Edits move them along or forget them.
    var pinned: [Pinned] = []
    /// Pieces that have been drawn as chips (their word was finished).
    var shown: [NSRange] = []

    struct Pinned: Equatable {
        var range: NSRange
        var value: ParsedTaskToken.Value
    }

    init(text: String = "") {
        self.text = text
    }

    /// The recognised pieces that still count, in text order: the parser's
    /// (minus dismissed ones and any a pinned piece replaces) and the
    /// pinned ones. A pinned date or priority wins over a typed one.
    func activeTokens(parser: TaskTextParser) -> [ParsedTaskToken] {
        let pinnedTokens = pinned.compactMap { piece -> ParsedTaskToken? in
            guard NSMaxRange(piece.range) <= (text as NSString).length, let range = Range(piece.range, in: text) else { return nil }
            return ParsedTaskToken(value: piece.value, range: range)
        }
        let pinnedDate = pinned.contains { if case .dueDay = $0.value { true } else { false } }
        let pinnedPriority = pinned.contains { if case .priority = $0.value { true } else { false } }
        let parsed = parser.parse(text).tokens.filter { token in
            let range = token.utf16Range(in: text)
            if dismissed.contains(range) { return false }
            if pinned.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { return false }
            switch token.value {
            case .dueDay: return !pinnedDate
            case .priority: return !pinnedPriority
            case .tag: return true
            }
        }
        return (parsed + pinnedTokens).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The ranges drawn as chips. A piece becomes a chip once its word is
    /// finished: while the insertion point sits right at its end the person
    /// may still be typing ("fri" on the way to "friday", "mon" to
    /// "monday"). One already drawn (or picked) stays a chip there.
    func chips(parser: TaskTextParser, caret: Int?) -> [NSRange] {
        activeTokens(parser: parser)
            .map { $0.utf16Range(in: text) }
            .filter { range in caret == nil || NSMaxRange(range) != caret || shown.contains(range) || pinned.contains { $0.range == range } }
    }

    /// The caret moved: every piece it is not at the end of is finished,
    /// and stays drawn from now on. Returns whether anything changed.
    @discardableResult
    mutating func markShown(parser: TaskTextParser, caret: Int?) -> Bool {
        guard let caret else { return false }
        var changed = false
        for token in activeTokens(parser: parser) {
            let range = token.utf16Range(in: text)
            if NSMaxRange(range) != caret, !shown.contains(range) {
                shown.append(range)
                changed = true
            }
        }
        return changed
    }

    /// The task this text makes, or nil when there is nothing to add. A
    /// line that is only pieces (for example "#home") keeps its text as
    /// the title, as the draft step does for pasted lines.
    func draft(parser: TaskTextParser, status: TaskStatus, parentID: UUID? = nil) -> TaskDraft? {
        let collapsed = TaskDraftBuilder.collapsed(text)
        guard !collapsed.isEmpty else { return nil }
        let parts = parts(parser: parser)
        return TaskDraft(
            title: parts.title.isEmpty ? collapsed : parts.title,
            tags: parts.tags,
            dueDay: parts.dueDay,
            priority: parts.priority ?? .none,
            status: status,
            parentID: parentID
        )
    }

    /// What the text says: its title without the pieces, and the pieces'
    /// values (the first date and priority count).
    struct Parts: Equatable {
        var title: String
        var tags: [String] = []
        var dueDay: DueDay?
        var priority: TaskPriority?
    }

    func parts(parser: TaskTextParser) -> Parts {
        let tokens = activeTokens(parser: parser)
        var parts = Parts(title: TaskTextParser.title(text, removing: tokens.map(\.range)))
        for token in tokens {
            switch token.value {
            case let .tag(tag): if !parts.tags.contains(tag) { parts.tags.append(tag) }
            case let .dueDay(day): parts.dueDay = parts.dueDay ?? day
            case let .priority(level): parts.priority = parts.priority ?? level
            }
        }
        return parts
    }

    /// Backspace on a chip: the piece stays, as plain text (a picked piece
    /// loses its value too).
    mutating func dismiss(_ range: NSRange) {
        pinned.removeAll { $0.range == range }
        shown.removeAll { $0 == range }
        if !dismissed.contains(range) { dismissed.append(range) }
    }

    /// Every piece the parser sees in the text as it is now counts as
    /// plain text: a title being edited keeps the words it already had
    /// ("Call mom today" stays that title), and only new shorthand applies.
    mutating func dismissAllRecognised(parser: TaskTextParser) {
        dismissed = parser.parse(text).tokens.map { $0.utf16Range(in: text) }
    }

    /// Remembers a picked piece at `range` with its exact value.
    mutating func pin(_ range: NSRange, value: ParsedTaskToken.Value) {
        pinned.removeAll { NSIntersectionRange($0.range, range).length > 0 || $0.range == range }
        dismissed.removeAll { NSIntersectionRange($0, range).length > 0 }
        pinned.append(Pinned(range: range, value: value))
        if !shown.contains(range) { shown.append(range) }
    }

    /// An edit replaced `range` with `replacement`: pieces after it move
    /// along, pieces before it stay, and a piece the edit touched (or a word
    /// the edit joins, typed right against it) is forgotten, so the parser
    /// decides afresh.
    mutating func edited(_ range: NSRange, replacement: String) {
        dismissed = dismissed.compactMap { Self.shift($0, by: range, replacement: replacement) }
        shown = shown.compactMap { Self.shift($0, by: range, replacement: replacement) }
        pinned = pinned.compactMap { piece in
            Self.shift(piece.range, by: range, replacement: replacement).map { Pinned(range: $0, value: piece.value) }
        }
    }

    static func shift(_ piece: NSRange, by range: NSRange, replacement: String) -> NSRange? {
        let delta = (replacement as NSString).length - range.length
        let insertion = range.length == 0 && !replacement.isEmpty
        let end = NSMaxRange(piece)
        if range.location >= end {
            // After the piece; typing straight on from its end joins it.
            let joins = insertion && range.location == end
                && replacement.first.map { !$0.isWhitespace } == true
            return joins ? nil : piece
        }
        if NSMaxRange(range) <= piece.location {
            let joins = insertion && range.location == piece.location
                && replacement.last.map { !$0.isWhitespace } == true
            return joins ? nil : NSRange(location: piece.location + delta, length: piece.length)
        }
        return nil
    }

    mutating func clear() {
        text = ""
        dismissed = []
        pinned = []
        shown = []
    }

    // MARK: - Where a pick goes

    /// The range of the active piece of this kind (the date, the priority),
    /// which a new pick replaces rather than competing with it.
    func range(of kind: PieceKind, parser: TaskTextParser) -> NSRange? {
        activeTokens(parser: parser).first { kind.matches($0.value) }.map { $0.utf16Range(in: text) }
    }

    enum PieceKind {
        case date, priority

        func matches(_ value: ParsedTaskToken.Value) -> Bool {
            switch (self, value) {
            case (.date, .dueDay), (.priority, .priority): true
            default: false
            }
        }
    }

    /// The edit that puts `words` into the text as a piece: in place of the
    /// existing piece of that kind, or at the caret (the end when unknown)
    /// with a space on either side as needed. Returns the range to replace,
    /// the string to put there, and where the piece's own words land.
    func insertion(of words: String, replacing existing: NSRange?, caret: Int?) -> (range: NSRange, string: String, piece: NSRange) {
        let ns = text as NSString
        if let existing {
            return (existing, words, NSRange(location: existing.location, length: (words as NSString).length))
        }
        var at = min(max(caret ?? ns.length, 0), ns.length)
        // Not in the middle of a word: after it.
        while at < ns.length, let scalar = UnicodeScalar(ns.character(at: at)), !CharacterSet.whitespaces.contains(scalar) { at += 1 }
        let before = at > 0 ? ns.character(at: at - 1) : 32
        let after = at < ns.length ? ns.character(at: at) : 32
        let needsLead = at > 0 && !(UnicodeScalar(before).map(CharacterSet.whitespaces.contains) ?? true)
        let needsTrail = !(UnicodeScalar(after).map(CharacterSet.whitespaces.contains) ?? true) || at == ns.length
        let string = (needsLead ? " " : "") + words + (needsTrail ? " " : "")
        let piece = NSRange(location: at + (needsLead ? 1 : 0), length: (words as NSString).length)
        return (NSRange(location: at, length: 0), string, piece)
    }

    // MARK: - Suggestions while typing (owner fix 5 B)

    enum Suggestion: Equatable {
        /// `#…` at the caret: the matching tags (existing first), and
        /// "Create #…" when none is exactly it.
        case tags(range: NSRange, query: String, matches: [String], create: String?)
        /// A date word at the caret: the day it means, before it is taken.
        case date(range: NSRange, words: String, title: String, day: DueDay)

        var range: NSRange {
            switch self {
            case let .tags(range, _, _, _), let .date(range, _, _, _): range
            }
        }

        /// How many choices the list shows.
        var count: Int {
            switch self {
            case let .tags(_, _, matches, create): matches.count + (create == nil ? 0 : 1)
            case .date: 1
            }
        }
    }

    /// The word ending at the caret (only when the caret is at a word's
    /// end), as a UTF-16 range.
    func wordBeforeCaret(_ caret: Int?) -> NSRange? {
        let ns = text as NSString
        guard let caret, caret > 0, caret <= ns.length else { return nil }
        if caret < ns.length, let scalar = UnicodeScalar(ns.character(at: caret)), !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return nil
        }
        var start = caret
        while start > 0, let scalar = UnicodeScalar(ns.character(at: start - 1)), !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start -= 1
        }
        return start < caret ? NSRange(location: start, length: caret - start) : nil
    }

    /// Date words a few typed letters complete ("tom" → tomorrow).
    static let everydayWords: Set<String> = ["sun", "sat", "wed"]
    static let dateWords = ["today", "tomorrow", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// What to suggest for the word at the caret, or nil. `tags` are the
    /// library's tags, most used first.
    func suggestion(parser: TaskTextParser, caret: Int?, tags: [String], limit: Int = 6) -> Suggestion? {
        guard let range = wordBeforeCaret(caret) else { return nil }
        let ns = text as NSString
        let word = ns.substring(with: range)
        if pinned.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { return nil }
        if dismissed.contains(where: { NSIntersectionRange($0, range).length > 0 }) { return nil }
        if word.hasPrefix("#") {
            let query = String(word.dropFirst()).lowercased()
            guard query.isEmpty || AtticTag.normalize(query) != nil || query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            let prefix = tags.filter { $0.lowercased().hasPrefix(query) }
            let inside = query.isEmpty ? [] : tags.filter { !$0.lowercased().hasPrefix(query) && $0.lowercased().contains(query) }
            let matches = Array((prefix + inside).prefix(limit))
            let normalized = AtticTag.normalize(query)
            let create = normalized.flatMap { name in tags.contains { $0.lowercased() == name.lowercased() } ? nil : name }
            guard !matches.isEmpty || create != nil else { return nil }
            return .tags(range: range, query: query, matches: matches, create: create)
        }
        let lower = word.lowercased()
        // "next w…" completes "next week".
        if lower.count >= 1, "week".hasPrefix(lower), range.location >= 5 {
            let previous = NSRange(location: range.location - 5, length: 5)
            if ns.substring(with: previous).lowercased() == "next ", previous.location == 0 || wordStartOK(ns, previous.location),
               let day = parser.parseDueDay("next week") {
                let whole = NSRange(location: previous.location, length: NSMaxRange(range) - previous.location)
                return .date(range: whole, words: "next week", title: String(localized: "Next week"), day: day)
            }
        }
        // A finished date the parser already reads here ("30/9", "fri").
        if let token = activeTokens(parser: parser).first(where: { NSMaxRange($0.utf16Range(in: text)) == NSMaxRange(range) }),
           case let .dueDay(day) = token.value {
            let tokenRange = token.utf16Range(in: text)
            let words = ns.substring(with: tokenRange)
            return .date(range: tokenRange, words: words, title: Self.capitalised(words), day: day)
        }
        // Three letters at least, and never the everyday words the parser
        // also refuses as dates ("sun", "sat", "wed").
        guard lower.count >= 3, lower.allSatisfy(\.isLetter), !Self.everydayWords.contains(lower) else { return nil }
        guard let match = Self.dateWords.first(where: { $0.hasPrefix(lower) }), let day = parser.parseDueDay(match) else { return nil }
        return .date(range: range, words: match, title: Self.capitalised(match), day: day)
    }

    private func wordStartOK(_ ns: NSString, _ location: Int) -> Bool {
        guard location > 0, let scalar = UnicodeScalar(ns.character(at: location - 1)) else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    static func capitalised(_ words: String) -> String {
        guard let first = words.first else { return words }
        return first.uppercased() + words.dropFirst()
    }
}

/// Pasted text with several lines, waiting for the person to choose.
struct TaskPasteOffer: Equatable {
    let text: String
    let lineCount: Int

    init?(_ text: String) {
        let lines = TaskDraftBuilder.lines(of: text)
        guard lines.count > 1 else { return nil }
        self.text = text
        lineCount = lines.count
    }
}
