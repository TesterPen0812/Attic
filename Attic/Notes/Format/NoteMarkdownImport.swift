import Foundation

/// Offline CommonMark/GFM import. Foundation owns syntax parsing; this adapter
/// maps its semantic intents to Attic's existing readable block vocabulary.
enum NoteMarkdownImport {
    static func shouldImport(_ text: String) -> Bool {
        if ["**", "`", "~~", "<u>", "<mark", "<strong>", "<em>", "==", "<br>", "&#"].contains(where: text.contains) { return true }
        return text.range(of: #"(?m)^(?: {4,}\S|\t[ \t]*\S| {0,3}#{1,6} |\s*[-*+] |\s*[1-9][0-9]*\. |> ?| {0,3}(?:---+|\*\*\*+|___+)\s*$|\s*\|.*\|)|\[[^\]]+\]\([^\)]+\)"#, options: .regularExpression) != nil
    }

    private struct Paragraph {
        var intents: [PresentationIntent.IntentType]
        var block = NoteBlock.text("")
        var startsWithChecklist = false
        var startsWithAlert = false
        var calloutStart = false
        var emptyParagraph = false
        var calloutBoundary = false
    }

    static func document(_ markdown: String) throws -> NoteDocument {
        // Foundation interprets undefined footnotes as links and consumes
        // definitions. R14 keeps both as literal text instead.
        let originalMarkdown = markdown
        let prepared = try prepareExtensions(markdown)
        let markdown = prepared.source
        let source = NSMutableString(string: markdown)
        // Parse-only tokens let Foundation retain empty paragraphs. Only an
        // entire exported <br> line is structural; code stays literal.
        let emptyParagraphToken = "atticEmptyParagraph" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        if markdown.contains("<br>") {
            let codeRanges = protectedCode(in: markdown).all
            let empty = try NSRegularExpression(pattern: #"(?m)^(?:#{1,6} |>[ \t]?(?:[^\n<>]* )?)?(<br>)$"#)
            for match in empty.matches(in: markdown, range: NSRange(location: 0, length: source.length)).reversed()
                where !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                source.replaceCharacters(in: match.range(at: 1), with: emptyParagraphToken)
            }
        }
        let footnote = try NSRegularExpression(pattern: #"\[\^[^\]]+\]"#)
        let footnoteSource = source as String
        let matches = footnote.matches(in: footnoteSource, range: NSRange(location: 0, length: source.length))
        if !matches.isEmpty {
            // Ask the same parser for code source ranges before applying the
            // prose workaround. Code's real backslashes must stay verbatim.
            let codeRanges = protectedCode(in: footnoteSource).all
            let units = Array(footnoteSource.utf16)
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
            if text.contains(emptyParagraphToken) { paragraphs[paragraphs.count - 1].emptyParagraph = true }
            text = text.replacingOccurrences(of: emptyParagraphToken, with: "")
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
                if offset == 0, !inline.contains(.code) {
                    let lineStart = sourceText[..<range.lowerBound].lastIndex(of: "\n").map { sourceText.index(after: $0) } ?? sourceText.startIndex
                    let before = String(sourceText[lineStart..<range.lowerBound])
                    // Only container prefixes may precede a structural marker.
                    // Inline delimiters, escapes and entities remain literal.
                    let atBlockStart = before.range(of: #"^(?:[ \t]*(?:>[ \t]?|(?:[-+*]|[0-9]{1,9}[.)])[ \t]+))*[ \t]*$"#, options: .regularExpression) != nil
                    if atBlockStart {
                        paragraphs[paragraphs.count - 1].calloutBoundary = raw == "<!-- attic:callout-start -->" && before.isEmpty
                        paragraphs[paragraphs.count - 1].startsWithChecklist = raw.range(of: #"^\[( |x|X)\](?: |$)"#, options: .regularExpression) != nil
                        paragraphs[paragraphs.count - 1].startsWithAlert = raw.range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?: |$|\n)"#, options: .regularExpression) != nil
                        paragraphs[paragraphs.count - 1].calloutStart = sourceText[..<lineStart].hasSuffix("<!-- attic:callout-start -->\n\n")
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
        var explicitAlerts = Set<Int>()
        var startedAlerts = Set<Int>()
        var tableIndices: [Int: Int] = [:]
        var nextCalloutStart = false
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            let intents = paragraph.intents
            var block = paragraph.block
            if let replacement = prepared.tables[block.text] {
                blocks.append(.table(replacement)); continue
            }
            if prepared.boundaries.contains(block.text) { nextCalloutStart = true; continue }
            let isTask = prepared.tasks.contains { block.text.hasPrefix($0) }
            let isAlert = prepared.alerts.contains { block.text.hasPrefix($0) }
            var literalEmojiOffsets = Set<Int>()
            restoreInline(&block, spans: prepared.spans, literals: prepared.literals, offsets: &literalEmojiOffsets)
            let listHint = prepared.lists.first { entry in
                block.text.hasPrefix(entry.key) || ["[x] ", "[X] ", "[ ] "].contains { prefix in block.text.hasPrefix(prefix + entry.key) }
            }
            if let listHint, block.text.hasPrefix(listHint.key) { removePrefix(listHint.key.utf16.count, from: &block) }
            if let tableIntent = intents.first(where: { if case .table = $0.kind { true } else { false } }),
               case let .table(columns) = tableIntent.kind,
               let cellIntent = intents.first(where: { if case .tableCell = $0.kind { true } else { false } }),
               case let .tableCell(column) = cellIntent.kind {
                var row = 0
                for intent in intents { if case let .tableRow(index) = intent.kind { row = index } }
                guard columns.count <= NoteTable.maxColumns, row < NoteTable.maxRows else {
                    return NoteDocument(blocks: originalMarkdown.components(separatedBy: "\n").map { .text($0) })
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
            // Foundation exposes raw HTML as text. Recognize only the exact
            // standalone comment, never its escaped prose or code spelling.
            if !code, quote == nil, list == nil, paragraph.calloutBoundary,
               block.text.trimmingCharacters(in: .newlines) == "<!-- attic:callout-start -->" { continue }
            if let list, let item, case let .listItem(ordinal) = item.kind {
                let depth = intents.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count - 1
                block.style = list.kind == .orderedList ? "number" : "bullet"
                block.indent = min(2, max(0, depth)) == 0 ? nil : min(2, depth)
                if seenLists.insert(list.identity).inserted, list.kind == .orderedList, ordinal != 1 { block.start = ordinal }
                if paragraph.startsWithChecklist || isTask, let marker = block.text.range(of: #"^\[( |x|X)\](?: |$)"#, options: .regularExpression) {
                    block.kind = .checklist; block.id = UUID(); block.checked = !block.text.hasPrefix("[ ]")
                    removePrefix((String(block.text[marker]) as NSString).length, from: &block); block.style = nil; block.start = nil
                }
            }
            if let entry = listHint, block.text.hasPrefix(entry.key), list != nil { removePrefix(entry.key.utf16.count, from: &block) }
            if let hint = listHint?.value, list != nil {
                if let indent = hint.indent { block.indent = indent }
                if let start = hint.start { block.start = start }
            }
            if let quote {
                if let item, case let .listItem(ordinal) = item.kind {
                    let prefix = list?.kind == .orderedList ? "\(ordinal). " : "• "
                    if block.kind == .checklist { prepend(block.checked ? "[x] " : "[ ] ", to: &block) }
                    prepend(prefix, to: &block)
                }
                if seenQuotes.insert(quote.identity).inserted, paragraph.startsWithAlert || isAlert,
                   let alert = block.text.range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?: |\u2028|\n)?"#, options: .regularExpression) {
                    let name = String(block.text[alert]).components(separatedBy: "]")[0].dropFirst(2)
                    let defaults = ["NOTE": "", "TIP": "💡", "IMPORTANT": "❗", "WARNING": "⚠️", "CAUTION": "🛑"]
                    let alertLength = (String(block.text[alert]) as NSString).length
                    removePrefix(alertLength, from: &block)
                    var icon = defaults[String(name)] ?? ""
                    if !literalEmojiOffsets.contains(alertLength),
                       let first = block.text.first, first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.value > 127 && $0.properties.isEmoji) }) {
                        icon = String(first); removePrefix((icon as NSString).length, from: &block)
                        if block.text.hasPrefix(" ") { removePrefix(1, from: &block) }
                    }
                    alerts[quote.identity] = icon
                    if paragraph.calloutStart || nextCalloutStart { explicitAlerts.insert(quote.identity) }
                    nextCalloutStart = false
                }
                block.style = "quote"; block.level = nil; block.indent = nil; block.language = nil; block.start = nil
                block.kind = .text; block.id = nil; block.checked = false
                block.callout = alerts[quote.identity]
                if block.text.isEmpty, !paragraph.emptyParagraph, block.callout != nil,
                   paragraphs.dropFirst(paragraphIndex + 1).contains(where: { $0.intents.contains { $0.kind == .blockQuote && $0.identity == quote.identity } }) { continue }
                if let icon = block.callout, startedAlerts.insert(quote.identity).inserted {
                    block.calloutStart = explicitAlerts.contains(quote.identity) ||
                        (blocks.last?.style == "quote" && blocks.last?.callout == icon)
                }
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
        return NoteDocument(blocks: blocks.isEmpty ? [.text(prepared.boundaries.isEmpty ? originalMarkdown : "")] : blocks)
    }

    /// Locate balanced inline HTML in one pass. A non-greedy paired-tag
    /// regex rescans every unmatched opener and is quadratic on pasted junk.
    private static func inlineHTMLRanges(in source: String) -> [NSRange] {
        let regex = try! NSRegularExpression(pattern: #"<(\/?)(strong|em|u|s|mark|code|a)(?:\s+[^<>]*)?>"#)
        let text = source as NSString
        var stack: [String] = [], depth = 0, start = 0, invalid = false, result: [NSRange] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let tag = text.substring(with: match.range(at: 2))
            if match.range(at: 1).length == 0 {
                if depth == 0 { start = match.range.location; invalid = false }
                depth += 1
                if depth <= 32 { stack.append(tag) } else { invalid = true }
            } else {
                if depth > 32 { depth -= 1; continue }
                guard depth > 0, stack.last == tag else { stack.removeAll(); depth = 0; continue }
                stack.removeLast(); depth -= 1
                if depth == 0, !invalid {
                    let range = NSRange(location: start, length: NSMaxRange(match.range) - start)
                    if !text.substring(with: range).contains("\n") { result.append(range) }
                }
            }
        }
        return result
    }

    /// Source ranges reported by Foundation drift after hard breaks. Code
    /// shielding must use literal source offsets, before any parse-only atoms
    /// are inserted. This lexer recognizes fences, indented blocks and exact
    /// backtick runs; it never interprets HTML or resolves a resource.
    private static func protectedCode(in source: String) -> (all: [NSRange], blocks: [NSRange]) {
        let text = source as NSString
        var blocks: [NSRange] = [], offset = 0
        var fence: (unit: UInt16, count: Int, start: Int)?
        var previousBlank = true, indented = false, inList = false
        for line in source.components(separatedBy: "\n") {
            let length = line.utf16.count, full = min(length + 1, text.length - offset)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                let close = trimmed.utf16.prefix { $0 == active.unit }.count
                if close >= active.count && trimmed.utf16.dropFirst(close).allSatisfy({ $0 == 32 || $0 == 9 }) {
                    blocks.append(NSRange(location: active.start, length: offset + full - active.start)); fence = nil
                }
            } else {
                let list = line.range(of: #"^[ \t]*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+"#, options: .regularExpression) != nil
                if list { inList = true }
                else if previousBlank, !line.hasPrefix(" "), !line.hasPrefix("\t"), !trimmed.isEmpty { inList = false }
                if let match = line.range(of: #"^ {0,3}(?:>[ \t]?)*(`{3,}|~{3,})"#, options: .regularExpression) {
                    let value = String(line[match].reversed().prefix { $0 == "`" || $0 == "~" }.reversed())
                    if let unit = value.utf16.first { fence = (unit, value.utf16.count, offset) }
                    indented = false
                } else {
                    let hasIndent = line.hasPrefix("    ") || line.hasPrefix("\t")
                    if hasIndent && !inList && (previousBlank || indented) {
                        blocks.append(NSRange(location: offset, length: full)); indented = true
                    } else if !trimmed.isEmpty { indented = false }
                }
            }
            previousBlank = trimmed.isEmpty
            offset += length + 1
        }
        if let fence { blocks.append(NSRange(location: fence.start, length: text.length - fence.start)) }
        let units = Array(source.utf16)
        let htmlRanges = inlineHTMLRanges(in: source)
        var all = blocks, index = 0, blockIndex = 0, htmlIndex = 0
        var work = max(1, units.count) * 16
        while index < units.count {
            while blockIndex < blocks.count, NSMaxRange(blocks[blockIndex]) <= index { blockIndex += 1 }
            if blockIndex < blocks.count, NSLocationInRange(index, blocks[blockIndex]) { index = NSMaxRange(blocks[blockIndex]); continue }
            while htmlIndex < htmlRanges.count, NSMaxRange(htmlRanges[htmlIndex]) <= index { htmlIndex += 1 }
            if htmlIndex < htmlRanges.count, htmlRanges[htmlIndex].location == index { index = NSMaxRange(htmlRanges[htmlIndex]); continue }
            guard units[index] == 96 else { index += 1; continue }
            var slash = index
            while slash > 0, units[slash - 1] == 92 { slash -= 1 }
            if (index - slash) % 2 == 1 { index += 1; continue }
            var width = 1
            while index + width < units.count, units[index + width] == 96 { width += 1 }
            var close = index + width, found: Int?
            let limit = blockIndex < blocks.count ? blocks[blockIndex].location : units.count
            while close < limit {
                guard work > 0 else { return ([NSRange(location: 0, length: text.length)], blocks) }
                work -= 1
                if units[close] != 96 { close += 1; continue }
                var count = 1
                while close + count < units.count, units[close + count] == 96 { count += 1 }
                if count == width { found = close + count; break }
                close += count
            }
            if let end = found { all.append(NSRange(location: index, length: end - index)); index = end }
            else { index += width }
        }
        return (all, blocks)
    }

    /// Replace supported source extensions with parse-only atoms before
    /// CommonMark consumes them. Tokens are unique per parse and never saved.
    private static func prepareExtensions(_ source: String) throws -> (source: String, tables: [String: NoteTable], spans: [String: NoteTable.Cell], lists: [String: (indent: Int?, start: Int?)], tasks: Set<String>, boundaries: Set<String>, alerts: Set<String>, literals: Set<String>) {
        let protected = protectedCode(in: source)
        let code = protected.all, fenced = protected.blocks
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sourceUnits = Array(source.utf16)
        func escaped(at offset: Int) -> Bool {
            var start = offset
            while start > 0, sourceUnits[start - 1] == 92 { start -= 1 }
            return (offset - start) % 2 == 1
        }
        let result = NSMutableString(string: source)
        var replacements: [(NSRange, String)] = [], tables: [String: NoteTable] = [:], spans: [String: NoteTable.Cell] = [:]
        var lists: [String: (indent: Int?, start: Int?)] = [:]
        var tasks = Set<String>(), boundaries = Set<String>(), alerts = Set<String>(), literals = Set<String>()
        let lines = source.components(separatedBy: "\n")
        var line = 0, offset = 0
        while line < lines.count {
            let possibleTable = NoteTableText.commentFields(lines[line]) != nil ||
                (lines[line].contains("|") && line + 1 < lines.count && NoteTableText.delimiterAlignments(lines[line + 1]) != nil)
            if possibleTable, !fenced.contains(where: { NSLocationInRange(offset, $0) }),
               let table = NoteTableText.parseMarkdown(lines: Array(lines[line...])) {
                let length = lines[line..<(line + table.consumed)].joined(separator: "\n").utf16.count
                let token = "atticTable" + nonce + String(tables.count) + "End"
                tables[token] = table.table
                replacements.append((NSRange(location: offset, length: length), token))
                offset += length + 1; line += table.consumed
            } else { offset += lines[line].utf16.count + 1; line += 1 }
        }
        // HTML is deliberately restricted to paired inline tags. Never parse
        // code, escaped source, tables twice, or arbitrary document HTML.
        let string = source as NSString
        let highlight = try NSRegularExpression(pattern: #"==[^=\n]+=="#)
        let inlineRanges = inlineHTMLRanges(in: source) + highlight.matches(in: source, range: NSRange(location: 0, length: string.length)).map(\.range)
        for range in inlineRanges.sorted(by: { $0.location < $1.location }) {
            guard !code.contains(where: { NSLocationInRange(range.location, $0) }),
                  !replacements.contains(where: { NSIntersectionRange($0.0, range).length > 0 }) else { continue }
            var escapeStart = range.location
            while escapeStart > 0, string.character(at: escapeStart - 1) == 92 { escapeStart -= 1 }
            guard (range.location - escapeStart) % 2 == 0 else { continue }
            let raw = string.substring(with: range)
            let cell: NoteTable.Cell?
            if raw.hasPrefix("==") { cell = NoteTableText.inlineCell(raw) }
            else { cell = NoteMarkdownInline.parse(raw) }
            guard let cell else { continue }
            let token = "atticSpan" + nonce + String(spans.count) + "End"
            spans[token] = cell
            if raw.range(of: #"^(?:<[^<>]+>)*&#"#, options: .regularExpression) != nil { literals.insert(token) }
            replacements.append((range, token))
        }
        let emptyLine = try NSRegularExpression(pattern: #"(?m)^(?:#{1,6} |>[ \t]?(?:[^\n<>]* )?)?(<br>)$"#)
        let emptyRanges = Set(emptyLine.matches(in: source, range: NSRange(location: 0, length: string.length)).map { $0.range(at: 1) })
        let breaks = try NSRegularExpression(pattern: #"<br(?: ?/)?>"#)
        for match in breaks.matches(in: source, range: NSRange(location: 0, length: string.length)) {
            guard !escaped(at: match.range.location), !emptyRanges.contains(match.range), !code.contains(where: { NSLocationInRange(match.range.location, $0) }),
                  !replacements.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else { continue }
            let token = "atticSpan" + nonce + String(spans.count) + "End"
            spans[token] = NoteTable.Cell("\u{2028}"); replacements.append((match.range, token))
        }
        let numeric = try NSRegularExpression(pattern: #"(?:&#(?:x[0-9a-fA-F]+|[0-9]+);)+"#)
        for match in numeric.matches(in: source, range: NSRange(location: 0, length: string.length)) {
            guard !escaped(at: match.range.location), !code.contains(where: { NSLocationInRange(match.range.location, $0) }),
                  !replacements.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else { continue }
            let token = "atticSpan" + nonce + String(spans.count) + "End"
            spans[token] = NoteTable.Cell(NoteTableText.decodeEntities(string.substring(with: match.range)))
            literals.insert(token); replacements.append((match.range, token))
        }
        let structural = try NSRegularExpression(pattern: #"(?m)^<!-- attic:callout-start -->$|^>[ \t]?(\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\])(?: |$)"#)
        for match in structural.matches(in: source, range: NSRange(location: 0, length: string.length)) {
            let range = match.range(at: 1).location == NSNotFound ? match.range : match.range(at: 1)
            guard !code.contains(where: { NSLocationInRange(range.location, $0) }),
                  !replacements.contains(where: { NSIntersectionRange($0.0, range).length > 0 }) else { continue }
            let token = "atticSpan" + nonce + String(spans.count) + "End"
            spans[token] = NoteTable.Cell(string.substring(with: range))
            if match.range(at: 1).location == NSNotFound { boundaries.insert(token) } else { alerts.insert(token) }
            replacements.append((range, token))
        }
        let task = try NSRegularExpression(pattern: #"(?m)^[ \t]*[-+*][ \t]+(\[(?: |x|X)\])(?: |$)"#)
        for match in task.matches(in: source, range: NSRange(location: 0, length: string.length)) {
            let range = match.range(at: 1)
            guard !code.contains(where: { NSLocationInRange(range.location, $0) }),
                  !replacements.contains(where: { NSIntersectionRange($0.0, range).length > 0 }) else { continue }
            let token = "atticSpan" + nonce + String(spans.count) + "End"
            spans[token] = NoteTable.Cell(string.substring(with: range)); tasks.insert(token)
            replacements.append((range, token))
        }
        let hint = try NSRegularExpression(pattern: #"<!-- attic:list(?: indent=([12]))?(?: start=([0-9]+))? -->"#)
        for match in hint.matches(in: source, range: NSRange(location: 0, length: string.length)) {
            let line = string.lineRange(for: NSRange(location: match.range.location, length: 0))
            let prefix = string.substring(with: NSRange(location: line.location, length: match.range.location - line.location))
            guard prefix.range(of: #"^[ \t]*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+(?:\[(?: |x|X)\] )?$"#, options: .regularExpression) != nil else { continue }
            guard !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  !replacements.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else { continue }
            let indent = match.range(at: 1).location == NSNotFound ? nil : Int(string.substring(with: match.range(at: 1)))
            let start = match.range(at: 2).location == NSNotFound ? nil : Int(string.substring(with: match.range(at: 2)))
            let token = "atticList" + nonce + String(lists.count) + "End"
            lists[token] = (indent, start); replacements.append((match.range, token))
        }
        for (range, token) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: token)
        }
        return (result as String, tables, spans, lists, tasks, boundaries, alerts, literals)
    }

    private static func restoreInline(_ block: inout NoteBlock, spans: [String: NoteTable.Cell], literals: Set<String>, offsets: inout Set<Int>) {
        var replacements: [(NSRange, NoteTable.Cell)] = []
        let text = block.text as NSString
        let regex = try! NSRegularExpression(pattern: #"atticSpan[A-F0-9]{32}[0-9]+End"#)
        for match in regex.matches(in: block.text, range: NSRange(location: 0, length: text.length)) {
            if let cell = spans[text.substring(with: match.range)] { replacements.append((match.range, cell)) }
        }
        for (range, cell) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            let token = (block.text as NSString).substring(with: range)
            let delta = cell.text.utf16.count - range.length
            offsets = Set(offsets.map { $0 >= NSMaxRange(range) ? $0 + delta : $0 })
            if literals.contains(token) { offsets.insert(range.location) }
            block.marks = block.marks.map { mark in
                var mark = mark
                let end = mark.offset + mark.length
                if mark.offset >= NSMaxRange(range) { mark.offset += delta }
                else if end >= NSMaxRange(range) { mark.length += delta }
                return mark
            }
            block.text = (block.text as NSString).replacingCharacters(in: range, with: cell.text)
            block.marks += cell.marks.map { NoteMark($0.kind, offset: range.location + $0.offset, length: $0.length, url: $0.url, colour: $0.colour) }
        }
        block.marks = NoteTableText.canonicalMarks(block.marks)
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
