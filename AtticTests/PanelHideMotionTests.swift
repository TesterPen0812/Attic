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

    func testDurationsMatchSlide() {
        XCTAssertEqual(PanelHideMotionTuning.hideDuration, 0.22)
        XCTAssertEqual(PanelHideMotionTuning.showDuration, 0.24)
        XCTAssertEqual(PanelHideAnimation.defaultValue, .slide)
    }

    func testSwoopIsIdentityShownAndEndsInEachCorner() {
        let visible = CGRect(x: 28, y: 28, width: 320, height: 464)
        let anchor = CGPoint.zero
        XCTAssertTrue(CATransform3DIsIdentity(PanelSwoopGeometry.transform(
            progress: 0, visibleBounds: visible, layerAnchor: anchor, corner: .topRight)))
        for corner in ScreenCorner.allCases {
            let end = PanelSwoopGeometry.transform(progress: 1, visibleBounds: visible, layerAnchor: anchor, corner: corner)
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

    func testLiveGlassIsAFourthOption() {
        XCTAssertEqual(PanelHideAnimation.allCases, [.slide, .genie, .swoop, .genieLiveGlass])
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
