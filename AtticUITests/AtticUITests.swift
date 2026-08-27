import XCTest

final class AtticUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchArguments += [
            "-AtticSettings.selectedSection", "general",
            "-hasAdoptedAgentAccessOptIn", "YES",
            "-isAgentAccessEnabled", "NO",
            "-appearancePreference", "system"
        ]
        app.launch()
    }

    func testSettingsNavigationAndSelectionPersistAfterClosingWindow() throws {
        var settingsWindow = openSettings()

        let sections = ["general", "panel", "appearance", "sync", "agentAccess", "about"]
        for section in sections {
            selectSettingsSection(section, in: settingsWindow)
            XCTAssertTrue(
                settingsWindow.descendants(matching: .any)["settings-page-\(section)"]
                    .waitForExistence(timeout: 2)
            )
        }

        selectSettingsSection("panel", in: settingsWindow)
        settingsWindow.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 2))

        settingsWindow = openSettings()
        XCTAssertTrue(
            settingsWindow.descendants(matching: .any)["settings-page-panel"]
                .waitForExistence(timeout: 2)
        )
    }

    func testSettingsBindingSurvivesNavigation() throws {
        let settingsWindow = openSettings()
        selectSettingsSection("appearance", in: settingsWindow)

        let translucency = settingsWindow.descendants(matching: .any)["setting-translucency"]
        XCTAssertTrue(translucency.waitForExistence(timeout: 2))
        let initialValue = String(describing: translucency.value)
        translucency.click()
        let changedValue = String(describing: translucency.value)
        XCTAssertNotEqual(changedValue, initialValue)

        selectSettingsSection("about", in: settingsWindow)
        selectSettingsSection("appearance", in: settingsWindow)
        XCTAssertEqual(String(describing: translucency.value), changedValue)

        translucency.click()
        XCTAssertEqual(String(describing: translucency.value), initialValue)
    }

    func testAgentAccessConditionalContentAndSensitiveTextHandling() throws {
        let settingsWindow = openSettings()
        selectSettingsSection("agentAccess", in: settingsWindow)

        let accessToggle = settingsWindow.descendants(matching: .any)["setting-agent-access"]
        let connection = settingsWindow.descendants(matching: .any)["settings-agent-connection"]
        let disabledMessage = settingsWindow.descendants(matching: .any)["settings-agent-disabled-message"]
        XCTAssertTrue(accessToggle.waitForExistence(timeout: 2))
        XCTAssertTrue(disabledMessage.waitForExistence(timeout: 2))
        XCTAssertFalse(connection.exists)

        accessToggle.click()
        XCTAssertTrue(connection.waitForExistence(timeout: 2))
        XCTAssertTrue(
            settingsWindow.descendants(matching: .any)["settings-agent-authorization-summary"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertEqual(
            settingsWindow.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Authorization: Bearer")
            ).count,
            0
        )

        accessToggle.click()
        XCTAssertTrue(connection.waitForNonExistence(timeout: 2))
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

        let actions = app.popUpButtons["Edit task"]
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
        XCTAssertTrue(betaRow.isHittable)
        XCTAssertTrue(alphaRow.isHittable)

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

    private func addTask(named title: String) {
        let addButton = app.buttons["add-task-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 2))
        addButton.click()

        let titleField = app.textFields["new-task-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        titleField.typeText(title)
        titleField.typeKey(.return, modifierFlags: [])
    }

    private func openSettings() -> XCUIElement {
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 2))
        settingsButton.click()

        let settingsWindow = app.windows["Attic Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 2))
        return settingsWindow
    }

    private func selectSettingsSection(_ section: String, in settingsWindow: XCUIElement) {
        let row = settingsWindow.descendants(matching: .any)["settings-nav-\(section)"]
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.click()
    }
}
