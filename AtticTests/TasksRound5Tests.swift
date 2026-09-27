import AppKit
import XCTest
@testable import Attic

/// Round 5: the owner's items after the round 4 preview.
@MainActor
final class TasksRound5Tests: XCTestCase {
    // MARK: - An open picker is edit mode (the owner's item 2)

    func testEditModeHoldsThePanelUntilItClosesThenAShortGrace() async throws {
        var applied: [Bool] = []
        let hold = PanelEditHold(grace: .milliseconds(80)) { applied.append($0) }
        hold.set(true)
        hold.set(true)
        XCTAssertEqual(applied, [true], "one lock however many things are open")
        hold.set(false)
        XCTAssertTrue(hold.isHeld, "closing starts the grace; the panel is still held")
        XCTAssertEqual(applied, [true])
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(applied, [true, false], "after the grace the hover rules resume")
        XCTAssertFalse(hold.isHeld)

        // Something opens again within the grace: the hold never lapses.
        hold.set(true)
        hold.set(false)
        try await Task.sleep(for: .milliseconds(20))
        hold.set(true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(applied, [true, false, true], "no release while a second picker is open")
        hold.end()
        XCTAssertEqual(applied, [true, false, true, false], "hiding ends it with no grace")
    }

    func testTheEditingLockNeverLapsesLikeTypingFocus() {
        // Typing focus alone lapses once the pointer is out and the
        // keyboard idle; edit mode (a picker, an editor) does not.
        XCTAssertFalse(MainPanelAutoHidePolicy.isInteractionLocked(
            reasons: [.quickEntryFocus], pointerInside: false, secondsSinceKeyboardInput: 60))
        XCTAssertTrue(MainPanelAutoHidePolicy.isInteractionLocked(
            reasons: [.taskEditing], pointerInside: false, secondsSinceKeyboardInput: 60))
        XCTAssertTrue(MainPanelAutoHidePolicy.isInteractionLocked(
            reasons: [.quickEntryFocus, .taskEditing], pointerInside: false, secondsSinceKeyboardInput: 60))
    }

    // MARK: - One swipe, one page (the owner's item 4)

    func testASwipeMovesAtMostOnePage() {
        let width: CGFloat = 320
        func land(_ x: CGFloat, from current: Int) -> Int {
            TasksPagerBehavior.page(proposed: x, width: width, current: current, count: 3)
        }
        XCTAssertEqual(land(2 * width, from: 0), 1, "a hard swipe from Now stops at Later")
        XCTAssertEqual(land(10 * width, from: 0), 1, "however far the momentum would carry it")
        XCTAssertEqual(land(0, from: 2), 1, "from Done, back to Later, not Now")
        XCTAssertEqual(land(-5 * width, from: 1), 0)
        XCTAssertEqual(land(width * 0.4, from: 0), 0, "a short drag settles back")
        XCTAssertEqual(land(width * 0.6, from: 0), 1, "past halfway it turns the page")
        XCTAssertEqual(land(3 * width, from: 2), 2, "never past the last page")
        XCTAssertEqual(land(-width, from: 0), 0, "nor before the first")
        XCTAssertEqual(TasksPagerBehavior.page(proposed: 500, width: 0, current: 1, count: 3), 1, "no width yet: stay")
    }

    // MARK: - F4: a drag's eligibility is decided at the press

    func testATitlePressStaysADragAsTheRowMovesPastItsControls() {
        let session = TasksDragSession()
        let row = UUID()
        // The checklist, in the row's own space (Astra's geometry).
        session.controlFrames[row] = [CGRect(x: 56, y: 26, width: 40, height: 16)]
        var origin = CGPoint(x: 12, y: 200)
        var decisions = 0
        let decide: (CGPoint) -> Bool = { point in
            decisions += 1
            return !session.isOnControl(row, at: point, rowOrigin: origin)
        }
        let press = CGPoint(x: 80, y: 210)   // on the title line, above the checklist
        XCTAssertTrue(session.allows(row, start: press, decide: decide), "a title press drags")
        // The row lifts and travels up (and the list scrolls): measured
        // now, the same press point would fall on the checklist.
        origin = CGPoint(x: 12, y: 180)
        XCTAssertTrue(session.isOnControl(row, at: press, rowOrigin: origin), "the geometry that used to stop the drag")
        for _ in 0..<5 { XCTAssertTrue(session.allows(row, start: press, decide: decide), "updates keep the press's answer") }
        XCTAssertTrue(session.allows(row, start: press, decide: decide), "and so does the release")
        XCTAssertEqual(decisions, 1, "decided once, at the press")
        session.end()

        // The next press is decided afresh: with the row now at y 180,
        // this one is on the checklist.
        XCTAssertEqual(origin, CGPoint(x: 12, y: 180))
        XCTAssertFalse(session.allows(row, start: CGPoint(x: 80, y: 214), decide: decide), "a press on a control never drags")
        origin = CGPoint(x: 12, y: 230)
        XCTAssertFalse(session.allows(row, start: CGPoint(x: 80, y: 214), decide: decide), "however the row moves after")
        XCTAssertEqual(decisions, 2)
        session.end()
    }
}
