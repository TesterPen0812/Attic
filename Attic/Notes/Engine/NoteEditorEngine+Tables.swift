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

    /// The table the keyboard is in (a cell, or whole cells selected), or
    /// was in before one of the page's controls took it for a moment.
    var focusedTable: NoteTableView? {
        guard let table = activeTableView, table.engine === self, table.window != nil,
              table.activeCell != nil || table.cellSelection != nil else { return nil }
        return table
    }

    // MARK: Hosting

    /// The engine owns the tables it shows: their look, their hosted views.
    func adoptTable(_ table: NoteTableAttachment, force: Bool) {
        let restyled = force || table.style != style
        table.engine = self
        table.style = style
        table.allowsTextAttachmentView = true
        if restyled, let view = table.hostedView {
            table.invalidateLayout(clearingText: true)
            if let cell = view.activeCell, view.hasEditor {
                // The cell being edited takes the new inks and fonts too.
                view.editor.prepare(header: table.table.headerRow && cell.row == 0)
            }
            view.modelDidChange()
            view.canvas.needsDisplay = true
        } else if restyled {
            table.invalidateLayout(clearingText: true)
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

    func tableDidScroll(_ view: NoteTableView) {
        onTableScroll?(view)
        onTableChromeChange?()
    }

    func tableWillChangeCell(_ view: NoteTableView) { history.breakCoalescing() }

    func tableSelectionDidChange(_ view: NoteTableView?) {
        onTableChromeChange?()
        onTableFocusChange?()
    }

    func tableFocusDidChange(_ view: NoteTableView) {
        if view.activeCell != nil || view.cellSelection != nil {
            if activeTableView !== view { activeTableView?.deactivate() }
            activeTableView = view
        } else if activeTableView === view {
            activeTableView = nil
        }
        onTableChromeChange?()
        onTableFocusChange?()
        onCaretChange?()
        find.updateHighlights()
    }

    /// After one of the page's controls (Aa's row, a grip's menu): the
    /// keyboard goes back to the table it came from. False when none.
    @discardableResult
    func returnKeyboardToTable() -> Bool {
        guard let table = focusedTable, let window = table.window else { return false }
        if let range = table.cellSelection {
            if window.firstResponder !== table.canvas { window.makeFirstResponder(table.canvas) }
            _ = range
        } else if let cell = table.activeCell {
            if window.firstResponder !== table.editor {
                table.activate(cell, caret: .range(table.editor.selectedRange()))
            }
        }
        return true
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
        find.refresh()
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

    // MARK: The selection bar in a table

    /// A mark's state over the cell editor's selection (or the caret's
    /// typing attributes), or over every selected cell.
    func tableMarkState(_ kind: NoteMark.Kind) -> NoteFormatState? {
        guard let view = focusedTable, let attachment = view.attachment else { return nil }
        if let range = view.cellSelection {
            let cells = range.positions.map { attachment.table[$0] }.filter { !$0.text.isEmpty }
            guard !cells.isEmpty else { return .off }
            let full = cells.filter { cell in
                cell.marks.contains { $0.kind == kind && $0.offset == 0 && $0.length >= (cell.text as NSString).length }
            }.count
            return full == cells.count ? .on : (full == 0 && !cells.contains { $0.marks.contains { $0.kind == kind } } ? .off : .mixed)
        }
        guard view.isEditingCell || view.hasEditor, let storage = view.editor.textStorage else { return nil }
        let selection = view.editor.selectedRange()
        if selection.length == 0 { return view.editor.typingAttributes[.noteMark(kind)] == nil ? .off : .on }
        var on = 0, off = 0
        storage.enumerateAttribute(.noteMark(kind), in: selection) { value, _, _ in
            if value == nil { off += 1 } else { on += 1 }
        }
        return off == 0 ? .on : (on == 0 ? .off : .mixed)
    }

    /// The table selection's first and last line, in the text view's
    /// coordinates (the selection bar sits above or below them).
    func tableSelectionRects(in textView: NSTextView) -> (first: NSRect, last: NSRect)? {
        guard let view = focusedTable else { return nil }
        if let range = view.cellSelection {
            let top = view.grid.cellRect(NoteTable.Position(row: range.rows.lowerBound, column: range.columns.lowerBound))
            let bottom = view.grid.cellRect(NoteTable.Position(row: range.rows.upperBound, column: range.columns.upperBound))
            return (view.canvas.convert(top, to: textView), view.canvas.convert(bottom, to: textView))
        }
        let editor = view.editor
        let selection = editor.selectedRange()
        guard selection.length > 0, let layoutManager = editor.textLayoutManager,
              let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: selection.location),
              let end = content.location(start, offsetBy: selection.length),
              let range = NSTextRange(location: start, end: end) else { return nil }
        var frames: [NSRect] = []
        layoutManager.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
            frames.append(frame)
            return true
        }
        guard let first = frames.first, let last = frames.last else { return nil }
        return (editor.convert(first, to: textView), editor.convert(last, to: textView))
    }

    /// Link… on a cell's text: its selection (or the link around the caret)
    /// is captured and the page's link card opens for it.
    @discardableResult
    func requestCellLink(in view: NoteTableView) -> Bool {
        guard let attachment = view.attachment, let cell = view.activeCell, view.hasEditor,
              let storage = view.editor.textStorage else { return false }
        var selection = view.editor.selectedRange()
        var url: String?
        if selection.length == 0 {
            guard selection.location < storage.length else { return false }
            var effective = NSRange()
            url = storage.attribute(.noteMark(.link), at: selection.location, effectiveRange: &effective) as? String
            guard url != nil else { return false }
            selection = effective
        } else {
            url = storage.attribute(.noteMark(.link), at: selection.location, effectiveRange: nil) as? String
        }
        guard let onCellLinkRequest else { return false }
        onCellLinkRequest(NoteCellLinkTarget(tableID: attachment.objectID, position: cell, range: selection,
                                             selection: view.editor.selectedRange(), url: url))
        return true
    }

    /// The link card's address on a cell's text (nil removes the link).
    @discardableResult
    func commitCellLink(_ url: String?, target: NoteCellLinkTarget) -> Bool {
        guard let (attachment, _) = tableAttachment(id: target.tableID), attachment.table.contains(target.position),
              let view = attachment.hostedView else { return false }
        if let url {
            let parsed = URL(string: url)
            guard parsed?.scheme == "https" || parsed?.scheme == "http", parsed?.host != nil else { return false }
        }
        view.activate(target.position, caret: .range(target.range))
        let applied = applyCellMark(.link, in: view, url: url, on: url != nil)
        view.editor.place(.range(target.selection))
        return applied
    }

    /// Whole cells selected: the state the cells' bar shows.
    func cellSelectionState() -> NoteCellSelectionState? {
        guard let view = focusedTable, let range = view.cellSelection, let attachment = view.attachment else { return nil }
        let aligns = Set(range.columns.compactMap { attachment.table.columns.indices.contains($0) ? attachment.table.columns[$0].align : nil })
        return NoteCellSelectionState(alignment: aligns.count == 1 ? aligns.first : nil)
    }

    /// The cells' bar: copy, cut (clears, the grid stays) or clear.
    @discardableResult
    func perform(cellAction action: NoteCellAction, pasteboard: NSPasteboard = .general) -> Bool {
        guard let view = focusedTable, let range = view.cellSelection else { return false }
        switch action {
        case .copy:
            copyCells(in: view, range: range, to: pasteboard)
        case .cut:
            copyCells(in: view, range: range, to: pasteboard)
            clearCells(in: view, range: range, name: String(localized: "Cut"))
        case .clear:
            clearCells(in: view, range: range)
        }
        _ = returnKeyboardToTable()
        return true
    }

    /// A cell's right-click rows: the grips' and the row's actions, so
    /// nothing depends on the hover-only controls.
    func tableContextCommands(for view: NoteTableView, at cell: NoteTable.Position) -> [AtticMenuCommand] {
        guard !isReadOnly, let attachment = view.attachment, attachment.table.contains(cell) else { return [] }
        let table = attachment.table
        return [
            AtticMenuCommand("Add Row Above", systemImage: "arrow.up.to.line") { [weak self] in
                self?.addRow(to: attachment, at: cell.row, focusing: cell.column)
            },
            AtticMenuCommand("Add Row Below", systemImage: "arrow.down.to.line") { [weak self] in
                self?.addRow(to: attachment, at: cell.row + 1, focusing: cell.column)
            },
            AtticMenuCommand("Add Column Before", systemImage: "arrow.left.to.line", startsSection: true) { [weak self] in
                self?.addColumn(to: attachment, at: cell.column, focusingRow: cell.row)
            },
            AtticMenuCommand("Add Column After", systemImage: "arrow.right.to.line") { [weak self] in
                self?.addColumn(to: attachment, at: cell.column + 1, focusingRow: cell.row)
            },
            AtticMenuCommand("Delete Row", systemImage: "trash", isDisabled: table.rowCount < 2, startsSection: true) { [weak self] in
                self?.deleteRow(of: attachment, at: cell.row)
            },
            AtticMenuCommand("Delete Column", systemImage: "trash", isDisabled: table.columnCount < 2) { [weak self] in
                self?.deleteColumn(of: attachment, at: cell.column)
            },
            AtticMenuCommand("Header Row", startsSection: true, isChecked: table.headerRow) { [weak self] in
                self?.toggleHeaderRow(attachment)
            },
            AtticMenuCommand("Copy as Markdown") { [weak self] in self?.copyTableAsMarkdown(attachment) },
            AtticMenuCommand("Delete Table", systemImage: "trash", isDestructive: true) { [weak self] in
                self?.deleteTable(attachment)
            }
        ]
    }

    // MARK: Aa's row in a table

    func tableToolsState() -> NoteTableToolsState? {
        guard let table = focusedTable?.table else { return nil }
        return NoteTableToolsState(headerRow: table.headerRow, rows: table.rowCount, columns: table.columnCount)
    }

    /// The cell the tools act at: the active cell, or a cell selection's end.
    private var toolCell: (NoteTableAttachment, NoteTable.Position)? {
        guard let view = focusedTable, let attachment = view.attachment,
              let cell = view.activeCell ?? view.cellSelection?.head else { return nil }
        return (attachment, cell)
    }

    @discardableResult
    func perform(tableTool tool: NoteTableTool) -> Bool {
        guard let (attachment, cell) = toolCell else { return false }
        switch tool {
        case .addRow: return addRow(to: attachment, at: cell.row + 1, focusing: cell.column)
        case .addColumn: return addColumn(to: attachment, at: cell.column + 1, focusingRow: cell.row)
        case .deleteRow: return deleteRow(of: attachment, at: cell.row)
        case .deleteColumn: return deleteColumn(of: attachment, at: cell.column)
        }
    }

    @discardableResult
    func perform(tableMenu item: NoteTableMenuItem, attachment given: NoteTableAttachment? = nil) -> Bool {
        guard let attachment = given ?? toolCell?.0 else { return false }
        switch item {
        case .headerRow:
            let applied = toggleHeaderRow(attachment)
            _ = returnKeyboardToTable()
            return applied
        case .distributeColumns:
            let applied = distributeColumns(attachment)
            _ = returnKeyboardToTable()
            return applied
        case .convertToText: return convertTableToText(attachment)
        case .copyAsMarkdown:
            copyTableAsMarkdown(attachment)
            _ = returnKeyboardToTable()
            return true
        case .deleteTable: return deleteTable(attachment)
        }
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

    // MARK: Paste and the Markdown habit

    /// A table pasted over `selection` on its own line, as one Undo step;
    /// the note says so and offers Paste as Text.
    @discardableResult
    func pasteTable(_ table: NoteTable, at selection: NSRange, sourceText: String) -> Bool {
        guard table.isWithinLimits else {
            isPastingAsPlainText = true
            defer { isPastingAsPlainText = false }
            let pasted = pastePlainText(sourceText, at: selection)
            onNotice?(String(localized: "That table is larger than \(NoteTable.maxColumns) columns or \(NoteTable.maxRows) rows, so it was pasted as text."))
            return pasted
        }
        let marker = history.marker()
        guard insertTable(table, replacing: selection, name: String(localized: "Paste"), entering: false) else { return false }
        tablePasteOffer = NoteTablePasteOffer(text: sourceText, selection: selection, steps: marker + 1)
        onNotice?(NoteTablePasteOffer.notice)
        return true
    }

    /// "Paste as Text": the table paste is undone and its text pasted instead.
    @discardableResult
    func pasteLastTableAsText() -> Bool {
        guard let offer = tablePasteOffer, history.undoOps.count == offer.steps, history.undo() else {
            tablePasteOffer = nil
            return false
        }
        tablePasteOffer = nil
        isPastingAsPlainText = true
        defer { isPastingAsPlainText = false }
        return pastePlainText(offer.text, at: offer.selection)
    }

    /// `| a | b |` then Return: the row becomes a table's header with two
    /// empty rows, as the note's other Markdown habits do; one ⌘Z gives the
    /// text back.
    func convertPipeRowToTable(line: NSRange) -> Bool {
        let typed = (textStorage.string as NSString).substring(with: line)
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("|"), text.hasSuffix("|"), text.count > 2, paragraphStyle(at: line.location) != .mono,
              let cells = NoteTableText.pipeCells(text), cells.count >= 2,
              cells.count <= NoteTable.maxColumns, NoteTableText.delimiterAlignments(text) == nil else { return false }
        let table = NoteTable(texts: [cells] + Array(repeating: Array(repeating: "", count: cells.count), count: 2))
        let attachment = NoteTableAttachment(table: table)
        adoptTable(attachment, force: false)
        let replacement = NSMutableAttributedString(attributedString: NoteTextCodec.attachmentString(attachment, attributes: style.bodyAttributes))
        if NSMaxRange(line) == textStorage.length {
            replacement.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
        }
        guard performEdit(line, with: replacement, name: String(localized: "Table")) else { return false }
        // Undo gives back the row as typed, with the Return.
        history.setLastRestoredText(NSAttributedString(string: typed + "\n", attributes: style.bodyAttributes))
        enterTable(attachment, at: NoteTable.Position(row: 1, column: 0), caret: .start)
        return true
    }

    /// A table on its own line in place of `selection`: the text before it
    /// stays on its line, the text after it goes to the next. A paragraph
    /// always follows the table.
    @discardableResult
    func insertTable(_ table: NoteTable, replacing selection: NSRange, name: String, entering: Bool) -> Bool {
        guard !isReadOnly else { return false }
        let string = textStorage.string as NSString
        let title = titleParagraphRange
        var target = selection
        // Never in the title: after it.
        if target.location <= NSMaxRange(title) {
            target = NSRange(location: NSMaxRange(title), length: max(0, NSMaxRange(target) - NSMaxRange(title)))
        }
        let attachment = NoteTableAttachment(table: table)
        adoptTable(attachment, force: false)
        let insertion = NSMutableAttributedString()
        if target.location > 0, string.character(at: target.location - 1) != 0x0A {
            insertion.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
        }
        insertion.append(NoteTextCodec.attachmentString(attachment, attributes: style.bodyAttributes))
        let after = NSMaxRange(target)
        if after >= string.length || string.character(at: after) != 0x0A {
            insertion.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
        }
        let caret = target.location + insertion.length + (after < string.length && string.character(at: after) == 0x0A ? 1 : 0)
        guard performEdit(target, with: insertion, name: name,
                          selection: NSRange(location: min(caret, textStorage.length + insertion.length - target.length), length: 0))
        else { return false }
        if entering { enterTable(attachment, at: NoteTable.Position(row: 0, column: 0), caret: .start) }
        return true
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
    func applyCellMark(_ kind: NoteMark.Kind, in view: NoteTableView, url: String? = nil, on forced: Bool? = nil) -> Bool {
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
        if let forced { on = forced }
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

    /// Tabular plain text: tab-separated rows, or a Markdown pipe table.
    static func table(fromText text: String) -> NoteTable? {
        if let rows = NoteTableText.parseTSV(text) { return NoteTable(texts: rows, headerRow: true) }
        return NoteTableText.parseMarkdown(text)
    }

    /// An HTML paste that is a table and nothing else (Excel, Numbers, a
    /// table copied from a web page); a page with prose around a table
    /// stays rich text.
    static func table(fromHTML html: String) -> NoteTable? {
        guard let parsed = NoteTableText.parseHTML(html) else { return nil }
        guard let start = html.range(of: "<table", options: .caseInsensitive),
              let end = html.range(of: "</table>", options: [.caseInsensitive, .backwards]) else { return nil }
        let outside = NoteTableText.htmlText(String(html[..<start.lowerBound]) + String(html[end.upperBound...]))
        guard outside.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NoteTable(texts: parsed.rows, headerRow: true)
    }

    static func table(from pasteboard: NSPasteboard) -> NoteTable? {
        if let data = pasteboard.data(forType: tableType),
           case let .editable(document) = NoteContentCodec.decode(data, context: .fragment),
           let table = document.blocks.first(where: { $0.kind == .table })?.table {
            return table.withFreshIDs()
        }
        if let html = pasteboard.string(forType: .html), let table = table(fromHTML: html) { return table }
        if let tsv = pasteboard.string(forType: tsvType), let rows = NoteTableText.parseTSV(tsv) {
            return NoteTable(texts: rows, headerRow: true)
        }
        if let text = pasteboard.string(forType: .string) { return table(fromText: text) }
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

/// Link… on a cell: the table, the cell and the text the address goes on.
struct NoteCellLinkTarget: Equatable {
    var tableID: UUID
    var position: NoteTable.Position
    /// The linked run around a caret, or the selection.
    var range: NSRange
    var selection: NSRange
    var url: String?
}

/// What "Paste as Text" takes back: the pasted text, where it went, and
/// the history's depth just after the paste (it must still be the last step).
struct NoteTablePasteOffer: Equatable {
    static let notice = String(localized: "Pasted as a table.")
    var text: String
    var selection: NSRange
    var steps: Int
}
