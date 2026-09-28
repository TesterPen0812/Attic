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

    /// The Done search's field: on the tabs' line while searching.
    private var searchField: XCUIElement {
        window.textFields.matching(NSPredicate(format: "label == %@", "Search done tasks")).firstMatch
    }

    /// The search field is there and has the keyboard. Reading a missing
    /// element's value fails the test at once (no waiting), so existence is
    /// checked first (round 7: ⌘F's field was read before it appeared).
    private var searchHasKeyboard: Bool {
        searchField.exists && (searchField.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    /// The search's text, or "" while it is not there.
    private var searchText: String {
        searchField.exists ? (searchField.value as? String) ?? "" : ""
    }

    /// The magnifier at the end of the tabs' line on Done.
    private var searchButton: XCUIElement {
        window.buttons["tasks-done-search-button"]
    }

    /// The row lies inside the window (the page shown), not on a page
    /// beside it that is built for the swipe.
    private func isOnScreen(_ title: String) -> Bool {
        let element = row(title)
        guard element.exists else { return false }
        let frame = element.frame
        return window.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
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
        let editor = window.descendants(matching: .any).matching(identifier: "AtticTitleField").firstMatch
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
        // An ordinary drag: no hold before it moves (owner fix 6).
        from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.1)
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

        // "Show Details" on a Done log task opens its details, which offer
        // Restore to Now; the right-click menu restores too.
        row("Send invoice").rightClick()
        let open = app.menuItems["Show Details"]
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

    /// Round 6 (owner item 17, card B of v22): the Done search lives on
    /// the tabs' line. A magnifier at its end; clicking it, ⌘F or typing on
    /// the Done page turns the line into the field; the results mark the
    /// match and end with "N of M done tasks"; Esc returns the tabs.
    func testTheDoneSearchTakesTheTabsLineAndEscReturnsThem() throws {
        XCTAssertFalse(searchButton.exists, "the magnifier is Done's alone")
        tab("done").click()
        waitFor(isOnScreen("Pay rent"), "the Done log shows")
        XCTAssertFalse(searchField.exists, "no search row: the log starts with its days")
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3), "a magnifier at the end of the tabs' line")
        searchButton.click()
        waitFor(searchHasKeyboard, "the field takes the line, with the keyboard")
        XCTAssertFalse(tab("now").exists, "the field is where the tabs were")
        app.typeText("invoice")
        waitFor(!row("Pay rent").exists, "typing filters the log")
        XCTAssertTrue(row("Send invoice").exists)
        let count = window.descendants(matching: .any)["tasks-done-search-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 3), "a quiet count under the results")
        // A static text reads out as its value on macOS (CI run 2: the
        // label was empty).
        let spoken = [count.label, (count.value as? String) ?? ""].first { !$0.isEmpty } ?? ""
        XCTAssertTrue(spoken.hasPrefix("1 of "), "the count says 1 of all: \(spoken)")
        app.typeKey(.escape, modifierFlags: [])
        waitFor(row("Pay rent").exists, "Esc ends the search")
        waitFor(tab("now").exists, "and the tabs return")
        XCTAssertFalse(searchField.exists)

        // ⌘F, and a letter typed with a row focused, open it too.
        app.typeKey("f", modifierFlags: .command)
        waitFor(searchHasKeyboard, "⌘F puts the keyboard in the search")
        app.typeKey(.escape, modifierFlags: [])
        waitFor(tab("now").exists, "Esc returns the tabs")
        waitForSettled(row("Pay rent"))
        select("Pay rent")
        app.typeText("inv")
        waitFor(searchText == "inv", "typing on the Done page searches")
        waitFor(!row("Pay rent").exists, "and filters")
        app.typeKey(.escape, modifierFlags: [])
        waitFor(tab("done").exists && row("Pay rent").exists, "Esc returns the tabs and the whole log")
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

    // MARK: - Round 3: date, tags and priority without the shorthand

    private func menuItem(_ title: String) -> XCUIElement { app.menuItems[title] }

    /// The strip over the add bar (owner fix 5 A2; round 6, item 18): it
    /// shows with a draft; each button shows what the task will get, picked
    /// or typed, on its button (never in the text), with a clear ×; the Tag
    /// button opens the tag list.
    func testTheStripShowsPickedValuesOnItsButtons() throws {
        XCTAssertTrue(addBar.waitForExistence(timeout: 5))
        let date = window.buttons["composer-date"]
        let tag = window.buttons["composer-tag"]
        let priority = window.buttons["composer-priority"]
        XCTAssertFalse(date.exists, "no strip while the bar is empty")
        addBar.click()
        addBar.typeText("Water the ferns")
        XCTAssertTrue(date.waitForExistence(timeout: 3), "the strip shows with the first keystroke")
        date.click()
        let tomorrow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tomorrow")).firstMatch
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 3), "the date picker opens")
        tomorrow.click()
        waitFor((date.value as? String) == "Tomorrow", "the Date button shows the pick: \(String(describing: date.value))")
        XCTAssertEqual(addBar.value as? String, "Water the ferns", "picking never inserts text")
        XCTAssertTrue(window.buttons["composer-date-clear"].exists, "a set button has its ×")

        tag.click()
        let launch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "#launch")).firstMatch
        XCTAssertTrue(launch.waitForExistence(timeout: 3), "the Tag button opens the tag list (it types no #)")
        launch.click()
        waitFor((tag.value as? String) == "launch", "the Tag button shows the tag: \(String(describing: tag.value))")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(addBar.value as? String, "Water the ferns")

        priority.click()
        let high = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "High")).firstMatch
        XCTAssertTrue(high.waitForExistence(timeout: 3), "Priority offers No Priority, Medium and High")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "Low")).firstMatch.exists, "no Low")
        high.click()
        waitFor((priority.value as? String) == "High", "the Priority button shows High")

        // Each × takes its button's value, over the bottom stack's band
        // (round 8: Tag × and Priority × clicked for real).
        window.buttons["composer-priority-clear"].click()
        waitFor((priority.value as? String ?? "").isEmpty, "Priority × clears it")
        window.buttons["composer-tag-clear"].click()
        waitFor((tag.value as? String ?? "").isEmpty, "Tag × clears it")
        // And back, for the task.
        tag.click()
        XCTAssertTrue(launch.waitForExistence(timeout: 3))
        launch.click()
        waitFor((tag.value as? String) == "launch", "the tag again")
        app.typeKey(.escape, modifierFlags: [])
        priority.click()
        XCTAssertTrue(high.waitForExistence(timeout: 3))
        high.click()
        waitFor((priority.value as? String) == "High", "High again")

        // A typed piece shows on its button too; the × clears it, words and all.
        addBar.click()
        addBar.typeKey(.rightArrow, modifierFlags: .command)
        // 31 Dec (not "next week": on a Sunday that is tomorrow too).
        addBar.typeText(" 31 dec ")
        waitFor((date.value as? String)?.isEmpty == false && (date.value as? String) != "Tomorrow",
                "a date typed after the pick replaces it: \(String(describing: date.value))")
        window.buttons["composer-date-clear"].click()
        waitFor((date.value as? String ?? "").isEmpty, "× clears the date")
        waitFor((addBar.value as? String)?.lowercased().contains("dec") == false, "and its typed words")

        addBar.click()
        addBar.typeKey(.rightArrow, modifierFlags: .command)
        addBar.typeText("\r")
        waitFor(row("Water the ferns").exists, "the task is added")
        let spoken = label("Water the ferns")
        XCTAssertTrue(spoken.contains("high priority"), spoken)
        XCTAssertTrue(spoken.contains("tagged launch"), spoken)
        XCTAssertFalse(spoken.contains("due "), spoken)
        waitFor(!date.exists, "the strip goes with the draft")
    }

    /// Round 8 (G1): a mark typed after a pick and sent at once, with no
    /// space after it, is the task's priority; the send button adds it.
    func testSendingAMarkTypedAfterAPickUsesTheMark() throws {
        XCTAssertTrue(addBar.waitForExistence(timeout: 5))
        addBar.click()
        addBar.typeText("Call mom")
        let priority = window.buttons["composer-priority"]
        XCTAssertTrue(priority.waitForExistence(timeout: 3))
        priority.click()
        let high = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "High")).firstMatch
        XCTAssertTrue(high.waitForExistence(timeout: 3))
        high.click()
        waitFor((priority.value as? String) == "High", "picked High")
        addBar.click()
        addBar.typeKey(.rightArrow, modifierFlags: .command)
        addBar.typeText(" !")
        let send = window.buttons["Add"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "the send button shows")
        send.click()
        waitFor(row("Call mom").exists, "the send button adds the task")
        let spoken = label("Call mom")
        XCTAssertTrue(spoken.contains("medium priority"), "the typed mark wins over the pick: \(spoken)")
        XCTAssertFalse(spoken.hasPrefix("Call mom !"), spoken)
    }

    /// The selection bar's controls take their clicks over the bottom
    /// stack's band (round 8): its priority menu and its move button.
    func testTheSelectionBarsControlsTakeTheirClicks() throws {
        select("Call the plumber")
        XCUIElement.perform(withKeyModifiers: .command) { select("Email beta testers") }
        let move = window.buttons["Move 2 tasks to Later"]
        XCTAssertTrue(move.waitForExistence(timeout: 3), "the selection bar shows")
        window.buttons["Set priority of 2 tasks"].click()
        let high = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "High")).firstMatch
        XCTAssertTrue(high.waitForExistence(timeout: 3), "its priority menu opens")
        XCTAssertFalse(app.menuItems.matching(NSPredicate(format: "title == %@", "Low")).firstMatch.exists, "no Low")
        high.click()
        waitFor(label("Call the plumber").contains("high priority") && label("Email beta testers").contains("high priority"),
                "the bar set both to High")
        XCTAssertTrue(move.waitForExistence(timeout: 3))
        move.click()
        waitFor(!row("Call the plumber").exists && !row("Email beta testers").exists, "the bar moved both to Later")
        app.typeKey("z", modifierFlags: .command)
        waitFor(row("Call the plumber").exists && row("Email beta testers").exists, "⌘Z brings them back")
    }

    /// Suggestions while typing (owner fix 5 B, review 15): Tab takes the
    /// highlighted tag and keeps editing; the next Return adds the task.
    func testSuggestionsTakeATagAndADateWithTab() throws {
        XCTAssertTrue(addBar.waitForExistence(timeout: 5))
        addBar.click()
        addBar.typeText("Buy stamps #lau")
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
        waitFor((addBar.value as? String) == "Buy stamps #launch ", "Tab takes the suggested tag")
        addBar.typeText("tom")
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
        waitFor((addBar.value as? String) == "Buy stamps #launch tomorrow ", "and the day a date word means")
        XCTAssertFalse(row("Buy stamps").exists, "taking a suggestion never adds the task")
        addBar.typeText("\r")
        waitFor(row("Buy stamps").exists, "Return adds it")
        XCTAssertTrue(label("Buy stamps").contains("tagged launch"), label("Buy stamps"))
        XCTAssertTrue(label("Buy stamps").contains("due Tomorrow"), label("Buy stamps"))
    }

    /// Date and Tags in the right-click menu (owner fixes 3 and 5 D).
    func testTheRightClickMenuSetsTheDateAndTags() throws {
        row("Call the plumber").rightClick()
        XCTAssertTrue(menuItem("Date").waitForExistence(timeout: 3))
        menuItem("Date").hover()
        XCTAssertTrue(menuItem("Tomorrow").waitForExistence(timeout: 3), "Today, Tomorrow, Next Week")
        XCTAssertTrue(menuItem("Pick a Date…").exists)
        menuItem("Tomorrow").click()
        waitFor(label("Call the plumber").contains("due Tomorrow"), "the date is set")
        row("Call the plumber").rightClick()
        XCTAssertTrue(menuItem("Tags").waitForExistence(timeout: 3))
        menuItem("Tags").hover()
        XCTAssertTrue(menuItem("#launch").waitForExistence(timeout: 3), "the library's tags")
        XCTAssertTrue(menuItem("New Tag…").exists)
        menuItem("#launch").click()
        waitFor(label("Call the plumber").contains("tagged launch"), "the tag is added")
        row("Call the plumber").rightClick()
        menuItem("Date").hover()
        XCTAssertTrue(menuItem("Remove Date").waitForExistence(timeout: 3))
        menuItem("Remove Date").click()
        waitFor(!label("Call the plumber").contains("due"), "Remove Date takes it away")
    }

    /// A row's date is a button (owner fix 5 C): it opens the same picker,
    /// with Remove date.
    func testARowsDateOpensThePicker() throws {
        // The date sits at the row's right end, on the title line.
        let row = row("Book dentist")
        row.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: row.frame.width - 50, dy: 17)).click()
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove date")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3), "the picker offers Remove date")
        remove.click()
        waitFor(!label("Book dentist").contains("due"), "the date is removed")
        let toast = window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Date removed")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "with an Undo toast")
    }

    /// Edit Title understands the shorthand as a patch (owner fix 4).
    func testEditTitleUnderstandsTheShorthand() throws {
        select("Call the plumber")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let editor = window.descendants(matching: .any).matching(identifier: "AtticTitleField").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "Return opens the title editor")
        waitFor((editor.value(forKey: "hasKeyboardFocus") as? Bool) == true, "the editor has the keyboard")
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: .command)
        app.typeText(" #launch tomorrow !!\r")
        waitFor(label("Call the plumber").contains("tagged launch"), "the tag applies")
        XCTAssertTrue(label("Call the plumber").contains("due Tomorrow"), label("Call the plumber"))
        XCTAssertTrue(label("Call the plumber").contains("high priority"), label("Call the plumber"))
    }

    /// The owner's blocker (round 5): Backspace in "Find or add a tag"
    /// deleted the task. A field that is typing keeps every key: Backspace,
    /// Space and Return edit the query, never the row.
    func testKeysTypedInTheTagPickerStayInItsField() throws {
        row("Call the plumber").rightClick()
        XCTAssertTrue(menuItem("Tags").waitForExistence(timeout: 3))
        menuItem("Tags").hover()
        XCTAssertTrue(menuItem("New Tag…").waitForExistence(timeout: 3))
        menuItem("New Tag…").click()
        let field = app.descendants(matching: .textField)
            .matching(NSPredicate(format: "label == %@", "Find or add a tag")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the tag picker opens with its field")
        field.click()
        field.typeText("gardn")
        field.typeKey(.delete, modifierFlags: [])
        field.typeKey(.delete, modifierFlags: [])
        waitFor((field.value as? String) == "gar", "Backspace edited the query: \(String(describing: field.value))")
        field.typeText(" x")
        field.typeKey(.delete, modifierFlags: [])
        field.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(row("Call the plumber").exists, "the task is still there")
        XCTAssertTrue(label("Call the plumber").contains(", to do"), "Space in the field did not complete it")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(row("Call the plumber").exists)
    }

    /// The row's keys a person might press while the keyboard is somewhere
    /// else: Backspace, forward delete, Space, ⇧Space and ⌘B.
    private func pressRowKeys(in element: XCUIElement? = nil) {
        let target: XCUIElement = element ?? app
        target.typeKey(.delete, modifierFlags: [])
        target.typeKey(.forwardDelete, modifierFlags: [])
        target.typeKey(.space, modifierFlags: [])
        target.typeKey(.space, modifierFlags: .shift)
        target.typeKey("b", modifierFlags: .command)
    }

    /// Round 5 (the class of the owner's blocker): the date picker has no
    /// field, and its keys are still its own, never the row's Delete,
    /// Complete, Start working or Move to Later.
    func testKeysPressedInTheDatePickerNeverReachTheRow() throws {
        let row = row("Book dentist")
        row.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: row.frame.width - 50, dy: 17)).click()
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove date")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3), "the date picker opens")
        pressRowKeys()
        XCTAssertTrue(self.row("Book dentist").exists, "the task is still there")
        let spoken = label("Book dentist")
        XCTAssertTrue(spoken.contains(", to do"), "not completed or started: \(spoken)")
        XCTAssertTrue(spoken.contains("due Tomorrow"), "its date is as it was: \(spoken)")
        app.typeKey(.escape, modifierFlags: [])
        waitFor(!remove.exists, "Esc closes the picker")
        XCTAssertTrue(self.row("Book dentist").exists, "still on Now")
    }

    /// Round 5: the add bar's suggestion list keeps the keys in the draft.
    func testKeysTypedWithTheSuggestionsShowingStayInTheDraft() throws {
        select("Call the plumber")
        XCTAssertTrue(addBar.waitForExistence(timeout: 5))
        addBar.click()
        addBar.typeText("Buy #la")
        let suggestion = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "#launch")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3), "the suggestions show")
        // The first Backspace may turn the recognised "#la" back into text
        // (a chip's Backspace deletes nothing); either way the keys stay in
        // the draft.
        addBar.typeKey(.delete, modifierFlags: [])
        addBar.typeKey(.delete, modifierFlags: [])
        waitFor(["Buy #", "Buy #l"].contains((addBar.value as? String) ?? ""),
                "Backspace edited the draft: \(String(describing: addBar.value))")
        addBar.typeKey(.space, modifierFlags: [])
        addBar.typeKey(.space, modifierFlags: .shift)
        XCTAssertTrue(row("Call the plumber").exists, "the selected task is still there")
        XCTAssertTrue(label("Call the plumber").contains(", to do"), label("Call the plumber"))
        XCTAssertFalse(row("Buy").exists, "nothing was added")
    }

    /// Round 5: the title editor keeps every key; Esc discards the edit.
    func testKeysTypedInTheTitleEditorStayInIt() throws {
        select("Call the plumber")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let editor = window.descendants(matching: .any).matching(identifier: "AtticTitleField").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "Return opens the title editor")
        waitFor((editor.value(forKey: "hasKeyboardFocus") as? Bool) == true, "the editor has the keyboard")
        editor.typeKey(.delete, modifierFlags: [])
        editor.typeKey(.delete, modifierFlags: [])
        waitFor((editor.value as? String) == "Call the plumb", "Backspace edited the title: \(String(describing: editor.value))")
        pressRowKeys(in: editor)
        app.typeKey(.escape, modifierFlags: [])
        waitFor(row("Call the plumber").exists, "Esc keeps the title as it was, and the task is there")
        XCTAssertTrue(label("Call the plumber").contains(", to do"), label("Call the plumber"))
    }

    /// Round 5: Done's search keeps every key; the Done row it filters is
    /// never restored or un-completed by them.
    func testKeysTypedInTheDoneSearchStayInIt() throws {
        tab("done").click()
        waitFor(isOnScreen("Pay rent"), "the Done log shows")
        waitForSettled(row("Pay rent"))
        select("Pay rent")
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        searchButton.click()
        waitFor(searchHasKeyboard, "the search has the keyboard")
        app.typeText("pay")
        app.typeKey(.delete, modifierFlags: [])
        waitFor(searchText == "pa", "Backspace edited the search")
        app.typeKey(.space, modifierFlags: [])
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(row("Pay rent").exists, "the Done task is still listed")
        app.typeKey(.escape, modifierFlags: [])
        waitFor(row("Send invoice").exists, "Esc clears the search")
        XCTAssertTrue(row("Pay rent").exists, "still in the Done log")
    }

    /// The tag popover points at the tags that were clicked (round 5, the
    /// owner's item 3), not the middle of the row.
    func testTheTagPopoverOpensFromTheClickedTags() throws {
        row("Call the plumber").rightClick()
        XCTAssertTrue(menuItem("Tags").waitForExistence(timeout: 3))
        menuItem("Tags").hover()
        XCTAssertTrue(menuItem("#launch").waitForExistence(timeout: 3))
        menuItem("#launch").click()
        waitFor(label("Call the plumber").contains("tagged launch"), "the tag is added")
        // The tags lead the details line, under the title's start (text at
        // 44 pt; the details line is the row's lower line).
        let rowFrame = row("Call the plumber").frame
        let tagPoint = CGPoint(x: rowFrame.minX + 44 + 16, y: rowFrame.maxY - 14)
        row("Call the plumber").coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: tagPoint.x - rowFrame.minX, dy: tagPoint.y - rowFrame.minY)).click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 3), "the tag picker opens")
        // Centred on the tags it came from (a popover centres on its anchor
        // unless a screen edge pushes it), not on the row's middle.
        XCTAssertLessThan(abs(popover.frame.midX - tagPoint.x), 40,
                          "popover \(popover.frame) points at the tags near \(tagPoint), not the row \(rowFrame)")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Waits until `element` has stopped moving (a page sliding in).
    private func waitForSettled(_ element: XCUIElement, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = element.frame
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let now = element.frame
            if now == last { return }
            last = now
        }
    }

    /// Round 5 (the owner's Done row stayed lit): a click on the list's
    /// empty space, or on Done's search, leaves no row lit; nothing is lit
    /// that the person did not click or reach with the keyboard.
    func testAClickElsewhereInTheListLeavesNoRowLit() throws {
        XCTAssertFalse(row("Call the plumber").isSelected, "nothing is lit on opening")
        select("Call the plumber")
        waitFor(row("Call the plumber").isSelected, "a click on the row selects it")
        // The space between the last line of the list and the add bar.
        XCTAssertTrue(completedToday.waitForExistence(timeout: 3))
        let gapTop = completedToday.frame.maxY, gapBottom = addBar.frame.minY
        XCTAssertGreaterThan(gapBottom - gapTop, 40, "the demo list leaves space under its last line")
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.width / 2, dy: (gapTop + gapBottom) / 2 - window.frame.minY)).click()
        waitFor(!row("Call the plumber").isSelected, "a click on the empty space clears it")

        tab("done").click()
        waitFor(row("Pay rent").isHittable, "the Done log shows")
        XCTAssertFalse(row("Send invoice").isSelected, "Done's first row is not lit on arrival")
        // The pager slides the Done page in: click once it has settled, or
        // the click lands where the row was a moment before.
        waitForSettled(row("Pay rent"))
        select("Pay rent")
        waitFor(row("Pay rent").isSelected, "a click selects it")
        searchButton.click()
        waitFor(!row("Pay rent").isSelected, "starting a search clears it")
        XCTAssertFalse(row("Send invoice").isSelected)
    }

    // MARK: - Round 6: Done rows take clicks (owner item 23)

    /// Done rows are selected by a click, ⇧-click extends and ⌘-click
    /// adds, as on Now and Later; Restore acts on the selection as one
    /// step, and one ⌘Z puts them all back.
    func testDoneRowsAreClickSelectableAndRestoreTogether() throws {
        tab("done").click()
        waitFor(isOnScreen("Pay rent"), "the Done log shows")
        waitForSettled(row("Pay rent"))
        select("Call the bank")
        waitFor(row("Call the bank").isSelected, "a click selects a Done row")
        XCUIElement.perform(withKeyModifiers: .shift) { select("Pay rent") }
        waitFor(row("Pay rent").isSelected && row("Call the bank").isSelected, "⇧-click extends the selection")
        XCUIElement.perform(withKeyModifiers: .command) { select("Send invoice") }
        waitFor(row("Send invoice").isSelected, "⌘-click adds a row")
        XCTAssertTrue(row("Pay rent").isSelected)
        XCTAssertFalse(row("Water the plants").isSelected, "⌘-click adds only that row")
        row("Pay rent").rightClick()
        let restore = menuItem("Restore 3 Tasks to Now")
        XCTAssertTrue(restore.waitForExistence(timeout: 3), "the menu restores the selection")
        restore.click()
        waitFor(!row("Pay rent").exists && !row("Call the bank").exists && !row("Send invoice").exists,
                "all three leave the Done log")
        app.typeKey("z", modifierFlags: .command)
        waitFor(row("Pay rent").exists && row("Call the bank").exists && row("Send invoice").exists,
                "one ⌘Z puts all three back")
    }

    // MARK: - Round 6: pages (owner items 21 and 22)

    /// Each page's own row, to tell which page is shown.
    private func landmark(_ page: String) -> String {
        switch page {
        case "now": "Call the plumber"
        case "backlog": "Plan the spring trip"
        default: "Pay rent"
        }
    }

    private func waitForPage(_ page: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(tab(page).isSelected && isOnScreen(landmark(page)), message, file: file, line: line)
        for other in ["now", "backlog", "done"] where other != page {
            XCTAssertFalse(isOnScreen(landmark(other)), "\(message): \(other) is not shown", file: file, line: line)
        }
    }

    /// A click on a tab lands on that page from every other page (round 5
    /// landed on Later when Done was clicked from Now).
    func testEveryTabClickLandsOnItsPageFromEveryOther() throws {
        let pages = ["now", "backlog", "done"]
        for from in pages {
            for to in pages where to != from {
                tab(from).click()
                waitForPage(from, "on \(from)")
                tab(to).click()
                waitForPage(to, "a click on \(to) from \(from) lands on \(to)")
            }
        }
    }

    /// One hard swipe from Now stops at Later, never Done (owner item 21).
    /// The scroll's sign differs between Xcode versions: if the first
    /// swipe goes the other way (Now stays), the second is the same swipe
    /// forwards.
    func testAHardSwipeFromNowStopsAtLater() throws {
        waitForPage("now", "the panel opens on Now")
        let point = row("Call the plumber").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.hover()
        // Synthesized scrolls carry no trackpad phases or momentum and are
        // sometimes dropped on a busy runner: a gesture that moved nothing
        // is sent again (it proves one gesture never crosses two pages, not
        // a real trackpad's feel).
        for delta in [-2_000.0, 2_000.0, -2_000.0, 2_000.0] {
            point.scroll(byDeltaX: delta, deltaY: 0)
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, tab("now").isSelected { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            // Let any momentum finish before judging where it stopped.
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            if !tab("now").isSelected { break }
        }
        XCTAssertFalse(tab("done").isSelected, "a hard swipe never crosses two pages")
        waitForPage("backlog", "a hard swipe from Now stops at Later")
    }
}
