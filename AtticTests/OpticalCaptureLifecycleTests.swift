import XCTest
@testable import Attic

final class OpticalCaptureLifecycleTests: XCTestCase {
    func testDuplicateStartForSameConfigurationIsSuppressed() {
        var lifecycle = OpticalCaptureLifecycle()

        XCTAssertEqual(
            lifecycle.reconcile(shouldRun: true, configurationFingerprint: 41),
            .start(generation: 1)
        )
        XCTAssertEqual(
            lifecycle.reconcile(shouldRun: true, configurationFingerprint: 41),
            .none
        )
        XCTAssertEqual(lifecycle.phase, .running(generation: 1, configurationFingerprint: 41))
    }

    func testConfigurationChangeUsesFreshGenerationAndRejectsStaleFrames() {
        var lifecycle = OpticalCaptureLifecycle()
        XCTAssertEqual(
            lifecycle.reconcile(shouldRun: true, configurationFingerprint: 1),
            .start(generation: 1)
        )
        XCTAssertTrue(lifecycle.acceptsFrame(generation: 1))

        XCTAssertEqual(
            lifecycle.reconcile(shouldRun: true, configurationFingerprint: 2),
            .restart(previousGeneration: 1, generation: 2)
        )
        XCTAssertFalse(lifecycle.acceptsFrame(generation: 1))
        XCTAssertTrue(lifecycle.acceptsFrame(generation: 2))
    }

    func testStaleCaptureFailuresAreRejectedAfterRestartAndStop() {
        var lifecycle = OpticalCaptureLifecycle()
        _ = lifecycle.reconcile(shouldRun: true, configurationFingerprint: 1)
        XCTAssertTrue(lifecycle.acceptsFailure(generation: 1))

        _ = lifecycle.reconcile(shouldRun: true, configurationFingerprint: 2)
        XCTAssertFalse(lifecycle.acceptsFailure(generation: 1))
        XCTAssertTrue(lifecycle.acceptsFailure(generation: 2))

        _ = lifecycle.reconcile(shouldRun: false, configurationFingerprint: 2)
        XCTAssertFalse(lifecycle.acceptsFailure(generation: 2))
    }

    func testHiddenOrOffStopsCaptureAndRequestsResourceRelease() {
        var lifecycle = OpticalCaptureLifecycle()
        _ = lifecycle.reconcile(shouldRun: true, configurationFingerprint: 9)

        XCTAssertEqual(
            lifecycle.reconcile(shouldRun: false, configurationFingerprint: 9),
            .stop(generation: 1)
        )
        XCTAssertEqual(lifecycle.phase, .stopped)
        XCTAssertFalse(lifecycle.acceptsFrame(generation: 1))
        XCTAssertTrue(lifecycle.requiresResourceRelease)

        XCTAssertEqual(
            lifecycle.reconcile(shouldRun: false, configurationFingerprint: 9),
            .none
        )
    }

    func testRendererLifecycleClearsFrameAndResourcesWhenReleased() {
        var lifecycle = OpticalRendererLifecycle()
        lifecycle.prepare()
        lifecycle.didReceiveFrame()

        XCTAssertTrue(lifecycle.isPrepared)
        XCTAssertTrue(lifecycle.hasRetainedFrame)

        lifecycle.release()

        XCTAssertFalse(lifecycle.isPrepared)
        XCTAssertFalse(lifecycle.hasRetainedFrame)
        XCTAssertGreaterThan(lifecycle.releaseGeneration, 0)
    }

    func testFallbackResolutionNeverSimulatesUnsupportedRefraction() {
        XCTAssertEqual(
            OpticalBackdropMode.resolve(
                preset: .off,
                permission: .authorized,
                metalAvailable: true,
                captureAvailable: true,
                reduceTransparency: false
            ),
            .material(reason: .performanceOff)
        )
        XCTAssertEqual(
            OpticalBackdropMode.resolve(
                preset: .balanced,
                permission: .notRequested,
                metalAvailable: true,
                captureAvailable: true,
                reduceTransparency: false
            ),
            .material(reason: .permissionNotRequested)
        )
        XCTAssertEqual(
            OpticalBackdropMode.resolve(
                preset: .balanced,
                permission: .denied,
                metalAvailable: true,
                captureAvailable: true,
                reduceTransparency: false
            ),
            .material(reason: .permissionDenied)
        )
        XCTAssertEqual(
            OpticalBackdropMode.resolve(
                preset: .balanced,
                permission: .authorized,
                metalAvailable: false,
                captureAvailable: true,
                reduceTransparency: false
            ),
            .material(reason: .metalUnavailable)
        )
        XCTAssertEqual(
            OpticalBackdropMode.resolve(
                preset: .balanced,
                permission: .authorized,
                metalAvailable: true,
                captureAvailable: false,
                reduceTransparency: false
            ),
            .material(reason: .captureUnavailable)
        )
        XCTAssertEqual(
            OpticalBackdropMode.resolve(
                preset: .balanced,
                permission: .authorized,
                metalAvailable: true,
                captureAvailable: true,
                reduceTransparency: true
            ),
            .opaque(reason: .reduceTransparency)
        )
        XCTAssertEqual(
            OpticalBackdropMode.resolve(
                preset: .balanced,
                permission: .authorized,
                metalAvailable: true,
                captureAvailable: true,
                reduceTransparency: false
            ),
            .live
        )
    }
}
