import AppKit
import XCTest

/// The Tasks page inside the real panel (not the standalone preview window):
/// the v9 title and page pill, a long title, the row quick look, the files
/// panel "Open page" leads to until task pages arrive, and a page kept
/// built behind another one taking no keys, clicks or VoiceOver.
/// The in-memory UI-test store holds the v9 mockup's tasks
/// (`ATTIC_UI_TEST_SEED=demo`).
final class TasksPanelUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_SEED"] = "demo"
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["panel-pin-button"].waitForExistence(timeout: 5))
        XCTAssertTrue(row("Book dentist").waitForExistence(timeout: 5), "the demo tasks are listed")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: - Helpers

    /// A task row, found by the start of what VoiceOver reads for it.
    private func row(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    private func element(_ identifierPrefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix)).firstMatch
    }

    private var addBar: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "AtticTokenField").firstMatch
    }

    private var pageTitle: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tasks-page-title").firstMatch
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// The row's status circle: 16 pt at x = 20, on the title line.
    private func circle(_ title: String) -> XCUICoordinate {
        row(title).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: 17))
    }

    // MARK: - Title and page pill

    func testTheTitleAndPagePillMoveBetweenTasksBacklogAndDone() throws {
        XCTAssertTrue(pageTitle.waitForExistence(timeout: 3))
        XCTAssertEqual(pageTitle.label, "Tasks")
        let pill = app.descendants(matching: .any)["tasks-page-pill"]
        XCTAssertTrue(pill.exists, "the page pill is one control")
        for (page, title, task) in [("backlog", "Backlog", "Plan the spring trip"), ("done", "Done", "Send invoice"),
                                    ("now", "Tasks", "Book dentist")] {
            let choice = app.buttons["tasks-page-\(page)"]
            XCTAssertTrue(choice.exists, "\(title) is one of the pill's named choices")
            choice.click()
            waitFor(pageTitle.label == title, "the title reads \(title)")
            waitFor(row(task).exists, "\(title) lists its tasks")
            XCTAssertTrue(choice.isSelected, "\(title) reads as the selected choice")
        }
        // Only the page shown is read: the other pages built for the swipe
        // are hidden from VoiceOver.
        XCTAssertFalse(row("Plan the spring trip").exists)
    }

    // MARK: - Long title

    /// A long title stays on one line at the row's normal height, and the
    /// whole title is the row's accessibility label.
    func testALongTitleStaysOnOneRowAndIsReadInFull() throws {
        let longTitle = "A long task title that must stay on a single row and fade at the trailing edge instead of wrapping"
        XCTAssertTrue(addBar.waitForExistence(timeout: 3))
        addBar.click()
        app.typeText("Short\r")
        waitFor(row("Short").exists, "the short task is listed")
        app.typeText(longTitle + "\r")
        waitFor(row(longTitle).exists, "the full title is the row's accessibility label")
        XCTAssertEqual(row(longTitle).frame.height, row("Short").frame.height, accuracy: 1,
                       "a long title never makes the row taller")
        XCTAssertEqual(row(longTitle).frame.width, row("Short").frame.width, accuracy: 1,
                       "nor wider")
    }

    // MARK: - Quick look

    /// → opens the row's quick look; a subtask ticks; "Add subtask" adds
    /// one (Return, then Esc stops); Esc closes the quick look.
    func testTheQuickLookExpandsTicksAddsAndClosesWithEscape() throws {
        row("Ship appearance PR").click()
        app.typeKey(.rightArrow, modifierFlags: [])
        let merge = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Merge")).firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: 3), "the quick look lists the subtasks")
        XCTAssertEqual(merge.value as? String, "to do")

        merge.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 7, dy: 0)).click()
        waitFor((merge.value as? String) == "done", "its box ticks it")
        waitFor(row("Ship appearance PR").label.contains("3 of 4 subtasks"), "the row counts it")

        let add = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add subtask")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        app.typeText("Pack the charger\r")
        let added = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Pack the charger")).firstMatch
        waitFor(added.exists, "Return adds the subtask")
        app.typeKey(.escape, modifierFlags: [])

        row("Ship appearance PR").click()
        app.typeKey(.escape, modifierFlags: [])
        waitFor(!merge.exists, "Esc closes the quick look")
        XCTAssertTrue(app.buttons["panel-pin-button"].exists, "and nothing more")
    }

    // MARK: - Files panel

    /// "Open page" (⌘Return) opens the task's files in the old detail
    /// panel, with no way to its Subtasks editor; it pins, and Esc
    /// dismisses it without taking the main panel with it.
    func testOpenPageShowsTheFilesPanelThatPinsAndDismisses() throws {
        row("Book dentist").click()
        app.typeKey(.return, modifierFlags: .command)
        let transient = element("subtask-panel-")
        XCTAssertTrue(transient.waitForExistence(timeout: 3), "the files panel opens")
        XCTAssertTrue(element("add-attachment-").exists, "on the task's files")
        XCTAssertFalse(element("subtask-view-switch-").exists, "with no way to a second subtask editor")

        transient.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        for _ in 0..<3 where transient.exists {
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        waitFor(!transient.exists, "Esc dismisses it")
        XCTAssertTrue(app.buttons["panel-pin-button"].exists, "the main panel stays")

        row("Book dentist").click()
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(transient.waitForExistence(timeout: 3))
        let pin = element("subtask-pin-")
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        pin.click()
        let pinned = element("subtask-pinned-")
        XCTAssertTrue(pinned.waitForExistence(timeout: 3), "it pins into its own window")
        XCTAssertFalse(element("subtask-view-switch-").exists, "still files only")
        pinned.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        for _ in 0..<3 where pinned.exists {
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        waitFor(!pinned.exists, "Esc dismisses the pinned window too")
    }

    // MARK: - A page kept built behind another

    /// Tasks stays built behind Canvas: while hidden it takes no clicks, no
    /// keys and is not read by VoiceOver; back on Tasks, nothing changed.
    func testAHiddenTasksPageTakesNoKeysClicksOrVoiceOver() throws {
        XCTAssertTrue(addBar.waitForExistence(timeout: 3))
        addBar.click()
        app.typeText("Kept draft")
        let circlePoint = circle("Book dentist")

        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["canvas-surface"].waitForExistence(timeout: 5))
        waitFor(!row("Book dentist").exists, "VoiceOver does not read the hidden Tasks page")
        XCTAssertFalse(addBar.exists, "nor its add bar")

        circlePoint.click()                       // where the hidden circle is
        app.typeKey("9", modifierFlags: [])       // a key the hidden field must not take

        app.typeKey("1", modifierFlags: .command)
        waitFor(row("Book dentist").exists, "Tasks shows again")
        XCTAssertTrue(row("Book dentist").label.contains("to do"), "the click did not reach the hidden circle")
        XCTAssertEqual(addBar.value as? String, "Kept draft", "the key did not reach the hidden add bar")
    }
}
