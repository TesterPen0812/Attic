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
}
