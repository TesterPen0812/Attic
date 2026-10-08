import AppKit

/// Tables in the editor (spec § 4): inserting, editing a grid in place with
/// Undo, the keyboard into, through and out of a table, and paste.
///
/// A table is one U+FFFC on its own line (`NoteTableAttachment`). Changes to
/// its grid never touch the note's characters: each is a history step that
/// holds the grid before and after (`NoteUndoHistory.recordTableChange`).
/// Inserting, deleting, cutting and pasting a whole table are ordinary text
/// edits of that one character.
@MainActor
extension NoteEditorEngine {
    // MARK: Finding tables

    func tableAttachment(id: UUID) -> (NoteTableAttachment, NSRange)? {
        var found: (NoteTableAttachment, NSRange)?
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, stop in
            if let table = value as? NoteTableAttachment, table.objectID == id {
                found = (table, range)
                stop.pointee = true
            }
        }
        return found
    }

    func tableAttachment(at location: Int) -> NoteTableAttachment? {
        object(at: location) as? NoteTableAttachment
    }

    func range(ofTable attachment: NoteTableAttachment) -> NSRange? {
        tableAttachment(id: attachment.objectID).flatMap { $0.0 === attachment ? $0.1 : nil }
    }

    /// The table the keyboard is in (a cell, or whole cells selected).
    var focusedTable: NoteTableView? {
        guard let responder = textView?.window?.firstResponder else { return nil }
        if let editor = responder as? NoteTableCellEditor, let table = editor.table, table.engine === self { return table }
        if let canvas = responder as? NoteTableCanvas, let table = canvas.table, table.engine === self { return table }
        return nil
    }

    // MARK: Hosting

    /// The engine owns the tables it shows: their look, their hosted views.
    func adoptTable(_ table: NoteTableAttachment, force: Bool) {
        let restyled = force || table.style != style
        table.engine = self
        table.style = style
        table.allowsTextAttachmentView = true
        if restyled {
            table.invalidateLayout(clearingText: true)
            table.hostedView?.modelDidChange()
            table.hostedView?.canvas.needsDisplay = true
        }
    }

    /// A date inside a cell is drawn by the note's renderer.
    func prepareCellObject(_ object: NoteObjectAttachment) {
        guard let date = object as? NoteDateAttachment else { return }
        rendererApply(date)
    }

    /// The table's height changed: its line is laid out again.
    func tableLayoutDidChange(_ view: NoteTableView) {
        guard let attachment = view.attachment, let range = range(ofTable: attachment) else { return }
        invalidateLayout(range)
        textView?.needsLayout = true
        onTableChromeChange?()
    }

    func tableDidScroll(_ view: NoteTableView) { onTableChromeChange?() }

    func tableWillChangeCell(_ view: NoteTableView) { history.breakCoalescing() }

    func tableSelectionDidChange(_ view: NoteTableView?) {
        onTableChromeChange?()
        onCaretChange?()
    }

    func tableFocusDidChange(_ view: NoteTableView) {
        onTableChromeChange?()
        onCaretChange?()
    }

    /// TextKit re-hosts a table's view when the text before it changes;
    /// the keyboard goes back to the cell it was in.
    func isRehostingTable(_ view: NoteTableView) -> Bool {
        guard let attachment = view.attachment else { return false }
        return range(ofTable: attachment) != nil && view.window == nil
    }

    var allowsTableCellEdit: Bool { !isReadOnly && activity != .writingToolsRefused }

    var isWritingToolsAvailableForCells: Bool { textView?.writingToolsBehavior != NSWritingToolsBehavior.none }

    // MARK: Changing a grid

    /// Changes `attachment`'s grid as one Undo step (typing in one cell
    /// coalesces). Returns false when nothing changed or editing is refused.
    @discardableResult
    func changeTable(_ attachment: NoteTableAttachment, name: String, coalescing cell: NoteTable.Position? = nil,
                     before: NoteTableFocus? = nil, after: NoteTableFocus? = nil,
                     _ change: (inout NoteTable) -> Void) -> Bool {
        guard !isReadOnly, range(ofTable: attachment) != nil else { return false }
        guard activity == .idle || activity == .composing || activity == .writingToolsSafe else {
            return refuseTableEdit()
        }
        let old = attachment.table
        var new = old
        change(&new)
        guard new != old else { return false }
        guard new.isRectangular, new.isWithinLimits else {
            onNotice?(String(localized: "A table can have at most \(NoteTable.maxColumns) columns and \(NoteTable.maxRows) rows."))
            return false
        }
        if cell == nil { history.breakCoalescing() }
        history.recordTableChange(id: attachment.objectID, before: old, after: new, name: name,
                                  focusBefore: before ?? currentTableFocus(attachment),
                                  focusAfter: after, cell: cell)
        attachment.table = new
        tableContentDidChange(attachment)
        return true
    }

    private func refuseTableEdit() -> Bool {
        onNotice?(String(localized: "Finish Writing Tools or composing text before editing this note."))
        NSSound.beep()
        return false
    }

    /// The grid changed without a character edit: the saved document, the
    /// table's line and the page's chrome follow.
    func tableContentDidChange(_ attachment: NoteTableAttachment) {
        invalidateDocumentCache()
        onTextChange?()
        onTableChromeChange?()
    }

    func currentTableFocus(_ attachment: NoteTableAttachment) -> NoteTableFocus? {
        guard let view = attachment.hostedView, let cell = view.activeCell, view.hasEditor else { return nil }
        return NoteTableFocus(position: cell, selection: view.editor.selectedRange())
    }

    /// Undo and Redo of a grid step: the grid comes back, and the keyboard
    /// goes to the cell the step was made in.
    func restoreTable(id: UUID, table: NoteTable, focus: NoteTableFocus?) -> Bool {
        guard let (attachment, _) = tableAttachment(id: id) else { return false }
        attachment.table = table
        tableContentDidChange(attachment)
        if let focus, let view = attachment.hostedView, table.contains(focus.position) {
            view.activate(focus.position, caret: .range(focus.selection))
        }
        return true
    }

    // MARK: Structure (each one Undo step)

    @discardableResult
    func addRow(to attachment: NoteTableAttachment, at index: Int, focusing column: Int) -> Bool {
        let at = min(max(0, index), attachment.table.rowCount)
        let focus = NoteTable.Position(row: at, column: min(column, attachment.table.columnCount - 1))
        guard changeTable(attachment, name: String(localized: "Add Row"),
                          after: NoteTableFocus(position: focus, selection: NSRange(location: 0, length: 0)), { $0.insertRow(at: at) })
        else { return false }
        attachment.hostedView?.activate(focus, caret: .start)
        return true
    }

    @discardableResult
    func addColumn(to attachment: NoteTableAttachment, at index: Int, focusingRow row: Int) -> Bool {
        let at = min(max(0, index), attachment.table.columnCount)
        let focus = NoteTable.Position(row: min(row, attachment.table.rowCount - 1), column: at)
        guard changeTable(attachment, name: String(localized: "Add Column"),
                          after: NoteTableFocus(position: focus, selection: NSRange(location: 0, length: 0)), {
            let align = $0.columns.indices.contains(at - 1) ? $0.columns[at - 1].align : .left
            $0.insertColumn(at: at, align: align)
        }) else { return false }
        attachment.hostedView?.activate(focus, caret: .start)
        return true
    }

    @discardableResult
    func deleteRow(of attachment: NoteTableAttachment, at index: Int) -> Bool {
        guard attachment.table.rowCount > 1 else { return deleteTable(attachment) }
        let column = attachment.hostedView?.activeCell?.column ?? 0
        guard changeTable(attachment, name: String(localized: "Delete Row"), { $0.removeRow(at: index) }) else { return false }
        let row = min(index, attachment.table.rowCount - 1)
        attachment.hostedView?.activate(NoteTable.Position(row: row, column: column), caret: .end)
        return true
    }

    @discardableResult
    func deleteColumn(of attachment: NoteTableAttachment, at index: Int) -> Bool {
        guard attachment.table.columnCount > 1 else { return deleteTable(attachment) }
        let row = attachment.hostedView?.activeCell?.row ?? 0
        guard changeTable(attachment, name: String(localized: "Delete Column"), { $0.removeColumn(at: index) }) else { return false }
        let column = min(index, attachment.table.columnCount - 1)
        attachment.hostedView?.activate(NoteTable.Position(row: row, column: column), caret: .end)
        return true
    }

    @discardableResult
    func moveRow(of attachment: NoteTableAttachment, from source: Int, to destination: Int) -> Bool {
        let column = attachment.hostedView?.activeCell?.column ?? 0
        guard changeTable(attachment, name: String(localized: "Move Row"), { $0.moveRow(from: source, to: destination) }) else { return false }
        attachment.hostedView?.activate(NoteTable.Position(row: destination, column: column), caret: .end)
        return true
    }

    @discardableResult
    func moveColumn(of attachment: NoteTableAttachment, from source: Int, to destination: Int) -> Bool {
        let row = attachment.hostedView?.activeCell?.row ?? 0
        guard changeTable(attachment, name: String(localized: "Move Column"), { $0.moveColumn(from: source, to: destination) }) else { return false }
        attachment.hostedView?.activate(NoteTable.Position(row: row, column: destination), caret: .end)
        return true
    }

    @discardableResult
    func setAlignment(_ alignment: NoteTable.Alignment, of attachment: NoteTableAttachment, columns: ClosedRange<Int>) -> Bool {
        changeTable(attachment, name: String(localized: "Align")) { table in
            for column in columns where table.columns.indices.contains(column) { table.columns[column].align = alignment }
        }
    }

    @discardableResult
    func toggleHeaderRow(_ attachment: NoteTableAttachment) -> Bool {
        changeTable(attachment, name: String(localized: "Header Row")) { $0.headerRow.toggle() }
    }

    /// Every column back to its content's width (the dragged widths go).
    @discardableResult
    func distributeColumns(_ attachment: NoteTableAttachment) -> Bool {
        changeTable(attachment, name: String(localized: "Distribute Columns")) { table in
            for index in table.columns.indices { table.columns[index].width = nil }
        }
    }

    /// A drag of a column's edge shows live; `commitColumnWidth` makes the
    /// whole drag one Undo step.
    func previewColumnWidth(_ attachment: NoteTableAttachment, column: Int, width: CGFloat) {
        guard let view = attachment.hostedView, attachment.table.columns.indices.contains(column) else { return }
        var table = attachment.table
        // The other columns keep the widths they show, so only this one moves.
        for index in table.columns.indices where table.columns[index].width == nil && index != column {
            table.columns[index].width = Double(view.grid.columnWidths[index])
        }
        table.columns[column].width = Double(width)
        attachment.table = table
        view.refreshLayout()
        tableLayoutDidChange(view)
    }

    func commitColumnWidth(_ attachment: NoteTableAttachment, from before: NoteTable) {
        let after = attachment.table
        guard after != before else { return }
        attachment.table = before
        changeTable(attachment, name: String(localized: "Column Width")) { $0 = after }
    }

    // MARK: Whole tables

    /// Deletes the table (and its line) as one Undo step; the caret goes
    /// to where it was.
    @discardableResult
    func deleteTable(_ attachment: NoteTableAttachment) -> Bool {
        guard let range = range(ofTable: attachment) else { return false }
        let line = paragraphRange(at: range.location)
        let removal = NSMaxRange(line) == textStorage.length && line.location > 0
            ? NSRange(location: line.location - 1, length: line.length + 1) : line
        let caret = min(removal.location, max(0, textStorage.length - removal.length))
        let deleted = performEdit(removal, with: NSAttributedString(), name: String(localized: "Delete Table"),
                                  selection: NSRange(location: caret, length: 0))
        if deleted { textView?.window?.makeFirstResponder(textView) }
        return deleted
    }

    /// Selects the whole table in the note's text (Esc twice, ⌘A twice).
    func selectWholeTable(_ attachment: NoteTableAttachment) {
        guard let range = range(ofTable: attachment), let textView else { return }
        attachment.hostedView?.deactivate()
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        onTableChromeChange?()
    }

    /// The table's text, row by row (Convert to Text): one Undo step.
    @discardableResult
    func convertTableToText(_ attachment: NoteTableAttachment) -> Bool {
        guard let range = range(ofTable: attachment) else { return false }
        let lines = attachment.table.rows.map { row in row.cells.map(\.displayText).joined(separator: "\t") }
        let text = NSAttributedString(string: lines.joined(separator: "\n"), attributes: style.bodyAttributes)
        let applied = performEdit(range, with: text, name: String(localized: "Convert to Text"),
                                  selection: NSRange(location: range.location + text.length, length: 0))
        if applied { textView?.window?.makeFirstResponder(textView) }
        return applied
    }

    func copyTableAsMarkdown(_ attachment: NoteTableAttachment, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(NoteTableText.markdown(attachment.table, cellText: Self.markdownCellText), forType: .string)
    }

    /// A cell's Markdown: its marks as Markdown, its dates as text.
    static func markdownCellText(_ cell: NoteTable.Cell) -> String {
        NoteMarkdownExport.inlineMarkdown(cell.block)
    }

    // MARK: Inserting

    /// `/table`, the Aa row, ⋯ › Insert › Table, Format › Table: a 2 × 3
    /// table with its header row after the caret's line, with the caret in
    /// its first cell. A paragraph always follows a table.
    @discardableResult
    func insertTable(_ table: NoteTable = .blank(), at selection: NSRange? = nil, name: String = String(localized: "Insert Table")) -> Bool {
        guard !isReadOnly else { return false }
        let selection = selection ?? textView?.selectedRange() ?? NSRange(location: textStorage.length, length: 0)
        let title = titleParagraphRange
        let attachment = NoteTableAttachment(table: table)
        adoptTable(attachment, force: false)
        let line = lineRange(at: selection.location)
        let string = textStorage.string as NSString
        let insertion = NSMutableAttributedString()
        let target: NSRange
        if selection.location > NSMaxRange(title), line.length == 0 {
            // An empty line becomes the table.
            target = NSRange(location: line.location, length: 0)
            insertion.append(NoteTextCodec.attachmentString(attachment, attributes: style.bodyAttributes))
            if NSMaxRange(line) >= string.length || string.character(at: NSMaxRange(line)) != 0x0A {
                insertion.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
            } else if NSMaxRange(line) + 1 >= string.length {
                insertion.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
            }
        } else {
            let end = NSMaxRange(max(selection.location, NSMaxRange(title)) == selection.location ? line : title)
            target = NSRange(location: end, length: 0)
            insertion.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
            insertion.append(NoteTextCodec.attachmentString(attachment, attributes: style.bodyAttributes))
            if end == string.length || isTableAhead(after: end) {
                insertion.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
            }
        }
        guard performEdit(target, with: insertion, name: name) else { return false }
        enterTable(attachment, at: NoteTable.Position(row: 0, column: 0), caret: .start)
        return true
    }

    private func isTableAhead(after location: Int) -> Bool {
        location + 1 < textStorage.length && tableAttachment(at: location + 1) != nil
    }

    /// The keyboard goes into a cell (after layout has hosted the view).
    func enterTable(_ attachment: NoteTableAttachment, at position: NoteTable.Position, caret: NoteTableCaret) {
        guard let range = range(ofTable: attachment) else { return }
        if let layoutManager, let textRange = textRange(for: range) { layoutManager.ensureLayout(for: textRange) }
        textView?.scrollRangeToVisible(range)
        textView?.layoutSubtreeIfNeeded()
        let view = attachment.tableView
        if view.window == nil {
            // TextKit hosts the view on its next pass.
            DispatchQueue.main.async { [weak self, weak attachment] in
                guard let self, let attachment, self.range(ofTable: attachment) != nil else { return }
                self.textView?.layoutSubtreeIfNeeded()
                attachment.tableView.activate(position, caret: caret)
            }
            return
        }
        view.activate(position, caret: caret)
    }

    // MARK: The keyboard into and out of a table

    /// An arrow in the note's text that lands on a table's line enters the
    /// table (↓ → its first row, → its first cell, ↑ its last row, ← its
    /// last cell). Called after the text view moved the caret.
    func enterTableAfterMove(_ selector: Selector, from old: NSRange, x: CGFloat?) -> Bool {
        guard let textView, !textView.hasMarkedText() else { return false }
        let new = textView.selectedRange()
        guard new.length == 0 else { return false }
        let candidates = [new.location, new.location - 1]
        guard let location = candidates.first(where: { tableAttachment(at: $0) != nil && lineRange(at: $0).location == $0 }),
              let attachment = tableAttachment(at: location) else { return false }
        let table = attachment.table
        let forward: Bool
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveForward(_:)):
            forward = true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveBackward(_:)):
            forward = false
        default:
            return false
        }
        // Coming back from below onto the table's line end, going up.
        let row = forward ? 0 : table.rowCount - 1
        let view = attachment.tableView
        var column = forward ? 0 : table.columnCount - 1
        var caret: NoteTableCaret = forward ? .start : .end
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)), let x {
            let local = x - (rect(for: NSRange(location: location, length: 1))?.minX ?? 0) + view.scrollOffset
            column = view.grid.position(at: CGPoint(x: local, y: 1), clamped: true)?.column ?? column
            let cellX = local - view.grid.textRect(NoteTable.Position(row: row, column: column)).minX
            caret = forward ? .firstLine(x: cellX) : .lastLine(x: cellX)
        }
        textView.setSelectedRange(old)
        enterTable(attachment, at: NoteTable.Position(row: row, column: column), caret: caret)
        return true
    }

    /// Arrows at a table's outer edge leave it for the paragraph before or
    /// after it. A table is always followed by a paragraph: one is made if
    /// the table ends the note.
    func leaveTable(_ attachment: NoteTableAttachment, toward direction: NoteTableView.Direction, x: CGFloat?) {
        guard let range = range(ofTable: attachment), let textView else { return }
        attachment.hostedView?.deactivate()
        textView.window?.makeFirstResponder(textView)
        let string = textStorage.string as NSString
        switch direction {
        case .up, .left:
            let target = max(0, range.location - 1)
            if direction == .up, let x, let tableRect = rect(for: range) {
                let point = NSPoint(x: tableRect.minX + x, y: tableRect.minY - 4)
                let index = textView.characterIndexForInsertion(at: point)
                textView.setSelectedRange(NSRange(location: min(index, target), length: 0))
            } else {
                textView.setSelectedRange(NSRange(location: target, length: 0))
            }
        case .down, .right:
            if NSMaxRange(range) >= string.length {
                // The note ends with the table: a paragraph after it.
                performEdit(NSRange(location: string.length, length: 0),
                            with: NSAttributedString(string: "\n", attributes: style.bodyAttributes),
                            name: String(localized: "New Line"),
                            selection: NSRange(location: string.length + 1, length: 0))
                return
            }
            let next = NSMaxRange(range) + 1
            if direction == .down, let x, let tableRect = rect(for: range) {
                let point = NSPoint(x: tableRect.minX + x, y: tableRect.maxY + 12)
                let index = textView.characterIndexForInsertion(at: point)
                textView.setSelectedRange(NSRange(location: max(next, min(index, NSMaxRange(lineRange(at: next)))), length: 0))
            } else {
                textView.setSelectedRange(NSRange(location: min(next, textStorage.length), length: 0))
            }
        }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Return in an empty last row: the row goes and the caret leaves the
    /// table, as Return on an empty list item ends the list.
    func removeLastEmptyRowAndLeave(_ attachment: NoteTableAttachment, row: Int) {
        guard changeTable(attachment, name: String(localized: "Delete Row"), { $0.removeRow(at: row) }) else { return }
        leaveTable(attachment, toward: .down, x: nil)
    }

    // MARK: Cells

    func clearCells(in view: NoteTableView, range: NoteTableCellRange, name: String = String(localized: "Clear Cells")) {
        guard let attachment = view.attachment else { return }
        changeTable(attachment, name: name) { table in
            for position in range.positions where table.contains(position) { table[position] = .empty }
        }
        view.selectCells(range)
    }

    /// Copies whole cells: TSV for other apps, Markdown, an HTML table, and
    /// the cells as a table fragment for Attic.
    func copyCells(in view: NoteTableView, range: NoteTableCellRange, to pasteboard: NSPasteboard) {
        let table = view.table
        let rows = range.rows.map { row in range.columns.map { table[NoteTable.Position(row: row, column: $0)] } }
        var copy = NoteTable(headerRow: table.headerRow && range.rows.lowerBound == 0,
                             columns: range.columns.map { table.columns[$0] }, rows: rows.map { NoteTable.Row(cells: $0) })
        copy = copy.withFreshIDs()
        NoteTablePaste.write(copy, to: pasteboard)
    }

    /// Tabular data pasted into a cell fills cells from it, growing the
    /// table as needed: one Undo step. Past the limits nothing changes.
    @discardableResult
    func pasteIntoTable(_ view: NoteTableView, at anchor: NoteTable.Position, from pasteboard: NSPasteboard) -> Bool {
        guard let attachment = view.attachment, let pasted = NoteTablePaste.table(from: pasteboard) else { return false }
        let cells = pasted.rows.map(\.cells)
        let height = cells.count, width = cells.map(\.count).max() ?? 0
        guard anchor.row + height <= NoteTable.maxRows, anchor.column + width <= NoteTable.maxColumns else {
            onNotice?(String(localized: "That paste would make the table larger than \(NoteTable.maxColumns) columns by \(NoteTable.maxRows) rows, so nothing was pasted."))
            return false
        }
        let applied = changeTable(attachment, name: String(localized: "Paste")) { $0.fill(cells, at: anchor) }
        if applied {
            let end = NoteTable.Position(row: anchor.row + height - 1, column: anchor.column + width - 1)
            view.selectCells(NoteTableCellRange(anchor: anchor, head: end))
        }
        return applied
    }

    // MARK: Table keys

    /// Shortcuts inside a table: marks on the cell's text (⌘B, ⌘I, ⌘U…),
    /// ⌥⌘ arrows to add a row or column, and Undo.
    func handleTableShortcut(_ event: NSEvent, in view: NoteTableView) -> Bool {
        guard !isReadOnly, let attachment = view.attachment else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if flags == [.command, .option], let cell = view.activeCell ?? view.cellSelection?.head {
            switch event.keyCode {
            case 126: return addRow(to: attachment, at: cell.row, focusing: cell.column)
            case 125: return addRow(to: attachment, at: cell.row + 1, focusing: cell.column)
            case 123: return addColumn(to: attachment, at: cell.column, focusingRow: cell.row)
            case 124: return addColumn(to: attachment, at: cell.column + 1, focusingRow: cell.row)
            default: break
            }
        }
        guard let command = NoteCommandCatalog.command(for: event) else { return false }
        if case let .mark(kind) = command, kind != .link {
            return applyCellMark(kind, in: view)
        }
        return false
    }

    /// A mark on the cell's selected text, or on every selected cell.
    @discardableResult
    func applyCellMark(_ kind: NoteMark.Kind, in view: NoteTableView, url: String? = nil) -> Bool {
        guard let attachment = view.attachment else { return false }
        if let range = view.cellSelection {
            let allOn = range.positions.allSatisfy { position in
                let cell = attachment.table[position]
                return cell.text.isEmpty || cell.marks.contains { $0.kind == kind && $0.offset == 0 && $0.length == (cell.text as NSString).length }
            }
            return changeTable(attachment, name: NoteFormatCommand.mark(kind).title) { table in
                for position in range.positions where table.contains(position) {
                    table[position] = Self.cell(table[position], settingMark: kind, on: !allOn, url: url)
                }
            }
        }
        guard view.isEditingCell, let storage = view.editor.textStorage else { return false }
        let selection = view.editor.selectedRange()
        if selection.length == 0 {
            // No selection: the next characters typed take the mark.
            var typing = view.editor.typingAttributes
            let on = typing[.noteMark(kind)] == nil
            typing[.noteMark(kind)] = on ? (url ?? true) as Any : nil
            let base = (typing[.font] as? NSFont) ?? style.bodyFont
            var marks: [NoteMark.Kind: Any] = [:]
            for mark in NoteMark.Kind.allCases { if let value = typing[.noteMark(mark)] { marks[mark] = value } }
            typing.merge(style.markedAttributes(marks: marks, baseFont: view.table.headerRow && view.activeCell?.row == 0 ? style.tableHeaderFont : style.bodyFont)) { _, new in new }
            if marks[.bold] == nil && marks[.italic] == nil && marks[.code] == nil { typing[.font] = base }
            view.editor.typingAttributes = typing
            return true
        }
        var on = false
        storage.enumerateAttribute(.noteMark(kind), in: selection) { value, _, stop in
            if value == nil { on = true; stop.pointee = true }
        }
        let cell = Self.cell(NoteTextCodec.cell(from: storage), settingMark: kind, on: on, url: url, in: selection)
        guard let active = view.activeCell else { return false }
        let applied = changeTable(attachment, name: NoteFormatCommand.mark(kind).title,
                                  before: NoteTableFocus(position: active, selection: selection),
                                  after: NoteTableFocus(position: active, selection: selection)) { $0[active] = cell }
        if applied { view.editor.place(.range(selection)) }
        return applied
    }

    /// `cell` with mark `kind` on (or off) over `range` (the whole text by
    /// default); objects are never marked.
    static func cell(_ cell: NoteTable.Cell, settingMark kind: NoteMark.Kind, on: Bool, url: String?,
                     in range: NSRange? = nil) -> NoteTable.Cell {
        let units = Array(cell.text.utf16)
        let span = range ?? NSRange(location: 0, length: units.count)
        var flags = Array(repeating: false, count: units.count)
        var urls = Array(repeating: String?.none, count: units.count)
        for mark in cell.marks where mark.kind == kind {
            for index in mark.offset..<min(units.count, mark.offset + mark.length) {
                flags[index] = true
                urls[index] = mark.url
            }
        }
        for index in max(0, span.location)..<min(units.count, NSMaxRange(span)) where units[index] != NoteDocument.objectUnit {
            flags[index] = on
            urls[index] = on ? url : nil
        }
        var result = cell
        result.marks.removeAll { $0.kind == kind }
        var start: Int?
        for index in 0...units.count {
            let marked = index < units.count && flags[index] && units[index] != NoteDocument.objectUnit
            if marked, start == nil { start = index }
            let breaks = index == units.count || !marked || (start != nil && urls[index] != urls[start!])
            if breaks, let begin = start, index > begin {
                result.marks.append(NoteMark(kind, offset: begin, length: index - begin, url: urls[begin]))
                start = marked ? index : nil
            }
        }
        result.marks.sort { ($0.kind.rawValue, $0.offset) < ($1.kind.rawValue, $1.offset) }
        return result
    }
}

// MARK: - Paste

/// Tabular data on a pasteboard (spec § 4.4): Attic's own table fragment,
/// an HTML `<table>` (Excel, Numbers, a web page), tab-separated text
/// (spreadsheets) or a Markdown pipe table.
@MainActor
enum NoteTablePaste {
    static let tableType = NSPasteboard.PasteboardType("com.taha.attic.note-table")
    static let tsvType = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")

    static func table(from pasteboard: NSPasteboard) -> NoteTable? {
        if let data = pasteboard.data(forType: tableType),
           case let .editable(document) = NoteContentCodec.decode(data, context: .fragment),
           let table = document.blocks.first(where: { $0.kind == .table })?.table {
            return table.withFreshIDs()
        }
        if let html = pasteboard.string(forType: .html), let parsed = NoteTableText.parseHTML(html) {
            return NoteTable(texts: parsed.rows, headerRow: true)
        }
        if let tsv = pasteboard.string(forType: tsvType) ?? pasteboard.string(forType: .string),
           let rows = NoteTableText.parseTSV(tsv) {
            return NoteTable(texts: rows, headerRow: true)
        }
        if let text = pasteboard.string(forType: .string), let table = NoteTableText.parseMarkdown(text) {
            return table
        }
        return nil
    }

    /// A table's pasteboard forms: Attic's own, an HTML table, TSV and
    /// Markdown (as plain text, so a Markdown editor reads a table).
    static func write(_ table: NoteTable, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let fragment = NoteDocument(blocks: [.table(table)])
        if let data = try? NoteContentCodec.encode(fragment, context: .fragment) { pasteboard.setData(data, forType: tableType) }
        pasteboard.setString(html(table), forType: .html)
        pasteboard.setString(NoteTableText.tsv(table), forType: tsvType)
        pasteboard.setString(NoteTableText.markdown(table, cellText: NoteEditorEngine.markdownCellText), forType: .string)
    }

    static func html(_ table: NoteTable) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        }
        var html = "<table>"
        for (index, row) in table.rows.enumerated() {
            let tag = table.headerRow && index == 0 ? "th" : "td"
            html += "<tr>" + zip(row.cells, table.columns).map { cell, column in
                let align = column.align == .left ? "" : " style=\"text-align:\(column.align.rawValue)\""
                return "<\(tag)\(align)>\(escape(cell.displayText))</\(tag)>"
            }.joined() + "</tr>"
        }
        return html + "</table>"
    }
}
