import AppKit
import QuartzCore
import SwiftUI

/// The panel blurring under the chat (the design's `blur(10px) saturate(1.3)`
/// over a faint surface tint), opening from the ✦ as a circle. Core Animation
/// draws the blur; the wipe's progress is SwiftUI's, on the wipe's own curve,
/// so the blur, the colour over it, the thread and the composer all move on
/// one clock. (Run by Core Animation alone, the blur kept going through the
/// main thread's first frames while everything else waited, and the colour
/// arrived visibly later: screen 9, item 21.) It exists only while the chat
/// is on screen. It also catches Escape, wherever the keyboard is.
struct AgentChatBackdrop: NSViewRepresentable, Animatable {
    /// Where the wipe is going: open, or closing (Escape is then left alone).
    var shown: Bool
    /// 0: a point at the ✦ (or clear, when fading); 1: open.
    var reveal: CGFloat
    /// Where the circle opens from, in this view's top-left coordinates.
    var origin: CGPoint
    var tint: NSColor
    /// Reduce Motion: a fade, not a wipe.
    var fades: Bool
    /// Reduce Transparency, or no blur available: the tint alone, near solid.
    var solid: Bool
    var onEscape: @MainActor () -> Void
    var didMake: @MainActor (AgentChatBackdropView) -> Void = { _ in }

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    func makeNSView(context: Context) -> AgentChatBackdropView {
        let view = AgentChatBackdropView()
        didMake(view)
        return view
    }

    func updateNSView(_ view: AgentChatBackdropView, context: Context) {
        view.onEscape = onEscape
        view.isShown = shown
        view.configure(tint: tint, solid: solid)
        view.apply(reveal: reveal, origin: origin, fades: fades)
    }

    static func dismantleNSView(_ view: AgentChatBackdropView, coordinator: ()) { view.stopWatchingKeys() }
}

/// The wipe's circle, shared by what moves with it: the blur and tint, the
/// colour the alive layer draws over them, and the thread. The circle has a
/// soft rim (`feather` of its radius), which grows and shrinks with it.
struct AgentChatWipe: Equatable {
    /// The part of the circle's radius that fades out to its edge.
    static let feather: CGFloat = 0.24
    /// `cubic-bezier` values and lengths from the design's wipe.
    static let opening = (x1: 0.3, y1: 0.7, x2: 0.2, y2: 1.0, duration: 0.62)
    static let closing = (x1: 0.5, y1: 0.0, x2: 0.8, y2: 0.4, duration: 0.4)

    var origin: CGPoint
    /// The furthest corner from the origin: where the solid part must end up.
    var reach: CGFloat

    init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        reach = hypot(max(origin.x, size.width - origin.x), max(origin.y, size.height - origin.y)) + 2
    }

    /// The circle's radius when fully open, rim included.
    var fullRadius: CGFloat { reach / (1 - Self.feather) }
    /// Closed: half a point across, so nothing shows.
    var smallest: CGFloat { 0.5 / fullRadius }

    /// The circle's scale at `reveal` (0 closed, 1 open).
    func scale(reveal: CGFloat) -> CGFloat { smallest + (1 - smallest) * min(max(reveal, 0), 1) }

    /// The motion that takes `reveal` to 1 (opening) or 0 (closing).
    static func animation(opening: Bool) -> Animation {
        let t = opening ? Self.opening : Self.closing
        return .timingCurve(t.x1, t.y1, t.x2, t.y2, duration: t.duration)
    }
}

final class AgentChatBackdropView: NSView {
    static let blurRadius: CGFloat = 5
    static let saturation: CGFloat = 1.3

    var onEscape: @MainActor () -> Void = {}
    private let backdrop: CALayer?
    private let tintLayer = CALayer()
    var isShown = false
    nonisolated(unsafe) private var keyMonitor: Any?
    #if DEBUG
    /// Test seam: the circle's scale last applied to the blur and tint.
    private(set) var appliedScale: CGFloat?
    #endif

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
        if let last { apply(reveal: last.reveal, origin: last.origin, fades: last.fades) }
    }

    private var last: (reveal: CGFloat, origin: CGPoint, fades: Bool)?

    func configure(tint: NSColor, solid: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = tint.cgColor
        backdrop?.isHidden = solid
        CATransaction.commit()
    }

    /// Sets the blur and tint to `reveal`: a circle from `origin` with a soft
    /// rim, or, when it `fades`, the whole of it at that opacity. Called on
    /// every frame of the wipe, with no implicit motion of its own.
    func apply(reveal: CGFloat, origin: CGPoint, fades: Bool) {
        last = (reveal, origin, fades)
        guard !bounds.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for layer in [backdrop, tintLayer].compactMap({ $0 }) {
            if fades {
                layer.mask = nil
                layer.opacity = Float(min(max(reveal, 0), 1))
                continue
            }
            layer.opacity = 1
            let wipe = AgentChatWipe(origin: origin, size: bounds.size)
            let radius = wipe.fullRadius
            let scale = wipe.scale(reveal: reveal)
            let mask = (layer.mask as? CAGradientLayer) ?? Self.softMask()
            mask.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            mask.position = origin
            mask.transform = CATransform3DMakeScale(scale, scale, 1)
            layer.mask = mask
            #if DEBUG
            appliedScale = scale
            #endif
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
                guard let self, event.keyCode == 53, event.window === self.window, self.isShown else { return event }
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
