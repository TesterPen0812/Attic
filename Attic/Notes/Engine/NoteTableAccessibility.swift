import AppKit

/// VoiceOver's table (spec § 4.7): an `AXTable` with rows, columns and
/// cells. Each cell knows its row and column index; the header row's cells
/// are the column headers, so moving between cells reads the column's name
/// first. The cell being edited holds the live text editor. The grips and
/// "+" chips are named actions on each cell, so nothing depends on the
/// hover-only controls.
@MainActor
final class NoteTableAXRow: NSAccessibilityElement {
    private weak var view: NoteTableView?
    let row: Int
    var cells: [NoteTableAXCell] = []

    init(view: NoteTableView, row: Int) {
        self.view = view
        self.row = row
        super.init()
        setAccessibilityRole(.row)
        setAccessibilityParent(view)
        setAccessibilityIndex(row)
    }

    override func accessibilityChildren() -> [Any]? { cells }
    override func accessibilityIndex() -> Int { row }
    override func accessibilityFrame() -> NSRect {
        guard let view, view.table.rows.indices.contains(row) else { return .zero }
        let layout = view.grid
        return view.screenRect(CGRect(x: 0, y: layout.rowY(row), width: layout.width, height: layout.rowHeights[row]))
    }
}

@MainActor
final class NoteTableAXColumn: NSAccessibilityElement {
    private weak var view: NoteTableView?
    let column: Int

    init(view: NoteTableView, column: Int) {
        self.view = view
        self.column = column
        super.init()
        setAccessibilityRole(.column)
        setAccessibilityParent(view)
        setAccessibilityIndex(column)
    }

    override func accessibilityIndex() -> Int { column }
    override func accessibilityChildren() -> [Any]? {
        guard let view else { return nil }
        return view.table.rows.indices.compactMap { view.axCell(NoteTable.Position(row: $0, column: column)) }
    }
    override func accessibilityFrame() -> NSRect {
        guard let view, view.table.columns.indices.contains(column) else { return .zero }
        let layout = view.grid
        return view.screenRect(CGRect(x: layout.columnX(column), y: 0, width: layout.columnWidths[column], height: layout.height))
    }
}

@MainActor
final class NoteTableAXCell: NSAccessibilityElement {
    private weak var view: NoteTableView?
    let position: NoteTable.Position
    private weak var parentRow: NoteTableAXRow?

    init(view: NoteTableView, row: Int, column: Int, parentRow: NoteTableAXRow) {
        self.view = view
        self.position = NoteTable.Position(row: row, column: column)
        self.parentRow = parentRow
        super.init()
        setAccessibilityRole(.cell)
        setAccessibilityParent(parentRow)
    }

    override func accessibilityRowIndexRange() -> NSRange { NSRange(location: position.row, length: 1) }
    override func accessibilityColumnIndexRange() -> NSRange { NSRange(location: position.column, length: 1) }

    override func accessibilityValue() -> Any? {
        guard let view, view.table.contains(position) else { return nil }
        return view.table[position].displayText
    }

    override func accessibilityLabel() -> String? {
        guard let view, view.table.contains(position) else { return nil }
        let text = view.table[position].displayText
        return text.isEmpty ? String(localized: "Empty") : text
    }

    override func accessibilityChildren() -> [Any]? {
        guard let view, view.activeCell == position, view.hasEditor, !view.editor.isHidden else { return [] }
        return [view.editor]
    }

    override func isAccessibilitySelected() -> Bool {
        guard let view else { return false }
        return view.activeCell == position || view.cellSelection?.contains(position) == true
    }

    override func isAccessibilityFocused() -> Bool { view?.activeCell == position && view?.isEditingCell == true }

    override func accessibilityFrame() -> NSRect {
        guard let view, view.table.contains(position) else { return .zero }
        return view.screenRect(view.grid.cellRect(position))
    }

    override func accessibilityPerformPress() -> Bool {
        view?.activate(position, caret: .end)
        return view != nil
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let view, let engine = view.engine, let attachment = view.attachment, !engine.isReadOnly else { return nil }
        let position = self.position
        func action(_ name: String, _ body: @escaping @MainActor () -> Void) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) {
                MainActor.assumeIsolated { body() }
                return true
            }
        }
        let table = attachment.table
        var actions = [
            action(String(localized: "Add Row Above")) { engine.addRow(to: attachment, at: position.row, focusing: position.column) },
            action(String(localized: "Add Row Below")) { engine.addRow(to: attachment, at: position.row + 1, focusing: position.column) },
            action(String(localized: "Add Column Before")) { engine.addColumn(to: attachment, at: position.column, focusingRow: position.row) },
            action(String(localized: "Add Column After")) { engine.addColumn(to: attachment, at: position.column + 1, focusingRow: position.row) }
        ]
        if table.rowCount > 1 {
            actions.append(action(String(localized: "Delete Row")) { engine.deleteRow(of: attachment, at: position.row) })
        }
        if table.columnCount > 1 {
            actions.append(action(String(localized: "Delete Column")) { engine.deleteColumn(of: attachment, at: position.column) })
        }
        if position.row > 0 {
            actions.append(action(String(localized: "Move Row Up")) { engine.moveRow(of: attachment, from: position.row, to: position.row - 1) })
        }
        if position.row < table.rowCount - 1 {
            actions.append(action(String(localized: "Move Row Down")) { engine.moveRow(of: attachment, from: position.row, to: position.row + 1) })
        }
        if position.column > 0 {
            actions.append(action(String(localized: "Move Column Left")) { engine.moveColumn(of: attachment, from: position.column, to: position.column - 1) })
        }
        if position.column < table.columnCount - 1 {
            actions.append(action(String(localized: "Move Column Right")) { engine.moveColumn(of: attachment, from: position.column, to: position.column + 1) })
        }
        actions.append(action(table.headerRow ? String(localized: "Turn Off Header Row") : String(localized: "Turn On Header Row")) {
            engine.toggleHeaderRow(attachment)
        })
        actions.append(action(String(localized: "Delete Table")) { engine.deleteTable(attachment) })
        return actions
    }
}

extension NoteTableView {
    /// A rectangle in the grid's coordinates, on screen.
    func screenRect(_ rect: CGRect) -> NSRect {
        guard let window else { return .zero }
        let local = canvas.convert(rect, to: nil)
        return window.convertToScreen(local)
    }
}
