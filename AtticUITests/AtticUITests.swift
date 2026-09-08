import XCTest

final class AtticUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        forwardOwnedAttachmentRoot(to: app)
        app.launch()
        app.activate()
        XCTAssertTrue(
            app.descendants(matching: .any)["panel-section-picker"]
                .waitForExistence(timeout: 5)
        )
    }

    private func forwardOwnedAttachmentRoot(to application: XCUIApplication) {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["ATTIC_TEST_ATTACHMENT_ROOT"],
              let token = environment[
                "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN"
              ] else {
            return
        }
        application.launchEnvironment["ATTIC_TEST_ATTACHMENT_ROOT"] = root
        application.launchEnvironment[
            "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN"
        ] = token
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app = nil
    }

    func testAppearanceThemesResolveClearAndGradientControls() throws {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Attic Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.descendants(matching: .any)["settings-nav-appearance"].click()
        let page = settings.descendants(matching: .any)["settings-page-appearance"]
        XCTAssertTrue(page.waitForExistence(timeout: 3))
        let appearance = settings.descendants(matching: .any)["setting-appearance"]
        let glass = settings.descendants(matching: .any)["setting-glass-style"]
        let translucency = settings.descendants(matching: .any)["setting-translucency"]
        let coverage = settings.sliders["setting-panel-gradient-coverage"]
        let original = settings.buttons["setting-panel-theme-original"]

        func segment(_ title: String, in picker: XCUIElement) -> XCUIElement {
            picker.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        }
        func reveal(_ element: XCUIElement, deltaY: CGFloat) {
            for _ in 0..<5 {
                if element.isHittable { return }
                page.scroll(byDeltaX: 0, deltaY: deltaY)
            }
            XCTAssertTrue(element.isHittable, "Settings control must be reachable without resizing the window")
        }
        func waitFor(_ message: String, _ condition: @escaping () -> Bool) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed, message)
        }
        func assertSelected(_ element: XCUIElement) {
            waitFor("Expected selected glass style: \(element.label)") {
                element.isSelected || (element.value as? String) == "1"
                    || (element.value as? NSNumber)?.boolValue == true
            }
        }
        func recordPanel(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.dialogs.firstMatch.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        // One app launch covers every preset in both explicit appearances.
        // Establish Clear once, then prove unavailable states do not erase it.
        reveal(original, deltaY: 450)
        original.click()
        segment("Dark", in: appearance).click()
        if !glass.exists {
            reveal(translucency, deltaY: -450)
            translucency.click()
        }
        XCTAssertTrue(glass.waitForExistence(timeout: 3))
        let clear = segment("Clear", in: glass)
        reveal(clear, deltaY: -450)
        waitFor("Original Dark must enable Clear") { clear.isEnabled }
        clear.click()
        assertSelected(clear)

        let themes = ["original", "midnightCobalt", "porcelainVapor", "smokedUmber",
                      "electricBlue", "seaGlass", "amethyst"]
        for scheme in ["Light", "Dark"] {
            let schemeControl = segment(scheme, in: appearance)
            reveal(schemeControl, deltaY: 450)
            schemeControl.click()
            for theme in themes {
                let choice = settings.buttons["setting-panel-theme-\(theme)"]
                XCTAssertTrue(choice.waitForExistence(timeout: 3))
                reveal(choice, deltaY: -300)
                choice.click()
                waitFor("Selected theme must update") { (choice.value as? String) == "Selected" }
                let clearIsAvailable = theme == "original" && scheme == "Dark"
                waitFor("Clear availability must follow the selected preset and appearance") {
                    clear.exists == clearIsAvailable
                }
                if clearIsAvailable { XCTAssertTrue(clear.isEnabled) }
                assertSelected(segment(clearIsAvailable ? "Clear" : "Frosted", in: glass))
                XCTAssertEqual(settings.descendants(matching: .any)["setting-clear-availability"].exists,
                               !clearIsAvailable)
                // Evidence only: these screenshots do not assert contrast or
                // physical desktop readability on their own.
                recordPanel("Theme-\(theme)-\(scheme)")
            }
        }

        reveal(original, deltaY: 450)
        original.click()
        assertSelected(clear)
        reveal(translucency, deltaY: -450)
        translucency.click()
        waitFor("Opaque mode hides the glass picker") { !glass.exists }
        recordPanel("Original-Dark-Opaque")
        translucency.click()
        XCTAssertTrue(glass.waitForExistence(timeout: 3))
        assertSelected(clear)

        // Explicit Frosted makes the gradient active; Original Dark Clear
        // intentionally preserves its existing surface instead.
        let frosted = segment("Frosted", in: glass)
        reveal(frosted, deltaY: -450)
        frosted.click()
        assertSelected(frosted)
        reveal(coverage, deltaY: -450)
        XCTAssertTrue(coverage.isEnabled)
        for endpoint: CGFloat in [0, 1] {
            coverage.adjust(toNormalizedSliderPosition: endpoint)
            waitFor("Gradient slider must reach its endpoint") {
                abs(coverage.normalizedSliderPosition - endpoint) < 0.01
            }
            recordPanel(endpoint == 0 ? "Gradient-Off" : "Gradient-Full-Coverage")
        }
        coverage.adjust(toNormalizedSliderPosition: 0.55)
        reveal(clear, deltaY: 450)
        clear.click()
        let systemAppearance = segment("System", in: appearance)
        reveal(systemAppearance, deltaY: 450)
        systemAppearance.click()
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.descendants(matching: .any)["panel-section-picker"].exists)
    }

    func testCreateAdvanceCompleteAndOpenContextMenu() throws {
        let addButton = app.buttons["add-task-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        addButton.click()

        let composer = app.descendants(matching: .any)["task-entry-bar"]
        let submit = app.buttons["quick-entry-submit"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(addButton.frame.minY - composer.frame.minY, 5,
                                    "The expanded composer needs space above its action hit targets")
        XCTAssertGreaterThanOrEqual(addButton.frame.minX - composer.frame.minX, 6)
        XCTAssertGreaterThanOrEqual(composer.frame.maxX - submit.frame.maxX, 6)

        let titleField = app.textFields["quick-entry-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        XCTAssertFalse(app.textFields["new-task-title"].exists, "Task options must expand the one composer, not create a second input")
        titleField.typeText("Ship prototype")
        let highPriority = app.buttons["task-priority-high"]
        XCTAssertTrue(highPriority.waitForExistence(timeout: 2))
        highPriority.click()
        titleField.typeKey(.return, modifierFlags: [])

        let title = app.staticTexts["Ship prototype"]
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        let statusButton = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "complete-task-"
        )).firstMatch
        XCTAssertEqual(statusButton.value as? String, "High priority")
        // A successful Return keeps the same composer ready for consecutive
        // entry, including keyboard focus transfer to its priority controls.
        titleField.typeText("Next thought")
        titleField.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(highPriority.exists)
        titleField.click()
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeKey(.delete, modifierFlags: [])
        titleField.typeKey(.escape, modifierFlags: [])
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "task-row-")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).doubleClick()
        let inProgressSection = app.staticTexts["task-section-inProgress"]
        XCTAssertTrue(inProgressSection.waitForExistence(timeout: 2))

        let markDone = app.buttons.matching(NSPredicate(format: "label == %@", "Mark done")).firstMatch
        XCTAssertTrue(markDone.waitForExistence(timeout: 2))
        markDone.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
        let doneSection = app.staticTexts["task-section-done"]
        XCTAssertTrue(doneSection.waitForExistence(timeout: 2))

        let actions = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "task-actions-")
        ).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 2))
        actions.click()

        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 2))

        let editTitle = app.menuItems["Edit title…"]
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
        let titleField = app.textFields["quick-entry-title"]
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
        dragStart.click(
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
        let controls = app.descendants(matching: .any)["note-entry-bar"]
        XCTAssertGreaterThan(body.frame.height, app.dialogs.firstMatch.frame.height * 0.5,
                             "An attachment-free note should use the workspace, not a fixed short editor")
        XCTAssertLessThan(abs(controls.frame.minY - body.frame.maxY), 20,
                          "Writing should extend down to the note controls")
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
        let savedTitle = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@",
            "Live Notes UI"
        )).firstMatch
        XCTAssertTrue(savedTitle.waitForExistence(timeout: 2))

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

    func testNativePanelResizeKeepsDockedEdgesAndMinimumSize() throws {
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        app.buttons["panel-pin-button"].click()
        let initial = panel.frame
        let left = panel.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        left.click(forDuration: 0.1,
                   thenDragTo: left.withOffset(CGVector(dx: -90, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(panel.frame.width, initial.width + 90, accuracy: 3)
        XCTAssertEqual(panel.frame.height, initial.height, accuracy: 1)
        XCTAssertEqual(panel.frame.maxX, initial.maxX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, initial.minY, accuracy: 1)

        let wider = panel.frame
        let bottom = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.998))
        bottom.click(forDuration: 0.1,
                     thenDragTo: bottom.withOffset(CGVector(dx: 0, dy: 80)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(panel.frame.height, wider.height + 80, accuracy: 3)
        XCTAssertEqual(panel.frame.width, wider.width, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, initial.minY, accuracy: 1)

        let larger = panel.frame
        let corner = panel.coordinate(withNormalizedOffset: CGVector(
            dx: 25 / larger.width, dy: 1 - 25 / larger.height
        ))
        corner.click(forDuration: 0.1,
                     thenDragTo: corner.withOffset(CGVector(dx: 240, dy: -240)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(panel.frame.width, 332, accuracy: 1)
        XCTAssertEqual(panel.frame.height, 480, accuracy: 1)
        XCTAssertEqual(panel.frame.maxX, initial.maxX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, initial.minY, accuracy: 1)
        XCTAssertTrue(app.buttons["panel-pin-button"].isSelected)
        XCTAssertTrue(app.textFields["quick-entry-title"].isHittable)
        XCTAssertTrue(app.buttons["panel-section-tasks"].isHittable)
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
        let titleField = app.textFields["quick-entry-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        titleField.click()
        titleField.typeText(title)
        titleField.typeKey(.return, modifierFlags: [])
    }

}
