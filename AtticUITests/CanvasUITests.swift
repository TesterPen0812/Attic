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
        terminateApp()
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

        app.typeKey("z", modifierFlags: [.command, .shift])
        assertStrokeCount(1)

        app.buttons["canvas-tool-eraser"].click()
        eraseStroke(on: surface)
        assertStrokeCount(0)

        app.buttons["canvas-undo"].click()
        assertStrokeCount(1)

        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [.command, .shift])
        let clearConfirmation = app.sheets.buttons["Confirm Clear Canvas"].firstMatch
        if !clearConfirmation.waitForExistence(timeout: 1) {
            let canvasMenu = app.descendants(matching: .any)
                .matching(identifier: "canvas-document-menu")
                .firstMatch
            XCTAssertTrue(canvasMenu.waitForExistence(timeout: 2))
            canvasMenu.click()
            let editMenu = app.menuItems["Edit"]
            XCTAssertTrue(editMenu.waitForExistence(timeout: 2))
            editMenu.hover()
            let clear = app.menuItems["Clear Canvas"]
            XCTAssertTrue(clear.waitForExistence(timeout: 2))
            clear.click()
        }
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

        app.typeKey("1", modifierFlags: .command)
        app.typeKey("4", modifierFlags: .command)
        assertStrokeCount(1)

        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["Attic Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()

        terminateApp()
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
        let selectTool = app.buttons["canvas-tool-select"]
        XCTAssertTrue(selectTool.waitForExistence(timeout: 2))
        app.typeKey("v", modifierFlags: [])
        waitForSelection(true, on: selectTool)
        try saveVisualEvidence(named: "canvas-image-selected")

        app.typeKey(.rightArrow, modifierFlags: .option)
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: .shift)
        assertContentCount("1 item")
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
        XCTAssertFalse(pin.isSelected)
        pin.click()
        waitForSelection(true, on: pin)
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
        app.buttons["action-button-1"].click()
        waitForValue("Reference", on: menu)
        assertContentCount("0 items")
        try saveVisualEvidence(named: "canvas-second-document")
    }

    func testModeDockExpandsOnHoverAndCollapsesAfterPointerLeaves() {
        let dock = app.descendants(matching: .any)
            .matching(identifier: "panel-section-picker")
            .firstMatch
        let tasks = app.buttons["panel-section-tasks"]
        let backlog = app.buttons["panel-section-backlog"]
        let notes = app.buttons["panel-section-notes"]
        let canvas = app.buttons["panel-section-canvas"]
        let pin = app.buttons["panel-pin-button"]

        XCTAssertTrue(dock.waitForExistence(timeout: 3))
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        pin.hover()
        XCTAssertTrue(backlog.waitForNonExistence(timeout: 2))
        XCTAssertTrue(tasks.exists)
        XCTAssertFalse(backlog.exists)
        XCTAssertFalse(notes.exists)
        XCTAssertFalse(canvas.exists)

        dock.hover()
        XCTAssertTrue(backlog.waitForExistence(timeout: 2))
        XCTAssertTrue(notes.exists)
        XCTAssertTrue(canvas.exists)

        pin.hover()
        XCTAssertTrue(backlog.waitForNonExistence(timeout: 2))
        XCTAssertFalse(notes.exists)
        XCTAssertFalse(canvas.exists)
        XCTAssertTrue(tasks.exists)
    }

    func testModeDockExposesExactlyOneAccessibilitySelectionAcrossTransitions() {
        let dock = app.descendants(matching: .any)
            .matching(identifier: "panel-section-picker")
            .firstMatch
        let tasks = app.buttons["panel-section-tasks"]
        let backlog = app.buttons["panel-section-backlog"]
        let notes = app.buttons["panel-section-notes"]
        let canvas = app.buttons["panel-section-canvas"]
        let pin = app.buttons["panel-pin-button"]
        let modes = [tasks, backlog, notes, canvas]

        XCTAssertTrue(dock.waitForExistence(timeout: 3))
        dock.hover()
        XCTAssertTrue(canvas.waitForExistence(timeout: 2))
        assertExactlyOneSelected(in: modes, expected: tasks)

        backlog.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
        assertExactlyOneSelected(in: modes, expected: backlog)

        app.typeKey("3", modifierFlags: .command)
        assertExactlyOneSelected(in: modes, expected: notes)

        app.typeKey("4", modifierFlags: .command)
        assertExactlyOneSelected(in: modes, expected: canvas)

        pin.hover()
        XCTAssertTrue(tasks.waitForNonExistence(timeout: 2))
        XCTAssertTrue(backlog.waitForNonExistence(timeout: 2))
        XCTAssertTrue(notes.waitForNonExistence(timeout: 2))
        XCTAssertTrue(canvas.exists)
        XCTAssertTrue(canvas.isSelected)

        dock.hover()
        XCTAssertTrue(tasks.waitForExistence(timeout: 2))
        assertExactlyOneSelected(in: modes, expected: canvas)
    }

    private func launch(resetCanvasStore: Bool) {
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_CANVAS_RESET"] =
            resetCanvasStore ? "1" : "0"
        app.launch()
        app.activate()
        XCTAssertTrue(
            app.descendants(matching: .any)["panel-section-picker"]
                .waitForExistence(timeout: 5),
            "The LSUIElement host must expose its real panel shell after activation"
        )
    }

    private func terminateApp() {
        app.terminate()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 10),
            "The prior LSUIElement process must fully terminate before another launch"
        )
    }

    private func openCanvas() {
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(
            app.otherElements["canvas-surface"].waitForExistence(timeout: 3)
        )
    }

    private func assertExactlyOneSelected(
        in modes: [XCUIElement],
        expected: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let settledSelection = NSPredicate { _, _ in
            let selected = modes.filter(\.isSelected)
            return selected.count == 1
                && selected.first?.identifier == expected.identifier
        }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: settledSelection, object: nil)],
                timeout: 3
            ),
            .completed,
            file: file,
            line: line
        )
        let selected = modes.filter(\.isSelected)
        XCTAssertEqual(selected.count, 1, file: file, line: line)
        XCTAssertEqual(selected.first?.identifier, expected.identifier, file: file, line: line)
    }

    private func waitForSelection(
        _ expected: Bool,
        on element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate { object, _ in
            (object as? XCUIElement)?.isSelected == expected
        }
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
        let predicate = NSPredicate(
            format: "label == %@ OR value == %@",
            expected,
            expected
        )
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
