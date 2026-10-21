import Foundation

/// Tables as agents read and write them (spec § 4.6).
///
/// - `list_notes` shows each table as an `<!-- attic:table id=… -->` token
///   line and a GFM pipe table, and lists its row and column ids.
/// - `update_note` keeps a table whose token it keeps: cell text edits and
///   added or removed rows and columns are merged into it, so unchanged
///   rows, columns and cells keep their ids and marks. A pipe table without
///   a token is a new table, unless it is a table whose token alone was
///   removed (the whole table must go for it to be deleted).
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

    /// The table block an agent's table becomes, merged into the base
    /// table it names (or, without a token, one whose token alone went).
    static func block(_ parsed: Parsed, base: NoteDocument, used: inout Set<UUID>, tokenIDs: Set<UUID>) throws -> NoteBlock {
        let baseTables = base.blocks.filter { $0.kind == .table && $0.table != nil }
        var match: NoteBlock?
        if parsed.hasToken {
            guard let id = parsed.id else { throw NoteAgentTextError.unknownTable("without an id") }
            guard let found = baseTables.first(where: { $0.id == id }) else { throw NoteAgentTextError.unknownTable(id.uuidString) }
            guard !used.contains(id) else { throw NoteAgentTextError.invalidTableEdit("The table \(id.uuidString) appears twice.") }
            match = found
        } else {
            // A token-less copy of a table whose token alone was removed.
            match = baseTables.first { candidate in
                guard let id = candidate.id, !used.contains(id), !tokenIDs.contains(id), let table = candidate.table else { return false }
                return texts(table).first == parsed.rows.first
            }
        }
        if let match, let id = match.id, let table = match.table {
            used.insert(id)
            var merged = merge(table, rows: parsed.rows, alignments: parsed.alignments)
            if parsed.hasToken { merged.headerRow = !parsed.headerOff }
            var block = NoteBlock.table(merged, id: id)
            block.extras = match.extras
            return block
        }
        var table = NoteTable(headerRow: !parsed.headerOff,
                              columns: parsed.alignments.map { NoteTable.Column(align: $0) },
                              rows: parsed.rows.map { NoteTable.Row(cells: $0.map { cell($0, reusing: nil) }) })
        table.makeRectangular()
        return .table(table)
    }

    /// The cells as agents read them (dates as `[date:YYYY-MM-DD]`).
    static func texts(_ table: NoteTable) -> [[String]] {
        table.rows.map { $0.cells.map { NoteTextExport.agentInlineText($0.block) } }
    }

    /// Merges an agent's rows into `table`: rows and columns the agent kept
    /// keep their ids (matched by their text, in order, then by position);
    /// a cell whose text is unchanged keeps its marks and dates.
    static func merge(_ table: NoteTable, rows: [[String]], alignments: [NoteTable.Alignment]) -> NoteTable {
        let old = texts(table)
        let width = rows.first?.count ?? 0
        // Columns: by header text when the header names are unique, else by position.
        let oldHeaders = old.first ?? []
        let newHeaders = rows.first ?? []
        let columnMap: [Int?] = Set(oldHeaders).count == oldHeaders.count && Set(newHeaders).count == newHeaders.count
            ? match(old: oldHeaders, new: newHeaders) : (0..<width).map { $0 < table.columnCount ? $0 : nil }
        let rowMap = match(old: old.map { $0.joined(separator: "\u{1}") }, new: rows.map { $0.joined(separator: "\u{1}") })
        var columns: [NoteTable.Column] = []
        for (index, source) in columnMap.enumerated() {
            var column = source.map { table.columns[$0] } ?? NoteTable.Column()
            if index < alignments.count { column.align = alignments[index] }
            columns.append(column)
        }
        var result: [NoteTable.Row] = []
        for (rowIndex, cells) in rows.enumerated() {
            let sourceRow = rowMap[rowIndex]
            var row = sourceRow.map { NoteTable.Row(id: table.rows[$0].id, cells: [], extras: table.rows[$0].extras) }
                ?? NoteTable.Row(cells: [])
            for (columnIndex, text) in cells.enumerated() {
                var reusing: NoteTable.Cell?
                if let sourceRow, let sourceColumn = columnMap[columnIndex] {
                    let original = table.rows[sourceRow].cells[sourceColumn]
                    if old[sourceRow][sourceColumn] == text {
                        row.cells.append(original)
                        continue
                    }
                    reusing = original
                }
                row.cells.append(cell(text, reusing: reusing))
            }
            result.append(row)
        }
        var merged = table
        merged.columns = columns
        merged.rows = result
        merged.makeRectangular()
        return merged
    }

    /// New index → old index: equal keys in order first; then, between two
    /// kept neighbours, the changed entries pair up in order (an edited row
    /// keeps its id); the rest are new.
    static func match(old: [String], new: [String]) -> [Int?] {
        var result = [Int?](repeating: nil, count: new.count)
        var cursor = 0
        for (index, key) in new.enumerated() {
            if cursor < old.count, let found = old[cursor...].firstIndex(of: key) {
                result[index] = found
                cursor = found + 1
            }
        }
        // The gaps between anchors (and before the first, after the last).
        var newStart = 0, oldStart = 0
        func pairGap(newEnd: Int, oldEnd: Int) {
            var oldIndex = oldStart
            for newIndex in newStart..<newEnd where oldIndex < oldEnd {
                result[newIndex] = oldIndex
                oldIndex += 1
            }
        }
        for (index, value) in result.enumerated() {
            guard let value else { continue }
            pairGap(newEnd: index, oldEnd: value)
            newStart = index + 1
            oldStart = value + 1
        }
        pairGap(newEnd: new.count, oldEnd: old.count)
        return result
    }

    /// An agent's cell text: `[date:YYYY-MM-DD]` becomes a date (reusing a
    /// date's id the cell had); other text is kept as typed, without marks.
    static func cell(_ text: String, reusing: NoteTable.Cell?) -> NoteTable.Cell {
        var output = ""
        var inlines: [NoteInline] = []
        var reusable = reusing?.inlines ?? []
        var remainder = Substring(text.replacingOccurrences(of: String(NoteDocument.objectCharacter), with: ""))
        while let start = remainder.range(of: "[date:") {
            output += remainder[remainder.startIndex..<start.lowerBound]
            let after = remainder[start.upperBound...]
            if let close = after.firstIndex(of: "]"), let day = NoteDay(isoString: String(after[after.startIndex..<close])) {
                let id = reusable.firstIndex(where: { $0.kind == .date(day) }).map { reusable.remove(at: $0).id } ?? UUID()
                output.append(NoteDocument.objectCharacter)
                inlines.append(NoteInline(id: id, kind: .date(day)))
                remainder = after[after.index(after: close)...]
            } else {
                output += "[date:"
                remainder = after
            }
        }
        output += remainder
        return NoteTable.Cell(output, inlines: inlines, extras: reusing?.extras ?? [:])
    }
}

/// `update_note_table`: precise edits to one table by id.
///
/// Operations (applied in order, all or nothing):
/// - `{"op": "set_cell", "row_id", "column_id", "text"}`
/// - `{"op": "insert_row", "after_row_id"?: id or null (first), "cells"?: [text]}`
/// - `{"op": "insert_column", "after_column_id"?: id or null (first), "cells"?: [text, one per row], "align"?}`
/// - `{"op": "delete_row", "row_id"}`, `{"op": "delete_column", "column_id"}`
/// - `{"op": "set_header_row", "value": bool}`, `{"op": "set_alignment", "column_id", "align": "left|center|right"}`
enum NoteTableAgentEdit {
    static func apply(_ operations: [[String: Any]], to original: NoteTable) throws -> NoteTable {
        var table = original
        func uuid(_ value: Any?, _ name: String) throws -> UUID {
            guard let text = value as? String, let id = UUID(uuidString: text) else {
                throw NoteAgentTextError.invalidTableEdit("\(name) must be an id from list_notes.")
            }
            return id
        }
        func row(_ value: Any?) throws -> Int {
            let id = try uuid(value, "row_id")
            guard let index = table.rows.firstIndex(where: { $0.id == id }) else {
                throw NoteAgentTextError.invalidTableEdit("No row has id \(id.uuidString).")
            }
            return index
        }
        func column(_ value: Any?) throws -> Int {
            let id = try uuid(value, "column_id")
            guard let index = table.columns.firstIndex(where: { $0.id == id }) else {
                throw NoteAgentTextError.invalidTableEdit("No column has id \(id.uuidString).")
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
                table.rows[r].cells[c] = NoteAgentTableText.cell(try inlineOnly(text), reusing: table.rows[r].cells[c])
            case "insert_row":
                let at = try operation["after_row_id"].flatMap { $0 is NSNull ? nil : $0 }.map { try row($0) + 1 } ?? 0
                let cells = try texts(operation["cells"], count: table.columnCount)
                table.insertRow(at: at)
                table.rows[at].cells = try cells.map { NoteAgentTableText.cell(try inlineOnly($0), reusing: nil) }
            case "insert_column":
                let at = try operation["after_column_id"].flatMap { $0 is NSNull ? nil : $0 }.map { try column($0) + 1 } ?? 0
                let cells = try texts(operation["cells"], count: table.rowCount)
                let align = (operation["align"] as? String).flatMap(NoteTable.Alignment.init(rawValue:)) ?? .left
                table.insertColumn(at: at, align: align)
                for (index, text) in cells.enumerated() {
                    table.rows[index].cells[at] = NoteAgentTableText.cell(try inlineOnly(text), reusing: nil)
                }
            case "delete_row":
                guard table.removeRow(at: try row(operation["row_id"])) else {
                    throw NoteAgentTextError.invalidTableEdit("A table keeps at least one row; delete the table with update_note instead.")
                }
            case "delete_column":
                guard table.removeColumn(at: try column(operation["column_id"])) else {
                    throw NoteAgentTextError.invalidTableEdit("A table keeps at least one column; delete the table with update_note instead.")
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
