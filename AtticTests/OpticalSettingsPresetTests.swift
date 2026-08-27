import XCTest
@testable import Attic

final class OpticalSettingsPresetTests: XCTestCase {
    @MainActor
    func testBalancedIsTheDefaultPerformancePreset() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.glassPerformancePreset, .balanced)
    }

    @MainActor
    func testEveryPerformancePresetPersists() {
        for preset in OpticalPerformancePreset.allCases {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let settings = AppSettings(defaults: defaults)
            settings.glassPerformancePreset = preset

            XCTAssertEqual(AppSettings(defaults: defaults).glassPerformancePreset, preset)
        }
    }

    @MainActor
    func testInvalidStoredPresetFallsBackToBalancedAndPersistsSanitizedValue() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("turbo", forKey: "glassPerformancePreset")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.glassPerformancePreset, .balanced)
        XCTAssertEqual(defaults.string(forKey: "glassPerformancePreset"), "balanced")
    }

    @MainActor
    func testLegacyOpaquePreferenceMigratesToOffWithoutChangingOtherAxes() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "isTranslucent")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.glassPerformancePreset, .off)
        XCTAssertEqual(settings.glassTransparency, 0)
        XCTAssertEqual(settings.glassFrost, OpticalGlassControls.defaults.frost)
        XCTAssertEqual(settings.glassRefraction, OpticalGlassControls.defaults.refraction)
    }

    @MainActor
    func testExistingOpticalInstallationMigratesToBalanced() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(67.0, forKey: "glassRefraction")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.glassPerformancePreset, .balanced)
        XCTAssertEqual(settings.glassRefraction, 67)
    }

    @MainActor
    func testChangingPresetPreservesEveryIndependentAxis() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.glassTransparency = 11
        settings.glassFrost = 22
        settings.glassRefraction = 33
        settings.glassEdgeShine = 44
        settings.glassTint = 55
        settings.glassReadability = 66
        settings.glassInteractionResponse = 77
        let controls = settings.opticalGlassControls

        for preset in OpticalPerformancePreset.allCases {
            settings.glassPerformancePreset = preset
            XCTAssertEqual(settings.opticalGlassControls, controls)
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "OpticalSettingsPresetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
