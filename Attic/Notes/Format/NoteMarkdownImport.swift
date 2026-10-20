import Foundation
import Markdown

/// An offline AST adapter. The parser sees the original source, with smart
/// punctuation disabled. Its GFM table/strike/task extensions are enabled;
/// the GFM autolink extension is not (CommonMark angle links still work).
enum NoteMarkdownImport {
    static func shouldImport(_ text: String) -> Bool {
        if ["**", "`", "~~", "<u>", "<mark", "<strong>", "<em>", "==", "<br>", "&#"].contains(where: text.contains) { return true }
        return text.range(of: #"(?m)^(?: {4,}\S|\t[ \t]*\S| {0,3}#{1,6} |\s*[-*+] |\s*[1-9][0-9]*\. |> ?| {0,3}(?:---+|\*\*\*+|___+)\s*$|\s*\|.*\|)|\[[^\]]+\]\([^\)]+\)"#, options: .regularExpression) != nil
    }

    static func document(_ markdown: String) throws -> NoteDocument {
        let reader = Reader(markdown)
        let blocks = reader.blocks(Array(Document(parsing: markdown, options: [.disableSmartOpts]).children), preservingDefinitions: true)
        return NoteDocument(blocks: blocks.isEmpty ? [.text("")] : blocks)
    }

    /// Source positions are UTF-8 byte columns, not String or UTF-16 offsets.
    /// Keep the immutable source alongside the AST for export-only extensions.
    private final class Reader {
        let source: [UInt8]
        let lines: [Int]
        var tableColumns: [Int: [Int]] = [:]

        init(_ source: String) {
            let bytes = Array(source.utf8)
            self.source = bytes
            var starts = [0], index = 0
            while index < bytes.count {
                if bytes[index] == 13 {
                    index += 1
                    if index < bytes.count, bytes[index] == 10 { index += 1 }
                    starts.append(index)
                } else {
                    if bytes[index] == 10 { starts.append(index + 1) }
                    index += 1
                }
            }
            self.lines = starts
        }

        func offset(_ location: SourceLocation) -> Int? {
            guard location.line > 0, location.line <= lines.count, location.column > 0 else { return nil }
            let offset = lines[location.line - 1] + location.column - 1
            return offset <= source.count ? offset : nil
        }

        func raw(_ node: any Markup) -> String {
            guard let range = node.range else { return "" }
            return raw(range)
        }

        func raw(_ range: SourceRange) -> String {
            guard let start = offset(range.lowerBound), let end = offset(range.upperBound), start <= end else { return "" }
            return String(decoding: source[start..<end], as: UTF8.self)
        }

        /// cmark unescapes pipes before parsing a cell's inlines, but leaves
        /// its inline columns in that shorter buffer. Translate those columns
        /// back to the immutable source, relative to the enclosing AST cell.
        func rawInline(_ range: SourceRange, node: any Markup, table: Bool) -> String {
            guard table else { return raw(range) }
            var parent = node.parent
            while let value = parent, !(value is Markdown.Table.Cell) { parent = value.parent }
            guard let cellRange = parent?.range, let start = offset(cellRange.lowerBound),
                  let end = offset(cellRange.upperBound), let lower = offset(range.lowerBound),
                  let upper = offset(range.upperBound), start <= end else { return raw(range) }
            let columns: [Int]
            if let existing = tableColumns[start] { columns = existing }
            else {
                var map: [Int] = [], cursor = start
                while cursor < end {
                    map.append(cursor)
                    if source[cursor] == 92, cursor + 1 < end, source[cursor + 1] == 124 { cursor += 1 }
                    cursor += 1
                }
                map.append(end); tableColumns[start] = map; columns = map
            }
            guard lower >= start, upper >= lower, upper - start < columns.count else { return raw(range) }
            return String(decoding: source[columns[lower - start]..<columns[upper - start]], as: UTF8.self)
        }

        /// CommonMark removes link definitions from its tree. R14 reserves
        /// footnote-like definitions as literal prose. Restore only source
        /// lines not represented by any AST leaf, code block or HTML block.
        func footnoteDefinitions(_ nodes: [any Markup]) -> [(line: Int, block: NoteBlock)] {
            guard source.contains(94) else { return [] }
            var covered: [Range<Int>] = []
            func visit(_ node: any Markup) {
                if node.childCount == 0 || node is CodeBlock || node is HTMLBlock {
                    if let range = node.range, let start = offset(range.lowerBound), let end = offset(range.upperBound), start < end { covered.append(start..<end) }
                } else { for child in node.children { visit(child) } }
            }
            for node in nodes { visit(node) }
            covered.sort { $0.lowerBound < $1.lowerBound }
            var result: [(Int, NoteBlock)] = [], index = 0, continuation = false
            for (line, start) in lines.enumerated() {
                var end = line + 1 < lines.count ? lines[line + 1] : source.count
                while end > start, source[end - 1] == 10 || source[end - 1] == 13 { end -= 1 }
                let text = String(decoding: source[start..<end], as: UTF8.self)
                let position = start + text.utf8.prefix { $0 == 32 || $0 == 9 }.count
                while index < covered.count, covered[index].upperBound <= position { index += 1 }
                let represented = index < covered.count && covered[index].contains(position)
                let definition = text.range(of: #"^ {0,3}\[\^[^\]\n]+\]:"#, options: .regularExpression) != nil
                if !represented, definition || (continuation && text.first?.isWhitespace == true && !text.trimmingCharacters(in: .whitespaces).isEmpty) {
                    result.append((line + 1, .text(text))); continuation = true
                } else { continuation = false }
            }
            return result
        }

        func blocks(_ nodes: [any Markup], depth: Int = 0, preservingDefinitions: Bool = false) -> [NoteBlock] {
            var result: [NoteBlock] = []
            let definitions = preservingDefinitions ? footnoteDefinitions(nodes) : []
            var definitionIndex = 0
            var boundary = false, headerOff = false
            var consumed = Set<Int>()
            for (nodeIndex, node) in nodes.enumerated() {
                if consumed.contains(nodeIndex) { continue }
                while definitionIndex < definitions.count, definitions[definitionIndex].line <= (node.range?.lowerBound.line ?? 0) {
                    result.append(definitions[definitionIndex].block); definitionIndex += 1
                }
                if let html = node as? HTMLBlock {
                    let literal = html.rawHTML.trimmingCharacters(in: .newlines)
                    if literal == "<!-- attic:callout-start -->" { boundary = true; continue }
                    if literal == NoteTableText.headerOffComment { headerOff = true; continue }
                    if literal == "<!-- attic:empty-item -->", html.parent is ListItem { result.append(.text("")); continue }
                    if let end = literal.range(of: " -->"), listHint(String(literal[..<end.upperBound])) != nil,
                       html.parent is ListItem {
                        var tail = String(literal[end.upperBound...])
                        // cmark ends a comment HTML block on this physical
                        // line. Its following paragraph can still be the same
                        // exported list item's hard-break continuation. Read
                        // that contiguous source fragment together, without
                        // changing any user text or introducing parse atoms.
                        var line = html.range?.upperBound.line ?? 0
                        var next = nodeIndex + 1
                        while !tail.isEmpty, next < nodes.count, nodes[next] is Markdown.Paragraph,
                              let range = nodes[next].range, range.lowerBound.line == line + 1 {
                            tail += "\n" + raw(nodes[next]); consumed.insert(next)
                            line = range.upperBound.line; next += 1
                        }
                        if tail.isEmpty || tail == "<!-- attic:empty-item -->" { result.append(.text("")) }
                        else { result += Reader(tail).blocks(Array(Document(parsing: tail, options: [.disableSmartOpts]).children), depth: depth, preservingDefinitions: true) }
                        continue
                    }
                    // An exact standalone <br> is the exported empty Body.
                    if literal == "<br>" { result.append(.text("")); continue }
                    result += literal.components(separatedBy: "\n").map { .text($0) }
                } else if let table = node as? Markdown.Table {
                    // Attic's pipe-table contract ends at the first line with
                    // no pipe. cmark also admits such lines as implicit rows;
                    // keep that trailing prose outside the grid (H17-04).
                    let body = Array(table.body.children)
                    let end = body.firstIndex { !raw($0).contains("|") } ?? body.count
                    let rows = [Array(table.head.children)] + body[..<end].map { Array($0.children) }
                    let alignments: [NoteTable.Alignment] = table.columnAlignments.map {
                        switch $0 { case .center: return .center; case .right: return .right; default: return .left }
                    }
                    let cells = rows.map { row in row.map { node -> NoteTable.Cell in
                        // swift-markdown enables cmark's non-GFM table spans.
                        // A caret-only continuation cell has no AST text after
                        // that pass. Attic has no merged-cell representation:
                        // retain its literal source instead of dropping it.
                        if let cell = node as? Markdown.Table.Cell, cell.rowspan == 0 {
                            return .init(raw(cell).trimmingCharacters(in: .whitespaces))
                        }
                        return inline(Array(node.children), table: true)
                    } }
                    if cells.count > NoteTable.maxRows || table.maxColumnCount > NoteTable.maxColumns {
                        // The model's existing limit is unchanged. Keep every
                        // parsed cell readable without constructing an invalid table.
                        result += cells.map { .text($0.map(\.text).joined(separator: "\t")) }
                    } else {
                        var value = NoteTable(texts: cells.map { $0.map(\.text) }, headerRow: !headerOff, alignments: alignments)
                        for row in cells.indices { value.rows[row].cells = cells[row] }
                        result.append(.table(value))
                    }
                    for row in body[end...] { result.append(.text(raw(row))) }
                    headerOff = false
                } else if let quote = node as? BlockQuote {
                    var content = blocks(Array(quote.children), depth: depth)
                    var icon: String?
                    if let paragraph = quote.child(at: 0) as? Markdown.Paragraph,
                       raw(paragraph).range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?: |$|\n)"#, options: .regularExpression) != nil,
                       !content.isEmpty,
                       let marker = content[0].text.range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?: |\u2028|\n)?"#, options: .regularExpression) {
                        let name = String(content[0].text[marker]).components(separatedBy: "]")[0].dropFirst(2)
                        icon = ["NOTE": "", "TIP": "💡", "IMPORTANT": "❗", "WARNING": "⚠️", "CAUTION": "🛑"][String(name)] ?? ""
                        removePrefix(String(content[0].text[marker]).utf16.count, from: &content[0])
                        // The alert marker and text can be separate paragraphs.
                        if content[0].text.isEmpty, content.count > 1, content[1].kind != .table { content.removeFirst() }
                        let literal = raw(paragraph)
                        let afterMarker = literal.components(separatedBy: "]").dropFirst().joined(separator: "]")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: #"^> ?"#, with: "", options: .regularExpression)
                        let entityEmoji = afterMarker.hasPrefix("&#") || afterMarker.range(of: #"^(?:<[^<>]+>)+&#"#, options: .regularExpression) != nil
                        if !entityEmoji, let first = content[0].text.first,
                           first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.value > 127 && $0.properties.isEmoji) }) {
                            icon = String(first); removePrefix(String(first).utf16.count, from: &content[0])
                            if content[0].text.hasPrefix(" ") { removePrefix(1, from: &content[0]) }
                        }
                        if content[0].text == "\u{2028}", afterMarker.hasSuffix("<br>") {
                            content[0].text = ""; content[0].marks = []
                        }
                    }
                    var quoted = calloutParagraphs(content, icon: icon ?? "", preservingTables: true, preservingQuoteDepth: icon == nil)
                    if icon == nil { for index in quoted.indices { quoted[index].callout = nil } }
                    if let icon, let first = quoted.firstIndex(where: { $0.kind == .text && $0.style == "quote" }) {
                        quoted[first].calloutStart = boundary || (result.last?.style == "quote" && result.last?.callout == icon)
                    }
                    result += quoted; boundary = false
                } else if node is UnorderedList || node is OrderedList {
                    let start = (node as? OrderedList).map { Int($0.startIndex) }
                    var first = true
                    for child in node.children {
                        guard let item = child as? ListItem else { continue }
                        var parts = blocks(Array(item.children), depth: depth + 1)
                        var checkbox = item.checkbox
                        // GFM requires whitespace after a checkbox. R14 also
                        // accepts the familiar empty '- [ ]' / '- [x]' form.
                        if checkbox == nil, let paragraph = item.child(at: 0) as? Markdown.Paragraph {
                            let literal = raw(paragraph)
                            if ["[ ]", "[x]", "[X]"].contains(literal), !parts.isEmpty {
                                checkbox = literal == "[ ]" ? .unchecked : .checked
                                removePrefix(3, from: &parts[0])
                            }
                        }
                        if parts.isEmpty { parts = [.text("")] }
                        // One source ListItem owns one marker/checkbox. Its
                        // continuation paragraphs are interior line breaks;
                        // nested lists, quotes, code and tables stay separate.
                        func isParagraph(_ index: Int) -> Bool {
                            parts[index].kind == .text && !["mono", "quote", "bullet", "number"].contains(parts[index].style)
                        }
                        if let firstParagraph = parts.indices.first(where: isParagraph) {
                            let continuations = parts.indices.dropFirst(firstParagraph + 1).prefix(while: isParagraph)
                            for continuation in continuations {
                                let offset = parts[firstParagraph].text.utf16.count + 1
                                parts[firstParagraph].text += "\u{2028}" + parts[continuation].text
                                parts[firstParagraph].marks += parts[continuation].marks.map {
                                    NoteMark($0.kind, offset: offset + $0.offset, length: $0.length, url: $0.url, colour: $0.colour)
                                }
                            }
                            for continuation in continuations.reversed() { parts.remove(at: continuation) }
                        }
                        for index in parts.indices where parts[index].style != "mono" && parts[index].style != "quote" && parts[index].kind == .text && parts[index].style != "bullet" && parts[index].style != "number" {
                            parts[index].style = start == nil ? "bullet" : "number"
                            parts[index].level = nil
                            parts[index].indent = depth == 0 ? nil : min(2, depth)
                            if first, let start, start != 1 { parts[index].start = start }
                            if let checkbox {
                                parts[index].kind = .checklist; parts[index].id = UUID()
                                parts[index].checked = checkbox == .checked
                                parts[index].style = nil; parts[index].start = nil
                            }
                            applyListHint(item, to: &parts[index])
                            first = false
                        }
                        result += parts
                    }
                } else if let code = node as? CodeBlock {
                    var text = code.code
                    if text.hasSuffix("\n") { text.removeLast() }
                    result += text.components(separatedBy: "\n").map {
                        var block = NoteBlock.text($0, style: "mono"); block.language = NoteCodeLanguage.normalize(code.language); return block
                    }
                } else if node is ThematicBreak {
                    result.append(.divider())
                } else if node is Markdown.Paragraph || node is Heading {
                    let children = Array(node.children)
                    var cell = inline(children)
                    if children.count == 1, (children[0] as? InlineHTML)?.rawHTML == "<br>" { cell = .empty }
                    var block = NoteBlock.text(cell.text); block.marks = cell.marks
                    if let heading = node as? Heading { block.style = "heading"; block.level = heading.level }
                    result.append(block)
                } else {
                    let children = Array(node.children)
                    if children.isEmpty { result.append(.text(raw(node))) }
                    else { result += blocks(children, depth: depth) }
                }
            }
            result += definitions.dropFirst(definitionIndex).map(\.block)
            return result
        }

        func listHint(_ literal: String) -> (indent: Int?, start: Int?)? {
            guard literal.range(of: #"^<!-- attic:list(?: indent=[12])?(?: start=[0-9]+)? -->$"#, options: .regularExpression) != nil else { return nil }
            var indent: Int?, start: Int?
            for field in literal.split(separator: " ") {
                let pair = field.split(separator: "=", maxSplits: 1)
                guard pair.count == 2, let value = Int(pair[1]) else { continue }
                if pair[0] == "indent" { indent = value }
                if pair[0] == "start" { start = value }
            }
            return (indent, start)
        }

        func applyListHint(_ item: ListItem, to block: inout NoteBlock) {
            let literal: String
            if let html = item.child(at: 0) as? HTMLBlock { literal = html.rawHTML }
            else if let paragraph = item.child(at: 0) as? Markdown.Paragraph,
                    let html = paragraph.child(at: 0) as? InlineHTML { literal = html.rawHTML }
            else { return }
            guard let end = literal.range(of: " -->"), let hint = listHint(String(literal[..<end.upperBound])) else { return }
            if let indent = hint.indent { block.indent = indent }
            if let start = hint.start { block.start = start }
        }

        /// The legacy ==highlight== export predates paired <mark> spans.
        /// Recognize it only in AST text with actual source delimiters; an
        /// escape, entity or code leaf can never manufacture the extension.
        func textCell(_ text: Markdown.Text, table: Bool) -> NoteTable.Cell {
            guard let range = text.range else { return .init(text.string) }
            let source = rawInline(range, node: text, table: table)
            guard source.contains("=="), !source.contains("\\=") else { return .init(text.string) }
            let regex = try! NSRegularExpression(pattern: #"(?<![\\=])==([^=\n]+)==(?![=])"#)
            let literal = text.string as NSString
            let matches = regex.matches(in: text.string, range: NSRange(location: 0, length: literal.length))
            guard !matches.isEmpty,
                  regex.numberOfMatches(in: source, range: NSRange(location: 0, length: source.utf16.count)) == matches.count else { return .init(text.string) }
            var result = NoteTable.Cell(), cursor = 0
            for match in matches {
                result.text += literal.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let content = literal.substring(with: match.range(at: 1))
                result.marks.append(NoteMark(.highlight, offset: result.text.utf16.count, length: content.utf16.count))
                result.text += content; cursor = NSMaxRange(match.range)
            }
            result.text += literal.substring(from: cursor)
            return result
        }

        /// Interpret only balanced inline forms emitted by our exporter.
        /// Pairing uses AST HTML leaves; code and escaped tags cannot enter it.
        /// Raw source inside a recognized pair preserves punctuation literally,
        /// even if CommonMark gave that punctuation additional inline structure.
        func inline(_ nodes: [any Markup], table: Bool = false) -> NoteTable.Cell {
            var pairs: [Int: Int] = [:], stack: [(String, Int)] = []
            var invalid = false
            for (index, node) in nodes.enumerated() {
                guard let html = node as? InlineHTML,
                      let tag = html.rawHTML.range(of: #"^(?:<(?:strong|em|u|s|code)>|<mark(?: data-attic-colour="[^"<>]*")?>|<a href="[^"<>]*">|</(?:strong|em|u|s|mark|code|a)>)$"#, options: .regularExpression) else { continue }
                let literal = String(html.rawHTML[tag])
                let name = String(literal.dropFirst(literal.hasPrefix("</") ? 2 : 1).prefix { $0.isLetter })
                if literal.hasPrefix("</") {
                    guard let last = stack.last, last.0 == name else { stack.removeAll(); invalid = false; continue }
                    stack.removeLast()
                    if stack.isEmpty { if !invalid { pairs[last.1] = index }; invalid = false }
                } else {
                    stack.append((name, index))
                    if stack.count > 32 { invalid = true }
                }
            }
            var result = NoteTable.Cell(), index = 0
            func append(_ cell: NoteTable.Cell, mark: NoteMark.Kind? = nil, url: String? = nil) {
                let offset = result.text.utf16.count
                result.text += cell.text
                result.marks += cell.marks.map { NoteMark($0.kind, offset: offset + $0.offset, length: $0.length, url: $0.url, colour: $0.colour) }
                if let mark, !cell.text.isEmpty { result.marks.append(NoteMark(mark, offset: offset, length: cell.text.utf16.count, url: url)) }
            }
            while index < nodes.count {
                let node = nodes[index]
                if let end = pairs[index], let startRange = node.range, let endRange = nodes[end].range {
                    var literal = rawInline(startRange.lowerBound..<endRange.upperBound, node: node, table: table)
                    if table { literal = NoteTableText.unescape(literal, decodeHTML: false) }
                    // A balanced pair always has source bytes. Failed range
                    // extraction must fall back to the AST, never consume it
                    // as a successfully parsed empty span.
                    if !literal.isEmpty, let cell = NoteMarkdownInline.parse(literal) { append(cell); index = end + 1; continue }
                }
                if let text = node as? Markdown.Text { append(textCell(text, table: table)) }
                else if let code = node as? InlineCode { append(.init(code.code), mark: .code) }
                else if node is Strong { append(inline(Array(node.children), table: table), mark: .bold) }
                else if node is Emphasis { append(inline(Array(node.children), table: table), mark: .italic) }
                else if node is Strikethrough { append(inline(Array(node.children), table: table), mark: .strikethrough) }
                else if let link = node as? Markdown.Link {
                    let literal = link.range.map { rawInline($0, node: link, table: table) } ?? ""
                    if literal.range(of: #"^\[\^[^\]]+\](?:\[\])?$"#, options: .regularExpression) != nil { append(.init(literal)) }
                    else { append(inline(Array(node.children), table: table), mark: .link, url: link.destination) }
                }
                else if node is Image { append(inline(Array(node.children), table: table)) }
                else if node is LineBreak { append(.init(table ? "\n" : "\u{2028}")) }
                else if node is SoftBreak { append(.init(" ")) }
                else if let html = node as? InlineHTML {
                    if ["<br>", "<br/>", "<br />"].contains(html.rawHTML) { append(.init(table ? "\n" : "\u{2028}")) }
                    else if html.rawHTML == "<!-- attic:empty-item -->", node.parent?.parent is ListItem { /* exported empty item */ }
                    else if index == 0, html.rawHTML.range(of: #"^<!-- attic:list(?: indent=[12])?(?: start=[0-9]+)? -->$"#, options: .regularExpression) != nil,
                            node.parent?.parent is ListItem { /* structural list metadata */ }
                    else { append(.init(html.rawHTML)) }
                } else { append(inline(Array(node.children), table: table)) }
                index += 1
            }
            if result.text.contains(NoteDocument.objectCharacter) {
                // Marks use UTF-16 boundaries. Removing a placeholder must
                // translate both ends, including spans parsed from paired HTML.
                let units = Array(result.text.utf16)
                var boundaries = [0]
                for unit in units { boundaries.append(boundaries.last! + (unit == 0xFFFC ? 0 : 1)) }
                result.marks = result.marks.compactMap { mark in
                    guard mark.offset >= 0, mark.length > 0, mark.offset <= units.count,
                          mark.length <= units.count - mark.offset else { return nil }
                    let lower = boundaries[mark.offset], upper = boundaries[mark.offset + mark.length]
                    guard upper > lower else { return nil }
                    return NoteMark(mark.kind, offset: lower, length: upper - lower, url: mark.url, colour: mark.colour)
                }
                result.text = result.text.replacingOccurrences(of: String(NoteDocument.objectCharacter), with: "")
            }
            result.marks = NoteTableText.canonicalMarks(result.marks)
            return result
        }
    }

    static func calloutParagraphs(_ blocks: [NoteBlock], icon: String, preservingTables: Bool = false,
                                  preservingQuoteDepth: Bool = false) -> [NoteBlock] {
        var ordinal = 0
        return blocks.flatMap { block -> [NoteBlock] in
            // Source quotes cannot wrap a grid in our model. Keep the real
            // table between quoted paragraphs rather than flattening its cells.
            // Pasting into an existing callout retains the default projection.
            if preservingTables, block.kind == .table { return [block] }
            let quoteIndent = preservingQuoteDepth && block.style == "quote" ? min(2, (block.indent ?? 0) + 1) : nil
            var copy = block
            switch block.kind {
            case .text:
                if block.style == "bullet" { prepend("• ", to: &copy) }
                if block.style == "number" { ordinal = block.start ?? (ordinal < Int.max ? ordinal + 1 : ordinal); prepend("\(ordinal). ", to: &copy) }
                else if block.style != "bullet" { ordinal = 0 }
            case .checklist: prepend(block.checked ? "• [x] " : "• [ ] ", to: &copy)
            default: copy = .text(NoteTextExport.plainLine(block))
            }
            copy.kind = .text; copy.id = nil; copy.checked = false; copy.style = "quote"; copy.level = nil; copy.indent = quoteIndent
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
