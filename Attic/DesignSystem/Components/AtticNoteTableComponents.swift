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
    /// A drag that was cancelled (O4-02): Escape, the panel losing key
    /// status or hiding, the view leaving its window, or
    /// `AtticDragTracking.cancelAll()` (a page switch). The drag's move is
    /// not made.
    var onDragCancel: (() -> Void)?
    var hoverCursor: NSCursor { .arrow }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        let tracking = AtticDragTracking(view: self, window: window)
        var dragging = false
        defer { if dragging { NSCursor.pop() }; window.invalidateCursorRects(for: self) }
        while true {
            // Checked after each wait: an event dequeued after the drag
            // was interrupted (its release, say) moves nothing.
            let next = tracking.nextEvent()
            if tracking.isInterrupted {
                if dragging { onDragCancel?() }
                return
            }
            guard let next else { continue }
            if AtticDragTracking.isCancel(next) {
                // Esc ends the drag where it is; the button is still down,
                // and its release (and any move before it) does nothing.
                if dragging { onDragCancel?() }
                tracking.waitForRelease()
                return
            }
            guard next.type == .leftMouseDragged || next.type == .leftMouseUp else { continue }
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

/// A press-and-drag tracking loop that ends the way a native drag does
/// (O4-02): Escape cancels it, and so does the window losing key status
/// or hiding, the view leaving its window or being hidden, or
/// `cancelAll()` (the Notes page going away mid-drag). The loop wakes at
/// least every 50 ms to notice the ones that send it no event.
@MainActor
struct AtticDragTracking {
    /// Bumped by `cancelAll()`; a tracking loop started under an older
    /// value is interrupted.
    private(set) static var generation = 0
    /// Cancels every drag being tracked now.
    static func cancelAll() { generation &+= 1 }

    static let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .keyDown, .appKitDefined]
    static let wake: TimeInterval = 0.05

    let view: NSView
    let window: NSWindow
    private let wasKey: Bool
    private let wasVisible: Bool
    private let started: Int

    init(view: NSView, window: NSWindow) {
        self.view = view
        self.window = window
        wasKey = window.isKeyWindow
        wasVisible = window.isVisible
        started = Self.generation
    }

    /// Esc (no modifiers but Fn) cancels.
    static func isCancel(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 53
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    var isInterrupted: Bool {
        started != Self.generation || view.window !== window || (wasVisible && !window.isVisible)
            || view.isHiddenOrHasHiddenAncestor || (wasKey && !window.isKeyWindow)
    }

    /// The next drag, release or key event, or nil after `wake` with none.
    /// AppKit's own events (activation, key status) are handled at once,
    /// so `isInterrupted` sees them.
    func nextEvent() -> NSEvent? {
        guard let event = window.nextEvent(matching: Self.mask, until: Date(timeIntervalSinceNow: Self.wake),
                                           inMode: .eventTracking, dequeue: true) else { return nil }
        if event.type == .appKitDefined {
            NSApp.sendEvent(event)
            return nil
        }
        return event
    }

    /// After a cancel: swallows the rest of the press (moves and keys)
    /// until its release, or until the loop is interrupted.
    func waitForRelease() {
        while !isInterrupted {
            if nextEvent()?.type == .leftMouseUp { return }
        }
    }
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

