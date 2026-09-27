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
}
