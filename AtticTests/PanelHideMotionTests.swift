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

    private func project(_ point: CGPoint, _ t: CATransform3D) -> CGPoint {
        let x = point.x * t.m11 + point.y * t.m21 + t.m41
        let y = point.x * t.m12 + point.y * t.m22 + t.m42
        let w = point.x * t.m14 + point.y * t.m24 + t.m44
        return CGPoint(x: x / w, y: y / w)
    }
}
