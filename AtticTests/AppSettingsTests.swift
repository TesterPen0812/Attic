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
