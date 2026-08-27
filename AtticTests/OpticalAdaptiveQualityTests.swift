import Foundation
import XCTest
@testable import Attic

final class OpticalAdaptiveQualityTests: XCTestCase {
    func testHiddenPanelAlwaysResolvesToOff() {
        var controller = OpticalAdaptiveQualityController(initialEffectivePreset: .maximum)

        let result = controller.evaluate(
            inputs: inputs(isVisible: false),
            now: 100
        )

        XCTAssertEqual(result, .off)
    }

    func testLowPowerAndSeriousThermalPressureDegradeImmediatelyToLow() {
        var lowPowerController = OpticalAdaptiveQualityController(initialEffectivePreset: .maximum)
        XCTAssertEqual(
            lowPowerController.evaluate(
                inputs: inputs(isLowPowerModeEnabled: true),
                now: 10
            ),
            .low
        )

        var thermalController = OpticalAdaptiveQualityController(initialEffectivePreset: .maximum)
        XCTAssertEqual(
            thermalController.evaluate(
                inputs: inputs(thermalState: .serious),
                now: 10
            ),
            .low
        )
    }

    func testBatteryAndHighScaleCapInitialQuality() {
        var batteryController = OpticalAdaptiveQualityController(initialEffectivePreset: .balanced)
        XCTAssertEqual(
            batteryController.evaluate(
                inputs: inputs(isOnBatteryPower: true),
                now: 0
            ),
            .balanced
        )

        var highScaleController = OpticalAdaptiveQualityController(initialEffectivePreset: .maximum)
        XCTAssertEqual(
            highScaleController.evaluate(
                inputs: inputs(displayScale: 3.25),
                now: 0
            ),
            .low
        )

        var retinaController = OpticalAdaptiveQualityController(initialEffectivePreset: .maximum)
        XCTAssertEqual(
            retinaController.evaluate(
                inputs: inputs(displayScale: 2.5),
                now: 0
            ),
            .balanced
        )
    }

    func testHealthyACEnvironmentCanUseMaximum() {
        var controller = OpticalAdaptiveQualityController(initialEffectivePreset: .balanced)

        XCTAssertEqual(
            controller.evaluate(inputs: inputs(), now: 0),
            .maximum
        )
    }

    func testThreeConsecutiveUnhealthyWindowsAreRequiredForPerformanceDegrade() {
        var controller = OpticalAdaptiveQualityController(initialEffectivePreset: .maximum)
        let unhealthy = inputs(performance: .unhealthyFixture)

        XCTAssertEqual(controller.evaluate(inputs: unhealthy, now: 1), .maximum)
        XCTAssertEqual(controller.evaluate(inputs: unhealthy, now: 2), .maximum)
        XCTAssertEqual(controller.evaluate(inputs: unhealthy, now: 3), .balanced)
    }

    func testUpgradeRequiresSixHealthyWindowsAndTwentySecondsAfterDowngrade() {
        var controller = OpticalAdaptiveQualityController(initialEffectivePreset: .maximum)
        let unhealthy = inputs(performance: .unhealthyFixture)
        _ = controller.evaluate(inputs: unhealthy, now: 1)
        _ = controller.evaluate(inputs: unhealthy, now: 2)
        XCTAssertEqual(controller.evaluate(inputs: unhealthy, now: 3), .balanced)

        let healthy = inputs(performance: .healthyFixture)
        for time in 4...8 {
            XCTAssertEqual(
                controller.evaluate(inputs: healthy, now: TimeInterval(time)),
                .balanced
            )
        }
        XCTAssertEqual(controller.evaluate(inputs: healthy, now: 9), .balanced)
        XCTAssertEqual(controller.evaluate(inputs: healthy, now: 22.9), .balanced)
        XCTAssertEqual(controller.evaluate(inputs: healthy, now: 23), .maximum)
    }

    func testAdaptiveInputsContainNoWindowFocusSignal() {
        let reflectedLabels = Set(
            Mirror(reflecting: inputs()).children.compactMap(\.label)
        )

        XCTAssertFalse(reflectedLabels.contains("isKeyWindow"))
        XCTAssertFalse(reflectedLabels.contains("isFocused"))
        XCTAssertFalse(reflectedLabels.contains("windowActivity"))
    }

    private func inputs(
        isVisible: Bool = true,
        isLowPowerModeEnabled: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal,
        isOnBatteryPower: Bool = false,
        displayScale: Double = 2,
        performance: OpticalPerformanceSnapshot? = nil
    ) -> OpticalAdaptiveInputs {
        OpticalAdaptiveInputs(
            isPanelVisible: isVisible,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            thermalState: thermalState,
            isOnBatteryPower: isOnBatteryPower,
            displayScale: displayScale,
            performance: performance
        )
    }
}

private extension OpticalPerformanceSnapshot {
    static let healthyFixture = OpticalPerformanceSnapshot(
        capturedFrameCount: 120,
        renderedFrameCount: 120,
        droppedFrameCount: 0,
        incompleteFrameCount: 0,
        meanFrameTimeMilliseconds: 8,
        p95FrameTimeMilliseconds: 11,
        droppedFrameRate: 0,
        meanCaptureLatencyMilliseconds: 12,
        estimatedMemoryBytes: 24_000_000
    )

    static let unhealthyFixture = OpticalPerformanceSnapshot(
        capturedFrameCount: 100,
        renderedFrameCount: 84,
        droppedFrameCount: 16,
        incompleteFrameCount: 4,
        meanFrameTimeMilliseconds: 28,
        p95FrameTimeMilliseconds: 40,
        droppedFrameRate: 0.16,
        meanCaptureLatencyMilliseconds: 130,
        estimatedMemoryBytes: 96_000_000
    )
}
