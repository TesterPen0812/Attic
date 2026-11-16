import Foundation

/// Tables as agents read and write them (spec § 4.6).
///
/// - `list_notes` shows each table as an `<!-- attic:table id=… -->` token
///   line and a GFM pipe table, and lists its row and column ids.
/// - `update_note` keeps a table whose token it keeps and merges the
///   agent's text into it (`merge`): rows, columns and cells keep their ids,
///   marks, dates, widths and extras where the text proves which is which,
///   and an update that would lose them is refused. A pipe table without a
///   token is a new table, unless it is a table whose token alone was
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
            var merged = try merge(table, rows: parsed.rows, alignments: parsed.alignments)
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

    /// Merges an agent's rows into `table` (design: `ops/design/notes-tables.md`).
    /// The text proves only exact matches, so it keeps only what they prove:
    /// - **Unchanged:** a table whose text is unchanged is kept whole; a gap
    ///   whose old and new lines read the same, in order, keeps everything.
    /// - **Certain:** a row or column whose text is unique in both tables, as
    ///   a whole line or at the other dimension's certain lines (found in
    ///   rounds); a dimension with one line in both tables.
    /// - **Carried:** a hidden thing (a mark, a date id, a width, extras)
    ///   stays on a certain line, or on a gap of one line on each side between
    ///   the same certain neighbours. Larger equal gaps pair in place only
    ///   when they carry nothing hidden.
    /// - **Dropped** only by a pure deletion; otherwise the update is refused
    ///   (`lossyFormatting`), as is an edit to a cell with marks.
    static func merge(_ table: NoteTable, rows: [[String]], alignments: [NoteTable.Alignment]) throws -> NoteTable {
        let old = texts(table)
        let width = rows.first?.count ?? 0
        let hiddenCell = { (cell: NoteTable.Cell) in !cell.marks.isEmpty || !cell.inlines.isEmpty || !cell.extras.isEmpty }
        let rowHidden = table.rows.map { !$0.extras.isEmpty || $0.cells.contains(where: hiddenCell) }
        let columnHidden = table.columns.indices.map { column in
            table.columns[column].width != nil || !table.columns[column].extras.isEmpty
                || table.rows.contains { hiddenCell($0.cells[column]) }
        }
        // P0: what the text doesn't change isn't matched at all.
        if old == rows {
            var kept = table
            for index in kept.columns.indices where index < alignments.count { kept.columns[index].align = alignments[index] }
            return kept
        }
        var (rowMap, columnMap) = certain(old: old, new: rows)
        if !rowMap.contains(where: { $0 != nil }) && !columnMap.contains(where: { $0 != nil }) {
            // Nothing to start from: plain tables get new ids, others are refused.
            guard !rowHidden.contains(true) && !columnHidden.contains(true) else { throw NoteAgentTextError.lossyFormatting }
        } else {
            let oldColumns = table.columns.indices.map { column in old.map { $0[column] } }
            let newColumns = (0..<width).map { column in rows.map { $0[column] } }
            try pairGaps(&rowMap, oldCount: old.count, hidden: rowHidden) { old[$0] == rows[$1] }
            try pairGaps(&columnMap, oldCount: table.columnCount, hidden: columnHidden) { oldColumns[$0] == newColumns[$1] }
        }
        var merged = table
        merged.columns = (0..<width).map { index in
            var column = columnMap[index].map { table.columns[$0] } ?? NoteTable.Column()
            if index < alignments.count { column.align = alignments[index] }
            return column
        }
        merged.rows = try rows.enumerated().map { rowIndex, cells in
            let sourceRow = rowMap[rowIndex]
            var row = sourceRow.map { NoteTable.Row(id: table.rows[$0].id, cells: [], extras: table.rows[$0].extras) }
                ?? NoteTable.Row(cells: [])
            row.cells = try cells.enumerated().map { columnIndex, text in
                guard let sourceRow, let sourceColumn = columnMap[columnIndex] else { return cell(text, reusing: nil) }
                let original = table.rows[sourceRow].cells[sourceColumn]
                if old[sourceRow][sourceColumn] == text { return original }
                guard original.marks.isEmpty else { throw NoteAgentTextError.lossyFormatting }
                return cell(text, reusing: original)
            }
            return row
        }
        merged.makeRectangular()
        return merged
    }

    /// Certain rows and columns (new index → old index), in rounds: first
    /// whole lines unique in both tables; then each dimension keyed at the
    /// other's certain lines as they stood at the end of the round before,
    /// until a round adds nothing.
    static func certain(old: [[String]], new: [[String]]) -> (rows: [Int?], columns: [Int?]) {
        let oldWidth = old.first?.count ?? 0, newWidth = new.first?.count ?? 0
        let oldColumns = (0..<oldWidth).map { column in old.map { $0[column] } }
        let newColumns = (0..<newWidth).map { column in new.map { $0[column] } }
        var rows = unique(old: old, new: new, into: [Int?](repeating: nil, count: new.count))
        var columns = unique(old: oldColumns, new: newColumns, into: [Int?](repeating: nil, count: newWidth))
        if old.count == 1 && new.count == 1 { rows[0] = 0 }
        if oldWidth == 1 && newWidth == 1 { columns[0] = 0 }
        while true {
            let nextRows = unique(old: old, new: new, at: columns, into: rows)
            let nextColumns = unique(old: oldColumns, new: newColumns, at: rows, into: columns)
            guard nextRows != rows || nextColumns != columns else { return (rows, columns) }
            (rows, columns) = (nextRows, nextColumns)
        }
    }

    /// `map` plus each line not yet matched whose key is unique in both
    /// tables. The key is the whole line, or, given the other dimension's
    /// `certain` map, the line's cells at those lines in old order.
    static func unique(old: [[String]], new: [[String]], at certain: [Int?]? = nil, into map: [Int?]) -> [Int?] {
        var oldKeys: [[String]?] = old.map { $0 }, newKeys: [[String]?] = new.map { $0 }
        if let certain {
            let pairs = certain.enumerated().compactMap { newIndex, oldIndex in oldIndex.map { (new: newIndex, old: $0) } }.sorted { $0.old < $1.old }
            guard !pairs.isEmpty else { return map }
            oldKeys = old.map { line in pairs.map { line[$0.old] } }
            newKeys = new.map { line in pairs.map { line[$0.new] } }
        }
        var oldCount: [[String]: Int] = [:], newCount: [[String]: Int] = [:], oldIndex: [[String]: Int] = [:]
        for (index, key) in oldKeys.enumerated() { if let key { oldCount[key, default: 0] += 1; oldIndex[key] = index } }
        for key in newKeys { if let key { newCount[key, default: 0] += 1 } }
        var result = map
        let taken = Set(map.compactMap { $0 })
        for (index, key) in newKeys.enumerated() where result[index] == nil {
            guard let key, oldCount[key] == 1, newCount[key] == 1, let source = oldIndex[key], !taken.contains(source) else { continue }
            result[index] = source
        }
        return result
    }

    /// Left-over lines between the same two certain neighbours (or the
    /// table's edges) in both tables: one line on each side, or lines that
    /// read the `same` in order, pair in place; other equal gaps pair in
    /// place only when none of the old ones carries anything hidden. An unpaired old line with something hidden is a pure deletion
    /// only when no new line is unpaired; otherwise the update is refused.
    static func pairGaps(_ map: inout [Int?], oldCount: Int, hidden: [Bool], same: (Int, Int) -> Bool) throws {
        struct Gap: Hashable { var before: Int, after: Int }
        func gaps(_ anchors: [Int?], end: Int) -> [Gap: [Int]] {
            var next = [Int](repeating: end, count: anchors.count)
            var following = end
            for index in anchors.indices.reversed() {
                next[index] = following
                if let anchor = anchors[index] { following = anchor }
            }
            var result: [Gap: [Int]] = [:], previous = -1
            for index in anchors.indices {
                if let anchor = anchors[index] { previous = anchor; continue }
                result[Gap(before: previous, after: next[index]), default: []].append(index)
            }
            return result
        }
        let matched = Set(map.compactMap { $0 })
        let oldAnchors = (0..<oldCount).map { matched.contains($0) ? $0 : nil }
        let oldGaps = gaps(oldAnchors, end: oldCount)
        for (gap, newLines) in gaps(map, end: oldCount) {
            guard let oldLines = oldGaps[gap], oldLines.count == newLines.count,
                  oldLines.count == 1 || !oldLines.contains(where: { hidden[$0] })
                    || zip(oldLines, newLines).allSatisfy(same) else { continue }
            for (newLine, oldLine) in zip(newLines, oldLines) { map[newLine] = oldLine }
        }
        let kept = Set(map.compactMap { $0 })
        if map.contains(nil) && (0..<oldCount).contains(where: { !kept.contains($0) && hidden[$0] }) {
            throw NoteAgentTextError.lossyFormatting
        }
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
