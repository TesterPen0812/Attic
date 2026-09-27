import AppKit
import XCTest

/// The shell's keyboard, header and menu-bar actions in the real app: Esc
/// closes what is open first and hides the panel last; the page button
/// opens under the pointer and selects pages; the menu-bar Search opens the
/// Tasks page's Done search with the keyboard in it.
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
        // The panel's own menu item, not the app menu's hidden one.
        let settingsItems = app.menuItems.matching(NSPredicate(format: "title == %@", "Settings…"))
        var settingsItem = settingsItems.firstMatch
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let shown = settingsItems.allElementsBoundByIndex.first(where: { $0.exists && $0.frame.width > 0 }) {
                settingsItem = shown
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(settingsItem.exists && settingsItem.frame.width > 0, "the panel's menu is open")
        // To the menu itself: on a runner where Attic is not the active app,
        // an app-level key reaches the front app instead of the open menu.
        settingsItem.typeKey(.escape, modifierFlags: [])
        waitFor(settingsItems.allElementsBoundByIndex.allSatisfy { !$0.exists || $0.frame.width == 0 }, timeout: 3,
                "Esc closes the menu")
        XCTAssertTrue(pin.exists, "Esc in a menu closes the menu only")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(pin.waitForNonExistence(timeout: 3), "Esc with nothing left to close hides the panel")
    }

    /// The menu-bar item's Search: the Tasks page's Done search, focused,
    /// so typing searches right away.
    func testMenuBarSearchOpensTheDoneSearchWithTheKeyboard() throws {
        app.typeKey("2", modifierFlags: .command)
        waitFor(app.buttons["panel-section-notes"].isSelected, "Notes is shown")
        searchFromTheMenuBar()
    }

    /// The same when the panel was revealed without the keyboard (over
    /// another app, as the corner reveals it): Search still puts the
    /// keyboard in the Done search.
    func testMenuBarSearchFocusesTheDoneSearchAfterANonKeyReveal() throws {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_NONKEY_REVEAL"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["panel-pin-button"].waitForExistence(timeout: 5))
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        searchFromTheMenuBar()
    }

    private func searchFromTheMenuBar(file: StaticString = #filePath, line: UInt = #line) {
        let item = app.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the menu-bar item is there", file: file, line: line)
        item.click()
        let search = app.menuItems["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3), file: file, line: line)
        search.click()

        let field = app.textFields.matching(NSPredicate(format: "label == %@", "Search done tasks")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the Done page's search shows", file: file, line: line)
        waitFor(app.buttons["panel-section-tasks"].isSelected, "on the Tasks page")
        waitFor(app.buttons["tasks-page-done"].isSelected, "on its Done tab")
        waitForFocus(true, on: field, file: file, line: line)
        app.typeText("invoice")
        XCTAssertEqual(field.value as? String, "invoice", file: file, line: line)
    }

    // MARK: - Page button

    private var pageButton: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "panel-section-picker").firstMatch
    }

    private func page(_ name: String) -> XCUIElement { app.buttons["panel-section-\(name)"] }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func assertOnlySelected(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(page(name).isSelected, "\(name) reads as selected", file: file, line: line)
        XCTAssertEqual(["tasks", "notes", "canvas"].filter { page($0).isSelected }, [name], file: file, line: line)
    }

    /// Shut, the page button is a 36 pt square showing the current page;
    /// under the pointer it opens into all three (96 wide), a click goes
    /// there; ⌘1–⌘3 work from anywhere; it shuts when the pointer leaves.
    /// VoiceOver reads one "Pages" group with a named button per page.
    func testThePageButtonOpensUnderThePointerAndSelectsPages() throws {
        let pin = app.buttons["panel-pin-button"]
        XCTAssertTrue(pageButton.waitForExistence(timeout: 3))
        XCTAssertEqual(pageButton.label, "Pages")
        pin.hover()
        waitFor(abs(pageButton.frame.width - 36) < 1.5, "shut, it is the pin's size (\(pageButton.frame.width))")
        XCTAssertEqual(pageButton.frame.height, 36, accuracy: 1)
        XCTAssertTrue(page("tasks").isHittable, "the current page shows")
        XCTAssertFalse(page("notes").isHittable, "the others are folded away")
        XCTAssertEqual(page("notes").label, "Notes")
        assertOnlySelected("tasks")

        pageButton.hover()
        waitFor(page("notes").isHittable && page("canvas").isHittable, "under the pointer it opens")
        waitFor(abs(pageButton.frame.width - 96) < 1.5, "to 96 pt (\(pageButton.frame.width))")
        page("notes").click()
        assertOnlySelected("notes")

        app.typeKey("3", modifierFlags: .command)
        assertOnlySelected("canvas")
        app.typeKey("1", modifierFlags: .command)
        assertOnlySelected("tasks")

        pin.hover()
        waitFor(abs(pageButton.frame.width - 36) < 1.5, "it shuts when the pointer leaves")
    }

    /// Focus rings are for keyboard navigation only: clicking pages leaves
    /// the page button looking exactly as it did once the pointer leaves.
    func testClickingThePageButtonShowsNoFocusRing() throws {
        let pin = app.buttons["panel-pin-button"]
        XCTAssertTrue(pageButton.waitForExistence(timeout: 3))
        pin.hover()
        Thread.sleep(forTimeInterval: 0.6)
        let before = pageButton.screenshot()
        pageButton.hover()
        waitFor(page("notes").isHittable, "it opens")
        page("notes").click()
        page("tasks").click()
        pin.hover()
        Thread.sleep(forTimeInterval: 0.8)
        let after = pageButton.screenshot()
        let attachment = XCTAttachment(image: after.image)
        attachment.name = "page-button-after-clicks"
        attachment.lifetime = .keepAlways
        add(attachment)
        let changed = try differingPixelFraction(before.image, after.image)
        XCTAssertLessThan(changed, 0.01, "a mouse click must not leave a focus ring (\(changed) of pixels changed)")
    }

    private func differingPixelFraction(_ lhs: NSImage, _ rhs: NSImage) throws -> Double {
        let a = try XCTUnwrap(lhs.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let b = try XCTUnwrap(rhs.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        var differing = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let delta = max(abs(p.redComponent - q.redComponent),
                                abs(p.greenComponent - q.greenComponent),
                                abs(p.blueComponent - q.blueComponent))
                if delta > 0.06 { differing += 1 }
            }
        }
        return Double(differing) / Double(max(1, width * height))
    }
}
