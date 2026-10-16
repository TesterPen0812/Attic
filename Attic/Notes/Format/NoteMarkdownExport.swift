import Foundation

/// Copy as Markdown (UX plan § 3.21): text serialisation, never file
/// transfer. The title is a level-one heading; paragraphs are separated by a
/// blank line and list lines by a single break; checklists read `- [ ]` and
/// `- [x]`; dates read as text ("Thu, 1 Oct 2026"); images as a readable
/// label (`[image: pricing-v2.png]`). Anything this build can't read stays
/// as a literal placeholder rather than disappearing. Literal prose is escaped
/// before semantic marks are added, so importing cannot reinterpret it.
enum NoteMarkdownExport {
    static func markdown(_ document: NoteDocument, calendar: Calendar = .current, locale: Locale = .current,
                         filename: (UUID) -> String? = { _ in nil }) -> String {
        var lines: [(text: String, isListItem: Bool)] = []
        var numbered: [Int: Int] = [:]
        var listColumns: [Int: Int] = [:]
        var listWidths: [Int: Int] = [:]
        var index = 0
        while index < document.blocks.count {
            let block = document.blocks[index]
            index += 1
            if index == 1, block.kind == .text {
                let title = inlineText(block, calendar: calendar, locale: locale).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { lines.append(("# " + title, false)) }
                continue
            }
            if block.kind == .text, block.style == "mono" {
                numbered.removeAll(); listColumns.removeAll(); listWidths.removeAll()
                var code = [inlineText(block, calendar: calendar, locale: locale, escapeLiterals: false, includeMarks: false)]
                while index < document.blocks.count, document.blocks[index].kind == .text, document.blocks[index].style == "mono", document.blocks[index].language == block.language {
                    code.append(inlineText(document.blocks[index], calendar: calendar, locale: locale, escapeLiterals: false, includeMarks: false)); index += 1
                }
                let source = code.joined(separator: "\n")
                // A fence must be longer than any backtick run in the source.
                var longest = 0, current = 0
                for character in source {
                    if character == "`" { current += 1; longest = max(longest, current) } else { current = 0 }
                }
                let fence = String(repeating: "`", count: max(3, longest + 1))
                let language = block.language ?? ""
                // CommonMark forbids backticks in a backtick fence's info.
                let actualFence = language.contains("`") ? String(repeating: "~", count: max(3, source.split(whereSeparator: { $0 != "~" }).map(\.count).max().map { $0 + 1 } ?? 3)) : fence
                lines.append((actualFence + language + "\n" + source + "\n" + actualFence, false))
                continue
            }
            if block.kind == .text, block.style == "quote", let icon = block.callout {
                numbered.removeAll(); listColumns.removeAll(); listWidths.removeAll()
                var box = [block]
                while index < document.blocks.count, document.blocks[index].kind == .text,
                      document.blocks[index].style == "quote", document.blocks[index].callout == icon {
                    box.append(document.blocks[index]); index += 1
                }
                var text = "> [!NOTE]"
                for (offset, paragraph) in box.enumerated() {
                    if offset > 0 { text += "\n>" }
                    var content = inlineText(paragraph, calendar: calendar, locale: locale)
                        .replacingOccurrences(of: "\u{2028}", with: "\\\n> ")
                    // An entity denotes text, while a raw leading emoji is
                    // the external alert syntax for an icon.
                    if offset == 0, icon.isEmpty, let first = content.first,
                       first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.value > 127 && $0.properties.isEmoji) }) {
                        content.replaceSubrange(content.startIndex..<content.index(after: content.startIndex),
                                                with: first.unicodeScalars.map { "&#\($0.value);" }.joined())
                    }
                    text += "\n> " + (offset == 0 && !icon.isEmpty ? icon + " " : "") + content
                }
                lines.append((text, false)); continue
            }
            let isList = block.kind == .checklist || block.style == "bullet" || block.style == "number"
            let depth = block.indent ?? 0
            if !isList { numbered.removeAll(); listColumns.removeAll(); listWidths.removeAll() }
            let column = depth == 0 ? 0 : (listColumns[depth - 1] ?? (depth - 1) * 2) + (listWidths[depth - 1] ?? 2)
            let nesting = String(repeating: " ", count: column)
            var prefix = ""
            switch block.kind {
            case .text:
                switch block.style {
                case "heading": prefix = String(repeating: "#", count: min(6, max(1, block.level ?? 2))) + " "
                case "bullet": prefix = "- "
                case "number":
                    numbered = numbered.filter { $0.key <= depth }
                    let old = numbered[depth] ?? 0
                    let number = block.start ?? (old < Int.max ? old + 1 : old)
                    numbered[depth] = number; prefix = "\(number). "
                case "quote": prefix = "> "
                default: break
                }
                if block.style == "bullet" { numbered = numbered.filter { $0.key < depth } }
            case .checklist:
                numbered = numbered.filter { $0.key < depth }
                prefix = block.checked ? "- [x] " : "- [ ] "
            default: break
            }
            if isList {
                listColumns = listColumns.filter { $0.key <= depth }; listWidths = listWidths.filter { $0.key <= depth }
                listColumns[depth] = column; listWidths[depth] = prefix.count
            }
            switch block.kind {
            case .text, .checklist:
                let continuation = isList ? String(repeating: " ", count: column + prefix.count) : (block.style == "quote" ? nesting + "> " : "")
                let text = inlineText(block, calendar: calendar, locale: locale)
                    .replacingOccurrences(of: "\u{2028}", with: "\\\n" + continuation)
                if isList || !text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append((nesting + prefix + text, isList)) }
            case .image:
                lines.append(("[image: \(block.attachmentID.flatMap(filename) ?? String(localized: "image"))]", false))
            case .file: lines.append(("[file: \(block.filename ?? "file")]", false))
            case .divider: lines.append(("---", false))
            case .table:
                if let table = block.table { lines.append((NoteTableText.markdown(table) { inlineMarkdown($0.block, calendar: calendar, locale: locale) }, false)) }
            case .opaque: lines.append((String(localized: "[content that needs a newer Attic]"), false))
            }
        }
        var result = ""
        for (index, line) in lines.enumerated() {
            if index > 0 { result += line.isListItem && lines[index - 1].isListItem ? "\n" : "\n\n" }
            result += line.text
        }
        return result
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
    /// HTML cannot turn into formatting on re-import.
    static func escapeInlineText(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case ":": result += "&#58;" // Prevent GFM autolinks in literal prose.
            case "\\", "*", "_", "~", "`", "[", "]", "=", "#", "-", "+", "!": result += "\\" + String(character)
            default: result.append(character)
            }
        }
        // A period is syntax only after a block-leading ordinal. Escaping
        // periods inside a literal URL confuses Foundation's URL scanner.
        return result.replacingOccurrences(of: #"^([0-9]{1,9})([.)]) "#, with: #"$1\\$2 "#, options: .regularExpression)
    }

    private static func inlineText(_ block: NoteBlock, calendar: Calendar, locale: Locale,
                                   escapeLiterals: Bool = true, includeMarks: Bool = true) -> String {
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
            let marks = includeMarks ? block.marks.filter { $0.offset <= pair.0 && $0.offset + $0.length >= pair.1 } : []
            if marks.contains(where: { $0.kind == .code }) {
                let longest = value.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: longest + 1)
                let pad = value.hasPrefix("`") || value.hasSuffix("`") ||
                    (value.hasPrefix(" ") && value.hasSuffix(" ") && value.contains(where: { $0 != " " }))
                value = fence + (pad ? " " : "") + value + (pad ? " " : "") + fence
            } else if escapeLiterals { value = escapeInlineText(value) }
            for mark in marks.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }).reversed() {
                switch mark.kind {
                case .bold: value = "**" + value + "**"
                case .italic: value = "*" + value + "*"
                case .underline: value = "<u>" + value + "</u>"
                case .strikethrough: value = "~~" + value + "~~"
                case .code: break // Already wrapped around literal code above.
                case .highlight: value = "==" + value + "=="
                case .link:
                    var destination = mark.url ?? ""
                    if escapeLiterals {
                        destination = destination.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "&", with: "&amp;")
                            .replacingOccurrences(of: "<", with: "&lt;")
                            .replacingOccurrences(of: ">", with: "&gt;")
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
