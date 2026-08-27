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
    func testEveryUserFacingSettingPersistsThroughItsModelBinding() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        markDelayMigrationsComplete(in: defaults)
        defaults.set(true, forKey: "hasAdoptedAgentAccessOptIn")
        let settings = AppSettings(defaults: defaults)

        settings.corner = .bottomLeft
        settings.revealDelay = 1.4
        settings.hideDelay = 1.7
        settings.isTranslucent = false
        settings.appearance = .dark
        settings.isAgentAccessEnabled = true

        XCTAssertEqual(defaults.string(forKey: "selectedCorner"), ScreenCorner.bottomLeft.rawValue)
        XCTAssertEqual(defaults.double(forKey: "revealDelay"), 1.4)
        XCTAssertEqual(defaults.double(forKey: "hideDelay"), 1.7)
        XCTAssertFalse(defaults.bool(forKey: "isTranslucent"))
        XCTAssertEqual(defaults.string(forKey: "appearancePreference"), AppearancePreference.dark.rawValue)
        XCTAssertTrue(defaults.bool(forKey: "isAgentAccessEnabled"))

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.corner, .bottomLeft)
        XCTAssertEqual(restored.revealDelay, 1.4)
        XCTAssertEqual(restored.hideDelay, 1.7)
        XCTAssertFalse(restored.isTranslucent)
        XCTAssertEqual(restored.appearance, .dark)
        XCTAssertTrue(restored.isAgentAccessEnabled)
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
