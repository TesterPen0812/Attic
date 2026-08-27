import XCTest
@testable import Attic

final class OpticalWorkloadTests: XCTestCase {
    func testPresetWorkloadsUseDistinctRealResourceBudgets() {
        let off = OpticalWorkloadProfile.workload(for: .off)
        let low = OpticalWorkloadProfile.workload(for: .low)
        let balanced = OpticalWorkloadProfile.workload(for: .balanced)
        let maximum = OpticalWorkloadProfile.workload(for: .maximum)

        XCTAssertEqual(off.captureScale, 0)
        XCTAssertEqual(off.maximumFramesPerSecond, 0)
        XCTAssertEqual(off.queueDepth, 0)
        XCTAssertEqual(off.blurSampleCount, 0)
        XCTAssertEqual(off.edgeEvaluationCount, 0)
        XCTAssertEqual(off.maximumBandPixels, 0)
        XCTAssertEqual(off.maximumDisplacementPixels, 0)
        XCTAssertFalse(off.allowsLiveOptics)

        XCTAssertEqual(low.captureScale, 0.50)
        XCTAssertEqual(low.maximumFramesPerSecond, 15)
        XCTAssertEqual(low.queueDepth, 2)
        XCTAssertEqual(low.blurSampleCount, 5)
        XCTAssertEqual(low.edgeEvaluationCount, 1)
        XCTAssertEqual(low.maximumBandPixels, 28)
        XCTAssertEqual(low.maximumDisplacementPixels, 12)
        XCTAssertTrue(low.allowsLiveOptics)

        XCTAssertEqual(balanced.captureScale, 0.75)
        XCTAssertEqual(balanced.maximumFramesPerSecond, 30)
        XCTAssertEqual(balanced.queueDepth, 3)
        XCTAssertEqual(balanced.blurSampleCount, 9)
        XCTAssertEqual(balanced.edgeEvaluationCount, 3)
        XCTAssertEqual(balanced.maximumBandPixels, 32)
        XCTAssertEqual(balanced.maximumDisplacementPixels, 19)
        XCTAssertTrue(balanced.allowsLiveOptics)

        XCTAssertEqual(maximum.captureScale, 1.0)
        XCTAssertEqual(maximum.maximumFramesPerSecond, 60)
        XCTAssertEqual(maximum.queueDepth, 5)
        XCTAssertEqual(maximum.blurSampleCount, 13)
        XCTAssertEqual(maximum.edgeEvaluationCount, 5)
        XCTAssertEqual(maximum.maximumBandPixels, 36)
        XCTAssertEqual(maximum.maximumDisplacementPixels, 24)
        XCTAssertTrue(maximum.allowsLiveOptics)

        XCTAssertLessThan(low.captureScale, balanced.captureScale)
        XCTAssertLessThan(balanced.captureScale, maximum.captureScale)
        XCTAssertLessThan(low.maximumFramesPerSecond, balanced.maximumFramesPerSecond)
        XCTAssertLessThan(balanced.maximumFramesPerSecond, maximum.maximumFramesPerSecond)
        XCTAssertLessThan(low.blurSampleCount, balanced.blurSampleCount)
        XCTAssertLessThan(balanced.blurSampleCount, maximum.blurSampleCount)
        XCTAssertLessThan(low.edgeEvaluationCount, balanced.edgeEvaluationCount)
        XCTAssertLessThan(balanced.edgeEvaluationCount, maximum.edgeEvaluationCount)
    }

    func testAdaptivePresetUsesBalancedAsItsInitialConcreteWorkload() {
        XCTAssertEqual(
            OpticalWorkloadProfile.workload(for: .adaptive),
            OpticalWorkloadProfile.workload(for: .balanced)
        )
    }

    func testChangingWorkloadDoesNotRewriteIndependentUserControls() {
        let controls = OpticalGlassControls(
            transparency: 17,
            frost: 28,
            refraction: 39,
            edgeShine: 41,
            tint: 52,
            readability: 63,
            interactionResponse: 74
        )

        for preset in [
            OpticalPerformancePreset.low,
            .balanced,
            .maximum
        ] {
            let profile = OpticalGlassProfile.resolve(
                controls: controls,
                workload: OpticalWorkloadProfile.workload(for: preset),
                windowActivity: .key
            )

            XCTAssertEqual(profile.controlSnapshot, controls)
        }
    }

    func testZeroRefractionIsMathematicalIdentityInEveryEnabledWorkload() {
        var controls = OpticalGlassControls.defaults
        controls.refraction = 0

        for preset in [
            OpticalPerformancePreset.low,
            .balanced,
            .maximum
        ] {
            let profile = OpticalGlassProfile.resolve(
                controls: controls,
                workload: OpticalWorkloadProfile.workload(for: preset),
                windowActivity: .key
            )
            XCTAssertEqual(profile.refractionBandPixels, 0)
            XCTAssertEqual(profile.baseDisplacementPixels, 0)
        }
    }

    func testProfilesAreIndependentOfWindowFocusForEveryWorkload() {
        for preset in [
            OpticalPerformancePreset.low,
            .balanced,
            .maximum
        ] {
            let workload = OpticalWorkloadProfile.workload(for: preset)
            let key = OpticalGlassProfile.resolve(
                controls: .defaults,
                workload: workload,
                windowActivity: .key
            )
            let inactive = OpticalGlassProfile.resolve(
                controls: .defaults,
                workload: workload,
                windowActivity: .inactive
            )
            XCTAssertEqual(key, inactive)
        }
    }

    func testMaximumRefractionUsesEachWorkloadsRealEnvelope() {
        var controls = OpticalGlassControls.defaults
        controls.refraction = 100

        let low = OpticalGlassProfile.resolve(
            controls: controls,
            workload: .workload(for: .low),
            windowActivity: .key
        )
        let balanced = OpticalGlassProfile.resolve(
            controls: controls,
            workload: .workload(for: .balanced),
            windowActivity: .key
        )
        let maximum = OpticalGlassProfile.resolve(
            controls: controls,
            workload: .workload(for: .maximum),
            windowActivity: .key
        )

        XCTAssertEqual(low.refractionBandPixels, 28)
        XCTAssertEqual(low.baseDisplacementPixels, 12)
        XCTAssertEqual(balanced.refractionBandPixels, 32)
        XCTAssertEqual(balanced.baseDisplacementPixels, 19)
        XCTAssertEqual(maximum.refractionBandPixels, 36)
        XCTAssertEqual(maximum.baseDisplacementPixels, 24)
    }
}
