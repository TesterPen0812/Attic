import AppKit
import XCTest

final class CanvasUITests: XCTestCase {
    private var app: XCUIApplication!
    private var originalPasteboard: [[NSPasteboard.PasteboardType: Data]] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        originalPasteboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        launch(resetCanvasStore: true)
    }

    override func tearDownWithError() throws {
        NSPasteboard.general.clearContents()
        let items = originalPasteboard.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        NSPasteboard.general.writeObjects(items)
        terminateApp()
        app = nil
    }

    func testCanvasDrawUndoRedoEraseAndConfirmedClear() throws {
        openCanvas()
        let surface = canvasSurface
        XCTAssertTrue(surface.waitForExistence(timeout: 3))

        prepareSurfaceForInkInput(surface)
        drawStroke(on: surface)
        assertStrokeCount(1)

        app.buttons["canvas-undo"].click()
        assertStrokeCount(0)

        app.typeKey("z", modifierFlags: [.command, .shift])
        assertStrokeCount(1)

        let eraser = app.buttons["canvas-tool-eraser"]
        eraser.click()
        XCTAssertTrue(eraser.isSelected, "The single Eraser click must select the tool before its drag")
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

    func testSemanticTextAndShapesEditTransformUndoAndSurviveRelaunch() throws {
        openCanvas()
        let surface = canvasSurface
        app.buttons["canvas-add-text"].click()
        XCTAssertFalse(app.textFields["Type something"].exists)
        let placement = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        placement.click()
        let editor = app.textViews.matching(NSPredicate(format: "label == %@", "Edit canvas text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        assertContentCount("0 items")
        XCTAssertEqual(editor.frame.minX + 4, placement.screenPoint.x, accuracy: 3)
        XCTAssertEqual(editor.frame.minY + 4, placement.screenPoint.y, accuracy: 3)
        editor.typeText("Editable canvas text")
        editor.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 2))
        assertContentCount("1 item")
        let initialText = surface.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "canvas-object-", "Editable canvas text")
        ).firstMatch
        XCTAssertTrue(initialText.waitForExistence(timeout: 2))
        XCTAssertEqual(initialText.frame.minX + 4, placement.screenPoint.x, accuracy: 3)
        XCTAssertEqual(initialText.frame.minY + 4, placement.screenPoint.y, accuracy: 3)
        let textID = initialText.identifier
        let textObject = app.descendants(matching: .any).matching(identifier: textID).firstMatch
        app.buttons["canvas-object-edit-text"].click()
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        editor.typeText(" revised")
        editor.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 2))
        waitForLabel("Editable canvas text revised", on: textObject)
        assertFitAndResetChangeObjectGeometry(textObject)

        app.buttons["canvas-tool-pen"].click()
        waitForSelection(true, on: app.buttons["canvas-tool-pen"])
        app.descendants(matching: .any).matching(identifier: "canvas-add-shape").firstMatch.click()
        let rectangle = app.menuItems["Rectangle"]
        XCTAssertTrue(rectangle.waitForExistence(timeout: 2))
        rectangle.click()
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58))
        let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.72))
        start.click(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        assertContentCount("2 items")
        let shape = surface.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "canvas-object-", "Rectangle")
        ).firstMatch
        XCTAssertTrue(shape.waitForExistence(timeout: 2))
        shape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(shape.isSelected)
        let originalFrame = shape.frame
        app.typeKey(.rightArrow, modifierFlags: .shift)
        waitForFrame(of: shape, matching: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return abs(element.frame.minX - originalFrame.minX - 10) < 3
        })
        app.typeKey(.rightArrow, modifierFlags: .option)
        waitForFrame(of: shape, matching: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.frame.width > originalFrame.width + 1
        })
        app.typeKey("z", modifierFlags: .command)
        waitForFrame(of: shape, matching: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return abs(element.frame.width - originalFrame.width) < 1
        })
        app.typeKey("z", modifierFlags: .command)
        waitForFrame(of: shape, matching: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return abs(element.frame.minX - originalFrame.minX) < 1
        })
        assertFitAndResetChangeObjectGeometry(shape)
        app.typeKey("1", modifierFlags: .command)
        openCanvas()
        assertFitAndResetChangeObjectGeometry(shape)
        app.buttons["canvas-object-delete"].click()
        assertContentCount("1 item")
        app.typeKey("z", modifierFlags: .command)
        assertContentCount("2 items")
        try saveVisualEvidence(named: "canvas-semantic-text-and-shape")
        terminateApp()
        launch(resetCanvasStore: false)
        openCanvas()
        assertContentCount("2 items")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: textID).firstMatch.waitForExistence(timeout: 2))
        waitForLabel("Editable canvas text revised", on: app.descendants(matching: .any).matching(identifier: textID).firstMatch)
    }

    func testCompletedInkSurvivesSectionsSettingsAndRelaunch() throws {
        openCanvas()
        let surface = canvasSurface
        XCTAssertTrue(surface.waitForExistence(timeout: 3))
        prepareSurfaceForInkInput(surface)
        drawStroke(on: surface)
        assertStrokeCount(1)

        app.typeKey("1", modifierFlags: .command)
        app.typeKey("3", modifierFlags: .command)
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
        let surface = canvasSurface
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
        let undo = app.buttons["canvas-undo"]
        waitForEnabled(undo)
        undo.click()
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

    /// The header's page switch always shows all three pages (no hover
    /// dock) and always says which one is open; clicks and ⌘1/⌘2/⌘3 select.
    func testPageSwitchShowsEveryPageAndExactlyOneSelection() {
        let picker = app.descendants(matching: .any)
            .matching(identifier: "panel-section-picker")
            .firstMatch
        let tasks = app.buttons["panel-section-tasks"]
        let notes = app.buttons["panel-section-notes"]
        let canvas = app.buttons["panel-section-canvas"]
        let pin = app.buttons["panel-pin-button"]
        let pages = [tasks, notes, canvas]

        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        pin.hover()
        XCTAssertTrue(tasks.exists && notes.exists && canvas.exists, "every page stays visible away from the switch")
        XCTAssertFalse(app.buttons["panel-section-backlog"].exists, "Backlog lives inside the Tasks page")
        assertExactlyOneSelected(in: pages, expected: tasks)
        let width = picker.frame.width

        notes.click()
        assertExactlyOneSelected(in: pages, expected: notes)
        app.typeKey("3", modifierFlags: .command)
        assertExactlyOneSelected(in: pages, expected: canvas)
        XCTAssertEqual(picker.frame.width, width, accuracy: 0.5, "the switch keeps its width")
        app.typeKey("1", modifierFlags: .command)
        assertExactlyOneSelected(in: pages, expected: tasks)
    }

    /// Focus rings are for keyboard navigation only: clicking a page and
    /// coming back leaves the switch looking exactly as it did.
    func testClickingTheSwitchShowsNoFocusRing() throws {
        let picker = app.descendants(matching: .any)
            .matching(identifier: "panel-section-picker")
            .firstMatch
        let tasks = app.buttons["panel-section-tasks"]
        let notes = app.buttons["panel-section-notes"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        let away = app.buttons["panel-pin-button"]
        away.hover()
        Thread.sleep(forTimeInterval: 0.5)
        let before = picker.screenshot()
        notes.click()
        tasks.click()
        away.hover()
        Thread.sleep(forTimeInterval: 0.6)
        let after = picker.screenshot()
        let changed = try differingPixelFraction(before.image, after.image)
        let attachment = XCTAttachment(image: after.image)
        attachment.name = "page-switch-after-clicks"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(changed, 0.01, "a mouse click must not leave a focus ring (\(changed) of pixels changed)")
    }

    private func differingPixelFraction(_ lhs: NSImage, _ rhs: NSImage) throws -> Double {
        let a = try XCTUnwrap(lhs.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let b = try XCTUnwrap(rhs.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        var differing = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let delta = max(abs(p.redComponent - q.redComponent),
                                abs(p.greenComponent - q.greenComponent),
                                abs(p.blueComponent - q.blueComponent))
                if delta > 0.06 { differing += 1 }
            }
        }
        return Double(differing) / Double(max(1, width * height))
    }

    private func launch(resetCanvasStore: Bool) {
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_CANVAS_RESET"] =
            resetCanvasStore ? "1" : "0"
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["ATTIC_TEST_ATTACHMENT_ROOT"],
           let token = environment[
            "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN"
           ] {
            app.launchEnvironment["ATTIC_TEST_ATTACHMENT_ROOT"] = root
            app.launchEnvironment[
                "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN"
            ] = token
        }
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
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(
            canvasSurface.waitForExistence(timeout: 3)
        )
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "canvas-surface").count, 1)
        XCTAssertEqual(canvasSurface.label, "Canvas drawing board")
        XCTAssertTrue(canvasSurface.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Canvas objects"))
            .firstMatch.exists, "The native object accessibility tree must remain exposed")
    }

    private var canvasSurface: XCUIElement {
        // The children-preserving SwiftUI wrapper is exposed as Group on macOS.
        // Its stable identifier, label, and native child tree define the surface.
        app.descendants(matching: .any).matching(identifier: "canvas-surface").firstMatch
    }

    private func assertFitAndResetChangeObjectGeometry(_ object: XCUIElement,
                                                       file: StaticString = #filePath, line: UInt = #line) {
        let original = object.frame
        app.typeKey("9", modifierFlags: .command)
        waitForFrame(of: object, matching: NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            // Fitting can legitimately remain close to 100% when the content
            // already fills the available width. Recentring is still a real
            // viewport change; verify both scale and position, then require
            // Actual Size to restore the exact original geometry below.
            return abs(element.frame.width - original.width) > 2
                || abs(element.frame.minX - original.minX) > 2
                || abs(element.frame.minY - original.minY) > 2
        }, file: file, line: line)
        app.typeKey("0", modifierFlags: .command)
        waitForFrame(of: object, matching: NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return abs(element.frame.width - original.width) < 1
                && abs(element.frame.minX - original.minX) < 1
                && abs(element.frame.minY - original.minY) < 1
        }, file: file, line: line)
    }

    private func waitForFrame(of element: XCUIElement, matching predicate: NSPredicate,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 3),
                       .completed, file: file, line: line)
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
        // Use AppKit mouse synthesis; press/drag belongs to XCUI touch events.
        start.click(
            forDuration: 0.05,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
    }

    private func prepareSurfaceForInkInput(_ surface: XCUIElement) {
        let select = app.buttons["canvas-tool-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 2))
        app.typeKey("v", modifierFlags: [])
        waitForSelection(true, on: select)
        surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()

        let pen = app.buttons["canvas-tool-pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 2))
        app.typeKey("p", modifierFlags: [])
        waitForSelection(true, on: pen)
    }

    private func eraseStroke(on surface: XCUIElement) {
        let start = surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.20, dy: 0.34)
        )
        let end = surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.80, dy: 0.63)
        )
        start.click(
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

    private func waitForEnabled(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "enabled == true")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: predicate,
                        object: element
                    )
                ],
                timeout: 4
            ),
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
