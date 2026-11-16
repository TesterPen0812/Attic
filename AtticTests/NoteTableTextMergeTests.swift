import XCTest
@testable import Attic

/// An agent's text rewrite of a table (`update_note`; design note
/// `ops/design/notes-tables.md`, deep fix 4). The text shows cells but not
/// the hidden things (marks, date ids, widths, extras), so a rewrite keeps
/// each hidden thing on the line it belongs to, or it is refused. Never a
/// silent loss.
///
/// The fixed tables are the reviewers' (Opus R-1 to R-4, Dot R-1, Dot R-3)
/// and the builder's paper traces (cases 9, 9b and 10). The seeded test
/// judges every accepted rewrite against the generator's own record of
/// what it did, and checks that plain tables and single operations are
/// never refused.
@MainActor
final class NoteTableTextMergeTests: XCTestCase {
    private let tableID = UUID()

    // MARK: Harness

    /// `old` rewritten into `truth`'s text, through the production parser.
    private func rewrite(_ old: NoteTable, to truth: NoteTable) throws -> NoteTable {
        let base = NoteDocument(blocks: [.text("T"), .table(old, id: tableID)])
        let body = NoteTextExport.agentBody(NoteDocument(blocks: [.text("T"), .table(truth, id: tableID)]))
        let document = try NoteAgentTextParser.document(title: "T", body: body, base: base)
        let block = try XCTUnwrap(document.blocks.first { $0.kind == .table })
        XCTAssertEqual(block.id, tableID)
        return try XCTUnwrap(block.table)
    }

    private enum Outcome { case kept, refused }

    /// Rewrites `old` into `truth` and judges it. `expect` nil: kept or
    /// refused, but never a silent loss.
    @discardableResult
    private func check(_ old: NoteTable, _ truth: NoteTable, expect: Outcome?,
                       file: StaticString = #filePath, line: UInt = #line) -> NoteTable? {
        let actual: NoteTable
        do {
            actual = try rewrite(old, to: truth)
        } catch {
            XCTAssertEqual(error as? NoteAgentTextError, .lossyFormatting, "a refusal is the body's own error", file: file, line: line)
            if expect == .kept { XCTFail("refused: \(error)", file: file, line: line) }
            return nil
        }
        if expect == .refused { XCTFail("accepted; expected a refusal", file: file, line: line) }
        Self.assertFaithful(old: old, truth: truth, actual: actual, file: file, line: line)
        return actual
    }

    private static func hidden(_ cell: NoteTable.Cell) -> Bool {
        !cell.marks.isEmpty || !cell.inlines.isEmpty || !cell.extras.isEmpty
    }

    private static func carries(_ row: NoteTable.Row) -> Bool {
        !row.extras.isEmpty || row.cells.contains(where: hidden)
    }

    private struct ColumnView: Equatable {
        var width: Double?
        var extras: [String: NoteJSON]
        var cells: [NoteTable.Cell]
        var carries: Bool { width != nil || !extras.isEmpty || cells.contains(where: NoteTableTextMergeTests.hidden) }
    }

    private static func column(_ index: Int, of table: NoteTable) -> ColumnView {
        ColumnView(width: table.columns[index].width, extras: table.columns[index].extras,
                   cells: table.rows.map { $0.cells[index] })
    }

    /// The oracle (lead, 16 Nov): every row and column of the truth that
    /// carries a hidden thing has its id, extras, width and cells on the line
    /// it became, or on a line with identical text and identical hidden
    /// things; no hidden thing appears anywhere else. Plain lines' ids are
    /// not protected: a plain gap pairs in place by design.
    private static func assertFaithful(old: NoteTable, truth: NoteTable, actual: NoteTable,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(NoteAgentTableText.texts(actual), NoteAgentTableText.texts(truth), "the text is the agent's", file: file, line: line)
        XCTAssertEqual(actual.columns.map(\.align), truth.columns.map(\.align), file: file, line: line)
        // Rows.
        for row in actual.rows {
            let expected = truth.rows.first { $0.id == row.id } ?? old.rows.first { $0.id == row.id }
            guard carries(row) || expected.map(carries) == true else { continue }
            guard let expected else {
                XCTFail("hidden things on a row that is new: \(row)", file: file, line: line); continue
            }
            XCTAssertEqual(row.cells, expected.cells, "a row's hidden things follow it", file: file, line: line)
            XCTAssertEqual(row.extras, expected.extras, "a row's extras follow it", file: file, line: line)
        }
        let actualRowIDs = Set(actual.rows.map(\.id)), oldRowIDs = Set(old.rows.map(\.id))
        for row in truth.rows where oldRowIDs.contains(row.id) && carries(row) {
            XCTAssertTrue(actualRowIDs.contains(row.id), "a row with hidden things kept its id: \(row)", file: file, line: line)
        }
        // Columns.
        for index in actual.columns.indices {
            let id = actual.columns[index].id
            let view = column(index, of: actual)
            let expected = truth.columns.firstIndex { $0.id == id }.map { column($0, of: truth) }
                ?? old.columns.firstIndex { $0.id == id }.map { column($0, of: old) }
            guard view.carries || expected?.carries == true else { continue }
            guard let expected else {
                XCTFail("hidden things on a column that is new: \(view)", file: file, line: line); continue
            }
            XCTAssertEqual(view.width, expected.width, "a column's width follows it", file: file, line: line)
            XCTAssertEqual(view.extras, expected.extras, file: file, line: line)
            XCTAssertEqual(view.cells.map(\.marks), expected.cells.map(\.marks), "a column's marks follow it", file: file, line: line)
            XCTAssertEqual(view.cells.map(\.inlines), expected.cells.map(\.inlines), file: file, line: line)
        }
        let actualColumnIDs = Set(actual.columns.map(\.id)), oldColumnIDs = Set(old.columns.map(\.id))
        for index in truth.columns.indices where oldColumnIDs.contains(truth.columns[index].id) && column(index, of: truth).carries {
            XCTAssertTrue(actualColumnIDs.contains(truth.columns[index].id), "a column with hidden things kept its id", file: file, line: line)
        }
    }

    // MARK: Building tables

    private func bold(_ table: inout NoteTable, _ row: Int, _ column: Int) {
        table.rows[row].cells[column].marks = [NoteMark(.bold, offset: 0, length: table.rows[row].cells[column].text.utf16.count)]
    }

    private func edit(_ table: inout NoteTable, _ row: Int, _ column: Int, _ text: String) {
        table.rows[row].cells[column] = NoteTable.Cell(text)
    }

    private func swapColumns(_ table: inout NoteTable, _ a: Int, _ b: Int) {
        table.columns.swapAt(a, b)
        for index in table.rows.indices { table.rows[index].cells.swapAt(a, b) }
    }

    private func insertRow(_ table: inout NoteTable, at index: Int, _ texts: [String]) {
        table.rows.insert(NoteTable.Row(cells: texts.map { NoteTable.Cell($0) }), at: index)
    }

    private func insertColumn(_ table: inout NoteTable, at index: Int, _ texts: [String]) {
        table.columns.insert(NoteTable.Column(), at: index)
        for row in table.rows.indices { table.rows[row].cells.insert(NoteTable.Cell(texts[row]), at: index) }
    }

    private func deleteColumn(_ table: inout NoteTable, _ index: Int) {
        table.columns.remove(at: index)
        for row in table.rows.indices { table.rows[row].cells.remove(at: index) }
    }

    // MARK: The reviewers' tables

    /// Opus R-1: swap two rows and fix a typo in another row.
    func testMovingRowsAndEditingAnotherRowKeepsEveryRowsIdentity() {
        var old = NoteTable(texts: [["Name", "Note"], ["A", "a1"], ["B", "b1"], ["C", "c1"], ["D", "d1"]])
        bold(&old, 1, 0)
        bold(&old, 4, 0)
        var truth = old
        truth.rows.swapAt(1, 2)
        edit(&truth, 4, 1, "d2")
        let actual = check(old, truth, expect: .kept)
        XCTAssertEqual(actual?.rows.map(\.id), truth.rows.map(\.id), "the moved rows and the edited row keep their ids")
    }

    /// Opus R-2: delete the first of two identical rows; the second keeps its own id and plain cells.
    func testDeletingTheFirstOfTwoIdenticalRowsKeepsTheSecond() {
        var old = NoteTable(texts: [["Name", "Status"], ["TBD", "TBD"], ["R", "ready"], ["TBD", "TBD"], ["S", "typo"]])
        bold(&old, 1, 0)
        var truth = old
        truth.rows.remove(at: 1)
        edit(&truth, 3, 1, "fixed")
        let actual = check(old, truth, expect: .kept)
        XCTAssertEqual(actual?.rows.map(\.id), truth.rows.map(\.id))
    }

    /// Opus R-3: move columns and rename one in the same update.
    func testMovingColumnsAndRenamingOneKeepsEveryColumn() {
        var old = NoteTable(texts: [["A", "B", "C", "D"], ["a1", "b1", "c1", "d1"], ["a2", "b2", "c2", "d2"]])
        old.columns[3].width = 140
        old.columns[0].width = 90
        bold(&old, 1, 3)
        bold(&old, 2, 3)
        var truth = old
        swapColumns(&truth, 0, 1)
        edit(&truth, 0, 3, "D renamed")
        let actual = check(old, truth, expect: .kept)
        XCTAssertEqual(actual?.columns, truth.columns, "ids and widths follow their columns")
    }

    /// Opus R-4: edit one column in every row and insert a row. Text can't say which row is which.
    func testEditingAColumnInEveryRowAndInsertingARowIsRefusedWhenFormatted() {
        var old = NoteTable(texts: [["Item", "Status"], ["i1", "s1"], ["i2", "s2"], ["i3", "s3"]])
        bold(&old, 1, 0)
        var truth = old
        for row in 1...3 { edit(&truth, row, 1, "s\(row) done") }
        insertRow(&truth, at: 1, ["n", "new"])
        check(old, truth, expect: .refused)

        // Plain: accepted, and no row takes its neighbour's id.
        var plain = NoteTable(texts: [["Item", "Status"], ["i1", "s1"], ["i2", "s2"], ["i3", "s3"]])
        plain.rows[1].extras = [:]
        var plainTruth = plain
        for row in 1...3 { edit(&plainTruth, row, 1, "s\(row) done") }
        insertRow(&plainTruth, at: 1, ["n", "new"])
        guard let actual = check(plain, plainTruth, expect: .kept) else { return }
        let truthIndex = Dictionary(uniqueKeysWithValues: plainTruth.rows.enumerated().map { ($1.id, $0) })
        for (index, row) in actual.rows.enumerated() where Set(plain.rows.map(\.id)).contains(row.id) {
            XCTAssertEqual(truthIndex[row.id], index, "an old id is only on the row it became")
        }
    }

    /// Dot R-1: delete a column while editing a row so two rows read the same.
    func testDeletingAColumnWhileEditingARowNeverMovesFormatting() {
        var old = NoteTable(texts: [["Name", "Detail"], ["A", "one"], ["B", "two"]])
        bold(&old, 2, 0)
        var truth = old
        deleteColumn(&truth, 1)
        edit(&truth, 1, 0, "B")
        check(old, truth, expect: nil)
    }

    /// Dot R-3: swap two columns with the same (blank) header; ids, widths and marks follow the cells.
    func testSwappingColumnsWithTheSameHeaderKeepsEachColumn() {
        var old = NoteTable(texts: [["", ""], ["alpha", "beta"]])
        old.columns[0].width = 100
        old.columns[1].width = 140
        bold(&old, 1, 1)
        var truth = old
        swapColumns(&truth, 0, 1)
        let actual = check(old, truth, expect: .kept)
        XCTAssertEqual(actual?.columns, truth.columns)
    }

    // MARK: The paper traces

    /// Case 9: a sparse table where a value moves; blank rows are not proof of identity.
    func testAValueMovingInASparseTableIsRefusedWhenRowsCarryAnything() {
        var old = NoteTable(texts: [["A", "B", "C"], ["", "", ""], ["x", "", ""], ["", "", ""], ["", "", ""]])
        bold(&old, 2, 0)
        old.rows[4].extras = ["owner": .string("r4")]
        var truth = old
        edit(&truth, 2, 0, "")
        edit(&truth, 4, 1, "x")
        check(old, truth, expect: .refused)
    }

    /// Case 9b: a repeated table where a value moves; a line that reads like another isn't it.
    func testAValueMovingInARepeatedTableIsRefusedWhenRowsCarryAnything() {
        var old = NoteTable(texts: [["K", "V"], ["a", ""], ["a", "x"], ["a", ""]])
        bold(&old, 3, 0)
        var truth = old
        edit(&truth, 2, 1, "")
        edit(&truth, 3, 1, "x")
        check(old, truth, expect: .refused)
    }

    /// Rounds: a column edited in every row is accepted when another column tells the rows apart.
    func testEditingOneColumnInEveryRowKeepsRowsWhenAnotherColumnIsUnchanged() {
        var old = NoteTable(texts: [["Name", "Status"], ["n1", "s1"], ["n2", "s2"], ["n3", "s3"]])
        bold(&old, 2, 0)
        old.rows[1].extras = ["owner": .string("r1")]
        old.columns[0].width = 120
        var truth = old
        for row in 1...3 { edit(&truth, row, 1, "s\(row) done") }
        let actual = check(old, truth, expect: .kept)
        XCTAssertEqual(actual?.rows.map(\.id), truth.rows.map(\.id))
    }

    /// Case 10: every row edited in one column and the rows reordered, with row extras.
    func testReorderingAndEditingTheSameRowsIsRefusedWhenFormatted() {
        var old = NoteTable(texts: [["K", "V"], ["a", "1"], ["b", "2"], ["c", "3"]])
        for row in 1...3 { old.rows[row].extras = ["owner": .string("r\(row)")] }
        var truth = old
        truth.rows.swapAt(1, 2)
        for row in 1...3 { edit(&truth, row, 1, "v\(row) new") }
        check(old, truth, expect: .refused)
    }

    /// Rows and columns changed at once: never a silent loss; a plain table is accepted.
    func testChangingRowsAndColumnsAtOnceNeverLosesFormatting() {
        var widths = NoteTable(texts: [["A", "B", "C"], ["a1", "b1", "c1"], ["a2", "b2", "c2"]])
        widths.columns[0].width = 120
        var truth = widths
        swapColumns(&truth, 0, 1)
        insertRow(&truth, at: 3, ["a3", "b3", "c3"])
        check(widths, truth, expect: nil)
        var plainWidths = widths
        plainWidths.columns[0].width = nil
        var plainTruth = plainWidths
        swapColumns(&plainTruth, 0, 1)
        insertRow(&plainTruth, at: 3, ["a3", "b3", "c3"])
        check(plainWidths, plainTruth, expect: .kept)

        var marked = NoteTable(texts: [["A", "B"], ["a1", "b1"]])
        bold(&marked, 1, 0)
        var grown = marked
        insertRow(&grown, at: 2, ["a2", "b2"])
        insertColumn(&grown, at: 2, ["C", "c1", "c2"])
        check(marked, grown, expect: nil)
        var plainMarked = marked
        plainMarked.rows[1].cells[0].marks = []
        var plainGrown = plainMarked
        insertRow(&plainGrown, at: 2, ["a2", "b2"])
        insertColumn(&plainGrown, at: 2, ["C", "c1", "c2"])
        check(plainMarked, plainGrown, expect: .kept)
    }

    /// One-line dimensions are certain: a 1×1 table and a one-row table keep their formatting.
    func testOneLineTablesKeepTheirFormattingWhenACellIsEdited() {
        var single = NoteTable(texts: [["only"]])
        single.columns[0].width = 150
        var singleTruth = single
        edit(&singleTruth, 0, 0, "changed")
        XCTAssertEqual(check(single, singleTruth, expect: .kept)?.columns, singleTruth.columns)

        var row = NoteTable(texts: [["a", "b", "c"]])
        bold(&row, 0, 0)
        row.columns[1].width = 130
        var rowTruth = row
        edit(&rowTruth, 0, 1, "b changed")
        check(row, rowTruth, expect: .kept)
    }

    /// A table the agent didn't touch is kept exactly, whatever its duplicate or blank lines.
    func testAnUntouchedTableIsKeptExactly() throws {
        var twins = NoteTable(texts: [["Name", "Status"], ["a", "x"], ["a", "x"], ["b", "y"]])
        bold(&twins, 1, 0)
        var sparseHeader = NoteTable(texts: [["Title", "", ""], ["one", "", ""], ["two", "", ""]])
        sparseHeader.columns[1].width = 90
        sparseHeader.columns[2].width = 110
        var fresh = NoteTable.blank()
        fresh.columns[0].width = 140
        for (name, table) in [("twins", twins), ("sparse header", sparseHeader), ("fresh with a width", fresh), ("fresh", NoteTable.blank())] {
            let base = NoteDocument(blocks: [.text("T"), .text("Intro"), .table(table, id: tableID)])
            let body = NoteTextExport.agentBody(base).replacingOccurrences(of: "Intro", with: "Intro, edited")
            XCTAssertNoThrow(try {
                let document = try NoteAgentTextParser.document(title: "T", body: body, base: base)
                XCTAssertEqual(document.blocks.first { $0.kind == .table }?.table, table, "\(name): an untouched table keeps everything")
            }(), name)
        }
    }

    /// Unchanged text with a new alignment: the table is kept whole and takes the alignment (it is visible).
    func testAnAlignmentOnlyChangeKeepsTheTable() {
        var table = NoteTable(texts: [["", ""], ["", ""]])
        table.columns[0].width = 140
        var truth = table
        truth.columns[1].align = .right
        XCTAssertEqual(check(table, truth, expect: .kept), truth)
    }

    /// Finding B, the named exception: deleting a formatted row whose gap holds twin rows
    /// is refused (the text can't show which line went); `delete_row` does it.
    func testDeletingAFormattedRowBesideTwinRowsIsRefusedAndDoneByID() throws {
        var table = NoteTable(texts: [["K", "V"], ["a", "1"], ["d", "d"], ["d", "d"], ["x", "9"], ["", ""], ["", ""], ["z", "8"]])
        bold(&table, 4, 0)
        var truth = table
        truth.rows.remove(at: 4)
        check(table, truth, expect: .refused)
        let byID = try NoteTableAgentEdit.apply([["op": "delete_row", "row_id": table.rows[4].id.uuidString]], to: table)
        XCTAssertEqual(byID, truth)
        // Beside certain rows, the same deletion is a pure deletion.
        var lone = NoteTable(texts: [["K", "V"], ["a", "1"], ["x", "9"], ["z", "8"]])
        bold(&lone, 2, 0)
        var loneTruth = lone
        loneTruth.rows.remove(at: 2)
        XCTAssertEqual(check(lone, loneTruth, expect: .kept), loneTruth)
    }

    // MARK: The refusal

    /// The refusal is the body's own error and names the id route.
    func testTheRefusalTellsTheAgentHowToMakeTheChange() {
        let message = NoteAgentTextError.lossyFormatting.errorDescription ?? ""
        XCTAssertTrue(message.contains("update_note_table"), message)
        XCTAssertTrue(message.contains("separate updates"), message)
    }

    /// Each refused shape succeeds as the separate steps the message names, keeping every mark and width.
    func testEachRefusedChangeSucceedsAsSeparateSteps() throws {
        // Opus R-4 by id: edit each Status cell, then insert the row.
        var items = NoteTable(texts: [["Item", "Status"], ["i1", "s1"], ["i2", "s2"], ["i3", "s3"]])
        bold(&items, 1, 0)
        let status = items.columns[1].id.uuidString
        var operations: [[String: Any]] = (1...3).map {
            ["op": "set_cell", "row_id": items.rows[$0].id.uuidString, "column_id": status, "text": "s\($0) done"]
        }
        operations.append(["op": "insert_row", "after_row_id": items.rows[0].id.uuidString, "cells": ["n", "new"]])
        let byID = try NoteTableAgentEdit.apply(operations, to: items)
        XCTAssertEqual(byID.rows[2].id, items.rows[1].id)
        XCTAssertEqual(byID.rows[2].cells[0], items.rows[1].cells[0], "the bold item keeps its mark")

        // Case 10: the move alone, then the edits by id.
        var keyed = NoteTable(texts: [["K", "V"], ["a", "1"], ["b", "2"], ["c", "3"]])
        for row in 1...3 { keyed.rows[row].extras = ["owner": .string("r\(row)")] }
        var moved = keyed
        moved.rows.swapAt(1, 2)
        let afterMove = try XCTUnwrap(check(keyed, moved, expect: .kept))
        XCTAssertEqual(afterMove, moved)
        let value = afterMove.columns[1].id.uuidString
        let edited = try NoteTableAgentEdit.apply((1...3).map {
            ["op": "set_cell", "row_id": afterMove.rows[$0].id.uuidString, "column_id": value, "text": "v\($0) new"]
        }, to: afterMove)
        XCTAssertEqual(edited.rows.map(\.extras), moved.rows.map(\.extras))

        // Columns and rows at once: the column move alone, then the new row alone.
        var widths = NoteTable(texts: [["A", "B", "C"], ["a1", "b1", "c1"], ["a2", "b2", "c2"]])
        widths.columns[0].width = 120
        var swapped = widths
        swapColumns(&swapped, 0, 1)
        let afterSwap = try XCTUnwrap(check(widths, swapped, expect: .kept))
        var longer = afterSwap
        insertRow(&longer, at: 3, ["b3", "a3", "c3"])
        XCTAssertEqual(check(afterSwap, longer, expect: .kept)?.columns, swapped.columns)

        // A row and a column: one update each.
        var marked = NoteTable(texts: [["A", "B"], ["a1", "b1"]])
        bold(&marked, 1, 0)
        var withRow = marked
        insertRow(&withRow, at: 2, ["a2", "b2"])
        let afterRow = try XCTUnwrap(check(marked, withRow, expect: .kept))
        var withColumn = afterRow
        insertColumn(&withColumn, at: 2, ["C", "c1", "c2"])
        XCTAssertEqual(check(afterRow, withColumn, expect: .kept)?.rows[1].cells[0], marked.rows[1].cells[0])
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

        /// Fresh, unique text: an edit can never look like a move.
        mutating func fresh() -> String {
            counter += 1
            return "w\(counter)"
        }

        mutating func date() -> NoteTable.Cell {
            counter += 1
            let day = NoteDay(year: 2026 + counter / 300, month: 1 + (counter / 28) % 12, day: 1 + counter % 28)!
            return NoteTable.Cell(String(NoteDocument.objectCharacter), inlines: [NoteInline(id: UUID(), kind: .date(day))])
        }
    }

    private enum Operation {
        case moveRow(Int, Int), moveColumn(Int, Int)
        case insertRow(Int, [NoteTable.Cell]), insertColumn(Int, [NoteTable.Cell])
        case deleteRow(Int), deleteColumn(Int)
        case edit(Int, Int, String)

        func apply(to table: inout NoteTable) {
            switch self {
            case let .moveRow(from, to): table.rows.insert(table.rows.remove(at: from), at: to)
            case let .moveColumn(from, to):
                table.columns.insert(table.columns.remove(at: from), at: to)
                for row in table.rows.indices { table.rows[row].cells.insert(table.rows[row].cells.remove(at: from), at: to) }
            case let .insertRow(at, cells): table.rows.insert(NoteTable.Row(cells: cells), at: at)
            case let .insertColumn(at, cells):
                table.columns.insert(NoteTable.Column(), at: at)
                for row in table.rows.indices { table.rows[row].cells.insert(cells[row], at: at) }
            case let .deleteRow(at): table.rows.remove(at: at)
            case let .deleteColumn(at):
                table.columns.remove(at: at)
                for row in table.rows.indices { table.rows[row].cells.remove(at: at) }
            case let .edit(row, column, text): table.rows[row].cells[column] = NoteTable.Cell(text)
            }
        }

        /// The cell it edits, if any.
        var edited: (Int, Int)? {
            if case let .edit(row, column, _) = self { return (row, column) }
            return nil
        }
    }

    private func operation(on table: NoteTable, _ g: inout Generator) -> Operation {
        let rows = table.rowCount, columns = table.columnCount
        switch g.pick(9) {
        case 0: return .moveRow(1 + g.pick(rows - 1), 1 + g.pick(rows - 1))
        case 1: return .moveColumn(g.pick(columns), g.pick(columns))
        case 2 where rows < 12:
            // A fresh row, a blank row, or a copy of a plain row's text.
            // Never a twin of a line that carries hidden things (not covered: text can't tell twins apart).
            let plain = table.rows.indices.dropFirst().filter { !Self.carries(table.rows[$0]) }
            let twinsFree = { (texts: [String]) in
                !table.rows.contains { Self.carries($0) && $0.cells.map(\.text) == texts }
            }
            let blank = Array(repeating: "", count: columns)
            switch g.pick(4) {
            case 0 where twinsFree(blank): return .insertRow(1 + g.pick(rows), blank.map { NoteTable.Cell($0) })
            case 1 where !plain.isEmpty:
                let source = table.rows[plain[g.pick(plain.count)]].cells.map { NoteTable.Cell($0.text) }
                return .insertRow(1 + g.pick(rows), source)
            default: return .insertRow(1 + g.pick(rows), (0..<columns).map { _ in NoteTable.Cell(g.fresh()) })
            }
        case 3 where columns < 6: return .insertColumn(g.pick(columns + 1), (0..<rows).map { _ in NoteTable.Cell(g.fresh()) })
        case 4 where rows > 3: return .deleteRow(1 + g.pick(rows - 1))
        case 5 where columns > 2: return .deleteColumn(g.pick(columns))
        default: return .edit(g.pick(rows), g.pick(columns), g.fresh())
        }
    }

    /// Adds hidden things to lines whose text is unique, so the table stays formatted.
    private func decorate(_ table: inout NoteTable, _ g: inout Generator) {
        let texts = NoteAgentTableText.texts(table)
        let unique = table.rows.indices.filter { row in
            !texts[row].allSatisfy(\.isEmpty) && texts.filter { $0 == texts[row] }.count == 1
        }
        guard !unique.isEmpty else { return }
        let row = unique[g.pick(unique.count)], column = g.pick(table.columnCount)
        switch g.pick(4) {
        case 0 where !texts[row][column].isEmpty && table.rows[row].cells[column].inlines.isEmpty: bold(&table, row, column)
        case 1: table.rows[row].cells[column] = g.date()
        case 2: table.rows[row].extras = ["owner": .string(g.fresh())]
        default: table.columns[column].width = Double(80 + g.pick(100))
        }
    }

    /// The table without hidden things (dates become plain text).
    private func plain(_ table: NoteTable) -> NoteTable {
        var copy = table
        for column in copy.columns.indices { copy.columns[column].width = nil; copy.columns[column].extras = [:] }
        for row in copy.rows.indices {
            copy.rows[row].extras = [:]
            for column in copy.columns.indices where Self.hidden(copy.rows[row].cells[column]) {
                let cell = copy.rows[row].cells[column]
                copy.rows[row].cells[column] = NoteTable.Cell(cell.inlines.isEmpty ? cell.text : "day \(cell.inlines.first?.id.uuidString.prefix(6) ?? "")")
            }
        }
        return copy
    }

    /// A delete and an insert in the same slot are one edit of that line (the text can't tell them apart).
    private func recordSlotEdits(old: NoteTable, truth: inout NoteTable) {
        let oldRows = old.rows.map(\.id), oldColumns = old.columns.map(\.id)
        func slot<ID: Hashable>(_ index: Int, in order: [ID], survivors: Set<ID>) -> (ID?, ID?) {
            (order[..<index].last { survivors.contains($0) }, order[(index + 1)...].first { survivors.contains($0) })
        }
        let truthRows = truth.rows.map(\.id), rowSurvivors = Set(oldRows).intersection(truthRows)
        if let deleted = oldRows.firstIndex(where: { !rowSurvivors.contains($0) }),
           let inserted = truthRows.firstIndex(where: { !Set(oldRows).contains($0) }),
           slot(deleted, in: oldRows, survivors: rowSurvivors) == slot(inserted, in: truthRows, survivors: rowSurvivors) {
            truth.rows[inserted].id = old.rows[deleted].id
            truth.rows[inserted].extras = old.rows[deleted].extras
        }
        let truthColumns = truth.columns.map(\.id), columnSurvivors = Set(oldColumns).intersection(truthColumns)
        if let deleted = oldColumns.firstIndex(where: { !columnSurvivors.contains($0) }),
           let inserted = truthColumns.firstIndex(where: { !Set(oldColumns).contains($0) }),
           slot(deleted, in: oldColumns, survivors: columnSurvivors) == slot(inserted, in: truthColumns, survivors: columnSurvivors) {
            truth.columns[inserted].id = old.columns[deleted].id
            truth.columns[inserted].width = old.columns[deleted].width
            truth.columns[inserted].extras = old.columns[deleted].extras
        }
    }

    /// The oracle, naming the step and the tables when it fails.
    private func judge(_ context: String, old: NoteTable, truth: NoteTable, actual: NoteTable) {
        let before = testRun?.failureCount ?? 0
        Self.assertFaithful(old: old, truth: truth, actual: actual)
        if (testRun?.failureCount ?? 0) > before {
            XCTFail("\(context)\nold \(NoteAgentTableText.texts(old))\ntruth \(NoteAgentTableText.texts(truth))")
        }
    }

    /// Finding B (lead, 16 Nov): deleting a line when the text can't show which line went.
    /// A gap (rows between the nearest rows whose text is unique in both tables) holds two
    /// or more rows (so a row whose text repeats sits beside the deletion) and a row that
    /// carries something hidden. For a row, that is the gap around the deleted row; for a
    /// column, any gap of rows read on the columns that remain. Such a deletion is refused,
    /// and `delete_row` / `delete_column` does it.
    private func ambiguousDeletion(_ operation: Operation, in table: NoteTable) -> Bool {
        let texts = NoteAgentTableText.texts(table)
        let old: [[String]], new: [[String]], deleted: Int?
        switch operation {
        case let .deleteRow(at):
            (old, new, deleted) = (texts, texts.enumerated().filter { $0.offset != at }.map(\.element), at)
        case let .deleteColumn(at):
            old = texts.map { row in row.enumerated().filter { $0.offset != at }.map(\.element) }
            (new, deleted) = (old, nil)
        default:
            return false
        }
        var oldCount: [[String]: Int] = [:], newCount: [[String]: Int] = [:]
        old.forEach { oldCount[$0, default: 0] += 1 }
        new.forEach { newCount[$0, default: 0] += 1 }
        let unique = { (row: Int) in oldCount[old[row]] == 1 && newCount[old[row]] == 1 }
        var start = 0
        while start < old.count {
            guard !unique(start) else { start += 1; continue }
            var end = start
            while end < old.count && !unique(end) { end += 1 }
            let gap = start..<end
            if deleted.map(gap.contains) != false, gap.count > 1,
               gap.contains(where: { Self.carries(table.rows[$0]) }) { return true }
            start = end
        }
        return false
    }

    /// The same deletion through `update_note_table`.
    private func deleteByID(_ operation: Operation, in table: NoteTable) throws -> NoteTable {
        switch operation {
        case let .deleteRow(at): return try NoteTableAgentEdit.apply([["op": "delete_row", "row_id": table.rows[at].id.uuidString]], to: table)
        case let .deleteColumn(at): return try NoteTableAgentEdit.apply([["op": "delete_column", "column_id": table.columns[at].id.uuidString]], to: table)
        default: throw NoteAgentTextError.invalidTableEdit("not a deletion")
        }
    }

    /// One step's rewrite: a table whose text is unchanged comes back whole (P0);
    /// any other accepted rewrite is judged against the generator's record.
    private func accept(_ context: String, old: NoteTable, truth: NoteTable, actual: NoteTable) {
        if NoteAgentTableText.texts(truth) == NoteAgentTableText.texts(old) {
            XCTAssertEqual(actual, old, "\(context): unchanged text keeps the table whole")
        } else {
            judge(context, old: old, truth: truth, actual: actual)
        }
    }

    /// Seeded rewrites, two operations per step, with duplicate and blank rows:
    /// every accepted rewrite is judged against the generator's record; a table
    /// whose text is unchanged is kept whole; a plain table is never refused; one
    /// operation that edits no marked cell is never refused, except an ambiguous
    /// deletion, which is refused and done by id instead.
    func testSeededRewritesKeepEveryHiddenThingOrAreRefused() throws {
        for seed: UInt64 in [20261116, 20261117, 20261118] {
            var g = Generator(state: seed)
            var current = NoteTable(texts: [["h1", "h2", "h3", "h4"]] + (1..<7).map { _ in (0..<4).map { _ in g.fresh() } })
            current.rows[3].cells = current.rows[2].cells   // a duplicate row
            insertRow(&current, at: 5, ["", "", "", ""])     // a blank row
            insertRow(&current, at: 6, ["", "", "", ""])
            var counts = (accepted: 0, refused: 0, ambiguous: 0)
            for step in 0..<150 {
                if g.pick(2) == 0 { decorate(&current, &g) }
                let context = "seed \(seed), step \(step)"
                // No operation: the table comes back exactly.
                XCTAssertEqual(try? rewrite(current, to: current), current, "\(context): an untouched table changed or was refused")
                let first = operation(on: current, &g)
                var single = current
                first.apply(to: &single)
                var next = current
                let ambiguous = ambiguousDeletion(first, in: current)
                do {
                    let actual = try rewrite(current, to: single)
                    XCTAssertFalse(ambiguous, "\(context): an ambiguous deletion was accepted: \(first); texts \(NoteAgentTableText.texts(current))")
                    accept(context + ", one operation \(first)", old: current, truth: single, actual: actual)
                    next = actual
                } catch where ambiguous {
                    counts.ambiguous += 1
                    XCTAssertEqual(try deleteByID(first, in: current), single, "\(context): the id route deletes it, keeping everything")
                } catch {
                    let marked = first.edited.map { !current.rows[$0.0].cells[$0.1].marks.isEmpty } ?? false
                    XCTAssertTrue(marked, "\(context): one operation refused: \(first); texts \(NoteAgentTableText.texts(current)); "
                                  + "rows carrying hidden things \(current.rows.indices.filter { Self.carries(current.rows[$0]) })")
                }
                // Two operations: faithful or refused.
                let second = operation(on: single, &g)
                var truth = single
                second.apply(to: &truth)
                recordSlotEdits(old: current, truth: &truth)
                if let actual = try? rewrite(current, to: truth) {
                    accept(context + ", two operations \(first), \(second)", old: current, truth: truth, actual: actual)
                    next = actual
                    counts.accepted += 1
                } else {
                    XCTAssertNotEqual(NoteAgentTableText.texts(truth), NoteAgentTableText.texts(current), "\(context): unchanged text was refused")
                    counts.refused += 1
                }
                // A plain table is never refused.
                let plainCurrent = plain(current)
                var plainTruth = plainCurrent
                first.apply(to: &plainTruth)
                second.apply(to: &plainTruth)
                XCTAssertNoThrow(try rewrite(plainCurrent, to: plainTruth), "\(context): a plain table was refused")
                current = next
            }
            XCTAssertGreaterThan(counts.accepted, 30, "seed \(seed): the test exercises accepted rewrites")
            XCTAssertGreaterThan(counts.refused, 0, "seed \(seed): and refusals")
            print("seed \(seed): \(counts)")
        }
    }
}
