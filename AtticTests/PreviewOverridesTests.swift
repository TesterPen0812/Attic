import AppKit
import XCTest
@testable import Attic

/// The preview-only A/B switches (`AtticPreviewOverrides`): they work only in
/// a strict preview identity, and with none set they change nothing.
@MainActor
final class PreviewOverridesTests: XCTestCase {
    private let everything = [
        "ATTIC_UI_TEST_MOTION": "reduced", "ATTIC_UI_TEST_SCROLLERS": "system",
        "ATTIC_UI_TEST_HOVER": "off", "ATTIC_UI_TEST_LIFT": "off", "ATTIC_UI_TEST_CORNER_BUTTONS": "flat",
    ]

    private func scratchDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "AtticPreviewOverridesTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: - Where they work

    func testNoNonPreviewIdentityTakesAnyOverride() {
        let identities: [String?] = [
            "com.taha.Attic", "com.taha.Attic.UnitTestHost", "com.taha.Attic.perf.ui",
            "com.taha.Attic.previewish", "com.taha.Attic.preview.", "com.taha.AtticUITests", "", nil,
        ]
        for identity in identities {
            let resolved = AtticPreviewOverrides.resolve(environment: everything, bundleIdentifier: identity)
            XCTAssertEqual(resolved, .none, "\(identity ?? "nil") ignores every override")
            XCTAssertTrue(resolved.stylesScrollers)
            XCTAssertTrue(resolved.drawsLiftLayer)
        }
    }

    func testAPreviewIdentityTakesEachOverrideAlone() {
        let preview = "com.taha.Attic.preview.main"
        func resolve(_ key: String, _ value: String) -> AtticPreviewOverrides {
            AtticPreviewOverrides.resolve(environment: [key: value], bundleIdentifier: preview)
        }
        let scrollers = resolve("ATTIC_UI_TEST_SCROLLERS", "system")
        XCTAssertEqual(scrollers, AtticPreviewOverrides(scrollers: .system))
        XCTAssertFalse(scrollers.stylesScrollers)
        XCTAssertTrue(resolve("ATTIC_UI_TEST_SCROLLERS", "overlay").stylesScrollers)
        XCTAssertFalse(resolve("ATTIC_UI_TEST_LIFT", "off").drawsLiftLayer)
        XCTAssertTrue(resolve("ATTIC_UI_TEST_LIFT", "on").drawsLiftLayer)
        XCTAssertEqual(resolve("ATTIC_UI_TEST_SCROLLERS", "unknown"), .none)
    }

    func testNothingDiffersByDefault() {
        let preview = AtticPreviewOverrides.resolve(environment: ["ATTIC_UI_TESTING": "1"], bundleIdentifier: "com.taha.Attic.preview.main")
        XCTAssertEqual(preview, .none)
        XCTAssertTrue(preview.stylesScrollers && preview.drawsLiftLayer)
    }

    func testRetiredOverridesCannotChangeTheChosenBehaviour() {
        let retired = ["ATTIC_UI_TEST_MOTION": "calm", "ATTIC_UI_TEST_HOVER": "off",
                       "ATTIC_UI_TEST_CORNER_BUTTONS": "flat"]
        XCTAssertEqual(AtticPreviewOverrides.resolve(environment: retired,
                                                    bundleIdentifier: "com.taha.Attic.preview.cleanup"), .none)
    }

    // MARK: - Motion

    func testTheDefaultMotionIsUnchangedWithNoOverride() throws {
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let before = AtticMotionTuning.current
        let level = AtticMotionPreference.level
        defer { AtticMotionTuning.current = before; AtticMotionPreference.level = level }
        let settings = AppSettings(defaults: defaults, motionLabAvailable: false)
        XCTAssertEqual(settings.animations, .lively)
        XCTAssertEqual(settings.motionFeel, .lively)
    }

    // MARK: - Scrollers

    func testScrollersAreStyledUnlessTheSwitchLeavesThemToTheSystem() {
        let styled = NSScrollView()
        styled.scrollerStyle = .legacy
        TasksScrollKeeper.styleScrollers(of: styled, hidden: false, overrides: .none)
        XCTAssertEqual(styled.scrollerStyle, .overlay, "by default: thin overlay scrollers")
        let system = NSScrollView()
        system.scrollerStyle = .legacy
        TasksScrollKeeper.styleScrollers(of: system, hidden: true, overrides: AtticPreviewOverrides(scrollers: .system))
        XCTAssertEqual(system.scrollerStyle, .legacy, "system: left as the system has them")
        let overlay = NSScrollView()
        overlay.scrollerStyle = .legacy
        TasksScrollKeeper.styleScrollers(of: overlay, hidden: false, overrides: AtticPreviewOverrides(scrollers: .overlay))
        XCTAssertEqual(overlay.scrollerStyle, .overlay)
    }
}
