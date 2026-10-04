import AppKit
import XCTest
@testable import Attic

/// Part 2 A (owner-approved, 2026-10-01): a two-finger swipe toward the edge
/// of the screen the panel lives on closes it, wherever that swipe has no
/// other job: over the header and the controls, over empty space, and past
/// the last page that way, pinned or not (owner, 2026-10-02). A pull with
/// resistance and a threshold; never from momentum.
@MainActor
final class SwipeToCloseTests: XCTestCase {
    // MARK: Direction

    func testOnlyASwipeTowardThePanelsEdgePastTheLastPageClosesIt() {
        typealias Swipe = TasksPagerSwipe
        // Natural scrolling: the content follows the fingers; a positive dx
        // is the fingers moving right, toward the page before.
        XCTAssertTrue(Swipe.closesPanel(dx: 10, dy: 0, inverted: true, shown: 0, count: 3, corner: .topRight),
                      "right-docked, on Now, fingers right: nothing before Now")
        XCTAssertFalse(Swipe.closesPanel(dx: 10, dy: 0, inverted: true, shown: 1, count: 3, corner: .topRight),
                       "on Later the swipe goes to Now")
        XCTAssertFalse(Swipe.closesPanel(dx: -10, dy: 0, inverted: true, shown: 2, count: 3, corner: .topRight),
                       "away from the edge never closes")
        XCTAssertTrue(Swipe.closesPanel(dx: -10, dy: 0, inverted: true, shown: 2, count: 3, corner: .bottomLeft),
                      "left-docked, on Done, fingers left: nothing after Done")
        XCTAssertFalse(Swipe.closesPanel(dx: -10, dy: 0, inverted: true, shown: 1, count: 3, corner: .bottomLeft))
        // Without natural scrolling the same fingers report the other sign.
        XCTAssertTrue(Swipe.closesPanel(dx: -10, dy: 0, inverted: false, shown: 2, count: 3, corner: .topRight),
                      "right-docked, fingers right, classic scrolling: toward Done's end")
        XCTAssertFalse(Swipe.closesPanel(dx: 10, dy: 30, inverted: true, shown: 0, count: 3, corner: .topRight),
                       "a mostly vertical swipe is the list's")
    }

    // MARK: The pager hands its end over

    private func pager(corner: ScreenCorner? = .topRight) -> TasksPagerSwipe {
        let swipe = TasksPagerSwipe(count: 3)
        swipe.width = 300
        swipe.closeCorner = { corner }
        return swipe
    }

    func testAtTheLastPageThatWayThePagerHandsTheSwipeToThePanel() {
        let swipe = pager()
        XCTAssertEqual(swipe.handle(.init(phase: .began, time: 1, inverted: true), shown: 0, allowed: true), .pass)
        let first = swipe.handle(.init(phase: .changed, dx: 8, time: 1.01, inverted: true), shown: 0, allowed: true)
        XCTAssertFalse(first.consumes, "the panel sees the pull")
        XCTAssertEqual(swipe.axis, .closing)
        XCTAssertFalse(swipe.handle(.init(phase: .changed, dx: 20, time: 1.02, inverted: true), shown: 0, allowed: true).consumes)
        XCTAssertFalse(swipe.handle(.init(phase: .ended, time: 1.03, inverted: true), shown: 0, allowed: true).consumes)
        XCTAssertFalse(swipe.ownsMomentum, "its momentum is not the pager's either (the panel ignores momentum)")
    }

    /// A pin no longer matters to the pager (the pager never knew it); a
    /// pager with no corner (a gallery's) leaves the end to the rubber band.
    func testAPagerWithNoPanelCornerOnlyRubberBands() {
        let swipe = pager(corner: nil)
        _ = swipe.handle(.init(phase: .began, time: 1, inverted: true), shown: 0, allowed: true)
        let first = swipe.handle(.init(phase: .changed, dx: 8, time: 1.01, inverted: true), shown: 0, allowed: true)
        XCTAssertTrue(first.consumes, "the pager keeps it: a rubber band")
        XCTAssertEqual(swipe.axis, .horizontal)
    }

    /// A page swipe that reaches the end and goes on is still the pager's:
    /// only a fresh gesture closes, and its momentum stays the pager's.
    func testAPageSwipeThatOverrunsTheEndNeverCloses() {
        let swipe = pager()
        _ = swipe.handle(.init(phase: .began, time: 1, inverted: true), shown: 1, allowed: true)
        XCTAssertTrue(swipe.handle(.init(phase: .changed, dx: 8, time: 1.01, inverted: true), shown: 1, allowed: true).consumes)
        // The live tab is Now by now; the fingers keep going.
        XCTAssertTrue(swipe.handle(.init(phase: .changed, dx: 400, time: 1.1, inverted: true), shown: 0, allowed: true).consumes)
        XCTAssertEqual(swipe.axis, .horizontal)
        _ = swipe.handle(.init(phase: .ended, time: 1.12, inverted: true), shown: 0, allowed: true)
        XCTAssertTrue(swipe.ownsMomentum)
        XCTAssertTrue(swipe.handle(.init(phase: .none, momentum: true, dx: 30, time: 1.2, inverted: true), shown: 0, allowed: true).consumes,
                      "its momentum is swallowed, never handed to the panel")
    }

    // MARK: The pull and its threshold

    func testThePullFollowsTheFingersWithResistance() {
        let width: CGFloat = 360
        var last: CGFloat = 0
        for distance in stride(from: CGFloat(10), through: 400, by: 10) {
            let resisted = PanelCollapseGeometry.resistedProgress(forSwipeDistance: distance, panelWidth: width)
            let plain = PanelCollapseGeometry.progress(forSwipeDistance: distance, panelWidth: width)
            XCTAssertLessThan(resisted, plain + 0.0001, "never ahead of the fingers at \(distance)")
            XCTAssertGreaterThan(resisted, last, "always following at \(distance)")
            last = resisted
        }
        XCTAssertEqual(PanelCollapseGeometry.resistedProgress(forSwipeDistance: 0, panelWidth: width), 0)
        XCTAssertEqual(PanelCollapseGeometry.reducedOpacity(progress: 0), 1)
        XCTAssertEqual(PanelCollapseGeometry.reducedOpacity(progress: 1), PanelCollapseGeometry.reducedMinimumOpacity, accuracy: 0.0001,
                       "Reduced fades instead")
    }

    func testAReleaseClosesPastADistanceOrAFlick() {
        typealias Tracker = PanelTrackpadDismissTracker
        XCTAssertFalse(Tracker.closes(progress: 30, velocity: 100), "a short, slow pull springs back")
        XCTAssertTrue(Tracker.closes(progress: 50, velocity: 0), "past the distance")
        XCTAssertTrue(Tracker.closes(progress: 16, velocity: 600), "a flick")
        XCTAssertFalse(Tracker.closes(progress: 4, velocity: 900), "a flick that has not moved yet")

        func run(_ deltas: [CGFloat], step: TimeInterval) -> PanelTrackpadDismissUpdate {
            var tracker = Tracker()
            var time: TimeInterval = 10
            var result = tracker.update(sample: .init(deltaX: 0, deltaY: 0, phase: .began, isPrecise: true,
                                                      isDirectionInvertedFromDevice: false, time: time), dockedCorner: .topRight)
            for delta in deltas {
                time += step
                result = tracker.update(sample: .init(deltaX: delta, deltaY: 0, phase: .changed, isPrecise: true,
                                                      isDirectionInvertedFromDevice: false, time: time), dockedCorner: .topRight)
            }
            time += step
            return tracker.update(sample: .init(deltaX: 0, deltaY: 0, phase: .ended, isPrecise: true,
                                                isDirectionInvertedFromDevice: false, time: time), dockedCorner: .topRight)
        }
        // Right-docked, classic scrolling: toward the edge is a negative dx.
        XCTAssertEqual(run(Array(repeating: -2, count: 10), step: 0.05), .passThrough, "20 pt, slowly: springs back")
        XCTAssertEqual(run(Array(repeating: -6, count: 10), step: 0.02), .requestHide, "60 pt: closes")
        XCTAssertEqual(run(Array(repeating: -5, count: 4), step: 0.008), .requestHide, "a quick 20 pt flick: closes")
        XCTAssertEqual(run(Array(repeating: 6, count: 10), step: 0.02), .passThrough, "away from the edge: never")
    }

    // MARK: The panel: momentum, pinned, and its own surfaces

    private func scroll(_ dx: Int32, phase: Int64, momentum: Int64 = 0, at point: CGPoint) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.location = point
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func panel() -> (AtticPanel, () -> Int) {
        let panel = AtticPanel(contentRect: CGRect(x: -5_000, y: -5_000, width: 320, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        panel.trackpadDismissCorner = .topRight
        var requests = 0
        panel.onTrackpadDismissRequest = { requests += 1 }
        return (panel, { requests })
    }

    /// Phases: 1 began, 2 changed, 4 ended. Momentum: 1 begin, 2 continue, 3 end.
    func testAFreshPullClosesPinnedOrNotButMomentumNever() throws {
        let point = CGPoint(x: 10, y: 10)
        // A fresh gesture toward the right edge (classic scrolling: negative).
        do {
            let (panel, requests) = panel()
            defer { panel.close() }
            panel.sendEvent(try scroll(0, phase: 1, at: point))
            for _ in 0..<12 { panel.sendEvent(try scroll(-6, phase: 2, at: point)) }
            panel.sendEvent(try scroll(0, phase: 4, at: point))
            XCTAssertEqual(requests(), 1, "a fresh pull past the threshold closes")
        }
        // The same movement arriving only as momentum (a page swipe's).
        do {
            let (panel, requests) = panel()
            defer { panel.close() }
            panel.sendEvent(try scroll(-6, phase: 0, momentum: 1, at: point))
            for _ in 0..<12 { panel.sendEvent(try scroll(-6, phase: 0, momentum: 2, at: point)) }
            panel.sendEvent(try scroll(0, phase: 0, momentum: 3, at: point))
            XCTAssertEqual(requests(), 0, "momentum never closes")
        }
        // A vertical scroll.
        do {
            let (panel, requests) = panel()
            defer { panel.close() }
            let up = { (dy: Int32, phase: Int64) throws -> NSEvent in
                let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: -1, wheel3: 0))
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                event.location = point
                return try XCTUnwrap(NSEvent(cgEvent: event))
            }
            panel.sendEvent(try up(0, 1))
            for _ in 0..<12 { panel.sendEvent(try up(-8, 2)) }
            panel.sendEvent(try up(0, 4))
            XCTAssertEqual(requests(), 0, "vertical scrolling is the list's")
        }
    }
}
