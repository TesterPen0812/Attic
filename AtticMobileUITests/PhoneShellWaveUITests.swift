import XCTest

/// Real headless iPhone Simulator interactions and screenshot evidence for the
/// first page wave. This suite never resets local data or opens a Mac window.
final class PhoneShellWaveUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_TESTING"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 12))
    }

    override func tearDownWithError() throws {
        if app.state == .runningForeground { app.terminate() }
        app = nil
    }

    func testRootNavigationAndDraftSurvival() throws {
        screenshot("Home")
        let tasks = app.buttons["Tasks"]
        XCTAssertTrue(tasks.isHittable)
        tasks.tap()
        XCTAssertTrue(app.staticTexts["Tasks"].waitForExistence(timeout: 6))
        screenshot("Tasks")
        let calendar = app.buttons["Calendar"]
        XCTAssertTrue(calendar.isHittable)
        calendar.tap()
        XCTAssertTrue(app.buttons["phone-calendar-month-toggle"].waitForExistence(timeout: 8))
        screenshot("Calendar")
        app.buttons["Home"].tap()

        let create = app.buttons["Create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let title = app.textFields["phone-capture-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let unique = "Draft survives close " + UUID().uuidString.prefix(8)
        title.tap()
        title.typeText(unique)
        screenshot("Capture draft")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        XCTAssertEqual(title.value as? String, unique, "Closing capture must preserve the draft")
        let saveButton = app.buttons["phone-capture-create"]
        XCTAssertTrue(saveButton.isEnabled, "The restored draft must make Create available")
        saveButton.tap()
        XCTAssertFalse(app.alerts["Could not save"].exists, "A failed save must surface as a visible alert")
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed,
                       "Successful create must dismiss Capture before Home can receive touches")
        XCTAssertTrue(create.isHittable)

        // A successfully created draft must not reappear on the next capture.
        create.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue((title.value as? String) != unique, "A committed draft must reset")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
        ], timeout: 8), .completed)

        let notes = app.buttons["All notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        XCTAssertTrue(notes.isHittable)
        notes.tap()
        XCTAssertTrue(app.staticTexts["phone-all-notes-title"].waitForExistence(timeout: 5),
                      "Home link must open the destination, not just remain visible on Home")
        XCTAssertTrue(app.buttons["Back"].isHittable)
        screenshot("All notes")
        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["Canvases"].isHittable)
        app.buttons["Canvases"].tap()
        XCTAssertTrue(app.staticTexts["phone-canvases-title"].waitForExistence(timeout: 5))
        screenshot("Canvases")
        app.buttons["Back"].tap()
        let search = app.buttons["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(app.textFields["phone-search-field"].waitForExistence(timeout: 5))
        screenshot("Search")
    }

    func testHomeTagRowsAreReachablePastFloatingDock() throws {
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for _ in 0..<4 { scroll.swipeUp() }
        // The dedicated overnight Simulator has three note tags; project is
        // last alphabetically. A task-only tag does not belong in this list.
        let lastTag = app.buttons["#project"]
        XCTAssertTrue(lastTag.waitForExistence(timeout: 5), "Synthetic fixture must include its last tag")
        XCTAssertTrue(lastTag.isHittable, "Last Home tag must be reachable above the dock")
        lastTag.tap()
        XCTAssertEqual(lastTag.value as? String, "Expanded")
        scroll.swipeUp()
        let lastNote = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Release checklist")).firstMatch
        XCTAssertTrue(lastNote.waitForExistence(timeout: 5))
        XCTAssertTrue(lastNote.isHittable, "Expanded tag note must remain touchable")
        screenshot("Home scrolled")
        lastNote.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))
        screenshot("Last tag note")
    }

    func testCreateCanvasOpensDrawAndReturnsToLibrary() throws {
        let canvases = app.buttons["Canvases"]
        XCTAssertTrue(canvases.waitForExistence(timeout: 5))
        canvases.tap()
        XCTAssertTrue(app.staticTexts["phone-canvases-title"].waitForExistence(timeout: 5))
        let create = app.buttons["phone-create-canvas"]
        XCTAssertTrue(create.isHittable)
        create.tap()
        XCTAssertTrue(app.buttons["phone-draw-title"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["phone-draw-menu"].exists)
        XCTAssertTrue(app.buttons["Back"].isHittable)
        screenshot("Draw created")
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["phone-canvases-title"].waitForExistence(timeout: 5))
        screenshot("Canvas in library")
    }

    func testTaskChecklistPersistsAcrossNavigation() throws {
        app.buttons["Tasks"].tap()
        let row = app.buttons["Review the prototype"]
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["phone-task-title"].waitForExistence(timeout: 6))
        let list = app.scrollViews.firstMatch
        let field = app.textFields["phone-add-step-field"]
        for _ in 0..<4 where !field.isHittable { list.swipeUp() }
        XCTAssertTrue(field.isHittable, "The checklist composer should remain reachable")
        let unique = "Review sample " + UUID().uuidString.prefix(8)
        field.tap()
        field.typeText(unique)
        let add = app.buttons["phone-add-step-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let toggle = app.buttons["Complete " + unique]
        XCTAssertTrue(toggle.waitForExistence(timeout: 6), "A new step must appear after saving")
        toggle.tap()
        XCTAssertTrue(app.buttons["Reopen " + unique].waitForExistence(timeout: 6))
        screenshot("Task checklist")
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Tasks"].waitForExistence(timeout: 6))
        row.tap()
        XCTAssertTrue(app.buttons["Reopen " + unique].waitForExistence(timeout: 6),
                      "The completed step must be durable after leaving the task")
    }

    func testSearchMatchesTaskAndNavigatesToDetail() throws {
        app.buttons["Search"].firstMatch.tap()
        let search = app.textFields["phone-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 6))
        search.tap()
        search.typeText("prototype")
        let result = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Review the prototype")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 6))
        screenshot("Search matching task")
        result.tap()
        XCTAssertTrue(app.descendants(matching: .any)["phone-task-title"].waitForExistence(timeout: 6))
    }

    func testCapturePriorityExpandsInPlaceAndNoteShowsConfirmation() throws {
        app.buttons["Create"].tap()
        let expanded = app.buttons["phone-priority-expand"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 5))
        expanded.tap()
        XCTAssertTrue(app.buttons["phone-priority-high"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["Later"].exists, "Priority takes the date and Later controls' place")
        screenshot("Capture expanded priority")
        app.buttons["phone-priority-high"].tap()
        XCTAssertTrue(expanded.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["phone-priority-low"].exists)
        app.buttons["Cancel"].tap()

        app.buttons["Create"].tap()
        let noteKind = app.buttons["Note"]
        XCTAssertTrue(noteKind.waitForExistence(timeout: 5))
        noteKind.tap()
        let title = app.textFields["phone-capture-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("New note confirmation " + UUID().uuidString.prefix(8))
        app.buttons["phone-capture-create"].tap()
        XCTAssertFalse(app.alerts["Could not save"].exists)
        let notice = app.staticTexts["Added to Notes"]
        XCTAssertTrue(notice.waitForExistence(timeout: 6), "Quick capture confirms inside the thumb capsule")
        screenshot("Capture note confirmation")
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 8), "Capture chrome returns after the notice")
    }

    func testHomeSettingsMenuOpensLocalPreferencesAndReturns() throws {
        let actions = app.buttons["phone-page-actions-menu"]
        XCTAssertTrue(actions.waitForExistence(timeout: 6))
        actions.tap()
        let settings = app.buttons["phone-page-action-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Home menu should expose Settings")
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["phone-settings-page"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["phone-setting-appearance"].exists)
        XCTAssertTrue(app.buttons["phone-setting-animations"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["phone-settings-sync-status"].exists)
        screenshot("Settings")
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 6))
    }

    func testLongPressTaskSelectsSeveralAndReplacesTabCapsule() throws {
        app.buttons["Tasks"].tap()
        let first = app.buttons["Review the prototype"]
        XCTAssertTrue(first.waitForExistence(timeout: 6))
        first.press(forDuration: 0.8)

        let count = app.staticTexts["phone-task-selection-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 6), "Holding a task must enter selection mode")
        XCTAssertEqual(count.label, "1 selected")
        XCTAssertFalse(app.buttons["Home"].exists, "Selection bar takes the tab capsule's place")
        XCTAssertTrue(app.buttons["Create"].exists, "Create remains beside the selection bar")

        let second = app.buttons["Check the iPhone layout"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        XCTAssertEqual(count.label, "2 selected")
        XCTAssertEqual(second.value as? String, "Selected")
        screenshot("Two tasks selected")

        let actions = app.buttons["phone-task-selection-more"]
        XCTAssertTrue(actions.isHittable)
        actions.tap()
        XCTAssertTrue(app.buttons["Move to Later"].waitForExistence(timeout: 5))
        screenshot("Selected task actions")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.4)).tap()
        let close = app.buttons["Close selection"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5))
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Phone wave · " + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
