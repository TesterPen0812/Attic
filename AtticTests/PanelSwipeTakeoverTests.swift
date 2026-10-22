import AppKit
import XCTest
@testable import Attic

/// Owner, 2026-10-22: a second swipe started while a swipe's release motion
/// (its close or its spring-back) is still running picks the panel up from
/// wherever that motion has it, with its speed, either way; and a release
/// closes on its projected travel (distance plus the flick's coast) rather
/// than on a 450 pt/s flick threshold. The 12 pt twitch guard and the
/// intent distance are unchanged; timed hides and reveals are never taken
/// over.
@MainActor
final class PanelSwipeTakeoverTests: XCTestCase {
    private typealias Tracker = PanelTrackpadDismissTracker

    // MARK: Flick projection

    /// Right-docked, classic scrolling (toward the edge is a negative dx),
    /// events at 120 Hz like a trackpad, then `still` frames at rest.
    private func release(distance: CGFloat, speed: CGFloat, still: Int = 0,
                         takeover: PanelSwipeTakeover? = nil, away: Bool = false) -> PanelTrackpadDismissUpdate {
        var tracker = Tracker()
        let step: TimeInterval = 1.0 / 120
        var time: TimeInterval = 100
        var deltas: [CGFloat] = []
        var left = distance
        while left > 0.01 { let delta = min(speed * CGFloat(step), left); deltas.append(delta); left -= delta }
        deltas += Array(repeating: 0, count: still)
        _ = tracker.update(sample: .init(deltaX: 0, deltaY: 0, phase: .began, isPrecise: true,
                                         isDirectionInvertedFromDevice: false, time: time), dockedCorner: .topRight)
        for delta in deltas {
            time += step
            _ = tracker.update(sample: .init(deltaX: away ? delta : -delta, deltaY: 0, phase: .changed, isPrecise: true,
                                             isDirectionInvertedFromDevice: false, time: time),
                               dockedCorner: .topRight, takeover: takeover)
        }
        time += step
        return tracker.update(sample: .init(deltaX: 0, deltaY: 0, phase: .ended, isPrecise: true,
                                            isDirectionInvertedFromDevice: false, time: time),
                              dockedCorner: .topRight, takeover: takeover)
    }

    /// Flicks just under the old 450 pt/s threshold short of 48 pt sprang
    /// back; a little faster closed (g6: 43 pt at 458 pt/s went either
    /// way). Projected, they all close.
    func testABorderlineFlickProjectsToClosed() {
        for (distance, speed) in [(CGFloat(43), CGFloat(430)), (35, 440), (40, 445), (47, 430)] {
            XCTAssertEqual(release(distance: distance, speed: speed), .requestHide, "\(distance) pt at \(speed) pt/s")
        }
        for (distance, speed) in [(CGFloat(35), CGFloat(470)), (43, 458), (47, 470)] {
            XCTAssertEqual(release(distance: distance, speed: speed), .requestHide, "\(distance) pt at \(speed) pt/s")
        }
    }

    func testASlowDragThatStopsShortSpringsBack() {
        XCTAssertEqual(release(distance: 45, speed: 200, still: 8), .passThrough, "45 pt, then the fingers rest")
        XCTAssertEqual(release(distance: 30, speed: 600, still: 8), .passThrough)
        XCTAssertEqual(release(distance: 20, speed: 60), .passThrough, "a slow, short drag")
        XCTAssertEqual(release(distance: 50, speed: 200, still: 8), .requestHide, "past 48 pt it still closes at rest")
        // The twitch guard: under 12 pt nothing closes, however fast.
        XCTAssertEqual(release(distance: 10, speed: 1200), .passThrough)
        XCTAssertFalse(Tracker.closes(progress: 11, velocity: 5000))
    }

    /// UIKit's projection, v/1000 · r/(1 − r), at its `.fast` rate.
    func testTheProjectionIsUIKitsFastDeceleration() {
        XCTAssertEqual(Tracker.decelerationRate, 0.99)
        XCTAssertEqual(Tracker.projectedCoast(velocity: 1000), 99, accuracy: 0.01)
        XCTAssertEqual(Tracker.projectedCoast(velocity: 0), 0)
        XCTAssertTrue(Tracker.closes(progress: 13, velocity: 364), "a 12 pt flick closes near the old 450 pt/s")
        XCTAssertFalse(Tracker.closes(progress: 13, velocity: 340))
        XCTAssertFalse(Tracker.closes(progress: 60, velocity: -200), "flung back from past the distance: springs back")
    }

    // MARK: Takeover, as the tracker decides it

    func testATakeoverGoesEitherWayAndDecidesOnThePanelsPosition() {
        let closing = PanelSwipeTakeover(progress: 0.6, velocity: 3, panelWidth: 320)
        let springingBack = PanelSwipeTakeover(progress: 0.05, velocity: -1, panelWidth: 320)
        // A fresh swipe away from the edge is the content's; a takeover's is not.
        XCTAssertEqual(release(distance: 120, speed: 400, still: 8, away: true), .passThrough)
        XCTAssertEqual(release(distance: 200, speed: 600, takeover: closing, away: true), .passThrough,
                       "pulled back from a close: it springs open")
        XCTAssertEqual(release(distance: 2, speed: 100, still: 8, takeover: closing), .requestHide,
                       "caught closing and let go: it carries on closing")
        XCTAssertEqual(release(distance: 4, speed: 600, takeover: springingBack), .passThrough,
                       "a twitch on a spring-back never closes")
        XCTAssertEqual(release(distance: 60, speed: 500, takeover: springingBack), .requestHide,
                       "swiped again past the distance: it closes")
        XCTAssertEqual(release(distance: 30, speed: 450, takeover: springingBack), .requestHide,
                       "or flicked again")
    }

    func testTheCarriedSpeedStartsAtTheMotionsAndDiesAway() {
        let velocity: CGFloat = 4
        XCTAssertEqual(PanelSwipeTakeover.carry(velocity: velocity, elapsed: 0), 0)
        let step = 0.0005
        XCTAssertEqual(PanelSwipeTakeover.carry(velocity: velocity, elapsed: step) / CGFloat(step), velocity, accuracy: 0.1,
                       "starts at the motion's speed")
        let peak = (1...300).map { PanelSwipeTakeover.carry(velocity: velocity, elapsed: Double($0) / 1000) }.max() ?? 0
        XCTAssertLessThan(peak, 0.07, "a small overrun, not a second motion")
        XCTAssertTrue(PanelSwipeTakeover.carryHasEnded(velocity: velocity, elapsed: 0.4))
        XCTAssertFalse(PanelSwipeTakeover.carryHasEnded(velocity: velocity, elapsed: 0.02))
    }

    func testTheFollowStartsWhereTheMotionHadThePanel() {
        for start in [CGFloat(0), 0.1, 0.5, 0.9] {
            XCTAssertEqual(PanelCollapseGeometry.followProgress(from: start, distance: 0, panelWidth: 320), start, accuracy: 0.0001)
            XCTAssertGreaterThan(PanelCollapseGeometry.followProgress(from: start, distance: 20, panelWidth: 320), start)
            XCTAssertLessThan(PanelCollapseGeometry.followProgress(from: start, distance: 400, panelWidth: 320), 1)
        }
        XCTAssertEqual(PanelCollapseGeometry.followProgress(from: 0.6, distance: -PanelCollapseGeometry.openingTravel(panelWidth: 320),
                                                            panelWidth: 320), 0, accuracy: 0.0001, "one travel back opens it")
        // A fresh swipe is the pull, unchanged.
        for distance in [CGFloat(10), 48, 150] {
            XCTAssertEqual(PanelCollapseGeometry.followProgress(from: 0, distance: distance, panelWidth: 320),
                           PanelCollapseGeometry.resistedProgress(forSwipeDistance: distance, panelWidth: 320), accuracy: 0.0001)
        }
    }

    // MARK: Takeover on a real panel (Slide, main's default, and Swoop)

    private struct Rig {
        let controller: AtticPanelController
        let panel: AtticPanel
        let settings: AppSettings
        let defaults: UserDefaults
        let suite: String
    }

    private func makeRig(_ mode: PanelHideAnimation) throws -> Rig {
        let suite = "PanelSwipeTakeoverTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let persistence = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: persistence)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: persistence, attachmentFileStore: makeTestAttachmentFileStore()))
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let settings = AppSettings(defaults: defaults)
        settings.hideAnimation = mode
        let controller = AtticPanelController(
            store: store, noteStore: notes, canvasSession: CanvasSession(store: CanvasStore(container: persistence)),
            noteDraft: NoteDraftController(noteStore: notes), settings: settings, uiState: PanelUIState()
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        let screen = try XCTUnwrap(controller.currentScreen ?? NSScreen.main)
        XCTAssertTrue(controller.show(on: screen, corner: .topRight))
        // The reveal is a timed motion, which no swipe takes over: let it
        // end (CI's runners are slower than 0.5 s).
        let probe = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0))
        let deadline = Date().addingTimeInterval(5)
        spin(0.3)
        while panel.canBeginTrackpadSwipe?(probe) != true, Date() < deadline { spin(0.05) }
        XCTAssertEqual(panel.canBeginTrackpadSwipe?(probe), true, "the reveal has ended")
        spin(0.2)
        return Rig(controller: controller, panel: panel, settings: settings, defaults: defaults, suite: suite)
    }

    private func close(_ rig: Rig) {
        rig.panel.orderOut(nil)
        rig.defaults.removePersistentDomain(forName: rig.suite)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Phases: 1 began, 2 changed, 4 ended. Right-docked: a negative `dx`
    /// is toward the edge with classic scrolling; natural scrolling (CI's
    /// runners) reports the other sign, so it is flipped there. Over the
    /// header, like a real swipe.
    private func send(_ dx: Int32, phase: Int64, to panel: AtticPanel) throws {
        func event(_ dx: Int32) throws -> CGEvent {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            let point = CGPoint(x: panel.frame.width / 2, y: panel.frame.height - AtticStyle.panelElevationMargin - 20)
            let screen = panel.convertPoint(toScreen: point)
            event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            return event
        }
        let inverted = try XCTUnwrap(NSEvent(cgEvent: try event(1))).isDirectionInvertedFromDevice
        panel.sendEvent(try XCTUnwrap(NSEvent(cgEvent: try event(inverted ? -dx : dx))))
    }

    /// A gesture at 120 Hz: `steps` events of `dx` each, `still` resting
    /// events, then (unless `lifts` is false) the lift.
    private func swipe(_ dx: Int32, steps: Int, still: Int = 0, lifts: Bool = true, on panel: AtticPanel) throws {
        try send(0, phase: 1, to: panel)
        for _ in 0..<steps { spin(1.0 / 120); try send(dx, phase: 2, to: panel) }
        for _ in 0..<still { spin(1.0 / 120); try send(0, phase: 2, to: panel) }
        guard lifts else { return }
        spin(1.0 / 120)
        try send(0, phase: 4, to: panel)
    }

    /// A pull of 40 pt that rests and lifts springs back; a new swipe toward
    /// the edge during that spring picks the panel up where the spring has
    /// it (no jump), follows the fingers from there, and closes on release.
    func testANewSwipeTakesOverTheSpringBackFromWhereItIs() throws {
        for mode in [PanelHideAnimation.slide, .swoop] {
            let rig = try makeRig(mode)
            defer { close(rig) }
            try swipe(-5, steps: 8, still: 8, on: rig.panel)
            spin(0.04)
            let springing = rig.controller.displayedProgressForProbe
            XCTAssertTrue(rig.panel.isVisible, "\(mode)")
            XCTAssertGreaterThan(springing, 0.005, "\(mode): the spring-back is still running")
            // The new swipe's first event.
            try send(0, phase: 1, to: rig.panel)
            try send(-1, phase: 2, to: rig.panel)
            let caught = rig.controller.displayedProgressForProbe
            XCTAssertEqual(caught, springing, accuracy: 0.03, "\(mode): picked up where the spring had it")
            for _ in 0..<20 { spin(1.0 / 120); try send(-6, phase: 2, to: rig.panel) }
            let followed = rig.controller.displayedProgressForProbe
            XCTAssertGreaterThan(followed, springing + 0.1, "\(mode): the new swipe drives the panel")
            spin(1.0 / 120)
            try send(0, phase: 4, to: rig.panel)
            let deadline = Date().addingTimeInterval(3)
            while rig.panel.isVisible, Date() < deadline { spin(0.02) }
            XCTAssertFalse(rig.panel.isVisible, "\(mode): released past the distance, it closes")
        }
    }

    /// A swipe released to close, then swiped back the other way while the
    /// close is still running: the panel reverses and springs open.
    func testAReSwipeTheOtherWayReversesAClose() throws {
        for mode in [PanelHideAnimation.slide, .swoop] {
            let rig = try makeRig(mode)
            defer { close(rig) }
            try swipe(-8, steps: 12, on: rig.panel)
            spin(0.03)
            XCTAssertTrue(rig.panel.isVisible, "\(mode): still closing")
            let closing = rig.controller.displayedProgressForProbe
            try send(0, phase: 1, to: rig.panel)
            try send(2, phase: 2, to: rig.panel)
            XCTAssertEqual(rig.controller.displayedProgressForProbe, closing, accuracy: 0.05, "\(mode): no jump")
            for _ in 0..<30 { spin(1.0 / 120); try send(8, phase: 2, to: rig.panel) }
            XCTAssertLessThan(rig.controller.displayedProgressForProbe, closing, "\(mode): it comes back")
            spin(1.0 / 120)
            try send(0, phase: 4, to: rig.panel)
            spin(1.0)
            XCTAssertTrue(rig.panel.isVisible, "\(mode): the close was taken back")
            XCTAssertEqual(rig.controller.displayedProgressForProbe, 0, accuracy: 0.01, "\(mode): fully open again")
        }
    }

    /// The window server sends events through a window's clear pixels, and
    /// Slide's close leaves the fingers' point within about 50 ms: while a
    /// release motion runs (only then) the panel's whole area takes a new
    /// swipe's first event.
    func testTheWholePanelTakesASwipeStartOnlyWhileAReleaseRuns() throws {
        let rig = try makeRig(.slide)
        defer { close(rig) }
        let content = try XCTUnwrap(rig.panel.contentView as? AtticPanelContentContainer)
        XCTAssertFalse(content.catchesSwipeStarts, "at rest")
        try swipe(-8, steps: 12, on: rig.panel)
        XCTAssertTrue(content.catchesSwipeStarts, "while the release closes it")
        let deadline = Date().addingTimeInterval(3)
        while rig.panel.isVisible, Date() < deadline { spin(0.02) }
        XCTAssertFalse(content.catchesSwipeStarts, "once hidden")
        let screen = try XCTUnwrap(rig.controller.currentScreen ?? NSScreen.main)
        XCTAssertTrue(rig.controller.show(on: screen, corner: .topRight))
        XCTAssertFalse(content.catchesSwipeStarts, "a reveal is no release")
        spin(0.8)
        _ = rig.controller.requestHide { _ in }
        XCTAssertFalse(content.catchesSwipeStarts, "nor is a timed hide")
    }

    /// Escape or the shortcut hides on a timed motion: a swipe never takes
    /// that over.
    func testATimedHideIsNeverTakenOver() throws {
        let rig = try makeRig(.slide)
        defer { close(rig) }
        var hidden = false
        _ = rig.controller.requestHide { hidden = $0 == .hidden }
        spin(0.03)
        try swipe(4, steps: 20, on: rig.panel)
        let deadline = Date().addingTimeInterval(3)
        while !hidden, Date() < deadline { spin(0.02) }
        XCTAssertTrue(hidden, "the timed hide finishes")
        XCTAssertFalse(rig.panel.isVisible)
    }
}
