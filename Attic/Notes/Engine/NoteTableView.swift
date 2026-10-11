import AppKit
import QuartzCore

/// Where the caret goes in a cell.
enum NoteTableCaret: Equatable {
    case start, end, all
    case range(NSRange)
    /// The line nearest `x` (in the cell's text coordinates), on the first
    /// or last line.
    case firstLine(x: CGFloat), lastLine(x: CGFloat)
}

/// A rectangular block of cells, from an anchor to the moving end.
struct NoteTableCellRange: Equatable {
    var anchor: NoteTable.Position
    var head: NoteTable.Position

    var rows: ClosedRange<Int> { min(anchor.row, head.row)...max(anchor.row, head.row) }
    var columns: ClosedRange<Int> { min(anchor.column, head.column)...max(anchor.column, head.column) }
    var positions: [NoteTable.Position] {
        rows.flatMap { row in columns.map { NoteTable.Position(row: row, column: $0) } }
    }
    func contains(_ position: NoteTable.Position) -> Bool {
        rows.contains(position.row) && columns.contains(position.column)
    }
}

/// The cell and text selection an Undo step returns to.
struct NoteTableFocus: Equatable {
    var position: NoteTable.Position
    var selection: NSRange
}

// MARK: - Drawing

/// The grid as drawn on screen and on paper (sheet 3): a 0.5 pt grid in a
/// 10 pt rounded card, the header row semibold on its fill, a selection's
/// tint and the active cell's ring.
@MainActor
enum NoteTableDrawing {
    typealias M = AtticNoteTableMetrics

    static func draw(table: NoteTable, layout: NoteTableLayout, design: AtticDesignContext, style: NoteTextStyle,
                     string: (NoteTable.Position) -> NSAttributedString, skipping: NoteTable.Position?,
                     selection: NoteTableCellRange? = nil, active: NoteTable.Position? = nil,
                     dirty: CGRect? = nil) {
        let tokens = AtticColorTokens.resolve(design)
        let contrast = design.colourKey.increaseContrast
        let hairline = contrast ? M.contrastHairline : M.hairline
        let bounds = CGRect(origin: .zero, size: layout.size)
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: hairline / 2, dy: hairline / 2),
                                xRadius: M.radius, yRadius: M.radius)
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        if table.headerRow, !layout.rowHeights.isEmpty {
            tokens.tableHeaderFill.nsColor.setFill()
            CGRect(x: 0, y: 0, width: layout.width, height: layout.rowHeights[0]).fill()
        }
        if let selection {
            tokens.tableSelectionFill.nsColor.setFill()
            for position in selection.positions { layout.cellRect(position).fill(using: .sourceOver) }
        }
        let visible = dirty ?? bounds
        for row in table.rows.indices {
            let rowY = layout.rowY(row)
            guard rowY <= visible.maxY, rowY + layout.rowHeights[row] >= visible.minY else { continue }
            for column in table.columns.indices {
                let position = NoteTable.Position(row: row, column: column)
                guard position != skipping else { continue }
                let rect = layout.cellRect(position)
                guard rect.intersects(visible), !table[position].isEmpty else { continue }
                string(position).draw(with: layout.textRect(position), options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
        tokens.tableGrid.nsColor.setFill()
        var x: CGFloat = 0
        for width in layout.columnWidths.dropLast() {
            x += width
            CGRect(x: x - hairline / 2, y: 0, width: hairline, height: layout.height).fill(using: .sourceOver)
        }
        var y: CGFloat = 0
        for height in layout.rowHeights.dropLast() {
            y += height
            CGRect(x: 0, y: y - hairline / 2, width: layout.width, height: hairline).fill(using: .sourceOver)
        }
        NSGraphicsContext.restoreGraphicsState()
        tokens.tableGrid.nsColor.setStroke()
        card.lineWidth = hairline
        card.stroke()
        if let active {
            let ring = NSBezierPath(roundedRect: layout.cellRect(active).insetBy(dx: M.activeRingWidth / 2 - 0.5,
                                                                                 dy: M.activeRingWidth / 2 - 0.5),
                                    xRadius: M.activeRingRadius, yRadius: M.activeRingRadius)
            ring.lineWidth = M.activeRingWidth
            tokens.tableActiveRing.nsColor.setStroke()
            ring.stroke()
        }
    }
}

// MARK: - The table view

/// The view TextKit hosts for one table: the drawn grid in a sideways
/// scroll view (a table wider than the text column scrolls inside it, with
/// a fade at each cut edge), and one live cell editor laid over the active
/// cell. Keys move between cells; arrows at the table's edges leave it.
@MainActor
final class NoteTableView: NSView {
    typealias M = AtticNoteTableMetrics
    private(set) weak var attachment: NoteTableAttachment?
    /// The table's viewport: it clips the grid and carries the fade.
    let scrollView = NoteTableViewport()
    let canvas = NoteTableCanvas()
    private(set) lazy var editor: NoteTableCellEditor = {
        let editor = NoteTableCellEditor.make(table: self)
        canvas.addSubview(editor)
        return editor
    }()
    private(set) var hasEditor = false
    /// The cell being edited (the caret is in it).
    private(set) var activeCell: NoteTable.Position?
    /// A selection of whole cells (Esc, ⇧-arrows past a cell's edge, a
    /// drag across cells).
    private(set) var cellSelection: NoteTableCellRange?
    private(set) var grid = NoteTableLayout(columnWidths: [], rowHeights: [], viewportWidth: 264)
    private let fadeMask = CAGradientLayer()

    init(attachment: NoteTableAttachment) {
        self.attachment = attachment
        super.init(frame: NSRect(x: 0, y: 0, width: 264, height: 60))
        wantsLayer = true
        scrollView.wantsLayer = true
        scrollView.clipsToBounds = true
        scrollView.addSubview(canvas)
        scrollView.table = self
        canvas.table = self
        addSubview(scrollView)
        setAccessibilityElement(true)
        setAccessibilityRole(.table)
        refreshLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not archived") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    var table: NoteTable { attachment?.table ?? .blank() }
    var engine: NoteEditorEngine? { attachment?.engine }
    var style: NoteTextStyle { attachment?.style ?? NoteTextStyle() }

    /// The native text editor can install an I-beam over its attachment
    /// views after their cursor rectangles were evaluated. Resolve the
    /// table's actual resize hit strip again at that hover point.
    func edgeCursor(atWindowPoint point: CGPoint) -> NSCursor? {
        guard engine?.isReadOnly == false else { return .arrow }
        let local = canvas.convert(point, from: nil)
        guard local.y >= 0, local.y <= grid.height,
              let edge = grid.columnEdge(near: local.x), edge < table.columnCount - 1 || grid.scrolls else { return nil }
        return .resizeLeftRight
    }

    // MARK: Layout

    /// The text column's width, from the frame TextKit gave the view.
    private var viewportWidth: CGFloat { max(M.minColumnWidth, bounds.width) }

    func refreshLayout() {
        guard let attachment else { return }
        let next = attachment.layout(width: viewportWidth)
        let changed = next != grid
        grid = next
        scrollView.frame = bounds
        // As tall as the view (TextKit may give it a fraction more than the
        // grid), so the clip has nothing to scroll up and down.
        canvas.frame = CGRect(x: -scrollOffset, y: 0, width: max(grid.width, bounds.width), height: max(grid.height, bounds.height))
        clampScroll()
        if changed { canvas.needsDisplay = true }
        placeEditor()
        updateFade()
    }

    // MARK: The pointer over the table (its indicator shows)

    private(set) var isPointerInside = false
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        if grid.scrolls { engine?.onTableChromeChange?() }
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        if grid.scrolls { engine?.onTableChromeChange?() }
    }

    // MARK: Re-hosting

    /// TextKit takes the view out of the text and puts it back when the
    /// text before the table changes; the keyboard then returns to where it
    /// was. A view that does not come back hands the keyboard to the note.
    private(set) var keepsFocusThroughRehost = false
    private var focusBeforeRehost: (cell: NoteTable.Position?, selection: NSRange?, cells: NoteTableCellRange?)?

    /// Where the view last sat in the note's text view (to park it there).
    private var lastFrameInTextView: NSRect?
    /// Parked in the note's text view while TextKit has it out of the
    /// viewport (the note scrolled while a cell has the keyboard).
    private(set) var isParked = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, isFocused {
            keepsFocusThroughRehost = true
            focusBeforeRehost = (activeCell, hasEditor ? editor.selectedRange() : nil, cellSelection)
            if let textView = engine?.textView, window != nil, !isParked {
                lastFrameInTextView = convert(bounds, to: textView)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        // TextKit hosting it again ends a parking.
        if newSuperview != nil, newSuperview !== engine?.textView { isParked = false }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard keepsFocusThroughRehost else { return }
        if window != nil {
            restoreFocusAfterRehost()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.keepsFocusThroughRehost else { return }
                if self.window != nil {
                    self.restoreFocusAfterRehost()
                } else if let attachment = self.attachment, let engine = self.engine, engine.range(ofTable: attachment) != nil,
                          let textView = engine.textView, textView.window != nil {
                    // Scrolled out of TextKit's viewport while a cell has the
                    // keyboard: parked in the text view, the cell keeps it.
                    self.isParked = true
                    self.frame = self.lastFrameInTextView ?? NSRect(x: textView.textContainerOrigin.x, y: -10_000,
                                                                    width: self.bounds.width, height: self.bounds.height)
                    textView.addSubview(self)
                } else {
                    // Gone from the note (deleted, or its Undo): the note's text takes the keyboard.
                    self.keepsFocusThroughRehost = false
                    self.focusBeforeRehost = nil
                    self.deactivate()
                    if let textView = self.engine?.textView, let window = textView.window,
                       window.firstResponder === window || window.firstResponder == nil {
                        window.makeFirstResponder(textView)
                    }
                }
            }
        }
    }

    private func restoreFocusAfterRehost() {
        let saved = focusBeforeRehost
        keepsFocusThroughRehost = false
        focusBeforeRehost = nil
        guard let window, window.firstResponder === window || window.firstResponder == nil
            || window.firstResponder === editor || window.firstResponder === canvas else { return }
        if let cells = saved?.cells {
            selectCells(cells)
        } else if let cell = saved?.cell, table.contains(cell) {
            activate(cell, caret: saved?.selection.map(NoteTableCaret.range) ?? .end)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.25
        super.setFrameSize(newSize)
        if widthChanged { attachment?.invalidateLayout() }
        refreshLayout()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        // TextKit lays out attachment views after the note's layout callback.
        // Place the grips and add chips again using the table's final frame.
        engine?.onTableChromeChange?()
    }

    /// The model changed (typing, a structure change, an Undo, an agent).
    func modelDidChange() {
        let heightBefore = grid.height
        if let activeCell, !table.contains(activeCell) { self.activeCell = nil }
        if let selection = cellSelection, !(table.contains(selection.anchor) && table.contains(selection.head)) {
            cellSelection = nil
        }
        refreshLayout()
        canvas.needsDisplay = true
        if hasEditor, let activeCell, !editor.isApplyingOwnEdit {
            editor.load(cellString(activeCell), keepingSelection: true)
        }
        if hasEditor, activeCell == nil { editor.isHidden = true }
        if abs(grid.height - heightBefore) > 0.25 { engine?.tableLayoutDidChange(self) }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func cellString(_ position: NoteTable.Position) -> NSMutableAttributedString {
        attachment?.cellString(at: position) ?? NSMutableAttributedString()
    }

    private func placeEditor() {
        guard hasEditor else { return }
        guard let activeCell, table.contains(activeCell) else {
            editor.isHidden = true
            return
        }
        let rect = grid.textRect(activeCell)
        let height = max(rect.height, editor.contentHeight)
        let frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
        if editor.frame != frame { editor.frame = frame }
        editor.isHidden = false
    }

    // MARK: Scrolling

    /// How far the table is scrolled sideways (0 at its left edge).
    private(set) var scrollOffset: CGFloat = 0

    /// The furthest a wide table scrolls.
    var maxScrollOffset: CGFloat { max(0, grid.width - bounds.width) }

    func setScrollOffset(_ value: CGFloat) {
        let clamped = min(max(0, value), maxScrollOffset).rounded()
        guard abs(clamped - scrollOffset) > 0.01 else { return }
        scrollOffset = clamped
        canvas.setFrameOrigin(NSPoint(x: -clamped, y: 0))
        updateFade()
        engine?.tableDidScroll(self)
    }

    private func clampScroll() {
        if scrollOffset > maxScrollOffset { setScrollOffset(maxScrollOffset) }
    }

    /// Sideways scrolling over a wide table moves it until its end, and
    /// never chains into a page swipe or swipe-to-close (the panel leaves
    /// gestures over it alone, `AtticHorizontalScrollOwner`); scrolling up
    /// and down goes to the note. Each gesture keeps the axis it started on.
    private var gestureAxisIsSideways: Bool?

    override func scrollWheel(with event: NSEvent) {
        let starts = event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        if starts { gestureAxisIsSideways = nil }
        if gestureAxisIsSideways == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            gestureAxisIsSideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) && grid.scrolls
        }
        if gestureAxisIsSideways == true {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8
            setScrollOffset(scrollOffset - delta)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled), event.momentumPhase.isEmpty {
            // Momentum may follow and keeps the axis.
        }
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { gestureAxisIsSideways = nil }
    }

    /// The 16 pt fade at each cut edge, only while there is more that way.
    private func updateFade() {
        guard grid.scrolls, bounds.width > 2 * M.edgeFade else {
            scrollView.layer?.mask = nil
            return
        }
        let offset = scrollOffset
        let left = offset > 0.5, right = offset + bounds.width < grid.width - 0.5
        guard left || right else {
            scrollView.layer?.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = scrollView.bounds
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        let edge = M.edgeFade / bounds.width
        fadeMask.colors = [left ? NSColor.clear.cgColor : NSColor.black.cgColor, NSColor.black.cgColor,
                           NSColor.black.cgColor, right ? NSColor.clear.cgColor : NSColor.black.cgColor]
        fadeMask.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        scrollView.layer?.mask = fadeMask
        CATransaction.commit()
    }

    /// Scrolls sideways so `position`'s cell is in view.
    func scrollToVisible(_ position: NoteTable.Position) {
        guard grid.scrolls else { return }
        let rect = grid.cellRect(position)
        var offset = scrollOffset
        if rect.minX < offset + M.edgeFade { offset = max(0, rect.minX - (position.column == 0 ? 0 : M.edgeFade)) }
        if rect.maxX > offset + bounds.width - M.edgeFade {
            offset = min(grid.width - bounds.width,
                         rect.maxX - bounds.width + (position.column == table.columnCount - 1 ? 0 : M.edgeFade))
        }
        guard abs(offset - scrollOffset) > 0.25 else { return }
        setScrollOffset(offset)
    }

    // MARK: Editing a cell

    var isEditingCell: Bool { hasEditor && activeCell != nil && window?.firstResponder === editor }
    var isFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder === editor || responder === canvas
    }

    /// The keyboard is now in other text (the note's, another table's, a
    /// field) or the window lost it altogether.
    var keyboardLeftForText: Bool {
        guard let window else { return true }
        guard let responder = window.firstResponder else { return true }
        if responder === window { return !window.isKeyWindow }
        return responder is NSText || responder is NoteTableCanvas
    }

    /// Puts the caret in `position` (the keyboard comes to the table).
    func activate(_ position: NoteTable.Position, caret: NoteTableCaret = .end) {
        guard table.contains(position) else { return }
        let changedCell = activeCell != position || !hasEditor
        if cellSelection != nil {
            cellSelection = nil
            canvas.needsDisplay = true
        }
        activeCell = position
        hasEditor = true
        if changedCell || editor.isHidden {
            engine?.tableWillChangeCell(self)
            editor.prepare(header: table.headerRow && position.row == 0)
            editor.load(cellString(position), keepingSelection: false)
        }
        refreshLayout()
        placeEditor()
        canvas.needsDisplay = true
        scrollToVisible(position)
        if window?.firstResponder !== editor { window?.makeFirstResponder(editor) }
        editor.place(caret)
        engine?.tableFocusDidChange(self)
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }

    /// The keyboard left the table: the editor hides, the grid is drawn whole.
    func deactivate() {
        if isParked {
            // Parked out of view for the keyboard's sake; TextKit hosts it again when it is shown.
            isParked = false
            removeFromSuperview()
        }
        guard activeCell != nil || cellSelection != nil else { return }
        activeCell = nil
        cellSelection = nil
        if hasEditor { editor.isHidden = true }
        canvas.needsDisplay = true
        engine?.tableFocusDidChange(self)
    }

    /// Selects whole cells (the editor gives the keyboard to the grid).
    func selectCells(_ range: NoteTableCellRange) {
        guard table.contains(range.anchor), table.contains(range.head) else { return }
        cellSelection = range
        activeCell = nil
        if hasEditor { editor.isHidden = true }
        canvas.needsDisplay = true
        scrollToVisible(range.head)
        if window?.firstResponder !== canvas { window?.makeFirstResponder(canvas) }
        engine?.tableFocusDidChange(self)
    }

    /// The live text in the active cell became the model's (typing, IME,
    /// Writing Tools, a mark). One coalescing Undo step per cell.
    func editorTextDidChange(selectionBefore: NSRange) {
        guard let activeCell, let attachment, let engine else { return }
        let cell = NoteTextCodec.cell(from: editor.textStorage ?? NSTextStorage(), keeping: table[activeCell])
        guard cell != table[activeCell] else {
            refreshEditorHeight()
            return
        }
        editor.isApplyingOwnEdit = true
        defer { editor.isApplyingOwnEdit = false }
        engine.changeTable(attachment, name: String(localized: "Typing"), coalescing: activeCell,
                           before: NoteTableFocus(position: activeCell, selection: selectionBefore),
                           after: NoteTableFocus(position: activeCell, selection: editor.selectedRange())) { table in
            table[activeCell] = cell
        }
    }

    /// Composing text (IME) has no model change yet, but the row may grow.
    func refreshEditorHeight() {
        guard let activeCell, let attachment else { return }
        let rect = grid.textRect(activeCell)
        let needed = editor.contentHeight
        if needed > rect.height + 0.5 || abs(editor.frame.height - max(rect.height, needed)) > 0.5 {
            attachment.invalidateLayout()
            let before = grid.height
            refreshLayout()
            if abs(grid.height - before) > 0.25 { engine?.tableLayoutDidChange(self) }
        }
    }

    // MARK: Moving between cells

    enum Direction { case up, down, left, right }

    func neighbour(of position: NoteTable.Position, _ direction: Direction) -> NoteTable.Position? {
        var next = position
        switch direction {
        case .up: next.row -= 1
        case .down: next.row += 1
        case .left: next.column -= 1
        case .right: next.column += 1
        }
        return table.contains(next) ? next : nil
    }

    /// The caret's x in the table's coordinates (for ↑ ↓ into other cells).
    var caretX: CGFloat? {
        guard let activeCell, hasEditor else { return nil }
        return grid.textRect(activeCell).minX + editor.caretX
    }

    /// Arrows that cross a cell's edge: the neighbouring cell, or out of the
    /// table at its outer edge.
    func cross(_ direction: Direction) {
        guard let activeCell, let engine, let attachment else { return }
        let x = caretX
        if let next = neighbour(of: activeCell, direction) {
            let caret: NoteTableCaret
            switch direction {
            case .left: caret = .end
            case .right: caret = .start
            case .up: caret = .lastLine(x: (x ?? 0) - grid.textRect(next).minX)
            case .down: caret = .firstLine(x: (x ?? 0) - grid.textRect(next).minX)
            }
            activate(next, caret: caret)
        } else {
            engine.leaveTable(attachment, toward: direction, x: x.map { $0 - scrollOffset })
        }
    }

    /// ⇧-arrows past a cell's edge start a rectangular cell selection.
    func extendSelection(_ direction: Direction) {
        let range = cellSelection ?? activeCell.map { NoteTableCellRange(anchor: $0, head: $0) }
        guard var range else { return }
        if let next = neighbour(of: range.head, direction) { range.head = next }
        selectCells(range)
    }

    /// Tab: the next cell; in the last cell it adds a row. ⇧Tab: the previous.
    func tab(backward: Bool) {
        guard let activeCell, let engine, let attachment else { return }
        let table = self.table
        if backward {
            if activeCell.column > 0 { return activate(NoteTable.Position(row: activeCell.row, column: activeCell.column - 1), caret: .end) }
            if activeCell.row > 0 { return activate(NoteTable.Position(row: activeCell.row - 1, column: table.columnCount - 1), caret: .end) }
            return
        }
        if activeCell.column < table.columnCount - 1 {
            return activate(NoteTable.Position(row: activeCell.row, column: activeCell.column + 1), caret: .end)
        }
        if activeCell.row < table.rowCount - 1 {
            return activate(NoteTable.Position(row: activeCell.row + 1, column: 0), caret: .end)
        }
        engine.addRow(to: attachment, at: table.rowCount, focusing: 0)
    }

    /// Return: the cell below; on the last row a new row; Return in an
    /// empty last row removes it and leaves the table (as on an empty list
    /// item).
    func returnKey() {
        guard let activeCell, let engine, let attachment else { return }
        let table = self.table
        if activeCell.row < table.rowCount - 1 {
            return activate(NoteTable.Position(row: activeCell.row + 1, column: activeCell.column), caret: .end)
        }
        let rowIsEmpty = table.rows[activeCell.row].cells.allSatisfy(\.isEmpty)
        if rowIsEmpty, table.rowCount > 1, activeCell.row > (table.headerRow ? 0 : -1) {
            engine.removeLastEmptyRowAndLeave(attachment, row: activeCell.row)
            return
        }
        engine.addRow(to: attachment, at: table.rowCount, focusing: activeCell.column)
    }

    // MARK: Accessibility

    private var axCache: (table: NoteTable, rows: [NoteTableAXRow], columns: [NoteTableAXColumn])?

    private func axElements() -> (rows: [NoteTableAXRow], columns: [NoteTableAXColumn]) {
        if let axCache, axCache.table == table { return (axCache.rows, axCache.columns) }
        let table = self.table
        let rows = table.rows.indices.map { NoteTableAXRow(view: self, row: $0) }
        let columns = table.columns.indices.map { NoteTableAXColumn(view: self, column: $0) }
        for row in rows {
            row.cells = table.columns.indices.map { NoteTableAXCell(view: self, row: row.row, column: $0, parentRow: row) }
        }
        axCache = (table, rows, columns)
        return (rows, columns)
    }

    func axCell(_ position: NoteTable.Position) -> NoteTableAXCell? {
        let rows = axElements().rows
        guard rows.indices.contains(position.row), rows[position.row].cells.indices.contains(position.column) else { return nil }
        return rows[position.row].cells[position.column]
    }

    override func accessibilityLabel() -> String? {
        String(localized: "Table, \(table.columnCount) columns, \(table.rowCount) rows")
    }
    override func accessibilityRoleDescription() -> String? { NSAccessibility.Role.table.description(with: nil) }
    override func accessibilityChildren() -> [Any]? { axElements().rows }
    override func accessibilityRows() -> [Any]? { axElements().rows }
    override func accessibilityVisibleRows() -> [Any]? { axElements().rows }
    override func accessibilityColumns() -> [Any]? { axElements().columns }
    override func accessibilityVisibleColumns() -> [Any]? { axElements().columns }
    override func accessibilityRowCount() -> Int { table.rowCount }
    override func accessibilityColumnCount() -> Int { table.columnCount }
    override func accessibilityColumnHeaderUIElements() -> [Any]? {
        guard table.headerRow else { return nil }
        return axElements().rows.first?.cells
    }
    override func accessibilityRowHeaderUIElements() -> [Any]? { nil }
    override func accessibilitySelectedCells() -> [Any]? {
        if let cellSelection { return cellSelection.positions.compactMap(axCell) }
        return activeCell.flatMap(axCell).map { [$0] }
    }
    override func accessibilityCell(forColumn column: Int, row: Int) -> Any? {
        axCell(NoteTable.Position(row: row, column: column))
    }
}

// MARK: - Viewport

/// The table's viewport in the text column: it clips the grid (which moves
/// sideways inside it) and owns sideways scrolling while the table is wider
/// than the column.
final class NoteTableViewport: NSView, AtticHorizontalScrollOwner {
    weak var table: NoteTableView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    var ownsHorizontalScrolling: Bool { table?.grid.scrolls ?? false }
}

// MARK: - The grid (drawn) and its keys in cell-selection mode

@MainActor
final class NoteTableCanvas: NSView {
    weak var table: NoteTableView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { table?.cellSelection != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let table, let attachment = table.attachment else { return }
        let editing = table.hasEditor && table.activeCell != nil && !table.editor.isHidden
        NoteTableDrawing.draw(table: attachment.table, layout: table.grid,
                              design: attachment.engine?.objectDesign ?? attachment.style.design, style: attachment.style,
                              string: { position in
                                  let string = table.cellString(position)
                                  attachment.engine?.find.decorate(string, tableID: attachment.objectID, cell: position)
                                  return string
                              }, skipping: editing ? table.activeCell : nil,
                              selection: table.cellSelection, active: editing ? table.activeCell : nil, dirty: dirtyRect)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let table, table.engine?.isReadOnly == false else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        guard let position = table.grid.position(at: point, clamped: true) else { return }
        if let edge = table.grid.columnEdge(near: point.x), edge < table.table.columnCount - 1 || table.grid.scrolls {
            return trackColumnResize(edge, from: event)
        }
        if event.modifierFlags.contains(.shift), let anchor = table.activeCell ?? table.cellSelection?.anchor {
            table.selectCells(NoteTableCellRange(anchor: anchor, head: position))
            return
        }
        table.activate(position, caret: .end)
        // The click places the caret (and a drag selects) inside the cell;
        // a drag that leaves the cell selects whole cells.
        let editor = table.editor
        if event.clickCount > 1 {
            editor.mouseDown(with: event)
            return
        }
        let anchorIndex = editor.characterIndex(atWindowPoint: event.locationInWindow)
        editor.setSelectedRange(NSRange(location: anchorIndex, length: 0))
        var range: NoteTableCellRange?
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let local = convert(next.locationInWindow, from: nil)
            autoscroll(with: next)
            if let over = table.grid.position(at: local, clamped: true), over != position || range != nil {
                let selection = NoteTableCellRange(anchor: position, head: over)
                if selection != range {
                    range = selection
                    table.selectCells(selection)
                }
            } else if range == nil {
                let index = editor.characterIndex(atWindowPoint: next.locationInWindow)
                editor.setSelectedRange(NSRange(location: min(anchorIndex, index), length: abs(index - anchorIndex)))
            }
            if next.type == .leftMouseUp { break }
        }
    }

    private func trackColumnResize(_ column: Int, from event: NSEvent) {
        guard let table, let engine = table.engine, let attachment = table.attachment else { return }
        let start = convert(event.locationInWindow, from: nil).x
        let startWidth = table.grid.columnWidths[column]
        let before = attachment.table
        var changed = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let x = convert(next.locationInWindow, from: nil).x
            let width = max(AtticNoteTableMetrics.minDraggedWidth, (startWidth + x - start).rounded())
            engine.previewColumnWidth(attachment, column: column, width: width)
            changed = true
            if next.type == .leftMouseUp { break }
        }
        if changed { engine.commitColumnWidth(attachment, from: before) }
    }

    override func resetCursorRects() {
        guard let table else { return }
        guard table.engine?.isReadOnly == false else { addCursorRect(bounds, cursor: .arrow); return }
        var x: CGFloat = 0
        for (index, width) in table.grid.columnWidths.enumerated() {
            x += width
            guard index < table.grid.columnWidths.count - 1 || table.grid.scrolls else { continue }
            addCursorRect(CGRect(x: x - AtticNoteTableMetrics.resizeHitWidth / 2, y: 0,
                                 width: AtticNoteTableMetrics.resizeHitWidth, height: table.grid.height),
                          cursor: .resizeLeftRight)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let table, let engine = table.engine,
              let cell = table.grid.position(at: convert(event.locationInWindow, from: nil), clamped: true) else { return nil }
        let commands = engine.tableContextCommands(for: table, at: cell)
        return commands.isEmpty ? nil : AtticNativeMenu.make(commands, title: String(localized: "Table"))
    }

    // MARK: Keys with whole cells selected

    override func keyDown(with event: NSEvent) {
        guard let table, let engine = table.engine else { return super.keyDown(with: event) }
        if AtticPanel.isUndoKey(event) {
            // The note's history, never the panel's fallback.
            if event.modifierFlags.contains(.shift) { engine.redoCommand() } else { engine.undoCommand() }
            return
        }
        if engine.handleTableShortcut(event, in: table) { return }
        interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {
        guard let table, var range = table.cellSelection else { return super.doCommand(by: selector) }
        switch selector {
        case #selector(moveUp(_:)), #selector(moveDown(_:)), #selector(moveLeft(_:)), #selector(moveRight(_:)):
            let direction: NoteTableView.Direction = selector == #selector(moveUp(_:)) ? .up
                : selector == #selector(moveDown(_:)) ? .down : selector == #selector(moveLeft(_:)) ? .left : .right
            let next = table.neighbour(of: range.head, direction) ?? range.head
            table.selectCells(NoteTableCellRange(anchor: next, head: next))
        case #selector(moveUpAndModifySelection(_:)), #selector(moveDownAndModifySelection(_:)),
             #selector(moveLeftAndModifySelection(_:)), #selector(moveRightAndModifySelection(_:)):
            let direction: NoteTableView.Direction = selector == #selector(moveUpAndModifySelection(_:)) ? .up
                : selector == #selector(moveDownAndModifySelection(_:)) ? .down
                : selector == #selector(moveLeftAndModifySelection(_:)) ? .left : .right
            if let next = table.neighbour(of: range.head, direction) { range.head = next }
            table.selectCells(range)
        case #selector(insertNewline(_:)):
            table.activate(range.head, caret: .end)
        case #selector(insertTab(_:)):
            table.activate(range.head, caret: .end)
            table.tab(backward: false)
        case #selector(insertBacktab(_:)):
            table.activate(range.head, caret: .end)
            table.tab(backward: true)
        case #selector(deleteBackward(_:)), #selector(deleteForward(_:)):
            table.engine?.clearCells(in: table, range: range)
        case #selector(cancelOperation(_:)):
            // Esc again: the whole table.
            if let attachment = table.attachment { table.engine?.selectWholeTable(attachment) }
        case #selector(selectAll(_:)):
            let all = NoteTableCellRange(anchor: NoteTable.Position(row: 0, column: 0),
                                         head: NoteTable.Position(row: table.table.rowCount - 1, column: table.table.columnCount - 1))
            if range == all, let attachment = table.attachment { table.engine?.selectWholeTable(attachment) }
            else { table.selectCells(all) }
        default:
            break
        }
    }

    override func insertText(_ insertString: Any) {
        // Typing over selected cells edits the anchor cell, replacing its text.
        guard let table, let range = table.cellSelection else { return }
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        guard !text.isEmpty else { return }
        table.activate(range.anchor, caret: .all)
        table.editor.insertText(insertString, replacementRange: table.editor.selectedRange())
    }

    override func cancelOperation(_ sender: Any?) { doCommand(by: #selector(cancelOperation(_:))) }
    override func selectAll(_ sender: Any?) { doCommand(by: #selector(selectAll(_:))) }

    @objc func copy(_ sender: Any?) {
        guard let table, let range = table.cellSelection else { return }
        table.engine?.copyCells(in: table, range: range, to: .general)
    }

    @objc func cut(_ sender: Any?) {
        guard let table, let range = table.cellSelection else { return }
        table.engine?.copyCells(in: table, range: range, to: .general)
        table.engine?.clearCells(in: table, range: range, name: String(localized: "Cut"))
    }

    @objc func paste(_ sender: Any?) {
        guard let table, let range = table.cellSelection else { return }
        table.engine?.pasteIntoTable(table, at: NoteTable.Position(row: range.rows.lowerBound, column: range.columns.lowerBound),
                                     from: .general)
    }

    @objc func delete(_ sender: Any?) { doCommand(by: #selector(deleteBackward(_:))) }

    @objc func undo(_ sender: Any?) { table?.engine?.undoCommand() }
    @objc func redo(_ sender: Any?) { table?.engine?.redoCommand() }

    override var undoManager: UndoManager? { table?.engine?.textView?.undoShim ?? super.undoManager }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let table {
            DispatchQueue.main.async { [weak table] in
                guard let table, !table.isFocused, table.cellSelection != nil, !table.keepsFocusThroughRehost else { return }
                if table.keyboardLeftForText { table.deactivate() }
            }
        }
        return resigned
    }
}
