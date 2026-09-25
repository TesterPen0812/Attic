import AppKit
import XCTest

/// The shell's keyboard and menu-bar actions in the real app: Esc closes
/// what is open first and hides the panel last; the menu-bar Search opens
/// the Tasks page's Done search with the keyboard in it.
final class PanelShellUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["panel-pin-button"].waitForExistence(timeout: 5))
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private var addBar: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "AtticTokenField").firstMatch
    }

    private func waitForFocus(_ focused: Bool, on element: XCUIElement,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { object, _ in
            ((object as? XCUIElement)?.value(forKey: "hasKeyboardFocus") as? Bool) == focused
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 3),
                       .completed, "keyboard focus \(focused ? "in" : "out of") the field", file: file, line: line)
    }

    /// First Esc leaves the add bar (what was typed stays), the next closes
    /// an open menu, and only an Esc with nothing left to close hides.
    func testEscapeLeavesTheFieldThenClosesTheMenuThenHidesThePanel() throws {
        let pin = app.buttons["panel-pin-button"]
        XCTAssertTrue(addBar.waitForExistence(timeout: 3))
        addBar.click()
        waitForFocus(true, on: addBar)
        app.typeText("Draft kept")

        app.typeKey(.escape, modifierFlags: [])
        waitForFocus(false, on: addBar)
        XCTAssertTrue(pin.exists, "the first Esc only leaves the field")
        XCTAssertEqual(addBar.value as? String, "Draft kept")

        // The panel's own menu: Esc closes it and nothing else.
        pin.coordinate(withNormalizedOffset: CGVector(dx: 2.6, dy: 0.5)).rightClick()
        let settingsItem = app.menuItems["Settings…"]
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settingsItem.waitForNonExistence(timeout: 3))
        XCTAssertTrue(pin.exists, "Esc in a menu closes the menu only")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(pin.waitForNonExistence(timeout: 3), "Esc with nothing left to close hides the panel")
    }

    /// The menu-bar item's Search: the Tasks page's Done search, focused,
    /// so typing searches right away.
    func testMenuBarSearchOpensTheDoneSearchWithTheKeyboard() throws {
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.buttons["panel-section-notes"].waitForExistence(timeout: 3))

        let item = app.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the menu-bar item is there")
        item.click()
        let search = app.menuItems["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()

        let field = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "AtticTokenField", "Search done tasks…"))
            .firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the Done page's search shows")
        XCTAssertTrue(app.buttons["panel-section-tasks"].isSelected)
        waitForFocus(true, on: field)
        app.typeText("invoice")
        XCTAssertEqual(field.value as? String, "invoice")
    }
}
