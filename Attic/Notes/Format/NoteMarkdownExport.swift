import Foundation

/// Copy as Markdown (UX plan § 3.21): text serialisation, never file
/// transfer. The title is a level-one heading; paragraphs are separated by a
/// blank line and list lines by a single break; checklists read `- [ ]` and
/// `- [x]`; dates read as text ("Thu, 1 Oct 2026"); images as a readable
/// label (`[image: pricing-v2.png]`). Anything this build can't read stays
/// as a literal placeholder rather than disappearing. Outside table cells,
/// Markdown characters the person typed are kept as typed.
enum NoteMarkdownExport {
    static func markdown(_ document: NoteDocument, calendar: Calendar = .current, locale: Locale = .current,
                         filename: (UUID) -> String? = { _ in nil }) -> String {
        var lines: [(text: String, isListItem: Bool)] = []
        var numbered: [Int: Int] = [:]
        for (index, block) in document.blocks.enumerated() {
            if index == 0, block.kind == .text {
                let title = inlineText(block, calendar: calendar, locale: locale).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { lines.append(("# " + title, false)) }
                continue
            }
            switch block.kind {
            case .text:
                let text = inlineText(block, calendar: calendar, locale: locale)
                if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let nesting = String(repeating: "  ", count: block.indent ?? 0)
                if block.style == "number" {
                    let depth = block.indent ?? 0
                    numbered[depth, default: 0] += 1
                    numbered = numbered.filter { $0.key <= depth }
                } else { numbered.removeAll() }
                let prefix: String = switch block.style {
                case "heading": String(repeating: "#", count: max(1, block.level ?? 2)) + " "
                case "bullet": "- "
                case "number": "\(numbered[block.indent ?? 0] ?? 1). "
                case "quote": "> "
                case "mono": "    "
                default: ""
                }
                lines.append((nesting + prefix + text, block.style == "bullet" || block.style == "number"))
            case .checklist:
                numbered.removeAll()
                lines.append((String(repeating: "  ", count: block.indent ?? 0) +
                              (block.checked ? "- [x] " : "- [ ] ") +
                              inlineText(block, calendar: calendar, locale: locale), true))
            case .image:
                numbered.removeAll()
                let name = block.attachmentID.flatMap(filename) ?? String(localized: "image")
                lines.append(("[image: \(name)]", false))
            case .file:
                numbered.removeAll()
                lines.append(("[file: \(block.filename ?? "file")]", false))
            case .divider:
                numbered.removeAll()
                lines.append(("---", false))
            case .table:
                numbered.removeAll()
                if let table = block.table {
                    lines.append((NoteTableText.markdown(table) { inlineMarkdown($0.block, calendar: calendar, locale: locale) }, false))
                }
            case .opaque:
                numbered.removeAll()
                lines.append((String(localized: "[content that needs a newer Attic]"), false))
            }
        }
        var result = ""
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result += line.isListItem && lines[index - 1].isListItem ? "\n" : "\n\n"
            }
            result += line.text
        }
        return result
    }

    /// A note still in the old format: its title and body as they are.
    static func markdown(title: String, body: String) -> String {
        let heading = title.trimmingCharacters(in: .whitespaces)
        let text = body.trimmingCharacters(in: .newlines)
        switch (heading.isEmpty, text.isEmpty) {
        case (true, _): return text
        case (false, true): return "# " + heading
        case (false, false): return "# " + heading + "\n\n" + text
        }
    }

    /// A date as the note shows it, with the year: "Thu, 1 Oct 2026".
    static func dateText(_ day: NoteDay, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated).year()
        return day.date(in: calendar).formatted(style)
    }

    /// A table cell's text with its marks as Markdown and its dates as text.
    static func inlineMarkdown(_ block: NoteBlock, calendar: Calendar = .current, locale: Locale = .current) -> String {
        inlineText(block, calendar: calendar, locale: locale, escapeLiterals: true)
    }

    /// Escape prose before adding mark delimiters, so literal Markdown and
    /// HTML cannot turn into formatting on table re-import.
    static func escapeInlineText(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\\", "*", "_", "~", "`", "[", "]", "=": result += "\\" + String(character)
            default: result.append(character)
            }
        }
        return result
    }

    private static func inlineText(_ block: NoteBlock, calendar: Calendar, locale: Locale,
                                   escapeLiterals: Bool = false) -> String {
        var result = ""
        let text = block.text as NSString
        var boundaries: Set<Int> = [0, text.length]
        for mark in block.marks {
            boundaries.insert(mark.offset)
            boundaries.insert(mark.offset + mark.length)
        }
        for offset in 0..<text.length where text.character(at: offset) == NoteDocument.objectUnit {
            boundaries.insert(offset)
            boundaries.insert(offset + 1)
        }
        let points = boundaries.sorted()
        let objectOffsets = (0..<text.length).filter { text.character(at: $0) == NoteDocument.objectUnit }
        for pair in zip(points, points.dropFirst()) where pair.0 < pair.1 {
            let range = NSRange(location: pair.0, length: pair.1 - pair.0)
            if let objectIndex = objectOffsets.firstIndex(of: pair.0), range.length == 1 {
                if objectIndex < block.inlines.count {
                    switch block.inlines[objectIndex].kind {
                    case let .date(day): result += dateText(day, calendar: calendar, locale: locale)
                    case .opaque: result += String(localized: "[content that needs a newer Attic]")
                    }
                }
                continue
            }
            var value = text.substring(with: range)
            if escapeLiterals { value = escapeInlineText(value) }
            let marks = block.marks.filter { $0.offset <= pair.0 && $0.offset + $0.length >= pair.1 }
            for mark in marks.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }).reversed() {
                switch mark.kind {
                case .bold: value = "**" + value + "**"
                case .italic: value = "*" + value + "*"
                case .underline: value = "<u>" + value + "</u>"
                case .strikethrough: value = "~~" + value + "~~"
                case .code: value = "`" + value + "`"
                case .highlight: value = "==" + value + "=="
                case .link:
                    var destination = mark.url ?? ""
                    if escapeLiterals {
                        destination = escapeInlineText(destination)
                            .replacingOccurrences(of: "(", with: "\\(")
                            .replacingOccurrences(of: ")", with: "\\)")
                    }
                    value = "[" + value + "](" + destination + ")"
                }
            }
            result += value
        }
        return result
    }
}
