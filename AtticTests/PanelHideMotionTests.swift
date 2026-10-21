import AppKit
import QuartzCore
import XCTest
@testable import Attic

/// The hide animations (Slide, Swoop, Genie): timing, end states and
/// corners, without a window.
final class PanelHideMotionTests: XCTestCase {
    func testTimingRunsFromStartToEnd() {
        for timing in [PanelHideMotionTuning.hideTiming, PanelHideMotionTuning.showTiming] {
            XCTAssertEqual(timing.value(at: 0), 0, accuracy: 1e-6)
            XCTAssertEqual(timing.value(at: 1), 1, accuracy: 1e-6)
            var last = 0.0
            for step in 1...20 {
                let value = timing.value(at: Double(step) / 20)
                XCTAssertGreaterThanOrEqual(value, last - 1e-9)
                last = value
            }
        }
    }

    func testRunReadsProgressAndReverses() {
        let run = PanelHideMotionRun(from: 0.4, to: 0, start: 10, duration: 0.24, timing: PanelHideMotionTuning.showTiming)
        XCTAssertEqual(run.progress(at: 10), 0.4, accuracy: 1e-9)
        XCTAssertEqual(run.progress(at: 10.24), 0, accuracy: 1e-9)
        XCTAssertTrue(run.isFinished(at: 10.25))
        XCTAssertFalse(run.isFinished(at: 10.1))
    }

    func testEachAnimationOwnsItsDurationsStartingAtSlides() {
        for mode in PanelHideAnimation.allCases {
            XCTAssertEqual(mode.defaultHideDuration, 0.22, "\(mode)")
            XCTAssertEqual(mode.defaultRevealDuration, 0.24, "\(mode)")
        }
        XCTAssertEqual(PanelHideAnimation.defaultValue, .slide)
    }

    func testSpeedLabOverridesOneAnimationAndClamps() {
        var lab = PanelHideSpeedLab()
        XCTAssertTrue(lab.isDefault)
        lab.setDuration(0.5, .swoop, hiding: true)
        XCTAssertEqual(lab.duration(.swoop, hiding: true), 0.5, accuracy: 1e-9)
        XCTAssertEqual(lab.duration(.swoop, hiding: false), 0.24, accuracy: 1e-9)
        XCTAssertEqual(lab.duration(.genieLiveGlass, hiding: true), 0.22, accuracy: 1e-9)
        lab.setDuration(5, .genieLiveGlass, hiding: false)
        XCTAssertEqual(lab.duration(.genieLiveGlass, hiding: false), 0.8, accuracy: 1e-9)
        lab.setDuration(0.01, .slide, hiding: true)
        XCTAssertEqual(lab.duration(.slide, hiding: true), 0.1, accuracy: 1e-9)
        // Back at the default, the override is dropped.
        for mode in PanelHideAnimation.allCases {
            lab.setDuration(mode.defaultHideDuration, mode, hiding: true)
            lab.setDuration(mode.defaultRevealDuration, mode, hiding: false)
        }
        XCTAssertTrue(lab.isDefault)
    }

    @MainActor
    func testSpeedLabIsPreviewOnly() {
        let suite = "PanelHideMotionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preview = AppSettings(defaults: defaults, motionLabAvailable: true)
        preview.hideSpeedLab.setDuration(0.6, .genieLiveGlass, hiding: true)
        XCTAssertEqual(AppSettings(defaults: defaults, motionLabAvailable: true)
            .hideMotionDuration(.genieLiveGlass, hiding: true), 0.6, accuracy: 1e-9)
        // The release identity never reads (or keeps) the lab's values.
        let release = AppSettings(defaults: defaults, motionLabAvailable: false)
        XCTAssertEqual(release.hideMotionDuration(.genieLiveGlass, hiding: true), 0.22, accuracy: 1e-9)
        release.hideSpeedLab.setDuration(0.7, .slide, hiding: false)
        XCTAssertTrue(release.hideSpeedLab.isDefault)
        XCTAssertEqual(release.hideMotionDuration(.slide, hiding: false), 0.24, accuracy: 1e-9)
    }

    /// Owner report (2026-10-19): Swoop cut off on a straight line mid-
    /// flight. Every animation, at every progress a hide, reveal or swipe
    /// reaches, in every corner and at small to Extra Large sizes, draws the
    /// panel's whole layer (surface and shadow margin) inside the window.
    func testEveryAnimationStaysInsideItsWindow() {
        let margin = AtticStyle.panelElevationMargin
        let sizes = [CGSize(width: 280, height: 360), CGSize(width: 320, height: 560),
                     CGSize(width: 380, height: 700), CGSize(width: 380, height: 900), CGSize(width: 600, height: 420)]
        let columns = PanelHideMotionTuning.genieColumns, rows = PanelHideMotionTuning.genieRows
        let tolerance: CGFloat = 0.5
        for size in sizes {
            let visible = CGRect(x: margin, y: margin, width: size.width, height: size.height)
            let host = visible.insetBy(dx: -margin, dy: -margin)
            let hostCorners = [CGPoint(x: host.minX, y: host.minY), CGPoint(x: host.maxX, y: host.minY),
                               CGPoint(x: host.minX, y: host.maxY), CGPoint(x: host.maxX, y: host.maxY)]
            for corner in ScreenCorner.allCases {
                for step in 0...100 {
                    let progress = Double(step) / 100
                    let label = "\(size) \(corner) p=\(progress)"
                    // Slide: the live layer, scaled about its corner.
                    let anchor = CGPoint(x: host.midX, y: host.midY)
                    let slide = PanelCollapseGeometry.transform(
                        progress: progress, visibleBounds: visible, layerBounds: host,
                        corner: corner, layerAnchor: anchor)
                    for point in hostCorners {
                        let local = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y).applying(slide)
                        assertInside(CGPoint(x: local.x + anchor.x, y: local.y + anchor.y), host, tolerance, "Slide \(label)")
                    }
                    // Swoop: the live layer under its 3D transform.
                    let swoop = PanelSwoopGeometry.transform(
                        progress: progress, visibleBounds: visible, hostBounds: host,
                        layerAnchor: .zero, corner: corner)
                    for point in hostCorners {
                        assertInside(project(point, swoop), host, tolerance, "Swoop \(label)")
                    }
                    // Nor past its resting edge toward the menu bar (or the
                    // Dock): the panel window sits under the menu bar.
                    let top = corner == .topRight || corner == .topLeft
                    for point in [CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX, y: visible.minY),
                                  CGPoint(x: visible.minX, y: visible.maxY), CGPoint(x: visible.maxX, y: visible.maxY)] {
                        let drawn = project(point, swoop)
                        if top {
                            XCTAssertLessThanOrEqual(drawn.y, visible.maxY + tolerance, "Swoop toward the menu bar \(label)")
                        } else {
                            XCTAssertGreaterThanOrEqual(drawn.y, visible.minY - tolerance, "Swoop toward the Dock \(label)")
                        }
                    }
                    // Both Genies: the mesh (and the live glass's outline,
                    // which follows it) in the window-sized Metal view.
                    let uniforms = PanelGenieRenderer.uniforms(progress: progress, corner: corner)
                    for row in 0...rows {
                        for column in 0...columns where row == 0 || row == rows || column == 0 || column == columns {
                            let p = PanelGenieRenderer.position(Float(column) / Float(columns), Float(row) / Float(rows), uniforms)
                            let drawn = CGPoint(x: host.minX + CGFloat(p.x) * host.width,
                                                y: host.minY + CGFloat(p.y) * host.height)
                            assertInside(drawn, host, tolerance, "Genie \(label)")
                        }
                    }
                }
            }
        }
    }

    func testSwoopKeepsItsShapeWhereItAlreadyFits() {
        // The fit only acts where the motion would leave the window: at rest
        // and near the corner the transform is the designed one.
        let visible = CGRect(x: 28, y: 28, width: 320, height: 560)
        let host = visible.insetBy(dx: -28, dy: -28)
        for corner in ScreenCorner.allCases {
            for progress in [0.0, 0.7, 0.9, 1.0] {
                let designed = PanelSwoopGeometry.worldTransform(progress: progress, visibleBounds: visible, corner: corner)
                let fitted = PanelSwoopGeometry.transform(progress: progress, visibleBounds: visible, hostBounds: host,
                                                          layerAnchor: .zero, corner: corner)
                XCTAssertTrue(CATransform3DEqualToTransform(designed, fitted), "\(corner) p=\(progress)")
            }
        }
    }

    /// Owner report (2026-10-19): a bright white bar behind "Add a task" in
    /// flight. The token field's clip view drew the control background.
    @MainActor
    func testTokenFieldDrawsNoBackgroundBehindItsText() {
        let field = AtticTokenFieldView()
        var views: [NSView] = [field]
        var clips: [NSClipView] = []
        while let view = views.popLast() {
            if let clip = view as? NSClipView { clips.append(clip) }
            views += view.subviews
        }
        XCTAssertFalse(clips.isEmpty)
        for clip in clips { XCTAssertFalse(clip.drawsBackground) }
    }

    private func assertInside(_ point: CGPoint, _ host: CGRect, _ tolerance: CGFloat, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let inside = point.x >= host.minX - tolerance && point.x <= host.maxX + tolerance
            && point.y >= host.minY - tolerance && point.y <= host.maxY + tolerance
        if !inside {
            XCTFail("\(label): drawn at (\(Int(point.x)), \(Int(point.y))) outside \(host)", file: file, line: line)
        }
    }

    func testSwoopIsIdentityShownAndEndsInEachCorner() {
        let visible = CGRect(x: 28, y: 28, width: 320, height: 464)
        let anchor = CGPoint.zero
        XCTAssertTrue(CATransform3DIsIdentity(PanelSwoopGeometry.transform(
            progress: 0, visibleBounds: visible, hostBounds: visible.insetBy(dx: -28, dy: -28),
            layerAnchor: anchor, corner: .topRight)))
        for corner in ScreenCorner.allCases {
            let end = PanelSwoopGeometry.transform(progress: 1, visibleBounds: visible,
                                                  hostBounds: visible.insetBy(dx: -28, dy: -28),
                                                  layerAnchor: anchor, corner: corner)
            let centre = CGPoint(x: visible.midX, y: visible.midY)
            let projected = project(centre, end)
            let right = corner == .topRight || corner == .bottomRight
            let top = corner == .topRight || corner == .topLeft
            let target = CGPoint(x: right ? visible.maxX : visible.minX, y: top ? visible.maxY : visible.minY)
            XCTAssertEqual(projected.x, target.x, accuracy: 12, "\(corner)")
            XCTAssertEqual(projected.y, target.y, accuracy: 12, "\(corner)")
        }
        XCTAssertEqual(PanelSwoopGeometry.opacity(progress: 1), 0, accuracy: 1e-6)
        XCTAssertEqual(PanelSwoopGeometry.opacity(progress: 0), 1, accuracy: 1e-6)
    }

    func testGenieUniformsAtEnds() {
        let shown = PanelGenieRenderer.uniforms(progress: 0, corner: .bottomLeft)
        XCTAssertEqual(shown.curve, 0)
        XCTAssertEqual(shown.slide, 0)
        XCTAssertEqual(shown.alpha, 1)
        XCTAssertEqual(shown.right, 0)
        XCTAssertEqual(shown.top, 0)
        let hidden = PanelGenieRenderer.uniforms(progress: 1, corner: .topRight)
        XCTAssertEqual(hidden.curve, 1)
        XCTAssertEqual(hidden.slide, 1)
        XCTAssertEqual(hidden.alpha, 0)
        XCTAssertEqual(hidden.right, 1)
        XCTAssertEqual(hidden.top, 1)
    }

    @MainActor
    func testHideAnimationSettingPersists() {
        let suite = "PanelHideMotionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppSettings(defaults: defaults).hideAnimation, .slide)
        AppSettings(defaults: defaults).hideAnimation = .swoop
        XCTAssertEqual(AppSettings(defaults: defaults).hideAnimation, .swoop)
        defaults.set("bogus", forKey: "panelHideAnimation")
        XCTAssertEqual(AppSettings(defaults: defaults).hideAnimation, .slide)
    }

    func testSwipeSpringStartsWithTheFingersAndSettles() {
        // A release to close: from the fingers' progress and speed into 1.
        let close = PanelHideMotionRun(from: 0.35, to: 1, start: 5,
                                       spring: PanelHideMotionTuning.swipeCloseSpring, velocity: 3)
        XCTAssertEqual(close.progress(at: 5), 0.35, accuracy: 1e-9)
        XCTAssertGreaterThan(close.progress(at: 5 + 1.0 / 120), 0.35)
        XCTAssertLessThan(close.duration, 0.6)
        XCTAssertEqual(close.progress(at: 5 + close.duration), 1, accuracy: 1e-9)
        // Critically damped: never past the corner on the way.
        for step in 0...60 {
            XCTAssertLessThanOrEqual(close.progress(at: 5 + close.duration * Double(step) / 60), 1.001)
        }
        // A spring-back with the feel's bounce, starting while moving out.
        let back = PanelHideMotionRun(from: 0.3, to: 0, start: 0,
                                      spring: AtticMotionSpring(response: 0.35, bounce: 0.2), velocity: 1)
        XCTAssertGreaterThan(back.progress(at: 1.0 / 120), 0.3)
        XCTAssertEqual(back.progress(at: back.duration), 0, accuracy: 1e-9)
        XCTAssertTrue(back.isFinished(at: back.duration))
    }

    func testLiveGlassOutlineFollowsTheDrawnMesh() {
        let columns = Float(PanelHideMotionTuning.genieColumns), rows = Float(PanelHideMotionTuning.genieRows)
        for corner in ScreenCorner.allCases {
            // Shown: the outline is the panel's own.
            let shown = PanelGenieRenderer.uniforms(progress: 0, corner: corner)
            let point = SIMD2<Float>(0.137, 0.861)
            let same = PanelGenieRenderer.meshPosition(point, shown)
            XCTAssertEqual(same.x, point.x, accuracy: 1e-5)
            XCTAssertEqual(same.y, point.y, accuracy: 1e-5)
            // In flight: on every grid vertex it is the shader's position,
            // and between them it stays on the drawn triangles' edges.
            for progress in [0.2, 0.5, 0.8] {
                let u = PanelGenieRenderer.uniforms(progress: progress, corner: corner)
                for (i, j) in [(0, 0), (7, 3), (56, 14), (31, 9)] {
                    let g = SIMD2(Float(i) / columns, Float(j) / rows)
                    let mesh = PanelGenieRenderer.meshPosition(g, u)
                    let shader = PanelGenieRenderer.position(g.x, g.y, u)
                    XCTAssertEqual(mesh.x, shader.x, accuracy: 1e-5)
                    XCTAssertEqual(mesh.y, shader.y, accuracy: 1e-5)
                }
                let a = PanelGenieRenderer.position(10 / columns, 4 / rows, u)
                let b = PanelGenieRenderer.position(11 / columns, 4 / rows, u)
                let mid = PanelGenieRenderer.meshPosition(SIMD2(10.5 / columns, 4 / rows), u)
                XCTAssertEqual(mid.x, (a.x + b.x) / 2, accuracy: 1e-5)
                XCTAssertEqual(mid.y, (a.y + b.y) / 2, accuracy: 1e-5)
            }
        }
    }

    /// Draft 5: Genie's snapshot stood in a faint pill for every control's
    /// glass, including glass the panel never shows. The next Tasks page's
    /// search row sits transparent just past the panel's side; under the
    /// mesh's first frames its pill showed at the window's edge.
    func testGlassStandInsOnlyWhereThePanelShowsTheGlass() {
        func layer(_ name: String, _ frame: CGRect, in parent: CALayer, clips: Bool = false) -> CALayer {
            let made = CALayer()
            made.name = name
            made.frame = frame
            made.masksToBounds = clips
            parent.addSublayer(made)
            return made
        }
        // A 380 x 700 panel in its window, with its 28 pt margin, shaped by a
        // zero-sized mask (as the real surface's is), which clips nothing here.
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 436, height: 756)
        let surfaceRect = CGRect(x: 28, y: 28, width: 380, height: 700)
        let surface = layer("surface", surfaceRect, in: root)
        surface.mask = CALayer()
        surface.mask?.frame = CGRect(x: 0, y: 700, width: 0, height: 0)
        // The shown page's search row: one pill per control.
        let row = layer("CASDFLayer", CGRect(x: 10, y: 620, width: 120, height: 24), in: surface)
        _ = layer("CASDFElementLayer", CGRect(x: 0, y: 0, width: 56, height: 24), in: row)
        _ = layer("CASDFElementLayer", CGRect(x: 64, y: 0, width: 56, height: 24), in: row)
        // The next page, transparent, 10 pt past the panel's side (the bug).
        let nextPage = layer("page", CGRect(x: 390, y: 0, width: 380, height: 700), in: surface)
        nextPage.opacity = 0
        let nextRow = layer("CASDFLayer", CGRect(x: 0, y: 619, width: 102, height: 25), in: nextPage)
        _ = layer("CASDFElementLayer", CGRect(x: 0, y: 0, width: 102, height: 25), in: nextRow)
        // A hidden subtree inside the panel shows no glass either.
        let hidden = layer("hidden", CGRect(x: 0, y: 400, width: 380, height: 40), in: surface)
        hidden.isHidden = true
        _ = layer("CASDFLayer", CGRect(x: 10, y: 8, width: 80, height: 24), in: hidden)
        // A clipping ancestor: glass scrolled out of it gets none, and glass
        // half past the panel's side is drawn only up to that side.
        let list = layer("list", CGRect(x: 0, y: 100, width: 380, height: 200), in: surface, clips: true)
        _ = layer("CASDFLayer", CGRect(x: 10, y: 220, width: 80, height: 24), in: list)
        _ = layer("CASDFLayer", CGRect(x: 350, y: 40, width: 60, height: 24), in: list)
        // Opaque glass outside the surface, with nothing clipping it.
        _ = layer("CASDFLayer", CGRect(x: 412, y: 100, width: 20, height: 24), in: root)

        let scan = PanelGenieView.scanGlass(in: root, surfaceRect: surfaceRect, hidesSurfaceMaterial: false,
                                            className: { $0.name ?? "CALayer" })
        XCTAssertEqual(scan.pills.map(\.rect), [
            CGRect(x: 38, y: 648, width: 56, height: 24),
            CGRect(x: 102, y: 648, width: 56, height: 24),
            CGRect(x: 378, y: 168, width: 60, height: 24),
        ])
        for pill in scan.pills {
            XCTAssertTrue(surfaceRect.contains(pill.clip), "stand-in drawn outside the panel: \(pill)")
        }
        XCTAssertEqual(scan.pills.last.map { $0.rect.intersection($0.clip).maxX }, surfaceRect.maxX)
        XCTAssertEqual(scan.leftOut, [
            CGRect(x: 418, y: 647, width: 102, height: 25),
            CGRect(x: 38, y: 436, width: 80, height: 24),
            CGRect(x: 38, y: 348, width: 80, height: 24),
            CGRect(x: 412, y: 100, width: 20, height: 24),
        ])
        // Every glass layer is still hidden for the render, shown or not.
        XCTAssertEqual(scan.hidden.count, 9)
    }

    /// Owner, 2026-10-21: three ship, Slide, Swoop and Genie (the live-glass
    /// one, which keeps its stored raw value).
    func testHideAnimationsAreNamedAndOrderedForSettings() {
        XCTAssertEqual(PanelHideAnimation.allCases.map(\.title), ["Slide", "Swoop", "Genie"])
        XCTAssertEqual(PanelHideAnimation.allCases.map(\.rawValue), ["slide", "swoop", "genieLiveGlass"])
    }

    func testGenieIsTheThirdOptionAndTheOnlyMesh() {
        XCTAssertEqual(PanelHideAnimation.allCases, [.slide, .swoop, .genieLiveGlass])
        XCTAssertTrue(PanelHideAnimation.genieLiveGlass.usesGenieMesh)
        XCTAssertFalse(PanelHideAnimation.swoop.usesGenieMesh)
        XCTAssertFalse(PanelHideAnimation.slide.usesGenieMesh)
    }

    /// Genie Classic was dropped (owner, 2026-10-21): a stored Classic reads
    /// as Genie, never as the default, and is stored as Genie from then on.
    @MainActor
    func testAStoredGenieClassicReadsAsGenie() throws {
        XCTAssertEqual(PanelHideAnimation(storedValue: "genie"), .genieLiveGlass)
        XCTAssertEqual(PanelHideAnimation(storedValue: "genieLiveGlass"), .genieLiveGlass)
        XCTAssertEqual(PanelHideAnimation(storedValue: "swoop"), .swoop)
        XCTAssertNil(PanelHideAnimation(storedValue: "puff"))
        let suite = "HideAnimationMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("genie", forKey: "panelHideAnimation")
        XCTAssertEqual(AppSettings(defaults: defaults).hideAnimation, .genieLiveGlass)
        XCTAssertEqual(defaults.string(forKey: "panelHideAnimation"), "genieLiveGlass")
        XCTAssertEqual(AppSettings(defaults: defaults).hideAnimation, .genieLiveGlass)
    }

    /// Settings' help: one short line for each animation, in order.
    func testEachAnimationHasOneHelpLine() {
        let lines = PanelHideAnimation.settingsHelp.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, PanelHideAnimation.allCases.count)
        for (line, mode) in zip(lines, PanelHideAnimation.allCases) {
            XCTAssertTrue(line.hasPrefix(mode.title + ":"), line)
            XCTAssertLessThan(line.count, 90, "short: \(line)")
        }
        XCTAssertFalse(PanelHideAnimation.settingsHelp.contains("Classic"))
    }

    private func project(_ point: CGPoint, _ t: CATransform3D) -> CGPoint {
        let x = point.x * t.m11 + point.y * t.m21 + t.m41
        let y = point.x * t.m12 + point.y * t.m22 + t.m42
        let w = point.x * t.m14 + point.y * t.m24 + t.m44
        return CGPoint(x: x / w, y: y / w)
    }
}

/// Genie's ship round (g6): the first frame (in step with the take-over,
/// with the controls' glass), the crisp snapshot, snapshots prepared ahead.
@MainActor
final class PanelHideMotionShipTests: XCTestCase {
    // MARK: The first frame

    /// A flight's first frame is drawn, and the live panel steps aside, in
    /// the same call (one Core Animation transaction). Drafts drew into a
    /// CAMetalLayer whose drawable reached the screen a frame or two after
    /// the live panel had stepped aside: an empty, then a glass-only panel
    /// as a hide began (owner, 2026-10-21).
    func testTheFirstFrameAndTheTakeOverLandTogether() throws {
        try XCTSkipIf(PanelGenieRenderer.shared.device == nil, "no Metal device")
        PanelGenieRenderer.shared.prewarm()
        let deadline = Date().addingTimeInterval(5)
        while PanelGenieRenderer.shared.state() == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let size = CGSize(width: 200, height: 300)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        let content = NSView(frame: root.bounds)
        content.wantsLayer = true
        content.addSubview(NSTextField(labelWithString: "Attic"))
        let genie = PanelGenieView(frame: root.bounds)
        root.addSubview(content)
        root.addSubview(genie)
        window.contentView = root
        genie.layoutSubtreeIfNeeded()
        genie.captureSnapshot(of: content, tiers: nil, surfaceRect: root.bounds.insetBy(dx: 20, dy: 20), cornerRadius: 30,
                              translucent: false, dark: false)
        XCTAssertNil(genie.shownFrame)
        var tookOver = false
        genie.beginFlight(progress: 0, corner: .topRight) {
            XCTAssertNotNil(genie.shownFrame, "the frame is there before the live panel steps aside")
            tookOver = true
        }
        XCTAssertTrue(tookOver)
        XCTAssertFalse(genie.isHidden)
    }

    /// The snapshot is taken at the window's backing scale (crisp text in
    /// flight; drafts took it at 1×).
    func testTheSnapshotIsAtBackingScale() throws {
        try XCTSkipIf(PanelGenieRenderer.shared.device == nil, "no Metal device")
        let size = CGSize(width: 200, height: 300)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        let content = NSView(frame: root.bounds)
        content.wantsLayer = true
        content.addSubview(NSTextField(labelWithString: "Attic"))
        let genie = PanelGenieView(frame: root.bounds)
        root.addSubview(content)
        root.addSubview(genie)
        window.contentView = root
        let surface = root.bounds.insetBy(dx: 20, dy: 20)
        genie.captureSnapshot(of: content, tiers: nil, surfaceRect: surface, cornerRadius: 30, translucent: true, dark: false)
        let scale = window.backingScaleFactor
        XCTAssertGreaterThanOrEqual(scale, 1)
        XCTAssertEqual(genie.snapshotPixelSize, CGSize(width: 200 * scale, height: 300 * scale))
    }

    // MARK: Snapshots prepared ahead

    /// Anything that may change what the panel shows marks a prepared
    /// snapshot stale; the swipe's own scroll events and resting fingers do
    /// not.
    func testThePanelReportsWhatMayChangeItsContent() throws {
        let panel = AtticPanel(contentRect: CGRect(x: -5_000, y: -5_000, width: 320, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        panel.trackpadDismissCorner = .topRight
        var changes = 0
        panel.onContentMayChange = { changes += 1 }
        let point = CGPoint(x: 10, y: 10)
        func scroll(dx: Int32 = 0, dy: Int32 = 0, phase: Int64, momentum: Int64 = 0) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                              wheel1: dy, wheel2: dx, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            event.location = point
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        panel.sendEvent(try scroll(phase: 128))
        XCTAssertEqual(changes, 0, "fingers resting change nothing")
        // A swipe toward the docked edge (classic scrolling: negative dx).
        panel.sendEvent(try scroll(phase: 1))
        for _ in 0..<12 { panel.sendEvent(try scroll(dx: -6, phase: 2)) }
        panel.sendEvent(try scroll(phase: 4))
        XCTAssertEqual(changes, 0, "the swipe's own events change nothing")
        // A vertical scroll reaches the content.
        panel.sendEvent(try scroll(dy: 0, phase: 1))
        for _ in 0..<8 { panel.sendEvent(try scroll(dy: -8, phase: 2)) }
        XCTAssertGreaterThan(changes, 0, "scrolling content changes it")
        changes = 0
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: panel.windowNumber, context: nil, characters: "a",
                                                 charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        panel.sendEvent(key)
        XCTAssertEqual(changes, 1, "a key changes it")
    }

    /// A prepared snapshot is used while nothing has changed, and never
    /// after the content, the surface or the panel's size may have.
    func testAPreparedSnapshotIsUsedOnlyWhileNothingHasChanged() throws {
        try XCTSkipIf(PanelGenieRenderer.shared.device == nil, "no Metal device")
        let rig = try PanelRig(attachments: makeTestAttachmentFileStore())
        defer { rig.close() }
        let content = rig.content
        let solid = PanelGenieSurface(live: nil, translucent: false)
        let glass = PanelGenieSurface(live: PanelGenieLiveMaterial(kind: .glass, colorScheme: .light, cornerRadius: 52),
                                      translucent: true)
        XCTAssertFalse(content.hasPreparedSnapshot(.genieLiveGlass, surface: solid))
        content.prepareAlternateSnapshot(.genieLiveGlass, surface: solid)
        XCTAssertTrue(content.hasPreparedSnapshot(.genieLiveGlass, surface: solid))
        XCTAssertFalse(content.hasPreparedSnapshot(.genieLiveGlass, surface: glass), "another surface")
        content.noteContentMayChange()
        XCTAssertFalse(content.hasPreparedSnapshot(.genieLiveGlass, surface: solid), "the content may have changed")

        // Prepared, then a hide: the flight starts from it, without a snapshot of its own.
        content.prepareAlternateSnapshot(.genieLiveGlass, surface: solid)
        var done = false
        content.animateAlternate(.genieLiveGlass, to: 1, corner: .topRight, surface: solid,
                                 curve: .timed(duration: 0.05, timing: PanelHideMotionTuning.hideTiming)) { done = true }
        #if DEBUG
        XCTAssertEqual(PanelHideMotionTrace.snapshotMilliseconds["reused"], 1, "the hide used the prepared snapshot")
        #endif
        XCTAssertFalse(content.hasPreparedSnapshot(.genieLiveGlass, surface: solid), "used once")
        let deadline = Date().addingTimeInterval(2)
        while !done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(done, "the hide finishes (taking over, or after its frames)")
        content.clearAlternateMotion()
    }

    /// The snapshot tells the panel's content from its controls: the pages'
    /// scrolling content renders under them, the edges' variable blurs and
    /// the controls (the composer's field among them) over it. (Rendered
    /// whole, the controls' glass and the blurs were missing and rows showed
    /// through the add bar: owner, 2026-10-21.)
    func testTheSnapshotTellsTheContentFromTheControls() throws {
        let rig = try PanelRig(attachments: makeTestAttachmentFileStore())
        defer { rig.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        rig.content.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(PanelGenieView.tierSplit(rig.host.layer, surfaceRect: rig.host.frame))
        func has(_ layers: [CALayer], _ test: (CALayer) -> Bool) -> Bool {
            layers.contains { test($0) || has($0.sublayers ?? [], test) }
        }
        let isBlur: (CALayer) -> Bool = { layer in
            (layer.filters ?? []).contains { (($0 as? NSObject)?.value(forKey: "name") as? String) == "variableBlur" }
        }
        // SwiftUI's page scroll view (the composer's field has one of its own).
        let isPage: (CALayer) -> Bool = { layer in
            layer.delegate.map { String(describing: type(of: $0)).contains("HostingScrollView") } ?? false
        }
        let isField: (CALayer) -> Bool = { $0.delegate is AtticTokenFieldView }
        // The content's render keeps the pages and leaves the controls out.
        XCTAssertFalse(has(split.aboveContent, isPage), "the content renders under the controls")
        XCTAssertTrue(has(split.aboveContent, isField), "the composer's field is a control")
        // The controls' render keeps the controls and leaves the pages out.
        XCTAssertTrue(has(split.belowControls, isPage))
        XCTAssertFalse(has(split.belowControls, isField))
        if AtticVariableBlur.isAvailable {
            // The blurs are made from the content: neither render draws them.
            XCTAssertTrue(has(split.aboveContent, isBlur))
            XCTAssertTrue(has(split.belowControls, isBlur))
        }
    }

    /// Frosted's material is live under the mesh, so none of it is in the
    /// snapshot: beside its backdrop, the fill composited with a blend mode
    /// and the chameleon layer (a render draws both flat: Frosted read white
    /// and opaque in flight). The surface's own fills stay.
    func testFrostedLeavesItsWholeMaterialOutOfTheSnapshot() {
        let surface = CGRect(x: 28, y: 28, width: 320, height: 560)
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 376, height: 616)
        let host = CALayer()
        host.frame = root.bounds
        root.addSublayer(host)
        var names: [ObjectIdentifier: String] = [:]
        func layer(_ name: String, _ frame: CGRect, filter: String? = nil) -> CALayer {
            let made = CALayer()
            made.frame = frame
            made.compositingFilter = filter
            names[ObjectIdentifier(made)] = name
            host.addSublayer(made)
            return made
        }
        let fill = layer("ColorShapeLayer", surface)
        let backdrop = layer("CABackdropLayer", surface)
        let darken = layer("CALayer", surface, filter: "darkenBlendMode")
        let chameleon = layer("CAChameleonLayer", surface)
        let row = layer("CGDrawingLayer", CGRect(x: 50, y: 300, width: 200, height: 20))
        let scan = PanelGenieView.scanGlass(in: root, surfaceRect: surface, hidesSurfaceMaterial: true) {
            names[ObjectIdentifier($0)] ?? "CALayer"
        }
        let hidden = Set(scan.hidden.map(ObjectIdentifier.init))
        XCTAssertTrue(hidden.contains(ObjectIdentifier(backdrop)))
        XCTAssertTrue(hidden.contains(ObjectIdentifier(darken)), "the blended fill")
        XCTAssertTrue(hidden.contains(ObjectIdentifier(chameleon)))
        XCTAssertFalse(hidden.contains(ObjectIdentifier(fill)), "the surface's own fill stays")
        XCTAssertFalse(hidden.contains(ObjectIdentifier(row)))
        // Glass (no live Frosted): the blended fill is not Frosted's.
        let glass = PanelGenieView.scanGlass(in: root, surfaceRect: surface, hidesSurfaceMaterial: false) {
            names[ObjectIdentifier($0)] ?? "CALayer"
        }
        XCTAssertFalse(Set(glass.hidden.map(ObjectIdentifier.init)).contains(ObjectIdentifier(darken)))
    }

    /// The controls' glass averages only what lies inside the panel: where
    /// the blur reaches past the edge, an opaque (Solid) panel stays opaque
    /// and a translucent one keeps its own translucency.
    func testTheControlsGlassBlurStaysInsideThePanel() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        func image(_ value: UInt8, alpha: UInt8) throws -> CGImage {
            // Two pixels: as blurred near the edge, half the weight is outside.
            let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            let data = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
            for pixel in 0..<2 { for channel in 0..<3 { data[pixel * 4 + channel] = value }; data[pixel * 4 + 3] = alpha }
            return try XCTUnwrap(context.makeImage())
        }
        func alpha(_ image: CGImage?) throws -> UInt8 {
            let image = try XCTUnwrap(image)
            let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
            return try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))[3]
        }
        // Solid: opaque content, blurred to half by the edge, over a half-covered shape.
        let solid = PanelGenieView.normalisedBlur(try image(100, alpha: 128), over: try image(128, alpha: 128), space: space)
        XCTAssertEqual(Int(try alpha(solid)), 255, accuracy: 2)
        // Glass: 30% content, blurred to 15% by the edge: 30% again.
        let glass = PanelGenieView.normalisedBlur(try image(30, alpha: 38), over: try image(128, alpha: 128), space: space)
        XCTAssertEqual(Int(try alpha(glass)), 76, accuracy: 2)
    }

    /// The hover monitor announces a timed reveal (pointer resting in the
    /// corner) and a timed hide (pointer gone), so Genie can prepare.
    func testTimedRevealsAndHidesAreAnnouncedAhead() throws {
        let rig = try PanelRig(attachments: makeTestAttachmentFileStore(), withController: true)
        defer { rig.close() }
        let monitor = try XCTUnwrap(rig.monitor)
        let settings = rig.settings
        let screen = try XCTUnwrap(NSScreen.main)
        settings.corner = .topRight
        settings.revealDelay = 0.5
        var announced: [(hiding: Bool, delay: TimeInterval)?] = []
        monitor.onVisibilityChangeExpected = { announced.append($0) }
        monitor.start()
        defer { monitor.stop() }
        let corner = CGPoint(x: screen.frame.maxX - 1, y: screen.frame.maxY - 1)
        let away = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        monitor.sampleForTesting(at: corner)
        let reveal = try XCTUnwrap(announced.last ?? nil, "resting in the corner announces a reveal")
        XCTAssertFalse(reveal.hiding)
        XCTAssertEqual(reveal.delay, 0.5, accuracy: 0.1)
        monitor.sampleForTesting(at: away)
        XCTAssertNil(announced.last ?? nil, "leaving the corner calls it off")
    }
}

/// A real panel content container (and, optionally, its controller and the
/// hover monitor) off screen, for the hide-animation tests.
@MainActor
private struct PanelRig {
    let settings: AppSettings
    let content: AtticPanelContentContainer
    let panel: AtticPanel
    let host: AtticPanelHostingView
    let state: PanelUIState
    var monitor: CornerHoverMonitor?
    private let suite: String
    private let defaults: UserDefaults

    init(attachments: AttachmentFileStore, withController: Bool = false) throws {
        suite = "PanelRig.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container, long: true)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: attachments)
        let canvasStore = CanvasStore(container: container)
        let canvasSession = CanvasSession(store: canvasStore)
        let noteDraft = NoteDraftController(noteStore: notes)
        state = PanelUIState()
        let size = CGSize(width: 320, height: 480)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        settings = AppSettings(defaults: defaults)
        host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes, canvasSession: canvasSession,
                                     noteDraft: noteDraft, chromeInteractionState: chrome, uiState: state,
                                     settings: settings, tasksPageState: TasksPageState()),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        content = AtticPanelContentContainer(hostingView: host, visibleSize: size, perimeter: 0)
        panel = AtticPanel(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.orderFront(nil)
        content.layoutSubtreeIfNeeded()
        if withController {
            let uiState = PanelUIState()
            let controller = AtticPanelController(store: store, noteStore: notes, canvasSession: canvasSession,
                                                  noteDraft: noteDraft, settings: settings, uiState: uiState)
            monitor = CornerHoverMonitor(settings: settings, panelController: controller, uiState: uiState,
                                         store: store, noteStore: notes, canvasStore: canvasStore, noteDraft: noteDraft)
        }
    }

    func close() {
        host.cancelActiveInteraction(reason: .lostWindow)
        state.releasePageContent()
        panel.close()
        defaults.removePersistentDomain(forName: suite)
    }
}
