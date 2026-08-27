import AppKit
import XCTest

final class CanvasUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        launch(resetCanvasStore: true)
    }

    override func tearDownWithError() throws {
        NSPasteboard.general.clearContents()
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

        app.buttons["panel-section-tasks"].click()
        XCTAssertTrue(
            app.buttons["panel-section-canvas"].waitForExistence(timeout: 2)
        )
        app.buttons["panel-section-canvas"].click()
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

    func testCanvasImagePasteMoveResizeDeleteUndoAndVisualStates() throws {
        openCanvas()
        let surface = app.otherElements["canvas-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 3))
        surface.click()
        if app.buttons["canvas-undo"].isEnabled {
            app.buttons["canvas-undo"].click()
        }
        assertContentCount("0 items")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(makeTestTIFF(), forType: .tiff))
        app.typeKey("v", modifierFlags: .command)
        assertContentCount("1 item")
        XCTAssertTrue(app.buttons["canvas-image-delete"].waitForExistence(timeout: 3))
        try saveVisualEvidence(named: "canvas-image-selected")

        let frame = surface.frame
        let bottomRight = surface.coordinate(withNormalizedOffset: CGVector(
            dx: 0.5 + min(78 / max(frame.width, 1), 0.35),
            dy: 0.5 + min(38 / max(frame.height, 1), 0.30)
        ))
        let resizedBottomRight = surface.coordinate(withNormalizedOffset: CGVector(
            dx: 0.5 + min(116 / max(frame.width, 1), 0.44),
            dy: 0.5 + min(58 / max(frame.height, 1), 0.38)
        ))
        bottomRight.press(
            forDuration: 0.1,
            thenDragTo: resizedBottomRight,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )

        let center = surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let movedCenter = surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.62, dy: 0.60)
        )
        center.press(
            forDuration: 0.1,
            thenDragTo: movedCenter,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        try saveVisualEvidence(named: "canvas-image-resized-moved")

        app.buttons["canvas-image-delete"].click()
        assertContentCount("0 items")
        app.buttons["canvas-undo"].click()
        assertContentCount("1 item")
    }

    func testPinAndCompactCanvasDocumentManagementVisualStates() throws {
        openCanvas()
        let pin = app.buttons["panel-pin-button"]
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        XCTAssertEqual(pin.value as? String, "Not pinned")
        pin.click()
        waitForValue("Pinned", on: pin)
        try saveVisualEvidence(named: "canvas-panel-pinned")

        let menu = app.descendants(matching: .any)
            .matching(identifier: "canvas-document-menu")
            .firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.click()
        let newCanvas = app.menuItems["New Canvas"]
        XCTAssertTrue(newCanvas.waitForExistence(timeout: 2))
        try saveVisualEvidence(named: "canvas-document-menu")
        newCanvas.click()

        let field = app.textFields["Canvas name"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText("Reference")
        app.buttons["Create"].click()
        waitForValue("Reference", on: menu)
        assertContentCount("0 items")
        try saveVisualEvidence(named: "canvas-second-document")
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
        let button = app.buttons["panel-section-canvas"]
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
        assertContentCount(
            count == 1 ? "1 item" : "\(count) items",
            file: file,
            line: line
        )
    }

    private func assertContentCount(
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let counter = app.staticTexts["canvas-content-count"]
        XCTAssertTrue(
            counter.waitForExistence(timeout: 3),
            file: file,
            line: line
        )
        waitForLabel(expected, on: counter, file: file, line: line)
    }

    private func waitForLabel(
        _ expected: String,
        on element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 4),
            .completed,
            file: file,
            line: line
        )
    }

    private func waitForValue(
        _ expected: String,
        on element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
   ) {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
           )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 4),
            .completed,
            file: file,
            line: line
        )
    }

    private func makeTestTIFF() -> Data {
        let image = NSImage(size: NSSize(width: 160, height: 80))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            xRadius: 14,
            yRadius: 14
        ).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 58, y: 18, width: 44, height: 44)).fill()
        image.unlockFocus()
        return image.tiffRepresentation ?? Data()
    }

    private func saveVisualEvidence(named name: String) throws {
        guard let directoryPath = ProcessInfo.processInfo.environment[
            "ATTIC_VISUAL_UAT_DIRECTORY"
        ], !directoryPath.isEmpty else {
            return
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("\(name).png")
        try XCUIScreen.main.screenshot().pngRepresentation.write(
            to: url,
            options: .atomic
        )
        add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
    }
}
