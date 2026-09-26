import AppKit
import XCTest

/// The Phase 1 Tasks page, driven as a person drives it: the page runs on
/// its own in a preview window (`--attic-gallery --attic-tasks-page`, an
/// in-memory store with the v9 demo tasks), and each test types, clicks and
/// right-clicks, then reads what VoiceOver would read.
final class TasksPageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchArguments += ["--attic-gallery", "--attic-tasks-page"]
        var opened = false
        for _ in 0..<2 where !opened {
            app.launch()
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, !window.exists {
                app.activate()
                _ = window.waitForExistence(timeout: 1)
            }
            opened = window.exists
            if !opened { app.terminate() }
        }
        XCTAssertTrue(opened, "The Tasks page window did not open: \(app.debugDescription)")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private var window: XCUIElement { app.windows["Attic Tasks Page"] }

    /// A task row, found by the start of what VoiceOver reads for it.
    private func row(_ title: String) -> XCUIElement {
        window.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    private func label(_ title: String) -> String { row(title).label }

    private var addBar: XCUIElement {
        window.descendants(matching: .any).matching(identifier: "AtticTokenField").firstMatch
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5, _ message: String) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message)
    }

    /// Clicks the row's status circle (16 pt at x = 20, on the title line).
    private func clickCircle(_ title: String, modifiers: XCUIElement.KeyModifierFlags = []) {
        let element = row(title)
        let point = element.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: 17))
        if modifiers.isEmpty {
            point.click()
        } else {
            XCUIElement.perform(withKeyModifiers: modifiers) { point.click() }
        }
    }

    func testTheAddBarUnderstandsShorthandAndKeepsFocusForTheNextTask() throws {
        XCTAssertTrue(addBar.waitForExistence(timeout: 5))
        addBar.click()
        addBar.typeText("Water the plants tomorrow #home !!\r")
        waitFor(row("Water the plants").exists, "the new task is listed")
        let spoken = label("Water the plants")
        XCTAssertTrue(spoken.contains("to do"), spoken)
        XCTAssertTrue(spoken.contains("high priority"), spoken)
        XCTAssertTrue(spoken.contains("due Tomorrow"), spoken)
        XCTAssertTrue(spoken.contains("tagged home"), spoken)
        // Return kept the bar focused: the next line goes straight in.
        app.typeText("Second one\r")
        waitFor(row("Second one").exists, "Return keeps the add bar focused")
        // ⌘Z undoes the last add; the bar has no typing left to undo.
        app.typeKey("z", modifierFlags: .command)
        waitFor(!row("Second one").exists, "⌘Z undoes the add")
    }

    func testTheCircleAdvancesAndOptionClickCompletes() throws {
        XCTAssertTrue(row("Book dentist").waitForExistence(timeout: 5))
        clickCircle("Book dentist")
        waitFor(label("Book dentist").contains("in progress"), "click: to do → in progress")
        clickCircle("Email beta testers", modifiers: .option)
        waitFor(label("Email beta testers").contains(", done"), "Option-click completes")
    }

    func testKeyboardMovesEditsAndCompletes() throws {
        XCTAssertTrue(row("Ship appearance PR").waitForExistence(timeout: 5))
        row("Ship appearance PR").click()
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        // ↓ moved to Email beta testers: Return edits its title in place.
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        // The title editor takes the keyboard on the next turn: wait for it
        // before ⌘A, or the list's select-all takes the key instead.
        let editor = window.descendants(matching: .textField)
            .matching(NSPredicate(format: "value == %@", "Email beta testers")).firstMatch
        // (The row may merge the field into its own element; then give the
        // editor a moment to take the keyboard instead.)
        if editor.waitForExistence(timeout: 2) {
            waitFor((editor.value(forKey: "hasKeyboardFocus") as? Bool) == true, "the editor has the keyboard")
        } else {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Email the beta testers\r")
        waitFor(row("Email the beta testers").exists, "Return saves the edited title")
        // Space starts it, ⇧Space completes it.
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        waitFor(label("Email the beta testers").contains("in progress"), "Space starts")
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: .shift)
        waitFor(label("Email the beta testers").contains(", done"), "⇧Space completes")
    }

    func testRightClickMovesToBacklogWithAnUndoToast() throws {
        XCTAssertTrue(row("Book dentist").waitForExistence(timeout: 5))
        row("Book dentist").rightClick()
        let move = app.menuItems["Move to Backlog"]
        XCTAssertTrue(move.waitForExistence(timeout: 3))
        move.click()
        waitFor(!row("Book dentist").exists, "it leaves Now")
        let toast = window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Moved to Backlog")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "the Undo toast shows")
        window.buttons["Undo"].click()
        waitFor(row("Book dentist").exists, "Undo brings it back")
    }

    /// A real drag: the row lifts in place, the others slide apart, and it
    /// lands where it was dropped within its group.
    func testDraggingARowReordersItWithinItsGroup() throws {
        XCTAssertTrue(row("Book dentist").waitForExistence(timeout: 5))
        XCTAssertLessThan(row("Ship appearance PR").frame.minY, row("Book dentist").frame.minY)
        let from = row("Book dentist").coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        let to = row("Ship appearance PR").coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3))
        from.press(forDuration: 0.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        waitFor(row("Book dentist").frame.minY < row("Ship appearance PR").frame.minY, "Book dentist now sits above Ship appearance PR")
        // One step: ⌘Z puts it back.
        app.typeKey("z", modifierFlags: .command)
        waitFor(row("Ship appearance PR").frame.minY < row("Book dentist").frame.minY, "⌘Z undoes the move")
    }

    /// The page pill's three choices (v9): Tasks, Backlog and Done, with
    /// the page's one title following.
    private func pill(_ page: String) -> XCUIElement {
        window.buttons["tasks-page-\(page)"]
    }

    private var pageTitle: XCUIElement {
        window.descendants(matching: .any).matching(identifier: "tasks-page-title").firstMatch
    }

    func testThePagePillMovesBetweenTasksBacklogAndDone() throws {
        XCTAssertTrue(pill("backlog").waitForExistence(timeout: 5))
        XCTAssertEqual(pageTitle.label, "Tasks")
        pill("backlog").click()
        waitFor(row("Plan the spring trip").isHittable, "Backlog lists its tasks")
        waitFor(pageTitle.label == "Backlog", "the title reads Backlog")
        pill("done").click()
        waitFor(pageTitle.label == "Done", "the title reads Done")
        waitFor(row("Send invoice").isHittable, "Done lists the Done log")
        XCTAssertTrue(window.descendants(matching: .any)["Yesterday"].exists)
        // "Open page" on a Done log task opens its details there.
        row("Send invoice").rightClick()
        let open = app.menuItems["Open Page"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        open.click()
        let restore = window.buttons["Restore to Now"]
        XCTAssertTrue(restore.waitForExistence(timeout: 3), "the details offer Restore to Now")
        restore.click()
        pill("now").click()
        waitFor(pageTitle.label == "Tasks", "the title reads Tasks")
        waitFor(row("Send invoice").exists, "restored to Now")
    }
}
