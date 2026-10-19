import AppKit
import QuartzCore
import XCTest
@testable import Attic

/// The experimental hide drafts (phase-x/genie): timing, end states and
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
        XCTAssertEqual(lab.duration(.genie, hiding: true), 0.22, accuracy: 1e-9)
        lab.setDuration(5, .genie, hiding: false)
        XCTAssertEqual(lab.duration(.genie, hiding: false), 0.8, accuracy: 1e-9)
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
        preview.hideSpeedLab.setDuration(0.6, .genie, hiding: true)
        XCTAssertEqual(AppSettings(defaults: defaults, motionLabAvailable: true)
            .hideMotionDuration(.genie, hiding: true), 0.6, accuracy: 1e-9)
        // The release identity never reads (or keeps) the lab's values.
        let release = AppSettings(defaults: defaults, motionLabAvailable: false)
        XCTAssertEqual(release.hideMotionDuration(.genie, hiding: true), 0.22, accuracy: 1e-9)
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

    /// Owner, 2026-10-20: Slide, Swoop, Genie, Genie Classic. The live-glass
    /// Genie takes the plain name; the stored raw values never change.
    func testHideAnimationsAreNamedAndOrderedForSettings() {
        XCTAssertEqual(PanelHideAnimation.allCases.map(\.title), ["Slide", "Swoop", "Genie", "Genie Classic"])
        XCTAssertEqual(PanelHideAnimation.allCases.map(\.rawValue), ["slide", "swoop", "genieLiveGlass", "genie"])
    }

    func testLiveGlassIsAFourthOption() {
        XCTAssertEqual(PanelHideAnimation.allCases, [.slide, .swoop, .genieLiveGlass, .genie])
        XCTAssertTrue(PanelHideAnimation.genieLiveGlass.usesGenieMesh)
        XCTAssertFalse(PanelHideAnimation.swoop.usesGenieMesh)
    }

    private func project(_ point: CGPoint, _ t: CATransform3D) -> CGPoint {
        let x = point.x * t.m11 + point.y * t.m21 + t.m41
        let y = point.x * t.m12 + point.y * t.m22 + t.m42
        let w = point.x * t.m14 + point.y * t.m24 + t.m44
        return CGPoint(x: x / w, y: y / w)
    }
}
