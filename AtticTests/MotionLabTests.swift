import QuartzCore
import SwiftUI
import XCTest
@testable import Attic

/// The feel measured by the cost tests: `ATTIC_MOTION_FEEL` (calm, subtle,
/// lively, playful; `TEST_RUNNER_ATTIC_MOTION_FEEL` through xcodebuild), else the
/// default feel.
enum MotionFeelUnderTest {
    nonisolated(unsafe) private static var saved: AtticMotionTuning?

    @discardableResult
    static func apply() -> String {
        saved = AtticMotionTuning.current
        let feel = AtticMotionFeel(rawValue: ProcessInfo.processInfo.environment["ATTIC_MOTION_FEEL"] ?? "") ?? .recommended
        AtticMotionTuning.current = feel.tuning
        return feel.rawValue
    }

    static func restore() {
        if let saved { AtticMotionTuning.current = saved }
        saved = nil
    }
}

/// The Motion Lab (owner, 2026-09-30): every preset reads the current
/// feel; Reduced motion never does; the lab never shows under the release
/// identity; the pager's settle bounces a little and never toward a
/// second page.
@MainActor
final class MotionLabTests: XCTestCase {
    private var saved = AtticMotionTuning.current

    override func setUp() {
        super.setUp()
        saved = AtticMotionTuning.current
    }

    override func tearDown() {
        AtticMotionTuning.current = saved
        super.tearDown()
    }

    private let feelPresets: [AtticMotionPreset] = [.slide, .expand, .doneSlide, .popover, .toast, .complete, .settle, .failReturn]

    // MARK: - The feels are data

    func testPresetsRouteThroughTheFeel() {
        for feel in AtticMotionFeel.allCases {
            AtticMotionTuning.current = feel.tuning
            for preset in AtticMotionPreset.allCases {
                let spring = preset.spring(in: feel.tuning)
                XCTAssertEqual(preset.duration, spring.response, "\(feel) \(preset)")
                XCTAssertEqual(preset.bounce, spring.bounce, "\(feel) \(preset)")
                XCTAssertEqual(preset.animation(reduceMotion: false), .spring(duration: spring.response, bounce: spring.bounce),
                               "\(feel) \(preset)")
            }
        }
        // The lab's edits reach the presets too.
        var edited = AtticMotionTuning.lively
        edited.popover = AtticMotionSpring(response: 0.41, bounce: 0.33)
        AtticMotionTuning.current = edited
        XCTAssertEqual(AtticMotionPreset.popover.animation(reduceMotion: false), .spring(duration: 0.41, bounce: 0.33))
        // A crossfade and hover feedback are the same in every feel.
        for feel in AtticMotionFeel.allCases {
            XCTAssertEqual(AtticMotionPreset.pageSwitch.spring(in: feel.tuning), AtticMotionSpring(response: 0.18, bounce: 0))
            XCTAssertEqual(AtticMotionPreset.hover.spring(in: feel.tuning), AtticMotionSpring(response: 0.10, bounce: 0))
        }
    }

    /// Calm is round 11 exactly, Playful round 9 exactly (the CHANGELOG),
    /// Lively the brief's shape: navigation about 0.3 s with a light
    /// bounce, things that appear bouncier and from 0.92, no fades.
    func testTheFeelsAreRound11TheRecommendationAndRound9() {
        let calm = AtticMotionTuning.calm
        XCTAssertEqual([calm.slide, calm.expand, calm.doneSlide, calm.popover, calm.toast, calm.complete, calm.settle, calm.failReturn],
                       [.init(response: 0.25, bounce: 0), .init(response: 0.22, bounce: 0), .init(response: 0.25, bounce: 0),
                        .init(response: 0.22, bounce: 0.15), .init(response: 0.24, bounce: 0.12), .init(response: 0.22, bounce: 0.15),
                        .init(response: 0.24, bounce: 0.08), .init(response: 0.28, bounce: 0.1)])
        XCTAssertEqual(calm.appear, .fade)
        XCTAssertEqual(calm.leave, .fade)
        let playful = AtticMotionTuning.playful
        XCTAssertEqual([playful.slide, playful.expand, playful.doneSlide, playful.popover, playful.toast, playful.complete,
                        playful.settle, playful.failReturn],
                       [.init(response: 0.32, bounce: 0.15), .init(response: 0.30, bounce: 0.2), .init(response: 0.34, bounce: 0.2),
                        .init(response: 0.26, bounce: 0.3), .init(response: 0.32, bounce: 0.25), .init(response: 0.26, bounce: 0.3),
                        .init(response: 0.30, bounce: 0.25), .init(response: 0.34, bounce: 0.15)])
        let lively = AtticMotionTuning.lively
        XCTAssertEqual(AtticMotionFeel.recommended, .lively)
        XCTAssertEqual(lively.appear, .spring)
        XCTAssertEqual(lively.leave, .spring)
        XCTAssertFalse(lively.popsNativePopovers, "the native pop-over spring is experimental: off until seen")
        for spring in [lively.slide, lively.expand, lively.doneSlide] {
            XCTAssertEqual(spring.response, 0.28, accuracy: 0.03)
            XCTAssertEqual(spring.bounce, 0.12, accuracy: 0.01)
        }
        for spring in [lively.popover, lively.toast, lively.complete] {
            XCTAssertEqual(spring.bounce, 0.22, accuracy: 0.01)
        }
        XCTAssertEqual(lively.appearScale, 0.92, accuracy: 0.001)
        XCTAssertEqual(lively.leaveScale, 0.96, accuracy: 0.001)
    }

    /// A lively spring starts faster than a critically damped one, so each
    /// of Lively's springs reaches 95 % of its way within a frame and a
    /// half (12 ms) of Calm's: the bounce adds no delay.
    func testLivelyArrivesAsSoonAsCalm() {
        for preset in feelPresets {
            let calm = Self.arrival(preset.spring(in: .calm))
            let lively = Self.arrival(preset.spring(in: .lively))
            XCTAssertLessThanOrEqual(lively, calm + 0.012, "\(preset): \(lively) against \(calm)")
        }
    }

    /// Subtle: Calm's timings with a small bounce (navigation about 0.04,
    /// appear about 0.10), still springing in and tucking away (no plain
    /// fades), quieter than Lively.
    func testSubtleIsCalmsTimingsWithASmallBounce() {
        let subtle = AtticMotionTuning.subtle
        let calm = AtticMotionTuning.calm
        let lively = AtticMotionTuning.lively
        for spring in [subtle.slide, subtle.expand, subtle.doneSlide] {
            XCTAssertEqual(spring.bounce, 0.04, accuracy: 0.001)
        }
        for spring in [subtle.popover, subtle.toast, subtle.complete] {
            XCTAssertEqual(spring.bounce, 0.10, accuracy: 0.001)
        }
        XCTAssertEqual(subtle.slide.response, calm.slide.response)
        XCTAssertEqual(subtle.popover.response, calm.popover.response)
        XCTAssertEqual(subtle.appear, .spring)
        XCTAssertEqual(subtle.leave, .spring)
        XCTAssertFalse(subtle.popsNativePopovers)
        XCTAssertGreaterThan(subtle.appearScale, lively.appearScale, "a smaller pop")
        XCTAssertGreaterThan(subtle.leaveScale, lively.leaveScale, "a smaller tuck")
        XCTAssertLessThan(subtle.leaveResponse, lively.leaveResponse, "and a quicker one")
        for preset in feelPresets {
            XCTAssertLessThanOrEqual(preset.spring(in: .subtle).bounce, preset.spring(in: .lively).bounce, "\(preset)")
            XCTAssertLessThanOrEqual(preset.spring(in: .subtle).response, preset.spring(in: .lively).response, "\(preset)")
        }
        // No plain fades: in Full mode a popover is an animation with a hidden scale.
        XCTAssertLessThan(AtticMotionPreset.popover.hiddenScale(reduceMotion: false), 1)
    }

    /// Like Lively, each Subtle spring reaches 95 % of its way within a
    /// frame and a half of Calm's.
    func testSubtleArrivesAsSoonAsCalm() {
        for preset in feelPresets {
            let calm = Self.arrival(preset.spring(in: .calm))
            let subtle = Self.arrival(preset.spring(in: .subtle))
            XCTAssertLessThanOrEqual(subtle, calm + 0.012, "\(preset): \(subtle) against \(calm)")
        }
    }

    // MARK: - Animations: Lively, Subtle, Reduced

    private func makeSettings(lab: Bool = false, _ prepare: (UserDefaults) -> Void = { _ in }) throws -> (AppSettings, UserDefaults, () -> Void) {
        let suite = "MotionFinalizeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        prepare(defaults)
        let settings = AppSettings(defaults: defaults, motionLabAvailable: lab)
        return (settings, defaults, {
            defaults.removePersistentDomain(forName: suite)
            AtticMotionPreference.level = .lively
        })
    }

    func testLivelyIsTheDefaultInEveryBuild() throws {
        for lab in [false, true] {
            let (settings, _, cleanUp) = try makeSettings(lab: lab)
            defer { cleanUp() }
            XCTAssertEqual(settings.animations, .lively)
            XCTAssertEqual(settings.motionFeel, .lively)
            XCTAssertEqual(settings.motionTuning, AtticMotionTuning.lively)
            XCTAssertEqual(AtticMotionTuning.current, AtticMotionTuning.lively)
            XCTAssertEqual(AtticMotionPreference.level, .lively)
        }
        XCTAssertEqual(AtticAnimationLevel.allCases, [.lively, .subtle, .reduced])
    }

    func testSubtleAndReducedMapToTheirValues() throws {
        let (settings, _, cleanUp) = try makeSettings()
        defer { cleanUp() }
        settings.animations = .subtle
        XCTAssertEqual(settings.motionFeel, .subtle)
        XCTAssertEqual(AtticMotionTuning.current, AtticMotionTuning.subtle)
        XCTAssertEqual(AtticMotionPreset.popover.spring(in: AtticMotionTuning.current), AtticMotionTuning.subtle.popover)
        settings.animations = .reduced
        XCTAssertEqual(AtticMotionPreference.level, .reduced)
        XCTAssertTrue(AtticMotionPreference.reducesMotion)
        for preset in AtticMotionPreset.allCases {
            XCTAssertEqual(preset.hiddenScale(reduceMotion: true), 1, "\(preset): nothing scales when reduced")
        }
        settings.animations = .lively
        XCTAssertEqual(AtticMotionTuning.current, AtticMotionTuning.lively)
        XCTAssertEqual(AtticAnimationLevel.lively.feel, .lively)
        XCTAssertEqual(AtticAnimationLevel.subtle.feel, .subtle)
    }

    func testOldSettingsMigrate() throws {
        let (full, fullDefaults, cleanUpFull) = try makeSettings { $0.set("full", forKey: "animations") }
        defer { cleanUpFull() }
        XCTAssertEqual(full.animations, .lively, "an old Full is Lively")
        XCTAssertEqual(fullDefaults.string(forKey: "animations"), "lively", "and is stored as such")
        XCTAssertEqual(AtticMotionTuning.current, AtticMotionTuning.lively)

        let (reduced, _, cleanUpReduced) = try makeSettings { $0.set("reduced", forKey: "animations") }
        defer { cleanUpReduced() }
        XCTAssertEqual(reduced.animations, .reduced, "an old Reduced stays Reduced")

        let (unknown, _, cleanUpUnknown) = try makeSettings { $0.set("sparkly", forKey: "animations") }
        defer { cleanUpUnknown() }
        XCTAssertEqual(unknown.animations, .lively)

        XCTAssertEqual(AtticAnimationLevel.migrated(from: nil), .lively)
        XCTAssertEqual(AtticAnimationLevel.migrated(from: "subtle"), .subtle)
    }

    /// macOS Reduce Motion wins whatever Animations says.
    func testMacReduceMotionForcesReduced() {
        final class Probe { var reduceMotion: Bool? }
        let probe = Probe()
        struct Reader: View {
            let probe: Probe
            @Environment(\.atticDesign) private var design
            var body: some View {
                probe.reduceMotion = design.reduceMotion
                return Color.clear
            }
        }
        for level in AtticAnimationLevel.allCases {
            probe.reduceMotion = nil
            let host = NSHostingView(rootView: Reader(probe: probe)
                .atticDesignFromSystem(animations: level)
                .environment(\.accessibilityReduceMotion, true))
            host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(probe.reduceMotion, true, "\(level)")
        }
    }

    /// A lab choice overrides Animations until Animations is changed; the
    /// release identity has no lab to choose in.
    func testTheLabChoiceAndTheAnimationsSettingAgree() throws {
        let (settings, defaults, cleanUp) = try makeSettings(lab: true)
        defer { cleanUp() }
        settings.chooseMotionFeel(.subtle)
        XCTAssertEqual(AtticMotionTuning.current, AtticMotionTuning.subtle)
        XCTAssertEqual(settings.animations, .lively, "the setting is untouched")
        settings.chooseMotionFeel(.playful)
        XCTAssertEqual(AppSettings(defaults: defaults, motionLabAvailable: true).motionFeel, .playful)
        settings.animations = .subtle
        XCTAssertEqual(settings.motionFeel, .subtle, "changing Animations puts the feel back")
        XCTAssertNil(defaults.object(forKey: "motionLabFeel"))
        XCTAssertNil(defaults.object(forKey: "motionLabTuning"))
        XCTAssertEqual(AppSettings(defaults: defaults, motionLabAvailable: true).motionFeel, .subtle)
    }

    /// The release identity never writes lab keys, even when Animations changes.
    func testTheReleaseIdentityWritesNoLabKeys() throws {
        let (settings, defaults, cleanUp) = try makeSettings(lab: false)
        defer { cleanUp() }
        settings.animations = .subtle
        settings.animations = .lively
        XCTAssertNil(defaults.object(forKey: "motionLabFeel"))
        XCTAssertNil(defaults.object(forKey: "motionLabTuning"))
    }

    /// Edges is gone: nothing stored, nothing copied.
    func testEdgesIsGone() throws {
        let (settings, defaults, cleanUp) = try makeSettings(lab: true)
        defer { cleanUp() }
        settings.chooseMotionFeel(.lively)
        XCTAssertNil(defaults.object(forKey: "motionLabEdges"))
        XCTAssertFalse(settings.motionTuning.copyText(feel: .lively).contains("Edges"))
    }

    // MARK: - Reduced motion ignores the feel

    func testReducedMotionIgnoresTheFeel() {
        AtticMotionTuning.current = .calm
        let baseline = AtticMotionPreset.allCases.map {
            [$0.animation(reduceMotion: true), $0.leaveAnimation(reduceMotion: true), $0.exit(reduceMotion: true),
             $0.animation(reduceMotion: true, showing: false)]
        }
        for feel in AtticMotionFeel.allCases {
            AtticMotionTuning.current = feel.tuning
            let reduced = AtticMotionPreset.allCases.map {
                [$0.animation(reduceMotion: true), $0.leaveAnimation(reduceMotion: true), $0.exit(reduceMotion: true),
                 $0.animation(reduceMotion: true, showing: false)]
            }
            XCTAssertEqual(reduced, baseline, "\(feel) reached Reduced motion")
            for preset in AtticMotionPreset.allCases {
                XCTAssertEqual(preset.hiddenScale(reduceMotion: true), 1, "\(feel) \(preset): Reduced never scales")
            }
        }
        // Still the round 9 fallbacks: fades, and instant for a page switch and an expand.
        XCTAssertNil(AtticMotionPreset.pageSwitch.animation(reduceMotion: true))
        XCTAssertNil(AtticMotionPreset.expand.animation(reduceMotion: true))
        XCTAssertNil(AtticMotionPreset.expand.exit(reduceMotion: true))
        XCTAssertEqual(AtticMotionPreset.popover.animation(reduceMotion: true), .easeOut(duration: 0.18))
        XCTAssertEqual(AtticMotionPreset.popover.exit(reduceMotion: true), .easeOut(duration: 0.12))
    }

    // MARK: - Appear and leave

    /// Calm leaves as before the lab (the preset's own spring, the Done
    /// search's short fade); the spring style tucks away with a quick,
    /// unbouncy spring; Lively pops things in from 0.92 and Calm never
    /// scales.
    func testAppearAndLeaveFollowTheStyles() {
        AtticMotionTuning.current = .calm
        XCTAssertEqual(AtticMotionPreset.toast.leaveAnimation(reduceMotion: false), .spring(duration: 0.24, bounce: 0.12))
        XCTAssertEqual(AtticMotionPreset.popover.exit(reduceMotion: false), .easeOut(duration: 0.12))
        XCTAssertEqual(AtticMotionPreset.popover.hiddenScale(reduceMotion: false), 1)
        AtticMotionTuning.current = .lively
        XCTAssertEqual(AtticMotionPreset.toast.leaveAnimation(reduceMotion: false), .spring(duration: 0.14, bounce: 0))
        XCTAssertEqual(AtticMotionPreset.popover.exit(reduceMotion: false), .spring(duration: 0.14, bounce: 0))
        XCTAssertEqual(AtticMotionPreset.popover.animation(reduceMotion: false, showing: true),
                       AtticMotionPreset.popover.animation(reduceMotion: false))
        XCTAssertEqual(AtticMotionPreset.popover.animation(reduceMotion: false, showing: false),
                       AtticMotionPreset.popover.leaveAnimation(reduceMotion: false))
        XCTAssertEqual(AtticMotionPreset.popover.hiddenScale(reduceMotion: false), 0.92, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionPreset.settle.hiddenScale(reduceMotion: false), 0.968, accuracy: 0.0001, "rows pop gently")
        XCTAssertEqual(AtticMotionPreset.pageSwitch.hiddenScale(reduceMotion: false), 1, "pages never scale")
        var fading = AtticMotionTuning.lively
        fading.appear = .fade
        AtticMotionTuning.current = fading
        XCTAssertEqual(AtticMotionPreset.popover.hiddenScale(reduceMotion: false), 1)
    }

    func testAPopOverGrowsFromTheEdgeItComesFrom() {
        XCTAssertEqual(AtticMotionPreset.anchor(for: .top), .top)
        XCTAssertEqual(AtticMotionPreset.anchor(for: .bottom), .bottom)
        XCTAssertEqual(AtticMotionPreset.anchor(for: .leading), .leading)
        XCTAssertEqual(AtticMotionPreset.anchor(for: .trailing), .trailing)
        // A native pop-over grows from the arrow: under a button clicked
        // above it, from its top at the pointer's x; above the add bar
        // (arrow edge .top), from its bottom.
        let frame = CGRect(x: 100, y: 300, width: 240, height: 180)
        let bounds = CGRect(origin: .zero, size: frame.size)
        let below = AtticPopoverPop.anchor(frame: frame, bounds: bounds, mouse: CGPoint(x: 150, y: 500),
                                           arrowEdge: .bottom, flipped: false)
        XCTAssertEqual(below, CGPoint(x: 50, y: 180))
        let above = AtticPopoverPop.anchor(frame: frame, bounds: bounds, mouse: CGPoint(x: 400, y: 900),
                                           arrowEdge: .top, flipped: false)
        XCTAssertEqual(above, CGPoint(x: 120, y: 0), "far pointer (keyboard): the arrow edge, centred")
        // The pop's transform keeps the anchor still.
        let layer = CALayer()
        layer.bounds = bounds
        layer.anchorPoint = .zero
        let transform = AtticPopoverPop.transform(scale: 0.9, about: CGPoint(x: 50, y: 180), in: layer)
        let moved = CGPoint(x: 50, y: 180).applying(CATransform3DGetAffineTransform(transform))
        XCTAssertEqual(moved.x, 50, accuracy: 0.001)
        XCTAssertEqual(moved.y, 180, accuracy: 0.001)
    }

    // MARK: - The lab's knobs

    func testTheGroupKnobsShiftEverySpringInTheGroup() {
        var tuning = AtticMotionTuning.calm
        tuning.navigationResponse = 0.30
        XCTAssertEqual(tuning.slide.response, 0.30, accuracy: 0.0001)
        XCTAssertEqual(tuning.expand.response, 0.27, accuracy: 0.0001, "the differences are kept")
        XCTAssertEqual(tuning.doneSlide.response, 0.30, accuracy: 0.0001)
        tuning.appearBounce = 0.25
        XCTAssertEqual(tuning.popover.bounce, 0.25, accuracy: 0.0001)
        XCTAssertEqual(tuning.settle.bounce, 0.18, accuracy: 0.0001)
        XCTAssertEqual(tuning.slide.response, 0.30, accuracy: 0.0001, "only its group moved")
        tuning.appearResponse = 5
        XCTAssertEqual(tuning.failReturn.response, AtticMotionTuning.responseRange.upperBound, "clamped")
        tuning.navigationBounce = -1
        XCTAssertEqual(tuning.slide.bounce, 0, "clamped")
        XCTAssertEqual(tuning.popover.bounce, 0.25, accuracy: 0.0001, "only its group moved")
    }

    func testCopyValuesCarriesEveryValueAsSwift() {
        var tuning = AtticMotionTuning.lively
        tuning.appearScale = 0.9
        let text = tuning.copyText(feel: .lively)
        XCTAssertTrue(text.hasPrefix("Attic motion: Lively (edited)"))
        XCTAssertTrue(text.contains("popover: .init(response: 0.260, bounce: 0.220)"))
        XCTAssertTrue(text.contains("appearScale: 0.900"))
        XCTAssertTrue(text.contains("appear: .spring, leave: .spring"))
        XCTAssertTrue(AtticMotionTuning.calm.copyText(feel: .calm).hasPrefix("Attic motion: Calm\n"))
    }

    // MARK: - The lab is never in the release identity

    func testTheLabIsHiddenInTheReleaseIdentity() {
        XCTAssertFalse(AtticMotionLab.isAvailable(bundleIdentifier: "com.taha.Attic", arguments: []))
        XCTAssertFalse(AtticMotionLab.isAvailable(bundleIdentifier: "com.taha.Attic", arguments: [AtticMotionLab.argument]))
        XCTAssertFalse(AtticMotionLab.isAvailable(bundleIdentifier: nil, arguments: [AtticMotionLab.argument]))
        XCTAssertFalse(AtticMotionLab.isAvailable(bundleIdentifier: "com.taha.Attic.preview.", arguments: []))
        XCTAssertFalse(AtticMotionLab.isAvailable(bundleIdentifier: "com.other.preview.motion", arguments: [AtticMotionLab.argument]))
        XCTAssertFalse(AtticMotionLab.isAvailable(bundleIdentifier: "com.taha.Attic.dira", arguments: []))
        XCTAssertTrue(AtticMotionLab.isAvailable(bundleIdentifier: "com.taha.Attic.preview.motion", arguments: []))
        XCTAssertTrue(AtticMotionLab.isAvailable(bundleIdentifier: "com.taha.Attic.dira", arguments: [AtticMotionLab.argument]))
    }

    /// Outside the lab a stored feel is never read (nor written): the app
    /// runs the recommended feel.
    func testOutsideTheLabAStoredFeelIsIgnored() throws {
        let suite = "MotionLabTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lab = AppSettings(defaults: defaults, motionLabAvailable: true)
        lab.chooseMotionFeel(.playful)
        lab.motionTuning.appearScale = 0.85
        XCTAssertEqual(AtticMotionTuning.current.appearScale, 0.85, "applies at once")
        let reopened = AppSettings(defaults: defaults, motionLabAvailable: true)
        XCTAssertEqual(reopened.motionFeel, .playful, "the preview keeps its choice")
        XCTAssertEqual(reopened.motionTuning.appearScale, 0.85)
        let release = AppSettings(defaults: defaults, motionLabAvailable: false)
        XCTAssertEqual(release.motionFeel, .recommended)
        XCTAssertEqual(release.motionTuning, AtticMotionFeel.recommended.tuning)
        XCTAssertEqual(AtticMotionTuning.current, AtticMotionFeel.recommended.tuning)
        release.chooseMotionFeel(.calm)
        XCTAssertEqual(release.motionFeel, .recommended, "no lab, no choosing")
        XCTAssertEqual(defaults.string(forKey: "motionLabFeel"), "playful", "and nothing written")
    }

    // MARK: - The pager's settle

    /// The settle follows the feel's navigation spring: in Calm it never
    /// passes the page; with a bounce it lands with a small settle past it,
    /// at most a fiftieth of a page however hard the flick, never back
    /// toward the page it left, and it comes to rest.
    func testThePagerSettleBouncesAFiftiethAtMost() {
        for bounce in [0.0, 0.12, 0.15, 0.25, 0.45] {
            for speed in [CGFloat(0), 2, 5, 20, 500] {
                let spring = TasksPagerSpring(from: 0.4, to: 1, speed: speed, duration: 0.30, bounce: bounce)
                var time: TimeInterval = 0
                var peak: CGFloat = 0.4
                var rested = false
                while time < 3 {
                    guard let value = spring.value(at: time) else { rested = true; break }
                    peak = max(peak, value)
                    time += 1.0 / 240
                }
                XCTAssertTrue(rested, "bounce \(bounce), speed \(speed): it comes to rest")
                XCTAssertLessThanOrEqual(peak, 1 + TasksPagerSpring.maxOvershoot + 0.0005, "bounce \(bounce), speed \(speed)")
                if bounce == 0 { XCTAssertLessThanOrEqual(peak, 1.0001, "Calm never passes the page") }
                XCTAssertEqual(spring.value(at: time) ?? 1, 1, accuracy: 0.001)
            }
        }
        // A tab click two pages away: still a fiftieth of a page at most.
        for bounce in [0.12, 0.45] {
            let far = TasksPagerSpring(from: 0, to: 2, speed: 0, duration: 0.30, bounce: bounce)
            var t: TimeInterval = 0
            while let value = far.value(at: t), t < 3 {
                XCTAssertLessThanOrEqual(value, 2 + TasksPagerSpring.maxOvershoot + 0.0005, "bounce \(bounce)")
                t += 1.0 / 240
            }
        }
        // From the rubber band past the last page, back without swinging far the other way.
        let back = TasksPagerSpring(from: 1.08, to: 1, speed: 0, duration: 0.30, bounce: 0.45)
        var time: TimeInterval = 0
        while let value = back.value(at: time), time < 3 {
            XCTAssertGreaterThanOrEqual(value, 1 - TasksPagerSpring.maxOvershoot - 0.0005)
            time += 1.0 / 240
        }
        // A bounce makes it quicker off the mark, never slower to arrive.
        let calm = TasksPagerSpring(from: 0, to: 1, speed: 0, duration: 0.25)
        let lively = TasksPagerSpring(from: 0, to: 1, speed: 0, duration: 0.30, bounce: 0.12)
        XCTAssertLessThanOrEqual(Self.arrival(lively), Self.arrival(calm) + 0.004)
    }

    // MARK: - The timings, measured

    /// Prints what each feel's springs take (ATTIC_MOTION_TIMINGS): when
    /// each reaches 95 % of its way, how far it overshoots, and when it has
    /// settled within 0.5 %, for every preset, the leave tuck and the
    /// pager's settle (still, and after a 5 pages/s flick).
    func testMeasuresTheTimingsOfEachFeel() {
        var lines: [String] = []
        for feel in AtticMotionFeel.allCases {
            let tuning = feel.tuning
            var parts: [String] = []
            for preset in feelPresets {
                parts.append("\(preset.rawValue) " + Self.describe(preset.spring(in: tuning)))
            }
            parts.append("leave " + (tuning.leave == .spring
                ? Self.describe(AtticMotionSpring(response: tuning.leaveResponse, bounce: 0))
                : "fade \(Int(min(tuning.popover.response, 0.12) * 1000))ms"))
            for speed in [CGFloat(0), 5] {
                let pager = TasksPagerSpring(from: 0, to: 1, speed: speed, duration: tuning.slide.response, bounce: tuning.slide.bounce)
                let (arrival, peak, rest) = Self.trace(pager)
                parts.append(String(format: "pager@%.0f 95%%=%.0fms over=%.1f%% rest=%.0fms", speed, arrival * 1000,
                                    (peak - 1) * 100, rest * 1000))
            }
            lines.append("\(feel.rawValue): " + parts.joined(separator: ", "))
        }
        print("ATTIC_MOTION_TIMINGS\n" + lines.joined(separator: "\n"))
        XCTAssertEqual(lines.count, AtticMotionFeel.allCases.count)
    }

    // MARK: - Helpers

    /// When SwiftUI's spring reaches 95 % of its way.
    static func arrival(_ spring: AtticMotionSpring) -> Double {
        let swiftUI = Spring(duration: spring.response, bounce: spring.bounce)
        var time = 0.0
        while swiftUI.value(target: 1.0, time: time) < 0.95, time < 2 { time += 0.0005 }
        return time
    }

    static func arrival(_ spring: TasksPagerSpring) -> Double { trace(spring).arrival }

    static func trace(_ spring: TasksPagerSpring) -> (arrival: Double, peak: CGFloat, rest: Double) {
        var time = 0.0
        var arrival: Double?
        var peak: CGFloat = 0
        while let value = spring.value(at: time), time < 3 {
            if arrival == nil, value >= spring.from + (spring.to - spring.from) * 0.95 { arrival = time }
            peak = max(peak, value)
            time += 0.0005
        }
        return (arrival ?? time, max(peak, spring.to), time)
    }

    static func describe(_ spring: AtticMotionSpring) -> String {
        let swiftUI = Spring(duration: spring.response, bounce: spring.bounce)
        var peak = 0.0
        var time = 0.0
        while time < 1.5 { peak = max(peak, swiftUI.value(target: 1.0, time: time)); time += 0.0005 }
        let settle = swiftUI.settlingDuration(target: 1.0, epsilon: 0.005)
        return String(format: "%.2f/%.2f 95%%=%.0fms over=%.1f%% settle=%.0fms", spring.response, spring.bounce,
                      arrival(spring) * 1000, max(0, peak - 1) * 100, settle * 1000)
    }
}
