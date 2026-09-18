import XCTest

final class CanvasMobileUITests: XCTestCase {
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

    func testCanvasDrawUndoRedoAndRelaunch() throws {
        openCanvas()
        let surface = app.otherElements["canvas-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 3))

        let start = surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.2, dy: 0.35)
        )
        let end = surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)
        )
        start.press(
            forDuration: 0.05,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        assertStrokeCount(1)

        app.buttons["canvas-undo"].tap()
        assertStrokeCount(0)
        app.buttons["canvas-redo"].tap()
        assertStrokeCount(1)

        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 3)
        launch(resetCanvasStore: false)
        openCanvas()
        assertStrokeCount(1)
    }

    private func launch(resetCanvasStore: Bool) {
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_CANVAS_RESET"] =
            resetCanvasStore ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    private func openCanvas() {
        let button = app.buttons["mobile-section-canvas"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()
        XCTAssertTrue(
            app.otherElements["canvas-surface"].waitForExistence(timeout: 3)
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
