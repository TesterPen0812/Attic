import CoreGraphics
import XCTest
@testable import Attic

final class OpticalMetalRendererTests: XCTestCase {
    func testUniformsMapPanelIntoOverscannedCaptureAndUseWorkloadBudgets() {
        var controls = OpticalGlassControls.defaults
        controls.refraction = 100
        let workload = OpticalWorkloadProfile.workload(for: .maximum)
        let profile = OpticalGlassProfile.resolve(
            controls: controls,
            workload: workload,
            windowActivity: .inactive
        )
        let region = ScreenCaptureRegionMapper.makeRegion(
            panelFrame: CGRect(x: 1_000, y: 500, width: 332, height: 380),
            displayFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            backingScale: 2,
            workload: workload,
            frostRadiusPixels: profile.frostRadius
        )
        let state = OpticalMetalRenderState(
            profile: profile,
            workload: workload,
            region: region,
            panelSizePoints: CGSize(width: 332, height: 380),
            cornerRadiusPoints: 18,
            backingScale: 2,
            tintColor: SIMD4<Float>(1, 1, 1, 1),
            surfaceColor: SIMD4<Float>(0.1, 0.1, 0.1, 1),
            interactionMultiplier: 1
        )

        let uniforms = OpticalMetalUniforms.make(
            textureWidth: region.outputPixelWidth,
            textureHeight: region.outputPixelHeight,
            state: state
        )

        XCTAssertEqual(uniforms.geometry0.x, Float(region.outputPixelWidth))
        XCTAssertEqual(uniforms.geometry0.y, Float(region.outputPixelHeight))
        XCTAssertEqual(
            uniforms.geometry0.z,
            Float(region.panelRectInCapturePoints.minX / region.sourceRect.width),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            uniforms.geometry0.w,
            Float(region.panelRectInCapturePoints.minY / region.sourceRect.height),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            uniforms.geometry1.x,
            Float(region.panelRectInCapturePoints.width / region.sourceRect.width),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            uniforms.geometry1.y,
            Float(region.panelRectInCapturePoints.height / region.sourceRect.height),
            accuracy: 0.0001
        )
        XCTAssertEqual(uniforms.geometry1.z, 664)
        XCTAssertEqual(uniforms.geometry1.w, 760)
        XCTAssertEqual(uniforms.optics0.x, 36)
        XCTAssertEqual(uniforms.optics0.y, 36)
        XCTAssertEqual(uniforms.optics0.z, 23)
        XCTAssertEqual(uniforms.optics0.w, 1)
        XCTAssertEqual(uniforms.optics2.z, 13)
        XCTAssertEqual(uniforms.optics2.w, 5)
        XCTAssertEqual(uniforms.optics3.x, 24)
    }

    func testShaderHasExactIdentityBranchAndWorkloadControlledLoops() {
        let source = OpticalShaderLibrary.source

        XCTAssertTrue(source.contains("Exact coordinate identity for Refraction 0"))
        XCTAssertTrue(source.contains("bandPixels > 0.0f"))
        XCTAssertTrue(source.contains("displacementPixels > 0.0f"))
        XCTAssertTrue(source.contains("sampleIndex < 13u"))
        XCTAssertTrue(source.contains("sampleIndex >= blurSampleCount"))
        XCTAssertTrue(source.contains("evaluationIndex < 5u"))
        XCTAssertTrue(source.contains("evaluationIndex >= edgeEvaluationCount"))
    }

    func testShaderUsesTheSharedBottomAndCornerEnvelope() {
        let source = OpticalShaderLibrary.source

        XCTAssertTrue(source.contains("2.0f * abs(inwardNormal.x * inwardNormal.y)"))
        XCTAssertTrue(source.contains("0.68f + 0.14f * bottomWeight + 0.18f * cornerWeight"))
    }

    @MainActor
    func testRuntimeMetalLibraryCompilesWhenMetalIsAvailable() throws {
        guard OpticalMetalRenderer.isSupported else {
            throw XCTSkip("No Metal device is available on this test host.")
        }

        XCTAssertNotNil(OpticalMetalRenderer(metrics: OpticalPerformanceMetrics()))
    }

    @MainActor
    func testRendererRemainsPausedAndDrawsOnlyWhenAFrameArrives() throws {
        guard OpticalMetalRenderer.isSupported else {
            throw XCTSkip("No Metal device is available on this test host.")
        }
        guard let renderer = OpticalMetalRenderer(metrics: OpticalPerformanceMetrics()) else {
            return XCTFail("Expected a Metal renderer")
        }

        XCTAssertTrue(renderer.view.enableSetNeedsDisplay)
        XCTAssertTrue(renderer.view.isPaused)
    }

    func testFocusDoesNotAppearInMetalRenderStateOrUniforms() {
        let stateLabels = Set(
            Mirror(reflecting: emptyState()).children.compactMap(\.label)
        )
        let uniformLabels = Set(
            Mirror(
                reflecting: OpticalMetalUniforms.make(
                    textureWidth: 1,
                    textureHeight: 1,
                    state: emptyState()
                )
            ).children.compactMap(\.label)
        )

        for labels in [stateLabels, uniformLabels] {
            XCTAssertFalse(labels.contains("isFocused"))
            XCTAssertFalse(labels.contains("isKeyWindow"))
            XCTAssertFalse(labels.contains("windowActivity"))
        }
    }

    private func emptyState() -> OpticalMetalRenderState {
        let workload = OpticalWorkloadProfile.workload(for: .low)
        let profile = OpticalGlassProfile.resolve(
            controls: .defaults,
            workload: workload,
            windowActivity: .key
        )
        let region = ScreenCaptureRegionMapper.makeRegion(
            panelFrame: CGRect(x: 10, y: 10, width: 100, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
            backingScale: 1,
            workload: workload,
            frostRadiusPixels: 0
        )
        return OpticalMetalRenderState(
            profile: profile,
            workload: workload,
            region: region,
            panelSizePoints: CGSize(width: 100, height: 100),
            cornerRadiusPoints: 18,
            backingScale: 1,
            tintColor: SIMD4<Float>(1, 1, 1, 1),
            surfaceColor: SIMD4<Float>(0, 0, 0, 1),
            interactionMultiplier: 1
        )
    }
}
