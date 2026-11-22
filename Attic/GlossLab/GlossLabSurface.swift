#if ATTIC_GLOSS_LAB
import AppKit
import SwiftUI

// The Gloss lab's drawing on the live panel (experimental preview only).
// Everything here is vector shapes and unit-space gradients: no geometry
// reader, no blur, no picture redrawn while the panel resizes. Hit testing
// is off on every layer.

/// 1. Bare glass at the rim: a mask for the panel's foundation fill and
/// Tint that fades them out over the last `width` pt towards the edge,
/// following the panel's curve. Built from nested insets of the panel's own
/// squircle, one per pixel at 2x, so the ramp is linear in alpha and
/// re-paths on resize like any shape.
struct GlossRimFadeMask: View {
    let cornerSize: CGFloat
    let exponent: CGFloat
    let width: CGFloat

    var body: some View {
        let steps = Self.steps(width: width)
        let shape = Squircle(cornerRadius: cornerSize, exponent: exponent)
        if steps == 0 {
            shape.fill(Color.black)
        } else {
            ZStack {
                ForEach(Array(0..<steps), id: \.self) { k in
                    shape.inset(by: width * CGFloat(k) / CGFloat(steps))
                        .fill(Color.black.opacity(Self.alpha(step: k, of: steps)))
                }
            }
        }
    }

    static func steps(width: CGFloat) -> Int {
        width < 0.25 ? 0 : max(1, Int((width * 2).rounded(.up)))
    }

    /// The opacity of step `k` so that, laid over the steps before it,
    /// the mask's alpha inside inset k is (k + 1) / steps.
    static func alpha(step k: Int, of steps: Int) -> Double {
        let before = Double(k) / Double(steps)
        let after = Double(k + 1) / Double(steps)
        return (after - before) / (1 - before)
    }
}

/// 5 and 6, drawn over the panel's surface and under its content: the
/// light from the top with its bottom shade, and the fine grain.
struct GlossLabPanelSurfaceLayer: View {
    let cornerSize: CGFloat
    @Environment(\.atticDesign) private var design

    var body: some View {
        #if DEBUG
        let _ = GlossLabCounters.surfaceLayer += 1
        #endif
        let lab = GlossLab.shared
        let shape = Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent)
        ZStack {
            if lab.topLight {
                GlossTopLight(shape: shape, dark: design.mode == .dark, keepsOut: lab.topLightKeepsOut,
                              light: design.mode == .dark ? lab.topLightDark : lab.topLightLight,
                              shade: design.mode == .dark ? lab.bottomShadeDark : lab.bottomShadeLight,
                              rimFade: rimFade(lab))
            }
            if lab.grain {
                GlossGrain(percent: lab.grainPercent)
                    .clipShape(shape)
                    .glossLabRimFade(rimFade(lab))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension GlossLabPanelSurfaceLayer {
    /// With 1 on, 5 and 6 leave the rim bare too, as the foundation, the
    /// Tint and the lift do (glass surfaces only, as for those). Read only
    /// inside 5's and 6's branches, so flipping 1 with both off re-runs
    /// nothing here.
    private func rimFade(_ lab: GlossLab) -> GlossRimFadeMask? {
        guard lab.rimFade, design.tokens.panel.kind != .solid else { return nil }
        return GlossRimFadeMask(cornerSize: cornerSize, exponent: AtticStyle.panelSquircleExponent, width: lab.rimFadeWidth)
    }
}

/// 5. An additive white strongest at the top and gone by two thirds of the
/// height, and a soft shade over the bottom third. With `keepsOut`, both
/// leave the top and bottom control bands, as the lift does (Accepted
/// 2026-11-13), measured in points by a stack, not a geometry reader.
struct GlossTopLight: View {
    let shape: Squircle
    let dark: Bool
    let keepsOut: Bool
    let light: Double
    let shade: Double
    /// Idea 1's rim fade, or nil. It goes inside the blend, so the faded
    /// white still adds to the glass.
    var rimFade: GlossRimFadeMask?

    var body: some View {
        ZStack {
            shape.fill(LinearGradient(stops: [.init(color: .white.opacity(light), location: 0),
                                              .init(color: .white.opacity(light * 0.45), location: 0.3),
                                              .init(color: .white.opacity(0), location: 1)],
                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 2.0 / 3)))
                .mask { bands }
                .glossLabRimFade(rimFade)
                .blendMode(.plusLighter)
            shape.fill(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                              .init(color: .black.opacity(shade), location: 1)],
                                      startPoint: UnitPoint(x: 0.5, y: 2.0 / 3), endPoint: .bottom))
                .mask { bands }
                .glossLabRimFade(rimFade)
        }
    }

    @ViewBuilder
    private var bands: some View {
        if keepsOut {
            let clear = AtticSurfaceModel.LiftControlBands.clear
            let fade = AtticSurfaceModel.LiftControlBands.fade
            VStack(spacing: 0) {
                Color.clear.frame(height: clear)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fade)
                Color.clear.frame(height: clear)
            }
        } else {
            Color.black
        }
    }
}

/// 6. Fine grain: one small noise picture, made once, tiled, never
/// animated and never regenerated. Each pixel is black or white; the layer
/// is drawn at `percent` %.
struct GlossGrain: View {
    let percent: Double

    var body: some View {
        Image(decorative: Self.tile, scale: 2)
            .resizable(resizingMode: .tile)
            .opacity(percent / 100)
    }

    static let tile: CGImage = {
        let side = 128
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let v: UInt8 = (z & 1) == 0 ? 0 : 255
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v; bytes[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }()
}

/// 3 and 4, drawn over the panel at its rim (inside the clip, like the
/// trunk's rim): the Edge light and the second inner edge.
struct GlossLabPanelRimLayer: View {
    let cornerSize: CGFloat
    @Environment(\.atticDesign) private var design

    var body: some View {
        #if DEBUG
        let _ = GlossLabCounters.rimLayer += 1
        #endif
        let lab = GlossLab.shared
        let dark = design.mode == .dark
        let shape = Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent)
        ZStack {
            if lab.movingLight {
                // 9: the same light, drawn by Core Animation and tilted
                // towards the pointer without a SwiftUI body run.
                GlossMovingEdgeLight(cornerSize: cornerSize, width: lab.edgeLightWidth,
                                     strength: dark ? lab.edgeLightDark : lab.edgeLightLight,
                                     tilt: lab.movingLightTilt, reach: lab.movingLightReach)
            }
            if lab.edgeLight {
                let strength = dark ? lab.edgeLightDark : lab.edgeLightLight
                // Bright along the top and the upper sides, fading down.
                // With 9 on, 9 draws this light instead.
                if !lab.movingLight {
                    shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(strength), location: 0),
                                                              .init(color: .white.opacity(strength * 0.4), location: 0.22),
                                                              .init(color: .white.opacity(0), location: 0.55)],
                                                      startPoint: .top, endPoint: .bottom),
                                       lineWidth: lab.edgeLightWidth)
                }
                // A thin darker line along the bottom.
                shape.inset(by: 0.25)
                    .stroke(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.7),
                                                   .init(color: .black.opacity(lab.edgeLightShade), location: 1)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
            }
            if lab.innerEdge {
                shape.inset(by: lab.innerEdgeInset)
                    .stroke(Color.white.opacity(lab.innerEdgeStrength), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 9. Highlights that move: idea 3's Edge light (the same stroke, stops and
/// strengths) drawn by Core Animation, its gradient axis tilted a little
/// towards the pointer. Nothing here runs a SwiftUI body per pointer move:
/// a display link reads the pointer once per refresh and writes the
/// gradient's two points directly, with implicit actions off. Under Reduce
/// Motion (macOS or Settings) the link is stopped and the light rests where
/// idea 3 draws it.
struct GlossMovingEdgeLight: NSViewRepresentable {
    let cornerSize: CGFloat
    let width: CGFloat
    let strength: Double
    let tilt: Double
    let reach: Double

    func makeNSView(context: Context) -> GlossMovingEdgeLightView { GlossMovingEdgeLightView() }

    func updateNSView(_ view: GlossMovingEdgeLightView, context: Context) {
        #if DEBUG
        GlossLabCounters.movingUpdates += 1
        #endif
        view.configure(cornerSize: cornerSize, width: width, strength: strength, tilt: tilt, reach: reach)
    }

    static func dismantleNSView(_ view: GlossMovingEdgeLightView, coordinator: ()) { view.stop() }
}

final class GlossMovingEdgeLightView: NSView {
    #if DEBUG
    /// Tests only: the pointer in screen points, in place of the real one.
    @MainActor static var pointerForTesting: CGPoint?
    #endif

    private let gradient = CAGradientLayer()
    private let stroke = CAShapeLayer()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var cornerSize: CGFloat = 0
    private var width: CGFloat = 2.5
    private var tilt: Double = 10
    private var reach: Double = 0.06
    private var builtFor: (size: CGSize, corner: CGFloat, width: CGFloat)?
    /// Where the light points now and where the pointer asks it to go,
    /// each as (x, y) in -1...1 of the panel's half-size.
    private(set) var current = CGPoint.zero
    private var lastWritten: (start: CGPoint, end: CGPoint)?
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        gradient.mask = stroke
        stroke.fillColor = nil
        stroke.strokeColor = NSColor.black.cgColor
        gradient.actions = ["startPoint": NSNull(), "endPoint": NSNull(), "colors": NSNull(), "locations": NSNull(),
                            "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        stroke.actions = ["path": NSNull(), "lineWidth": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        gradient.locations = [0, 0.22, 0.55]
        layer?.addSublayer(gradient)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    var gradientPoints: (start: CGPoint, end: CGPoint) { (gradient.startPoint, gradient.endPoint) }

    func configure(cornerSize: CGFloat, width: CGFloat, strength: Double, tilt: Double, reach: Double) {
        self.cornerSize = cornerSize
        self.width = width
        self.tilt = tilt
        self.reach = reach
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.colors = [NSColor.white.withAlphaComponent(strength).cgColor,
                           NSColor.white.withAlphaComponent(strength * 0.4).cgColor,
                           NSColor.white.withAlphaComponent(0).cgColor]
        CATransaction.commit()
        rebuildIfNeeded()
        writePoints()
        updateRunning()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildIfNeeded()
    }

    override func layout() {
        super.layout()
        rebuildIfNeeded()
    }

    /// The stroke follows the panel's squircle, as idea 3's `strokeBorder`
    /// does (inset by half the width). Rebuilt only when the size, corner
    /// or width changes, never per pointer move.
    private func rebuildIfNeeded() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if gradient.superlayer == nil { layer?.addSublayer(gradient) }
        if let built = builtFor, built.size == size, built.corner == cornerSize, built.width == width { return }
        builtFor = (size, cornerSize, width)
        #if DEBUG
        GlossLabCounters.movingPathBuilds += 1
        #endif
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        stroke.frame = gradient.bounds
        let shape = Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent)
        stroke.path = shape.inset(by: width / 2).path(in: CGRect(origin: .zero, size: size)).cgPath
        stroke.lineWidth = width
        CATransaction.commit()
        // The unit points do not change with the size; this writes only
        // on the first build (or if the layer's flip changed).
        writePoints()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        guard let window else { return stop() }
        writePoints()
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunning() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunning() }
        })
        updateRunning()
    }

    /// The link runs only while the view is in a visible window and motion
    /// is allowed. Under Reduce Motion the light goes back to rest.
    func updateRunning() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        if AtticMotionPreference.reducesMotion {
            stopLink()
            if current != .zero { current = .zero; writePoints() }
            return
        }
        guard visible else { return stopLink() }
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = nil
    }

    var isRunning: Bool { link != nil }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    func stop() {
        stopLink()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    @objc private func frame(_ link: CADisplayLink) {
        let dt = lastTimestamp.map { link.targetTimestamp - $0 } ?? link.duration
        lastTimestamp = link.targetTimestamp
        step(dt: dt)
    }

    /// One display refresh; tests drive it directly. Reads the pointer,
    /// eases towards it (time constant 80 ms) and writes the gradient's
    /// points only when they changed.
    func step(dt: CFTimeInterval) {
        #if DEBUG
        GlossLabCounters.movingTicks += 1
        #endif
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        if AtticMotionPreference.reducesMotion { return updateRunning() }
        var screen = NSEvent.mouseLocation
        #if DEBUG
        if let point = Self.pointerForTesting { screen = point }
        #endif
        let local = convert(window.convertPoint(fromScreen: screen), from: nil)
        func unit(_ value: CGFloat, _ mid: CGFloat, _ half: CGFloat) -> CGFloat { min(1, max(-1, (value - mid) / half)) }
        let target = CGPoint(x: unit(local.x, bounds.midX, bounds.width / 2), y: unit(local.y, bounds.midY, bounds.height / 2))
        let k = CGFloat(1 - exp(-max(0, dt) / 0.08))
        var next = CGPoint(x: current.x + (target.x - current.x) * k, y: current.y + (target.y - current.y) * k)
        if abs(next.x - target.x) < 0.002 { next.x = target.x }
        if abs(next.y - target.y) < 0.002 { next.y = target.y }
        guard next != current else { return }
        current = next
        writePoints()
    }

    /// The axis starts at the top and ends at the bottom (idea 3), turned
    /// by up to `tilt` degrees so the lit end leans towards the pointer's
    /// side, and slid by up to `reach` of the height with the pointer.
    static func points(pointer: CGPoint, tilt: Double, reach: Double) -> (start: CGPoint, end: CGPoint) {
        let angle = -Double(pointer.x) * tilt * .pi / 180
        let sx = CGFloat(sin(angle)) / 2, sy = CGFloat(cos(angle)) / 2
        let slide = pointer.y * CGFloat(reach)
        return (CGPoint(x: 0.5 - sx, y: 0.5 - sy + slide), CGPoint(x: 0.5 + sx, y: 0.5 + sy + slide))
    }

    private func writePoints() {
        var (start, end) = Self.points(pointer: current, tilt: tilt, reach: reach)
        // Unit space has y = 0 at the top only when the layer's contents
        // are flipped (AppKit flips a flipped view's layer).
        if !gradient.contentsAreFlipped() { start.y = 1 - start.y; end.y = 1 - end.y }
        if let last = lastWritten, last.start == start, last.end == end { return }
        lastWritten = (start, end)
        #if DEBUG
        GlossLabCounters.movingWrites += 1
        #endif
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.startPoint = start
        gradient.endPoint = end
        CATransaction.commit()
    }
}

/// 10. One rim recipe for every control: the button's Edge light with its
/// lit runs measured from each corner over a square of the control's
/// height, so a wide control (Now · Later · Done) is lit exactly as far as
/// a square one (pin, •••, Search). The trunk's single gradient runs along
/// the bounding box's diagonal, so on a wide control the lit run stretches
/// with the width and its brightest point lies nearer the end cap.
struct GlossLabControlEdgeLight<S: InsettableShape>: View {
    let shape: S
    let light: AtticEdgeLight

    var body: some View {
        GeometryReader { proxy in
            #if DEBUG
            let _ = GlossLabCounters.controlEdgeLight += 1
            #endif
            let size = proxy.size
            let side = max(1, min(size.width, size.height))
            let ux = side / max(size.width, 1), uy = side / max(size.height, 1)
            ZStack {
                shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(light.topLeading), location: 0),
                                                          .init(color: .white.opacity(0), location: light.fade)],
                                                  startPoint: .topLeading, endPoint: UnitPoint(x: ux, y: uy)),
                                   lineWidth: light.lineWidth)
                shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0), location: 1 - light.fade),
                                                          .init(color: .white.opacity(light.bottomTrailing), location: 1)],
                                                  startPoint: UnitPoint(x: 1 - ux, y: 1 - uy), endPoint: .bottomTrailing),
                                   lineWidth: light.lineWidth)
                shape.stroke(light.hairline.color, lineWidth: light.hairlineWidth)
            }
        }
    }
}

/// 2. The ring between the panel's squircle and the same squircle inset by
/// `width`. The inner curve is the outer one inset and walked the other way
/// (mirrored about the centre), so the inside is a hole under either fill
/// rule.
struct GlossRing: Shape {
    var outer: Squircle
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = outer.path(in: rect)
        let inner = outer.inset(by: width).path(in: rect)
        let mirror = CGAffineTransform(translationX: rect.midX, y: 0).scaledBy(x: -1, y: 1).translatedBy(x: -rect.midX, y: 0)
        path.addPath(inner, transform: mirror)
        return path
    }
}

/// 2. A band of Apple's Clear glass around the edge, regular glass inside
/// it, in place of the panel's one regular glass. Two honest ways to lay
/// it, both Apple's own glass with nothing drawn to imitate it:
/// - ring: Clear on the ring only, Regular on the inset squircle; the two
///   glasses sit side by side and neither is over the other;
/// - stacked: Clear under the whole panel, Regular over its inner part
///   (glass over glass, which Apple says does not sample the glass under it).
/// Either may share one `GlassEffectContainer` (spacing 0) or not.
struct GlossClearBandGlass: View {
    let cornerSize: CGFloat
    let width: CGFloat
    let method: GlossLab.ClearBandMethod
    let sharesContainer: Bool

    var body: some View {
        let shape = Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent)
        if sharesContainer {
            GlassEffectContainer(spacing: 0) { glasses(shape) }
        } else {
            glasses(shape)
        }
    }

    private func glasses(_ shape: Squircle) -> some View {
        let inner = shape.inset(by: width)
        return ZStack {
            switch method {
            case .ring:
                let ring = GlossRing(outer: shape, width: width)
                ring.fill(Color.clear).glassEffect(.clear, in: ring)
            case .stacked:
                shape.fill(Color.clear).glassEffect(.clear, in: shape)
            }
            inner.fill(Color.clear).glassEffect(.regular, in: inner)
        }
    }
}

/// 7. The panel's exterior shadow. With 7 and its spill off it is the
/// trunk's `AtticPanelOutsideShadow`, untouched. With 7 on: a tight
/// contact shadow and a wide soft one, both cast only outside the
/// squircle, the soft one held inside the window's transparent margin
/// (the trunk's own extent rule, radius x 2 + drop). With the spill on: a
/// faint white glow under the bottom edge, cast by a band just inside it.
/// The panel's window, its margin and its geometry are the trunk's.
struct GlossLabPanelShadow: View {
    let shape: Squircle
    let cornerSize: CGFloat
    let elevation: AtticPanelSurfaceElevation
    /// The window's transparent margin around the surface, pt.
    let margin: CGFloat
    @Environment(\.atticDesign) private var design

    /// The spill's glow: radius and drop, pt (extent 2 x 8 + 4 = 20).
    static let spillRadius: CGFloat = 8
    static let spillDrop: CGFloat = 4
    static let spillCasterHeight: CGFloat = 10

    /// The soft shadow's radius, held so radius x 2 + drop fits the margin.
    static func softRadius(_ wanted: CGFloat, drop: CGFloat, margin: CGFloat) -> CGFloat {
        max(0, min(wanted, (margin - abs(drop)) / 2))
    }

    var body: some View {
        #if DEBUG
        let _ = GlossLabCounters.shadowLayer += 1
        #endif
        let lab = GlossLab.shared
        if !lab.glassShadow && !lab.glassSpill {
            AtticPanelOutsideShadow(shape: shape, elevation: elevation)
        } else {
            let dark = design.mode == .dark
            let inset = AtticPanelOutsideShadow.casterInset
            ZStack {
                if lab.glassShadow {
                    let drop = CGFloat(lab.shadowSoftDrop)
                    shape.fill(Color.black).padding(inset)
                        .shadow(color: .black.opacity(dark ? lab.shadowSoftDark : lab.shadowSoftLight),
                                radius: Self.softRadius(CGFloat(lab.shadowSoftRadius), drop: drop, margin: margin),
                                x: 0, y: drop)
                    shape.fill(Color.black).padding(inset)
                        .shadow(color: .black.opacity(dark ? lab.shadowContactDark : lab.shadowContactLight),
                                radius: 1, x: 0, y: 1)
                } else {
                    AtticPanelOutsideShadow(shape: shape, elevation: elevation)
                }
                if lab.glassSpill {
                    Rectangle().fill(Color.white)
                        .frame(height: Self.spillCasterHeight)
                        .padding(.horizontal, cornerSize)
                        .padding(.bottom, inset)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .shadow(color: .white.opacity(lab.spillStrength),
                                radius: Self.softRadius(Self.spillRadius, drop: Self.spillDrop, margin: margin),
                                x: 0, y: Self.spillDrop)
                }
                shape.fill(Color.black).blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}
#endif
