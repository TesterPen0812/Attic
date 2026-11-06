import AppKit
import QuartzCore
import SwiftUI

/// The panel blurring under the chat (the design's `blur(10px) saturate(1.3)`
/// over a faint surface tint), opening from the ✦ as a circle. Core Animation
/// draws the blur and runs the wipe, so opening costs the main thread nothing
/// per frame, and it exists only while the chat is on screen. It also catches
/// Escape, wherever the keyboard is.
struct AgentChatBackdrop: NSViewRepresentable {
    var shown: Bool
    /// Where the circle opens from, in this view's top-left coordinates.
    var origin: CGPoint
    var tint: NSColor
    /// Reduce Motion: a fade, not a wipe.
    var fades: Bool
    /// Reduce Transparency, or no blur available: the tint alone, near solid.
    var solid: Bool
    var onEscape: @MainActor () -> Void
    var didMake: @MainActor (AgentChatBackdropView) -> Void = { _ in }

    func makeNSView(context: Context) -> AgentChatBackdropView {
        let view = AgentChatBackdropView()
        didMake(view)
        return view
    }

    func updateNSView(_ view: AgentChatBackdropView, context: Context) {
        view.onEscape = onEscape
        view.configure(tint: tint, solid: solid)
        view.setShown(shown, origin: origin, fades: fades)
    }

    static func dismantleNSView(_ view: AgentChatBackdropView, coordinator: ()) { view.stopWatchingKeys() }
}

final class AgentChatBackdropView: NSView {
    /// `cubic-bezier` values and lengths from the design's wipe.
    static let opening = (x1: Float(0.3), y1: Float(0.7), x2: Float(0.2), y2: Float(1), duration: 0.62)
    static let closing = (x1: Float(0.5), y1: Float(0), x2: Float(0.8), y2: Float(0.4), duration: 0.4)
    static let blurRadius: CGFloat = 5
    static let saturation: CGFloat = 1.3

    var onEscape: @MainActor () -> Void = {}
    private let backdrop: CALayer?
    private let tintLayer = CALayer()
    private var isShown: Bool?
    private var pending: (shown: Bool, origin: CGPoint, fades: Bool)?
    nonisolated(unsafe) private var keyMonitor: Any?

    init() {
        backdrop = AtticVariableBlurView.backdropClass?.init()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        if let backdrop {
            backdrop.setValue(false, forKey: "windowServerAware")
            backdrop.filters = [Self.filter("gaussianBlur", ("inputRadius", Self.blurRadius)),
                                Self.filter("colorSaturate", ("inputAmount", Self.saturation))].compactMap { $0 }
            layer?.addSublayer(backdrop)
        }
        layer?.addSublayer(tintLayer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private static func filter(_ type: String, _ value: (String, CGFloat)) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject?,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")) else { return nil }
        let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject
        filter?.setValue(value.1, forKey: value.0)
        return filter
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopWatchingKeys() } else { watchKeys() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        backdrop?.setValue(window?.backingScaleFactor ?? 2, forKey: "scale")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        tintLayer.frame = bounds
        CATransaction.commit()
        if let pending, !bounds.isEmpty {
            self.pending = nil
            setShown(pending.shown, origin: pending.origin, fades: pending.fades)
        }
    }

    func configure(tint: NSColor, solid: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = tint.cgColor
        backdrop?.isHidden = solid
        CATransaction.commit()
    }

    /// Runs the wipe or fade the first time and on every change of `shown`.
    func setShown(_ shown: Bool, origin: CGPoint, fades: Bool) {
        guard shown != isShown else { return }
        guard !bounds.isEmpty else {
            pending = (shown, origin, fades)
            return
        }
        let first = isShown == nil
        isShown = shown
        let layers = [backdrop, tintLayer].compactMap { $0 }
        if fades {
            for layer in layers {
                layer.mask = nil
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = shown ? 0 : 1
                fade.toValue = shown ? 1 : 0
                fade.duration = 0.2
                layer.opacity = shown ? 1 : 0
                layer.add(fade, forKey: "fade")
            }
            return
        }
        let reach = hypot(max(origin.x, bounds.width - origin.x), max(origin.y, bounds.height - origin.y)) + 2
        let small = Self.circle(at: origin, radius: 0.5)
        let large = Self.circle(at: origin, radius: reach)
        let timing = shown ? Self.opening : Self.closing
        for layer in layers {
            let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.frame = bounds
            mask.fillColor = NSColor.black.cgColor
            layer.mask = mask
            let wipe = CABasicAnimation(keyPath: "path")
            wipe.fromValue = shown || first ? small : large
            wipe.toValue = shown ? large : small
            wipe.duration = timing.duration
            wipe.timingFunction = CAMediaTimingFunction(controlPoints: timing.x1, timing.y1, timing.x2, timing.y2)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.path = shown ? large : small
            CATransaction.commit()
            mask.add(wipe, forKey: "wipe")
        }
    }

    private static func circle(at centre: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    private func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.keyCode == 53, event.window === self.window, self.isShown == true else { return event }
                self.onEscape()
                return nil
            }
        }
    }

    func stopWatchingKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
