import XCTest
@testable import Attic

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testNonFiniteStoredDelaysUseSafeFallbacks() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        markDelayMigrationsComplete(in: defaults)
        defaults.set(Double.nan, forKey: "revealDelay")
        defaults.set(Double.infinity, forKey: "hideDelay")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.revealDelay, 0.2)
        XCTAssertEqual(settings.hideDelay, 0.3)
        XCTAssertTrue(settings.revealDelay.isFinite)
        XCTAssertTrue(settings.hideDelay.isFinite)
    }

    @MainActor
    func testNonFiniteAssignedDelaysAreSanitizedAndPersisted() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        markDelayMigrationsComplete(in: defaults)
        let settings = AppSettings(defaults: defaults)

        settings.revealDelay = .infinity
        settings.hideDelay = .nan

        XCTAssertEqual(settings.revealDelay, 0.2)
        XCTAssertEqual(settings.hideDelay, 0.3)
        XCTAssertEqual(defaults.double(forKey: "revealDelay"), 0.2)
        XCTAssertEqual(defaults.double(forKey: "hideDelay"), 0.3)
    }

    @MainActor
    func testOpticalGlassDefaultsMatchTheRestingTarget() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let expected = OpticalGlassControls.defaults

        XCTAssertEqual(settings.glassTransparency, expected.transparency)
        XCTAssertEqual(settings.glassFrost, expected.frost)
        XCTAssertEqual(settings.glassRefraction, expected.refraction)
        XCTAssertEqual(settings.glassEdgeShine, expected.edgeShine)
        XCTAssertEqual(settings.glassTint, expected.tint)
        XCTAssertEqual(settings.glassReadability, expected.readability)
        XCTAssertEqual(settings.glassInteractionResponse, expected.interactionResponse)
        XCTAssertEqual(settings.opticalGlassControls, expected)
    }

    @MainActor
    func testLegacyOpaquePreferenceMigratesToZeroTransparency() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "isTranslucent")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.glassTransparency, 0)
        XCTAssertEqual(defaults.double(forKey: "glassTransparency"), 0)
        XCTAssertEqual(settings.glassRefraction, OpticalGlassControls.defaults.refraction)
    }

    @MainActor
    func testOpticalGlassControlsClampAndPersistIndependently() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.glassTransparency = -20
        settings.glassFrost = 120
        settings.glassRefraction = 62
        settings.glassEdgeShine = 11
        settings.glassTint = 22
        settings.glassReadability = 33
        settings.glassInteractionResponse = 44

        XCTAssertEqual(settings.glassTransparency, 0)
        XCTAssertEqual(settings.glassFrost, 100)
        XCTAssertEqual(settings.glassRefraction, 62)
        XCTAssertEqual(settings.glassEdgeShine, 11)
        XCTAssertEqual(settings.glassTint, 22)
        XCTAssertEqual(settings.glassReadability, 33)
        XCTAssertEqual(settings.glassInteractionResponse, 44)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.glassTransparency, 0)
        XCTAssertEqual(reloaded.glassFrost, 100)
        XCTAssertEqual(reloaded.glassRefraction, 62)
        XCTAssertEqual(reloaded.glassEdgeShine, 11)
        XCTAssertEqual(reloaded.glassTint, 22)
        XCTAssertEqual(reloaded.glassReadability, 33)
        XCTAssertEqual(reloaded.glassInteractionResponse, 44)
    }

    @MainActor
    func testNonFiniteOpticalGlassControlsUseAxisDefaults() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.nan, forKey: "glassTransparency")
        defaults.set(Double.infinity, forKey: "glassFrost")
        defaults.set(-Double.infinity, forKey: "glassRefraction")
        defaults.set(Double.nan, forKey: "glassEdgeShine")
        defaults.set(Double.infinity, forKey: "glassTint")
        defaults.set(Double.nan, forKey: "glassReadability")
        defaults.set(Double.infinity, forKey: "glassInteractionResponse")

        let settings = AppSettings(defaults: defaults)
        let expected = OpticalGlassControls.defaults

        XCTAssertEqual(settings.glassTransparency, expected.transparency)
        XCTAssertEqual(settings.glassFrost, expected.frost)
        XCTAssertEqual(settings.glassRefraction, expected.refraction)
        XCTAssertEqual(settings.glassEdgeShine, expected.edgeShine)
        XCTAssertEqual(settings.glassTint, expected.tint)
        XCTAssertEqual(settings.glassReadability, expected.readability)
        XCTAssertEqual(settings.glassInteractionResponse, expected.interactionResponse)
    }

    @MainActor
    func testAssignedNonFiniteOpticalControlIsSanitizedAndPersisted() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.glassRefraction = .nan

        XCTAssertEqual(settings.glassRefraction, OpticalGlassControls.defaults.refraction)
        XCTAssertEqual(
            defaults.double(forKey: "glassRefraction"),
            OpticalGlassControls.defaults.refraction
        )
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func markDelayMigrationsComplete(in defaults: UserDefaults) {
        defaults.set(true, forKey: "hasAdoptedFasterReveal")
        defaults.set(true, forKey: "hasAdoptedQuickerRevealV2")
        defaults.set(true, forKey: "hasAdoptedInstantRevealV3")
    }
}

final class OpticalGlassContractTests: XCTestCase {
    func testOpticalAxesResolveIndependently() {
        let baselineControls = OpticalGlassControls.defaults
        let baseline = OpticalGlassProfile.resolve(
            controls: baselineControls,
            windowActivity: .key
        )

        var controls = baselineControls
        controls.transparency = 35
        XCTAssertEqual(changedFields(from: baseline, to: resolved(controls)), ["surfaceOpacity"])

        controls = baselineControls
        controls.frost = 71
        XCTAssertEqual(changedFields(from: baseline, to: resolved(controls)), ["frostRadius"])

        controls = baselineControls
        controls.refraction = 41
        XCTAssertEqual(
            changedFields(from: baseline, to: resolved(controls)),
            ["baseDisplacementPixels", "refractionBandPixels"]
        )

        controls = baselineControls
        controls.edgeShine = 73
        XCTAssertEqual(changedFields(from: baseline, to: resolved(controls)), ["edgeShineOpacity"])

        controls = baselineControls
        controls.tint = 64
        XCTAssertEqual(changedFields(from: baseline, to: resolved(controls)), ["tintOpacity"])

        controls = baselineControls
        controls.readability = 52
        XCTAssertEqual(changedFields(from: baseline, to: resolved(controls)), ["readabilityOpacity"])

        controls = baselineControls
        controls.interactionResponse = 87
        XCTAssertEqual(changedFields(from: baseline, to: resolved(controls)), ["interactionBoost"])
    }

    func testZeroRefractionIsIdentityAcrossThePanel() {
        var controls = OpticalGlassControls.defaults
        controls.refraction = 0
        let profile = resolved(controls)
        let boundary = PanelOpticalBoundary(
            size: CGSize(width: 332, height: 380),
            cornerRadius: 18,
            exponent: 5
        )
        let points = [
            CGPoint(x: 1, y: 190),
            CGPoint(x: 331, y: 190),
            CGPoint(x: 166, y: 1),
            CGPoint(x: 166, y: 379),
            CGPoint(x: 2.75, y: 2.75),
            CGPoint(x: 166, y: 190)
        ]

        for point in points {
            let sample = boundary.sample(at: point, profile: profile, backingScale: 2)
            XCTAssertEqual(sample.edgeInfluence, 0, accuracy: 0.000_001)
            XCTAssertEqual(sample.displacement, .zero)
            XCTAssertEqual(sample.sourcePoint, point)
        }
    }

    func testEdgeMaskIsContinuousAtStraightToCornerJoin() {
        let profile = resolved(.defaults)
        let boundary = PanelOpticalBoundary(
            size: CGSize(width: 332, height: 380),
            cornerRadius: 18,
            exponent: 5
        )
        let beforeJoin = boundary.sample(
            at: CGPoint(x: 313.75, y: 379),
            profile: profile,
            backingScale: 2
        )
        let afterJoin = boundary.sample(
            at: CGPoint(x: 314.25, y: 379),
            profile: profile,
            backingScale: 2
        )

        XCTAssertEqual(beforeJoin.edgeInfluence, afterJoin.edgeInfluence, accuracy: 0.001)
        XCTAssertEqual(beforeJoin.displacement.x, afterJoin.displacement.x, accuracy: 0.02)
        XCTAssertEqual(beforeJoin.displacement.y, afterJoin.displacement.y, accuracy: 0.02)
    }

    func testEdgeMaskFallsContinuouslyToZeroBeforeTheCenter() {
        let profile = resolved(.defaults)
        let boundary = PanelOpticalBoundary(
            size: CGSize(width: 332, height: 380),
            cornerRadius: 18,
            exponent: 5
        )
        let samples = [1.0, 5.0, 10.0, 17.0, 19.0].map {
            boundary.sample(
                at: CGPoint(x: 166, y: $0),
                profile: profile,
                backingScale: 2
            ).edgeInfluence
        }

        XCTAssertGreaterThan(samples[0], samples[1])
        XCTAssertGreaterThan(samples[1], samples[2])
        XCTAssertGreaterThan(samples[2], samples[3])
        XCTAssertEqual(samples[4], 0, accuracy: 0.000_001)
    }

    func testCenterHasNoOpticalContributionOrSeam() {
        let profile = resolved(.defaults)
        let boundary = PanelOpticalBoundary(
            size: CGSize(width: 332, height: 380),
            cornerRadius: 18,
            exponent: 5
        )
        let centerPoints = [
            CGPoint(x: 166, y: 190),
            CGPoint(x: 165.75, y: 190),
            CGPoint(x: 166.25, y: 190),
            CGPoint(x: 116, y: 190),
            CGPoint(x: 216, y: 190)
        ]

        for point in centerPoints {
            let sample = boundary.sample(at: point, profile: profile, backingScale: 2)
            XCTAssertEqual(sample.edgeInfluence, 0, accuracy: 0.000_001)
            XCTAssertEqual(sample.displacement, .zero)
        }
    }

    func testResolvedProfileIsIndependentOfWindowFocus() {
        let controls = OpticalGlassControls.defaults
        let key = OpticalGlassProfile.resolve(controls: controls, windowActivity: .key)
        let inactive = OpticalGlassProfile.resolve(controls: controls, windowActivity: .inactive)

        XCTAssertEqual(key, inactive)
    }

    private func resolved(_ controls: OpticalGlassControls) -> OpticalGlassProfile {
        OpticalGlassProfile.resolve(controls: controls, windowActivity: .key)
    }

    private func changedFields(
        from lhs: OpticalGlassProfile,
        to rhs: OpticalGlassProfile
    ) -> Set<String> {
        var fields: Set<String> = []
        if lhs.surfaceOpacity != rhs.surfaceOpacity { fields.insert("surfaceOpacity") }
        if lhs.frostRadius != rhs.frostRadius { fields.insert("frostRadius") }
        if lhs.refractionBandPixels != rhs.refractionBandPixels {
            fields.insert("refractionBandPixels")
        }
        if lhs.baseDisplacementPixels != rhs.baseDisplacementPixels {
            fields.insert("baseDisplacementPixels")
        }
        if lhs.edgeShineOpacity != rhs.edgeShineOpacity {
            fields.insert("edgeShineOpacity")
        }
        if lhs.tintOpacity != rhs.tintOpacity { fields.insert("tintOpacity") }
        if lhs.readabilityOpacity != rhs.readabilityOpacity {
            fields.insert("readabilityOpacity")
        }
        if lhs.interactionBoost != rhs.interactionBoost {
            fields.insert("interactionBoost")
        }
        return fields
    }
}
