import AppKit
import os
import OSLog
import QuartzCore
import SpriteKit

/// Corner-pulled ("genie") sheet presentation for the main panel.
///
/// Rendering: a transient borderless overlay window carries a SpriteKit
/// snapshot of the live panel, warped by `SKWarpGeometryGrid` — a real
/// texture-mapped mesh, so the sheet deforms coherently with filtered
/// sampling and no slice seams. While the session exists the panel's own
/// content subtree is virtualized (hidden but still laid out and still a
/// valid event target), so ordering, key status, screen association and the
/// saved frame never change; the handoff back to live content happens at
/// progress 0 where sprite and live pixels are identical.
///
/// Motion: a `PanelGenieGeometry.MotionRun` advances deterministically from
/// `SKSceneDelegate.update` timestamps — no timers of our own, and reversal
/// continues from the currently applied progress. The overlay exists only
/// for the transition's lifetime; teardown removes it and there is no idle
/// renderer, display link or render loop left behind.
@MainActor
final class PanelGenieSession {
    /// Progress currently applied to the mesh: 0 is the at-rest sheet,
    /// 1 is fully consumed into the anchor point.
    private(set) var progress: CGFloat = 0
    /// True while a timed run is in flight (interactive pulls apply directly).
    private(set) var isMotionActive = false

    private weak var panel: AtticPanel?
    private weak var contentContainer: AtticPanelContentContainer?
    private var overlayWindow: NSWindow?
    private let sprite: SKSpriteNode
    private let baseGrid: SKWarpGeometryGrid
    private let sceneDriver = SceneDriver()
    private var run: PanelGenieGeometry.MotionRun?
    private var runCompletion: (() -> Void)?
    private var terminateObserver: NSObjectProtocol?
    private let spec: PanelGenieGeometry.Spec
    private let size: CGSize
    private let anchor: CGPoint
    private let corner: ScreenCorner
    private let columns: Int
    private let rows: Int
    private let signposter = OSSignposter(
        subsystem: "com.taha.Attic", category: .pointsOfInterest
    )
    private var signpostInterval: OSSignpostIntervalState?
    private var renderedFrames = 0
    private var firstTick: TimeInterval?

    var isPresenting: Bool { overlayWindow != nil }

    private init(
        panel: AtticPanel,
        contentContainer: AtticPanelContentContainer,
        overlayWindow: NSWindow,
        sprite: SKSpriteNode,
        baseGrid: SKWarpGeometryGrid,
        corner: ScreenCorner,
        anchor: CGPoint,
        size: CGSize,
        columns: Int,
        rows: Int,
        spec: PanelGenieGeometry.Spec
    ) {
        self.panel = panel
        self.contentContainer = contentContainer
        self.overlayWindow = overlayWindow
        self.sprite = sprite
        self.baseGrid = baseGrid
        self.corner = corner
        self.anchor = anchor
        self.size = size
        self.columns = columns
        self.rows = rows
        self.spec = spec
    }

    /// Installs the transient presentation: captures the live subtree into a
    /// snapshot at the screen's backing scale, covers the panel plus the
    /// anchor reach with a transparent overlay, and virtualizes the real
    /// content. Returns nil when a snapshot cannot be produced — callers then
    /// use the restrained non-deforming path.
    static func begin(
        panel: AtticPanel,
        contentContainer: AtticPanelContentContainer,
        motionView: NSView,
        screen: NSScreen,
        corner: ScreenCorner,
        initialProgress: CGFloat,
        spec: PanelGenieGeometry.Spec = .standard
    ) -> PanelGenieSession? {
        let size = motionView.bounds.size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              panel.frame.width.isFinite, panel.frame.height.isFinite else {
            return nil
        }
        motionView.layoutSubtreeIfNeeded()
        guard let image = capturePresentation(of: motionView, scale: screen.backingScaleFactor) else {
            return nil
        }

        let workArea = screen.visibleFrame
        guard workArea.isFinite, workArea.width > 0, workArea.height > 0 else { return nil }
        let anchorScreen = PanelGenieGeometry.anchorPoint(in: workArea, corner: corner, spec: spec)
        // Panel-local space == motionView bounds space: both describe the
        // window's content region (visible rect plus the transparent resize
        // perimeter) with (0,0) at the window frame's lower-left.
        let anchor = CGPoint(
            x: anchorScreen.x - panel.frame.minX,
            y: anchorScreen.y - panel.frame.minY
        )
        let overlayFrame = panel.frame.union(CGRect(
            x: anchorScreen.x - 4, y: anchorScreen.y - 4, width: 8, height: 8
        ))
        guard overlayFrame.isFinite, !overlayFrame.isEmpty else { return nil }

        let overlay = NSWindow(
            contentRect: overlayFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.level = .floating
        overlay.collectionBehavior = panel.collectionBehavior
        overlay.animationBehavior = .none
        overlay.isReleasedWhenClosed = false

        let skView = SKView(frame: CGRect(origin: .zero, size: overlayFrame.size))
        skView.allowsTransparency = true
        skView.ignoresSiblingOrder = true
        overlay.contentView = skView

        let scene = SKScene(size: overlayFrame.size)
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear

        let sprite = SKSpriteNode(texture: SKTexture(cgImage: image))
        sprite.texture?.filteringMode = .linear
        sprite.anchorPoint = .zero
        sprite.position = CGPoint(
            x: panel.frame.minX - overlayFrame.minX,
            y: panel.frame.minY - overlayFrame.minY
        )
        sprite.size = size

        let divisions = PanelGenieGeometry.meshDivisions(for: size, spec: spec)
        let source = PanelGenieGeometry.sourcePositions(
            columns: divisions.columns, rows: divisions.rows
        ).map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let destination = PanelGenieGeometry.destinationPositions(
            columns: divisions.columns,
            rows: divisions.rows,
            size: size,
            progress: PanelGenieGeometry.displayProgress(initialProgress, spec: spec),
            corner: corner,
            anchor: anchor,
            spec: spec
        ).map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let grid = SKWarpGeometryGrid(
            columns: divisions.columns,
            rows: divisions.rows,
            sourcePositions: source,
            destinationPositions: destination
        )
        sprite.warpGeometry = grid
        scene.addChild(sprite)
        skView.presentScene(scene)

        let session = PanelGenieSession(
            panel: panel,
            contentContainer: contentContainer,
            overlayWindow: overlay,
            sprite: sprite,
            baseGrid: grid,
            corner: corner,
            anchor: anchor,
            size: size,
            columns: divisions.columns,
            rows: divisions.rows,
            spec: spec
        )
        session.sceneDriver.session = session
        scene.delegate = session.sceneDriver

        contentContainer.setPresentationVirtualized(true)
        contentContainer.allowsContentInteraction = false
        session.progress = min(1, max(0, initialProgress))
        overlay.orderFrontRegardless()

        session.terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak session] _ in
            MainActor.assumeIsolated { session?.teardown() }
        }
        let signpostID = session.signposter.makeSignpostID()
        session.signpostInterval = session.signposter.beginInterval(
            "PanelGeniePresentation", id: signpostID
        )
        return session
    }

    /// Starts a bounded run toward `target` from whatever is on screen now.
    /// A stale completion is discarded without firing — supersession is how
    /// the controller guarantees one active transition.
    func animate(
        to target: CGFloat,
        direction: PanelGenieGeometry.MotionDirection,
        completion: @escaping () -> Void
    ) {
        let target = min(1, max(0, target))
        guard overlayWindow != nil,
              abs(target - progress) > spec.completionEpsilon else {
            run = nil
            runCompletion = nil
            isMotionActive = false
            apply(target)
            completion()
            return
        }
        run = PanelGenieGeometry.planRun(
            from: progress, to: target, direction: direction, spec: spec
        )
        runCompletion = completion
        isMotionActive = true
    }

    /// Interactive (gesture-driven) progress: applied verbatim on the next
    /// rendered frame, ending any timed run without completing it.
    func applyImmediately(_ progress: CGFloat) {
        run = nil
        runCompletion = nil
        isMotionActive = false
        apply(progress)
    }

    /// Stops the in-flight run but keeps the presentation exactly where it
    /// is, so the next transition continues from the visible state.
    func holdMotion() {
        run = nil
        runCompletion = nil
        isMotionActive = false
    }

    /// Jumps the in-flight run to its own target and fires its completion —
    /// the coherent instant end when Reduce Motion turns on mid-transition.
    func finishImmediately() {
        guard let activeRun = run else { return }
        run = nil
        isMotionActive = false
        apply(activeRun.to)
        let completion = runCompletion
        runCompletion = nil
        completion?()
    }

    /// Removes the overlay and hands the surface back to the live subtree.
    /// Idempotent; safe at any progress and from every cancellation path.
    func teardown() {
        run = nil
        runCompletion = nil
        isMotionActive = false
        if let overlayWindow {
            overlayWindow.orderOut(nil)
            self.overlayWindow = nil
        }
        contentContainer?.setPresentationVirtualized(false)
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
        if let signpostInterval {
            let frames = renderedFrames
            let elapsedMs = firstTick.map { (CACurrentMediaTime() - $0) * 1000 }
            signposter.endInterval("PanelGeniePresentation", signpostInterval)
            signpostInterval = nil
            Logger(subsystem: "com.taha.Attic", category: "PanelGenie").debug(
                "Panel genie presentation ended: \(frames) mesh frames over \(elapsedMs ?? -1, privacy: .public) ms"
            )
        }
    }

    deinit {
        // Sessions are only created and released on the main thread and every
        // owner path tears down first — this is only a last-resort release.
        guard let overlay = overlayWindow else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { overlay.orderOut(nil) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { overlay.orderOut(nil) }
            }
        }
    }

    // MARK: - Frame driver

    /// Called once per rendered SpriteKit frame. Progress is a pure function
    /// of the vsync timestamp, so cadence changes cannot corrupt the motion.
    fileprivate func tick(_ now: TimeInterval) {
        guard var activeRun = run else { return }
        if activeRun.startTime == nil { activeRun.startTime = now }
        if firstTick == nil { firstTick = now }
        renderedFrames += 1
        apply(activeRun.progress(at: now))
        guard activeRun.isComplete(at: now) else { return }
        run = nil
        isMotionActive = false
        apply(activeRun.to)
        let completion = runCompletion
        runCompletion = nil
        completion?()
    }

    private func apply(_ progress: CGFloat) {
        let clamped = min(1, max(0, progress))
        self.progress = clamped
        let destination = PanelGenieGeometry.destinationPositions(
            columns: columns,
            rows: rows,
            size: size,
            progress: PanelGenieGeometry.displayProgress(clamped, spec: spec),
            corner: corner,
            anchor: anchor,
            spec: spec
        ).map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        sprite.warpGeometry = baseGrid.gridByReplacingDestPositions(destination)
    }

    /// Forwards SpriteKit's per-frame update into the session. SpriteKit calls
    /// the delegate on the main run loop while the scene is presented.
    private final class SceneDriver: NSObject, SKSceneDelegate {
        weak var session: PanelGenieSession?

        func update(_ currentTime: TimeInterval, for scene: SKScene) {
            MainActor.assumeIsolated {
                session?.tick(currentTime)
            }
        }
    }

    /// Renders the live presentation subtree (which is layer-backed, so the
    /// SwiftUI content is part of the layer hierarchy) into a bitmap at the
    /// display's backing scale. Falls back to `cacheDisplay` if the layer
    /// path is unavailable; never touches window-server or desktop capture.
    private static func capturePresentation(of view: NSView, scale: CGFloat) -> CGImage? {
        let bounds = view.bounds
        let scale = scale.isFinite && scale > 0 ? scale : 2
        if let layer = view.layer {
            let pixelSize = CGSize(
                width: (bounds.width * scale).rounded(.up),
                height: (bounds.height * scale).rounded(.up)
            )
            if let context = CGContext(
                data: nil,
                width: Int(pixelSize.width),
                height: Int(pixelSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                context.scaleBy(x: scale, y: scale)
                layer.render(in: context)
                if let image = context.makeImage() { return image }
            }
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }
}
