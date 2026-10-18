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
    /// The live reorder while a grip is being dragged (V-05).
    private var reorder: NoteTableReorder?

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
        // U-26: the add chips sit on the card's own edges, centred on its
        // outline (as the grips sit on theirs), so add-column stays clear of
        // the panel's edge and add-row leaves the next line its room.
        center(addColumnChip, CGPoint(x: rect.minX + visibleWidth, y: rect.midY))
        center(addRowChip, CGPoint(x: rect.minX + visibleWidth / 2, y: rect.minY + grid.height))
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
        // One Reduced policy (A4 M-07): the app's setting or macOS's; an
        // indicator is a fade, so F/E either way.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AtticMotionScale.fast
            context.timingFunction = AtticMotionScale.easeOutTimingFunction
            indicator.animator().alphaValue = target
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
    ///
    /// V-05: the column (or row) lifts onto a card that follows the pointer
    /// along its axis while the others slide apart to open the gap it will
    /// land in; on release the card settles into the gap and the move is
    /// made (`NoteTableReorder`).
    private func drag(_ axis: Axis, to windowPoint: CGPoint, ended: Bool) {
        guard let table = engine.focusedTable, let attachment = table.attachment, let textView,
              let cell = table.activeCell ?? table.cellSelection?.head else { return }
        let grip = axis == .column ? columnGrip : rowGrip
        if axis == .column { columnGripDragging = true } else { rowGripDragging = true }
        let source = axis == .column ? cell.column : cell.row
        if reorder == nil {
            reorder = NoteTableReorder(table: table, textView: textView, axis: axis == .column ? .column : .row,
                                       source: source, tokens: AtticColorTokens.resolve(design),
                                       animated: !design.reduceMotion, below: grip)
        }
        // The grip follows the pointer along its axis.
        let point = textView.convert(windowPoint, from: nil)
        var frame = grip.frame
        if axis == .column { frame.origin.x = point.x - frame.width / 2 } else { frame.origin.y = point.y - frame.height / 2 }
        grip.frame = frame
        reorder?.update(windowPoint: windowPoint)
        dragTarget = reorder?.target ?? source
        guard ended else { return }
        columnGripDragging = false
        rowGripDragging = false
        dragTarget = nil
        let session = reorder
        reorder = nil
        grip.isHidden = true
        let commit: (Int) -> Void = { [weak self, weak attachment] target in
            guard let self, let attachment else { return }
            if target != source {
                if axis == .column { self.engine.moveColumn(of: attachment, from: source, to: target) }
                else { self.engine.moveRow(of: attachment, from: source, to: target) }
            }
            self.place()
        }
        if let session { session.finish(commit) } else { commit(source) }
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


/// A table column or row being dragged by its grip (V-05). The table's
/// cells are shown as one snapshot strip per column (or row) over the
/// hidden canvas; the dragged one lifts onto a card (the dropdowns'
/// surface) that follows the pointer along the axis, and the others slide
/// apart to open the gap it will land in. On release the card settles into
/// the gap, the move is made, and the live table shows again in the same
/// turn. Snapshots are taken once, when the drag starts: nothing redraws
/// per frame but Core Animation's moves.
@MainActor
final class NoteTableReorder {
    enum Axis { case column, row }

    let axis: Axis
    let source: Int
    private(set) var target: Int
    private weak var table: NoteTableView?
    private weak var textView: NSView?
    private let sizes: [CGFloat]
    private let strips: [NSView]
    private let container = NoteTableReorderLayer()
    private let card: NoteDragLiftView
    private let animated: Bool
    private let canvasAlpha: CGFloat
    /// Where the pointer took the card, along the axis, from its start.
    private var grab: CGFloat?
    /// The strips as the canvas drew them.
    private let images: [NSImage?]
    /// A row drag in a table with a header row: the header's look (its
    /// fill and semibold text) belongs to the first place, not to the row
    /// that had it. Whichever row the drop would put first shows it, and
    /// the header row shows as a body row once it would leave (F5a V-05).
    private let headerRows: Bool
    /// The rows drawn in the other look, made once each when first needed.
    private var otherLooks: [Int: NSImage] = [:]
    /// The row shown with the header's look.
    private var headerOccupant = 0

    static let duration = AtticMotionScale.fast

    init?(table: NoteTableView, textView: NSView, axis: Axis, source: Int, tokens: AtticColorTokens,
          animated: Bool, below sibling: NSView?) {
        let grid = table.grid
        let sizes = axis == .column ? grid.columnWidths : grid.rowHeights
        guard sizes.indices.contains(source), sizes.count > 1 else { return nil }
        self.axis = axis
        self.source = source
        self.target = source
        self.table = table
        self.textView = textView
        self.sizes = sizes
        self.animated = animated
        let canvas = table.canvas
        canvasAlpha = canvas.alphaValue
        // One snapshot per strip, in the canvas's own drawing (its cells,
        // grid lines, header fill, selection and the cell being edited).
        var strips: [NSView] = []
        var images: [NSImage?] = []
        for index in sizes.indices {
            let rect = Self.stripRect(index, sizes: sizes, axis: axis, grid: grid)
            let image = NoteDragLiftView.snapshot(of: rect, in: canvas)
            images.append(image)
            let strip = NSView(frame: rect)
            strip.wantsLayer = true
            strip.layer?.contents = image
            strip.layer?.contentsGravity = .resize
            strips.append(strip)
        }
        self.strips = strips
        self.images = images
        headerRows = axis == .row && table.attachment?.table.headerRow == true
        container.frame = canvas.frame
        container.wantsLayer = true
        for (index, strip) in strips.enumerated() where index != source { container.addSubview(strip) }
        table.scrollView.addSubview(container, positioned: .above, relativeTo: canvas)
        let sourceRect = Self.stripRect(source, sizes: sizes, axis: axis, grid: grid)
        card = NoteDragLiftView(snapshot: images[source], size: sourceRect.size, padding: .zero, tokens: tokens)
        card.layer?.cornerRadius = 4
        card.frame = textView.convert(sourceRect, from: canvas)
        textView.addSubview(card, positioned: .below, relativeTo: sibling)
        canvas.alphaValue = 0
        CATransaction.flush()
    }

    private static func stripRect(_ index: Int, sizes: [CGFloat], axis: Axis, grid: NoteTableLayout) -> CGRect {
        let start = sizes.prefix(index).reduce(0, +)
        return axis == .column
            ? CGRect(x: start, y: 0, width: sizes[index], height: grid.height)
            : CGRect(x: 0, y: start, width: grid.width, height: sizes[index])
    }

    /// The strips' starts along the axis with `source` moved to `target`.
    static func starts(sizes: [CGFloat], source: Int, target: Int) -> [Int: CGFloat] {
        var order = Array(sizes.indices)
        order.remove(at: source)
        order.insert(source, at: target)
        var result: [Int: CGFloat] = [:]
        var position: CGFloat = 0
        for index in order {
            result[index] = position
            position += sizes[index]
        }
        return result
    }

    /// The slot the card (starting at `start`, along the axis) lands in.
    /// A strip before the source stays before it until the card's leading
    /// edge passes the strip's middle; one after it moves before it once
    /// the card's trailing edge does. F5a V-05: the earlier rule (the
    /// card's middle against the others' middles) could never give the
    /// first place when the strip there is shorter than the card: a row
    /// pushed hard against the table's top still landed second, under its
    /// own card, with a gap shown where nothing would land.
    static func target(sizes: [CGFloat], source: Int, start: CGFloat) -> Int {
        let size = sizes[source]
        var position: CGFloat = 0
        var before = 0
        for index in sizes.indices {
            defer { position += sizes[index] }
            guard index != source else { continue }
            let middle = position + sizes[index] / 2
            if index < source ? start >= middle : start + size > middle { before += 1 }
        }
        return before
    }

    func update(windowPoint: CGPoint) {
        guard let table, let textView else { return }
        let canvas = table.canvas
        let local = canvas.convert(windowPoint, from: nil)
        let along = axis == .column ? local.x : local.y
        let size = sizes[source]
        let total = sizes.reduce(0, +)
        let home = sizes.prefix(source).reduce(0, +)
        if grab == nil { grab = along - home }
        // The card follows the pointer, kept within the table.
        let start = min(max(along - (grab ?? size / 2), 0), max(0, total - size))
        var rect = Self.stripRect(source, sizes: sizes, axis: axis, grid: table.grid)
        if axis == .column { rect.origin.x = start } else { rect.origin.y = start }
        card.move(to: textView.convert(rect, from: canvas), animated: false)
        let next = Self.target(sizes: sizes, source: source, start: start)
        guard next != target else { return }
        target = next
        layOut(animated: animated)
        restyleHeader(animated: animated)
    }

    /// The header's look follows the first place (rows only): the row the
    /// drop would put first takes it, and the one it leaves goes plain.
    private func restyleHeader(animated: Bool) {
        guard headerRows, let table else { return }
        var order = Array(sizes.indices)
        order.remove(at: source)
        order.insert(source, at: target)
        let occupant = order[0]
        guard occupant != headerOccupant else { return }
        let previous = headerOccupant
        headerOccupant = occupant
        for index in [previous, occupant] {
            let image = look(of: index, asHeader: index == occupant, in: table)
            if index == source {
                card.setSnapshot(image, animated: animated, duration: Self.duration)
            } else {
                let layer = strips[index].layer
                if animated {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = Self.duration
                    layer?.add(fade, forKey: "look")
                }
                layer?.contents = image
            }
        }
        // The grip's tracking loop never commits implicit layer changes
        // (F5a V-06 met the same): commit the new looks now.
        CATransaction.flush()
    }

    /// Row `index` with the header's look or a body row's.
    private func look(of index: Int, asHeader: Bool, in table: NoteTableView) -> NSImage? {
        // The canvas drew row 0 as the header and the others plain.
        if asHeader == (index == 0) { return images[index] }
        if let made = otherLooks[index] { return made }
        let made = Self.rowImage(index, asHeader: asHeader, in: table)
        otherLooks[index] = made
        return made
    }

    /// Draws row `index` as it would look first (`asHeader`) or second, in
    /// its own height: the table drawn with that row moved there, cut to it.
    static func rowImage(_ index: Int, asHeader: Bool, in table: NoteTableView) -> NSImage? {
        guard let attachment = table.attachment else { return nil }
        let grid = table.grid
        var model = attachment.table
        let slot = asHeader ? 0 : 1
        guard grid.rowHeights.count == model.rowCount, model.moveRow(from: index, to: slot) else { return nil }
        var order = Array(grid.rowHeights.indices)
        order.remove(at: index)
        order.insert(index, at: slot)
        let layout = NoteTableLayout(columnWidths: grid.columnWidths, rowHeights: order.map { grid.rowHeights[$0] },
                                     viewportWidth: grid.viewportWidth)
        let rect = CGRect(x: 0, y: layout.rowY(slot), width: grid.width, height: layout.rowHeights[slot])
        let canvas = table.canvas
        guard rect.width > 0, rect.height > 0,
              let bitmap = canvas.bitmapImageRepForCachingDisplay(in: CGRect(origin: .zero, size: rect.size)),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        // The cell being edited keeps its soft fill, in its new place.
        let editing = table.hasEditor && !table.editor.isHidden ? table.activeCell : nil
        let active = editing.flatMap { cell in order.firstIndex(of: cell.row).map { NoteTable.Position(row: $0, column: cell.column) } }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // In points, whether or not the context already scales to pixels.
        let cg = context.cgContext
        let scale = CGFloat(bitmap.pixelsWide) / rect.width / max(cg.ctm.a, 0.0001)
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: rect.height)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: 0, y: -rect.minY)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        canvas.effectiveAppearance.performAsCurrentDrawingAppearance {
            NoteTableDrawing.draw(table: model, layout: layout,
                                  design: attachment.engine?.objectDesign ?? attachment.style.design, style: attachment.style,
                                  string: { attachment.cellString(at: $0, in: model) }, skipping: nil,
                                  active: active, strokesCard: canvas.strokesCard)
        }
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func layOut(animated: Bool) {
        let starts = Self.starts(sizes: sizes, source: source, target: target)
        let apply = {
            for (index, strip) in self.strips.enumerated() where index != self.source {
                var frame = strip.frame
                if self.axis == .column { frame.origin.x = starts[index] ?? frame.minX } else { frame.origin.y = starts[index] ?? frame.minY }
                if animated { strip.animator().frame = frame } else { strip.frame = frame }
            }
        }
        guard animated else { return apply() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            apply()
        }
    }

    /// Settles the card into its gap, then makes the move (`commit` with
    /// the target) and shows the live table again, in one turn.
    func finish(_ commit: @escaping (Int) -> Void) {
        guard let table, let textView else { return teardown() }
        let starts = Self.starts(sizes: sizes, source: source, target: target)
        var rect = Self.stripRect(source, sizes: sizes, axis: axis, grid: table.grid)
        if axis == .column { rect.origin.x = starts[source] ?? rect.minX } else { rect.origin.y = starts[source] ?? rect.minY }
        let landing = textView.convert(rect, from: table.canvas)
        pendingCommit = commit
        guard animated, landing != card.frame else { return land() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            card.animator().frame = landing
        }, completionHandler: { [self] in MainActor.assumeIsolated { land() } })
    }

    private var pendingCommit: ((Int) -> Void)?

    private func land() {
        let commit = pendingCommit
        pendingCommit = nil
        commit?(target)
        teardown()
    }

    private func teardown() {
        table?.canvas.alphaValue = canvasAlpha
        container.removeFromSuperview()
        card.removeFromSuperview()
    }
}

/// The reorder's strips: drawn only, never hit.
final class NoteTableReorderLayer: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
