import Foundation

/// Offline CommonMark/GFM import. Foundation owns syntax parsing; this adapter
/// maps its semantic intents to Attic's existing readable block vocabulary.
enum NoteMarkdownImport {
    static func shouldImport(_ text: String) -> Bool {
        if ["**", "`", "~~"].contains(where: text.contains) { return true }
        return text.range(of: #"(?m)^(?: {4,}\S|\t[ \t]*\S| {0,3}#{1,6} |\s*[-*+] |\s*[1-9][0-9]*\. |> ?| {0,3}(?:---+|\*\*\*+|___+)\s*$|\s*\|.*\|)|\[[^\]]+\]\([^\)]+\)"#, options: .regularExpression) != nil
    }

    private struct Paragraph {
        var intents: [PresentationIntent.IntentType]
        var block = NoteBlock.text("")
        var literalEmojiOffsets = Set<Int>()
        var startsWithChecklist = false
        var startsWithAlert = false
    }

    static func document(_ markdown: String) throws -> NoteDocument {
        // Foundation interprets undefined footnotes as links and consumes
        // definitions. R14 keeps both as literal text instead.
        let source = NSMutableString(string: markdown)
        let footnote = try NSRegularExpression(pattern: #"\[\^[^\]]+\]"#)
        let matches = footnote.matches(in: markdown, range: NSRange(location: 0, length: source.length))
        if !matches.isEmpty {
            // Ask the same parser for code source ranges before applying the
            // prose workaround. Code's real backslashes must stay verbatim.
            let original = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full, appliesSourcePositionAttributes: true))
            let codeRanges: [NSRange] = original.runs.compactMap { run in
                let isCode = run.inlinePresentationIntent?.contains(.code) == true ||
                    run.presentationIntent?.components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) == true
                guard isCode, let position = run.markdownSourcePosition, let range = Range(position, in: markdown) else { return nil }
                return NSRange(range, in: markdown)
            }
            let units = Array(markdown.utf16)
            func escaped(at offset: Int) -> Bool {
                var start = offset
                while start > 0, units[start - 1] == 92 { start -= 1 }
                return (offset - start) % 2 == 1
            }
            for match in matches.reversed() {
                guard !escaped(at: match.range.location), !escaped(at: NSMaxRange(match.range) - 1),
                      !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                let literal = source.substring(with: match.range)
                source.replaceCharacters(in: match.range, with: literal.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]"))
            }
        }
        // Foundation emits no run for a truly empty list item. Give those
        // items a temporary parse-only token, then remove it from their text.
        // A unique token also restores literal lines inside fenced code.
        let emptyItemToken = "atticEmptyItem" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let emptyItem = try NSRegularExpression(pattern: #"(?m)^[ \t]*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+$"#)
        for match in emptyItem.matches(in: source as String, range: NSRange(location: 0, length: source.length)).reversed() {
            source.insert(emptyItemToken, at: NSMaxRange(match.range))
        }
        let sourceText = source as String
        let parsed = try AttributedString(markdown: sourceText, options: .init(interpretedSyntax: .full, appliesSourcePositionAttributes: true))
        var paragraphs: [Paragraph] = []
        var lastIdentity: Int?
        for run in parsed.runs {
            let intents = run.presentationIntent?.components ?? []
            let identity = intents.first?.identity ?? -1
            if lastIdentity != identity {
                paragraphs.append(Paragraph(intents: intents))
                lastIdentity = identity
            }
            if paragraphs.isEmpty { paragraphs.append(Paragraph(intents: intents)) }
            var text = String(parsed[run.range].characters)
            text = text.replacingOccurrences(of: emptyItemToken, with: "")
            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.softBreak) { text = " " }
            if inline.contains(.lineBreak) { text = "\u{2028}" }
            // The parser's image run already contains the alt text. No fetch.
            text = text.replacingOccurrences(of: String(NoteDocument.objectCharacter), with: "")
            let offset = (paragraphs[paragraphs.count - 1].block.text as NSString).length
            let length = (text as NSString).length
            if let position = run.markdownSourcePosition, let range = Range(position, in: sourceText) {
                let raw = String(sourceText[range])
                if raw.hasPrefix("&#") { paragraphs[paragraphs.count - 1].literalEmojiOffsets.insert(offset) }
                if offset == 0, !inline.contains(.code) {
                    let lineStart = sourceText[..<range.lowerBound].lastIndex(of: "\n").map { sourceText.index(after: $0) } ?? sourceText.startIndex
                    let before = String(sourceText[lineStart..<range.lowerBound])
                    // Only container prefixes may precede a structural marker.
                    // Inline delimiters, escapes and entities remain literal.
                    let atBlockStart = before.range(of: #"^(?:[ \t]*(?:>[ \t]?|(?:[-+*]|[0-9]{1,9}[.)])[ \t]+))*[ \t]*$"#, options: .regularExpression) != nil
                    if atBlockStart {
                        paragraphs[paragraphs.count - 1].startsWithChecklist = raw.range(of: #"^\[( |x|X)\](?: |$)"#, options: .regularExpression) != nil
                        paragraphs[paragraphs.count - 1].startsWithAlert = raw.range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?: |$|\n)"#, options: .regularExpression) != nil
                    }
                }
            }
            var marks: [NoteMark] = []
            for (intent, kind) in [(InlinePresentationIntent.stronglyEmphasized, NoteMark.Kind.bold), (.emphasized, .italic), (.strikethrough, .strikethrough), (.code, .code)] where inline.contains(intent) && length > 0 {
                marks.append(NoteMark(kind, offset: offset, length: length))
            }
            if let url = run.link, length > 0 { marks.append(NoteMark(.link, offset: offset, length: length, url: url.absoluteString)) }
            paragraphs[paragraphs.count - 1].block.text += text
            paragraphs[paragraphs.count - 1].block.marks += marks
        }

        var blocks: [NoteBlock] = []
        var seenLists = Set<Int>()
        var alerts: [Int: String] = [:]
        var seenQuotes = Set<Int>()
        var tableIndices: [Int: Int] = [:]
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            let intents = paragraph.intents
            var block = paragraph.block
            if let tableIntent = intents.first(where: { if case .table = $0.kind { true } else { false } }),
               case let .table(columns) = tableIntent.kind,
               let cellIntent = intents.first(where: { if case .tableCell = $0.kind { true } else { false } }),
               case let .tableCell(column) = cellIntent.kind {
                var row = 0
                for intent in intents { if case let .tableRow(index) = intent.kind { row = index } }
                guard columns.count <= NoteTable.maxColumns, row < NoteTable.maxRows else {
                    return NoteDocument(blocks: markdown.components(separatedBy: "\n").map { .text($0) })
                }
                let index: Int
                if let existing = tableIndices[tableIntent.identity] { index = existing }
                else {
                    index = blocks.count; tableIndices[tableIntent.identity] = index
                    let alignments: [NoteTable.Column] = columns.map { value in
                        NoteTable.Column(align: value.alignment == .center ? .center : (value.alignment == .right ? .right : .left))
                    }
                    blocks.append(.table(NoteTable(headerRow: true, columns: alignments, rows: [], extras: [:])))
                }
                var table = blocks[index].table!
                while table.rows.count <= row { table.rows.append(.init(cells: Array(repeating: .empty, count: columns.count))) }
                if table.columns.indices.contains(column) { table.rows[row].cells[column] = .init(block.text, marks: block.marks) }
                blocks[index].table = table
                continue
            }
            let quote = intents.last(where: { $0.kind == .blockQuote })
            let list = intents.first(where: { $0.kind == .orderedList || $0.kind == .unorderedList })
            let item = intents.first(where: { if case .listItem = $0.kind { true } else { false } })
            var code = false
            for intent in intents {
                switch intent.kind {
                case let .header(level): block.style = "heading"; block.level = min(6, max(1, level))
                case let .codeBlock(language): block.style = "mono"; block.language = NoteCodeLanguage.normalize(language); code = true
                case .thematicBreak: block = .divider()
                default: break
                }
            }
            if let list, let item, case let .listItem(ordinal) = item.kind {
                let depth = intents.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count - 1
                block.style = list.kind == .orderedList ? "number" : "bullet"
                block.indent = min(2, max(0, depth)) == 0 ? nil : min(2, depth)
                if seenLists.insert(list.identity).inserted, list.kind == .orderedList, ordinal != 1 { block.start = ordinal }
                if paragraph.startsWithChecklist, let marker = block.text.range(of: #"^\[( |x|X)\](?: |$)"#, options: .regularExpression) {
                    block.kind = .checklist; block.id = UUID(); block.checked = !block.text.hasPrefix("[ ]")
                    removePrefix((String(block.text[marker]) as NSString).length, from: &block); block.style = nil; block.start = nil
                }
            }
            if let quote {
                if let item, case let .listItem(ordinal) = item.kind {
                    let prefix = list?.kind == .orderedList ? "\(ordinal). " : "• "
                    if block.kind == .checklist { prepend(block.checked ? "[x] " : "[ ] ", to: &block) }
                    prepend(prefix, to: &block)
                }
                if seenQuotes.insert(quote.identity).inserted, paragraph.startsWithAlert,
                   let alert = block.text.range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?: |\u2028|\n)?"#, options: .regularExpression) {
                    let name = String(block.text[alert]).components(separatedBy: "]")[0].dropFirst(2)
                    let defaults = ["NOTE": "", "TIP": "💡", "IMPORTANT": "❗", "WARNING": "⚠️", "CAUTION": "🛑"]
                    let alertLength = (String(block.text[alert]) as NSString).length
                    removePrefix(alertLength, from: &block)
                    var icon = defaults[String(name)] ?? ""
                    if !paragraph.literalEmojiOffsets.contains(alertLength),
                       let first = block.text.first, first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.value > 127 && $0.properties.isEmoji) }) {
                        icon = String(first); removePrefix((icon as NSString).length, from: &block)
                        if block.text.hasPrefix(" ") { removePrefix(1, from: &block) }
                    }
                    alerts[quote.identity] = icon
                }
                block.style = "quote"; block.level = nil; block.indent = nil; block.language = nil; block.start = nil
                block.kind = .text; block.id = nil; block.checked = false
                block.callout = alerts[quote.identity]
                if block.text.isEmpty, block.callout != nil,
                   paragraphs.dropFirst(paragraphIndex + 1).contains(where: { $0.intents.contains { $0.kind == .blockQuote && $0.identity == quote.identity } }) { continue }
            }
            if code || block.text.contains("\n") {
                // One mono/quote paragraph per physical code line. The final
                // fence separator isn't an extra empty line in the code.
                var text = block.text
                if text.hasSuffix("\n") { text.removeLast() }
                for line in text.components(separatedBy: "\n") {
                    var part = block; part.text = line; part.marks = []; blocks.append(part)
                }
            } else { blocks.append(block) }
        }
        // Keep over-limit Markdown tables readable as text rather than
        // creating an invalid document or silently dropping any cells.
        blocks = blocks.map { block in
            guard let table = block.table, !table.isWithinLimits else { return block }
            return .text(NoteTableText.tsv(table))
        }
        return NoteDocument(blocks: blocks.isEmpty ? [.text(markdown)] : blocks)
    }

    static func calloutParagraphs(_ blocks: [NoteBlock], icon: String) -> [NoteBlock] {
        var ordinal = 0
        return blocks.flatMap { block -> [NoteBlock] in
            var copy = block
            switch block.kind {
            case .text:
                if block.style == "bullet" { prepend("• ", to: &copy) }
                if block.style == "number" { ordinal = block.start ?? ordinal + 1; prepend("\(ordinal). ", to: &copy) }
                else if block.style != "bullet" { ordinal = 0 }
            case .checklist: prepend(block.checked ? "• [x] " : "• [ ] ", to: &copy)
            default: copy = .text(NoteTextExport.plainLine(block))
            }
            copy.kind = .text; copy.id = nil; copy.checked = false; copy.style = "quote"; copy.level = nil; copy.indent = nil
            copy.language = nil; copy.start = nil; copy.callout = icon
            if copy.text.contains("\n") {
                return copy.text.components(separatedBy: "\n").map { line in
                    var paragraph = copy; paragraph.text = line; paragraph.marks = []; return paragraph
                }
            }
            return [copy]
        }
    }

    private static func prepend(_ text: String, to block: inout NoteBlock) {
        let length = (text as NSString).length
        block.text = text + block.text
        for index in block.marks.indices { block.marks[index].offset += length }
    }
    private static func removePrefix(_ length: Int, from block: inout NoteBlock) {
        block.text = (block.text as NSString).substring(from: min(length, (block.text as NSString).length))
        block.marks = block.marks.compactMap { mark in
            var copy = mark
            let end = mark.offset + mark.length
            copy.offset = max(0, mark.offset - length); copy.length = end - length - copy.offset
            return copy.length > 0 ? copy : nil
        }
    }
}

/// Stable language IDs; unrecognized info strings remain readable hints.
enum NoteCodeLanguage {
    static func normalize(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let aliases = ["js": "javascript", "ts": "typescript", "sh": "shell", "bash": "shell", "zsh": "shell", "yml": "yaml", "plaintext": "plain", "text": "plain"]
        let lower = value.lowercased()
        if let alias = aliases[lower] { return alias == "plain" ? nil : alias }
        if lower == "plain" { return nil }
        let supported = ["javascript", "typescript", "json", "swift", "python", "shell", "html", "css", "sql", "yaml", "diff", "mermaid"]
        return supported.contains(lower) ? lower : value
    }
}
