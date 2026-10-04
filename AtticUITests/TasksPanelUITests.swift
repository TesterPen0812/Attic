import AppKit
import XCTest

/// The Tasks page inside the real panel (not the standalone preview window):
/// the page tabs, the pinned state, Now on every reveal, a long title, the
/// row quick look, the files panel "Open page" leads to until task pages
/// arrive, and a page kept built behind another one taking no keys, clicks
/// or VoiceOver. The in-memory UI-test store holds the demo tasks
/// (`ATTIC_UI_TEST_SEED=demo`).
final class TasksPanelUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_SEED"] = "demo"
        // The real hover monitor (auto-hide on once the test unpins): the
        // menu routes to Open Files are checked as a person meets them.
        if name.contains("testNativeContextMenu") || name.contains("OnALaterRow") {
            app.launchEnvironment["ATTIC_UI_TEST_HOVER_MONITOR"] = "1"
            app.launchEnvironment["ATTIC_UI_TEST_PINNED"] = "1"
        }
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

    private func tab(_ page: String) -> XCUIElement {
        app.buttons["tasks-page-\(page)"]
    }

    private var pin: XCUIElement { app.buttons["panel-pin-button"] }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// The row's status circle: 16 pt, centred 24 pt in from the row's
    /// leading edge on the title line (the 28 pt hit area takes 16 down).
    private func circle(_ title: String) -> XCUICoordinate {
        row(title).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 16))
    }

    /// A click on the row's title (it selects; the circle completes).
    private func select(_ title: String) {
        row(title).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 16)).click()
    }

    // MARK: - Tabs

    func testTheTabsMoveBetweenNowLaterAndDone() throws {
        let group = app.descendants(matching: .any)["tasks-page-tabs"]
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        XCTAssertEqual(group.label, "Pages", "the tabs are one group for VoiceOver")
        XCTAssertTrue(tab("now").isSelected, "Tasks opens on Now")
        for (page, title, task) in [("backlog", "Later", "Plan the spring trip"), ("done", "Done", "Send invoice"),
                                    ("now", "Now", "Book dentist")] {
            let choice = tab(page)
            XCTAssertEqual(choice.label, title)
            choice.click()
            waitFor(row(task).exists, "\(title) lists its tasks")
            waitFor(choice.isSelected, "\(title) reads as the selected tab")
            XCTAssertEqual(["now", "backlog", "done"].filter { tab($0).isSelected }, [page], "exactly one tab is selected")
        }
        // Only the page shown is read: the other pages built for the swipe
        // are hidden from VoiceOver.
        XCTAssertFalse(row("Plan the spring trip").exists)
    }

    /// The panel opens on the page Tasks was left on (L7, follow-up part 2;
    /// before, always Now): hidden with Esc and shown again from the
    /// menu-bar item, three times.
    func testThePanelOpensOnThePageLastUsed() throws {
        for page in ["backlog", "done", "backlog"] {
            tab(page).click()
            waitFor(tab(page).isSelected, "\(page) is shown")
            pin.coordinate(withNormalizedOffset: CGVector(dx: 2.6, dy: 0.5)).click()
            app.typeKey(.escape, modifierFlags: [])
            if pin.exists { app.typeKey(.escape, modifierFlags: []) }
            XCTAssertTrue(pin.waitForNonExistence(timeout: 3), "Esc hides the panel")

            let item = app.statusItems.firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "the menu-bar item is there")
            item.click()
            let show = app.menuItems["Show Attic"]
            XCTAssertTrue(show.waitForExistence(timeout: 3))
            show.click()
            XCTAssertTrue(pin.waitForExistence(timeout: 3), "Show Attic reveals the panel")
            waitFor(tab(page).isSelected, "the panel opens on \(page), where it was left")
            XCTAssertFalse(tab("now").isSelected)
        }
    }

    // MARK: - Pinned

    /// Pinning shows as the pin's selected state and leaves the list where
    /// it was; unpinning puts the button back.
    func testPinningKeepsTheListInPlace() throws {
        XCTAssertFalse(pin.isSelected)
        XCTAssertEqual(pin.label, "Pin panel")
        let before = row("Book dentist").frame
        pin.click()
        waitFor(pin.isSelected, "the pin reads as selected")
        XCTAssertEqual(pin.label, "Unpin panel")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let after = row("Book dentist").frame
        XCTAssertEqual(after.minX, before.minX, accuracy: 0.5, "pinning does not move the list")
        XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, "pinning does not move the list")
        pin.click()
        waitFor(!pin.isSelected, "unpinned")
        XCTAssertEqual(pin.label, "Pin panel")
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
        select("Ship appearance PR")
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
        let field = app.textFields.matching(NSPredicate(format: "identifier != %@", "AtticTokenField")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "Add subtask opens its field")
        waitFor((field.value(forKey: "hasKeyboardFocus") as? Bool) == true, "the field has the keyboard")
        app.typeText("Pack the charger\r")
        let added = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Pack the charger")).firstMatch
        waitFor(added.exists, "Return adds the subtask")
        waitFor(row("Ship appearance PR").label.contains("3 of 5 subtasks"), "the row counts the new one")
        app.typeKey(.escape, modifierFlags: [])

        select("Ship appearance PR")
        app.typeKey(.escape, modifierFlags: [])
        waitFor(!merge.exists, "Esc closes the quick look")
        XCTAssertTrue(pin.exists, "and nothing more")
    }

    // MARK: - Files panel

    /// "Open page" (⌘Return) opens the task's files in the old detail
    /// panel, with no way to its Subtasks editor; it pins, and Esc
    /// dismisses it without taking the main panel with it.
    func testOpenPageShowsTheFilesPanelThatPinsAndDismisses() throws {
        select("Book dentist")
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
        XCTAssertTrue(pin.exists, "the main panel stays")

        select("Book dentist")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(transient.waitForExistence(timeout: 3))
        let filesPin = element("subtask-pin-")
        XCTAssertTrue(filesPin.waitForExistence(timeout: 3))
        filesPin.click()
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

    /// The pinned files window is its own window: it stays when another
    /// app takes the foreground, and its header drags it.
    func testThePinnedFilesWindowSurvivesDeactivationAndDragsByItsHeader() throws {
        select("Book dentist")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(element("subtask-panel-").waitForExistence(timeout: 3), "the files panel opens")
        let filesPin = element("subtask-pin-")
        XCTAssertTrue(filesPin.waitForExistence(timeout: 3))
        filesPin.click()
        let pinned = element("subtask-pinned-")
        XCTAssertTrue(pinned.waitForExistence(timeout: 3))
        XCTAssertFalse(element("subtask-panel-").exists, "pinning promotes the panel, never duplicates it")

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(pinned.exists, "the pinned window stays when Attic loses the foreground")
        app.activate()
        XCTAssertTrue(pinned.waitForExistence(timeout: 3))

        let handle = element("subtask-drag-")
        XCTAssertTrue(handle.waitForExistence(timeout: 3), "the pinned header exposes its drag handle")
        let initial = pinned.frame
        let press = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        press.click(forDuration: 0.2, thenDragTo: press.withOffset(CGVector(dx: -120, dy: 80)))
        waitFor(abs(pinned.frame.minX - (initial.minX - 120)) < 10 && abs(pinned.frame.minY - (initial.minY + 80)) < 10,
                "the pinned window follows a header drag (\(initial) → \(pinned.frame))")
        pinned.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        for _ in 0..<3 where pinned.exists {
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        waitFor(!pinned.exists, "Esc dismisses it")
    }

    /// A menu item on screen with this title (an open pop-up or context
    /// menu's, never the menu bar's own, which have no size until opened).
    private func openMenuItem(_ title: String) -> XCUIElement {
        let items = app.menuItems.matching(NSPredicate(format: "title == %@ OR title BEGINSWITH %@", title, title + ", "))
        return items.allElementsBoundByIndex.first { $0.frame.width > 0 && $0.frame.height > 0 } ?? items.firstMatch
    }

    /// More › Open Files… in the menu that is open.
    private func chooseOpenFiles(_ route: String) {
        let more = openMenuItem("More")
        XCTAssertTrue(more.waitForExistence(timeout: 3), "\(route): the task's menu opens")
        more.hover()
        waitFor(openMenuItem("Open Files…").frame.width > 0, "\(route): More's submenu opens")
        openMenuItem("Open Files…").click()
    }

    /// The files panel a menu opened is there and stays: the pointer goes
    /// off both windows (where a native submenu can leave it) and the test
    /// waits past the hide delay with time to spare. A panel that appears
    /// and vanishes again fails here (PR prep P1-1: `waitForExistence`
    /// alone passed the CI run 3 recording, where it flashed and went).
    private func assertFilesPanelStaysOpen(_ route: String, file: StaticString = #filePath, line: UInt = #line) {
        let transient = element("subtask-panel-")
        XCTAssertTrue(transient.waitForExistence(timeout: 10), "\(route) shows the files panel", file: file, line: line)
        XCTAssertTrue(element("add-attachment-").waitForExistence(timeout: 5), "\(route): on the task's files", file: file, line: line)
        let windows = app.dialogs.allElementsBoundByIndex.map(\.frame).filter { !$0.isEmpty }
        let union = windows.dropFirst().reduce(windows.first ?? pin.frame) { $0.union($1) }
        let screenWidth = NSScreen.screens.map(\.frame.maxX).max() ?? 1_440
        let x = union.minX - 80 > 10 ? union.minX - 80 : min(union.maxX + 80, screenWidth - 10)
        pin.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x - pin.frame.minX, dy: union.midY - pin.frame.minY))
            .hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        XCTAssertTrue(transient.exists, "\(route): the files panel stays with the pointer away, past the hide delay", file: file, line: line)
        XCTAssertTrue(element("add-attachment-").exists, "\(route): still on the task's files", file: file, line: line)
        XCTAssertTrue(pin.exists, "\(route): and the main panel with it", file: file, line: line)
    }

    /// Unpins the panel the hover-monitor launches start pinned, so the
    /// real auto-hide applies from here.
    private func unpin() {
        XCTAssertTrue(pin.wait(for: \.isSelected, toEqual: true, timeout: 5))
        pin.click()
        XCTAssertTrue(pin.wait(for: \.isSelected, toEqual: false, timeout: 5))
    }

    /// Closes the files panel with a click back in the main panel (on the
    /// tabs, not the task's own row), which also brings the pointer home
    /// before the unpinned panel's hide delay can run.
    private func closeFilesPanelFromTheMainPanel(_ transient: XCUIElement) {
        tab("backlog").click()
        waitFor(!transient.exists, "a click in the main panel closes the files panel")
        XCTAssertTrue(pin.exists, "the main panel stays")
    }

    private func dismissFilesPanel(_ transient: XCUIElement) {
        transient.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        for _ in 0..<3 where transient.exists {
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        waitFor(!transient.exists, "Esc dismisses the files panel")
    }

    /// Open Files… opens the task's files from every route (deep review
    /// P2-03: the right-click menu's opened nothing, while ⌘Return and
    /// ⇧⌘I's menu did): the row's right-click menu, then ⇧⌘I's menu, both
    /// under More.
    func testOpenFilesFromTheRightClickMenuAndTheActionsMenuOpensTheFilesPanel() throws {
        let transient = element("subtask-panel-")
        row("Book dentist").coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 16)).rightClick()
        chooseOpenFiles("right-click")
        XCTAssertTrue(transient.waitForExistence(timeout: 3), "the right-click menu's Open Files… opens the files panel")
        XCTAssertTrue(element("add-attachment-").exists, "on the task's files")
        dismissFilesPanel(transient)
        XCTAssertTrue(pin.exists, "the main panel stays")

        select("Book dentist")
        app.typeKey("i", modifierFlags: [.command, .shift])
        chooseOpenFiles("⇧⌘I")
        XCTAssertTrue(transient.waitForExistence(timeout: 3), "⇧⌘I's Open Files… opens it too")
        dismissFilesPanel(transient)
    }

    /// Unlike the mouse-only case, Return selects the native submenu item
    /// while the composer remains first responder underneath the NSMenu.
    /// This was the real-app route that silently rejected Open Files.
    func testNativeContextMenuReturnOpensFilesWhileTheComposerHasFocus() throws {
        XCTAssertTrue(addBar.waitForExistence(timeout: 10))
        unpin()
        addBar.click()
        addBar.typeText("Keep this draft")
        XCTAssertEqual(addBar.value(forKey: "hasKeyboardFocus") as? Bool, true)
        XCTAssertEqual(addBar.value as? String, "Keep this draft")

        row("Book dentist").coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 16)).rightClick()
        XCTAssertTrue(openMenuItem("More").waitForExistence(timeout: 5))
        // From no highlighted item: Up selects Delete, Up selects More,
        // Right enters its submenu, and Return chooses Open Files.
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(openMenuItem("Open Files…").waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(openMenuItem("More").waitForNonExistence(timeout: 5), "the native context menu closes")
        assertFilesPanelStaysOpen("Return on the native More › Open Files…")
        XCTAssertTrue(app.staticTexts["No attachments yet"].exists)
        XCTAssertEqual(addBar.value as? String, "Keep this draft", "the menu's Return did not submit the composer")
    }

    /// The ordinary app's auto-hide is active, the composer is clean, and
    /// Find has rebuilt this row before the native submenu is selected.
    func testNativeContextMenuAfterFindOpensFilesWithRealAutoHide() throws {
        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["tasks-find"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("dentist")
        XCTAssertTrue(row("Book dentist").waitForExistence(timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row("Book dentist").wait(for: \.isHittable, toEqual: true, timeout: 5))
        unpin()
        // All pointer actions stay in the row or its tracked menu. No draft,
        // test-only keep-visible grace, or pin protects the command.
        row("Book dentist").coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 16)).rightClick()
        let more = openMenuItem("More")
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.hover()
        let openFiles = openMenuItem("Open Files…")
        XCTAssertTrue(openFiles.waitForExistence(timeout: 5))
        openFiles.hover()
        app.typeKey(.return, modifierFlags: [])
        assertFilesPanelStaysOpen("native Open Files after Find, with real auto-hide")
        XCTAssertTrue(app.staticTexts["No attachments yet"].exists)
    }

    /// CU recheck 3's routes, on a Later row with the real auto-hide: the
    /// row's right-click menu and ⇧⌘I's menu, each walked with the keys
    /// and chosen with Return, and ⇧⌘I's chosen with a click. Each leaves
    /// the files panel open with the pointer away.
    func testOpenFilesFromBothMenusOnALaterRowStaysOpen() throws {
        unpin()
        tab("backlog").click()
        let trip = row("Plan the spring trip")
        XCTAssertTrue(trip.waitForExistence(timeout: 5), "Later lists the task")
        let transient = element("subtask-panel-")

        // Right-click › (Up, Up: More) › Right › Return.
        trip.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 16)).rightClick()
        XCTAssertTrue(openMenuItem("More").waitForExistence(timeout: 5))
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(openMenuItem("Open Files…").waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        assertFilesPanelStaysOpen("Later: right-click › More › Open Files… with Return")
        closeFilesPanelFromTheMainPanel(transient)

        // ⇧⌘I › (Up, Up: More) › Right › Return, from the keyboard alone.
        select("Plan the spring trip")
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(openMenuItem("More").waitForExistence(timeout: 5))
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(openMenuItem("Open Files…").waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        assertFilesPanelStaysOpen("Later: ⇧⌘I › More › Open Files… with Return")
        closeFilesPanelFromTheMainPanel(transient)

        // ⇧⌘I › More › Open Files…, clicked.
        select("Plan the spring trip")
        app.typeKey("i", modifierFlags: [.command, .shift])
        chooseOpenFiles("Later: ⇧⌘I, clicked")
        assertFilesPanelStaysOpen("Later: ⇧⌘I › More › Open Files…, clicked")
        closeFilesPanelFromTheMainPanel(transient)
    }

    // MARK: - A page kept built behind another

    /// Tasks stays built behind Canvas: while hidden it takes no clicks, no
    /// keys and is not read by VoiceOver; back on Tasks, nothing changed.
    func testAHiddenTasksPageTakesNoKeysClicksOrVoiceOver() throws {
        XCTAssertTrue(addBar.waitForExistence(timeout: 3))
        addBar.click()
        app.typeText("Kept draft")
        // Where the circle is, fixed to the panel (the row leaves the
        // accessibility tree once Tasks is hidden).
        let panel = app.dialogs.firstMatch
        let rowFrame = row("Book dentist").frame
        let circlePoint = panel.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: rowFrame.minX + 24 - panel.frame.minX, dy: rowFrame.minY + 16 - panel.frame.minY))

        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["canvas-surface"].waitForExistence(timeout: 5))
        // The select tool: a click on empty canvas then changes nothing.
        let selectTool = app.buttons["canvas-tool-select"]
        XCTAssertTrue(selectTool.waitForExistence(timeout: 3))
        selectTool.click()
        waitFor(!row("Book dentist").exists, "VoiceOver does not read the hidden Tasks page")
        XCTAssertFalse(addBar.exists, "nor its add bar")

        circlePoint.click()                       // where the hidden circle is
        app.typeKey("9", modifierFlags: [])       // a key the hidden field must not take

        app.typeKey("1", modifierFlags: .command)
        waitFor(app.buttons["panel-section-tasks"].isSelected, "⌘1 shows Tasks again")
        waitFor(row("Book dentist").exists, "Tasks shows again")
        XCTAssertTrue(row("Book dentist").label.contains("to do"), "the click did not reach the hidden circle")
        XCTAssertEqual(addBar.value as? String, "Kept draft", "the key did not reach the hidden add bar")
    }
}

/// The empty states, in the real panel over the caught-up seed: nothing
/// open, six tasks finished today, Later empty
/// (`ATTIC_UI_TEST_SEED=caughtup`).
final class TasksEmptyStateUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_SEED"] = "caughtup"
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["panel-pin-button"].waitForExistence(timeout: 5))
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private func emptyLine(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
    }

    func testNowIsCaughtUpAndLaterIsEmpty() throws {
        XCTAssertTrue(emptyLine("You’re caught up").waitForExistence(timeout: 3), "Now says it is caught up")
        let completed = app.descendants(matching: .any)["tasks-completed-today"]
        XCTAssertTrue(completed.exists, "with today's tasks one row below")
        XCTAssertEqual(completed.label, "Completed today, 6")
        XCTAssertEqual(completed.frame.minY - emptyLine("You’re caught up").frame.minY, 34, accuracy: 10,
                       "one row apart")

        app.buttons["tasks-page-backlog"].click()
        XCTAssertTrue(emptyLine("Nothing for later").waitForExistence(timeout: 3), "Later says it is empty")

        app.buttons["tasks-page-done"].click()
        let finished = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Send invoice,")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 3), "Done lists today's finished tasks")
    }
}
