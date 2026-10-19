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
                let title = inlineText(block, calendar: calendar, locale: locale, preserveWhitespace: false).trimmingCharacters(in: .whitespaces)
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
                      document.blocks[index].style == "quote", document.blocks[index].callout == icon,
                      !document.blocks[index].calloutStart {
                    box.append(document.blocks[index]); index += 1
                }
                // An HTML comment separates adjacent CommonMark quotes and
                // carries the explicit boundary without visible decoration.
                var text = (block.calloutStart ? "<!-- attic:callout-start -->\n\n" : "") + "> [!NOTE]"
                for (offset, paragraph) in box.enumerated() {
                    if offset > 0 { text += "\n>" }
                    var content = inlineText(paragraph, calendar: calendar, locale: locale, literalLeadingEmoji: offset == 0 && icon.isEmpty)
                        .replacingOccurrences(of: "\u{2028}", with: "\\\n> ")
                    if content.isEmpty, box.count > 1 { content = "<br>" }
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
            let depth = min(2, max(0, block.indent ?? 0))
            if !isList { numbered.removeAll(); listColumns.removeAll(); listWidths.removeAll() }
            let column = depth == 0 || listColumns[depth - 1] == nil ? 0 : (listColumns[depth - 1] ?? (depth - 1) * 2) + (listWidths[depth - 1] ?? 2)
            let nesting = String(repeating: " ", count: column)
            // CommonMark cannot express an orphan's semantic depth, or a
            // restart in the middle of the same ordered-list identity.
            var listHint = ""
            if isList {
                var hints: [String] = []
                if depth > 0 && (listColumns[depth - 1] == nil || listColumns[0] == nil) { hints.append("indent=\(depth)") }
                if let start = block.start, start > 999_999_999 || numbered[depth] != nil || (depth > 0 && listColumns[depth - 1] == nil) || (listColumns[0] == nil && !listColumns.isEmpty) { hints.append("start=\(start)") }
                if !hints.isEmpty { listHint = "<!-- attic:list " + hints.joined(separator: " ") + " -->" }
            }
            let looseChild = isList && block.style == "number" && (block.start ?? 1) > 1 && depth > (document.blocks[index - 2].indent ?? 0)
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
                    numbered[depth] = number
                    // CommonMark limits ordered markers to nine digits.
                    // The hidden hint carries an otherwise unrepresentable
                    // start; later items continue from it in Attic.
                    prefix = "\(number > 999_999_999 ? 1 : number). "
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
                listColumns[depth] = column; listWidths[depth] = block.kind == .checklist ? 2 : prefix.count
            }
            switch block.kind {
            case .text, .checklist:
                let continuation = isList ? String(repeating: " ", count: column + (block.kind == .checklist ? 2 : prefix.count)) : (block.style == "quote" ? nesting + "> " : "")
                var text = inlineText(block, calendar: calendar, locale: locale)
                    .replacingOccurrences(of: "\u{2028}", with: block.style == "heading" ? "<br>" : "\\\n" + continuation)
                // Bare empty items can become Setext underlines or close
                // their list before a nested child. A comment ends on this
                // line and keeps the item/children unambiguous (<br> opens an
                // HTML block that can consume a following child list).
                if isList, text.isEmpty { text = "<!-- attic:empty-item -->" }
                if !isList, text.isEmpty {
                    // Whitespace alone is only a separator in Markdown.
                    // A normal HTML break keeps an empty formatted paragraph.
                    lines.append((nesting + prefix + "<br>", false))
                } else if isList || !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append(((looseChild ? "\n" : "") + nesting + prefix + listHint + text, isList))
                }
            case .image:
                lines.append((attachmentLabel("image", filename: block.attachmentID.flatMap(filename) ?? String(localized: "image")), false))
            case .file: lines.append((attachmentLabel("file", filename: block.filename ?? "file"), false))
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

    private static func attachmentLabel(_ kind: String, filename: String) -> String {
        // A filename is one literal label even when it contains line breaks
        // or control characters. Show those scalars explicitly in the label.
        let visible = filename.unicodeScalars.map { scalar in
            scalar.value < 32 || scalar.value == 127 || scalar.value == 0x2028 || scalar.value == 0x2029
                ? "\\u{" + String(scalar.value, radix: 16) + "}" : String(scalar)
        }.joined()
        return escapeInlineText("[\(kind): \(visible)]")
    }

    /// A date as the note shows it, with the year: "Thu, 1 Oct 2026".
    static func dateText(_ day: NoteDay, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated).year()
        return day.date(in: calendar).formatted(style)
    }

    /// A table cell's text with its marks as Markdown and its dates as text.
    static func inlineMarkdown(_ block: NoteBlock, calendar: Calendar = .current, locale: Locale = .current) -> String {
        inlineText(block, calendar: calendar, locale: locale, escapeLiterals: true, tableCell: true)
    }

    /// Escape prose before adding mark delimiters, so literal Markdown and
    /// HTML cannot turn into formatting on re-import.
    static func escapeInlineText(_ text: String, preserveWhitespace: Bool = true, leadingWhitespace: Bool = true, trailingWhitespace: Bool = true) -> String {
        var result = ""
        let characters = Array(text)
        let leading = characters.prefix { $0.isWhitespace }.count
        let trailing = characters.reversed().prefix { $0.isWhitespace }.count
        for (index, character) in characters.enumerated() {
            if preserveWhitespace && (character == "\t" || (((leadingWhitespace && index < leading) || (trailingWhitespace && index >= characters.count - trailing)) && character.isWhitespace)) {
                result += character.unicodeScalars.map { "&#\($0.value);" }.joined()
                continue
            }
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
                                   escapeLiterals: Bool = true, includeMarks: Bool = true, preserveWhitespace: Bool = true, literalLeadingEmoji: Bool = false, tableCell: Bool = false) -> String {
        var result = ""
        let useHTML = includeMarks && escapeLiterals && (NoteMarkdownInline.needsHTML(block) ||
            (tableCell && block.marks.contains { $0.kind == .code && (block.text as NSString).substring(with: NSRange(location: $0.offset, length: $0.length)).contains("\\") }) ||
            (literalLeadingEmoji && block.text.first?.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.value > 127 && $0.properties.isEmoji) }) == true))
        let text = block.text as NSString
        var boundaries: Set<Int> = [0, text.length]
        var starts: [Int: [Int]] = [:]
        var ends: [Int: [Int]] = [:]
        for (index, mark) in block.marks.enumerated() {
            boundaries.insert(mark.offset)
            boundaries.insert(mark.offset + mark.length)
            if includeMarks {
                starts[mark.offset, default: []].append(index)
                ends[mark.offset + mark.length, default: []].append(index)
            }
        }
        for offset in 0..<text.length where text.character(at: offset) == NoteDocument.objectUnit {
            boundaries.insert(offset)
            boundaries.insert(offset + 1)
        }
        let points = boundaries.sorted()
        let objectOffsets = (0..<text.length).filter { text.character(at: $0) == NoteDocument.objectUnit }
        var objectIndex = 0
        var active: [Int: NoteMark] = [:]
        for pair in zip(points, points.dropFirst()) where pair.0 < pair.1 {
            for index in ends[pair.0] ?? [] { active[index] = nil }
            for index in starts[pair.0] ?? [] { active[index] = block.marks[index] }
            while objectIndex < objectOffsets.count, objectOffsets[objectIndex] < pair.0 { objectIndex += 1 }
            let range = NSRange(location: pair.0, length: pair.1 - pair.0)
            if objectIndex < objectOffsets.count, objectOffsets[objectIndex] == pair.0, range.length == 1 {
                if objectIndex < block.inlines.count {
                    switch block.inlines[objectIndex].kind {
                    case let .date(day): result += dateText(day, calendar: calendar, locale: locale)
                    case .opaque: result += String(localized: "[content that needs a newer Attic]")
                    }
                }
                continue
            }
            var value = text.substring(with: range)
            let marks = active.sorted {
                $0.value.kind.rawValue != $1.value.kind.rawValue
                    ? $0.value.kind.rawValue < $1.value.kind.rawValue : $0.key < $1.key
            }.map(\.value)
            if useHTML, !marks.isEmpty {
                result += NoteMarkdownInline.wrap(value, marks: marks, literalLeadingEmoji: literalLeadingEmoji && range.location == 0)
                continue
            }
            if marks.contains(where: { $0.kind == .code }) {
                let longest = value.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: longest + 1)
                let pad = value.hasPrefix("`") || value.hasSuffix("`") ||
                    (value.hasPrefix(" ") && value.hasSuffix(" ") && value.contains(where: { $0 != " " }))
                value = fence + (pad ? " " : "") + value + (pad ? " " : "") + fence
            } else if escapeLiterals { value = escapeInlineText(value, preserveWhitespace: preserveWhitespace, leadingWhitespace: range.location == 0, trailingWhitespace: NSMaxRange(range) == text.length) }
            if literalLeadingEmoji && range.location == 0 { value = NoteMarkdownInline.literalEmoji(value) }
            for mark in marks.reversed() {
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

/// A small, inert HTML inline vocabulary for spans Markdown cannot nest or
/// delimit unambiguously. No document/resource importer is involved.
enum NoteMarkdownInline {
    static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "&#10;").replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\t", with: "&#9;").replacingOccurrences(of: "\\", with: "&#92;")
            .replacingOccurrences(of: "|", with: "&#124;").replacingOccurrences(of: "\u{2028}", with: "&#8232;")
    }

    static func needsHTML(_ block: NoteBlock) -> Bool {
        let text = block.text as NSString
        var furthestEnd = -1
        for mark in block.marks.sorted(by: { $0.offset < $1.offset }) {
            // Detect crossing or adjoining spans with a sweep, rather than
            // comparing every pair (ordinary alternating marks must scale).
            if mark.offset <= furthestEnd { return true }
            furthestEnd = max(furthestEnd, mark.offset + mark.length)
            if mark.kind == .underline || mark.kind == .highlight { return true }
            let value = text.substring(with: NSRange(location: mark.offset, length: mark.length))
            if value.first?.isWhitespace == true || value.last?.isWhitespace == true { return true }
            if [.bold, .italic, .strikethrough].contains(mark.kind),
               (mark.offset > 0 || mark.offset + mark.length < text.length),
               [value.first, value.last].compactMap({ $0 }).contains(where: { !$0.isLetter && !$0.isNumber }) { return true }
            if mark.kind == .link, (mark.url ?? "").unicodeScalars.contains(where: { !$0.isASCII || CharacterSet.whitespacesAndNewlines.contains($0) || "\"<>\\".unicodeScalars.contains($0) }) { return true }
            if mark.kind == .code || mark.kind == .link, value.contains(where: { $0 == "\t" || $0 == "\u{2028}" || $0 == "\n" }) { return true }
        }
        return false
    }

    static func literalEmoji(_ text: String) -> String {
        guard let first = text.first, first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.value > 127 && $0.properties.isEmoji) }) else { return text }
        return first.unicodeScalars.map { "&#\($0.value);" }.joined() + text.dropFirst()
    }

    static func wrap(_ text: String, marks: [NoteMark], literalLeadingEmoji: Bool = false) -> String {
        var value = literalLeadingEmoji ? literalEmoji(html(text)) : html(text)
        for mark in marks.reversed() {
            switch mark.kind {
            case .bold: value = "<strong>" + value + "</strong>"
            case .italic: value = "<em>" + value + "</em>"
            case .underline: value = "<u>" + value + "</u>"
            case .strikethrough: value = "<s>" + value + "</s>"
            case .highlight: value = "<mark" + (mark.colour.map { " data-attic-colour=\"" + html($0) + "\"" } ?? "") + ">" + value + "</mark>"
            case .code: value = "<code>" + value + "</code>"
            case .link: value = "<a href=\"" + html(mark.url ?? "") + "\">" + value + "</a>"
            }
        }
        return value
    }

    /// Parse only our paired tags, with a bounded stack and no URL access.
    /// Escaped literal tags are decoded after recognition and remain text.
    static func parse(_ source: String) -> NoteTable.Cell? {
        let regex = try! NSRegularExpression(pattern: #"</?(?:strong|em|u|s|mark|code|a)(?:\s+[^<>]*)?>"#)
        let string = source as NSString
        var stack: [(tag: String, kind: NoteMark.Kind, start: Int, payload: String?)] = []
        var result = NoteTable.Cell(), cursor = 0
        for match in regex.matches(in: source, range: NSRange(location: 0, length: string.length)) {
            result.text += NoteTableText.decodeEntities(string.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let raw = string.substring(with: match.range)
            let tag = raw.dropFirst(raw.hasPrefix("</") ? 2 : 1).prefix { $0.isLetter }
            if raw.hasPrefix("</") {
                guard let open = stack.popLast(), open.tag == tag else { return nil }
                let length = result.text.utf16.count - open.start
                if length > 0 {
                    result.marks.append(NoteMark(open.kind, offset: open.start, length: length,
                        url: open.kind == .link ? open.payload : nil, colour: open.kind == .highlight ? open.payload : nil))
                }
            } else {
                guard stack.count < 32 else { return nil }
                let kind: NoteMark.Kind
                switch tag {
                case "strong": kind = .bold
                case "em": kind = .italic
                case "u": kind = .underline
                case "s": kind = .strikethrough
                case "mark": kind = .highlight
                case "code": kind = .code
                case "a": kind = .link
                default: return nil
                }
                let key = kind == .link ? "href" : "data-attic-colour"
                var payload: String?
                if let range = raw.range(of: key + "=\""), let end = raw[range.upperBound...].firstIndex(of: "\"") {
                    payload = NoteTableText.decodeEntities(String(raw[range.upperBound..<end]))
                }
                if kind == .link, payload == nil { return nil }
                if kind == .highlight, payload?.isEmpty == true { payload = nil }
                stack.append((String(tag), kind, result.text.utf16.count, payload))
            }
            cursor = NSMaxRange(match.range)
        }
        result.text += NoteTableText.decodeEntities(string.substring(from: cursor))
        guard stack.isEmpty else { return nil }
        result.marks = NoteTableText.canonicalMarks(result.marks)
        return result
    }
}
