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
    /// Told when a wipe starts, so the colour over the blur can follow it.
    var onWipe: @MainActor (AgentChatWipe?) -> Void = { _ in }
    var didMake: @MainActor (AgentChatBackdropView) -> Void = { _ in }

    func makeNSView(context: Context) -> AgentChatBackdropView {
        let view = AgentChatBackdropView()
        didMake(view)
        return view
    }

    func updateNSView(_ view: AgentChatBackdropView, context: Context) {
        view.onEscape = onEscape
        view.onWipe = onWipe
        view.configure(tint: tint, solid: solid)
        view.setShown(shown, origin: origin, fades: fades)
    }

    static func dismantleNSView(_ view: AgentChatBackdropView, coordinator: ()) { view.stopWatchingKeys() }
}

/// One open or close of the blur, shared by what moves with it: the blur and
/// tint here, and the colour the alive layer draws over them. The circle has a
/// soft rim (`feather` of its radius), which grows and shrinks with it.
struct AgentChatWipe: Equatable {
    /// The part of the circle's radius that fades out to its edge.
    static let feather: CGFloat = 0.24

    var shown: Bool
    var start: Date
    var origin: CGPoint
    /// The furthest corner from the origin: where the solid part must end up.
    var reach: CGFloat
    /// From `from` to the end, as a fraction of the full radius.
    var from: CGFloat
    var duration: Double
    var curve: (x1: Double, y1: Double, x2: Double, y2: Double)

    /// The circle's radius when fully open, rim included.
    var fullRadius: CGFloat { reach / (1 - Self.feather) }
    static func smallest(reach: CGFloat) -> CGFloat { 0.5 / (reach / (1 - feather)) }

    /// The circle's scale at `date`: the wipe's curve, as Core Animation runs it.
    func scale(at date: Date) -> CGFloat {
        let t = duration > 0 ? date.timeIntervalSince(start) / duration : 1
        let to: CGFloat = shown ? 1 : Self.smallest(reach: reach)
        return from + (to - from) * CGFloat(AgentEase.curve(curve.x1, curve.y1, curve.x2, curve.y2, t))
    }

    func isRunning(at date: Date) -> Bool { date.timeIntervalSince(start) < duration }

    /// Equatable by the wipe's identity: the tuple holds only its curve.
    static func == (a: AgentChatWipe, b: AgentChatWipe) -> Bool {
        a.shown == b.shown && a.start == b.start && a.origin == b.origin && a.reach == b.reach && a.from == b.from
    }
}

final class AgentChatBackdropView: NSView {
    /// `cubic-bezier` values and lengths from the design's wipe.
    static let opening = (x1: Float(0.3), y1: Float(0.7), x2: Float(0.2), y2: Float(1), duration: 0.62)
    static let closing = (x1: Float(0.5), y1: Float(0), x2: Float(0.8), y2: Float(0.4), duration: 0.4)
    static let blurRadius: CGFloat = 5
    static let saturation: CGFloat = 1.3

    var onEscape: @MainActor () -> Void = {}
    var onWipe: @MainActor (AgentChatWipe?) -> Void = { _ in }
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
            onWipe(nil)
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
        let timing = shown ? Self.opening : Self.closing
        let small = AgentChatWipe.smallest(reach: reach)
        let wipe = AgentChatWipe(shown: shown, start: Date(), origin: origin, reach: reach, from: shown || first ? small : 1,
                                 duration: timing.duration,
                                 curve: (Double(timing.x1), Double(timing.y1), Double(timing.x2), Double(timing.y2)))
        onWipe(wipe)
        let radius = wipe.fullRadius
        for layer in layers {
            let mask = (layer.mask as? CAGradientLayer) ?? Self.softMask()
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = wipe.from
            animation.toValue = shown ? 1 : small
            animation.duration = timing.duration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: timing.x1, timing.y1, timing.x2, timing.y2)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            mask.position = origin
            mask.transform = CATransform3DMakeScale(shown ? 1 : small, shown ? 1 : small, 1)
            CATransaction.commit()
            layer.mask = mask
            mask.add(animation, forKey: "wipe")
        }
    }

    /// A round mask with a soft rim, so the wipe's edge never slices through text.
    private static func softMask() -> CAGradientLayer {
        let mask = CAGradientLayer()
        mask.type = .radial
        mask.startPoint = CGPoint(x: 0.5, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 1)
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.locations = [0, NSNumber(value: Double(1 - AgentChatWipe.feather)), 1]
        return mask
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
