import AppKit

/// A table's controls over the note's text (spec § 4.3, sheet 3 panel 2):
/// they appear only while the caret is in a table, and take their place
/// from its layout.
///
/// - The column grip, above the active column; the row grip, in the margin
///   at the active row. A click selects the column or row and opens its
///   menu; a drag moves it.
/// - "+" at the end of the last column and under the last row.
/// - The sideways indicator under a wide table while it scrolls, or while
///   the pointer is over it.
@MainActor
final class NoteTableChrome: NSObject {
    typealias M = AtticNoteTableMetrics
    let engine: NoteEditorEngine
    private weak var textView: NoteEditorTextView?
    let columnGrip = AtticNoteTableGripView(axis: .column)
    let rowGrip = AtticNoteTableGripView(axis: .row)
    let addColumnChip = AtticNoteTableAddChipView(frame: .zero)
    let addRowChip = AtticNoteTableAddChipView(frame: .zero)
    private var indicators: [ObjectIdentifier: AtticNoteTableIndicatorView] = [:]
    private var indicatorUntil: [ObjectIdentifier: Date] = [:]
    private var previousLayout: (() -> Void)?
    private var previousChromeChange: (() -> Void)?
    var design: AtticDesignContext {
        didSet {
            guard design != oldValue else { return }
            for view in [columnGrip, rowGrip, addColumnChip, addRowChip] as [AtticNoteTableControlView] { view.design = design }
            for indicator in indicators.values { indicator.design = design }
        }
    }
    /// The drag's target while a grip is being dragged.
    private var dragTarget: Int?

    init(engine: NoteEditorEngine, textView: NoteEditorTextView, design: AtticDesignContext) {
        self.engine = engine
        self.textView = textView
        self.design = design
        super.init()
        for view in [columnGrip, rowGrip, addColumnChip, addRowChip] as [AtticNoteTableControlView] {
            view.design = design
            view.isHidden = true
            textView.addSubview(view)
        }
        columnGrip.setAccessibilityLabel(String(localized: "Column"))
        rowGrip.setAccessibilityLabel(String(localized: "Row"))
        addColumnChip.setAccessibilityLabel(String(localized: "Add Column"))
        addRowChip.setAccessibilityLabel(String(localized: "Add Row"))
        columnGrip.setAccessibilityIdentifier("notes-table-column-grip")
        rowGrip.setAccessibilityIdentifier("notes-table-row-grip")
        addColumnChip.setAccessibilityIdentifier("notes-table-add-column")
        addRowChip.setAccessibilityIdentifier("notes-table-add-row")
        columnGrip.onClick = { [weak self] in self?.openMenu(.column) }
        rowGrip.onClick = { [weak self] in self?.openMenu(.row) }
        columnGrip.onDrag = { [weak self] point, ended in self?.drag(.column, to: point, ended: ended) }
        rowGrip.onDrag = { [weak self] point, ended in self?.drag(.row, to: point, ended: ended) }
        addColumnChip.onClick = { [weak self] in self?.addAtEnd(column: true) }
        addRowChip.onClick = { [weak self] in self?.addAtEnd(column: false) }
        previousLayout = textView.onLayout
        textView.onLayout = { [weak self] in
            self?.previousLayout?()
            self?.place()
        }
        previousChromeChange = engine.onTableChromeChange
        engine.onTableChromeChange = { [weak self] in
            self?.previousChromeChange?()
            self?.place()
        }
    }

    func invalidate() {
        textView?.onLayout = previousLayout
        engine.onTableChromeChange = previousChromeChange
        for view in [columnGrip, rowGrip, addColumnChip, addRowChip] as [NSView] { view.removeFromSuperview() }
        for indicator in indicators.values { indicator.removeFromSuperview() }
        indicators.removeAll()
    }

    // MARK: Placing

    /// The table's rectangle (its viewport in the text column), in the text view.
    private func frame(of view: NoteTableView) -> NSRect? {
        guard let textView, view.window === textView.window, view.window != nil else { return nil }
        return view.convert(view.bounds, to: textView)
    }

    func place() {
        guard let textView else { return }
        placeIndicators()
        guard !engine.isReadOnly, let table = engine.focusedTable, let rect = frame(of: table),
              let cell = table.activeCell ?? table.cellSelection?.head, table.table.contains(cell) else {
            for view in [columnGrip, rowGrip, addColumnChip, addRowChip] as [NSView] where !view.isHidden { view.isHidden = true }
            return
        }
        let grid = table.grid
        let offset = table.scrollOffset
        let hit = M.gripHitTarget
        func center(_ view: NSView, _ point: CGPoint) {
            let frame = CGRect(x: (point.x - hit / 2).rounded(), y: (point.y - hit / 2).rounded(), width: hit, height: hit)
            if view.frame != frame { view.frame = frame }
            if view.isHidden { view.isHidden = false }
            if view.superview !== textView { textView.addSubview(view) }
        }
        // The column grip above the active column (kept inside the viewport).
        let columnMid = rect.minX + grid.columnX(cell.column) + grid.columnWidths[cell.column] / 2 - offset
        let clampedMid = min(max(columnMid, rect.minX + M.columnGripSize.width / 2), rect.maxX - M.columnGripSize.width / 2)
        if dragTarget == nil || columnGripDragging == false {
            center(columnGrip, CGPoint(x: clampedMid, y: rect.minY - M.columnGripAbove + M.columnGripSize.height / 2))
        }
        if dragTarget == nil || rowGripDragging == false {
            center(rowGrip, CGPoint(x: rect.minX - M.rowGripFromColumn + M.rowGripSize.width / 2,
                                    y: rect.minY + grid.rowY(cell.row) + grid.rowHeights[cell.row] / 2))
        }
        let visibleWidth = min(grid.width - offset, rect.width)
        center(addColumnChip, CGPoint(x: rect.minX + visibleWidth + M.addChipGap + M.addChipSize / 2, y: rect.midY))
        center(addRowChip, CGPoint(x: rect.minX + visibleWidth / 2, y: rect.maxY + 5 + M.addChipSize / 2))
        columnGrip.setAccessibilityHelp(String(localized: "Column \(cell.column + 1). Opens the column's menu."))
        rowGrip.setAccessibilityHelp(String(localized: "Row \(cell.row + 1). Opens the row's menu."))
    }

    private var columnGripDragging = false
    private var rowGripDragging = false

    // MARK: The indicator

    /// A wide table's indicator shows while it scrolls (a moment after),
    /// or while the pointer is over it.
    private func placeIndicators() {
        guard let textView else { return }
        var live = Set<ObjectIdentifier>()
        for view in engine.tableViews() where view.grid.scrolls {
            let key = ObjectIdentifier(view)
            live.insert(key)
            guard let rect = frame(of: view) else { continue }
            let indicator = indicators[key] ?? {
                let made = AtticNoteTableIndicatorView(frame: .zero)
                made.design = design
                made.alphaValue = 0
                textView.addSubview(made)
                indicators[key] = made
                return made
            }()
            let frame = CGRect(x: rect.minX, y: rect.maxY + M.indicatorGap, width: rect.width, height: M.indicatorHeight)
            if indicator.frame != frame { indicator.frame = frame }
            let total = view.grid.width
            indicator.share = rect.width / max(1, total)
            indicator.position = view.scrollOffset / max(1, total - rect.width)
            var shown = view.isPointerInside || (indicatorUntil[key].map { $0 > Date() } ?? false)
            #if DEBUG
            // Capture seam: the indicator stays for the screenshot of a scrolled table.
            if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_TABLE_STATE"] == "wide", view.scrollOffset > 0 { shown = true }
            #endif
            setShown(indicator, shown)
        }
        for (key, indicator) in indicators where !live.contains(key) {
            indicator.removeFromSuperview()
            indicators[key] = nil
        }
    }

    /// Called as a table scrolls: the indicator shows, then fades.
    func tableDidScroll(_ view: NoteTableView) {
        let key = ObjectIdentifier(view)
        indicatorUntil[key] = Date().addingTimeInterval(1.0)
        placeIndicators()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in self?.placeIndicators() }
    }

    private func setShown(_ indicator: NSView, _ shown: Bool) {
        let target: CGFloat = shown ? 1 : 0
        guard abs(indicator.alphaValue - target) > 0.01 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            indicator.alphaValue = target
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = shown ? 0.12 : 0.3
                indicator.animator().alphaValue = target
            }
        }
    }

    // MARK: Grips and chips

    private enum Axis { case row, column }

    private func openMenu(_ axis: Axis) {
        guard let table = engine.focusedTable, let attachment = table.attachment,
              let cell = table.activeCell ?? table.cellSelection?.head, let textView else { return }
        let model = table.table
        // A click selects the whole column or row first.
        let range = axis == .column
            ? NoteTableCellRange(anchor: NoteTable.Position(row: 0, column: cell.column),
                                 head: NoteTable.Position(row: model.rowCount - 1, column: cell.column))
            : NoteTableCellRange(anchor: NoteTable.Position(row: cell.row, column: 0),
                                 head: NoteTable.Position(row: cell.row, column: model.columnCount - 1))
        table.selectCells(range)
        let engine = engine
        var commands: [AtticMenuCommand] = []
        switch axis {
        case .column:
            let column = cell.column
            let align = model.columns[column].align
            commands = [
                AtticMenuCommand("Add Column Before", systemImage: "arrow.left.to.line") { engine.addColumn(to: attachment, at: column, focusingRow: cell.row) },
                AtticMenuCommand("Add Column After", systemImage: "arrow.right.to.line") { engine.addColumn(to: attachment, at: column + 1, focusingRow: cell.row) },
                AtticMenuCommand("Move Left", systemImage: "arrow.left", isDisabled: column == 0, startsSection: true) {
                    engine.moveColumn(of: attachment, from: column, to: column - 1)
                },
                AtticMenuCommand("Move Right", systemImage: "arrow.right", isDisabled: column == model.columnCount - 1) {
                    engine.moveColumn(of: attachment, from: column, to: column + 1)
                },
                AtticMenuCommand("Align Left", systemImage: "text.alignleft", startsSection: true, isChecked: align == .left) {
                    engine.setAlignment(.left, of: attachment, columns: column...column)
                },
                AtticMenuCommand("Align Centre", systemImage: "text.aligncenter", isChecked: align == .center) {
                    engine.setAlignment(.center, of: attachment, columns: column...column)
                },
                AtticMenuCommand("Align Right", systemImage: "text.alignright", isChecked: align == .right) {
                    engine.setAlignment(.right, of: attachment, columns: column...column)
                },
                AtticMenuCommand("Delete Column", systemImage: "trash", isDestructive: true, startsSection: true) {
                    engine.deleteColumn(of: attachment, at: column)
                }
            ]
        case .row:
            let row = cell.row
            commands = [
                AtticMenuCommand("Add Row Above", systemImage: "arrow.up.to.line") { engine.addRow(to: attachment, at: row, focusing: cell.column) },
                AtticMenuCommand("Add Row Below", systemImage: "arrow.down.to.line") { engine.addRow(to: attachment, at: row + 1, focusing: cell.column) },
                AtticMenuCommand("Move Up", systemImage: "arrow.up", isDisabled: row == 0, startsSection: true) {
                    engine.moveRow(of: attachment, from: row, to: row - 1)
                },
                AtticMenuCommand("Move Down", systemImage: "arrow.down", isDisabled: row == model.rowCount - 1) {
                    engine.moveRow(of: attachment, from: row, to: row + 1)
                },
                AtticMenuCommand("Delete Row", systemImage: "trash", isDestructive: true, startsSection: true) {
                    engine.deleteRow(of: attachment, at: row)
                }
            ]
        }
        let grip = axis == .column ? columnGrip : rowGrip
        AtticNativeMenu.popUp(commands, below: grip.frame, in: textView)
    }

    /// Dragging a grip moves its column or row; it lands where the pointer
    /// is when the drag ends (one Undo step).
    private func drag(_ axis: Axis, to windowPoint: CGPoint, ended: Bool) {
        guard let table = engine.focusedTable, let attachment = table.attachment, let textView,
              let cell = table.activeCell ?? table.cellSelection?.head else { return }
        let local = table.canvas.convert(windowPoint, from: nil)
        let over = table.grid.position(at: local, clamped: true)
        let grip = axis == .column ? columnGrip : rowGrip
        if axis == .column { columnGripDragging = true } else { rowGripDragging = true }
        // The grip follows the pointer along its axis.
        let point = textView.convert(windowPoint, from: nil)
        var frame = grip.frame
        if axis == .column { frame.origin.x = point.x - frame.width / 2 } else { frame.origin.y = point.y - frame.height / 2 }
        grip.frame = frame
        dragTarget = axis == .column ? over?.column : over?.row
        guard ended else { return }
        columnGripDragging = false
        rowGripDragging = false
        let target = dragTarget
        dragTarget = nil
        if let target {
            if axis == .column, target != cell.column { engine.moveColumn(of: attachment, from: cell.column, to: target) }
            if axis == .row, target != cell.row { engine.moveRow(of: attachment, from: cell.row, to: target) }
        }
        place()
    }

    private func addAtEnd(column: Bool) {
        guard let table = engine.focusedTable, let attachment = table.attachment else { return }
        let cell = table.activeCell ?? table.cellSelection?.head ?? NoteTable.Position(row: 0, column: 0)
        if column {
            engine.addColumn(to: attachment, at: attachment.table.columnCount, focusingRow: cell.row)
        } else {
            engine.addRow(to: attachment, at: attachment.table.rowCount, focusing: cell.column)
        }
    }
}
