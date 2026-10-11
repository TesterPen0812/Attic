import XCTest
@testable import Attic

final class PanelSquircleSettingsTests: XCTestCase {
    @MainActor
    func testDefaultsMatchExpectedValues() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.panelCornerSize, 52)
        XCTAssertEqual(settings.panelContentSize, PanelContentSize.standard.rawValue)
        XCTAssertEqual(settings.panelHeight, PanelGeometry.defaultPanelSize.height, accuracy: 0.001)
    }

    @MainActor
    func testCornerSizeRangeAndPresets() {
        XCTAssertEqual(PanelCornerSize.min, 10)
        XCTAssertEqual(PanelCornerSize.max, 140)
        XCTAssertEqual(PanelCornerSize.defaultValue, 52)
        XCTAssertEqual(
            PanelCornerSize.allCases.map(\.rawValue),
            [10, 18, 28, 40, 80, 110, 140]
        )
    }

    /// Phase 1 moved the fresh-install default from 80 to 52; a size someone
    /// already chose (including the old default, stored) is kept.
    @MainActor
    func testStoredCornerSizeSurvivesTheNewDefault() {
        for stored in [80.0, 18, 110] {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(stored, forKey: "panelCornerSize")
            XCTAssertEqual(AppSettings(defaults: defaults).panelCornerSize, stored)
        }
    }

    @MainActor
    func testCornerSizeClampedToRange() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        settings.panelCornerSize = 2
        XCTAssertEqual(settings.panelCornerSize, PanelCornerSize.min)

        settings.panelCornerSize = 100
        // 100 is within the expanded 10...140 range and must not be clamped.
        XCTAssertEqual(settings.panelCornerSize, 100)

        settings.panelCornerSize = 200
        XCTAssertEqual(settings.panelCornerSize, PanelCornerSize.max)

        settings.panelCornerSize = 140
        XCTAssertEqual(settings.panelCornerSize, 140)
    }

    @MainActor
    func testContentSizeClampedToRange() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        settings.panelContentSize = 200
        XCTAssertEqual(settings.panelContentSize, PanelContentSize.min)

        settings.panelContentSize = 900
        XCTAssertEqual(settings.panelContentSize, 900)
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
    func testManuallyResizedPanelSizePersistsAcrossInstances() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings1 = AppSettings(defaults: defaults)
        settings1.persistPanelSize(CGSize(width: 612, height: 644))

        let settings2 = AppSettings(defaults: defaults)
        XCTAssertEqual(settings2.panelContentSize, 612)
        XCTAssertEqual(settings2.panelHeight, 644)
    }

    @MainActor
    func testPersistedPanelSizeClampsEachDimensionIndependently() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.persistPanelSize(CGSize(width: 200, height: 640))
        XCTAssertEqual(settings.panelContentSize, PanelGeometry.minimumPanelSize.width)
        XCTAssertEqual(settings.panelHeight, 640)

        settings.persistPanelSize(CGSize(width: 680, height: 900))
        XCTAssertEqual(settings.panelContentSize, 680)
        XCTAssertEqual(settings.panelHeight, 900)
    }

    @MainActor
    func testNonFiniteCornerSizeUsesFallback() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.nan, forKey: "panelCornerSize")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.panelCornerSize, 52)
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
