import AppKit
import XCTest

/// The Phase 1 Tasks page, driven as a person drives it: the page runs on
/// its own in a preview window (`--attic-gallery --attic-tasks-page`, an
/// in-memory store with the demo tasks), and each test types, clicks and
/// right-clicks, then reads what VoiceOver would read.
///
/// Demo tasks on Now: Finalize launch checklist (in progress, High, today,
/// 1 of 3 subtasks), Ship appearance PR (High, 2 of 4), Email beta testers
/// (Medium), Book dentist (Low, tomorrow), Call the plumber; done today:
/// Renew domain. Later: Try the paper sketch idea, Research note templates,
/// Plan the spring trip. Done log: Send invoice and Water the plants
/// (yesterday), Call the bank, Pay rent, Renew passport.
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
        XCTAssertTrue(row("Book dentist").waitForExistence(timeout: 5), "the demo tasks are listed")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: - Helpers

    private var window: XCUIElement { app.windows["Attic Tasks Page"] }

    /// A task row, found by the start of what VoiceOver reads for it.
    private func row(_ title: String) -> XCUIElement {
        window.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    private func label(_ title: String) -> String { row(title).exists ? row(title).label : "" }

    private var addBar: XCUIElement {
        window.descendants(matching: .any).matching(identifier: "AtticTokenField").firstMatch
    }

    private func tab(_ page: String) -> XCUIElement {
        window.buttons["tasks-page-\(page)"]
    }

    private var completedToday: XCUIElement {
        window.descendants(matching: .any)["tasks-completed-today"]
    }

    private var searchField: XCUIElement {
        window.textFields.matching(NSPredicate(format: "label == %@", "Search done tasks")).firstMatch
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// The row's status circle: 16 pt, its centre 24 pt in from the row's
    /// leading edge and on the title line (17 pt down a one-line row, 15
    /// down a two-line one); the 28 pt hit area takes 16 for both.
    private func circle(_ title: String) -> XCUICoordinate {
        row(title).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 16))
    }

    /// Selects a row the way a click on its title does (not its circle).
    private func select(_ title: String) {
        row(title).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 16)).click()
    }

    // MARK: - Add bar

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

    // MARK: - One-click completion

    /// A click on the circle completes; a second click during the done
    /// hold brings it straight back; completed again, it holds its place,
    /// then moves into "Completed today", whose disclosure shows it, and
    /// its circle there restores it to Now.
    func testOneClickCompletesAndClickingAgainRestores() throws {
        XCTAssertTrue(completedToday.waitForExistence(timeout: 3))
        XCTAssertEqual(completedToday.label, "Completed today, 1")
        XCTAssertEqual(completedToday.value as? String, "collapsed")

        circle("Book dentist").click()
        waitFor(label("Book dentist").contains(", done"), "a click completes")
        circle("Book dentist").click()
        waitFor(label("Book dentist").contains(", to do"), "a second click during the hold brings it back")
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        XCTAssertTrue(row("Book dentist").exists, "restored, it stays in the list")
        XCTAssertEqual(completedToday.label, "Completed today, 1")

        circle("Book dentist").click()
        waitFor(label("Book dentist").contains(", done"), "a click completes")
        XCTAssertTrue(row("Book dentist").exists, "the done row holds its place for a moment")
        waitFor(!row("Book dentist").exists, timeout: 4, "then it leaves the open tasks")
        waitFor(completedToday.label == "Completed today, 2", "and is counted under Completed today")

        completedToday.click()
        waitFor((completedToday.value as? String) == "expanded", "the disclosure opens")
        waitFor(row("Book dentist").exists, "it lists today's done tasks")
        XCTAssertTrue(label("Book dentist").contains(", done"))
        XCTAssertTrue(row("Renew domain").exists)

        circle("Book dentist").click()
        waitFor(label("Book dentist").contains(", to do"), "its circle there restores it")
        waitFor(completedToday.label == "Completed today, 1", "and it leaves Completed today")

        completedToday.click()
        waitFor(!row("Renew domain").exists, "a second click hides the done tasks again")
        XCTAssertEqual(completedToday.value as? String, "collapsed")
    }

    /// ⇧Space starts and stops working; Space completes.
    func testShiftSpaceStartsAndStopsAndSpaceCompletes() throws {
        select("Call the plumber")
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: .shift)
        waitFor(label("Call the plumber").contains(", in progress"), "⇧Space starts working")
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: .shift)
        waitFor(label("Call the plumber").contains(", to do"), "⇧Space again stops")
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        waitFor(label("Call the plumber").contains(", done"), "Space completes")
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        waitFor(label("Call the plumber").contains(", to do"), "Space again brings it back")
    }

    func testKeyboardMovesAndEditsTheTitle() throws {
        select("Ship appearance PR")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        // ↓ moved to Email beta testers: Return edits its title in place.
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        // The title editor takes the keyboard on the next turn: wait for it
        // before ⌘A, or the list's select-all takes the key instead.
        let editor = window.textFields.matching(NSPredicate(format: "label == %@", "Title")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "Return opens the title editor")
        XCTAssertEqual(editor.value as? String, "Email beta testers")
        waitFor((editor.value(forKey: "hasKeyboardFocus") as? Bool) == true, "the editor has the keyboard")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Email the beta testers\r")
        waitFor(row("Email the beta testers").exists, "Return saves the edited title")
        XCTAssertTrue(label("Email the beta testers").contains("medium priority"), "the rest of the task is kept")
    }

    /// The marks after a title (High "!!", Medium "!") are read as the
    /// priority; Low and None say nothing about it.
    func testPriorityIsReadWithTheTask() throws {
        XCTAssertTrue(label("Ship appearance PR").contains("high priority"))
        XCTAssertTrue(label("Email beta testers").contains("medium priority"))
        XCTAssertTrue(label("Book dentist").contains("low priority"))
        XCTAssertFalse(label("Call the plumber").contains("priority"))
    }

    // MARK: - Moving

    func testRightClickMovesToLaterWithAnUndoToast() throws {
        row("Book dentist").rightClick()
        let move = app.menuItems["Move to Later"]
        XCTAssertTrue(move.waitForExistence(timeout: 3))
        move.click()
        waitFor(!row("Book dentist").exists, "it leaves Now")
        let toast = window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Moved to Later")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "the Undo toast shows")
        window.buttons["Undo"].click()
        waitFor(row("Book dentist").exists, "Undo brings it back")
    }

    /// A real drag: the row lifts in place, the others slide apart, and it
    /// lands where it was dropped within its group.
    func testDraggingARowReordersItWithinItsGroup() throws {
        XCTAssertLessThan(row("Ship appearance PR").frame.minY, row("Book dentist").frame.minY)
        let from = row("Book dentist").coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        let to = row("Ship appearance PR").coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3))
        from.press(forDuration: 0.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        waitFor(row("Book dentist").frame.minY < row("Ship appearance PR").frame.minY, "Book dentist now sits above Ship appearance PR")
        // One step: ⌘Z puts it back.
        app.typeKey("z", modifierFlags: .command)
        waitFor(row("Ship appearance PR").frame.minY < row("Book dentist").frame.minY, "⌘Z undoes the move")
    }

    // MARK: - Tabs, Later and Done

    /// Now · Later · Done are one "Pages" group of named buttons; each
    /// shows its list and reads as the selected one.
    func testTheTabsMoveBetweenNowLaterAndDone() throws {
        let group = window.descendants(matching: .any)["tasks-page-tabs"]
        XCTAssertTrue(group.exists)
        XCTAssertEqual(group.label, "Pages")
        XCTAssertTrue(tab("now").isSelected)
        XCTAssertEqual(tab("backlog").label, "Later")

        tab("backlog").click()
        waitFor(row("Plan the spring trip").isHittable, "Later lists its tasks")
        waitFor(tab("backlog").isSelected && !tab("now").isSelected, "Later reads as selected")
        XCTAssertFalse(row("Book dentist").exists, "only the page shown is read")

        tab("done").click()
        waitFor(row("Send invoice").isHittable, "Done lists the Done log")
        XCTAssertTrue(tab("done").isSelected)
        XCTAssertTrue(window.descendants(matching: .any)["Yesterday"].exists, "grouped by day")

        // "Open Page" on a Done log task opens its details, which offer
        // Restore to Now; the right-click menu restores too.
        row("Send invoice").rightClick()
        let open = app.menuItems["Open Page"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        open.click()
        XCTAssertTrue(window.buttons["Restore to Now"].waitForExistence(timeout: 3), "the details offer Restore to Now")
        app.typeKey(.escape, modifierFlags: [])
        row("Send invoice").rightClick()
        let restore = app.menuItems["Restore to Now"]
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.click()
        waitFor(!row("Send invoice").exists, "it leaves the Done log")

        tab("now").click()
        waitFor(tab("now").isSelected, "Now reads as selected")
        waitFor(row("Send invoice").exists, "restored to Now")
        XCTAssertTrue(label("Send invoice").contains(", to do"))
    }

    /// Completing on Later: the row shows done in place, then leaves Later;
    /// Now counts it under Completed today. Its circle there puts it back
    /// on Later, where it came from.
    func testCompletingOnLaterHoldsThenLeaves() throws {
        tab("backlog").click()
        waitFor(row("Try the paper sketch idea").isHittable, "Later lists its tasks")
        circle("Try the paper sketch idea").click()
        waitFor(label("Try the paper sketch idea").contains(", done"), "a click completes it on Later")
        waitFor(!row("Try the paper sketch idea").exists, timeout: 4, "then it leaves Later")

        tab("now").click()
        waitFor(completedToday.label == "Completed today, 2", "Now counts it as done today")
        completedToday.click()
        waitFor(row("Try the paper sketch idea").exists, "it is listed under Completed today")
        circle("Try the paper sketch idea").click()
        waitFor(!row("Try the paper sketch idea").exists, "restored, it leaves Now")
        tab("backlog").click()
        waitFor(row("Try the paper sketch idea").exists, "back on Later, where it came from")
    }

    /// The Done page's search is the row at the top of its list: typing
    /// filters the log, Esc clears the text, the next Esc leaves the field.
    func testTheDoneSearchFiltersAndEscapeClearsThenLeaves() throws {
        tab("done").click()
        waitFor(row("Pay rent").isHittable, "the Done log shows")
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.click()
        waitFor((searchField.value(forKey: "hasKeyboardFocus") as? Bool) == true, "a click puts the keyboard in the search")
        app.typeText("invoice")
        waitFor(!row("Pay rent").exists, "typing filters the log")
        XCTAssertTrue(row("Send invoice").exists)
        app.typeKey(.escape, modifierFlags: [])
        waitFor(row("Pay rent").exists, "Esc clears the search")
        XCTAssertEqual((searchField.value as? String) ?? "", "")
        app.typeKey(.escape, modifierFlags: [])
        waitFor((searchField.value(forKey: "hasKeyboardFocus") as? Bool) != true, "the next Esc leaves the field")
    }

    // MARK: - In progress: the dot, then the pie

    /// An in-progress task shows a centre dot until one of its subtasks is
    /// ticked, then a pie of the ticked share. Unticking the only ticked
    /// subtask of "Finalize launch checklist" (1 of 3) turns its pie back
    /// into the dot, and ticking it again brings the same pie back.
    func testTheCircleShowsTheDotUntilASubtaskIsTickedThenThePie() throws {
        let title = "Finalize launch checklist"
        select(title)
        app.typeKey(.rightArrow, modifierFlags: [])
        let freeze = window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Freeze strings")).firstMatch
        XCTAssertTrue(freeze.waitForExistence(timeout: 3), "the quick look lists the subtasks")
        XCTAssertEqual(freeze.value as? String, "done")
        XCTAssertTrue(label(title).contains("1 of 3 subtasks"))
        let pie = try circleImage(title)

        freeze.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 7, dy: 0)).click()
        waitFor(label(title).contains("0 of 3 subtasks"), "the subtask is unticked")
        XCTAssertTrue(label(title).contains(", in progress"), "still in progress")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let dot = try circleImage(title)

        freeze.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 7, dy: 0)).click()
        waitFor(label(title).contains("1 of 3 subtasks"), "ticked again")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let pieAgain = try circleImage(title)

        attach(pie, "circle-pie")
        attach(dot, "circle-dot")
        XCTAssertGreaterThan(try differingFraction(pie, dot), 0.04, "the pie and the dot must look different")
        XCTAssertLessThan(try differingFraction(pie, pieAgain), 0.02, "the same share draws the same pie")
    }

    /// The circle's 16 pt square, cut from a screenshot of the window.
    private func circleImage(_ title: String) throws -> CGImage {
        let shot = window.screenshot()
        let image = try XCTUnwrap(shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let scale = CGFloat(image.width) / window.frame.width
        let rowFrame = row(title).frame
        let centre = CGPoint(x: rowFrame.minX + 24 - window.frame.minX, y: rowFrame.minY + 15 - window.frame.minY)
        let side: CGFloat = 16
        let crop = CGRect(x: (centre.x - side / 2) * scale, y: (centre.y - side / 2) * scale, width: side * scale, height: side * scale)
        return try XCTUnwrap(image.cropping(to: crop.integral))
    }

    private func differingFraction(_ lhs: CGImage, _ rhs: CGImage) throws -> Double {
        let a = NSBitmapImageRep(cgImage: lhs)
        let b = NSBitmapImageRep(cgImage: rhs)
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        var differing = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let delta = max(abs(p.redComponent - q.redComponent), abs(p.greenComponent - q.greenComponent),
                                abs(p.blueComponent - q.blueComponent))
                if delta > 0.12 { differing += 1 }
            }
        }
        return Double(differing) / Double(max(1, width * height))
    }

    private func attach(_ image: CGImage, _ name: String) {
        let attachment = XCTAttachment(image: NSImage(cgImage: image, size: .zero))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
