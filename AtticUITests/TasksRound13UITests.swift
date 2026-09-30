import AppKit
import XCTest

/// Round 13, in the real panel with the demo tasks (`ATTIC_UI_TEST_SEED=demo`):
/// who owns the keyboard. Return in an open ⇧⌘I menu runs the highlighted
/// item (a subtask focused by Tab is covered by the hosted tests, which
/// press a real Tab). CI only: they
/// need a signed-in window server.
final class TasksRound13UITests: XCTestCase {
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

    private func row(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    private func select(_ title: String) {
        row(title).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 16)).click()
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// ⇧⌘I, eight ↓ to Add Subtask, Return: the subtask editor opens and the
    /// parent's title editor does not.
    func testReturnInTheActionsMenuRunsTheHighlightedItem() throws {
        select("Book dentist")
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.menuItems["Add Subtask"].waitForExistence(timeout: 3), "the actions menu opens")
        // A person's pace: the menu highlights as each ↓ lands, and Return
        // goes to the item that has the highlight (CI run 2 fired every key
        // in 0.6 s and Return ran Edit Title).
        for _ in 0..<8 {
            app.typeKey(.downArrow, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let beforeReturn = XCTAttachment(screenshot: app.screenshot())
        beforeReturn.name = "menu before Return"
        beforeReturn.lifetime = .keepAlways
        add(beforeReturn)
        let beforeTree = XCTAttachment(string: app.debugDescription)
        beforeTree.name = "accessibility before Return"
        beforeTree.lifetime = .keepAlways
        add(beforeTree)
        app.typeKey(.return, modifierFlags: [])
        let afterReturn = XCTAttachment(screenshot: app.screenshot())
        afterReturn.name = "menu after Return"
        afterReturn.lifetime = .keepAlways
        add(afterReturn)
        let afterTree = XCTAttachment(string: app.debugDescription)
        afterTree.name = "accessibility after Return"
        afterTree.lifetime = .keepAlways
        add(afterTree)
        func editors(_ label: String) -> XCUIElementQuery {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
        }
        waitFor(editors("New subtask of Book dentist").count > 0, "Add Subtask ran")
        XCTAssertEqual(editors("Title").count, 0, "and the title editor did not open")
    }

    /// Settings ▸ General ▸ Animations opens Attic's own pop-over list (an
    /// opaque surface, not the system menu's blur) and choosing an entry sets
    /// the row's value; the original choice is put back.
    func testTheAnimationsPopUpOpensAnOpaqueListAndChooses() throws {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Attic Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings opens")
        let popUp = settings.descendants(matching: .any).matching(identifier: "setting-animations").firstMatch
        XCTAssertTrue(popUp.waitForExistence(timeout: 5), "the Animations pop-up is on the General page")
        let original = (popUp.value as? String) ?? "Full"
        let other = original == "Reduced" ? "Full" : "Reduced"
        popUp.click()
        let choice = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", other)).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3), "the list offers \(other)")
        choice.click()
        waitFor((popUp.value as? String) == other, "the row shows \(other)")
        popUp.click()
        let back = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", original)).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.click()
        waitFor((popUp.value as? String) == original, "and the original choice is back")
    }
}
