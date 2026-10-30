import AppKit
import QuartzCore
import SwiftUI
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

    func testEachAnimationOwnsItsDurations() {
        for mode in [PanelHideAnimation.slide, .swoop] {
            XCTAssertEqual(mode.defaultHideDuration, 0.22, "\(mode)")
            XCTAssertEqual(mode.defaultRevealDuration, 0.24, "\(mode)")
        }
        // Owner's lab values (2026-10-29): Genie hides in 0.80 s, reveals in 0.76 s.
        XCTAssertEqual(PanelHideAnimation.genieLiveGlass.defaultHideDuration, 0.80, accuracy: 1e-9)
        XCTAssertEqual(PanelHideAnimation.genieLiveGlass.defaultRevealDuration, 0.76, accuracy: 1e-9)
        XCTAssertEqual(PanelHideAnimation.defaultValue, .slide)
    }

    func testSpeedLabOverridesOneAnimationAndClamps() {
        var lab = PanelHideSpeedLab()
        XCTAssertTrue(lab.isDefault)
        lab.setDuration(0.5, .swoop, hiding: true)
        XCTAssertEqual(lab.duration(.swoop, hiding: true), 0.5, accuracy: 1e-9)
        XCTAssertEqual(lab.duration(.swoop, hiding: false), 0.24, accuracy: 1e-9)
        XCTAssertEqual(lab.duration(.genieLiveGlass, hiding: true), 0.80, accuracy: 1e-9)
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
        XCTAssertEqual(release.hideMotionDuration(.genieLiveGlass, hiding: true), 0.80, accuracy: 1e-9)
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
                              dark: false)
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
        genie.captureSnapshot(of: content, tiers: nil, surfaceRect: surface, cornerRadius: 30, dark: false)
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
        var hovers = 0
        panel.onContentMayChange = { hoverOnly in if hoverOnly { hovers += 1 } else { changes += 1 } }
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
        func has(_ layers: [CALayer], _ test: (CALayer) -> Bool) -> Bool {
            layers.contains { test($0) || has($0.sublayers ?? [], test) }
        }
        let isBlur: (CALayer) -> Bool = { layer in
            (layer.filters ?? []).contains { (($0 as? NSObject)?.value(forKey: "name") as? String) == "variableBlur" }
        }
        // Where the panel draws neither (CI's virtual GPU), there is nothing
        // to tell apart and the snapshot renders whole.
        let root = try XCTUnwrap(rig.host.layer)
        let isControlGlass: (CALayer) -> Bool = { layer in
            String(describing: type(of: layer)) == "CASDFLayer"
                && root.convert(layer.bounds, from: layer).width < rig.host.frame.width - 3
        }
        try XCTSkipUnless(has([root], isBlur) || has([root], isControlGlass),
                          "this Mac draws neither the edges' variable blur nor the controls' Liquid Glass")
        let split = try XCTUnwrap(PanelGenieView.tierSplit(rig.host.layer, surfaceRect: rig.host.frame))
        // SwiftUI's page scroll view (the composer's field has one of its own;
        // the bottom bar's tag bar scrolls too, a control one row tall).
        let isPage: (CALayer) -> Bool = { layer in
            layer.bounds.height > 2 * AtticControlSize.headerControl
                && (layer.delegate.map { String(describing: type(of: $0)).contains("HostingScrollView") } ?? false)
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

    /// Each control's glass in flight has the control's own shape at rest,
    /// read from its glass element: the corner buttons are 32 pt squares at
    /// 13.5 continuous, not circles (owner, 2026-10-21: "why do the controls
    /// become round?"). A group of one control takes that control's shape.
    func testInFlightControlGlassKeepsTheControlsOwnShape() {
        let surface = CGRect(x: 28, y: 28, width: 320, height: 560)
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 376, height: 616)
        var names: [ObjectIdentifier: String] = [:]
        func add(_ name: String, _ frame: CGRect, to parent: CALayer, radius: CGFloat = 0, curve: CALayerCornerCurve = .circular) -> CALayer {
            let made = CALayer()
            made.frame = parent.convert(frame, from: root)
            made.cornerRadius = radius
            made.cornerCurve = curve
            names[ObjectIdentifier(made)] = name
            parent.addSublayer(made)
            return made
        }
        // The corner buttons: one glass group, two 32 pt elements at 13.5 continuous.
        let buttons = add("CASDFLayer", CGRect(x: 44, y: 540, width: 288, height: 32), to: root)
        _ = add("CASDFElementLayer", CGRect(x: 44, y: 540, width: 32, height: 32), to: buttons, radius: 13.5, curve: .continuous)
        _ = add("CASDFElementLayer", CGRect(x: 300, y: 540, width: 32, height: 32), to: buttons, radius: 13.5, curve: .continuous)
        // The add bar: a group of one control, its element the same size.
        let bar = add("CASDFLayer", CGRect(x: 44, y: 44, width: 288, height: 32), to: root)
        _ = add("CASDFElementLayer", CGRect(x: 44, y: 44, width: 288, height: 32), to: bar, radius: 13.5, curve: .continuous)
        let scan = PanelGenieView.scanGlass(in: root, surfaceRect: surface, hidesSurfaceMaterial: false) {
            names[ObjectIdentifier($0)] ?? "CALayer"
        }
        XCTAssertEqual(scan.pills.count, 3)
        for pill in scan.pills {
            XCTAssertEqual(pill.cornerRadius ?? -1, 13.5, accuracy: 0.001, "the at-rest radius, \(pill.rect)")
            XCTAssertTrue(pill.continuous)
            let atRest = Path(roundedRect: pill.rect, cornerRadius: 13.5, style: .continuous).cgPath
            XCTAssertEqual(pill.path(), atRest, "the at-rest outline")
            XCTAssertNotEqual(pill.path(), Path(ellipseIn: pill.rect).cgPath)
        }
    }

    /// The controls' Liquid Glass rides a Genie flight live (owner,
    /// 2026-10-23: a stand-in fill calibrated on one backdrop turned the
    /// grey glass over a dark wallpaper flat white in flight). At rest each
    /// control's glass has its own shape, in the part the panel shows; in
    /// flight its outline is the mesh's; it shows only with the controls'
    /// mesh, and none without controls.
    func testTheControlsGlassRidesTheMeshLive() {
        let size = CGSize(width: 376, height: 616)
        let panel = CGRect(x: 28, y: 28, width: 320, height: 560)
        let view = PanelGenieControlGlassView(frame: CGRect(origin: .zero, size: size))
        let pills = [
            PanelGenieView.GlassPill(rect: CGRect(x: 44, y: 540, width: 32, height: 32), clip: panel, cornerRadius: 13.5),
            PanelGenieView.GlassPill(rect: CGRect(x: 44, y: 44, width: 288, height: 32), clip: panel, cornerRadius: 13.5),
            // Half past the panel's side: only the part the panel shows.
            PanelGenieView.GlassPill(rect: CGRect(x: 332, y: 300, width: 32, height: 32), clip: panel, cornerRadius: 13.5)
        ]
        func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height) }
        func assertAtRest(_ message: String) {
            XCTAssertEqual(view.shapes.count, pills.count, message)
            for (pill, shape) in zip(pills, view.shapes) {
                let expected = flipped(pill.rect.intersection(pill.clip))
                let bounds = shape.boundingRect
                XCTAssertEqual(bounds.minX, expected.minX, accuracy: 0.01, "\(message): \(pill.rect)")
                XCTAssertEqual(bounds.maxX, expected.maxX, accuracy: 0.01, "\(message): \(pill.rect)")
                XCTAssertEqual(bounds.minY, expected.minY, accuracy: 0.01, "\(message): \(pill.rect)")
                XCTAssertEqual(bounds.maxY, expected.maxY, accuracy: 0.01, "\(message): \(pill.rect)")
            }
            // The corner button's own continuous 13.5 corner, not a square's.
            XCTAssertFalse(view.shapes[0].contains(CGPoint(x: 44.5, y: size.height - 571.5)), message)
            XCTAssertTrue(view.shapes[0].contains(CGPoint(x: 60, y: size.height - 556)), message)
        }
        view.configure(pills: pills, in: size, dark: true)
        assertAtRest("configured")
        view.update(PanelGenieRenderer.uniforms(progress: 0, corner: .topRight), isShown: false)
        XCTAssertTrue(view.isHidden, "not without the controls' mesh")
        view.update(PanelGenieRenderer.uniforms(progress: 0, corner: .topRight), isShown: true)
        XCTAssertFalse(view.isHidden)
        assertAtRest("the first frame")

        for progress in [0.2, 0.5, 0.8] {
            let uniforms = PanelGenieRenderer.uniforms(progress: progress, corner: .topRight)
            view.update(uniforms, isShown: true)
            func mapped(_ point: CGPoint) -> CGPoint {
                let p = PanelGenieRenderer.meshPosition(SIMD2(Float(point.x / size.width), Float(point.y / size.height)), uniforms)
                return CGPoint(x: CGFloat(p.x) * size.width, y: size.height - CGFloat(p.y) * size.height)
            }
            func box(_ rect: CGRect, corners: Bool) -> CGRect {
                // The rect's edges, every half point, through the mesh.
                let inset: CGFloat = corners ? 0 : 14
                var points: [CGPoint] = []
                var t = rect.minX + inset
                while t <= rect.maxX - inset { points += [CGPoint(x: t, y: rect.minY), CGPoint(x: t, y: rect.maxY)]; t += 0.5 }
                t = rect.minY + inset
                while t <= rect.maxY - inset { points += [CGPoint(x: rect.minX, y: t), CGPoint(x: rect.maxX, y: t)]; t += 0.5 }
                let moved = points.map(mapped)
                let xs = moved.map(\.x), ys = moved.map(\.y)
                return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            }
            for (pill, shape) in zip(pills, view.shapes) {
                let visible = pill.rect.intersection(pill.clip)
                let bounds = shape.boundingRect
                // Inside the bent square, around the bent edges' straight runs.
                XCTAssertTrue(box(visible, corners: true).insetBy(dx: -0.6, dy: -0.6).contains(bounds), "\(progress) \(pill.rect)")
                XCTAssertTrue(bounds.insetBy(dx: -0.6, dy: -0.6).contains(box(visible, corners: false)), "\(progress) \(pill.rect)")
                // Past the slide's edge the mesh folds a control onto a line.
                if Float(visible.midX / size.width) + uniforms.slide < 0.98 {
                    XCTAssertTrue(shape.contains(mapped(CGPoint(x: visible.midX, y: visible.midY))), "\(progress) \(pill.rect)")
                }
            }
            XCTAssertNotEqual(view.shapes[1].boundingRect, flipped(pills[1].rect), "bent in flight")
        }
        view.update(PanelGenieRenderer.uniforms(progress: 0, corner: .topRight), isShown: true)
        assertAtRest("back at rest")

        view.configure(pills: [], in: size, dark: false)
        view.update(PanelGenieRenderer.uniforms(progress: 0.5, corner: .topRight), isShown: true)
        XCTAssertTrue(view.isHidden, "no controls, no glass")
        XCTAssertTrue(view.shapes.isEmpty)
    }

    /// On a real panel: a Genie flight draws the content and the controls as
    /// two meshes with the controls' live glass between them, one shape per
    /// control, bent with the mesh; the stand-in fill is gone.
    func testOnARealPanelTheControlsGlassRidesBetweenTheMeshes() throws {
        try XCTSkipIf(PanelGenieRenderer.shared.device == nil, "no Metal device")
        PanelGenieRenderer.shared.prewarm()
        let deadline = Date().addingTimeInterval(5)
        while PanelGenieRenderer.shared.state() == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let rig = try PanelRig(attachments: makeTestAttachmentFileStore())
        defer { rig.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        rig.content.layoutSubtreeIfNeeded()
        let root = try XCTUnwrap(rig.content.subviews.first?.layer ?? rig.host.superview?.layer)
        let scan = PanelGenieView.scanGlass(in: root, surfaceRect: rig.host.frame, hidesSurfaceMaterial: false)
        try XCTSkipIf(scan.pills.isEmpty, "this Mac draws no Liquid Glass controls")
        let surface = PanelGenieSurface(live: PanelGenieLiveMaterial(kind: .glass, colorScheme: .dark, cornerRadius: 52),
                                        translucent: true)
        rig.content.setAlternateProgress(.genieLiveGlass, 0, corner: .topRight, surface: surface)
        let genie = rig.content.genieForTesting
        let glass = genie.liveControlGlass
        XCTAssertNotNil(genie.shownFrame)
        XCTAssertNotNil(genie.shownControlsFrame, "the controls have their own mesh")
        XCTAssertFalse(glass.isHidden)
        XCTAssertEqual(glass.shapes.count, scan.pills.count)
        // One glass per control (each glass group has two SDF layers).
        XCTAssertEqual(Set(scan.pills.map { "\($0.rect)" }).count, scan.pills.count, "\(scan.pills.map(\.rect))")
        XCTAssertEqual(genie.subviews.firstIndex(of: glass), 1, "between the content's mesh and the controls'")
        let rest = glass.shapes.map(\.boundingRect)
        // Each control's glass at rest covers the part of it the panel shows.
        let height = genie.bounds.height
        for (pill, bounds) in zip(scan.pills, rest) {
            let shown = pill.rect.intersection(pill.clip)
            XCTAssertEqual(bounds.width, shown.width, accuracy: 0.5, "\(pill.rect) clip \(pill.clip): \(bounds)")
            XCTAssertEqual(bounds.minY, height - shown.maxY, accuracy: 0.5, "\(pill.rect) clip \(pill.clip): \(bounds)")
        }
        rig.content.setAlternateProgress(.genieLiveGlass, 0.4, corner: .topRight, surface: surface)
        XCTAssertNotEqual(glass.shapes.map(\.boundingRect), rest, "bent with the mesh")
        rig.content.clearAlternateMotion()
        XCTAssertTrue(genie.isHidden)
    }

    /// On a real panel: the corner buttons' in-flight glass has the shape
    /// they have at rest. In the panel design (2026-10-27) that is the
    /// design's superellipse corner (`AtticControlOutline`) at
    /// `AtticRadius.header` (13.5 on 27 pt), not a capsule.
    func testThePanelsCornerButtonsKeepTheirRadiusInFlight() throws {
        let rig = try PanelRig(attachments: makeTestAttachmentFileStore())
        defer { rig.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        rig.content.layoutSubtreeIfNeeded()
        let root = try XCTUnwrap(rig.content.subviews.first?.layer ?? rig.host.superview?.layer)
        let scan = PanelGenieView.scanGlass(in: root, surfaceRect: rig.host.frame, hidesSurfaceMaterial: false)
        let corner = scan.pills.filter { abs($0.rect.width - AtticControlSize.headerControl) < 0.5 && abs($0.rect.height - AtticControlSize.headerControl) < 0.5 }
        try XCTSkipIf(scan.pills.isEmpty, "this Mac draws no Liquid Glass controls")
        XCTAssertEqual(corner.count, 4, "the pin, •••, Search and \"+\": \(scan.pills.map(\.rect))")
        for pill in corner {
            XCTAssertEqual(pill.cornerRadius ?? -1, AtticRadius.header, accuracy: 0.3, "\(pill.rect)")
            XCTAssertEqual(pill.exponent ?? -1, AtticControlShape.designExponent, accuracy: 1e-6, "\(pill.rect)")
        }
    }

    /// On a real panel in the panel design: each control's glass rides the
    /// flight on its own, in its own place and shape. The pin and the page
    /// switch share one glass group, and the design's superellipse glass
    /// reports its outline padded past the control: before, the group rode
    /// as one 288 pt capsule across the whole header line.
    func testThePanelDesignsControlsEachRideInTheirOwnShape() throws {
        let rig = try PanelRig(attachments: makeTestAttachmentFileStore())
        defer { rig.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        rig.content.layoutSubtreeIfNeeded()
        let root = try XCTUnwrap(rig.content.subviews.first?.layer ?? rig.host.superview?.layer)
        let surface = rig.host.frame
        let scan = PanelGenieView.scanGlass(in: root, surfaceRect: surface, hidesSurfaceMaterial: false)
        try XCTSkipIf(scan.pills.isEmpty, "this Mac draws no Liquid Glass controls")
        let control = AtticControlSize.headerControl
        let header = scan.pills.filter { $0.rect.midY > surface.midY }.sorted { $0.rect.minX < $1.rect.minX }
        // The top row (Accepted 2026-10-30): Pin, Now · Later · Done, •••, Search.
        XCTAssertEqual(header.map { ($0.rect.width * 2).rounded() / 2 }, [control, TasksTopTabsMetrics.width, control, control],
                       "\(header.map(\.rect))")
        for pill in header { XCTAssertEqual(pill.rect.height, control, accuracy: 0.5, "\(pill.rect)") }
        // The bottom bar's page switch: one glass, 27 tall, a capsule.
        let switchWidth = AtticPageButton<PanelPage>.width(open: false, count: PanelPage.allCases.count)
        let pageSwitch = try XCTUnwrap(scan.pills.first { abs($0.rect.width - switchWidth) < 0.5 && $0.rect.midY < surface.midY },
                                       "\(scan.pills.map(\.rect))")
        XCTAssertEqual(pageSwitch.rect.height, control, accuracy: 0.5)
        XCTAssertEqual(pageSwitch.cornerRadius ?? -1, control / 2, accuracy: 0.5)
        // Every control here has the design's corner, at most a capsule's radius.
        for pill in scan.pills {
            XCTAssertEqual(pill.exponent ?? -1, AtticControlShape.designExponent, accuracy: 1e-6, "\(pill.rect)")
            let radius = try XCTUnwrap(pill.cornerRadius, "\(pill.rect)")
            XCTAssertGreaterThan(radius, 1, "\(pill.rect)")
            XCTAssertLessThanOrEqual(radius, min(pill.rect.width, pill.rect.height) / 2 + 0.01, "\(pill.rect)")
        }
    }

    /// The snapshot's render applies a view's layer mask, the Tasks chip
    /// row's fade among them (owner's panel design, 2026-10-28), in a flipped
    /// view (a scroll view's) as in a plain one: what a mask hides at rest
    /// stays hidden in a flight's first frame.
    func testTheSnapshotAppliesLayerMasks() throws {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 80, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        view.wantsLayer = true
        window.contentView = view
        let base = try XCTUnwrap(view.layer)
        base.backgroundColor = NSColor.blue.cgColor
        // Left: a plain view whose red fill keeps its left half.
        let plain = NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        plain.wantsLayer = true
        view.addSubview(plain)
        let plainFill = try XCTUnwrap(plain.layer)
        plainFill.backgroundColor = NSColor.red.cgColor
        let keepLeft = CALayer()
        keepLeft.frame = CGRect(x: 0, y: 0, width: 20, height: 40)
        keepLeft.backgroundColor = NSColor.black.cgColor
        plainFill.mask = keepLeft
        // Right: a flipped view whose red fill keeps its top half (y down).
        let flipped = Flipped(frame: CGRect(x: 40, y: 0, width: 40, height: 40))
        flipped.wantsLayer = true
        view.addSubview(flipped)
        let flippedFill = try XCTUnwrap(flipped.layer)
        flippedFill.backgroundColor = NSColor.red.cgColor
        let keepTop = CALayer()
        keepTop.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
        keepTop.backgroundColor = NSColor.black.cgColor
        flippedFill.mask = keepTop
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertNotNil(plainFill.superlayer)
        let image = try XCTUnwrap(PanelGenieView.renderTier(of: view, hiding: [], scale: 2))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // (x, y) in points, y up; true where red wins over blue.
        func red(_ x: Int, _ y: Int) -> Bool {
            let row = image.height - 1 - y * 2, offset = row * context.bytesPerRow + x * 2 * 4
            return data[offset] > data[offset + 2]
        }
        XCTAssertTrue(red(5, 20), "kept by the mask")
        XCTAssertFalse(red(35, 20), "the mask hides it: the blue beneath shows")
        XCTAssertTrue(red(60, 35), "kept by the flipped view's mask (its top)")
        XCTAssertFalse(red(60, 5), "hidden by the flipped view's mask (its bottom)")
    }

    /// A snapshot prepared while the panel is idle stays good for as long
    /// as nothing changes (a swipe then starts without one: at finger rest
    /// it froze a swipe that moved within ~80 ms), and goes stale at once
    /// when something may have changed.
    func testAnIdleSnapshotLastsUntilSomethingChanges() throws {
        try XCTSkipIf(PanelGenieRenderer.shared.device == nil, "no Metal device")
        let rig = try PanelRig(attachments: makeTestAttachmentFileStore())
        defer { rig.close() }
        let solid = PanelGenieSurface(live: nil, translucent: false)
        rig.content.prepareAlternateSnapshot(.genieLiveGlass, surface: solid, lifetime: 30)
        RunLoop.current.run(until: Date().addingTimeInterval(PanelHideMotionTuning.geniePreparedLifetime + 0.3))
        XCTAssertTrue(rig.content.hasPreparedSnapshot(.genieLiveGlass, surface: solid), "past the short lifetime")
        // The pointer moving: a swipe may still start from it; a timed hide
        // or reveal takes a fresh one.
        rig.content.noteContentMayChange(hoverOnly: true)
        XCTAssertTrue(rig.content.hasPreparedSnapshot(.genieLiveGlass, surface: solid))
        XCTAssertFalse(rig.content.hasPreparedSnapshot(.genieLiveGlass, surface: solid, hoverFresh: true))
        rig.content.noteContentMayChange()
        XCTAssertFalse(rig.content.hasPreparedSnapshot(.genieLiveGlass, surface: solid))
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
