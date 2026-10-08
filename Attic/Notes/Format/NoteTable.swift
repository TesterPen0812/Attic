import Foundation

/// A table in a note (`NoteBlockKind.table`, capability `table-v1`).
///
/// ```jsonc
/// { "kind": "table", "id": "<uuid>", "headerRow": true,
///   "columns": [{ "id": "<uuid>", "width": 120, "align": "left" }],   // width: set by a drag, else absent
///   "rows": [{ "id": "<uuid>", "cells": [{ "text": "…", "marks": […], "inline": […] }] }] }
/// ```
///
/// - Rows, columns and the table keep stable ids, so edits merge and agents
///   address them (`update_note_table`).
/// - A cell holds inline content only: text, inline marks, links and dates.
///   Its `text` may hold line breaks ("\n", ⌥Return); block styles, lists,
///   images, files and nested tables are never stored in a cell.
/// - Every row has exactly one cell per column (rectangular).
/// - Unknown fields on the table, a column, a row or a cell are kept.
struct NoteTable: Equatable, Sendable {
    enum Alignment: String, Equatable, Sendable, CaseIterable {
        case left, center, right
    }

    struct Column: Equatable, Sendable {
        var id: UUID
        /// Points, set by dragging the column's edge; nil sizes it from its
        /// content (56–168).
        var width: Double?
        var align: Alignment
        var extras: [String: NoteJSON]

        init(id: UUID = UUID(), width: Double? = nil, align: Alignment = .left, extras: [String: NoteJSON] = [:]) {
            self.id = id
            self.width = width
            self.align = align
            self.extras = extras
        }
    }

    struct Cell: Equatable, Sendable {
        /// U+FFFC marks each inline object (a date), as in a text block.
        var text: String
        var marks: [NoteMark]
        var inlines: [NoteInline]
        var extras: [String: NoteJSON]

        init(_ text: String = "", marks: [NoteMark] = [], inlines: [NoteInline] = [], extras: [String: NoteJSON] = [:]) {
            self.text = text
            self.marks = marks
            self.inlines = inlines
            self.extras = extras
        }

        static let empty = Cell()

        /// The cell as a text block (shared rendering and mark rules).
        var block: NoteBlock {
            NoteBlock(kind: .text, text: text, marks: marks, inlines: inlines)
        }

        /// The text with each inline object in its readable form.
        var displayText: String { block.displayText }

        var isEmpty: Bool { text.isEmpty }
    }

    struct Row: Equatable, Sendable {
        var id: UUID
        var cells: [Cell]
        var extras: [String: NoteJSON]

        init(id: UUID = UUID(), cells: [Cell], extras: [String: NoteJSON] = [:]) {
            self.id = id
            self.cells = cells
            self.extras = extras
        }
    }

    /// A cell's place: row and column indices.
    struct Position: Hashable, Sendable, Comparable {
        var row: Int
        var column: Int

        init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }

        static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.row, lhs.column) < (rhs.row, rhs.column)
        }
    }

    /// Limits (spec § 4.4; held by the performance gate).
    static let maxColumns = 30
    static let maxRows = 500

    var headerRow: Bool
    var columns: [Column]
    var rows: [Row]
    var extras: [String: NoteJSON]

    init(headerRow: Bool = true, columns: [Column], rows: [Row], extras: [String: NoteJSON] = [:]) {
        self.headerRow = headerRow
        self.columns = columns
        self.rows = rows
        self.extras = extras
    }

    /// A new, empty table (`/table`: 2 × 3 with the header row).
    static func blank(columns: Int = 2, rows: Int = 3, headerRow: Bool = true) -> NoteTable {
        let columnCount = max(1, columns)
        return NoteTable(headerRow: headerRow,
                         columns: (0..<columnCount).map { _ in Column() },
                         rows: (0..<max(1, rows)).map { _ in Row(cells: Array(repeating: .empty, count: columnCount)) })
    }

    /// A table from plain cell texts (paste, agents, Markdown).
    init(texts: [[String]], headerRow: Bool = true, alignments: [Alignment] = []) {
        let width = max(1, texts.map(\.count).max() ?? 1)
        self.init(headerRow: headerRow,
                  columns: (0..<width).map { index in Column(align: index < alignments.count ? alignments[index] : .left) },
                  rows: texts.map { row in
                      Row(cells: (0..<width).map { index in Cell(index < row.count ? row[index] : "") })
                  })
    }

    var columnCount: Int { columns.count }
    var rowCount: Int { rows.count }

    var isRectangular: Bool {
        !columns.isEmpty && !rows.isEmpty && rows.allSatisfy { $0.cells.count == columns.count }
    }

    var isWithinLimits: Bool { columns.count <= Self.maxColumns && rows.count <= Self.maxRows }

    func contains(_ position: Position) -> Bool {
        rows.indices.contains(position.row) && columns.indices.contains(position.column)
    }

    subscript(position: Position) -> Cell {
        get { rows[position.row].cells[position.column] }
        set { rows[position.row].cells[position.column] = newValue }
    }

    /// Every cell's readable text, row by row.
    var texts: [[String]] { rows.map { $0.cells.map(\.displayText) } }

    var isEmpty: Bool { rows.allSatisfy { $0.cells.allSatisfy(\.isEmpty) } }

    /// Every inline object's id (dates in cells).
    var inlineIDs: [UUID] { rows.flatMap { $0.cells.flatMap { $0.inlines.map(\.id) } } }

    // MARK: Structure

    mutating func insertRow(at index: Int, id: UUID = UUID()) {
        let at = min(max(0, index), rows.count)
        rows.insert(Row(id: id, cells: Array(repeating: .empty, count: columns.count)), at: at)
    }

    mutating func insertColumn(at index: Int, id: UUID = UUID(), align: Alignment = .left) {
        let at = min(max(0, index), columns.count)
        columns.insert(Column(id: id, align: align), at: at)
        for row in rows.indices { rows[row].cells.insert(.empty, at: at) }
    }

    /// The last row or column is never removed (delete the table instead).
    @discardableResult
    mutating func removeRow(at index: Int) -> Bool {
        guard rows.count > 1, rows.indices.contains(index) else { return false }
        rows.remove(at: index)
        return true
    }

    @discardableResult
    mutating func removeColumn(at index: Int) -> Bool {
        guard columns.count > 1, columns.indices.contains(index) else { return false }
        columns.remove(at: index)
        for row in rows.indices { rows[row].cells.remove(at: index) }
        return true
    }

    @discardableResult
    mutating func moveRow(from source: Int, to destination: Int) -> Bool {
        guard rows.indices.contains(source), rows.indices.contains(destination), source != destination else { return false }
        let row = rows.remove(at: source)
        rows.insert(row, at: destination)
        return true
    }

    @discardableResult
    mutating func moveColumn(from source: Int, to destination: Int) -> Bool {
        guard columns.indices.contains(source), columns.indices.contains(destination), source != destination else { return false }
        let column = columns.remove(at: source)
        columns.insert(column, at: destination)
        for row in rows.indices {
            let cell = rows[row].cells.remove(at: source)
            rows[row].cells.insert(cell, at: destination)
        }
        return true
    }

    /// Fills cells from `anchor` with `texts`, growing the table as needed
    /// (within the limits). Returns false, changing nothing, past them.
    @discardableResult
    mutating func fill(_ texts: [[Cell]], at anchor: Position) -> Bool {
        let height = texts.count
        let width = texts.map(\.count).max() ?? 0
        guard height > 0, width > 0 else { return false }
        let neededRows = anchor.row + height, neededColumns = anchor.column + width
        guard neededRows <= Self.maxRows, neededColumns <= Self.maxColumns else { return false }
        while columns.count < neededColumns { insertColumn(at: columns.count) }
        while rows.count < neededRows { insertRow(at: rows.count) }
        for (rowOffset, row) in texts.enumerated() {
            for (columnOffset, cell) in row.enumerated() {
                self[Position(row: anchor.row + rowOffset, column: anchor.column + columnOffset)] = cell
            }
        }
        return true
    }

    /// Makes every row as long as the column list (a repair for writes that
    /// are validated afterwards; never used to accept a ragged agent write).
    mutating func makeRectangular() {
        for row in rows.indices {
            if rows[row].cells.count < columns.count {
                rows[row].cells += Array(repeating: .empty, count: columns.count - rows[row].cells.count)
            } else if rows[row].cells.count > columns.count {
                rows[row].cells.removeLast(rows[row].cells.count - columns.count)
            }
        }
    }

    /// New ids for the table's rows, columns and inline objects (a pasted
    /// copy beside its original).
    func withFreshIDs() -> NoteTable {
        var copy = self
        for index in copy.columns.indices { copy.columns[index].id = UUID() }
        for row in copy.rows.indices {
            copy.rows[row].id = UUID()
            for cell in copy.rows[row].cells.indices {
                copy.rows[row].cells[cell].inlines = copy.rows[row].cells[cell].inlines.map { inline in
                    var fresh = inline
                    fresh.id = UUID()
                    return fresh
                }
            }
        }
        return copy
    }
}
