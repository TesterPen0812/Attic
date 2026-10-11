import AppKit
import QuartzCore

/// A note table's hover-free controls (sheet 3, panel 2), drawn from the
/// tokens: the column and row grips (a pill with three dots), the "+" chips
/// at the table's ends, and the sideways scroll indicator under a wide
/// table. AppKit views: they sit over the note's text and move with its
/// layout, never re-rendering it. Each keeps a 28 pt hit target.
@MainActor
class AtticNoteTableControlView: NSView {
    var design: AtticDesignContext = .default { didSet { if design != oldValue { needsDisplay = true } } }
    var tokens: AtticColorTokens { AtticColorTokens.resolve(design) }
    /// The drawn part, centred in the view (the view is the hit target).
    var drawnSize: CGSize = .zero { didSet { needsDisplay = true } }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var drawnRect: CGRect {
        CGRect(x: (bounds.width - drawnSize.width) / 2, y: (bounds.height - drawnSize.height) / 2,
               width: drawnSize.width, height: drawnSize.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A click (the pointer moved less than 3 pt).
    var onClick: (() -> Void)?
    /// A drag: the pointer in the window, and whether it ended.
    var onDrag: ((_ windowPoint: CGPoint, _ ended: Bool) -> Void)? {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var hoverCursor: NSCursor { .arrow }

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        var dragging = false
        defer { if dragging { NSCursor.pop() }; window?.invalidateCursorRects(for: self) }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = next.locationInWindow
            if !dragging, hypot(point.x - start.x, point.y - start.y) >= 3, onDrag != nil { dragging = true; NSCursor.closedHand.push() }
            if dragging { onDrag?(point, next.type == .leftMouseUp) }
            if next.type == .leftMouseUp { break }
        }
        if !dragging { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: hoverCursor) }
}

/// A row's or a column's grip: a 5 × 14 (row) or 18 × 5 (column) pill with
/// three dots along it.
@MainActor
final class AtticNoteTableGripView: AtticNoteTableControlView {
    override var hoverCursor: NSCursor { onDrag == nil ? .arrow : .openHand }
    enum Axis { case row, column }
    let axis: Axis

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        drawnSize = axis == .row ? AtticNoteTableMetrics.rowGripSize : AtticNoteTableMetrics.columnGripSize
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not archived") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = drawnRect
        let radius = min(rect.width, rect.height) / 2
        let fill = isHovered ? tokens.tableGripDot.withAlpha(tokens.tableGripFill.alpha * 1.6) : tokens.tableGripFill
        fill.nsColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        tokens.tableGripDot.nsColor.setFill()
        let dot: CGFloat = 2, gap: CGFloat = 2
        let span = dot * 3 + gap * 2
        for index in 0..<3 {
            let offset = CGFloat(index) * (dot + gap)
            let origin = axis == .row
                ? CGPoint(x: rect.midX - dot / 2, y: rect.midY - span / 2 + offset)
                : CGPoint(x: rect.midX - span / 2 + offset, y: rect.midY - dot / 2)
            NSBezierPath(ovalIn: CGRect(origin: origin, size: CGSize(width: dot, height: dot))).fill()
        }
    }
}

/// The "+" at the end of the last column or under the last row: a 14 pt
/// disc with an 8 pt plus.
@MainActor
final class AtticNoteTableAddChipView: AtticNoteTableControlView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawnSize = CGSize(width: AtticNoteTableMetrics.addChipSize, height: AtticNoteTableMetrics.addChipSize)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not archived") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = drawnRect
        (isHovered ? tokens.tableGripFill : tokens.tableAddFill).nsColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let glyph = AtticNoteTableMetrics.addChipGlyph
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.midX - glyph / 2, y: rect.midY))
        path.line(to: CGPoint(x: rect.midX + glyph / 2, y: rect.midY))
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - glyph / 2))
        path.line(to: CGPoint(x: rect.midX, y: rect.midY + glyph / 2))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        tokens.ink(.helper).nsColor.setStroke()
        path.stroke()
    }
}

/// The overlay scroller's thumb under a wide table: 3 pt tall, as long as
/// the visible share of the table.
@MainActor
final class AtticNoteTableIndicatorView: NSView {
    var design: AtticDesignContext = .default { didSet { needsDisplay = true } }
    /// The visible share (0…1) and where it starts (0…1 of the rest).
    var share: CGFloat = 1 { didSet { needsDisplay = true } }
    var position: CGFloat = 0 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let width = max(24, bounds.width * share)
        let x = (bounds.width - width) * position
        let height = AtticNoteTableMetrics.indicatorHeight
        let rect = CGRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
        AtticColorTokens.resolve(design).tableIndicator.nsColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
    }
}
