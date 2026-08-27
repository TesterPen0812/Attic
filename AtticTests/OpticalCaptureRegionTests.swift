import CoreGraphics
import XCTest
@testable import Attic

final class OpticalCaptureRegionTests: XCTestCase {
    func testMaximumRegionAddsDisplacementBlurSafetyOverscanAndConvertsCoordinates() {
        let region = ScreenCaptureRegionMapper.makeRegion(
            panelFrame: CGRect(x: 1_000, y: 500, width: 332, height: 380),
            displayFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            backingScale: 2,
            workload: .workload(for: .maximum),
            frostRadiusPixels: 8
        )

        XCTAssertEqual(region.overscanPoints, 18, accuracy: 0.001)
        assertRect(
            region.sourceRect,
            equals: CGRect(x: 982, y: 2, width: 368, height: 416)
        )
        assertRect(
            region.panelRectInCapturePoints,
            equals: CGRect(x: 18, y: 18, width: 332, height: 380)
        )
        XCTAssertEqual(region.outputPixelWidth, 736)
        XCTAssertEqual(region.outputPixelHeight, 832)
    }

    func testLowPresetActuallyReducesCaptureDimensionsAndOverscan() {
        let panel = CGRect(x: 1_000, y: 500, width: 332, height: 380)
        let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let low = ScreenCaptureRegionMapper.makeRegion(
            panelFrame: panel,
            displayFrame: display,
            backingScale: 2,
            workload: .workload(for: .low),
            frostRadiusPixels: 8
        )
        let maximum = ScreenCaptureRegionMapper.makeRegion(
            panelFrame: panel,
            displayFrame: display,
            backingScale: 2,
            workload: .workload(for: .maximum),
            frostRadiusPixels: 8
        )

        XCTAssertEqual(low.overscanPoints, 12, accuracy: 0.001)
        XCTAssertEqual(low.outputPixelWidth, 356)
        XCTAssertEqual(low.outputPixelHeight, 404)
        XCTAssertLessThan(low.outputPixelWidth, maximum.outputPixelWidth)
        XCTAssertLessThan(low.outputPixelHeight, maximum.outputPixelHeight)
    }

    func testRegionClampsToDisplayWithoutRectangularOutOfBoundsSampling() {
        let region = ScreenCaptureRegionMapper.makeRegion(
            panelFrame: CGRect(x: 1_100, y: 610, width: 332, height: 280),
            displayFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            backingScale: 2,
            workload: .workload(for: .maximum),
            frostRadiusPixels: 8
        )

        assertRect(
            region.sourceRect,
            equals: CGRect(x: 1_082, y: 0, width: 358, height: 308)
        )
        assertRect(
            region.panelRectInCapturePoints,
            equals: CGRect(x: 18, y: 10, width: 332, height: 280)
        )
        XCTAssertEqual(region.outputPixelWidth, 716)
        XCTAssertEqual(region.outputPixelHeight, 616)
    }

    func testInvalidScaleAndOffWorkloadProduceNoCaptureRegion() {
        XCTAssertNil(
            ScreenCaptureRegionMapper.makeRegionIfPossible(
                panelFrame: CGRect(x: 10, y: 10, width: 332, height: 380),
                displayFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                backingScale: .nan,
                workload: .workload(for: .balanced),
                frostRadiusPixels: 8
            )
        )
        XCTAssertNil(
            ScreenCaptureRegionMapper.makeRegionIfPossible(
                panelFrame: CGRect(x: 10, y: 10, width: 332, height: 380),
                displayFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                backingScale: 2,
                workload: .workload(for: .off),
                frostRadiusPixels: 8
            )
        )
    }

    func testCaptureConfigurationContainsRealWorkloadAndStableFingerprint() {
        let region = ScreenCaptureRegionMapper.makeRegion(
            panelFrame: CGRect(x: 100, y: 100, width: 332, height: 380),
            displayFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            backingScale: 2,
            workload: .workload(for: .low),
            frostRadiusPixels: 8
        )
        let first = OpticalCaptureConfiguration(
            displayID: 42,
            region: region,
            workload: .workload(for: .low),
            generation: 7
        )
        let second = OpticalCaptureConfiguration(
            displayID: 42,
            region: region,
            workload: .workload(for: .low),
            generation: 8
        )

        XCTAssertEqual(first.maximumFramesPerSecond, 15)
        XCTAssertEqual(first.queueDepth, 3)
        XCTAssertEqual(first.screenCaptureQueueDepth, 3)
        XCTAssertEqual(first.outputPixelWidth, region.outputPixelWidth)
        XCTAssertEqual(first.outputPixelHeight, region.outputPixelHeight)
        XCTAssertEqual(first.configurationFingerprint, second.configurationFingerprint)
        XCTAssertNotEqual(first.generation, second.generation)
    }

    func testScreenCaptureQueueDepthIsClampedToPublicContract() {
        let base = OpticalWorkloadProfile.workload(for: .low)
        let region = ScreenCaptureRegionMapper.makeRegion(
            panelFrame: CGRect(x: 100, y: 100, width: 332, height: 380),
            displayFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            backingScale: 2,
            workload: base,
            frostRadiusPixels: 0
        )
        let belowMinimum = OpticalWorkloadProfile(
            captureScale: base.captureScale,
            maximumFramesPerSecond: base.maximumFramesPerSecond,
            queueDepth: 1,
            blurSampleCount: base.blurSampleCount,
            edgeEvaluationCount: base.edgeEvaluationCount,
            maximumBandPixels: base.maximumBandPixels,
            maximumDisplacementPixels: base.maximumDisplacementPixels
        )
        let aboveMaximum = OpticalWorkloadProfile(
            captureScale: base.captureScale,
            maximumFramesPerSecond: base.maximumFramesPerSecond,
            queueDepth: 99,
            blurSampleCount: base.blurSampleCount,
            edgeEvaluationCount: base.edgeEvaluationCount,
            maximumBandPixels: base.maximumBandPixels,
            maximumDisplacementPixels: base.maximumDisplacementPixels
        )

        XCTAssertEqual(
            OpticalCaptureConfiguration(
                displayID: 1,
                region: region,
                workload: belowMinimum,
                generation: 1
            ).screenCaptureQueueDepth,
            3
        )
        XCTAssertEqual(
            OpticalCaptureConfiguration(
                displayID: 1,
                region: region,
                workload: aboveMaximum,
                generation: 1
            ).screenCaptureQueueDepth,
            8
        )
    }

    private func assertRect(
        _ actual: CGRect,
        equals expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }
}
