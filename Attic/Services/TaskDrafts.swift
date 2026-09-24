import Foundation

/// A task that has been understood but not created yet. Every way of making
/// tasks (the MCP `create_task` now; the add bar, paste, drag and any later
/// AI in later phases) produces drafts, and `TaskStore.commit(_:)` turns a
/// batch into real tasks in one save, so all creation shares one set of rules.
struct TaskDraft: Equatable {
    var title: String
    var tags: [String]
    var dueDay: DueDay?
    var priority: TaskPriority
    /// The list the task goes to: `.todo` for Now, `.backlog` for Backlog
    /// (`.inProgress` is allowed for agents that start work straight away).
    var status: TaskStatus
    var parentID: UUID?
    /// Files already copied into private storage by a composer; bound in the
    /// same save as the task.
    var attachments: [TaskImageReference]

    init(
        title: String,
        tags: [String] = [],
        dueDay: DueDay? = nil,
        priority: TaskPriority = .none,
        status: TaskStatus = .todo,
        parentID: UUID? = nil,
        attachments: [TaskImageReference] = []
    ) {
        self.title = title
        self.tags = AtticTag.normalizedSet(tags)
        self.dueDay = dueDay
        self.priority = priority
        self.status = status
        self.parentID = parentID
        self.attachments = attachments
    }
}

/// How pasted text with several lines becomes drafts; the caller asks
/// (the add bar offers "Add 5 tasks" or "Add as one task").
enum TaskDraftSplitMode: Equatable {
    case onePerLine
    case single
}

/// Turns typed or pasted text into drafts with the shared parser.
struct TaskDraftBuilder {
    let parser: TaskTextParser
    /// Where drafts go unless the text says otherwise.
    var status: TaskStatus = .todo
    var parentID: UUID? = nil
    /// Tags every draft gets in addition to the ones typed (for example a
    /// note's tags when a card is made in it).
    var inheritedTags: [String] = []

    init(parser: TaskTextParser, status: TaskStatus = .todo, parentID: UUID? = nil, inheritedTags: [String] = []) {
        self.parser = parser
        self.status = status
        self.parentID = parentID
        self.inheritedTags = inheritedTags
    }

    /// Blank lines are skipped; list bullets and checkbox markers at the
    /// start of a pasted line are dropped. A line that is only tokens (for
    /// example "#home") keeps its text as the title rather than vanishing.
    func drafts(from text: String, mode: TaskDraftSplitMode) -> [TaskDraft] {
        switch mode {
        case .onePerLine:
            return Self.lines(of: text).compactMap(draft(fromLine:))
        case .single:
            let joined = Self.lines(of: text).joined(separator: " ")
            return draft(fromLine: joined).map { [$0] } ?? []
        }
    }

    func draft(fromLine line: String) -> TaskDraft? {
        let text = Self.strippingListMarker(line)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parsed = parser.parse(text)
        let title = parsed.title.isEmpty ? Self.collapsed(text) : parsed.title
        return TaskDraft(
            title: title,
            tags: parsed.tags + inheritedTags,
            dueDay: parsed.dueDay,
            priority: parsed.priority ?? .none,
            status: status,
            parentID: parentID
        )
    }

    static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// "- ", "* ", "• ", "1. ", "1) ", "[ ] ", "- [x] " and similar.
    static func strippingListMarker(_ line: String) -> String {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        func dropPrefix(_ prefixes: [String]) -> Bool {
            for prefix in prefixes where rest.hasPrefix(prefix) {
                rest = rest.dropFirst(prefix.count)
                rest = rest.drop(while: { $0 == " " || $0 == "\t" })
                return true
            }
            return false
        }
        _ = dropPrefix(["- ", "* ", "+ ", "• ", "– "])
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                rest = after.dropFirst(2).drop(while: { $0 == " " })
            }
        }
        _ = dropPrefix(["[ ] ", "[x] ", "[X] ", "[] "])
        return String(rest)
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
