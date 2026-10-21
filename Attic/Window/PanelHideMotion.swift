import AppKit
import Metal
import QuartzCore
import SwiftUI

// The panel's hide animations (Settings › General › Behaviour › Hide
// animation). Slide is `AtticPanelContentContainer.setCollapseProgress`;
// the other two live here:
//
// - Genie: a snapshot of the panel's content drawn through a Metal vertex
//   grid bent along a Genie curve into the panel's own corner (a reveal runs
//   it backwards), with the panel's material kept live under it.
// - Swoop: the live panel (real glass) on a curved path into the corner,
//   narrowing and stretching toward it, with layer transforms only.

/// Settings › General › Behaviour › Hide animation.
enum PanelHideAnimation: String, CaseIterable, Identifiable, Sendable {
    // Declared in Settings' order: Slide, Swoop, Genie (owner, 2026-10-21:
    // three ship; Genie Classic was dropped). The raw values stay as first
    // stored, so a choice carries over.
    case slide
    case swoop
    /// "Genie": the bend with the panel's real glass kept live under it.
    case genieLiveGlass

    static let defaultValue: PanelHideAnimation = .slide

    var id: String { rawValue }

    /// Reads a stored choice. Genie Classic (`genie`, dropped 2026-10-21)
    /// reads as Genie, its nearest look, never as the default.
    init?(storedValue: String) {
        if storedValue == "genie" { self = .genieLiveGlass; return }
        self.init(rawValue: storedValue)
    }

    /// Genie draws the content through the Metal mesh.
    var usesGenieMesh: Bool { self == .genieLiveGlass }

    /// This animation's own hide and reveal durations: where each one's
    /// shipped default lives. All three start at Slide's (0.22 s and 0.24 s);
    /// the preview-only speed lab (`PanelHideSpeedLab`) tunes them on screen.
    var defaultHideDuration: TimeInterval {
        switch self {
        case .slide, .swoop, .genieLiveGlass: 0.22
        }
    }

    var defaultRevealDuration: TimeInterval {
        switch self {
        case .slide, .swoop, .genieLiveGlass: 0.24
        }
    }

    var title: String {
        switch self {
        case .slide: String(localized: "Slide")
        case .swoop: String(localized: "Swoop")
        case .genieLiveGlass: String(localized: "Genie")
        }
    }

    /// One short line on how it looks (Settings' help, one line each).
    var summary: String {
        switch self {
        case .slide: String(localized: "Slide: the panel shrinks into its corner.")
        case .swoop: String(localized: "Swoop: the panel curves into its corner, narrowing as it goes.")
        case .genieLiveGlass: String(localized: "Genie: the panel pours into its corner through a funnel, like the Dock's minimise.")
        }
    }

    /// The Hide animation row's help: each animation's line, in order.
    static var settingsHelp: String { allCases.map(\.summary).joined(separator: "\n") }
}

/// Preview-only speed lab (owner, 2026-10-19): each animation's hide and
/// reveal duration, tuned on screen. Only overrides are stored; the chosen
/// values later become each animation's `defaultHideDuration` and
/// `defaultRevealDuration`, and the lab is removed. Never read under the
/// release identity (`AppSettings` ignores it unless `AtticMotionLab`).
struct PanelHideSpeedLab: Codable, Equatable, Sendable {
    /// Milliseconds the sliders cover.
    static let range: ClosedRange<Double> = 100...800
    static let step: Double = 10

    /// "<animation>.hide" / "<animation>.reveal" → seconds.
    private var overrides: [String: Double] = [:]

    init() {}

    private static func key(_ mode: PanelHideAnimation, hiding: Bool) -> String {
        "\(mode.rawValue).\(hiding ? "hide" : "reveal")"
    }

    func duration(_ mode: PanelHideAnimation, hiding: Bool) -> TimeInterval {
        overrides[Self.key(mode, hiding: hiding)] ?? (hiding ? mode.defaultHideDuration : mode.defaultRevealDuration)
    }

    mutating func setDuration(_ seconds: TimeInterval, _ mode: PanelHideAnimation, hiding: Bool) {
        let fallback = hiding ? mode.defaultHideDuration : mode.defaultRevealDuration
        let milliseconds = seconds.isFinite ? seconds * 1000 : fallback * 1000
        let clamped = min(Self.range.upperBound, max(Self.range.lowerBound, milliseconds)) / 1000
        overrides[Self.key(mode, hiding: hiding)] = abs(clamped - fallback) < 0.0005 ? nil : clamped
    }

    var isDefault: Bool { overrides.isEmpty }
}

/// Every tunable number of the hide animations in one place.
enum PanelHideMotionTuning {
    /// Time → progress. Hide eases in and out (the funnel forms, then the
    /// panel is drawn into the corner); a reveal decelerates like Slide.
    static let hideTiming = UnitBezier(0.42, 0.0, 0.58, 1.0)
    static let showTiming = UnitBezier(0.22, 0.8, 0.28, 1.0)

    // Genie
    /// The funnel forms over this first share of the progress…
    static let genieCurveEnd: Double = 0.45
    /// …while the content slides into the corner over this span.
    static let genieSlideStart: Double = 0.12
    /// The funnel's mouth at the corner, as a share of the panel's height.
    static let genieMouth: Double = 0.14
    /// How much the mouth closes by the end.
    static let genieMouthClose: Double = 0.7
    /// The last sliver fades rather than leaving a line at the corner.
    static let genieFadeStart: Double = 0.86
    /// Grid density (along the flow, across it).
    static let genieColumns = 56
    static let genieRows = 14
    /// Frames a new Genie flight waits for its first drawable to reach the
    /// screen before it takes over from the live panel regardless.
    static let genieHandoverMaxFrames = 8
    /// How long a snapshot taken ahead of a hide, reveal or swipe stays good.
    static let geniePreparedLifetime: CFTimeInterval = 1.5
    /// A timed hide or reveal prepares its snapshot this long ahead.
    static let geniePrepareLead: TimeInterval = 0.12

    // Swoop
    /// The size the panel ends at (Slide's collapsed scale is 0.015).
    static let swoopEndScale: Double = 0.03
    /// Along the line to the corner the panel shrinks late (it stretches
    /// toward the corner); across it, it narrows early.
    static let swoopAlongPower: Double = 1.7
    static let swoopAcrossEnd: Double = 0.75
    /// The path bows inward by this share of the panel's height, so the
    /// panel swoops in on a curve rather than a straight line.
    static let swoopBow: Double = 0.12
    /// The tilt that makes the panel narrow toward the corner (degrees).
    static let swoopTiltDegrees: Double = 24
    static let swoopPerspective: Double = 900
    static let swoopFadeStart: Double = 0.85
    static let swoopKeyframes = 30

    // Swipe follows fingers
    /// A swipe released to close finishes into the corner on this spring
    /// (critically damped, from the fingers' progress and speed).
    static let swipeCloseSpring = AtticMotionSpring(response: 0.24, bounce: 0)
    /// The release speed is capped (progress per second).
    static let swipeMaxVelocity: Double = 12
}

/// CSS-style cubic Bézier timing, solved on the CPU so a motion's
/// progress can be read at any moment (an interruption continues from it).
struct UnitBezier: Sendable {
    private let cx, bx, ax, cy, by, ay: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1; bx = 3 * (x2 - x1) - cx; ax = 1 - cx - bx
        cy = 3 * y1; by = 3 * (y2 - y1) - cy; ay = 1 - cy - by
    }

    func value(at x: Double) -> Double {
        let x = min(1, max(0, x))
        var t = x
        for _ in 0..<8 {
            let error = ((ax * t + bx) * t + cx) * t - x
            if abs(error) < 1e-6 { break }
            let slope = (3 * ax * t + 2 * bx) * t + cx
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        t = min(1, max(0, t))
        return ((ay * t + by) * t + cy) * t
    }
}

private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

/// A run from one progress to another (0 = shown, 1 = hidden): timed on a
/// Bézier curve, or on a spring that starts with the fingers' speed.
struct PanelHideMotionRun {
    let from: Double
    let to: Double
    let start: CFTimeInterval
    let duration: CFTimeInterval
    private let curve: Curve

    private enum Curve {
        case timed(UnitBezier)
        case spring(omega: Double, zeta: Double, velocity: Double)
    }

    init(from: Double, to: Double, start: CFTimeInterval, duration: CFTimeInterval, timing: UnitBezier) {
        self.from = from
        self.to = to
        self.start = start
        self.duration = duration
        curve = .timed(timing)
    }

    /// A spring (SwiftUI's response and bounce) from `from` with
    /// `velocity` (progress per second); it lasts until it settles.
    init(from: Double, to: Double, start: CFTimeInterval, spring: AtticMotionSpring, velocity: Double) {
        self.from = from
        self.to = to
        self.start = start
        let omega = 2 * .pi / max(0.05, spring.response)
        let zeta = spring.bounce >= 0 ? max(0.05, 1 - spring.bounce) : 1 / (1 + max(-0.95, spring.bounce))
        curve = .spring(omega: omega, zeta: zeta, velocity: velocity)
        // Settled: within 0.1% of the travel for 1/12 s in a row.
        let tolerance = 0.001
        var settled = 0.0, quiet = 0.0, t = 0.0
        while t < 2 {
            t += 1.0 / 240
            let x = Self.displacement(x0: from - to, v0: velocity, omega: omega, zeta: zeta, t: t)
            if abs(x) < tolerance { quiet += 1.0 / 240; if quiet >= 1.0 / 12 { settled = t - quiet; break } } else { quiet = 0 }
            settled = t
        }
        duration = max(1.0 / 60, settled)
    }

    private static func displacement(x0: Double, v0: Double, omega: Double, zeta: Double, t: Double) -> Double {
        if abs(zeta - 1) < 1e-3 {
            return exp(-omega * t) * (x0 + (v0 + omega * x0) * t)
        }
        if zeta < 1 {
            let damped = omega * (1 - zeta * zeta).squareRoot()
            return exp(-zeta * omega * t) * (x0 * cos(damped * t) + (v0 + zeta * omega * x0) / damped * sin(damped * t))
        }
        let root = (zeta * zeta - 1).squareRoot()
        let r1 = -omega * (zeta - root), r2 = -omega * (zeta + root)
        let c2 = (v0 - r1 * x0) / (r2 - r1)
        return (x0 - c2) * exp(r1 * t) + c2 * exp(r2 * t)
    }

    func progress(at time: CFTimeInterval) -> Double {
        guard duration > 0 else { return to }
        switch curve {
        case .timed(let timing):
            return from + (to - from) * timing.value(at: (time - start) / duration)
        case let .spring(omega, zeta, velocity):
            let t = time - start
            guard t > 0 else { return from }
            guard t < duration else { return to }
            return to + Self.displacement(x0: from - to, v0: velocity, omega: omega, zeta: zeta, t: t)
        }
    }

    func isFinished(at time: CFTimeInterval) -> Bool { time - start >= duration }

    /// The progress `count + 1` evenly spaced samples (Swoop's keyframes).
    func samples(_ count: Int) -> [Double] {
        (0...count).map { progress(at: start + duration * Double($0) / Double(count)) }
    }
}

/// How a draft motion runs: timed like Slide, or a spring after a swipe.
enum PanelHideMotionCurve {
    case timed(duration: TimeInterval, timing: UnitBezier)
    case spring(AtticMotionSpring, velocity: Double)

    func run(from: Double, to: Double, start: CFTimeInterval) -> PanelHideMotionRun {
        switch self {
        case let .timed(duration, timing):
            PanelHideMotionRun(from: from, to: to, start: start, duration: duration, timing: timing)
        case let .spring(spring, velocity):
            PanelHideMotionRun(from: from, to: to, start: start, spring: spring, velocity: velocity)
        }
    }
}

enum PanelSwoopGeometry {
    /// The live panel's layer transform at `progress`. `visibleBounds` is
    /// the visible surface and `hostBounds` the whole layer (surface plus
    /// its shadow margin, the window's own bounds), both in the layer's
    /// bounds coordinates.
    static func transform(
        progress: Double, visibleBounds: CGRect, hostBounds: CGRect, layerAnchor: CGPoint, corner: ScreenCorner
    ) -> CATransform3D {
        let world = fitted(worldTransform(progress: progress, visibleBounds: visibleBounds, corner: corner),
                           in: hostBounds, corner: corner, visibleBounds: visibleBounds)
        // A layer transforms about its anchor point.
        var layer = CATransform3DMakeTranslation(layerAnchor.x, layerAnchor.y, 0)
        layer = CATransform3DConcat(layer, world)
        return CATransform3DConcat(layer, CATransform3DMakeTranslation(-layerAnchor.x, -layerAnchor.y, 0))
    }

    /// The motion as designed, from layer-bounds points to where they are
    /// drawn. Unfitted, its tilt brings the panel's far end toward the
    /// viewer and swells it, and its bow carries it sideways, a quarter of
    /// the way in, past the window's 28 pt margin; the window cut it off on
    /// a straight line (owner, 2026-10-19). `fitted` keeps it inside.
    static func worldTransform(progress: Double, visibleBounds: CGRect, corner: ScreenCorner) -> CATransform3D {
        let p = min(1, max(0, progress))
        guard p > 0 else { return CATransform3DIdentity }
        typealias T = PanelHideMotionTuning
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topRight || corner == .topLeft
        let cornerPoint = CGPoint(x: right ? visibleBounds.maxX : visibleBounds.minX,
                                  y: top ? visibleBounds.maxY : visibleBounds.minY)
        // The line from the panel's centre to its corner, and the bow's
        // direction: as far off that line as its normal, but inward on both
        // axes, away from the side edge and from the menu bar or Dock edge.
        // (Draft 2's normal lifted the panel toward the top or bottom edge,
        // past its window and under the menu bar, at the top corners.)
        let angle = atan2(cornerPoint.y - visibleBounds.midY, cornerPoint.x - visibleBounds.midX)
        let normal = CGPoint(x: (right ? -1 : 1) * abs(sin(angle)), y: (top ? -1 : 1) * abs(cos(angle)))
        let end = T.swoopEndScale
        let along = 1 - (1 - end) * pow(p, T.swoopAlongPower)
        let across = 1 - (1 - end) * smoothstep(0, T.swoopAcrossEnd, p)
        let bow = T.swoopBow * visibleBounds.height * sin(.pi * p)
        let tilt = T.swoopTiltDegrees * .pi / 180 * sin(.pi * p)

        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / CGFloat(T.swoopPerspective)
        var world = CATransform3DMakeTranslation(-cornerPoint.x, -cornerPoint.y, 0)
        world = CATransform3DConcat(world, CATransform3DMakeRotation(-angle, 0, 0, 1))
        world = CATransform3DConcat(world, CATransform3DMakeScale(along, across, 1))
        world = CATransform3DConcat(world, CATransform3DMakeRotation(tilt, 0, 1, 0))
        world = CATransform3DConcat(world, perspective)
        world = CATransform3DConcat(world, CATransform3DMakeRotation(angle, 0, 0, 1))
        return CATransform3DConcat(world, CATransform3DMakeTranslation(
            cornerPoint.x + normal.x * bow, cornerPoint.y + normal.y * bow, 0))
    }

    /// Keeps the whole layer (surface and shadow) inside the window: where
    /// the drawn layer would leave it, the motion is scaled down about the
    /// panel's own corner (the point it hides into) just enough to stay in.
    /// Where it already fits (from about halfway at the usual sizes) it is
    /// the motion as designed. The scale is continuous in progress, so a
    /// swipe and the keyframes see one shape, and it always pulls toward the
    /// corner the motion is heading for.
    static func fitted(_ world: CATransform3D, in hostBounds: CGRect, corner: ScreenCorner,
                       visibleBounds: CGRect) -> CATransform3D {
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topRight || corner == .topLeft
        let pivot = CGPoint(x: right ? visibleBounds.maxX : visibleBounds.minX,
                            y: top ? visibleBounds.maxY : visibleBounds.minY)
        guard hostBounds.insetBy(dx: 1, dy: 1).contains(pivot) else { return world }
        // A rectangle under a perspective with every w > 0 draws a convex
        // quad, so its bounding box is its corners'.
        let drawn = [
            CGPoint(x: hostBounds.minX, y: hostBounds.minY), CGPoint(x: hostBounds.maxX, y: hostBounds.minY),
            CGPoint(x: hostBounds.minX, y: hostBounds.maxY), CGPoint(x: hostBounds.maxX, y: hostBounds.maxY)
        ].map { project($0, world) }
        guard drawn.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return world }
        var scale: CGFloat = 1
        for point in drawn {
            if point.x < hostBounds.minX { scale = min(scale, (pivot.x - hostBounds.minX) / (pivot.x - point.x)) }
            if point.x > hostBounds.maxX { scale = min(scale, (hostBounds.maxX - pivot.x) / (point.x - pivot.x)) }
            if point.y < hostBounds.minY { scale = min(scale, (pivot.y - hostBounds.minY) / (pivot.y - point.y)) }
            if point.y > hostBounds.maxY { scale = min(scale, (hostBounds.maxY - pivot.y) / (point.y - pivot.y)) }
        }
        guard scale < 1 else { return world }
        // Affine after the projection: it commutes with the divide by w.
        var correction = CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0)
        correction = CATransform3DConcat(correction, CATransform3DMakeScale(scale, scale, 1))
        correction = CATransform3DConcat(correction, CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
        return CATransform3DConcat(world, correction)
    }

    /// Where `transform` draws `point` (z = 0), after the perspective divide.
    static func project(_ point: CGPoint, _ transform: CATransform3D) -> CGPoint {
        let x = point.x * transform.m11 + point.y * transform.m21 + transform.m41
        let y = point.x * transform.m12 + point.y * transform.m22 + transform.m42
        let w = point.x * transform.m14 + point.y * transform.m24 + transform.m44
        return CGPoint(x: x / w, y: y / w)
    }

    static func opacity(progress: Double) -> Float {
        Float(1 - smoothstep(PanelHideMotionTuning.swoopFadeStart, 1, progress))
    }
}

// MARK: - Genie (Metal)

/// The shared Metal pipeline. The shader compiles from source (the project
/// generator only collects Swift), off the main thread, at launch when
/// Genie is chosen or when it is picked in Settings.
final class PanelGenieRenderer: @unchecked Sendable {
    static let shared = PanelGenieRenderer()

    let device: MTLDevice?
    private let lock = NSLock()
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var isPreparing = false

    private init() { device = MTLCreateSystemDefaultDevice() }

    func prewarm() {
        lock.lock()
        let start = pipeline == nil && !isPreparing
        if start { isPreparing = true }
        lock.unlock()
        guard start else { return }
        DispatchQueue.global(qos: .userInitiated).async { _ = self.state() }
    }

    func state() -> (MTLRenderPipelineState, MTLCommandQueue)? {
        lock.lock(); defer { lock.unlock() }
        if let pipeline, let queue { return (pipeline, queue) }
        guard let device, let library = try? device.makeLibrary(source: Self.source, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "genieVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "genieFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let made = try? device.makeRenderPipelineState(descriptor: descriptor),
              let commandQueue = device.makeCommandQueue() else { return nil }
        pipeline = made
        queue = commandQueue
        isPreparing = false
        return (made, commandQueue)
    }

    /// The grid is laid out once: `columns` along x, `rows` along y, both
    /// in 0…1 with y up.
    private(set) lazy var grid: (vertices: MTLBuffer, indices: MTLBuffer, count: Int)? = {
        guard let device else { return nil }
        let columns = PanelHideMotionTuning.genieColumns, rows = PanelHideMotionTuning.genieRows
        var vertices: [SIMD2<Float>] = []
        for row in 0...rows {
            for column in 0...columns {
                vertices.append(SIMD2(Float(column) / Float(columns), Float(row) / Float(rows)))
            }
        }
        var indices: [UInt16] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let a = UInt16(row * (columns + 1) + column), b = a + 1
                let c = a + UInt16(columns + 1), d = c + 1
                indices += [a, b, c, b, d, c]
            }
        }
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD2<Float>>.stride),
              let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt16>.stride) else { return nil }
        return (vertexBuffer, indexBuffer, indices.count)
    }()

    struct Uniforms {
        var curve: Float
        var slide: Float
        var mouth: Float
        var alpha: Float
        var right: Float
        var top: Float
        var padding: SIMD2<Float> = .zero
    }

    static func uniforms(progress: Double, corner: ScreenCorner) -> Uniforms {
        typealias T = PanelHideMotionTuning
        let p = min(1, max(0, progress))
        return Uniforms(
            curve: Float(smoothstep(0, T.genieCurveEnd, p)),
            slide: Float(smoothstep(T.genieSlideStart, 1, p)),
            mouth: Float(T.genieMouth * (1 - T.genieMouthClose * smoothstep(0.55, 1, p))),
            alpha: Float(1 - smoothstep(T.genieFadeStart, 1, p)),
            right: corner == .topRight || corner == .bottomRight ? 1 : 0,
            top: corner == .topRight || corner == .topLeft ? 1 : 0
        )
    }

    /// The vertex shader's position for grid point `g` (both 0…1, y up),
    /// on the CPU: the live glass's mask follows the same outline.
    static func position(_ gx: Float, _ gy: Float, _ u: Uniforms) -> SIMD2<Float> {
        let s = u.right > 0.5 ? gx : 1 - gx
        let v = u.top > 0.5 ? gy : 1 - gy
        let w = min(s + u.slide, 1)
        let t = min(1, max(0, w))
        let f = u.curve * t * t * (3 - 2 * t)
        let b = f * (1 - u.mouth) * (1 - v) + v
        return SIMD2(u.right > 0.5 ? w : 1 - w, u.top > 0.5 ? b : 1 - b)
    }

    /// Where the drawn mesh puts grid point `p`: the shader's positions at
    /// the cell's corners, interpolated across the same triangle the index
    /// buffer draws (`a b c`, `b d c`), so an outline sits exactly on the
    /// drawn content's edge.
    static func meshPosition(_ p: SIMD2<Float>, _ u: Uniforms) -> SIMD2<Float> {
        let columns = Float(PanelHideMotionTuning.genieColumns), rows = Float(PanelHideMotionTuning.genieRows)
        let x = min(max(p.x, 0), 1) * columns, y = min(max(p.y, 0), 1) * rows
        let i = min(floor(x), columns - 1), j = min(floor(y), rows - 1)
        let fx = x - i, fy = y - j
        let x0 = i / columns, x1 = (i + 1) / columns, y0 = j / rows, y1 = (j + 1) / rows
        if fx + fy <= 1 {
            let a = position(x0, y0, u), b = position(x1, y0, u), c = position(x0, y1, u)
            return a + fx * (b - a) + fy * (c - a)
        }
        let b = position(x1, y0, u), c = position(x0, y1, u), d = position(x1, y1, u)
        return d + (1 - fx) * (c - d) + (1 - fy) * (b - d)
    }

    // The flow runs along x toward the screen edge the panel hides into;
    // the edge on the corner's side stays straight and the other edge
    // bends along a smoothstep funnel to the mouth at the corner. Content
    // past the mouth collapses into it.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct GenieUniforms { float curve; float slide; float mouth; float alpha; float right; float top; float2 padding; };
    struct GenieOut { float4 position [[position]]; float2 uv; };
    vertex GenieOut genieVertex(uint vid [[vertex_id]], constant float2 *grid [[buffer(0)]], constant GenieUniforms &u [[buffer(1)]]) {
        float2 g = grid[vid];
        float s = u.right > 0.5 ? g.x : 1.0 - g.x;
        float v = u.top > 0.5 ? g.y : 1.0 - g.y;
        float w = min(s + u.slide, 1.0);
        float f = u.curve * smoothstep(0.0, 1.0, w);
        float b = mix(f * (1.0 - u.mouth), 1.0, v);
        float nx = u.right > 0.5 ? w : 1.0 - w;
        float ny = u.top > 0.5 ? b : 1.0 - b;
        GenieOut out;
        out.position = float4(nx * 2.0 - 1.0, ny * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(g.x, 1.0 - g.y);
        return out;
    }
    fragment float4 genieFragment(GenieOut in [[stage_in]], texture2d<float> image [[texture(0)]], constant GenieUniforms &u [[buffer(1)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        return image.sample(linearSampler, in.uv) * u.alpha;
    }
    """
}

/// Whether a Genie flight may take over from the live panel. A Metal layer
/// that has just been shown (or whose window has just ordered in) can miss
/// its first drawables: taking over before one reaches the screen showed an
/// empty window for a frame (draft 5, 1 in 21 hides). So a flight waits for
/// a drawable to be presented, drawing clear frames meanwhile, and the live
/// panel stays in place until then (or until `maxFrames` have passed).
struct PanelGenieHandover: Equatable {
    var maxFrames = PanelHideMotionTuning.genieHandoverMaxFrames
    /// A drawable drawn since the layer was last shown, with its window
    /// visible, has reached the screen.
    private(set) var isEstablished = false
    private(set) var isWaiting = false
    private var framesWaited = 0
    /// Bumped on every reset: a late "presented" from before it is ignored.
    private(set) var generation = 0

    /// The layer was hidden, or its window is not on screen.
    mutating func reset() {
        isEstablished = false
        generation += 1
    }

    /// A flight starts. True when it can take over now; otherwise it waits.
    mutating func begin() -> Bool {
        guard !isEstablished else { isWaiting = false; return true }
        isWaiting = true
        framesWaited = 0
        return false
    }

    /// A clear frame was drawn while waiting. True when the wait gives up.
    mutating func waitedOneFrame() -> Bool {
        guard isWaiting else { return false }
        framesWaited += 1
        guard framesWaited >= maxFrames else { return false }
        isWaiting = false
        return true
    }

    /// A drawable of `generation` reached the screen. True when that ends a
    /// wait (the flight takes over now).
    mutating func presented(generation drawn: Int) -> Bool {
        guard drawn == generation else { return false }
        isEstablished = true
        guard isWaiting else { return false }
        isWaiting = false
        return true
    }

    mutating func cancel() { isWaiting = false }
}

/// Debug-build diagnostics for the on-screen motion bench (never compiled
/// into Release): what the last snapshot and flight cost, and which glass
/// it stood in for or left out.
enum PanelHideMotionTrace {
    #if DEBUG
    static var snapshotMilliseconds: [String: Double] = [:]
    static var materialLayers: [String] = []
    static var glassStandIns: [String] = []
    static var glassLeftOut: [String] = []
    static var maskMicroseconds: Double = 0
    static var layerDump: [String] = []
    #endif

    @inline(__always) static func note(_ key: String, _ value: @autoclosure () -> Double) {
        #if DEBUG
        snapshotMilliseconds[key] = value()
        #endif
    }
}

/// Draws the panel's snapshot through the Genie grid. It sits over the live
/// presentation inside the panel's own window (no extra windows) and never
/// takes a click: the live panel under it keeps its input.
final class PanelGenieView: NSView {
    private let metalLayer = CAMetalLayer()
    private var texture: MTLTexture?
    private var displayLink: CADisplayLink?
    private var run: PanelHideMotionRun?
    /// A run asked for while the flight still waits to take over.
    private var pendingRun: (curve: PanelHideMotionCurve, target: Double)?
    private var corner: ScreenCorner = .topRight
    /// Called with every drawn frame's uniforms, in the frame's own
    /// transaction (the live material's mask moves with it).
    var frameObserver: ((PanelGenieRenderer.Uniforms) -> Void)?
    private var handover = PanelGenieHandover()
    /// Runs once, in the transaction of the first frame that draws content.
    private var onHandover: (() -> Void)?
    private var completion: (() -> Void)?
    private(set) var progress: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = PanelGenieRenderer.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = true
        metalLayer.maximumDrawableCount = 3
        layer = metalLayer
        metalLayer.isOpaque = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isHidden: Bool {
        didSet { if isHidden, !oldValue { handover.reset() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        handover.reset()
    }

    var hasSnapshot: Bool { texture != nil }
    /// The snapshot's size in pixels (tests: it is taken at the window's
    /// backing scale).
    var snapshotPixelSize: CGSize? { texture.map { CGSize(width: $0.width, height: $0.height) } }
    var isAnimating: Bool { run != nil || pendingRun != nil }
    /// Waiting for a first drawable to reach the screen before taking over.
    var isWaitingToTakeOver: Bool { handover.isWaiting }
    /// Where the motion is now, read between display frames.
    var currentProgress: Double { run?.progress(at: CACurrentMediaTime()) ?? progress }

    /// Takes the snapshot the grid draws, at the window's backing scale (so
    /// text stays crisp in flight). The panel's material stays live under
    /// the mesh, so the snapshot leaves it out.
    func captureSnapshot(
        of view: NSView, surfaceRect: CGRect, cornerRadius: CGFloat, translucent: Bool, dark: Bool,
        hidesSurfaceMaterial: Bool = false
    ) {
        let began = CACurrentMediaTime()
        defer { PanelHideMotionTrace.note("total", (CACurrentMediaTime() - began) * 1000) }
        texture = nil
        guard let device = PanelGenieRenderer.shared.device, let root = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = Int((view.bounds.width * scale).rounded()), height = Int((view.bounds.height * scale).rounded())
        let space = view.window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // Glass's layers (backdrop and SDF rim) cannot render outside the
        // window server; hide them for the snapshot only (same transaction,
        // so the screen never sees it) and stand in for the small ones.
        let scan = Self.scanGlass(in: root, surfaceRect: surfaceRect, hidesSurfaceMaterial: hidesSurfaceMaterial)
        #if DEBUG
        if !scan.materialLayers.isEmpty { PanelHideMotionTrace.materialLayers = scan.materialLayers }
        PanelHideMotionTrace.glassStandIns = scan.pills.map { "\($0.rect.integral)" }
        PanelHideMotionTrace.glassLeftOut = scan.leftOut.map { "\($0.integral)" }
        #endif
        context.scaleBy(x: scale, y: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scan.hidden.forEach { $0.isHidden = true }
        let renderBegan = CACurrentMediaTime()
        // `cacheDisplay` redraws every view (Core Animation's `render(in:)`
        // costs the same and loses SwiftUI's text); its cost follows the
        // pixel count. Snapshots ahead of a timed hide, reveal or swipe
        // (`AtticPanelContentContainer.prepareAlternateSnapshot`) keep it
        // off the flight's first frame.
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) {
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            if let image = rep.cgImage {
                context.interpolationQuality = .none
                context.draw(image, in: view.bounds)
            }
        }
        // The controls' own glass: a faint pill over each (a flat snapshot
        // has no layer between a control's surface and its glyph).
        context.setFillColor(!translucent && !dark
            ? NSColor(white: 0, alpha: 0.05).cgColor
            : NSColor(white: 1, alpha: dark ? 0.07 : 0.22).cgColor)
        for pill in scan.pills {
            context.saveGState()
            context.clip(to: pill.clip)
            let radius = min(pill.rect.width, pill.rect.height) / 2
            context.addPath(Path(roundedRect: pill.rect, cornerRadius: radius, style: .continuous).cgPath)
            context.fillPath()
            context.restoreGState()
        }
        PanelHideMotionTrace.note("render", (CACurrentMediaTime() - renderBegan) * 1000)
        scan.hidden.forEach { $0.isHidden = false }
        CATransaction.commit()
        guard let data = context.data else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let made = device.makeTexture(descriptor: descriptor) else { return }
        made.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                     withBytes: data, bytesPerRow: width * 4)
        texture = made
        metalLayer.colorspace = space
    }

    func releaseSnapshot() { texture = nil }

    /// One control's glass stand-in: the control's rect, drawn only inside
    /// `clip`, the part of it the panel shows.
    struct GlassPill: Equatable {
        var rect: CGRect
        var clip: CGRect
    }

    struct GlassScan {
        /// The glass layers to hide while the snapshot renders.
        var hidden: [CALayer] = []
        var materialLayers: [String] = []
        var pills: [GlassPill] = []
        /// Glass the panel never shows (outside it, clipped away, hidden or
        /// transparent), which gets no stand-in.
        var leftOut: [CGRect] = []
    }

    /// Finds the glass the snapshot cannot render, and where a stand-in pill
    /// goes for each control's glass. A stand-in is drawn only where the
    /// control shows at rest: inside the panel's surface and every clipping
    /// ancestor, and not under a hidden or transparent one. (Before draft 5,
    /// glass the panel never shows got a pill too: the next Tasks page's
    /// search row, transparent and parked just past the panel's side, drew a
    /// pill at the window's edge in a hide's first frames and a reveal's last.)
    static func scanGlass(
        in root: CALayer, surfaceRect: CGRect, hidesSurfaceMaterial: Bool,
        className: (CALayer) -> String = { String(describing: type(of: $0)) }
    ) -> GlassScan {
        var scan = GlassScan()
        var groups: [(rect: CGRect, clip: CGRect)] = []
        var elements: [(rect: CGRect, clip: CGRect)] = []
        func walk(_ layer: CALayer, clip: CGRect, shown: Bool) {
            let name = className(layer)
            let shown = shown && !layer.isHidden && layer.opacity > 0.01
            var clip = clip
            // A mask's own frame says nothing about what it lets through (the
            // panel's is zero-sized and draws its shape beyond its bounds), so
            // only bounds clipping narrows the clip; the surface bounds it all.
            if layer.masksToBounds { clip = clip.intersection(root.convert(layer.bounds, from: layer)) }
            let frame = root.convert(layer.bounds, from: layer)
            if name == "CASDFElementLayer" { elements.append((frame, shown ? clip : .null)) }
            // Live Frosted: the panel's material is live under the mesh, so
            // its fill (`CAChameleonLayer`, composited onto the backdrop,
            // which a snapshot draws flat and opaque) stays out too.
            if hidesSurfaceMaterial, name == "CAChameleonLayer", !layer.isHidden {
                if abs(frame.width - surfaceRect.width) < 3, abs(frame.height - surfaceRect.height) < 3 {
                    scan.hidden.append(layer)
                    scan.materialLayers = [name]
                }
            }
            if glassLayerNames.contains(name), !layer.isHidden {
                scan.hidden.append(layer)
                if name == "CASDFLayer" { groups.append((frame, shown ? clip : .null)) }
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer, clip: clip, shown: shown) }
        }
        walk(root, clip: surfaceRect, shown: true)
        // A glass group merges its controls into one shape; stand in for
        // each control, not the group. The panel's own surface needs none.
        for group in groups where group.rect.width < surfaceRect.width - 1 || group.rect.height < surfaceRect.height - 1 {
            let inside = elements.filter {
                group.rect.insetBy(dx: -1, dy: -1).contains($0.rect) && $0.rect.width < group.rect.width - 1
            }
            for pill in inside.isEmpty ? [group] : inside where pill.rect.width > 4 && pill.rect.height > 4 {
                if pill.clip.intersection(pill.rect).width > 0.5, pill.clip.intersection(pill.rect).height > 0.5 {
                    scan.pills.append(GlassPill(rect: pill.rect, clip: pill.clip))
                } else {
                    scan.leftOut.append(pill.rect)
                }
            }
        }
        return scan
    }

    private static let glassLayerNames: Set<String> = [
        // Only the material itself: `SDFLayer` and `SDFPortalLayer` also
        // hold the controls' glyphs.
        "CABackdropLayer", "CASDFLayer", "CASDFElementLayer"
    ]

    /// A flight starts at `progress`. `takeOver` runs once, in the
    /// transaction of the first frame that draws the snapshot: at once when
    /// this layer already has a drawable on screen, otherwise after the
    /// first one is presented (clear frames until then, so the live panel
    /// under it stays what the screen shows).
    func beginFlight(progress: Double, corner: ScreenCorner, takeOver: @escaping () -> Void) {
        self.corner = corner
        self.progress = progress
        isPrewarming = false
        isHidden = false
        if window?.isVisible != true { handover.reset() }
        if handover.begin() {
            onHandover = nil
            takeOver()
            render()
        } else {
            onHandover = takeOver
            render()
            startLink()
        }
    }

    /// Ahead of a likely flight (a pending hide, or fingers resting): show
    /// the layer with a clear frame, so its first drawable reaches the
    /// screen now and the flight can take over on its first frame.
    func prewarm() {
        isHidden = false
        guard window?.isVisible == true, !handover.isEstablished, displayLink == nil else { return }
        isPrewarming = true
        prewarmFrames = 0
        render()
        startLink()
    }

    /// Showing clear frames ahead of a flight (`prewarm`).
    private var isPrewarming = false
    private var prewarmFrames = 0

    /// Draws `progress` now, in the current Core Animation transaction (a
    /// swipe, following the fingers).
    func show(progress: Double, corner: ScreenCorner) {
        self.corner = corner
        self.progress = progress
        isHidden = false
        render()
    }

    @discardableResult
    func animate(
        to target: Double, curve: PanelHideMotionCurve, corner: ScreenCorner,
        completion: @escaping () -> Void
    ) -> TimeInterval {
        stopRun()
        self.corner = corner
        self.completion = completion
        let made = curve.run(from: progress, to: target, start: CACurrentMediaTime())
        if handover.isWaiting {
            // The clock starts when the flight takes over.
            pendingRun = (curve, target)
        } else {
            run = made
        }
        startLink()
        // A display link stops while its window is on no screen (asleep,
        // locked, unplugged): the flight still ends, at its target.
        let watchdog = DispatchWorkItem { [weak self] in self?.finishRun(at: target) }
        self.watchdog?.cancel()
        self.watchdog = watchdog
        let frames = Double(PanelHideMotionTuning.genieHandoverMaxFrames) / 60
        DispatchQueue.main.asyncAfter(deadline: .now() + made.duration + frames + 0.25, execute: watchdog)
        return made.duration
    }

    private var watchdog: DispatchWorkItem?

    /// Ends the run at `target` now and reports it (the watchdog).
    private func finishRun(at target: Double) {
        guard run != nil || pendingRun != nil else { return }
        if handover.isWaiting {
            handover.cancel()
            takeOverNow()
        }
        progress = target
        render()
        let done = completion
        displayLink?.invalidate()
        displayLink = nil
        run = nil
        pendingRun = nil
        completion = nil
        done?()
    }

    private func startLink() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopRun() {
        watchdog?.cancel()
        watchdog = nil
        if let run { progress = run.progress(at: CACurrentMediaTime()) }
        run = nil
        pendingRun = nil
        completion = nil
    }

    /// Freezes where it is (an interruption reverses from here). A flight
    /// still waiting to take over keeps waiting.
    func stop() {
        stopRun()
        if !handover.isWaiting, !isPrewarming {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// Ends the flight: no waiting, no run, nothing drawn.
    func cancelFlight() {
        stopRun()
        isPrewarming = false
        handover.cancel()
        onHandover = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        if isPrewarming {
            prewarmFrames += 1
            if handover.isEstablished || prewarmFrames >= PanelHideMotionTuning.genieHandoverMaxFrames {
                isPrewarming = false
                displayLink?.invalidate()
                displayLink = nil
            } else {
                render()
            }
            return
        }
        if handover.isWaiting {
            if handover.waitedOneFrame() { takeOverNow() } else { render() }
            return
        }
        guard let run else {
            // Nothing to animate (a prewarm, or a swipe's flight that took
            // over): the link only served the wait.
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        progress = run.progress(at: link.targetTimestamp)
        render()
        if run.isFinished(at: link.targetTimestamp) {
            progress = run.to
            watchdog?.cancel()
            watchdog = nil
            let done = completion
            displayLink?.invalidate()
            displayLink = nil
            self.run = nil
            completion = nil
            done?()
        }
    }

    private func takeOverNow() {
        let takeOver = onHandover
        onHandover = nil
        if let pending = pendingRun {
            pendingRun = nil
            run = pending.curve.run(from: progress, to: pending.target, start: CACurrentMediaTime())
        }
        takeOver?()
        render()
    }

    private func render() {
        let scale = window?.backingScaleFactor ?? 2
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if metalLayer.drawableSize != pixelSize { metalLayer.drawableSize = pixelSize }
        if window?.isVisible != true, handover.isEstablished { handover.reset() }
        guard pixelSize.width > 0, pixelSize.height > 0,
              let (pipeline, queue) = PanelGenieRenderer.shared.state(),
              let grid = PanelGenieRenderer.shared.grid,
              let drawable = metalLayer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        // While waiting to take over: a clear frame, so the live panel under
        // it is still what the screen shows.
        let drawsContent = !handover.isWaiting && !isPrewarming
        var uniforms = PanelGenieRenderer.uniforms(progress: progress, corner: corner)
        if drawsContent { frameObserver?(uniforms) }
        if drawsContent, let texture, let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(grid.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<PanelGenieRenderer.Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PanelGenieRenderer.Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: grid.count, indexType: .uint16,
                                          indexBuffer: grid.indices, indexBufferOffset: 0)
            encoder.endEncoding()
        } else if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.endEncoding()
        }
        if !handover.isEstablished, window?.isVisible == true {
            let generation = handover.generation
            drawable.addPresentedHandler { [weak self] presented in
                let time = presented.presentedTime
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, time > 0 else { return }
                        if self.handover.presented(generation: generation) { self.takeOverNow() }
                    }
                }
            }
        }
        buffer.commit()
        buffer.waitUntilScheduled()
        drawable.present()
    }
}

// MARK: - Genie (live glass)

/// The panel's own material, live, for Genie (live glass): the same native
/// glass (or Frosted's material) the panel surface draws, in the panel's
/// squircle. Everything else is the bent snapshot above it.
struct PanelGenieLiveMaterial: Equatable {
    enum Kind: Equatable { case glass, frosted }
    var kind: Kind
    var colorScheme: ColorScheme
    var cornerRadius: CGFloat
}

private struct PanelGenieMaterialView: View {
    let material: PanelGenieLiveMaterial
    /// The panel's squircle at rest, in this view's coordinates (y down).
    var rest: CGRect
    /// In flight: the bent outline (y down). Nil draws the squircle.
    var outline: Path?

    var body: some View {
        let shape = PanelGenieOutlineShape(outline: outline, rest: rest, cornerRadius: material.cornerRadius)
        Group {
            switch material.kind {
            case .glass:
                // As `AtticPanelSurface`'s native glass, in the bent shape:
                // Liquid Glass draws its own rim along the bent edge.
                shape.fill(Color.clear).glassEffect(.regular, in: shape)
            case .frosted:
                shape.fill(.ultraThinMaterial)
            }
        }
        .environment(\.colorScheme, material.colorScheme)
        // Each frame's shape is the mesh's, not a morph toward it.
        .transaction { $0.disablesAnimations = true; $0.animation = nil }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The live material's shape: the mesh's bent outline in flight, the
/// panel's own squircle otherwise.
struct PanelGenieOutlineShape: Shape {
    var outline: Path?
    var rest: CGRect
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        outline ?? Squircle(cornerRadius: cornerRadius, exponent: AtticStyle.panelSquircleExponent).path(in: rest)
    }
}

/// Under the Genie mesh: the panel's material, live, in the outline of the
/// bent panel, so it keeps blurring the real desktop in the bending shape.
/// Glass takes the outline as its own shape every frame, so its rim runs
/// along the bent edge; Frosted (no rim) is masked to it. Fills the content
/// container (the mesh's space).
final class PanelGenieLiveGlassView: NSView {
    private let maskLayer = CAShapeLayer()
    private var host: NSHostingView<PanelGenieMaterialView>?
    private var material: PanelGenieLiveMaterial?
    /// The surface's squircle in mesh coordinates (0…1, y up), sampled
    /// densely enough to follow the mesh's columns and rows.
    private var outline: [SIMD2<Float>] = []
    private var points: [CGPoint] = []
    private var rest: CGRect = .zero
    /// Shown by the flight once it has taken over from the live panel.
    var isEngaged = false { didSet { if !isEngaged { isHidden = true } } }

    /// Glass bends its own shape (its rim follows the bend); otherwise the
    /// material is masked to the outline.
    private var shapesMaterial: Bool { material?.kind == .glass && PanelGenieLiveGlassView.glassTakesOutlineShape }
    static var glassTakesOutlineShape: Bool = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ATTIC_MOTION_BENCH_RIM"] == "mask" { return false }
        #endif
        return true
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        maskLayer.fillColor = NSColor.black.cgColor
        // A plain layer animates its path implicitly; the mask must land in
        // the same transaction as the mesh's drawable.
        maskLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Lays the material over the container, its squircle at `surfaceRect`
    /// (container coordinates), and samples its outline.
    func configure(material: PanelGenieLiveMaterial, surfaceRect: CGRect) {
        rest = CGRect(x: surfaceRect.minX, y: bounds.height - surfaceRect.maxY,
                      width: surfaceRect.width, height: surfaceRect.height)
        let view = PanelGenieMaterialView(material: material, rest: rest, outline: nil)
        if let host {
            host.rootView = view
        } else {
            let made = NSHostingView(rootView: view)
            made.sizingOptions = []
            addSubview(made)
            host = made
        }
        self.material = material
        layer?.mask = shapesMaterial ? nil : maskLayer
        // Its own appearance, not the window's: a reveal lays it out while
        // the panel is still off screen.
        host?.appearance = NSAppearance(named: material.colorScheme == .dark ? .darkAqua : .aqua)
        if host?.frame != bounds { host?.frame = bounds }
        maskLayer.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { outline = []; return }
        let squircle = Squircle(cornerRadius: material.cornerRadius, exponent: AtticStyle.panelSquircleExponent)
            .path(in: surfaceRect).cgPath
        var sampled: [SIMD2<Float>] = []
        var last: CGPoint?
        var first: CGPoint?
        let step: CGFloat = 2
        func add(_ point: CGPoint) {
            if let last {
                let pieces = max(1, Int((hypot(point.x - last.x, point.y - last.y) / step).rounded(.up)))
                for k in 1...pieces {
                    let t = CGFloat(k) / CGFloat(pieces)
                    sampled.append(SIMD2(Float((last.x + (point.x - last.x) * t) / bounds.width),
                                         Float((last.y + (point.y - last.y) * t) / bounds.height)))
                }
            } else {
                sampled.append(SIMD2(Float(point.x / bounds.width), Float(point.y / bounds.height)))
            }
            last = point
        }
        squircle.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: first = e.points[0]; last = nil; add(e.points[0])
            case .addLineToPoint: add(e.points[0])
            case .addQuadCurveToPoint: add(e.points[1])
            case .addCurveToPoint: add(e.points[2])
            case .closeSubpath: if let first { add(first) }
            @unknown default: break
            }
        }
        outline = sampled
        points = Array(repeating: .zero, count: sampled.count)
    }

    /// The material in the mesh's outline at `uniforms`. Called in the mesh
    /// frame's transaction.
    func update(_ uniforms: PanelGenieRenderer.Uniforms) {
        #if DEBUG
        let began = CACurrentMediaTime()
        defer { PanelHideMotionTrace.maskMicroseconds = (CACurrentMediaTime() - began) * 1_000_000 }
        #endif
        isHidden = !isEngaged
        guard isEngaged else { return }
        let width = bounds.width, height = bounds.height
        for index in outline.indices {
            let p = PanelGenieRenderer.meshPosition(outline[index], uniforms)
            points[index] = CGPoint(x: CGFloat(p.x) * width, y: CGFloat(p.y) * height)
        }
        if shapesMaterial, let host, let material {
            var path = Path()
            path.addLines(points.map { CGPoint(x: $0.x, y: height - $0.y) })
            path.closeSubpath()
            host.rootView = PanelGenieMaterialView(material: material, rest: rest, outline: path)
            host.layoutSubtreeIfNeeded()
        } else {
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            maskLayer.path = path
        }
        // The mesh fades its last sliver; the material fades with it.
        layer?.opacity = uniforms.alpha
    }
}

/// What a Genie snapshot stands on: the panel's own material, kept live
/// under it (nil on Solid, which transmits nothing).
struct PanelGenieSurface: Equatable {
    var live: PanelGenieLiveMaterial?
    /// Glass or Frosted (the controls' glass gets a light stand-in).
    var translucent: Bool
}
