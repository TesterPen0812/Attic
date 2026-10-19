import AppKit
import Metal
import QuartzCore
import SwiftUI

// Experimental (branch `phase-x/genie`, never merged into int13): two drafts
// of a hide/reveal motion for the owner to compare with today's Slide.
//
// - Genie: a snapshot of the panel drawn through a Metal vertex grid bent
//   along a Genie curve into the panel's own corner (the reveal runs it
//   backwards). Glass's live backdrop cannot be snapshotted without Screen
//   Recording, so in flight it is imitated with the surface's measured
//   mid-grey render under the snapshot.
// - Swoop: the live panel (real glass) on a curved path into the corner,
//   narrowing and stretching toward it, with layer transforms only.

/// Settings › Behaviour › Hide animation (this branch only).
enum PanelHideAnimation: String, CaseIterable, Identifiable, Sendable {
    case slide
    case genie
    case swoop

    static let defaultValue: PanelHideAnimation = .slide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slide: String(localized: "Slide")
        case .genie: String(localized: "Genie")
        case .swoop: String(localized: "Swoop")
        }
    }
}

/// Every tunable number of the two drafts in one place.
enum PanelHideMotionTuning {
    // Durations match Slide (`requestHide` 0.22 s, `animateShow` 0.24 s).
    static let hideDuration: TimeInterval = 0.22
    static let showDuration: TimeInterval = 0.24
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
    /// The snapshot's pixels per point (2 is the display's own; the
    /// snapshot's cost follows its pixel count).
    static var genieSnapshotScale: CGFloat = {
        ProcessInfo.processInfo.environment["ATTIC_GENIE_SNAPSHOT_SCALE"].flatMap(Double.init).map { CGFloat($0) } ?? 1
    }()

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

/// A timed run from one progress to another (0 = shown, 1 = hidden).
struct PanelHideMotionRun {
    let from: Double
    let to: Double
    let start: CFTimeInterval
    let duration: CFTimeInterval
    let timing: UnitBezier

    func progress(at time: CFTimeInterval) -> Double {
        guard duration > 0 else { return to }
        return from + (to - from) * timing.value(at: (time - start) / duration)
    }

    func isFinished(at time: CFTimeInterval) -> Bool { time - start >= duration }
}

enum PanelSwoopGeometry {
    /// The live panel's layer transform at `progress`. `visibleBounds` is
    /// the visible surface in the layer's bounds coordinates.
    static func transform(
        progress: Double, visibleBounds: CGRect, layerAnchor: CGPoint, corner: ScreenCorner
    ) -> CATransform3D {
        let p = min(1, max(0, progress))
        guard p > 0 else { return CATransform3DIdentity }
        typealias T = PanelHideMotionTuning
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topRight || corner == .topLeft
        let cornerPoint = CGPoint(x: right ? visibleBounds.maxX : visibleBounds.minX,
                                  y: top ? visibleBounds.maxY : visibleBounds.minY)
        // The line from the panel's centre to its corner, and its normal
        // turned inward (away from the screen edge, so the window's margin
        // never clips the curve).
        let angle = atan2(cornerPoint.y - visibleBounds.midY, cornerPoint.x - visibleBounds.midX)
        let inward: CGFloat = right == top ? 1 : -1
        let normal = CGPoint(x: -sin(angle) * inward, y: cos(angle) * inward)
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
        world = CATransform3DConcat(world, CATransform3DMakeTranslation(
            cornerPoint.x + normal.x * bow, cornerPoint.y + normal.y * bow, 0))
        // A layer transforms about its anchor point.
        var layer = CATransform3DMakeTranslation(layerAnchor.x, layerAnchor.y, 0)
        layer = CATransform3DConcat(layer, world)
        return CATransform3DConcat(layer, CATransform3DMakeTranslation(-layerAnchor.x, -layerAnchor.y, 0))
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

/// Draws the panel's snapshot through the Genie grid. It sits over the live
/// presentation inside the panel's own window (no extra windows) and never
/// takes a click: the live panel under it keeps its input.
final class PanelGenieView: NSView {
    private let metalLayer = CAMetalLayer()
    private var texture: MTLTexture?
    private var displayLink: CADisplayLink?
    private var run: PanelHideMotionRun?
    private var corner: ScreenCorner = .topRight
    private var onFrame: ((Double) -> Void)?
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

    var hasSnapshot: Bool { texture != nil }
    var isAnimating: Bool { run != nil }
    /// Where the motion is now, read between display frames.
    var currentProgress: Double { run?.progress(at: CACurrentMediaTime()) ?? progress }

    /// Takes the snapshot the grid draws. Glass and Frosted transmit a live
    /// backdrop a snapshot cannot hold, so `underlay` is laid in the visible
    /// squircle first (the surface's own render of a mid-grey desktop).
    /// The last snapshot's cost (cache, composite, upload), for the bench.
    static var lastSnapshotMilliseconds: [String: Double] = [:]

    func captureSnapshot(of view: NSView, surfaceRect: CGRect, cornerRadius: CGFloat, underlay: NSColor?, dark: Bool) {
        let began = CACurrentMediaTime()
        defer { Self.lastSnapshotMilliseconds["total"] = (CACurrentMediaTime() - began) * 1000 }
        texture = nil
        guard let device = PanelGenieRenderer.shared.device, let root = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int((view.bounds.width * scale).rounded()), height = Int((view.bounds.height * scale).rounded())
        let space = view.window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // Glass's layers (backdrop and SDF rim) cannot render outside the
        // window server; hide them for the snapshot only (same transaction,
        // so the screen never sees it) and stand in for the small ones.
        var hidden: [CALayer] = []
        var groups: [CGRect] = []
        var elements: [CGRect] = []
        func walk(_ layer: CALayer) {
            let name = String(describing: type(of: layer))
            if name == "CASDFElementLayer" { elements.append(root.convert(layer.bounds, from: layer)) }
            if Self.glassLayerNames.contains(name), !layer.isHidden {
                hidden.append(layer)
                if name == "CASDFLayer" { groups.append(root.convert(layer.bounds, from: layer)) }
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(root)
        // A glass group merges its controls into one shape; stand in for
        // each control, not the group. The panel's own surface needs none.
        var glassPills: [CGRect] = []
        for group in groups where group.width < surfaceRect.width - 1 || group.height < surfaceRect.height - 1 {
            let inside = elements.filter { group.insetBy(dx: -1, dy: -1).contains($0) && $0.width < group.width - 1 }
            glassPills += inside.isEmpty ? [group] : inside
        }
        context.scaleBy(x: scale, y: scale)
        if let underlay {
            // The panel's own squircle (AtticPanelSurface).
            let path = Squircle(cornerRadius: cornerRadius, exponent: AtticStyle.panelSquircleExponent)
                .path(in: surfaceRect.insetBy(dx: 0.5, dy: 0.5)).cgPath
            context.addPath(path)
            context.setFillColor(underlay.cgColor)
            context.fillPath()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hidden.forEach { $0.isHidden = true }
        let renderBegan = CACurrentMediaTime()
        // `cacheDisplay` redraws every view (Core Animation's `render(in:)`
        // costs the same and loses SwiftUI's text); its cost follows the
        // pixel count, so the snapshot is taken at `snapshotScale` and the
        // grid's linear sampling scales it up in flight.
        let snapshotScale = PanelHideMotionTuning.genieSnapshotScale
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * snapshotScale),
            pixelsHigh: Int(view.bounds.height * snapshotScale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) {
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            if let image = rep.cgImage {
                context.interpolationQuality = .high
                context.draw(image, in: view.bounds)
            }
        }
        // The controls' own glass: a faint pill over each (a flat snapshot
        // has no layer between a control's surface and its glyph).
        context.setFillColor(underlay == nil && !dark
            ? NSColor(white: 0, alpha: 0.05).cgColor
            : NSColor(white: 1, alpha: dark ? 0.07 : 0.22).cgColor)
        for rect in glassPills where rect.width > 4 && rect.height > 4 {
            let radius = min(rect.width, rect.height) / 2
            context.addPath(Path(roundedRect: rect, cornerRadius: radius, style: .continuous).cgPath)
            context.fillPath()
        }
        Self.lastSnapshotMilliseconds["render"] = (CACurrentMediaTime() - renderBegan) * 1000
        hidden.forEach { $0.isHidden = false }
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

    private static let glassLayerNames: Set<String> = [
        // Only the material itself: `SDFLayer` and `SDFPortalLayer` also
        // hold the controls' glyphs.
        "CABackdropLayer", "CASDFLayer", "CASDFElementLayer"
    ]

    /// Draws `progress` now, in the current Core Animation transaction.
    func show(progress: Double, corner: ScreenCorner) {
        self.corner = corner
        self.progress = progress
        isHidden = false
        render()
    }

    func animate(
        to target: Double, duration: TimeInterval, timing: UnitBezier, corner: ScreenCorner,
        completion: @escaping () -> Void
    ) {
        stop()
        self.corner = corner
        self.completion = completion
        run = PanelHideMotionRun(from: progress, to: target, start: CACurrentMediaTime(),
                                 duration: duration, timing: timing)
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Freezes where it is (an interruption reverses from here).
    func stop() {
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
        if run.isFinished(at: link.targetTimestamp) {
            progress = run.to
            let done = completion
            displayLink?.invalidate()
            displayLink = nil
            self.run = nil
            completion = nil
            done?()
        }
    }

    private func render() {
        let pixelSize = CGSize(width: bounds.width * (window?.backingScaleFactor ?? 2),
                               height: bounds.height * (window?.backingScaleFactor ?? 2))
        if metalLayer.drawableSize != pixelSize { metalLayer.drawableSize = pixelSize }
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
        if let texture, let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            var uniforms = PanelGenieRenderer.uniforms(progress: progress, corner: corner)
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
        buffer.commit()
        buffer.waitUntilScheduled()
        drawable.present()
    }
}
