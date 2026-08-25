import XCTest
@testable import Attic

final class PanelSquircleSettingsTests: XCTestCase {
    @MainActor
    func testDefaultsMatchExpectedValues() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.panelCornerSize, PanelCornerSize.standard.rawValue)
        XCTAssertEqual(settings.panelContentSize, PanelContentSize.standard.rawValue)
    }

    @MainActor
    func testCornerSizeClampedToRange() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        settings.panelCornerSize = 2
        XCTAssertEqual(settings.panelCornerSize, PanelCornerSize.min)

        settings.panelCornerSize = 100
        XCTAssertEqual(settings.panelCornerSize, PanelCornerSize.max)
    }

    @MainActor
    func testContentSizeClampedToRange() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        settings.panelContentSize = 200
        XCTAssertEqual(settings.panelContentSize, PanelContentSize.min)

        settings.panelContentSize = 500
        XCTAssertEqual(settings.panelContentSize, PanelContentSize.max)
    }

    @MainActor
    func testCornerSizePersistedAcrossInstances() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings1 = AppSettings(defaults: defaults)
        settings1.panelCornerSize = 28

        let settings2 = AppSettings(defaults: defaults)
        XCTAssertEqual(settings2.panelCornerSize, 28)
    }

    @MainActor
    func testContentSizePersistedAcrossInstances() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings1 = AppSettings(defaults: defaults)
        settings1.panelContentSize = 360

        let settings2 = AppSettings(defaults: defaults)
        XCTAssertEqual(settings2.panelContentSize, 360)
    }

    @MainActor
    func testNonFiniteCornerSizeUsesFallback() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.nan, forKey: "panelCornerSize")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.panelCornerSize, PanelCornerSize.standard.rawValue)
    }

    @MainActor
    func testNonFiniteContentSizeUsesFallback() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.infinity, forKey: "panelContentSize")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.panelContentSize, PanelContentSize.standard.rawValue)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "PanelSquircleSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}