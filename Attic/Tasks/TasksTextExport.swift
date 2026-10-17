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
        /// The task's files (O17-15): a drag out carries them beside the
        /// text, as file promises; the text itself never names them.
        var files: [TaskImageReference] = []

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
        let separator = items.allSatisfy(\.isTitleOnly) ? "\n" : "\n\n"
        for (index, item) in items.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: separator)) }
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

    /// A native drag offers the text as a promised file as well as inline
    /// text. Finder can receive every item as a file; text editors can keep
    /// using the plain text, Markdown or RTF on this same item.
    func dragWriter() -> NSPasteboardWriting { TasksTextFilePromise(export: self) }

    /// What ⌘C puts on the pasteboard: the titles as plain text (the add
    /// bar's round trip), the full text as Markdown and RTF.
    func write(to pasteboard: NSPasteboard) {
        let rtf = self.rtf
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

/// The leading task item must have a file representation too: a bare text
/// item beside attachment promises does not promise Finder the task text.
/// Snapshot the representations before the drag; fulfilling the promise
/// neither consults the task store nor exposes any private file URL.
private final class TasksTextFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let plain: String
    private let markdown: String
    private let richText: Data?
    private let filename: String
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Attic task text promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(export: TasksTextExport) {
        plain = export.plain
        markdown = export.markdown
        richText = export.rtf
        let title = export.items.count == 1 ? export.items[0].title : String(localized: "Tasks")
        let suffix = ".txt"
        var name = AttachmentFileStore.sanitizedFilename(title)
        // Task titles can exceed a filesystem filename. Reserve the suffix
        // within a 255-byte name, without cutting a Unicode character.
        while name.utf8.count + suffix.utf8.count > 255 { name.removeLast() }
        if name.isEmpty { name = "Task" }
        filename = name + suffix
        super.init()
        fileType = UTType.utf8PlainText.identifier
        delegate = self
    }

    private var textTypes: [NSPasteboard.PasteboardType] {
        [.string, TasksTextExport.markdownType] + (richText == nil ? [] : [.rtf])
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + textTypes
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        textTypes.contains(type) ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .string: plain
        case TasksTextExport.markdownType: markdown
        case .rtf: richText
        default: super.pasteboardPropertyList(forType: type)
        }
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType type: String) -> String { filename }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { Self.queue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            try Data(plain.utf8).write(to: url, options: .withoutOverwriting)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
