import AppKit
import QuartzCore

/// N-3: shared document-coordinate geometry; independent of event delivery
/// and refresh rate so the edge cases can run in an unshown window.
enum MarqueeGeometry {
    static let threshold: CGFloat = 4
    static let edge: CGFloat = 24

    static func activated(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= threshold
    }

    static func box(from start: CGPoint, to point: CGPoint) -> CGRect {
        CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
               width: abs(point.x - start.x), height: abs(point.y - start.y))
    }

    /// Touching an edge counts, even for a perfectly vertical sweep.
    static func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        a.maxX >= b.minX && a.minX <= b.maxX && a.maxY >= b.minY && a.minY <= b.maxY
    }

    /// Points/second, symmetric, continuous at the 24 pt activation edge.
    static func scrollVelocity(pointerY: CGFloat, viewport: CGRect) -> CGFloat {
        let top = viewport.minY + edge, bottom = viewport.maxY - edge
        let distance = pointerY < top ? pointerY - top : (pointerY > bottom ? pointerY - bottom : 0)
        return max(-1_200, min(1_200, distance * 12))
    }

    static func scrollOrigin(current: CGFloat, velocity: CGFloat, seconds: Double,
                             minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, current + velocity * min(0.05, max(0, seconds))))
    }
}

struct MarqueeItem {
    let id: AnyHashable
    let rect: CGRect
}

/// One small AppKit bridge for both pages. The page owns the selection and
/// commands; this owns only the pointer, display clock and transient box.
@MainActor
final class AtticMarqueeController: NSObject {
    enum Press { case select, move, ignore }
    weak var scrollView: NSScrollView?
    var items: () -> [MarqueeItem] = { [] }
    var selection: () -> Set<AnyHashable> = { [] }
    var apply: (Set<AnyHashable>) -> Void = { _ in }
    var press: (CGPoint, NSEvent) -> Press = { _, _ in .ignore }
    var click: (CGPoint) -> Void = { _ in }
    var clear: () -> Void = {}
    var embeddedClick: () -> Void = {}
    var move: (CGPoint) -> Void = { _ in }
    var movePreview: (CGPoint) -> CGRect? = { _ in nil }
    var selectionEnded: (CGPoint) -> Void = { _ in }
    var enabled: () -> Bool = { true }
    var drawsHighlights = true
    private(set) var isDragging = false
    private(set) var box: CGRect?
    private var origin: CGPoint?
    private var windowPoint = CGPoint.zero
    private var originalWindowPoint = CGPoint.zero
    private var additive = Set<AnyHashable>()
    private var moving = false
    private var insertion: CGRect?
    private var monitor: Any?
    private var clipObserver: NSObjectProtocol?
    private var link: CADisplayLink?
    private var frameWatch: AtticFrameWatch?
    private var previousFrame: CFTimeInterval?
    private var released: CFTimeInterval?
    private var highlights: [AnyHashable: (rect: CGRect, alpha: CGFloat, target: CGFloat)] = [:]
    private let overlay = MarqueeOverlay()
    private lazy var ticker = MarqueeTicker(owner: self)

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init()
        overlay.controller = self
        overlay.frame = scrollView.bounds
        overlay.autoresizingMask = [.width, .height]
        scrollView.addSubview(overlay)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                               object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        link?.invalidate()
        frameWatch?.stop()
        overlay.removeFromSuperview()
    }

    func invalidate() {
        origin = nil
        box = nil
        insertion = nil
        isDragging = false
        released = nil
        highlights = [:]
        stopClock()
        overlay.needsDisplay = true
    }

    private var viewport: CGRect {
        guard let scroll = scrollView else { return .zero }
        let clip = scroll.contentView
        let insets = clip.contentInsets
        var rect = clip.bounds
        rect.origin.y += max(0, insets.top)
        rect.size.height -= max(0, insets.top) + max(0, insets.bottom)
        return scroll.convert(rect, from: clip)
    }

    /// Internal for unshown-window event-path tests.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let scroll = scrollView, let document = scroll.documentView,
              event.window === scroll.window, !scroll.isHiddenOrHasHiddenAncestor, enabled() else {
            if origin != nil { invalidate() }
            return event
        }
        if event.type == .keyDown {
            let focus = scroll.window?.firstResponder as? NSView
            guard origin != nil || focus?.isDescendant(of: scroll) == true else { return event }
            if event.keyCode == 53, origin != nil || !selection().isEmpty {
                clear()
                origin = nil; isDragging = false; insertion = nil
                released = box == nil ? nil : CACurrentMediaTime()
                frameWatch?.stop(); frameWatch = nil
                refresh()
                if released != nil { startClock() }
                return nil
            }
            return event
        }
        let point = document.convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            guard viewport.contains(scroll.convert(event.locationInWindow, from: nil)) else { return event }
            // Embedded table/subtask editors and native controls keep their
            // clicks, even if their frame lies in nominal document whitespace.
            if let root = scroll.window?.contentView {
                var hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
                while let view = hit, view !== document {
                    if view is NSControl || view is NSTextView { embeddedClick(); return event }
                    hit = view.superview
                }
            }
            let disposition = press(point, event)
            guard disposition != .ignore, event.clickCount == 1 else { return event }
            origin = point
            windowPoint = event.locationInWindow
            originalWindowPoint = windowPoint
            additive = event.modifierFlags.contains(.shift) ? selection() : []
            moving = disposition == .move
            released = nil
            return nil
        case .leftMouseDragged:
            guard origin != nil else { return event }
            windowPoint = event.locationInWindow
            if !isDragging, MarqueeGeometry.activated(from: originalWindowPoint, to: windowPoint) {
                isDragging = true
                frameWatch = PerformanceSignposts.watchFrames("MarqueeDragFrames", view: scroll)
                PerformanceSignposts.noteInput("marquee-begin")
                startClock()
            }
            if isDragging { updateSelection() }
            return nil
        case .leftMouseUp:
            guard origin != nil else { return event }
            windowPoint = event.locationInWindow
            if isDragging {
                updateSelection()
                if moving { move(point) }
                else { selectionEnded(point) }
                released = CACurrentMediaTime()
                frameWatch?.stop(); frameWatch = nil
                PerformanceSignposts.noteInput("marquee-end selected=\(selection().count)")
            } else { click(point) }
            origin = nil
            isDragging = false
            refresh()
            return nil
        default: return event
        }
    }

    private func updateSelection() {
        guard let origin, let document = scrollView?.documentView else { return }
        let point = document.convert(windowPoint, from: nil)
        if !moving {
            let rect = MarqueeGeometry.box(from: origin, to: point)
            box = rect
            let hit = Set(items().filter { MarqueeGeometry.touches(rect, $0.rect) }.map(\.id)).union(additive)
            if hit != selection() { apply(hit) }
        } else { insertion = movePreview(point) }
        refresh()
    }

    func refresh() {
        guard drawsHighlights else { overlay.needsDisplay = true; return }
        let selected = selection()
        guard !selected.isEmpty || !highlights.isEmpty else { overlay.needsDisplay = true; return }
        for id in highlights.keys { highlights[id]?.target = 0 }
        if !selected.isEmpty {
            for item in items() where selected.contains(item.id) {
                highlights[item.id] = (item.rect, highlights[item.id]?.alpha ?? 0, 1)
            }
        }
        if highlights.values.contains(where: { $0.alpha != $0.target }) { startClock() }
        overlay.needsDisplay = true
    }

    private func startClock() {
        guard link == nil, let scroll = scrollView, scroll.window != nil else { return }
        let link = scroll.displayLink(target: ticker, selector: #selector(MarqueeTicker.frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        previousFrame = nil
    }

    private func stopClock() {
        link?.invalidate(); link = nil
        previousFrame = nil
        frameWatch?.stop(); frameWatch = nil
    }

    fileprivate func frame(_ link: CADisplayLink) {
        let delta = previousFrame.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        previousFrame = link.timestamp
        if isDragging, let scroll = scrollView, let document = scroll.documentView {
            // Sample once per refresh, including when the pointer has stopped
            // outside the edge. The origin remains in the document as it scrolls.
            windowPoint = scroll.window?.mouseLocationOutsideOfEventStream ?? windowPoint
            let local = overlay.convert(windowPoint, from: nil)
            let velocity = MarqueeGeometry.scrollVelocity(pointerY: local.y, viewport: overlay.convert(viewport, from: scroll))
            let clip = scroll.contentView
            var next = clip.bounds.origin
            next.y = MarqueeGeometry.scrollOrigin(current: next.y, velocity: velocity, seconds: delta,
                minimum: -clip.contentInsets.top,
                maximum: max(-clip.contentInsets.top, document.frame.height - clip.bounds.height + clip.contentInsets.bottom))
            if next != clip.bounds.origin { clip.scroll(to: next); scroll.reflectScrolledClipView(clip) }
            updateSelection()
        }
        for id in Array(highlights.keys) {
            guard var value = highlights[id] else { continue }
            let step = CGFloat(delta / (value.target > value.alpha ? 0.08 : 0.06))
            value.alpha = value.target > value.alpha ? min(value.target, value.alpha + step) : max(value.target, value.alpha - step)
            highlights[id] = value.alpha == 0 && value.target == 0 ? nil : value
        }
        if let released, CACurrentMediaTime() - released >= 0.12 { box = nil; insertion = nil; self.released = nil }
        overlay.needsDisplay = true
        if !isDragging, released == nil, !highlights.values.contains(where: { $0.alpha != $0.target }) { stopClock() }
    }

    fileprivate func draw() {
        guard let scroll = scrollView, let document = scroll.documentView else { return }
        NSBezierPath(rect: overlay.convert(viewport, from: scroll)).addClip()
        // Clip the whole run once, then fade its slices independently. Only
        // the outside corners round; inner joins never expose white stripes.
        NSGraphicsContext.saveGraphicsState()
        var runs: [CGRect] = []
        for rect in highlights.values.map(\.rect).sorted(by: { $0.minY < $1.minY }) {
            if let last = runs.last, abs(last.minX - rect.minX) < 0.5,
               abs(last.width - rect.width) < 0.5, rect.minY <= last.maxY + 0.5 {
                runs[runs.count - 1] = last.union(rect)
            } else { runs.append(rect) }
        }
        let clip = NSBezierPath()
        for run in runs { clip.append(NSBezierPath(roundedRect: overlay.convert(run, from: document), xRadius: 4, yRadius: 4)) }
        clip.addClip()
        for alpha in Set(highlights.values.map(\.alpha)) {
            let path = NSBezierPath()
            for value in highlights.values where value.alpha == alpha {
                path.appendRect(overlay.convert(value.rect, from: document))
            }
            NSColor.labelColor.withAlphaComponent(0.075 * alpha).setFill()
            path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let box {
            let opacity = released.map { max(0, 1 - (CACurrentMediaTime() - $0) / 0.12) } ?? 1
            let path = NSBezierPath(rect: overlay.convert(box, from: document))
            NSColor.black.withAlphaComponent(0.045 * opacity).setFill(); path.fill()
            NSColor.labelColor.withAlphaComponent(0.22 * opacity).setStroke()
            path.lineWidth = 0.5; path.stroke()
        }
        if let insertion {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(rect: overlay.convert(insertion, from: document)).fill()
        }
    }
}

@MainActor
private final class MarqueeTicker: NSObject {
    weak var owner: AtticMarqueeController?
    init(owner: AtticMarqueeController) { self.owner = owner }
    @objc func frame(_ link: CADisplayLink) { owner?.frame(link) }
}

private final class MarqueeOverlay: NSView {
    weak var controller: AtticMarqueeController?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { controller?.draw() }
}
