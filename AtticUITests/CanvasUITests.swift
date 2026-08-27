import XCTest

final class CanvasUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        launch(resetCanvasStore: true)
    }

    override func tearDownWithError() throws {
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 3)
        app = nil
    }

    func testCanvasDrawUndoRedoEraseAndConfirmedClear() throws {
        openCanvas()
        let surface = app.otherElements["canvas-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 3))

        drawStroke(on: surface)
        assertStrokeCount(1)

        app.buttons["canvas-undo"].click()
        assertStrokeCount(0)

        app.buttons["canvas-redo"].click()
        assertStrokeCount(1)

        app.buttons["canvas-tool-eraser"].click()
        eraseStroke(on: surface)
        assertStrokeCount(0)

        app.buttons["canvas-undo"].click()
        assertStrokeCount(1)

        app.buttons["canvas-clear"].click()
        let clearConfirmation = app.buttons["Confirm Clear Canvas"]
        XCTAssertTrue(clearConfirmation.waitForExistence(timeout: 2))
        clearConfirmation.click()
        assertStrokeCount(0)

        app.buttons["canvas-undo"].click()
        assertStrokeCount(1)
    }

    func testCompletedInkSurvivesSectionsSettingsAndRelaunch() throws {
        openCanvas()
        let surface = app.otherElements["canvas-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 3))
        drawStroke(on: surface)
        assertStrokeCount(1)

        app.buttons["section-tasks"].click()
        XCTAssertTrue(app.buttons["section-canvas"].waitForExistence(timeout: 2))
        app.buttons["section-canvas"].click()
        assertStrokeCount(1)

        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["Attic Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()

        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 3)
        launch(resetCanvasStore: false)
        openCanvas()
        assertStrokeCount(1)
    }

    private func launch(resetCanvasStore: Bool) {
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_CANVAS_RESET"] =
            resetCanvasStore ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    private func openCanvas() {
        let button = app.buttons["section-canvas"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.click()
        XCTAssertTrue(
            app.otherElements["canvas-surface"].waitForExistence(timeout: 3)
        )
    }

    private func drawStroke(on surface: XCUIElement) {
        let start = surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.22, dy: 0.35)
        )
        let end = surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.78, dy: 0.62)
        )
        start.press(
            forDuration: 0.05,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
    }

    private func eraseStroke(on surface: XCUIElement) {
        let start = surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.20, dy: 0.34)
        )
        let end = surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.80, dy: 0.63)
        )
        start.press(
            forDuration: 0.05,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
    }

    private func assertStrokeCount(
        _ count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let counter = app.staticTexts["canvas-stroke-count"]
        XCTAssertTrue(
            counter.waitForExistence(timeout: 3),
            file: file,
            line: line
        )
        let expected = count == 1 ? "1 stroke" : "\(count) strokes"
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: counter
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 3),
            .completed,
            file: file,
            line: line
        )
    }
}
