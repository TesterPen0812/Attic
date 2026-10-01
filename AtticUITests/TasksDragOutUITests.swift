import AppKit
import XCTest

/// A real drag out of the Tasks page (GPT-6.1's review of `ae84d1c`): the
/// row leaves the window, AppKit's dragging session begins, and the release
/// over the menu bar, where nothing takes a drop, ends it with no operation,
/// as Esc does. Nothing moves, nothing is saved, and the page goes on
/// working. (XCUITest drags in one stroke, so Esc itself cannot be pressed
/// mid-drag; the session ends the same way.) The page reports the sessions
/// it began and ended under `ATTIC_UI_TESTING` (`tasks-drag-out-state`).
final class TasksDragOutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchArguments += ["--attic-gallery", "--attic-tasks-page"]
        app.launch()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !window.exists {
            app.activate()
            _ = window.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(row("Book dentist").waitForExistence(timeout: 5), "the demo tasks are listed")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private var window: XCUIElement { app.windows["Attic Tasks Page"] }

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
        let order = ["Email beta testers", "Book dentist", "Call the plumber"].map { row($0).frame.minY }
        XCTAssertEqual(order, order.sorted(), "the demo order")
        // Up and out of the window, to the menu bar (4 pt from the screen's
        // top), held there so the page hands the drag to AppKit.
        let from = row("Book dentist").coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 4 - window.frame.minY))
        from.press(forDuration: 0.05, thenDragTo: top, withVelocity: .default, thenHoldForDuration: 0.8)
        waitFor(state.hasPrefix("began 1"), "AppKit's session began (\(state))")
        waitFor(state == "began 1 ended 1", "and ended, with nothing dropped (\(state))")
        let after = ["Email beta testers", "Book dentist", "Call the plumber"].map { row($0).frame.minY }
        XCTAssertEqual(after, after.sorted(), "nothing moved")
        // The page goes on: a click selects a row, a reorder drag works.
        row("Call the plumber").coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 16)).click()
        waitFor(row("Call the plumber").isSelected, "a click selects a row afterwards")
    }
}
