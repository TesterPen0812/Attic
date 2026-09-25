import XCTest

/// The title menu and the pop-up row open the system's own menus with
/// their items, in the running app as a person uses it (activated, a key
/// window): the design system's menu lab (`--attic-gallery-menus`, preview
/// builds only). The unit-test host can never be the active app, so this is
/// where opening a menu and choosing an item is proved on every macOS the
/// app supports.
final class AtticNativeMenuUITests: XCTestCase {
    private var app: XCUIApplication!
    private var lab: XCUIElement { app.windows["Attic Menu Lab"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchArguments += ["--attic-gallery", "--attic-gallery-menus"]
        var opened = false
        for _ in 0..<2 where !opened {
            app.launch()
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, !lab.exists {
                app.activate()
                _ = lab.waitForExistence(timeout: 1)
            }
            opened = lab.exists
            if !opened { app.terminate() }
        }
        XCTAssertTrue(opened, "The menu lab window did not open: \(app.debugDescription)")
        bringLabToFront()
    }

    /// Other apps on a shared desktop can cover the lab: activate it and
    /// click its title bar so the menus are the frontmost, hittable controls.
    private func bringLabToFront() {
        app.activate()
        lab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).click()
    }

    /// Clicks a menu control and waits for one of its items, retrying once
    /// after bringing the lab to the front.
    private func open(_ control: XCUIElement, expecting item: String) -> XCUIElement {
        let menuItem = app.menuItems[item]
        for attempt in 0..<2 {
            if attempt > 0 { bringLabToFront() }
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            control.click()
            if menuItem.waitForExistence(timeout: 5) { break }
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }
        return menuItem
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private func state() -> String {
        let element = app.staticTexts["menu-lab-state"]
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    func testTheTitleMenuOpensTheSystemMenuWithItsCommands() throws {
        let title = app.descendants(matching: .any)["menu-lab-title"]
        XCTAssertEqual(title.elementType, .menuButton, "The title is a menu button for VoiceOver")
        let duplicate = open(title, expecting: "Duplicate")
        XCTAssertTrue(duplicate.exists, "The title menu opens a native menu with its commands")
        XCTAssertTrue(app.menuItems["Delete"].exists)
        duplicate.click()
        let changed = NSPredicate { _, _ in self.state().hasPrefix("Duplicate") }
        wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 5)
    }

    func testThePopUpRowOpensTheSystemMenuWithItsChoices() throws {
        let row = app.descendants(matching: .any)["menu-lab-popup"]
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "menu-lab-popup").count, 1, "The row is one element for VoiceOver")
        XCTAssertEqual(row.elementType, .menuButton)
        let glass = open(row, expecting: "Glass")
        XCTAssertTrue(glass.exists, "The pop-up row opens a native menu with its choices")
        XCTAssertTrue(app.menuItems["Solid"].exists)
        glass.click()
        let changed = NSPredicate { _, _ in self.state().hasSuffix("glass") }
        wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 5)
    }
}
