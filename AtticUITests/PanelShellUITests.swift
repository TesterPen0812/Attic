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

    /// The "+" card's title (Accepted 2026-10-29 "The '+' card": the card
    /// replaced the add bar).
    private var addBar: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer-title").firstMatch
    }

    /// The launch is an explicit open, which opens the "+" card on Tasks
    /// (the composer job); its scrim takes the pointer over the whole panel.
    /// Escape closes it (Accepted 2026-10-29 "The '+' card": Escape keeps
    /// the draft, none here). Escape is no navigation key, so it shows no
    /// focus ring.
    private func closeTheCardIfOpen() {
        let open = addBar.waitForExistence(timeout: 2)
        print("CARD open at launch: \(open)")
        guard open else { return }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(addBar.waitForNonExistence(timeout: 3), "Escape closes the card")
    }

    private func waitForFocus(_ focused: Bool, on element: XCUIElement,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { object, _ in
            ((object as? XCUIElement)?.value(forKey: "hasKeyboardFocus") as? Bool) == focused
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 3),
                       .completed, "keyboard focus \(focused ? "in" : "out of") the field", file: file, line: line)
    }

    /// First Esc closes the "+" card (what was typed stays: Accepted "The
    /// '+' card", "Escape or a click outside keeps the draft"), the next
    /// closes an open menu, and only an Esc with nothing left to close hides.
    func testEscapeLeavesTheFieldThenClosesTheMenuThenHidesThePanel() throws {
        let pin = app.buttons["panel-pin-button"]
        let plus = app.buttons["tasks-new-task"]
        XCTAssertTrue(plus.waitForExistence(timeout: 3))
        plus.click()
        XCTAssertTrue(addBar.waitForExistence(timeout: 3), "\"+\" opens the card")
        waitForFocus(true, on: addBar)
        app.typeText("Draft kept")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(addBar.waitForNonExistence(timeout: 3), "the first Esc closes the card")
        XCTAssertTrue(pin.exists, "the first Esc only closes the card")
        plus.click()
        XCTAssertTrue(addBar.waitForExistence(timeout: 3))
        XCTAssertEqual(addBar.value as? String, "Draft kept", "the card keeps its draft")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(addBar.waitForNonExistence(timeout: 3))

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
        let search = app.menuItems["Search Done Tasks…"]
        XCTAssertTrue(search.waitForExistence(timeout: 3), file: file, line: line)
        search.click()

        let field = app.textFields.matching(NSPredicate(format: "label == %@", "Search done tasks")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the Done page's search shows", file: file, line: line)
        waitFor(app.buttons["panel-section-tasks"].isSelected, "on the Tasks page")
        // The field takes Done's tabs' line (round 6).
        waitFor(!app.buttons["tasks-page-now"].exists, "the search is on Done's tabs' line")
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

    /// Chrome B: shut, the page button is a square the pin's size showing the
    /// current page (30 pt since control size Medium, owner 2026-10-20; it
    /// was 32); under the pointer it opens into all three (78 wide, three
    /// 22 pt chips; it was 84), a click goes there; ⌘1–⌘3 work from anywhere; it shuts when the pointer leaves.
    /// VoiceOver reads one "Pages" group with a named button per page.
    func testThePageButtonOpensUnderThePointerAndSelectsPages() throws {
        let pin = app.buttons["panel-pin-button"]
        XCTAssertTrue(pageButton.waitForExistence(timeout: 3))
        XCTAssertEqual(pageButton.label, "Pages")
        pin.hover()
        XCTAssertEqual(pin.frame.width, 30, accuracy: 1, "chrome B's corner control, Medium")
        XCTAssertEqual(pin.frame.height, 30, accuracy: 1)
        waitFor(abs(pageButton.frame.width - 30) < 1.5, "shut, it is the pin's size (\(pageButton.frame.width))")
        XCTAssertEqual(pageButton.frame.height, 30, accuracy: 1)
        XCTAssertTrue(page("tasks").isHittable, "the current page shows")
        XCTAssertEqual(page("notes").label, "Notes")
        assertOnlySelected("tasks")

        pageButton.hover()
        waitFor(page("notes").isHittable && page("canvas").isHittable, "under the pointer it opens")
        waitFor(abs(pageButton.frame.width - 78) < 1.5, "to 78 pt (\(pageButton.frame.width))")
        page("notes").click()
        assertOnlySelected("notes")

        app.typeKey("3", modifierFlags: .command)
        assertOnlySelected("canvas")
        app.typeKey("1", modifierFlags: .command)
        assertOnlySelected("tasks")

        pin.hover()
        waitFor(abs(pageButton.frame.width - 30) < 1.5, "it shuts when the pointer leaves")
    }

    /// Focus rings are for keyboard navigation only: clicking pages leaves
    /// the page button looking exactly as it did once the pointer leaves.
    func testClickingThePageButtonShowsNoFocusRing() throws {
        let pin = app.buttons["panel-pin-button"]
        XCTAssertTrue(pageButton.waitForExistence(timeout: 3))
        closeTheCardIfOpen()
        pin.hover()
        Thread.sleep(forTimeInterval: 0.6)
        let before = pageButton.screenshot()
        pageButton.hover()
        if !page("notes").waitForExistence(timeout: 2) || !page("notes").isHittable {
            _ = atticHitReport(app, pageButton, "page-switch")
            _ = atticHitReport(app, page("notes"), "page-notes")
        }
        waitFor(page("notes").isHittable, "it opens")
        page("notes").click()
        // An open note's bar has no page switch; ⌘1 (no navigation key, so
        // no ring) comes back from there.
        if page("tasks").waitForExistence(timeout: 2) {
            page("tasks").click()
        } else {
            app.typeKey("1", modifierFlags: .command)
        }
        XCTAssertTrue(app.buttons["tasks-new-task"].waitForExistence(timeout: 3), "back on Tasks")
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
