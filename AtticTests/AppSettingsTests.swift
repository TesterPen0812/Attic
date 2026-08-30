import XCTest
@testable import Attic

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testGlassStyleDefaultsToClearAndPersists() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppSettings(defaults: defaults)
        XCTAssertEqual(initial.panelGlassStyle, .clear)

        for style in PanelGlassStyle.allCases {
            initial.panelGlassStyle = style
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertEqual(reloaded.panelGlassStyle, style)
        }
    }

    func testGlassStylesAreUniqueAndUseProductNames() {
        XCTAssertEqual(PanelGlassStyle.allCases.map(\.title), [
            "Clear",
            "Frosted",
            "Glassmorphism"
        ])
        XCTAssertEqual(Set(PanelGlassStyle.allCases.map(\.rawValue)).count, 3)
        XCTAssertEqual(PanelGlassStyle.glassmorphism.rawValue, "stable")
    }

    @MainActor
    func testLegacyLiveStablePreferenceMigratesToGlassmorphism() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("liveStable", forKey: "panelGlassStyle")
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.panelGlassStyle, .glassmorphism)
        XCTAssertEqual(defaults.string(forKey: "panelGlassStyle"), "stable")
    }

    @MainActor
    func testInvalidGlassStyleFallsBackToClear() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("unknown-style", forKey: "panelGlassStyle")
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.panelGlassStyle, .clear)
    }

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
