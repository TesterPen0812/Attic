import XCTest

final class AtticUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launch()
        app.activate()
        XCTAssertTrue(
            app.descendants(matching: .any)["panel-section-picker"]
                .waitForExistence(timeout: 5)
        )
    }

    override func tearDownWithError() throws {
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 3)
        app = nil
    }

    func testCreateAdvanceCompleteAndOpenContextMenu() throws {
        let addButton = app.buttons["add-task-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        addButton.click()

        let titleField = app.textFields["new-task-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        titleField.typeText("Ship prototype")
        titleField.typeKey(.return, modifierFlags: [])

        let title = app.staticTexts["Ship prototype"]
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "task-row-")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).doubleClick()
        let inProgressSection = app.staticTexts["task-section-inProgress"]
        XCTAssertTrue(inProgressSection.waitForExistence(timeout: 2))

        let markDone = app.buttons.matching(NSPredicate(format: "label == %@", "Mark done")).firstMatch
        XCTAssertTrue(markDone.waitForExistence(timeout: 2))
        markDone.click()
        let doneSection = app.staticTexts["task-section-done"]
        XCTAssertTrue(doneSection.waitForExistence(timeout: 2))

        let actions = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "task-actions-")
        ).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 2))
        actions.click()

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Copy"))
                .firstMatch
                .waitForExistence(timeout: 2)
        )

        let editTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Edit title…"))
            .firstMatch
        XCTAssertTrue(editTitle.waitForExistence(timeout: 2))
        editTitle.click()

        let editField = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "edit-task-title-")
        ).firstMatch
        XCTAssertTrue(editField.waitForExistence(timeout: 2))
    }

    func testLongTaskTitleWrapsInsteadOfTruncating() throws {
        app.buttons["add-task-button"].click()

        let longTitle = "A long task title that should wrap onto multiple lines instead of being cut off"
        let titleField = app.textFields["new-task-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        titleField.typeText(longTitle)
        titleField.typeKey(.return, modifierFlags: [])

        let title = app.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "A long task title")
        ).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(title.frame.height, 20)
    }

    func testDragReordersTasksWithMatchingPriority() throws {
        addTask(named: "Alpha")
        addTask(named: "Beta")

        let first = app.staticTexts["Alpha"]
        let second = app.staticTexts["Beta"]
        XCTAssertTrue(first.waitForExistence(timeout: 2))
        XCTAssertTrue(second.waitForExistence(timeout: 2))
        XCTAssertLessThan(second.frame.minY, first.frame.minY)

        let rows = app.groups.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "task-row-")
        )
        XCTAssertEqual(rows.count, 2)
        let betaRow = rows.matching(NSPredicate(format: "label == %@", "Beta")).firstMatch
        let alphaRow = rows.matching(NSPredicate(format: "label == %@", "Alpha")).firstMatch
        XCTAssertTrue(betaRow.waitForExistence(timeout: 2))
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 2))
        XCTAssertTrue(second.isHittable)
        XCTAssertTrue(first.isHittable)

        let dragStart = betaRow.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let dragEnd = alphaRow.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        dragStart.press(
            forDuration: 0.5,
            thenDragTo: dragEnd,
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )

        let deadline = Date().addingTimeInterval(2)
        while second.frame.minY <= first.frame.minY && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY)
    }

    func testNotesEditorKeepsDraftWhileBrowsingSavedNotes() throws {
        app.typeKey("3", modifierFlags: .command)

        let newNote = app.buttons["new-note-empty-state"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        newNote.click()

        let title = app.textFields["note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        app.typeText("Live Notes UI")
        app.typeKey(.return, modifierFlags: [])

        let body = app.textViews["note-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 2))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeText("The active draft stays mounted while the library is open.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(body.exists)

        let save = app.buttons["save-note"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        save.click()
        XCTAssertTrue(body.exists, "Saving in place must keep the focused workspace open")

        let browse = app.buttons["browse-saved-notes"]
        XCTAssertTrue(browse.waitForExistence(timeout: 2))
        browse.click()

        let drawer = app.descendants(matching: .any)["saved-notes-drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Live Notes UI"].exists)

        let returnToWriting = app.buttons["return-to-writing"]
        XCTAssertTrue(returnToWriting.waitForExistence(timeout: 2))
        returnToWriting.click()

        XCTAssertTrue(body.waitForExistence(timeout: 2))
        XCTAssertEqual(
            body.value as? String,
            "The active draft stays mounted while the library is open."
        )
        XCTAssertTrue(app.buttons["add-note-attachment"].exists)
        XCTAssertFalse(app.staticTexts["Drop files here"].exists)
    }

    func testNotesBodyPreservesFocusAcrossIncrementalTyping() throws {
        app.typeKey("3", modifierFlags: .command)

        let newNote = app.buttons["new-note-empty-state"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        newNote.click()

        let body = app.textViews["note-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 2))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        // Send separate key events instead of one `typeText` batch. This
        // catches focus bridges that surrender first responder after the
        // SwiftUI update caused by each character.
        app.typeText("a")
        app.typeText("b")
        app.typeText("c")

        XCTAssertEqual(body.value as? String, "abc")
    }

    private func addTask(named title: String) {
        let addButton = app.buttons["add-task-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 2))
        addButton.click()

        let titleField = app.textFields["new-task-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        titleField.typeText(title)
        titleField.typeKey(.return, modifierFlags: [])
    }

}
