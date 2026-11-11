import SwiftUI
import XCTest
@testable import Attic

/// What Attic takes from Loam (Accepted 2026-11-10, "Motion: what Attic
/// takes from Loam, both Reduced choices"): light arrivals pop, exits ease
/// in, presses shrink, rows lift, the toast rises and sinks, and Reduced
/// offers Fade as well as Instant.
@MainActor
final class LoamMotionTests: XCTestCase {
    private final class ArrivalState: ObservableObject {
        @Published var reduced = true
    }

    private struct ArrivalSurface: View {
        @ObservedObject var state: ArrivalState

        var body: some View {
            let design = AtticDesignContext(mode: .light, reduceMotion: state.reduced)
            Color.black.frame(width: 40, height: 40)
                .modifier(AtticStaggeredArrival(index: 3))
                .frame(width: 80, height: 80)
                .background(Color.white)
                .atticDesign(design)
        }
    }

    /// E-2: an arrival first displayed under Reduced must remain opaque
    /// when motion is re-enabled without unmounting the existing view.
    func testE2StaggeredArrivalStaysVisibleWhenReductionTurnsOff() throws {
        let state = ArrivalState()
        let host = NSHostingView(rootView: ArrivalSurface(state: state))
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 80, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        func centreRed() throws -> CGFloat {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let colour = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
            return try XCTUnwrap(colour.usingColorSpace(.deviceRGB)).redComponent
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertLessThan(try centreRed(), 0.25, "Reduced arrives visible")
        state.reduced = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertLessThan(try centreRed(), 0.25, "turning off Reduced cannot hide an existing button")
    }

    private var savedTuning = AtticMotionTuning.current
    private var savedStyle = AtticReducedMotionStyle.current

    override func setUp() {
        super.setUp()
        savedTuning = AtticMotionTuning.current
        savedStyle = AtticReducedMotionStyle.current
    }

    override func tearDown() {
        AtticMotionTuning.current = savedTuning
        AtticReducedMotionStyle.current = savedStyle
        super.tearDown()
    }

    // MARK: - Tokens

    /// Exits speed up: the one exit curve eases in over F (0.12 s).
    func testExitsEaseIn() {
        XCTAssertEqual(AtticMotionScale.exit, Animation.easeIn(duration: 0.12))
        XCTAssertEqual(AtticMotionPreset.toast.leaveAnimation(reduceMotion: false), Animation.easeIn(duration: 0.12))
    }

    /// The Undo toast arrives on pop (0.30 s, bounce 0.28) in Lively.
    func testTheToastArrivesOnPop() {
        XCTAssertEqual(AtticMotionPreset.toast.spring(in: .lively), AtticMotionSpring(response: 0.30, bounce: 0.28))
        AtticMotionTuning.current = .lively
        XCTAssertEqual(AtticMotionPreset.toast.animation(reduceMotion: false), .spring(duration: 0.30, bounce: 0.28))
    }

    /// The named values: pop, lift, press, stagger, the cross-fade, the
    /// chrome fold and the chat's exception.
    func testTheTokenTable() {
        XCTAssertEqual(AtticMotionScale.pop, AtticMotionSpring(response: 0.30, bounce: 0.28))
        XCTAssertEqual(AtticMotionScale.lift, AtticMotionSpring(response: 0.30, bounce: 0.18))
        XCTAssertTrue((1.02...1.03).contains(AtticMotionScale.liftScale))
        XCTAssertEqual(AtticMotionScale.pressScale, 0.97)
        XCTAssertEqual(AtticMotionScale.press, AtticMotionSpring(response: 0.20, bounce: 0))
        XCTAssertEqual(AtticMotionScale.crossfade, .easeOut(duration: 0.16))
        XCTAssertEqual(AtticMotionScale.deleteScale, 0.96)
        XCTAssertEqual(AtticMotionScale.gapCloseDelay, 0.06, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionScale.toastRise, 12)
        XCTAssertEqual(AtticMotionScale.toastSink, 8)
        XCTAssertEqual(AtticMotionScale.detailsDrop, 4)
        // The chrome fold: named, unchanged (0.26 s on .3, .7, .2, 1).
        XCTAssertEqual(AtticMotionScale.chromeFold, 0.26)
        XCTAssertEqual(AtticPanelChromeMetrics.fold(reduceMotion: false), .timingCurve(0.3, 0.7, 0.2, 1, duration: 0.26))
        XCTAssertEqual(AtticPanelChromeMetrics.curve(0.2), .timingCurve(0.3, 0.7, 0.2, 1, duration: 0.2))
        // The chat's numbers, unchanged.
        XCTAssertEqual(AtticChatMotion.opening, 0.62)
        XCTAssertEqual(AtticChatMotion.closing, 0.40)
        // Unchanged: the page slide's spring, the sweep, the Reduced fade.
        XCTAssertEqual(AtticMotionTuning.lively.slide, AtticMotionSpring(response: 0.28, bounce: 0.12))
        XCTAssertEqual(AtticMotionTuning.lively.complete, AtticMotionSpring(response: 0.20, bounce: 0.12))
        XCTAssertEqual(AtticMotionScale.reducedFade, .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.12))
    }

    /// 30 ms apart, never past 240 ms; none when motion is reduced.
    func testStaggerIsCapped() {
        XCTAssertEqual(AtticMotionScale.stagger(index: 0, reduceMotion: false), 0)
        XCTAssertEqual(AtticMotionScale.stagger(index: 1, reduceMotion: false), 0.03, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionScale.stagger(index: 3, reduceMotion: false), 0.09, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionScale.stagger(index: 8, reduceMotion: false), 0.24, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionScale.stagger(index: 40, reduceMotion: false), 0.24, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionScale.stagger(index: 5, reduceMotion: true), 0)
    }

    /// The tick lands on pop; the sweep keeps `complete`.
    func testTheTickLandsOnPop() {
        XCTAssertEqual(AtticStatusCircle.tickAnimation(reduceMotion: false, tuning: .lively), .spring(duration: 0.30, bounce: 0.28))
        XCTAssertEqual(AtticStatusCircle.tickAnimation(reduceMotion: false, tuning: .subtle), .spring(duration: 0.30, bounce: 0.04))
        XCTAssertEqual(AtticStatusCircle.tickAnimation(reduceMotion: true), AtticMotionScale.reducedFade)
        XCTAssertLessThan(AtticStatusCircle.tickStartScale, 1)
    }

    /// Press: 0.97 while held on a 0.20 s spring; nothing when reduced.
    func testPressIsOffWhenMotionIsReduced() {
        XCTAssertEqual(AtticMotionScale.pressedScale(pressed: true, reduceMotion: false), 0.97)
        XCTAssertEqual(AtticMotionScale.pressedScale(pressed: false, reduceMotion: false), 1)
        XCTAssertEqual(AtticMotionScale.pressedScale(pressed: true, reduceMotion: true), 1)
        XCTAssertEqual(AtticMotionScale.pressAnimation(reduceMotion: false), .spring(duration: 0.20, bounce: 0))
        XCTAssertNil(AtticMotionScale.pressAnimation(reduceMotion: true))
    }

    /// Delete: the row leaves on the eased-in exit at once; the list's
    /// move (the gap closing) starts 60 ms later.
    func testDeleteLeavesFirstThenTheGapCloses() {
        let travel = AtticMotionPreset.settle.animation(reduceMotion: false)
        XCTAssertEqual(AtticMotionScale.gapClose(travel, afterRowsLeave: true), travel?.delay(0.06))
        XCTAssertEqual(AtticMotionScale.gapClose(travel, afterRowsLeave: false), travel)
        XCTAssertNil(AtticMotionScale.gapClose(nil, afterRowsLeave: true))
    }

    /// The toast goes on a swipe down past 24 pt (or a flick), never up.
    func testTheToastSwipesDownToDismiss() {
        XCTAssertTrue(PanelToastSwipe.swipeDismisses(translation: 24, predicted: 24))
        XCTAssertTrue(PanelToastSwipe.swipeDismisses(translation: 10, predicted: 60))
        XCTAssertFalse(PanelToastSwipe.swipeDismisses(translation: 10, predicted: 20))
        XCTAssertFalse(PanelToastSwipe.swipeDismisses(translation: -40, predicted: -80))
    }

    /// A row picked up grows on `lift` and settles back as it lands; never
    /// when motion is reduced.
    func testAPickedUpRowLifts() {
        typealias Layer = TasksLiftedCardLayer<EmptyView>
        XCTAssertEqual(Layer.scale(raised: true, landed: false, reduceMotion: false), AtticMotionScale.liftScale)
        XCTAssertEqual(Layer.scale(raised: true, landed: true, reduceMotion: false), 1)
        XCTAssertEqual(Layer.scale(raised: true, landed: false, reduceMotion: true), 1)
        XCTAssertEqual(Layer.scale(raised: false, landed: false, reduceMotion: false), 1)
        XCTAssertEqual(Layer.liftAnimation, .spring(duration: 0.30, bounce: 0.18))
        let card = TasksLiftedCard()
        card.begin(id: UUID(), tab: .now, origin: CGRect(x: 0, y: 40, width: 300, height: 30))
        XCTAssertEqual(card.lift?.landed, false)
        card.land(at: 70)
        XCTAssertEqual(card.lift?.landed, true)
        card.begin(id: UUID(), tab: .now, origin: CGRect(x: 0, y: 40, width: 300, height: 30))
        XCTAssertEqual(card.lift?.landed, false, "a new pick-up starts lifted")
    }

    // MARK: - Reduced motion, both

    /// Instant (the default): pages and expansions at once, the rest fades.
    /// Fade: every movement becomes the 0.12 s fade.
    func testReducedFadeAndInstant() {
        AtticReducedMotionStyle.current = .instant
        XCTAssertEqual(AtticReducedMotionStyle.default, .instant)
        XCTAssertNil(AtticMotionPreset.pageSwitch.animation(reduceMotion: true))
        XCTAssertNil(AtticMotionPreset.expand.animation(reduceMotion: true))
        XCTAssertNil(AtticMotionScale.reducedChange)
        XCTAssertNil(AtticMotionScale.resolved(.easeOut(duration: 0.3), reduceMotion: true))
        XCTAssertEqual(PanelPageMotion.current(reduceMotion: true), .instant)
        XCTAssertNil(PanelPageMotion.current(reduceMotion: true).animation)
        XCTAssertEqual(AtticMotionPreset.popover.animation(reduceMotion: true), AtticMotionScale.reducedFade)

        AtticReducedMotionStyle.current = .fade
        XCTAssertEqual(AtticMotionPreset.pageSwitch.animation(reduceMotion: true), AtticMotionScale.reducedFade)
        XCTAssertEqual(AtticMotionPreset.expand.animation(reduceMotion: true), AtticMotionScale.reducedFade)
        XCTAssertEqual(AtticMotionPreset.expand.leaveAnimation(reduceMotion: true), AtticMotionScale.reducedFade)
        XCTAssertEqual(AtticMotionScale.resolved(.easeOut(duration: 0.3), reduceMotion: true), AtticMotionScale.reducedFade)
        let page = PanelPageMotion.current(reduceMotion: true)
        XCTAssertEqual(page, .fade)
        XCTAssertFalse(page.travels, "a faded switch never travels")
        XCTAssertEqual(page.restingOffset(side: 1, width: 400), 0)
        XCTAssertEqual(page.animation, AtticMotionScale.reducedFade)
        XCTAssertEqual(page.pageOpacityAnimation(incoming: true), AtticMotionScale.reducedFade)
        XCTAssertEqual(page.pageOpacityAnimation(incoming: false), AtticMotionScale.reducedFade)
        XCTAssertEqual(page.inPlaceOpacityAnimation(incoming: true), AtticMotionScale.reducedFade)
        // Nothing scales either way, and motion that isn't reduced is untouched.
        for preset in AtticMotionPreset.allCases {
            XCTAssertEqual(preset.hiddenScale(reduceMotion: true), 1, "\(preset)")
        }
        XCTAssertNotEqual(PanelPageMotion.current(reduceMotion: false), .fade)
        XCTAssertTrue(PanelPageMotion.current(reduceMotion: false).travels, "the slide stays")
        XCTAssertEqual(AtticMotionScale.resolved(.easeOut(duration: 0.3), reduceMotion: false), .easeOut(duration: 0.3))
    }

    func testReducedPickerCardsFadeOpacityForFadeAndAppearInstantlyForInstant() {
        AtticReducedMotionStyle.current = .fade
        XCTAssertEqual(AtticDropdownReveal.reducedOpacityAnimation(reduceMotion: true), AtticMotionScale.reducedFade,
                       "the picker and unfold cards must fade for 0.12 s")
        AtticReducedMotionStyle.current = .instant
        XCTAssertNil(AtticDropdownReveal.reducedOpacityAnimation(reduceMotion: true),
                     "the current Instant behavior remains")
        AtticReducedMotionStyle.current = .fade
        XCTAssertNil(AtticDropdownReveal.reducedOpacityAnimation(reduceMotion: false),
                     "the standard spring/unfold path must remain unchanged")
    }

    /// The choice persists like the other appearance settings; the row
    /// shows only while motion is reduced.
    func testTheReducedChoicePersistsAndShowsOnlyWhenReduced() throws {
        let suite = "LoamMotionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            AtticMotionPreference.level = .lively
        }
        let settings = AppSettings(defaults: defaults, motionLabAvailable: false)
        XCTAssertEqual(settings.reducedMotionStyle, .instant)
        settings.reducedMotionStyle = .fade
        XCTAssertEqual(defaults.string(forKey: "reducedMotionStyle"), "fade")
        XCTAssertEqual(AtticReducedMotionStyle.current, .fade)
        AtticReducedMotionStyle.current = .instant
        let reopened = AppSettings(defaults: defaults, motionLabAvailable: false)
        XCTAssertEqual(reopened.reducedMotionStyle, .fade)
        XCTAssertEqual(AtticReducedMotionStyle.current, .fade, "loading applies the stored choice")

        XCTAssertFalse(GeneralSettingsView.showsReducedStyle(level: .lively, systemReduceMotion: false))
        XCTAssertFalse(GeneralSettingsView.showsReducedStyle(level: .subtle, systemReduceMotion: false))
        XCTAssertTrue(GeneralSettingsView.showsReducedStyle(level: .reduced, systemReduceMotion: false))
        XCTAssertTrue(GeneralSettingsView.showsReducedStyle(level: .lively, systemReduceMotion: true))
        XCTAssertEqual(AtticReducedMotionStyle.allCases.map(\.title), ["Instant", "Fade"])
    }
}
