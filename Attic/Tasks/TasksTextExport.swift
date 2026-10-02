import AppKit
import UniformTypeIdentifiers

/// Tasks as text for other apps (owner-approved, 2026-10-01): what Copy (⌘C)
/// and dragging tasks out of the panel give. Each task is its title, then
/// its date, tags and priority, then its subtasks as a "- [ ]" list; in plain
/// text, Markdown and RTF. Pure, tested directly.
///
/// ⌘C's plain text stays the titles alone, one per line (round 10: it pastes
/// back into the add bar as one task per line), with the full text in its
/// Markdown and RTF forms; a drag out carries the full text in all three.
struct TasksTextExport: Equatable {
    struct Item: Equatable {
        struct Subtask: Equatable {
            var title: String
            var isDone: Bool
        }

        var title: String
        var isDone = false
        /// The date as a row shows it ("Today", "Tue", "30 Sep").
        var due: String?
        var tags: [String] = []
        /// The priority's name, or nil for none.
        var priority: String?
        var subtasks: [Subtask] = []

        /// Date, tags and priority, in that order, as one line.
        var details: String? {
            let parts = [due].compactMap { $0 } + tags.map { "#\($0)" } + [priority].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        var isTitleOnly: Bool { details == nil && subtasks.isEmpty }
    }

    let items: [Item]

    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

    /// The titles alone, one per line (⌘C's plain text).
    var titles: String { items.map(\.title).joined(separator: "\n") }

    /// Each task's title, details line and subtasks; tasks with anything
    /// beyond a title are set apart by a blank line.
    var plain: String {
        if items.allSatisfy(\.isTitleOnly) { return titles }
        return items.map { item in
            var lines = [item.title]
            if let details = item.details { lines.append(details) }
            lines += item.subtasks.map { "- [\($0.isDone ? "x" : " ")] \($0.title)" }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// A Markdown checklist: each task a top-level item with its details,
    /// its subtasks nested under it.
    var markdown: String {
        items.map { item in
            var line = "- [\(item.isDone ? "x" : " ")] **\(Self.escaped(item.title))**"
            if let details = item.details { line += " · \(Self.escaped(details))" }
            let subtasks = item.subtasks.map { "  - [\($0.isDone ? "x" : " ")] \(Self.escaped($0.title))" }
            return ([line] + subtasks).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// The plain text with bold titles and quieter details, as RTF.
    var rtf: Data? {
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let text = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: items.allSatisfy(\.isTitleOnly) ? "\n" : "\n\n")) }
            text.append(NSAttributedString(string: item.title, attributes: [.font: bold]))
            if let details = item.details {
                text.append(NSAttributedString(string: "\n" + details, attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            for subtask in item.subtasks {
                text.append(NSAttributedString(string: "\n\(subtask.isDone ? "☑" : "☐") \(subtask.title)", attributes: [.font: body]))
            }
        }
        return try? text.data(from: NSRange(location: 0, length: text.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// What a drag out of the panel carries: the full text, Markdown and RTF.
    func dragItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(plain, forType: .string)
        item.setString(markdown, forType: Self.markdownType)
        if let rtf { item.setData(rtf, forType: .rtf) }
        return item
    }

    /// What ⌘C puts on the pasteboard: the titles as plain text (the add
    /// bar's round trip), the full text as Markdown and RTF.
    func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, Self.markdownType] + (rtf == nil ? [] : [.rtf]), owner: nil)
        pasteboard.setString(titles, forType: .string)
        pasteboard.setString(markdown, forType: Self.markdownType)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
    }

    /// A priority as words ("High priority").
    static func priorityName(_ priority: TaskPriority) -> String {
        switch priority {
        case .none: ""
        case .low: String(localized: "Low priority")
        case .medium: String(localized: "Medium priority")
        case .high: String(localized: "High priority")
        }
    }

    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\*_[]`".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
