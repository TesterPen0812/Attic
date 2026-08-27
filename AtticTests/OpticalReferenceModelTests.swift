import CoreGraphics
import XCTest
@testable import Attic

final class OpticalReferenceModelTests: XCTestCase {
    func testReferenceFieldMatchesTheMaximumRestingShaderEnvelope() {
        let profile = maximumProfile(interactionResponse: 28)
        let boundary = PanelOpticalBoundary(
            size: CGSize(width: 332, height: 380),
            cornerRadius: 18,
            exponent: 5
        )

        XCTAssertEqual(profile.refractionBandPixels, 36, accuracy: 0.000_001)
        XCTAssertEqual(profile.baseDisplacementPixels, 23, accuracy: 0.000_001)
        XCTAssertEqual(profile.maximumDisplacementPixels, 24, accuracy: 0.000_001)

        let side = pixelMagnitude(
            boundary.sample(at: CGPoint(x: 1, y: 190), profile: profile, backingScale: 2)
        )
        let bottom = pixelMagnitude(
            boundary.sample(at: CGPoint(x: 166, y: 1), profile: profile, backingScale: 2)
        )
        let top = pixelMagnitude(
            boundary.sample(at: CGPoint(x: 166, y: 379), profile: profile, backingScale: 2)
        )
        let topCorner = pixelMagnitude(
            boundary.sample(at: CGPoint(x: 2.75, y: 377.25), profile: profile, backingScale: 2)
        )
        let bottomCorner = pixelMagnitude(
            boundary.sample(at: CGPoint(x: 2.75, y: 2.75), profile: profile, backingScale: 2)
        )

        XCTAssertTrue((15.4...15.7).contains(side))
        XCTAssertTrue((18.5...18.9).contains(bottom))
        XCTAssertTrue((15.4...15.7).contains(top))
        XCTAssertTrue((19.5...20.0).contains(topCorner))
        XCTAssertTrue((22.7...23.2).contains(bottomCorner))
        XCTAssertGreaterThan(bottom, side)
        XCTAssertGreaterThan(topCorner, side)
        XCTAssertGreaterThan(bottomCorner, bottom)
        XCTAssertGreaterThan(bottomCorner, topCorner)
    }

    func testInteractionResponseHasVisibleHeadroomAtMaximumWithoutExceedingCap() {
        let profile = maximumProfile(interactionResponse: 100)
        let boundary = PanelOpticalBoundary(
            size: CGSize(width: 332, height: 380),
            cornerRadius: 18,
            exponent: 5
        )
        let point = CGPoint(x: 2.75, y: 2.75)

        let resting = pixelMagnitude(
            boundary.sample(
                at: point,
                profile: profile,
                backingScale: 2,
                interactionProgress: 0
            )
        )
        let responding = pixelMagnitude(
            boundary.sample(
                at: point,
                profile: profile,
                backingScale: 2,
                interactionProgress: 1
            )
        )

        XCTAssertGreaterThan(responding, resting + 0.5)
        XCTAssertLessThanOrEqual(responding, 24)
    }

    func testSyntheticGridHasStableShaderAlignedGoldenSignature() {
        let profile = maximumProfile(interactionResponse: 28)
        let boundary = PanelOpticalBoundary(
            size: CGSize(width: 332, height: 380),
            cornerRadius: 18,
            exponent: 5
        )

        XCTAssertEqual(
            opticalSignature(boundary: boundary, profile: profile),
            [
                991, 1_550, 0,
                991, -1_550, 0,
                991, 0, 1_869,
                991, 0, -1_550,
                998, 1_623, 1_623,
                998, -1_623, 1_623,
                998, -1_396, -1_396,
                998, 1_396, -1_396,
                0, 0, 0
            ]
        )
    }

    private func maximumProfile(interactionResponse: Double) -> OpticalGlassProfile {
        var controls = OpticalGlassControls.defaults
        controls.refraction = 100
        controls.interactionResponse = interactionResponse
        return OpticalGlassProfile.resolve(
            controls: controls,
            workload: .workload(for: .maximum),
            windowActivity: .inactive
        )
    }

    private func pixelMagnitude(_ sample: OpticalDisplacementSample) -> Double {
        hypot(sample.displacement.x, sample.displacement.y) * 2
    }

    private func opticalSignature(
        boundary: PanelOpticalBoundary,
        profile: OpticalGlassProfile
    ) -> [Int] {
        let points = [
            CGPoint(x: 1, y: 190),
            CGPoint(x: 331, y: 190),
            CGPoint(x: 166, y: 1),
            CGPoint(x: 166, y: 379),
            CGPoint(x: 2.75, y: 2.75),
            CGPoint(x: 329.25, y: 2.75),
            CGPoint(x: 329.25, y: 377.25),
            CGPoint(x: 2.75, y: 377.25),
            CGPoint(x: 166, y: 190)
        ]

        return points.flatMap { point in
            let sample = boundary.sample(at: point, profile: profile, backingScale: 2)
            return [
                Int((sample.edgeInfluence * 1_000).rounded()),
                Int((sample.displacement.x * 200).rounded()),
                Int((sample.displacement.y * 200).rounded())
            ]
        }
    }
}
