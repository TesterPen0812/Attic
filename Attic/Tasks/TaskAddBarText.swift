import Foundation

/// The add bar's understanding of what was typed: the Phase 0 parser, minus
/// the pieces the person turned back into text (Backspace on a chip), and
/// the chips to draw while typing. Pure: tested directly.
struct TaskAddBarText: Equatable {
    var text = ""
    /// Recognised pieces the person turned back into plain text (UTF-16
    /// ranges in `text`); edits move them along or forget them.
    var dismissed: [NSRange] = []

    /// The recognised pieces that still count, in text order.
    func activeTokens(parser: TaskTextParser) -> [ParsedTaskToken] {
        parser.parse(text).tokens.filter { !dismissed.contains($0.utf16Range(in: text)) }
    }

    /// The ranges drawn as chips. A piece becomes a chip once its word is
    /// finished: while the insertion point sits right at its end the person
    /// may still be typing ("fri" on the way to "friday", "mon" to "monday").
    func chips(parser: TaskTextParser, caret: Int?) -> [NSRange] {
        activeTokens(parser: parser)
            .map { $0.utf16Range(in: text) }
            .filter { caret == nil || NSMaxRange($0) != caret }
    }

    /// The task this text makes, or nil when there is nothing to add. A
    /// line that is only pieces (for example "#home") keeps its text as
    /// the title, as the draft step does for pasted lines.
    func draft(parser: TaskTextParser, status: TaskStatus, parentID: UUID? = nil) -> TaskDraft? {
        let collapsed = TaskDraftBuilder.collapsed(text)
        guard !collapsed.isEmpty else { return nil }
        let tokens = activeTokens(parser: parser)
        let title = TaskTextParser.title(text, removing: tokens.map(\.range))
        var tags: [String] = []
        var dueDay: DueDay?
        var priority: TaskPriority?
        for token in tokens {
            switch token.value {
            case let .tag(tag): tags.append(tag)
            case let .dueDay(day): dueDay = dueDay ?? day
            case let .priority(level): priority = priority ?? level
            }
        }
        return TaskDraft(
            title: title.isEmpty ? collapsed : title,
            tags: tags,
            dueDay: dueDay,
            priority: priority ?? .none,
            status: status,
            parentID: parentID
        )
    }

    /// Backspace on a chip: the piece stays, as plain text.
    mutating func dismiss(_ range: NSRange) {
        if !dismissed.contains(range) { dismissed.append(range) }
    }

    /// An edit replaced `range` with `replacement`: pieces after it move
    /// along, pieces before it stay, and a piece the edit touched (or a word
    /// the edit joins, typed right against it) is forgotten, so the parser
    /// decides afresh.
    mutating func edited(_ range: NSRange, replacement: String) {
        let delta = (replacement as NSString).length - range.length
        let insertion = range.length == 0 && !replacement.isEmpty
        dismissed = dismissed.compactMap { piece in
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
    }

    mutating func clear() {
        text = ""
        dismissed = []
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
