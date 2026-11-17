import Foundation

/// Tables as agents read and write them (spec § 4.6; `ops/design/notes-tables.md`).
///
/// - `list_notes` shows each table as an `<!-- attic:table id=… -->` token
///   line and a GFM pipe table, and lists its row and column ids.
/// - `update_note` keeps a table whose text comes back as the export wrote
///   it, whole. Any other table is rebuilt from its text, keeping its id. A
///   table carrying something the text can't show (`carriesHidden`) must come
///   back unchanged under its own token (`NoteAgentTextSafety.validateTables`). A pipe table
///   without a token is a new table, unless it is a plain table whose token
///   alone was removed (the whole table must go for it to be deleted).
/// - `update_note_table` edits cells and structure by id
///   (`NoteTableAgentEdit`).
/// - Every write is checked: rectangular, within the limits, cells inline.
enum NoteAgentTableText {
    struct Parsed {
        var id: UUID?
        var headerOff: Bool
        var hasToken: Bool
        var rows: [[String]]
        var alignments: [NoteTable.Alignment]
        var consumed: Int
    }

    /// The table starting at `start` (a token line, or a pipe row followed
    /// by a delimiter row), or nil. A ragged table throws.
    static func parse(lines: [String], from start: Int) throws -> Parsed? {
        var index = start
        var id: UUID?
        var headerOff = false
        var hasToken = false
        if let fields = NoteTableText.commentFields(lines[index]) {
            hasToken = true
            id = fields["id"].flatMap(UUID.init(uuidString:))
            headerOff = fields["headerRow"] == "false"
            index += 1
        }
        guard index + 1 < lines.count, let header = NoteTableText.pipeCells(lines[index]),
              let alignments = NoteTableText.delimiterAlignments(lines[index + 1]) else {
            if hasToken { throw NoteAgentTextError.invalidTableEdit("A table token must be followed by its pipe table.") }
            return nil
        }
        guard alignments.count == header.count else { throw NoteAgentTextError.raggedTable }
        var rows = [header]
        var end = index + 2
        while end < lines.count, let cells = NoteTableText.pipeCells(lines[end]) {
            guard cells.count == header.count else { throw NoteAgentTextError.raggedTable }
            rows.append(cells)
            end += 1
        }
        guard header.count <= NoteTable.maxColumns, rows.count <= NoteTable.maxRows else { throw NoteAgentTextError.tableTooLarge }
        return Parsed(id: id, headerOff: headerOff, hasToken: hasToken, rows: rows, alignments: alignments, consumed: end - start)
    }

    /// The table block an agent's table becomes: the base table it names
    /// (or, without a token, a plain one whose token alone went) kept whole
    /// when its text is unchanged, otherwise rebuilt from the text.
    static func block(_ parsed: Parsed, base: NoteDocument, used: inout Set<UUID>, tokenIDs: Set<UUID>) throws -> NoteBlock {
        let baseTables = base.blocks.filter { $0.kind == .table && $0.table != nil }
        var match: NoteBlock?
        if parsed.hasToken {
            guard let id = parsed.id else { throw NoteAgentTextError.unknownTable("without an id") }
            guard let found = baseTables.first(where: { $0.id == id }) else { throw NoteAgentTextError.unknownTable(id.uuidString) }
            guard !used.contains(id) else { throw NoteAgentTextError.invalidTableEdit("The table \(id.uuidString) appears twice.") }
            match = found
        } else {
            match = baseTables.first { candidate in
                guard let id = candidate.id, !used.contains(id), !tokenIDs.contains(id), !carriesHidden(candidate) else { return false }
                return exported(candidate)?.rows.first == parsed.rows.first
            }
        }
        var table = NoteTable(headerRow: !parsed.headerOff,
                              columns: parsed.alignments.map { NoteTable.Column(align: $0) },
                              rows: try parsed.rows.map { NoteTable.Row(cells: try $0.map { try cell($0, reusing: nil) }) })
        table.makeRectangular()
        guard let match, let id = match.id else { return .table(table) }
        used.insert(id)
        // Compared as the export writes it, so its own round trip (a line
        // break read back as "\n") is never an edit.
        if let stored = exported(match), stored.rows == parsed.rows, stored.alignments == parsed.alignments,
           !parsed.hasToken || stored.headerOff == parsed.headerOff {
            return match
        }
        if !parsed.hasToken, let headerRow = match.table?.headerRow { table.headerRow = headerRow }
        return .table(table, id: id)
    }

    /// A table block as an agent reads it, parsed back.
    private static func exported(_ block: NoteBlock) -> Parsed? {
        try? parse(lines: NoteTextExport.agentTable(block).components(separatedBy: "\n"), from: 0)
    }

    /// The table carries something its text can't show: a mark, a dragged
    /// width, extras (on the table, a column, a row, a cell or an inline) or
    /// an object the text names only `[unsupported]`. A date's id is not:
    /// nothing outside the note refers to it.
    static func carriesHidden(_ block: NoteBlock) -> Bool {
        guard let table = block.table else { return false }
        return !block.extras.isEmpty || !table.extras.isEmpty
            || table.columns.contains { $0.width != nil || !$0.extras.isEmpty }
            || table.rows.contains { row in
                !row.extras.isEmpty || row.cells.contains { cell in
                    !cell.marks.isEmpty || !cell.extras.isEmpty || cell.inlines.contains { inline in
                        if case .opaque = inline.kind { return true }
                        return !inline.extras.isEmpty
                    }
                }
            }
    }

    /// An agent's cell text. `[date:YYYY-MM-DD]` becomes a date and
    /// `[unsupported]` the next object this build can't read, each keeping
    /// the whole inline `reusing` had for it (a date by its day, others in
    /// order); a token the text removes takes its object with it. Text can't
    /// tell apart objects of one kind that differ (unreadable ones, or dates on
    /// one day with different details), so keeping some of them is refused.
    /// Other text is kept as typed, without marks.
    static func cell(_ text: String, reusing: NoteTable.Cell?) throws -> NoteTable.Cell {
        var output = ""
        var inlines: [NoteInline] = []
        var dates = reusing?.inlines.filter { if case .date = $0.kind { true } else { false } } ?? []
        var unreadable = reusing?.inlines.filter { if case .opaque = $0.kind { true } else { false } } ?? []
        var kept: [NoteInline] = []
        var remainder = Substring(text.replacingOccurrences(of: String(NoteDocument.objectCharacter), with: ""))
        while let start = remainder.firstIndex(of: "[") {
            output += remainder[remainder.startIndex..<start]
            let token = remainder[start...]
            if token.hasPrefix("[unsupported]"), !unreadable.isEmpty {
                let reused = unreadable.removeFirst()
                kept.append(reused)
                inlines.append(reused)
                output.append(NoteDocument.objectCharacter)
                remainder = token.dropFirst("[unsupported]".count)
            } else if token.hasPrefix("[date:"), let close = token.firstIndex(of: "]"),
                      let day = NoteDay(isoString: String(token[token.index(start, offsetBy: 6)..<close])) {
                let reused = dates.firstIndex { $0.kind == .date(day) }.map { dates.remove(at: $0) }
                if let reused { kept.append(reused) }
                inlines.append(reused ?? NoteInline(id: UUID(), kind: .date(day)))
                output.append(NoteDocument.objectCharacter)
                remainder = token[token.index(after: close)...]
            } else {
                output += "["
                remainder = token.dropFirst()
            }
        }
        output += remainder
        for removed in dates + unreadable {
            guard kept.allSatisfy({ !sameGroup($0, removed) || ($0.kind == removed.kind && $0.extras == removed.extras) }) else {
                throw NoteAgentTextError.invalidTableEdit("This cell has several [unsupported] objects or dates on one day that differ in ways the text can't show; keep all of their tokens or remove all of them.")
            }
        }
        return NoteTable.Cell(output, inlines: inlines, extras: reusing?.extras ?? [:])
    }

    /// Two inlines the text writes alike: both unreadable, or dates on one day.
    private static func sameGroup(_ a: NoteInline, _ b: NoteInline) -> Bool {
        switch (a.kind, b.kind) {
        case (.opaque, .opaque): true
        case let (.date(x), .date(y)): x == y
        default: false
        }
    }
}

/// `update_note_table`: precise edits to one table by id.
///
/// Operations (applied in order, all or nothing):
/// - `{"op": "set_cell", "row_id", "column_id", "text"}`: the cell's own text
///   keeps it whole; a new text clears its marks, and `notices` says so.
/// - `{"op": "insert_row", "after_row_id"?: id or null (first), "cells"?: [text]}`
/// - `{"op": "insert_column", "after_column_id"?: id or null (first), "cells"?: [text, one per row], "align"?}`
/// - `{"op": "move_row", "row_id", "after_row_id": id or null (first)}`,
///   `{"op": "move_column", "column_id", "after_column_id": id or null (first)}`:
///   the line keeps its id, cells, marks, width and extras.
/// - `{"op": "delete_row", "row_id"}`, `{"op": "delete_column", "column_id"}`
/// - `{"op": "set_header_row", "value": bool}`, `{"op": "set_alignment", "column_id", "align": "left|center|right"}`
enum NoteTableAgentEdit {
    static func apply(_ operations: [[String: Any]], to original: NoteTable) throws -> NoteTable {
        var notices: [String] = []
        return try apply(operations, to: original, notices: &notices)
    }

    static func apply(_ operations: [[String: Any]], to original: NoteTable, notices: inout [String]) throws -> NoteTable {
        var table = original
        let readAgain = "Read the note again with list_notes for its current ids."
        func uuid(_ value: Any?, _ name: String) throws -> UUID {
            guard let text = value as? String, let id = UUID(uuidString: text) else {
                throw NoteAgentTextError.invalidTableEdit("\(name) must be an id from list_notes.")
            }
            return id
        }
        func row(_ value: Any?) throws -> Int {
            let id = try uuid(value, "row_id")
            guard let index = table.rows.firstIndex(where: { $0.id == id }) else {
                throw NoteAgentTextError.invalidTableEdit("No row has id \(id.uuidString). \(readAgain)")
            }
            return index
        }
        func column(_ value: Any?) throws -> Int {
            let id = try uuid(value, "column_id")
            guard let index = table.columns.firstIndex(where: { $0.id == id }) else {
                throw NoteAgentTextError.invalidTableEdit("No column has id \(id.uuidString). \(readAgain)")
            }
            return index
        }
        func texts(_ value: Any?, count: Int) throws -> [String] {
            guard let value else { return Array(repeating: "", count: count) }
            guard let list = value as? [Any], list.allSatisfy({ $0 is String }), list.count == count else {
                throw NoteAgentTextError.invalidTableEdit("cells must be \(count) strings.")
            }
            return list.compactMap { $0 as? String }
        }
        /// Where a moved line goes: after the line `name` names in `ids`, or
        /// first for null. The key is required: a typo must not move a row
        /// above the header.
        func position(_ operation: [String: Any], _ name: String, in ids: [UUID]) throws -> Int {
            guard let after = operation[name] else {
                throw NoteAgentTextError.invalidTableEdit("\(operation["op"] ?? "A move") needs \(name): an id, or null to move it first.")
            }
            guard !(after is NSNull) else { return 0 }
            let id = try uuid(after, name)
            guard let index = ids.firstIndex(of: id) else {
                throw NoteAgentTextError.invalidTableEdit("No other line has id \(id.uuidString) (a line can't move after itself). \(readAgain)")
            }
            return index + 1
        }
        func inlineOnly(_ text: String) throws -> String {
            guard !text.contains("\u{FFFC}") else { throw NoteAgentTextError.invalidTableEdit("A cell can't hold object characters.") }
            return text
        }
        for operation in operations {
            guard let op = operation["op"] as? String else {
                throw NoteAgentTextError.invalidTableEdit("Each operation needs an \"op\".")
            }
            switch op {
            case "set_cell":
                let r = try row(operation["row_id"]), c = try column(operation["column_id"])
                guard let text = operation["text"] as? String else { throw NoteAgentTextError.invalidTableEdit("set_cell needs text.") }
                let original = table.rows[r].cells[c]
                guard try inlineOnly(text) != NoteTextExport.agentInlineText(original.block) else { break }
                table.rows[r].cells[c] = try NoteAgentTableText.cell(text, reusing: original)
                let kinds = NoteMark.Kind.allCases.filter { kind in original.marks.contains { $0.kind == kind } }.map(\.rawValue)
                if let last = kinds.last {
                    let named = kinds.count > 1 ? kinds.dropLast().joined(separator: ", ") + " and " + last : last
                    notices.append(named.prefix(1).uppercased() + named.dropFirst() + " in the cell at row \(table.rows[r].id.uuidString), column \(table.columns[c].id.uuidString) "
                                   + (kinds.count > 1 ? "were" : "was") + " cleared because its text changed.")
                }
            case "insert_row":
                let at = try operation["after_row_id"].flatMap { $0 is NSNull ? nil : $0 }.map { try row($0) + 1 } ?? 0
                let cells = try texts(operation["cells"], count: table.columnCount)
                table.insertRow(at: at)
                table.rows[at].cells = try cells.map { try NoteAgentTableText.cell(try inlineOnly($0), reusing: nil) }
            case "insert_column":
                let at = try operation["after_column_id"].flatMap { $0 is NSNull ? nil : $0 }.map { try column($0) + 1 } ?? 0
                let cells = try texts(operation["cells"], count: table.rowCount)
                let align = (operation["align"] as? String).flatMap(NoteTable.Alignment.init(rawValue:)) ?? .left
                table.insertColumn(at: at, align: align)
                for (index, text) in cells.enumerated() {
                    table.rows[index].cells[at] = try NoteAgentTableText.cell(try inlineOnly(text), reusing: nil)
                }
            case "move_row":
                let source = try row(operation["row_id"])
                let moving = table.rows.remove(at: source)
                table.rows.insert(moving, at: try position(operation, "after_row_id", in: table.rows.map(\.id)))
            case "move_column":
                let source = try column(operation["column_id"])
                let moving = table.columns.remove(at: source)
                let cells = table.rows.indices.map { table.rows[$0].cells.remove(at: source) }
                let at = try position(operation, "after_column_id", in: table.columns.map(\.id))
                table.columns.insert(moving, at: at)
                for index in table.rows.indices { table.rows[index].cells.insert(cells[index], at: at) }
            case "delete_row":
                guard table.removeRow(at: try row(operation["row_id"])) else {
                    throw NoteAgentTextError.invalidTableEdit("A table keeps at least one row. To delete a plain table, remove it from the body with update_note; a table with formatting the text can't show is deleted in Attic.")
                }
            case "delete_column":
                guard table.removeColumn(at: try column(operation["column_id"])) else {
                    throw NoteAgentTextError.invalidTableEdit("A table keeps at least one column. To delete a plain table, remove it from the body with update_note; a table with formatting the text can't show is deleted in Attic.")
                }
            case "set_header_row":
                guard let value = operation["value"] as? Bool else { throw NoteAgentTextError.invalidTableEdit("set_header_row needs a boolean value.") }
                table.headerRow = value
            case "set_alignment":
                let c = try column(operation["column_id"])
                guard let align = (operation["align"] as? String).flatMap(NoteTable.Alignment.init(rawValue:)) else {
                    throw NoteAgentTextError.invalidTableEdit("align must be left, center or right.")
                }
                table.columns[c].align = align
            default:
                throw NoteAgentTextError.invalidTableEdit("Unknown operation \"\(op)\".")
            }
        }
        guard table.isRectangular else { throw NoteAgentTextError.raggedTable }
        guard table.isWithinLimits else { throw NoteAgentTextError.tableTooLarge }
        return table
    }

    /// A table as `list_notes` lists it: ids to address, cells as text.
    static func serialize(_ block: NoteBlock) -> [String: Any] {
        guard let table = block.table else { return [:] }
        return [
            "table_id": block.id?.uuidString ?? "",
            "header_row": table.headerRow,
            "columns": table.columns.map { column -> [String: Any] in
                var fields: [String: Any] = ["id": column.id.uuidString, "align": column.align.rawValue]
                if let width = column.width { fields["width"] = width }
                return fields
            },
            "rows": table.rows.map { row -> [String: Any] in
                ["id": row.id.uuidString, "cells": row.cells.map { NoteTextExport.agentInlineText($0.block) }]
            }
        ]
    }
}
