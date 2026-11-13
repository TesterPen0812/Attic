import AppKit
import XCTest

/// A real drag out of the Tasks page (GPT-6.1's review of `ae84d1c`): the
/// row leaves the window, AppKit's dragging session begins, and the release
/// over the preview's unregistered no-drop target ends it with no operation.
/// Finder can take even a desktop drop as a promised text file (fbbdc9a8).
/// Nothing moves, nothing is saved, and a click still selects a
/// row afterwards. The page reports the sessions it began and ended under
/// `ATTIC_UI_TESTING` (`tasks-drag-out-state`).
///
/// What this does not cover (code review): XCUITest drags in one stroke, so
/// Esc cannot be pressed mid-drag, and nothing here receives a drop, so a
/// copy delivered to another app is not checked. Both stay with the
/// hands-on acceptance.
final class TasksDragOutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchArguments += ["--attic-gallery", "--attic-tasks-page", "--attic-drag-no-drop-target"]
        app.launch()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !window.exists {
            app.activate()
            _ = window.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(row("Book dentist").waitForExistence(timeout: 5), "the demo tasks are listed")
        XCTAssertTrue(noDropTarget.waitForExistence(timeout: 5), "the non-accepting drag destination is present")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private var window: XCUIElement { app.windows["Attic Tasks Page"] }
    private var noDropTarget: XCUIElement { app.windows["Attic No-Drop Target"] }

    private func row(_ title: String) -> XCUIElement {
        window.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    private var state: String {
        let element = window.descendants(matching: .any).matching(identifier: "tasks-drag-out-state").firstMatch
        return element.exists ? (element.value as? String ?? element.label) : ""
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    func testADragOutEndedOverNothingLeavesThePageAsItWas() throws {
        XCTAssertEqual(state, "began 0 ended 0")
        // Accepted 2026-10-29 "Tasks: Later is the backlog": date groups
        // put Tomorrow (Book) before the later date (Email) and No date.
        let order = ["Book dentist", "Email beta testers", "Call the plumber"].map { row($0).frame.minY }
        XCTAssertEqual(order, order.sorted(), "the demo order")
        // Out of the Tasks window to a window in the same app that never
        // accepts a drag. The desktop itself accepts promised task files.
        let from = row("Book dentist").coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        let target = noDropTarget.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: target, withVelocity: .default, thenHoldForDuration: 0.8)
        waitFor(state.hasPrefix("began 1"), "AppKit's session began (\(state))")
        waitFor(state.hasPrefix("began 1 ended 1"), "and ended, with nothing dropped (\(state))")
        // O17-12: the card started home from where it was let go, so the
        // release point lies on it (it was held by it), on screen; the
        // session's own frame for it (reported) is evidence only.
        let numbers = state.split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
        XCTAssertGreaterThanOrEqual(numbers.count, 6, "the start and release are reported (\(state))")
        if numbers.count >= 6 {
            let start = CGPoint(x: numbers[2], y: numbers[3]), release = CGPoint(x: numbers[4], y: numbers[5])
            XCTAssertTrue(release.x > start.x && release.x < start.x + 420 && release.y > start.y && release.y < start.y + 120,
                          "the card starts home under the pointer that let it go (\(state))")
            print("O17-12 evidence: \(state)")
        }
        let after = ["Book dentist", "Email beta testers", "Call the plumber"].map { row($0).frame.minY }
        XCTAssertEqual(after, after.sorted(), "nothing moved")
        // The page goes on: a click selects a row.
        row("Call the plumber").coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 16)).click()
        waitFor(row("Call the plumber").isSelected, "a click selects a row afterwards")
    }
}
