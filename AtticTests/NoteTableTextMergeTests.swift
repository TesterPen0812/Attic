import XCTest
@testable import Attic

/// An agent's text rewrite of a table (`update_note`; design note
/// `ops/design/notes-tables.md`, "The stop rule fired", owner's pick:
/// refuse). The text shows cells but not marks, dragged widths, extras or
/// unreadable objects, so it can't say which line is which. A table that
/// carries any of them follows the body's rule for styled blocks: text
/// unchanged keeps it whole; anything else is refused, and the agent makes
/// the change by id with `update_note_table`. A plain table is rebuilt from
/// its text and never refused.
///
/// The fixed tables are the reviewers' (Astra R-1, R-2, R-4; Opus R-1 to
/// R-4, R-7). Each refused change is then made by id, and every hidden thing
/// must end on the line it started on. The seeded test does the same for
/// every step, judged against the generator's own record.
@MainActor
final class NoteTableTextMergeTests: XCTestCase {
    private let tableID = UUID()

    // MARK: Harness

    /// A note holding `table`, after an agent sends `body` (default: the
    /// note's own body) and `title`, through the production parser.
    private func update(_ table: NoteTable, title: String = "T", body: ((NoteDocument) -> String)? = nil,
                        blocks: [NoteBlock] = []) throws -> NoteDocument {
        let base = NoteDocument(blocks: [.text("T")] + blocks + [.table(table, id: tableID)])
        return try NoteAgentTextParser.document(title: title, body: body?(base) ?? NoteTextExport.agentBody(base), base: base)
    }

    /// `old` rewritten into `truth`'s text.
    private func rewrite(_ old: NoteTable, to truth: NoteTable) throws -> NoteTable {
        let document = try update(old) { _ in NoteTextExport.agentBody(NoteDocument(blocks: [.text("T"), .table(truth, id: self.tableID)])) }
        let block = try XCTUnwrap(document.blocks.first { $0.kind == .table })
        XCTAssertEqual(block.id, tableID, "the table keeps its id")
        return try XCTUnwrap(block.table)
    }

    /// The rewrite is refused with the body's own error.
    private func assertRefused(_ old: NoteTable, _ truth: NoteTable, _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try rewrite(old, to: truth), message, file: file, line: line) {
            XCTAssertEqual($0 as? NoteAgentTextError, .lossyFormatting, message, file: file, line: line)
        }
    }

    /// The agent text of a table, as `list_notes` shows it.
    private func wire(_ table: NoteTable) -> String {
        NoteTextExport.agentTable(.table(table, id: tableID))
    }

    /// Each cell as the agent reads it.
    private static func texts(_ table: NoteTable) -> [[String]] {
        table.rows.map { $0.cells.map { NoteTextExport.agentInlineText($0.block) } }
    }

    /// Anything the text can't show (the test's own reading of the design).
    private static func carries(_ table: NoteTable) -> Bool {
        !table.extras.isEmpty
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

    /// `actual` is `truth`, every id, mark, width and extra in its place; a
    /// line the truth added may have any new id.
    private static func assertSame(_ actual: NoteTable, _ truth: NoteTable, old: NoteTable, _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        var expected = truth
        let oldRows = Set(old.rows.map(\.id)), oldColumns = Set(old.columns.map(\.id))
        if actual.rows.count == truth.rows.count {
            for index in truth.rows.indices where !oldRows.contains(truth.rows[index].id) && !oldRows.contains(actual.rows[index].id) {
                expected.rows[index].id = actual.rows[index].id
            }
        }
        if actual.columns.count == truth.columns.count {
            for index in truth.columns.indices where !oldColumns.contains(truth.columns[index].id) && !oldColumns.contains(actual.columns[index].id) {
                expected.columns[index].id = actual.columns[index].id
            }
        }
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    // MARK: Building tables

    private func bold(_ table: inout NoteTable, _ row: Int, _ column: Int) {
        table.rows[row].cells[column].marks = [NoteMark(.bold, offset: 0, length: table.rows[row].cells[column].text.utf16.count)]
    }

    private func edit(_ table: inout NoteTable, _ row: Int, _ column: Int, _ text: String) {
        table.rows[row].cells[column] = NoteTable.Cell(text, extras: table.rows[row].cells[column].extras)
    }

    private func swapColumns(_ table: inout NoteTable, _ a: Int, _ b: Int) {
        table.columns.swapAt(a, b)
        for index in table.rows.indices { table.rows[index].cells.swapAt(a, b) }
    }

    private func date(_ iso: String, extras: [String: NoteJSON] = [:]) -> NoteTable.Cell {
        NoteTable.Cell(String(NoteDocument.objectCharacter), inlines: [NoteInline(id: UUID(), kind: .date(NoteDay(isoString: iso)!), extras: extras)])
    }

    private func id(_ table: NoteTable, row: Int) -> String { table.rows[row].id.uuidString }
    private func id(_ table: NoteTable, column: Int) -> String { table.columns[column].id.uuidString }

    // MARK: The reviewers' tables: refused, then done by id

    /// Opus R-3: sorted by name and renumbered. The `#` column reads the same, but the rows moved.
    func testSortingAndRenumberingAFormattedTableIsRefusedAndDoneByID() throws {
        var old = NoteTable(texts: [["#", "Name", "Due"], ["1", "a", ""], ["2", "b", ""], ["3", "c", ""]])
        for (row, iso) in [(1, "2026-12-01"), (2, "2026-12-02"), (3, "2026-12-03")] {
            old.rows[row].cells[2] = date(iso)
            old.rows[row].extras = ["owner": .string("r\(row)")]
        }
        var truth = old
        truth.rows.swapAt(1, 3)
        edit(&truth, 1, 0, "1")
        edit(&truth, 3, 0, "3")
        assertRefused(old, truth)
        let byID = try NoteTableAgentEdit.apply([
            ["op": "move_row", "row_id": id(old, row: 3), "after_row_id": id(old, row: 0)],
            ["op": "move_row", "row_id": id(old, row: 1), "after_row_id": id(old, row: 2)],
            ["op": "set_cell", "row_id": id(old, row: 3), "column_id": id(old, column: 0), "text": "1"],
            ["op": "set_cell", "row_id": id(old, row: 1), "column_id": id(old, column: 0), "text": "3"]
        ], to: old)
        XCTAssertEqual(byID, truth, "each row keeps its id, extras and date")
    }

    /// Astra R-1: rows and columns swapped at once, where the swapped columns read as before.
    func testSwappingRowsAndColumnsOfAFormattedTableIsRefusedAndDoneByID() throws {
        var old = NoteTable(texts: [["H", "H", "Tag"], ["A", "B", "x"], ["B", "A", "y"]])
        bold(&old, 1, 0)
        old.columns[0].width = 140
        var truth = old
        truth.rows.swapAt(1, 2)
        swapColumns(&truth, 0, 1)
        assertRefused(old, truth)
        let byID = try NoteTableAgentEdit.apply([
            ["op": "move_row", "row_id": id(old, row: 2), "after_row_id": id(old, row: 0)],
            ["op": "move_column", "column_id": id(old, column: 1), "after_column_id": NSNull()]
        ], to: old)
        XCTAssertEqual(byID, truth, "the bold cell and the width follow their column and row")
    }

    /// Opus R-2: a unique row deleted and a twin moved into its place.
    func testATwinMovedIntoADeletedRowsPlaceIsRefusedAndDoneByID() throws {
        var old = NoteTable(texts: [["K", "V"], ["a", "1"], ["x", "9"], ["b", "2"], ["d", "d"], ["d", "d"], ["c", "3"]])
        old.rows[2].extras = ["owner": .string("x")]
        old.rows[2].cells[1].extras = ["note": .string("x9")]
        var truth = old
        truth.rows.remove(at: 2)
        truth.rows.insert(truth.rows.remove(at: 3), at: 2)
        assertRefused(old, truth)
        let byID = try NoteTableAgentEdit.apply([
            ["op": "delete_row", "row_id": id(old, row: 2)],
            ["op": "move_row", "row_id": id(old, row: 4), "after_row_id": id(old, row: 1)]
        ], to: old)
        XCTAssertEqual(byID, truth)
    }

    /// Opus R-4: a formatted table needs its token. Without it (renamed or not) the update is refused;
    /// a plain table without its token is kept when it reads the same, and replaced when it doesn't.
    func testDroppingAFormattedTablesTokenIsRefused() throws {
        var formatted = NoteTable(texts: [["Pillar", "What"], ["Integrity", "Encrypted"]])
        formatted.columns[1].width = 150
        let tokenless: (NoteDocument) -> String = { NoteTextExport.agentBody($0).components(separatedBy: "\n").filter { !$0.hasPrefix("<!--") }.joined(separator: "\n") }
        let renamed: (NoteDocument) -> String = { tokenless($0).replacingOccurrences(of: "| Pillar |", with: "| Pillars |") }
        for body in [tokenless, renamed] {
            XCTAssertThrowsError(try update(formatted, body: body)) { XCTAssertEqual($0 as? NoteAgentTextError, .lossyFormatting) }
        }
        let plain = NoteTable(texts: [["Pillar", "What"], ["Integrity", "Encrypted"]])
        XCTAssertEqual(try update(plain, body: tokenless).blocks.last, .table(plain, id: tableID), "a plain table without its token is kept")
        let replaced = try update(plain, body: renamed)
        XCTAssertFalse(replaced.blocks.contains { $0.id == tableID }, "a renamed plain table without its token is a new table")
        XCTAssertEqual(replaced.blocks.last?.table?.texts.first, ["Pillars", "What"])
    }

    /// A formatted table can't be deleted, have its header row turned off, or be realigned through text.
    func testEveryOtherTextChangeToAFormattedTableIsRefused() throws {
        var table = NoteTable(texts: [["A", "B"], ["a", "b"]])
        bold(&table, 1, 1)
        XCTAssertThrowsError(try update(table, body: { _ in "" }), "the table removed")
        var realigned = table
        realigned.columns[1].align = .right
        assertRefused(table, realigned, "an alignment")
        let headerOff = { (base: NoteDocument) in NoteTextExport.agentBody(base).replacingOccurrences(of: " -->", with: " headerRow=false -->") }
        XCTAssertThrowsError(try update(table, body: headerOff), "the header row") { XCTAssertEqual($0 as? NoteAgentTextError, .lossyFormatting) }
        // By id, each is kept whole.
        let byID = try NoteTableAgentEdit.apply([
            ["op": "set_alignment", "column_id": id(table, column: 1), "align": "right"],
            ["op": "set_header_row", "value": false]
        ], to: table)
        XCTAssertEqual(byID.rows, table.rows)
        XCTAssertEqual(byID.columns.map(\.align), [.left, .right])
    }

    // MARK: Objects in cells

    /// Astra R-2, Opus R-1: text added beside a date with extras or an unreadable object keeps the object whole.
    func testSetCellKeepsADateAndAnUnreadableObjectWhole() throws {
        let day = NoteDay(isoString: "2026-12-01")!
        let dated = NoteInline(id: UUID(), kind: .date(day), extras: ["hint": .string("keep")])
        let unreadable = NoteInline(id: UUID(), kind: .opaque(.object(["kind": .string("future"), "v": .int(2)])))
        let object = String(NoteDocument.objectCharacter)
        var table = NoteTable(texts: [["Due", "Other"], ["", ""]])
        table.rows[1].cells[0] = NoteTable.Cell("Due " + object, inlines: [dated])
        table.rows[1].cells[1] = NoteTable.Cell(object + " note", inlines: [unreadable])
        XCTAssertEqual(Self.texts(table)[1], ["Due [date:2026-12-01]", "[unsupported] note"])
        let row = id(table, row: 1)
        let edited = try NoteTableAgentEdit.apply([
            ["op": "set_cell", "row_id": row, "column_id": id(table, column: 0), "text": "Due soon [date:2026-12-01]"],
            ["op": "set_cell", "row_id": row, "column_id": id(table, column: 1), "text": "[unsupported] note!"]
        ], to: table)
        XCTAssertEqual(edited.rows[1].cells[0], NoteTable.Cell("Due soon " + object, inlines: [dated]), "the date keeps its id and extras")
        XCTAssertEqual(edited.rows[1].cells[1], NoteTable.Cell(object + " note!", inlines: [unreadable]), "the unreadable object is kept")
        // Removing a token removes its object: a deletion the agent wrote.
        let removed = try NoteTableAgentEdit.apply([
            ["op": "set_cell", "row_id": row, "column_id": id(table, column: 0), "text": "Due soon"],
            ["op": "set_cell", "row_id": row, "column_id": id(table, column: 1), "text": "note"]
        ], to: table)
        XCTAssertEqual(removed.rows[1].cells.map(\.inlines), [[], []])
        // Through text, the same edit is refused (the table carries what the text can't show).
        var truth = table
        edit(&truth, 1, 1, "x")
        assertRefused(table, truth)
    }

    /// Opus R-7: set_cell with the cell's own text keeps its marks; a new text clears them (the result says so).
    func testSetCellKeepsMarksOnUnchangedText() throws {
        var table = NoteTable(texts: [["A"], ["bold words"]])
        table.rows[1].cells[0].marks = [NoteMark(.bold, offset: 0, length: 4), NoteMark(.italic, offset: 5, length: 5)]
        let same = try NoteTableAgentEdit.apply([["op": "set_cell", "row_id": id(table, row: 1), "column_id": id(table, column: 0), "text": "bold words"]], to: table)
        XCTAssertEqual(same, table)
        let changed = try NoteTableAgentEdit.apply([["op": "set_cell", "row_id": id(table, row: 1), "column_id": id(table, column: 0), "text": "plain words"]], to: table)
        XCTAssertEqual(changed.rows[1].cells[0], NoteTable.Cell("plain words"))
    }

    // MARK: Unchanged text

    /// A table the agent didn't touch is kept exactly, whatever it carries, including
    /// a line break the export writes as `<br>` (Astra R-4) and a title-only update.
    func testAnUntouchedTableIsKeptExactly() throws {
        var twins = NoteTable(texts: [["Name", "Status"], ["a", "x"], ["a", "x"], ["b", "y"]])
        bold(&twins, 1, 0)
        var sparseHeader = NoteTable(texts: [["Title", "", ""], ["one", "", ""], ["two", "", ""]])
        sparseHeader.columns[1].width = 90
        sparseHeader.columns[2].width = 110
        var fresh = NoteTable.blank()
        fresh.columns[0].width = 140
        var lineBreak = NoteTable(texts: [["H"], ["a\r\nb"]])
        lineBreak.rows[1].cells[0].marks = [NoteMark(.bold, offset: 0, length: 1)]
        var headerless = NoteTable(texts: [["a", "b"]], headerRow: false)
        headerless.rows[0].extras = ["owner": .string("r0")]
        for (name, table) in [("twins", twins), ("sparse header", sparseHeader), ("fresh with a width", fresh),
                              ("fresh", NoteTable.blank()), ("a line break", lineBreak), ("no header row", headerless)] {
            let changes: [(String, String, (NoteDocument) -> String)] = [
                ("a paragraph", "T", { NoteTextExport.agentBody($0).replacingOccurrences(of: "Intro", with: "Intro, edited") }),
                ("the title", "New title", { NoteTextExport.agentBody($0) })
            ]
            for (change, title, body) in changes {
                XCTAssertNoThrow(try {
                    let document = try update(table, title: title, body: body, blocks: [.text("Intro")])
                    XCTAssertEqual(document.blocks.last, .table(table, id: tableID), "\(name), \(change): kept whole")
                }(), "\(name), \(change)")
            }
        }
    }

    /// A plain note holding one formatted table is still checked (the body's plain-note path).
    func testAPlainNoteHoldingAFormattedTableIsChecked() throws {
        var table = NoteTable(texts: [["Item", "Status"], ["i1", "s1"]])
        table.columns[0].width = 120
        let edited = { (base: NoteDocument) in NoteTextExport.agentBody(base).replacingOccurrences(of: "| s1 |", with: "| done |") }
        XCTAssertThrowsError(try update(table, body: edited, blocks: [.text("Plain intro")])) {
            XCTAssertEqual($0 as? NoteAgentTextError, .lossyFormatting)
        }
    }

    // MARK: Plain tables

    /// A plain table is rebuilt from its text and never refused: moves, edits, rows and columns at once.
    func testAPlainTableIsRebuiltFromItsText() throws {
        let plain = NoteTable(texts: [["A", "B", "C"], ["a1", "b1", "c1"], ["a2", "b2", "c2"], ["a2", "b2", "c2"]])
        var truth = plain
        truth.rows.swapAt(1, 3)
        swapColumns(&truth, 0, 2)
        edit(&truth, 2, 1, "b edited [date:2026-12-05]")
        truth.columns[1].align = .center
        truth.rows.append(NoteTable.Row(cells: [NoteTable.Cell("new"), NoteTable.Cell(""), NoteTable.Cell("")]))
        let actual = try rewrite(plain, to: truth)
        XCTAssertEqual(Self.texts(actual), Self.texts(truth))
        XCTAssertEqual(actual.columns.map(\.align), truth.columns.map(\.align))
        XCTAssertEqual(actual.rows[2].cells[1].inlines.count, 1, "a date token is a date")
        XCTAssertFalse(Self.carries(actual))
    }

    // MARK: The refusal

    /// The refusal is the body's own error and names the id route and its operations.
    func testTheRefusalTellsTheAgentHowToMakeTheChange() {
        let message = NoteAgentTextError.lossyFormatting.errorDescription ?? ""
        for words in ["update_note_table", "unchanged", "move a row or column"] {
            XCTAssertTrue(message.contains(words), "\(words): \(message)")
        }
    }

    // MARK: Seeded rewrites

    /// The generator's operations, applied to a table with ids; it records the truth.
    private struct Generator {
        var state: UInt64
        var counter = 0

        mutating func pick(_ count: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(count, 1)))
        }

        mutating func fresh() -> String {
            counter += 1
            return "w\(counter)"
        }

        mutating func day() -> NoteDay {
            counter += 1
            return NoteDay(year: 2026 + counter / 300, month: 1 + (counter / 28) % 12, day: 1 + counter % 28)!
        }
    }

    private enum Operation {
        case moveRow(Int, Int), moveColumn(Int, Int)
        case insertRow(Int, [String]), insertColumn(Int, [String])
        case deleteRow(Int), deleteColumn(Int)
        case edit(Int, Int, String)

        /// The generator's record: the operation on the table with ids.
        func apply(to table: inout NoteTable) {
            switch self {
            case let .moveRow(from, to): table.rows.insert(table.rows.remove(at: from), at: to)
            case let .moveColumn(from, to):
                table.columns.insert(table.columns.remove(at: from), at: to)
                for row in table.rows.indices { table.rows[row].cells.insert(table.rows[row].cells.remove(at: from), at: to) }
            case let .insertRow(at, texts): table.rows.insert(NoteTable.Row(cells: texts.map { NoteTable.Cell($0) }), at: at)
            case let .insertColumn(at, texts):
                table.columns.insert(NoteTable.Column(), at: at)
                for row in table.rows.indices { table.rows[row].cells.insert(NoteTable.Cell(texts[row]), at: at) }
            case let .deleteRow(at): table.rows.remove(at: at)
            case let .deleteColumn(at):
                table.columns.remove(at: at)
                for row in table.rows.indices { table.rows[row].cells.remove(at: at) }
            case let .edit(row, column, text):
                // set_cell's documented result: the text, the cell's extras, no marks.
                table.rows[row].cells[column] = NoteTable.Cell(text, extras: table.rows[row].cells[column].extras)
            }
        }

        /// The same operation by id, on `table` as it stands.
        func byID(on table: NoteTable) -> [[String: Any]] {
            let rows = table.rows.map(\.id.uuidString), columns = table.columns.map(\.id.uuidString)
            func after(_ ids: [String], moving from: Int?, to index: Int) -> Any {
                var remaining = ids
                if let from { remaining.remove(at: from) }
                return index == 0 ? NSNull() : remaining[index - 1]
            }
            switch self {
            case let .moveRow(from, to): return [["op": "move_row", "row_id": rows[from], "after_row_id": after(rows, moving: from, to: to)]]
            case let .moveColumn(from, to): return [["op": "move_column", "column_id": columns[from], "after_column_id": after(columns, moving: from, to: to)]]
            case let .insertRow(at, texts): return [["op": "insert_row", "after_row_id": after(rows, moving: nil, to: at), "cells": texts]]
            case let .insertColumn(at, texts):
                return [["op": "insert_column", "after_column_id": after(columns, moving: nil, to: at), "cells": texts, "align": "left"]]
            case let .deleteRow(at): return [["op": "delete_row", "row_id": rows[at]]]
            case let .deleteColumn(at): return [["op": "delete_column", "column_id": columns[at]]]
            case let .edit(row, column, text): return [["op": "set_cell", "row_id": rows[row], "column_id": columns[column], "text": text]]
            }
        }
    }

    private func operation(on table: NoteTable, _ g: inout Generator) -> Operation {
        let rows = table.rowCount, columns = table.columnCount
        switch g.pick(9) {
        case 0: return .moveRow(1 + g.pick(rows - 1), 1 + g.pick(rows - 1))
        case 1: return .moveColumn(g.pick(columns), g.pick(columns))
        case 2 where rows < 12:
            // A fresh row, a blank row, or a copy of another row's text.
            switch g.pick(3) {
            case 0: return .insertRow(1 + g.pick(rows), Array(repeating: "", count: columns))
            case 1: return .insertRow(1 + g.pick(rows), table.rows[g.pick(rows)].cells.map(\.displayText).map { $0.contains("[") ? "copy" : $0 })
            default: return .insertRow(1 + g.pick(rows), (0..<columns).map { _ in g.fresh() })
            }
        case 3 where columns < 6: return .insertColumn(g.pick(columns + 1), (0..<rows).map { _ in g.fresh() })
        case 4 where rows > 3: return .deleteRow(1 + g.pick(rows - 1))
        case 5 where columns > 2: return .deleteColumn(g.pick(columns))
        default: return .edit(g.pick(rows), g.pick(columns), g.fresh())
        }
    }

    /// Adds something the text can't show, anywhere, or a plain date.
    private func decorate(_ table: inout NoteTable, _ g: inout Generator) {
        let row = g.pick(table.rowCount), column = g.pick(table.columnCount)
        let object = String(NoteDocument.objectCharacter)
        switch g.pick(7) {
        case 0 where !table.rows[row].cells[column].text.isEmpty && table.rows[row].cells[column].inlines.isEmpty: bold(&table, row, column)
        case 1: table.rows[row].cells[column] = NoteTable.Cell(object, inlines: [NoteInline(id: UUID(), kind: .date(g.day()))])
        case 2: table.rows[row].cells[column] = NoteTable.Cell(object, inlines: [NoteInline(id: UUID(), kind: .date(g.day()), extras: ["hint": .string(g.fresh())])])
        case 3: table.rows[row].cells[column] = NoteTable.Cell(object + " " + g.fresh(), inlines: [NoteInline(id: UUID(), kind: .opaque(.string(g.fresh())))])
        case 4: table.rows[row].extras = ["owner": .string(g.fresh())]
        case 5: table.rows[row].cells[column].extras = ["note": .string(g.fresh())]
        default: table.columns[column].width = Double(80 + g.pick(100))
        }
    }

    /// The table without anything the text can't show (dates stay, without extras).
    private func plain(_ table: NoteTable) -> NoteTable {
        var copy = table
        for column in copy.columns.indices { copy.columns[column].width = nil; copy.columns[column].extras = [:] }
        for row in copy.rows.indices {
            copy.rows[row].extras = [:]
            for column in copy.columns.indices {
                var cell = copy.rows[row].cells[column]
                cell.marks = []
                cell.extras = [:]
                if cell.inlines.contains(where: { if case .opaque = $0.kind { true } else { false } }) {
                    cell = NoteTable.Cell("was unreadable")
                }
                cell.inlines = cell.inlines.map { NoteInline(id: $0.id, kind: $0.kind) }
                copy.rows[row].cells[column] = cell
            }
        }
        return copy
    }

    /// One step through both routes: the text route refuses a changed table that
    /// carries anything (with `.lossyFormatting`, nothing else), keeps an unchanged one
    /// whole, and rebuilds a plain one from its text; the id route ends exactly at the
    /// generator's record. Returns the id route's table.
    private func step(_ context: String, _ current: NoteTable, _ operations: [Operation],
                      counts: inout (refused: Int, unchanged: Int, plain: Int)) throws -> NoteTable {
        var truth = current
        var byID = current
        for operation in operations {
            byID = try NoteTableAgentEdit.apply(operation.byID(on: byID), to: byID)
            operation.apply(to: &truth)
        }
        Self.assertSame(byID, truth, old: current, "\(context): by id, every hidden thing stays on its line")
        if wire(truth) == wire(current) {
            XCTAssertEqual(try? rewrite(current, to: truth), current, "\(context): unchanged text keeps the table whole")
            counts.unchanged += 1
        } else if Self.carries(current) {
            assertRefused(current, truth, "\(context): a changed table that carries something")
            counts.refused += 1
        } else {
            do {
                let actual = try rewrite(current, to: truth)
                XCTAssertEqual(Self.texts(actual), Self.texts(truth), "\(context): a plain table takes the text")
                XCTAssertEqual(actual.columns.map(\.align), truth.columns.map(\.align), "\(context)")
                XCTAssertEqual(actual.headerRow, truth.headerRow, "\(context)")
                XCTAssertFalse(Self.carries(actual), "\(context)")
                counts.plain += 1
            } catch {
                XCTFail("\(context): a plain table was refused: \(error)")
            }
        }
        return byID
    }

    /// Seeded steps of one and two operations on a table with duplicate and blank
    /// rows that gains marks, widths, dates (some with extras), unreadable objects
    /// and extras as it goes. The table evolves through the id route.
    func testSeededRewritesAreRefusedOrKeptWholeAndTheIDRouteKeepsEverything() throws {
        for seed: UInt64 in [20261116, 20261117, 20261118] {
            var g = Generator(state: seed)
            var current = NoteTable(texts: [["h1", "h2", "h3", "h4"]] + (1..<7).map { _ in (0..<4).map { _ in g.fresh() } })
            current.rows[3].cells = current.rows[2].cells   // a duplicate row
            current.rows.insert(NoteTable.Row(cells: Array(repeating: NoteTable.Cell(), count: 4)), at: 5)
            current.rows.insert(NoteTable.Row(cells: Array(repeating: NoteTable.Cell(), count: 4)), at: 6)
            var counts = (refused: 0, unchanged: 0, plain: 0)
            for index in 0..<150 {
                if g.pick(3) == 0 { decorate(&current, &g) }
                let context = "seed \(seed), step \(index)"
                let first = operation(on: current, &g)
                var single = current
                first.apply(to: &single)
                let second = operation(on: single, &g)
                _ = try step(context + ", none", current, [], counts: &counts)
                _ = try step(context + ", \(first)", current, [first], counts: &counts)
                _ = try step(context + ", plain, \(first), \(second)", plain(current), [first, second], counts: &counts)
                current = try step(context + ", \(first), \(second)", current, [first, second], counts: &counts)
            }
            XCTAssertGreaterThan(counts.refused, 100, "seed \(seed): formatted tables are exercised")
            XCTAssertGreaterThan(counts.plain, 100, "seed \(seed): plain tables are exercised")
            XCTAssertGreaterThanOrEqual(counts.unchanged, 150, "seed \(seed): unchanged tables are exercised")
            print("seed \(seed): \(counts)")
        }
    }
}
