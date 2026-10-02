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
            XCTAssertTrue(resolved.rowHoverTints)
            XCTAssertTrue(resolved.drawsLiftLayer)
        }
    }

    func testAPreviewIdentityTakesEachOverrideAlone() {
        let preview = "com.taha.Attic.preview.main"
        func resolve(_ key: String, _ value: String) -> AtticPreviewOverrides {
            AtticPreviewOverrides.resolve(environment: [key: value], bundleIdentifier: preview)
        }
        for motion in ["calm", "lively", "subtle", "reduced"] {
            XCTAssertEqual(resolve("ATTIC_UI_TEST_MOTION", motion), AtticPreviewOverrides(motion: .init(rawValue: motion)))
        }
        let scrollers = resolve("ATTIC_UI_TEST_SCROLLERS", "system")
        XCTAssertEqual(scrollers, AtticPreviewOverrides(scrollers: .system))
        XCTAssertFalse(scrollers.stylesScrollers)
        XCTAssertTrue(resolve("ATTIC_UI_TEST_SCROLLERS", "overlay").stylesScrollers)
        XCTAssertFalse(resolve("ATTIC_UI_TEST_HOVER", "off").rowHoverTints)
        XCTAssertTrue(resolve("ATTIC_UI_TEST_HOVER", "tint").rowHoverTints)
        XCTAssertFalse(resolve("ATTIC_UI_TEST_LIFT", "off").drawsLiftLayer)
        XCTAssertTrue(resolve("ATTIC_UI_TEST_LIFT", "on").drawsLiftLayer)
        XCTAssertEqual(resolve("ATTIC_UI_TEST_CORNER_BUTTONS", "flat"), AtticPreviewOverrides(cornerButtons: .flat))
        XCTAssertEqual(resolve("ATTIC_UI_TEST_CORNER_BUTTONS", "glass"), AtticPreviewOverrides(cornerButtons: .glass))
        // Each one changes only its own part, and an unknown word nothing.
        XCTAssertEqual(resolve("ATTIC_UI_TEST_HOVER", "off").motion, nil)
        XCTAssertEqual(resolve("ATTIC_UI_TEST_MOTION", "bouncy"), .none)
        XCTAssertEqual(resolve("ATTIC_UI_TEST_HOVER", "OFF"), .none)
    }

    func testNothingDiffersByDefault() {
        let preview = AtticPreviewOverrides.resolve(environment: ["ATTIC_UI_TESTING": "1"], bundleIdentifier: "com.taha.Attic.preview.main")
        XCTAssertEqual(preview, .none)
        XCTAssertTrue(preview.stylesScrollers && preview.rowHoverTints && preview.drawsLiftLayer)
        XCTAssertNil(preview.motion)
        XCTAssertNil(preview.cornerButtons)
    }

    // MARK: - Motion

    func testMotionForcesTheFeelForTheLaunchAndStoresNothing() throws {
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let before = AtticMotionTuning.current
        let level = AtticMotionPreference.level
        defer { AtticMotionTuning.current = before; AtticMotionPreference.level = level }
        let cases: [(AtticPreviewOverrides.Motion, AtticAnimationLevel, AtticMotionFeel)] = [
            (.calm, .lively, .calm), (.lively, .lively, .lively), (.subtle, .subtle, .subtle), (.reduced, .reduced, .subtle),
        ]
        for (motion, expectedLevel, expectedFeel) in cases {
            let settings = AppSettings(defaults: defaults, motionLabAvailable: true,
                                       previewOverrides: AtticPreviewOverrides(motion: motion))
            XCTAssertEqual(settings.animations, expectedLevel, "\(motion)")
            XCTAssertEqual(settings.motionFeel, expectedFeel, "\(motion)")
            XCTAssertEqual(settings.motionTuning, expectedFeel.tuning, "\(motion)")
            XCTAssertEqual(AtticMotionTuning.current, expectedFeel.tuning)
            XCTAssertNil(defaults.string(forKey: "animations"), "\(motion): the level is not stored")
            XCTAssertNil(defaults.data(forKey: "motionLabTuning"), "\(motion): no tuning is stored")
        }
    }

    func testMotionBeatsAStoredLabChoiceOnlyWhenSet() throws {
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let before = AtticMotionTuning.current
        let level = AtticMotionPreference.level
        defer { AtticMotionTuning.current = before; AtticMotionPreference.level = level }
        AppSettings(defaults: defaults, motionLabAvailable: true, previewOverrides: .none).chooseMotionFeel(.playful)
        XCTAssertEqual(AppSettings(defaults: defaults, motionLabAvailable: true, previewOverrides: .none).motionFeel, .playful,
                       "with no switch the stored choice is used, as before")
        let forced = AppSettings(defaults: defaults, motionLabAvailable: true, previewOverrides: AtticPreviewOverrides(motion: .calm))
        XCTAssertEqual(forced.motionFeel, .calm)
        XCTAssertEqual(AppSettings(defaults: defaults, motionLabAvailable: true, previewOverrides: .none).motionFeel, .playful,
                       "and the choice is still there afterwards")
    }

    func testTheDefaultMotionIsUnchangedWithNoOverride() throws {
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let before = AtticMotionTuning.current
        let level = AtticMotionPreference.level
        defer { AtticMotionTuning.current = before; AtticMotionPreference.level = level }
        let settings = AppSettings(defaults: defaults, motionLabAvailable: false, previewOverrides: .none)
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
