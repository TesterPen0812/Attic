import AppKit
import XCTest

/// Round 12, in the real panel with the demo tasks (`ATTIC_UI_TEST_SEED=demo`):
/// a click and a right-click act on the row under the pointer (never on the
/// previously selected one), the Tasks page's tab survives a visit to another
/// section, and Esc closes the quick look before anything else. CI only:
/// they need a signed-in window server.
final class TasksRound12UITests: XCTestCase {
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

    private func row(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    private func tab(_ page: String) -> XCUIElement { app.buttons["tasks-page-\(page)"] }

    private var pin: XCUIElement { app.buttons["panel-pin-button"] }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// A click on the row's title (it selects; the circle completes).
    private func select(_ title: String) {
        row(title).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 16)).click()
    }

    private var mergeSubtask: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Merge")).firstMatch
    }

    // MARK: - Bug 1

    /// A click on another row moves the selection there: the quick look
    /// (Right) opens on the row clicked, not on the one selected before.
    func testAClickMovesTheSelectionToTheRowUnderThePointer() throws {
        select("Book dentist")
        select("Ship appearance PR")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(mergeSubtask.waitForExistence(timeout: 3), "the quick look opened on the row clicked")
    }

    /// A right-click acts on the row under it, whatever was selected.
    func testARightClickActsOnTheRowUnderThePointerNotTheSelectedOne() throws {
        select("Book dentist")
        row("Email beta testers").rightClick()
        let move = app.menuItems["Move to Later"]
        XCTAssertTrue(move.waitForExistence(timeout: 3), "the row's menu opens")
        move.click()
        waitFor(!row("Email beta testers").exists, "the row right-clicked leaves Now")
        XCTAssertTrue(row("Book dentist").exists, "the row that was selected stays")
    }

    // MARK: - Bug 3

    /// Leaving for Notes or Canvas and coming back finds Tasks on the tab
    /// it was left on.
    func testTheTasksTabSurvivesAVisitToNotesAndCanvas() throws {
        tab("backlog").click()
        waitFor(tab("backlog").isSelected, "Later is shown")
        app.typeKey("2", modifierFlags: .command)
        waitFor(app.buttons["panel-section-notes"].isSelected, "on Notes")
        app.typeKey("3", modifierFlags: .command)
        waitFor(app.buttons["panel-section-canvas"].isSelected, "on Canvas")
        app.typeKey("1", modifierFlags: .command)
        waitFor(app.buttons["panel-section-tasks"].isSelected, "back on Tasks")
        waitFor(tab("backlog").isSelected, "Later is still the tab")
        waitFor(row("Plan the spring trip").exists, "and Later's list shows")
        XCTAssertFalse(tab("now").isSelected)
    }

    // MARK: - Bug 4

    /// Esc closes an open quick look first: the panel stays, and a second
    /// Esc is then free to do its next job.
    func testEscClosesTheQuickLookBeforeAnythingElse() throws {
        select("Ship appearance PR")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(mergeSubtask.waitForExistence(timeout: 3), "the quick look is open")
        app.typeKey(.escape, modifierFlags: [])
        waitFor(!mergeSubtask.exists, "Esc closes the quick look")
        XCTAssertTrue(pin.exists, "and the panel stays")
        XCTAssertTrue(row("Ship appearance PR").exists, "with the list as it was")
    }
}

/// Round 12 (Bug 5): rows scrolled under the tabs or the add bar are not
/// readable. With 500 rows in Now, the list scrolls to two places; what lies
/// under the tabs' line and the add bar's band must be the same picture at
/// both (the panel's own surface), whatever rows are under them. CI only.
final class TasksVeilUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_SEED"] = "scale"
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["panel-pin-button"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private func row(_ index: Int) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Open task number \(index) with a title,")).firstMatch
    }

    func testNothingShowsThroughTheTabsLineOrTheAddBarsBand() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(row(1).waitForExistence(timeout: 10), "the long list is there")
        let tabs = app.buttons["tasks-page-now"].frame
        let addBar = app.descendants(matching: .any).matching(identifier: "AtticTokenField").firstMatch
        XCTAssertTrue(addBar.waitForExistence(timeout: 5))
        let frame = window.frame
        // The tabs' line, and the add bar's top to the panel's bottom (in points, window-relative).
        let bands = [(tabs.minY - frame.minY, tabs.maxY - frame.minY), (addBar.frame.minY - frame.minY - 4, frame.height)]

        window.scroll(byDeltaX: 0, deltaY: -260)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let first = window.screenshot().image
        // Rows far away: a different page of the list under both bands.
        window.scroll(byDeltaX: 0, deltaY: -1_300)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let second = window.screenshot().image

        for (top, bottom) in bands {
            let changed = try differingShare(first, second, points: (top, bottom), windowWidth: frame.width)
            XCTAssertLessThan(changed, 0.004, "rows show through the band \(top)–\(bottom) (\(changed))")
        }
        let attachment = XCTAttachment(image: second)
        attachment.name = "veil-scrolled"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The share of pixels in the band (`points` in window coordinates) that
    /// differ between two captures of the window.
    private func differingShare(_ a: NSImage, _ b: NSImage, points: (CGFloat, CGFloat), windowWidth: CGFloat) throws -> Double {
        let left = try XCTUnwrap(a.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let right = try XCTUnwrap(b.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(left.pixelsWide, right.pixelsWide)
        let scale = CGFloat(left.pixelsWide) / windowWidth
        let rows = Int(max(points.0, 0) * scale)..<min(Int(points.1 * scale), left.pixelsHigh, right.pixelsHigh)
        var differing = 0, total = 0
        for y in rows {
            for x in 0..<left.pixelsWide {
                guard let p = left.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let q = right.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                let delta = max(abs(p.redComponent - q.redComponent), abs(p.greenComponent - q.greenComponent),
                                abs(p.blueComponent - q.blueComponent))
                if delta > 0.03 { differing += 1 }
            }
        }
        return total == 0 ? 1 : Double(differing) / Double(total)
    }
}
