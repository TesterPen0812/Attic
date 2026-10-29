import AppKit
import CoreImage
import IOSurface
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
    /// How long a snapshot taken ahead of a hide, reveal or swipe stays good.
    static let geniePreparedLifetime: CFTimeInterval = 1.5
    /// The panel idle this long, Genie prepares its snapshot (so a swipe
    /// starts without one, and a vertical scroll's touch-down never pays it:
    /// at finger rest it froze a swipe that moved within ~80 ms, g6 gesture
    /// checks), and keeps it this long while nothing changes.
    static let genieIdlePrepareDelay: TimeInterval = 0.5
    static let genieIdlePreparedLifetime: CFTimeInterval = 30
    /// A timed hide or reveal prepares its snapshot this long ahead.
    static let geniePrepareLead: TimeInterval = 0.25

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

    /// How fast the run goes at `time` (progress per second; over the last
    /// 1/240 s, so 0 once it has finished and before it starts).
    func velocity(at time: CFTimeInterval) -> Double {
        let step = 1.0 / 240
        return (progress(at: time) - progress(at: time - step)) / step
    }

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
///
/// Each frame is drawn into an IOSurface that becomes a plain layer's
/// contents in the current Core Animation transaction, so a frame reaches
/// the screen with every change made beside it (the live panel stepping
/// aside, the live material's mask). A `CAMetalLayer`'s drawable did not,
/// whatever its `presentsWithTransaction`: it came one or two frames after
/// them, which showed an empty or a glass-only panel as a hide began
/// (draft 5, 1 hide in 21; owner, 2026-10-21).
///
/// The controls' Liquid Glass rides the motion live (owner, 2026-10-23:
/// a stand-in fill calibrated on one backdrop turned the grey glass over a
/// dark wallpaper flat white in flight). The snapshot is two meshes, the
/// content and the controls' glyphs, with each control's own glass, live,
/// in its bent outline between them: the glass samples the bent content and
/// whatever is behind the window, as it does at rest.
final class PanelGenieView: NSView {
    /// Bottom to top: the content mesh, the controls' live glass, the
    /// controls' mesh (their glyphs and fills).
    private let contentView = NSView()
    private let controlGlassView = PanelGenieControlGlassView()
    private let controlsView = NSView()
    private let meshLayer = CALayer()
    private let controlsMeshLayer = CALayer()
    private var texture: MTLTexture?
    /// The controls drawn alone, when their glass is live (nil: the content
    /// texture holds everything).
    private var controlsTexture: MTLTexture?
    private var colorSpace: CGColorSpace?
    private var displayLink: CADisplayLink?
    private var run: PanelHideMotionRun?
    private var corner: ScreenCorner = .topRight
    /// Called with every drawn frame's uniforms, in the frame's own
    /// transaction (the live material's mask moves with it).
    var frameObserver: ((PanelGenieRenderer.Uniforms) -> Void)?
    private var completion: (() -> Void)?
    private var watchdog: DispatchWorkItem?
    private(set) var progress: Double = 0
    /// The frames' IOSurfaces, used in turn (the window server may still be
    /// showing the last one): the content's and the controls'.
    private var surfaces = PanelGenieSurfaceRing()
    private var controlSurfaces = PanelGenieSurfaceRing()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (view, layer) in [(contentView, meshLayer), (controlsView, controlsMeshLayer)] {
            layer.actions = ["contents": NSNull(), "contentsScale": NSNull(), "bounds": NSNull(),
                             "position": NSNull(), "frame": NSNull(), "hidden": NSNull()]
            layer.contentsGravity = .resize
            layer.isOpaque = false
            view.wantsLayer = true
            view.layer?.addSublayer(layer)
        }
        for view in [contentView, controlGlassView, controlsView] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        meshLayer.frame = contentView.bounds
        controlsMeshLayer.frame = controlsView.bounds
        CATransaction.commit()
    }

    var hasSnapshot: Bool { texture != nil }
    /// The snapshot's size in pixels (tests: it is taken at the window's
    /// backing scale).
    var snapshotPixelSize: CGSize? { texture.map { CGSize(width: $0.width, height: $0.height) } }
    /// The last frame drawn (tests: a frame is there as soon as it is asked for).
    var shownFrame: Any? { meshLayer.contents }
    /// The controls' last frame (nil while their glass is not live).
    var shownControlsFrame: Any? { controlsMeshLayer.contents }
    /// The controls' live glass (tests read its shapes).
    var liveControlGlass: PanelGenieControlGlassView { controlGlassView }
    var isAnimating: Bool { run != nil }
    /// Where the motion is now, read between display frames.
    var currentProgress: Double { run?.progress(at: CACurrentMediaTime()) ?? progress }
    /// How fast the motion goes now (progress per second; 0 when none runs).
    var currentVelocity: Double { run?.velocity(at: CACurrentMediaTime()) ?? 0 }

    // MARK: Snapshot

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    /// Core Image's first blur costs a further ~20 ms (Air): pay it when
    /// Genie is chosen, off the main thread, not in a flight's snapshot.
    static func prewarmImageWork() {
        DispatchQueue.global(qos: .utility).async {
            let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            let mask = CIImage(color: .white).cropped(to: image.extent)
            let blurred = image.applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": mask, kCIInputRadiusKey: 2])
            _ = imageContext.createCGImage(blurred, from: image.extent)
        }
    }

    /// Takes the snapshot the grid draws, at the window's backing scale (so
    /// text stays crisp in flight). The panel's material stays live under
    /// the mesh, so the snapshot leaves it out.
    ///
    /// No in-process render draws a backdrop: `cacheDisplay` (and Core
    /// Animation's `render(in:)`) leave out the controls' Liquid Glass and
    /// the edges' variable blurs, so rows under the add bar showed through
    /// and the corner buttons went flat (owner, 2026-10-21). `tiers` is the
    /// panel's layer whose children are, bottom to top, the surface and the
    /// pages' content, the edges' variable blurs, then the controls. The
    /// content is rendered alone and the blurs are made from it; the
    /// controls are rendered alone into their own texture, and each
    /// control's glass rides between the two, live, in `dark`'s appearance.
    func captureSnapshot(
        of view: NSView, tiers: CALayer?, surfaceRect: CGRect, cornerRadius: CGFloat, dark: Bool,
        hidesSurfaceMaterial: Bool = false
    ) {
        let began = CACurrentMediaTime()
        defer { PanelHideMotionTrace.note("total", (CACurrentMediaTime() - began) * 1000) }
        texture = nil
        controlsTexture = nil
        controlGlassView.configure(pills: [], in: view.bounds.size, dark: dark)
        guard let device = PanelGenieRenderer.shared.device, let root = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = Int((view.bounds.width * scale).rounded()), height = Int((view.bounds.height * scale).rounded())
        let space = view.window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0, let context = Self.bitmap(width: width, height: height, space: space) else { return }
        let scan = Self.scanGlass(in: root, surfaceRect: surfaceRect, hidesSurfaceMaterial: hidesSurfaceMaterial)
        #if DEBUG
        if !scan.materialLayers.isEmpty { PanelHideMotionTrace.materialLayers = scan.materialLayers }
        PanelHideMotionTrace.glassStandIns = scan.pills.map { "\($0.rect.integral)" }
        PanelHideMotionTrace.glassLeftOut = scan.leftOut.map { "\($0.integral)" }
        #endif
        let split = Self.tierSplit(tiers, surfaceRect: surfaceRect)
        let renderBegan = CACurrentMediaTime()
        func render(hiding extra: [CALayer]) -> CGImage? {
            // Hidden for the render only, in one transaction the screen never sees.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let hidden = (scan.hidden + extra).filter { !$0.isHidden }
            hidden.forEach { $0.isHidden = true }
            defer {
                hidden.forEach { $0.isHidden = false }
                CATransaction.commit()
            }
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.cgImage
        }
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .none
        var controlsImage: CGImage?
        if let split, !(scan.pills.isEmpty && scan.bands.isEmpty) {
            // The content (with the surface under it) and its blurs; the
            // controls on their own when their glass rides live between.
            var stage = CACurrentMediaTime()
            func lap(_ name: String) {
                PanelHideMotionTrace.note(name, (CACurrentMediaTime() - stage) * 1000)
                stage = CACurrentMediaTime()
            }
            let content = render(hiding: split.aboveContent)
            lap("r_content")
            let controls = render(hiding: split.belowControls)
            lap("r_controls")
            if let content {
                context.draw(Self.blurredBands(content: content, bands: scan.bands, scale: scale) ?? content, in: view.bounds)
                lap("glass_look")
            }
            if scan.pills.isEmpty {
                if let controls { context.draw(controls, in: view.bounds) }
            } else {
                controlsImage = controls
            }
            PanelHideMotionTrace.note("tiers", 1)
            #if DEBUG
            if ProcessInfo.processInfo.environment["ATTIC_MOTION_BENCH_DUMP"] == "1" {
                let folder = URL(fileURLWithPath: NSTemporaryDirectory())
                for (name, image) in [("tier-content", content), ("tier-controls", controls), ("tier-final", context.makeImage())] {
                    guard let image, let destination = CGImageDestinationCreateWithURL(
                        folder.appendingPathComponent("\(name).png") as CFURL, "public.png" as CFString, 1, nil) else { continue }
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                }
            }
            #endif
        } else if let whole = render(hiding: []) {
            context.draw(whole, in: view.bounds)
            PanelHideMotionTrace.note("tiers", 0)
        }
        PanelHideMotionTrace.note("render", (CACurrentMediaTime() - renderBegan) * 1000)
        guard let made = Self.texture(from: context, device: device) else { return }
        if let controlsImage, let controlsContext = Self.bitmap(width: width, height: height, space: space) {
            controlsContext.draw(controlsImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            controlsTexture = Self.texture(from: controlsContext, device: device)
            if controlsTexture != nil {
                controlGlassView.configure(pills: scan.pills, in: view.bounds.size, dark: dark)
            }
        }
        texture = made
        colorSpace = space
    }

    func releaseSnapshot() {
        texture = nil
        controlsTexture = nil
        controlGlassView.configure(pills: [], in: bounds.size, dark: false)
    }

    private static func texture(from context: CGContext, device: MTLDevice) -> MTLTexture? {
        guard let data = context.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: context.width, height: context.height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let made = device.makeTexture(descriptor: descriptor) else { return nil }
        made.replace(region: MTLRegionMake2D(0, 0, context.width, context.height), mipmapLevel: 0,
                     withBytes: data, bytesPerRow: context.bytesPerRow)
        return made
    }

    private static func bitmap(width: Int, height: Int, space: CGColorSpace) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// The panel's top-level layers each render hides: the content's hides
    /// the edges' blurs and the controls; the controls' hides the surface,
    /// the content and the blurs. Nil when they cannot be told apart.
    struct TierSplit {
        var aboveContent: [CALayer]
        var belowControls: [CALayer]
    }

    static func tierSplit(_ tiers: CALayer?, surfaceRect: CGRect,
                          className: @escaping (CALayer) -> String = { String(describing: type(of: $0)) }) -> TierSplit? {
        guard let layers = tiers?.sublayers, !layers.isEmpty else { return nil }
        func contains(_ layer: CALayer, _ test: (CALayer) -> Bool) -> Bool {
            test(layer) || (layer.sublayers ?? []).contains { contains($0, test) }
        }
        let isBlur: (CALayer) -> Bool = { layer in
            className(layer) == "CABackdropLayer"
                && (layer.filters ?? []).contains { (($0 as? NSObject)?.value(forKey: "name") as? String) == "variableBlur" }
        }
        let isControlGlass: (CALayer) -> Bool = { layer in
            guard className(layer) == "CASDFLayer", let root = tiers else { return false }
            let frame = root.convert(layer.bounds, from: layer)
            return frame.width < surfaceRect.width - 3 || frame.height < surfaceRect.height - 3
        }
        let blurs = layers.indices.filter { contains(layers[$0], isBlur) }
        let first: Int
        if let firstBlur = blurs.first {
            first = firstBlur
        } else if let firstGlass = layers.indices.first(where: {
            // A shown control: the next page's search row, transparent and
            // parked past the panel's side, sits below the content.
            !layers[$0].isHidden && layers[$0].opacity > 0.01 && contains(layers[$0], isControlGlass)
        }) {
            first = firstGlass
        } else {
            return nil
        }
        // The blurs sit between the content and the controls: they belong
        // to neither render (each is made from the content).
        let controlsStart = (blurs.last.map { $0 + 1 }) ?? first
        return TierSplit(aboveContent: Array(layers[first...]),
                         belowControls: Array(layers[..<min(controlsStart, layers.count)]))
    }

    /// The content with the edges' variable blurs made from it (y up). Core
    /// Image works on those regions only, so a snapshot costs a few
    /// milliseconds more, not a full-size pass. Nil when there are none.
    private static func blurredBands(content: CGImage, bands: [GlassBand], scale: CGFloat) -> CGImage? {
        guard !bands.isEmpty else { return nil }
        let space = content.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = bitmap(width: content.width, height: content.height, space: space) else { return nil }
        let full = CGRect(x: 0, y: 0, width: content.width, height: content.height)
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                .integral.intersection(full)
        }
        context.draw(content, in: full)
        // The edges' variable blurs: strongest at the panel's edge.
        let source = CIImage(cgImage: content).clampedToExtent()
        for band in bands where !band.strengths.isEmpty {
            let rect = pixels(band.clip.intersection(band.rect))
            guard rect.width > 0, rect.height > 0 else { continue }
            let rows = band.strengths.count
            let step = band.rect.height * scale / CGFloat(rows)
            var mask = CIImage(color: .black).cropped(to: rect)
            for (row, strength) in band.strengths.enumerated() {
                let strip = CGRect(x: band.rect.minX * scale, y: band.rect.maxY * scale - CGFloat(row + 1) * step,
                                   width: band.rect.width * scale, height: step + 1).intersection(rect)
                guard !strip.isEmpty else { continue }
                mask = CIImage(color: CIColor(red: strength, green: strength, blue: strength)).cropped(to: strip)
                    .composited(over: mask)
            }
            let blurred = source.applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": mask, kCIInputRadiusKey: band.radius * scale
            ])
            guard let patch = imageContext.createCGImage(blurred, from: rect, format: .BGRA8, colorSpace: space) else { continue }
            context.setBlendMode(.copy)
            context.draw(patch, in: rect)
            context.setBlendMode(.normal)
        }
        return context.makeImage()
    }

    /// One control's glass: the control's rect, shown only inside `clip`,
    /// the part of it the panel shows. In flight it rides the mesh live.
    struct GlassPill: Equatable {
        var rect: CGRect
        var clip: CGRect
        /// The control's own shape at rest, read from its glass element
        /// (`cornerRadius` and `cornerCurve`): the corner buttons are 32 pt
        /// squares at 13.5 continuous, not circles (owner, 2026-10-21). Nil
        /// when the glass gave none: a capsule.
        var cornerRadius: CGFloat?
        var continuous = true

        init(rect: CGRect, clip: CGRect, cornerRadius: CGFloat? = nil, continuous: Bool = true) {
            self.rect = rect
            self.clip = clip
            self.cornerRadius = cornerRadius
            self.continuous = continuous
        }

        /// The control's outline, `inset` points in from its edge.
        func path(inset: CGFloat = 0) -> CGPath {
            let shape = rect.insetBy(dx: inset, dy: inset)
            let radius = max(0, min(cornerRadius ?? .greatestFiniteMagnitude, min(rect.width, rect.height) / 2) - inset)
            return Path(roundedRect: shape, cornerRadius: radius, style: continuous ? .continuous : .circular).cgPath
        }
    }

    /// One in-window variable blur (a page's top or bottom edge): its rect,
    /// the part the panel shows, and its strength from top to bottom.
    struct GlassBand: Equatable {
        var rect: CGRect
        var clip: CGRect
        /// 0…1 per row, the first at the rect's top (maxY); empty is 1.
        var strengths: [CGFloat]
        /// The blur's radius at full strength (points).
        var radius: CGFloat = AtticEdgeBlurMetrics.radius
    }

    struct GlassScan {
        /// The glass layers to hide while the snapshot renders.
        var hidden: [CALayer] = []
        /// The variable blurs (not the controls' own glass).
        var bands: [GlassBand] = []
        var materialLayers: [String] = []
        var pills: [GlassPill] = []
        /// Glass the panel never shows (outside it, clipped away, hidden or
        /// transparent), which gets no live glass in flight.
        var leftOut: [CGRect] = []
    }

    /// Finds the glass the snapshot cannot render, and each control's glass
    /// that rides the flight live. It rides only where the
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
        var elements: [(rect: CGRect, clip: CGRect, radius: CGFloat, continuous: Bool)] = []
        var backdrops: [GlassBand] = []
        var materialParents: [CALayer] = []
        func surfaceSized(_ frame: CGRect) -> Bool {
            abs(frame.width - surfaceRect.width) < 3 && abs(frame.height - surfaceRect.height) < 3
        }
        func walk(_ layer: CALayer, clip: CGRect, shown: Bool) {
            let name = className(layer)
            let shown = shown && !layer.isHidden && layer.opacity > 0.01
            var clip = clip
            // A mask's own frame says nothing about what it lets through (the
            // panel's is zero-sized and draws its shape beyond its bounds), so
            // only bounds clipping narrows the clip; the surface bounds it all.
            if layer.masksToBounds { clip = clip.intersection(root.convert(layer.bounds, from: layer)) }
            let frame = root.convert(layer.bounds, from: layer)
            if name == "CASDFElementLayer" {
                elements.append((frame, shown ? clip : .null, layer.cornerRadius, layer.cornerCurve == .continuous))
            }
            if hidesSurfaceMaterial, name == "CABackdropLayer", surfaceSized(frame), let parent = layer.superlayer {
                materialParents.append(parent)
            }
            if name == "CABackdropLayer", shown, !surfaceSized(frame), frame.width > 4, frame.height > 4 {
                let blur = variableBlur(of: layer)
                backdrops.append(GlassBand(rect: frame, clip: clip, strengths: blur.strengths, radius: blur.radius))
            }
            if glassLayerNames.contains(name), !layer.isHidden {
                scan.hidden.append(layer)
                if name == "CASDFLayer" { groups.append((frame, shown ? clip : .null)) }
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer, clip: clip, shown: shown) }
        }
        walk(root, clip: surfaceRect, shown: true)
        // Live Frosted: the panel's material is live under the mesh, so all
        // of it stays out of the snapshot: beside its backdrop, a fill
        // composited with a blend mode (`darkenBlendMode`) and a
        // `CAChameleonLayer`, which a render draws flat and opaque. (Drafts
        // left the blended fill in: Frosted read white and opaque in flight.)
        for parent in materialParents {
            for sibling in parent.sublayers ?? [] where !sibling.isHidden && className(sibling) != "CABackdropLayer" {
                let frame = root.convert(sibling.bounds, from: sibling)
                guard surfaceSized(frame), sibling.compositingFilter != nil || className(sibling) == "CAChameleonLayer" else { continue }
                scan.hidden.append(sibling)
                scan.materialLayers.append(className(sibling))
            }
        }
        // A backdrop inside a control's glass is that glass; the rest are
        // the edges' variable blurs, strongest at the panel's edge.
        let controls = groups.filter { !surfaceSized($0.rect) }.map { $0.rect.insetBy(dx: -1, dy: -1) }
        for var band in backdrops where !controls.contains(where: { $0.contains(band.rect) }) {
            guard band.clip.intersection(band.rect).height > 0.5 else { continue }
            if let first = band.strengths.first, let last = band.strengths.last {
                let atTop = band.rect.midY > surfaceRect.midY
                if atTop ? last > first : first > last { band.strengths.reverse() }
            }
            scan.bands.append(band)
        }
        // A glass group merges its controls into one shape; ride live for
        // each control, not the group. The panel's own surface needs none.
        for group in groups where group.rect.width < surfaceRect.width - 1 || group.rect.height < surfaceRect.height - 1 {
            let inside = elements.filter {
                group.rect.insetBy(dx: -1, dy: -1).contains($0.rect) && $0.rect.width < group.rect.width - 1
            }
            // A group of one control: that control's own element gives the shape.
            let alone = elements.first {
                abs($0.rect.minX - group.rect.minX) < 1 && abs($0.rect.minY - group.rect.minY) < 1
                    && abs($0.rect.width - group.rect.width) < 1 && abs($0.rect.height - group.rect.height) < 1
            }
            let candidates = inside.isEmpty
                ? [(rect: group.rect, clip: group.clip, radius: alone?.radius ?? -1, continuous: alone?.continuous ?? true)]
                : inside
            for pill in candidates where pill.rect.width > 4 && pill.rect.height > 4 {
                if pill.clip.intersection(pill.rect).width > 0.5, pill.clip.intersection(pill.rect).height > 0.5 {
                    let made = GlassPill(rect: pill.rect, clip: pill.clip,
                                         cornerRadius: pill.radius >= 0 ? pill.radius : nil, continuous: pill.continuous)
                    // A glass group has two SDF layers (its backdrop's and its
                    // content's vibrancy): one control, one glass. Drawn twice,
                    // live glass doubled its tint (g8: the add bar 16-34
                    // levels off rest).
                    if !scan.pills.contains(made) { scan.pills.append(made) }
                } else if !scan.leftOut.contains(pill.rect) {
                    scan.leftOut.append(pill.rect)
                }
            }
        }
        return scan
    }

    /// A variable blur's strength per row of its mask (top row first; empty
    /// for a uniform backdrop) and its radius.
    private static func variableBlur(of layer: CALayer) -> (strengths: [CGFloat], radius: CGFloat) {
        for filter in layer.filters ?? [] {
            guard let filter = filter as? NSObject, filter.responds(to: NSSelectorFromString("valueForKey:")),
                  let value = filter.value(forKey: "inputMaskImage"),
                  CFGetTypeID(value as CFTypeRef) == CGImage.typeID else { continue }
            let image = value as! CGImage // swiftlint:disable:this force_cast
            let rows = image.height
            guard rows > 0, let context = CGContext(
                data: nil, width: 1, height: rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { continue }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: rows))
            guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { continue }
            let radius = (filter.value(forKey: "inputRadius") as? NSNumber).map { CGFloat($0.doubleValue) }
            return ((0..<rows).map { CGFloat(data[$0 * context.bytesPerRow]) / 255 }, radius ?? AtticEdgeBlurMetrics.radius)
        }
        return ([], AtticEdgeBlurMetrics.radius)
    }

    private static let glassLayerNames: Set<String> = [
        // Only the material itself: `SDFLayer` and `SDFPortalLayer` also
        // hold the controls' glyphs.
        "CABackdropLayer", "CASDFLayer", "CASDFElementLayer"
    ]


    // MARK: Flight

    /// A flight starts at `progress`: `takeOver` (the live panel stepping
    /// aside) and the first frame land in one transaction.
    func beginFlight(progress: Double, corner: ScreenCorner, takeOver: () -> Void) {
        self.corner = corner
        self.progress = progress
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = false
        render()
        takeOver()
        CATransaction.commit()
    }

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
        stop()
        self.corner = corner
        self.completion = completion
        let made = curve.run(from: progress, to: target, start: CACurrentMediaTime())
        run = made
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        // A display link stops while its window is on no screen (asleep,
        // locked, unplugged): the flight still ends, at its target.
        let watchdog = DispatchWorkItem { [weak self] in self?.finish(at: target) }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + made.duration + 0.25, execute: watchdog)
        return made.duration
    }

    /// Freezes where it is (an interruption reverses from here).
    func stop() {
        watchdog?.cancel()
        watchdog = nil
        if let run { progress = run.progress(at: CACurrentMediaTime()) }
        displayLink?.invalidate()
        displayLink = nil
        run = nil
        completion = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let run else { return }
        progress = run.progress(at: link.targetTimestamp)
        render()
        if run.isFinished(at: link.targetTimestamp) { finish(at: run.to) }
    }

    private func finish(at target: Double) {
        guard run != nil else { return }
        progress = target
        render()
        let done = completion
        watchdog?.cancel()
        watchdog = nil
        displayLink?.invalidate()
        displayLink = nil
        run = nil
        completion = nil
        done?()
    }

    private func render() {
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let device = PanelGenieRenderer.shared.device,
              let (pipeline, queue) = PanelGenieRenderer.shared.state(),
              let grid = PanelGenieRenderer.shared.grid,
              let frame = surfaces.next(width: width, height: height, device: device),
              let buffer = queue.makeCommandBuffer() else { return }
        let controlsFrame = controlsTexture == nil ? nil : controlSurfaces.next(width: width, height: height, device: device)
        var uniforms = PanelGenieRenderer.uniforms(progress: progress, corner: corner)
        frameObserver?(uniforms)
        controlGlassView.update(uniforms, isShown: controlsFrame != nil)
        func draw(_ texture: MTLTexture?, into target: MTLTexture) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            if let texture {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(grid.vertices, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<PanelGenieRenderer.Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PanelGenieRenderer.Uniforms>.stride, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: grid.count, indexType: .uint16,
                                              indexBuffer: grid.indices, indexBufferOffset: 0)
            }
            encoder.endEncoding()
        }
        draw(texture, into: frame.target)
        if let controlsFrame { draw(controlsTexture, into: controlsFrame.target) }
        buffer.commit()
        // The frame is complete before the layer shows it (well under a
        // millisecond for the grid).
        buffer.waitUntilCompleted()
        if let space = colorSpace?.copyICCData() {
            frame.surface.setAttachment(space, forKey: "IOSurfaceColorSpace")
            controlsFrame?.surface.setAttachment(space, forKey: "IOSurfaceColorSpace")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        meshLayer.contentsScale = scale
        meshLayer.contents = frame.surface
        controlsMeshLayer.contentsScale = scale
        controlsMeshLayer.contents = controlsFrame?.surface
        CATransaction.commit()
    }
}

/// A Genie mesh's frames: IOSurfaces used in turn, remade when the size
/// changes, never one the window server is still showing.
struct PanelGenieSurfaceRing {
    private var surfaces: [(surface: IOSurface, target: MTLTexture)] = []
    private var nextIndex = 0

    mutating func next(width: Int, height: Int, device: MTLDevice) -> (surface: IOSurface, target: MTLTexture)? {
        if surfaces.first.map({ $0.target.width != width || $0.target.height != height }) ?? true {
            surfaces = []
            for _ in 0..<3 {
                guard let surface = IOSurface(properties: [
                    .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: UInt32(0x4247_5241) // 'BGRA'
                ]) else { return nil }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
                )
                descriptor.usage = [.renderTarget]
                descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
                guard let target = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
                surfaces.append((surface, target))
            }
            nextIndex = 0
        }
        for _ in surfaces.indices {
            let candidate = surfaces[nextIndex]
            nextIndex = (nextIndex + 1) % surfaces.count
            if !candidate.surface.isInUse { return candidate }
        }
        return surfaces[nextIndex]
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
    /// In its resting shape at once (no SwiftUI change: a plain layer one).
    var isEngaged = false { didSet { isHidden = !isEngaged } }
    /// The material's shape is the squircle at rest (no outline set).
    private var showsRestShape = true

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
        showsRestShape = true
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
        let sampled = PanelGenieOutline.sample(squircle, in: bounds.size).first ?? []
        outline = sampled
        points = Array(repeating: .zero, count: sampled.count)
        // At rest the mask is the squircle itself.
        let restMask = CGMutablePath()
        restMask.addPath(squircle)
        maskLayer.path = restMask
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
        // Still at rest: keep the resting shape (changing it lands a frame
        // late; there is nothing to change yet).
        if uniforms.curve == 0, uniforms.slide == 0, showsRestShape {
            layer?.opacity = uniforms.alpha
            return
        }
        showsRestShape = false
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

/// Outlines the Genie mesh bends: a path sampled every couple of points
/// in mesh coordinates (0…1, y up), one array per subpath.
enum PanelGenieOutline {
    static func sample(_ path: CGPath, in size: CGSize, step: CGFloat = 2) -> [[SIMD2<Float>]] {
        guard size.width > 0, size.height > 0 else { return [] }
        var subpaths: [[SIMD2<Float>]] = []
        var sampled: [SIMD2<Float>] = []
        var last: CGPoint?
        var first: CGPoint?
        func add(_ point: CGPoint) {
            if let last {
                let pieces = max(1, Int((hypot(point.x - last.x, point.y - last.y) / step).rounded(.up)))
                for k in 1...pieces {
                    let t = CGFloat(k) / CGFloat(pieces)
                    sampled.append(SIMD2(Float((last.x + (point.x - last.x) * t) / size.width),
                                         Float((last.y + (point.y - last.y) * t) / size.height)))
                }
            } else {
                sampled.append(SIMD2(Float(point.x / size.width), Float(point.y / size.height)))
            }
            last = point
        }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if sampled.count > 2 { subpaths.append(sampled) }
                sampled = []
                first = e.points[0]; last = nil; add(e.points[0])
            case .addLineToPoint: add(e.points[0])
            case .addQuadCurveToPoint: add(e.points[1])
            case .addCurveToPoint: add(e.points[2])
            case .closeSubpath: if let first { add(first) }
            @unknown default: break
            }
        }
        if sampled.count > 2 { subpaths.append(sampled) }
        return subpaths
    }
}

private struct PanelGeniePathShape: Shape {
    var path: Path
    func path(in rect: CGRect) -> Path { path }
}

/// The controls' Liquid Glass in a Genie flight, each control's own glass
/// in its bent outline.
private struct PanelGenieControlGlassShapes: View {
    var shapes: [Path]
    var colorScheme: ColorScheme

    var body: some View {
        // In a glass container, as the controls' glass is at rest
        // (`AtticControlGroup`): measured on the Air (g8), a container's
        // glass matched rest within 3 levels on the corner buttons, plain
        // glass was 2-6 off; `.interactive()` changed nothing.
        GlassEffectContainer(spacing: AtticControlShape.mergeDistance) {
            ZStack {
                ForEach(shapes.indices, id: \.self) { index in
                    let shape = PanelGeniePathShape(path: shapes[index])
                    // As `AtticRaisedMaterialModifier`'s glass: Liquid Glass
                    // draws its own rim along the bent edge.
                    shape.fill(Color.clear).glassEffect(.regular, in: shape)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.colorScheme, colorScheme)
        // Each frame's shape is the mesh's, not a morph toward it.
        .transaction { $0.disablesAnimations = true; $0.animation = nil }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Between the Genie's content mesh and its controls' mesh: each control's
/// Liquid Glass, live, in the outline the mesh bends it to (owner,
/// 2026-10-23: the calibrated stand-in fill turned the controls' grey glass
/// over a dark wallpaper flat white in flight). Live, it composites what is
/// under it (the bent content, the panel's live material, whatever is
/// behind the window) as the controls' glass does at rest, on any backdrop.
final class PanelGenieControlGlassView: NSView {
    private var host: NSHostingView<PanelGenieControlGlassShapes>?
    /// Each control's outline in mesh coordinates (0…1, y up), per subpath.
    private var outlines: [[[SIMD2<Float>]]] = []
    /// Each control's outline at rest, in the snapshot's coordinates (y up).
    private var restOutlines: [CGPath] = []
    private var snapshotSize: CGSize = .zero
    private var colorScheme: ColorScheme = .light
    private var showsRestShapes = true
    /// The shapes drawn now, in this view's coordinates (y down; tests).
    private(set) var shapes: [Path] = []

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The controls' glass for a snapshot of `size` (y up), in its
    /// appearance, at rest. No pills: none.
    func configure(pills: [PanelGenieView.GlassPill], in size: CGSize, dark: Bool) {
        snapshotSize = size
        colorScheme = dark ? .dark : .light
        restOutlines = pills.map { pill in
            let outline = pill.path()
            return pill.clip.contains(pill.rect) ? outline : outline.intersection(CGPath(rect: pill.clip, transform: nil))
        }
        outlines = restOutlines.map { PanelGenieOutline.sample($0, in: size) }
        showsRestShapes = true
        guard !pills.isEmpty else {
            shapes = []
            host?.rootView = PanelGenieControlGlassShapes(shapes: [], colorScheme: colorScheme)
            isHidden = true
            return
        }
        if host == nil {
            let made = NSHostingView(rootView: PanelGenieControlGlassShapes(shapes: [], colorScheme: colorScheme))
            made.sizingOptions = []
            made.autoresizingMask = [.width, .height]
            addSubview(made)
            host = made
        }
        // Its own appearance, not the window's: a reveal lays it out while
        // the panel is still off screen.
        host?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if host?.frame != bounds { host?.frame = bounds }
        show(restShapes())
    }

    /// The glass at `uniforms`, in the mesh frame's transaction.
    func update(_ uniforms: PanelGenieRenderer.Uniforms, isShown: Bool) {
        isHidden = !isShown || outlines.isEmpty
        guard !isHidden else { return }
        if uniforms.curve == 0, uniforms.slide == 0 {
            // At rest the controls' own shapes, exactly.
            if !showsRestShapes { show(restShapes()); showsRestShapes = true }
        } else {
            showsRestShapes = false
            let width = bounds.width, height = bounds.height
            show(outlines.map { subpaths in
                var path = Path()
                for subpath in subpaths {
                    path.addLines(subpath.map {
                        let p = PanelGenieRenderer.meshPosition($0, uniforms)
                        return CGPoint(x: CGFloat(p.x) * width, y: height - CGFloat(p.y) * height)
                    })
                    path.closeSubpath()
                }
                return path
            })
        }
        // The mesh fades its last sliver; the glass fades with it.
        layer?.opacity = uniforms.alpha
    }

    /// The outlines at rest in this view's coordinates (y down).
    private func restShapes() -> [Path] {
        guard snapshotSize.width > 0, snapshotSize.height > 0 else { return [] }
        let transform = CGAffineTransform(a: bounds.width / snapshotSize.width, b: 0, c: 0,
                                          d: -bounds.height / snapshotSize.height, tx: 0, ty: bounds.height)
        return restOutlines.map { Path($0).applying(transform) }
    }

    private func show(_ made: [Path]) {
        shapes = made
        guard let host else { return }
        host.rootView = PanelGenieControlGlassShapes(shapes: made, colorScheme: colorScheme)
        host.layoutSubtreeIfNeeded()
    }
}

/// What a Genie snapshot stands on: the panel's own material, kept live
/// under it (nil on Solid, which transmits nothing).
struct PanelGenieSurface: Equatable {
    var live: PanelGenieLiveMaterial?
    /// Glass or Frosted (part of a prepared snapshot's key).
    var translucent: Bool
}
