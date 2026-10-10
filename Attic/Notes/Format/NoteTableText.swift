import Foundation

/// Tables as text (spec § 4.4, § 4.6): GFM pipe tables for Markdown export,
/// Copy as Markdown and agents; tab-separated text for plain text; and the
/// tabular forms a paste may bring (TSV, an HTML `<table>`, a Markdown pipe
/// table).
enum NoteTableText {
    // MARK: Markdown (GFM)

    /// The line before a table whose header row is off, so a re-import keeps
    /// it off (GFM always has a header).
    static let headerOffComment = "<!-- attic:table headerRow=false -->"

    /// A GFM pipe table: the first row is the header; `|` is escaped, a
    /// line break in a cell becomes `<br>`, and the alignment row reads
    /// `---`, `:---:` or `---:`. With the header row off, the first row is
    /// still GFM's header and a comment line before the table says so.
    static func markdown(_ table: NoteTable, cellText: (NoteTable.Cell) -> String = { NoteMarkdownExport.escapeInlineText($0.displayText) }) -> String {
        guard table.isRectangular else { return "" }
        var lines: [String] = []
        if !table.headerRow { lines.append(headerOffComment) }
        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        let rows = table.rows.map { $0.cells.map { escape(cellText($0)) } }
        lines.append(line(rows[0]))
        lines.append("|" + table.columns.map { column in
            switch column.align {
            case .left: " --- "
            case .center: " :---: "
            case .right: " ---: "
            }
        }.joined(separator: "|") + "|")
        for row in rows.dropFirst() { lines.append(line(row)) }
        return lines.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
        // GFM padding is trimmed on import. Quote only literal edge whitespace
        // so cell text survives without changing external table parsing rules.
        let scalars = Array(escaped.unicodeScalars)
        let leading = scalars.prefix { CharacterSet.whitespaces.contains($0) }.count
        let trailing = scalars.reversed().prefix { CharacterSet.whitespaces.contains($0) }.count
        return scalars.enumerated().map { index, scalar in
            index < leading || index >= scalars.count - trailing
                ? "&#\(scalar.value);" : String(scalar)
        }.joined()
    }

    /// Plain agent cell text has no inline parser: quote HTML and literal
    /// backslashes once before the table's pipe/newline escaping.
    static func plainCellMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\\", with: "\\\\")
    }

    static func unescape(_ text: String, decodeHTML: Bool = true) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                if next == "|" || (decodeHTML && next == "\\") { result.append(next) } else { result.append(character); result.append(next) }
            } else {
                result.append(character)
            }
        }
        let breaks = result.replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
        return decodeHTML ? decodeEntities(breaks) : breaks
    }

    /// The cells of one pipe-table line, or nil when it is not one.
    static func pipeCells(_ line: String, decodeHTML: Bool = true) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        // A leading and a trailing pipe enclose the row.
        if trimmed.hasPrefix("|") { cells.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
        guard !cells.isEmpty else { return nil }
        return cells.map { unescape($0.trimmingCharacters(in: .whitespaces), decodeHTML: decodeHTML) }
    }

    /// The alignments of a GFM delimiter row (`| --- | :-: |`), or nil.
    static func delimiterAlignments(_ line: String) -> [NoteTable.Alignment]? {
        guard let cells = pipeCells(line), !cells.isEmpty else { return nil }
        var result: [NoteTable.Alignment] = []
        for cell in cells {
            let value = cell.replacingOccurrences(of: " ", with: "")
            guard value.count >= 1, value.allSatisfy({ $0 == "-" || $0 == ":" }), value.contains("-") else { return nil }
            let left = value.hasPrefix(":"), right = value.hasSuffix(":")
            result.append(left && right ? .center : (right ? .right : .left))
        }
        return result
    }

    /// A pipe table at the start of `lines`: its header, delimiter and body
    /// rows (an `attic:table` comment line before it is read too). Returns
    /// the table and how many lines it used.
    static func parseMarkdown(lines: [String]) -> (table: NoteTable, consumed: Int, id: UUID?, headerOff: Bool)? {
        var index = 0
        var headerOff = false
        var id: UUID?
        while index < lines.count, let comment = commentFields(lines[index]) {
            if comment["headerRow"] == "false" { headerOff = true }
            if let raw = comment["id"], let value = UUID(uuidString: raw) { id = value }
            index += 1
        }
        guard index + 1 < lines.count, let header = pipeCells(lines[index], decodeHTML: false),
              let alignments = delimiterAlignments(lines[index + 1]), alignments.count == header.count else { return nil }
        var rows = [header]
        var end = index + 2
        while end < lines.count, let cells = pipeCells(lines[end], decodeHTML: false) {
            rows.append(cells)
            end += 1
        }
        let width = header.count
        let rectangular = rows.map { row in Array((row + Array(repeating: "", count: max(0, width - row.count))).prefix(width)) }
        var table = NoteTable(texts: rectangular, headerRow: !headerOff, alignments: alignments)
        for row in table.rows.indices {
            table.rows[row].cells = rectangular[row].map(inlineCell)
        }
        return (table, end, id, headerOff)
    }

    /// The inline syntax emitted by Copy as Markdown, with UTF-16 mark
    /// offsets. Parse before decoding entities so escaped literals stay prose.
    static func inlineCell(_ markdown: String) -> NoteTable.Cell {
        let input = Array(markdown)
        let delimiters: [(String, String, NoteMark.Kind)] = [
            ("**", "**", .bold), ("*", "*", .italic), ("~~", "~~", .strikethrough),
            ("`", "`", .code), ("==", "==", .highlight), ("<u>", "</u>", .underline)
        ]
        var remainingWork = max(1, input.count) * 16
        func matches(_ token: String, at index: Int) -> Bool {
            let chars = Array(token)
            return index + chars.count <= input.count && Array(input[index..<(index + chars.count)]) == chars
        }
        func parse(from start: Int, until end: String? = nil, depth: Int = 0) -> (cell: NoteTable.Cell, next: Int, closed: Bool) {
            var cell = NoteTable.Cell(), index = start, literal = ""
            func flush() { cell.text += decodeEntities(literal); literal = "" }
            func append(_ inner: NoteTable.Cell, kind: NoteMark.Kind, url: String? = nil) {
                flush()
                let offset = cell.text.utf16.count
                cell.text += inner.text
                cell.marks += inner.marks.map { NoteMark($0.kind, offset: offset + $0.offset, length: $0.length, url: $0.url) }
                if !inner.text.isEmpty { cell.marks.append(NoteMark(kind, offset: offset, length: inner.text.utf16.count, url: url)) }
            }
            while index < input.count {
                // Malformed external input must not cause recursive rescans
                // to block paste. Exhaustion leaves the remaining text literal.
                guard remainingWork > 0 else {
                    literal += String(input[index...]); flush()
                    return (cell, input.count, end == nil)
                }
                remainingWork -= 1
                if input[index] == "\\", index + 1 < input.count {
                    literal.append(input[index + 1]); index += 2; continue
                }
                if let end, matches(end, at: index) {
                    flush(); return (cell, index + end.count, true)
                }
                if depth < 32, input[index] == "[" {
                    let label = parse(from: index + 1, until: "]", depth: depth + 1)
                    if label.closed, matches("(", at: label.next) {
                        var cursor = label.next + 1, nesting = 1, url = ""
                        while cursor < input.count {
                            let character = input[cursor]
                            if character == "\\", cursor + 1 < input.count {
                                url.append(input[cursor + 1]); cursor += 2; continue
                            }
                            if character == "(" { nesting += 1 }
                            if character == ")" { nesting -= 1; if nesting == 0 { break } }
                            url.append(character); cursor += 1
                        }
                        if nesting == 0 {
                            append(label.cell, kind: .link, url: decodeEntities(url))
                            index = cursor + 1; continue
                        }
                    }
                }
                var consumed = false
                if depth < 32 {
                    for (open, close, kind) in delimiters where matches(open, at: index) {
                        let inner = parse(from: index + open.count, until: close, depth: depth + 1)
                        if inner.closed, !inner.cell.text.isEmpty {
                            append(inner.cell, kind: kind); index = inner.next; consumed = true; break
                        }
                    }
                }
                if !consumed { literal.append(input[index]); index += 1 }
            }
            flush(); return (cell, index, end == nil)
        }
        var cell = parse(from: 0).cell
        cell.marks.sort { $0.kind.rawValue != $1.kind.rawValue ? $0.kind.rawValue < $1.kind.rawValue : $0.offset < $1.offset }
        // Export splits marks at overlap boundaries; join their adjacent runs.
        var merged: [NoteMark] = []
        for mark in cell.marks {
            if let last = merged.last, last.kind == mark.kind, last.url == mark.url,
               last.offset + last.length == mark.offset {
                merged[merged.count - 1] = NoteMark(last.kind, offset: last.offset, length: last.length + mark.length, url: last.url)
            } else { merged.append(mark) }
        }
        cell.marks = merged
        return cell
    }

    /// The whole text is one pipe table (a paste, Markdown's `| a | b |`).
    static func parseMarkdown(_ text: String) -> NoteTable? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let parsed = parseMarkdown(lines: lines), parsed.consumed == lines.count else { return nil }
        return parsed.table
    }

    /// `<!-- attic:table id=… headerRow=false -->` → its fields.
    static func commentFields(_ line: String) -> [String: String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!-- attic:table"), trimmed.hasSuffix("-->") else { return nil }
        let inner = trimmed.dropFirst("<!-- attic:table".count).dropLast(3)
        var fields: [String: String] = [:]
        for part in inner.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields
    }

    // MARK: Tab-separated

    static func tsv(_ table: NoteTable) -> String {
        table.rows.map { row in
            row.cells.map { $0.displayText.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// Tab-separated rows: at least 2 columns, and most lines with the same
    /// number of cells (a stray tab in prose is not a table). A cell that
    /// starts with a quote is quoted, as spreadsheets write a cell holding a
    /// tab, a line break or a quote ("" for a quote inside).
    static func parseTSV(_ text: String) -> [[String]]? {
        guard text.contains("\t") else { return nil }
        let source = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var atFieldStart = true
        var iterator = Array(source).makeIterator()
        var pending: Character?
        func next() -> Character? {
            if let value = pending { pending = nil; return value }
            return iterator.next()
        }
        while let character = next() {
            if quoted {
                if character == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { quoted = false; pending = following }
                    } else { quoted = false }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where atFieldStart:
                quoted = true
                atFieldStart = false
            case "\t":
                row.append(field)
                field = ""
                atFieldStart = true
            case "\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                atFieldStart = true
            default:
                field.append(character)
                atFieldStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
        guard !rows.isEmpty else { return nil }
        let counts = rows.map(\.count)
        guard let common = Dictionary(grouping: counts, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key,
              common >= 2 else { return nil }
        let agreeing = counts.filter { $0 == common }.count
        guard Double(agreeing) / Double(counts.count) >= 0.6 else { return nil }
        return rows
    }

    // MARK: HTML

    /// The first `<table>` in `html`: its rows and cells as text, and
    /// whether its first row is a header (`<th>` or `<thead>`).
    static func parseHTML(_ html: String) -> (rows: [[String]], header: Bool)? {
        guard let tableStart = html.range(of: "<table", options: .caseInsensitive) else { return nil }
        let rest = html[tableStart.lowerBound...]
        let tableEnd = rest.range(of: "</table>", options: .caseInsensitive)?.upperBound ?? rest.endIndex
        let source = String(rest[..<tableEnd])
        var rows: [[String]] = []
        var header = false
        var cursor = source.startIndex
        while let rowStart = source.range(of: "<tr", options: .caseInsensitive, range: cursor..<source.endIndex) {
            let rowEnd = source.range(of: "</tr>", options: .caseInsensitive, range: rowStart.upperBound..<source.endIndex)
            let nextRow = source.range(of: "<tr", options: .caseInsensitive, range: rowStart.upperBound..<source.endIndex)
            let end = [rowEnd?.lowerBound, nextRow?.lowerBound].compactMap { $0 }.min() ?? source.endIndex
            let row = String(source[rowStart.upperBound..<end])
            var cells: [String] = []
            var cellCursor = row.startIndex
            while let open = row.range(of: "<t[dh][\\s>]", options: [.regularExpression, .caseInsensitive],
                                       range: cellCursor..<row.endIndex) {
                if rows.isEmpty, row[open].lowercased().hasPrefix("<th") { header = true }
                guard let tagEnd = row.range(of: ">", range: open.lowerBound..<row.endIndex) else { break }
                let close = row.range(of: "</t[dh]>|<t[dh][\\s>]", options: [.regularExpression, .caseInsensitive],
                                      range: tagEnd.upperBound..<row.endIndex)
                let content = String(row[tagEnd.upperBound..<(close?.lowerBound ?? row.endIndex)])
                cells.append(htmlText(content))
                let span = row[open.lowerBound..<tagEnd.upperBound]
                if let colspan = span.range(of: "colspan=\"?([0-9]+)", options: [.regularExpression, .caseInsensitive]) {
                    let digits = span[colspan].filter(\.isNumber)
                    if let count = Int(digits), count > 1 { cells += Array(repeating: "", count: min(count, NoteTable.maxColumns) - 1) }
                }
                cellCursor = close.map { row[$0].hasPrefix("</") ? $0.upperBound : $0.lowerBound } ?? row.endIndex
            }
            if !cells.isEmpty { rows.append(cells) }
            cursor = end
        }
        if source.range(of: "<thead", options: .caseInsensitive) != nil { header = true }
        guard !rows.isEmpty, (rows.map(\.count).max() ?? 0) >= 1, rows.count + (rows.first?.count ?? 0) > 2 else { return nil }
        return (rows, header)
    }

    /// An HTML fragment's text: tags dropped, `<br>` and block ends as line
    /// breaks, entities decoded, white space collapsed as a browser does.
    static func htmlText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br[^>]*>", with: "\u{1}", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</(p|div|li)>", with: "\u{1}", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "[ \\t\\n\\r]+", with: " ", options: .regularExpression)
        return text.components(separatedBy: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")]
        var result = text
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        // Numeric references.
        while let range = result.range(of: "&#(x[0-9a-fA-F]+|[0-9]+);", options: .regularExpression) {
            let body = result[range].dropFirst(2).dropLast()
            let value = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            result.replaceSubrange(range, with: value.flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? "")
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
