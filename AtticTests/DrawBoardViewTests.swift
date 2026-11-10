import AppKit
import XCTest
@testable import Attic

/// The board's engine rules (Planning.md, Draw › Engine): input never rasters
/// on the main thread, a press after a pan is handled at once, and nothing
/// renders while hidden. Synthetic events, no window on screen.
@MainActor
final class DrawBoardViewTests: XCTestCase {
    private var store: DrawInMemoryStore!
    private var model: DrawPageModel!
    private var board: DrawBoardView!

    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        store = DrawInMemoryStore()
        model = DrawPageModel(store: store)
        model.pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-draw-board-tests-\(UUID().uuidString)"))
        board = DrawBoardView(model: model)
        board.setFrameSize(CGSize(width: 320, height: 460))
        model.start()
        model.setShown(true)
    }

    override func tearDown() {
        model.setShown(false)
        model.pasteboard.releaseGlobally()
        board = nil
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        super.tearDown()
    }

    func testAuditB4TabAndArrowsVisitObjectsInReadingOrderWithoutEditingThem() throws {
        let text = DrawObject(frame: DrawFrame(x: 30, y: 100, width: 80, height: 30), zIndex: 9, content: .text("Launch plan"))
        let ink = DrawObject(frame: DrawFrame(x: 200, y: 90, width: 30, height: 20), zIndex: 1,
            content: .stroke([DrawPoint(x: 0, y: 0), DrawPoint(x: 30, y: 20)]))
        let rectangle = DrawObject(frame: DrawFrame(x: 20, y: 180, width: 80, height: 80), zIndex: 3, content: .shape(.rectangle))
        let ellipse = DrawObject(frame: DrawFrame(x: 200, y: 190, width: 80, height: 80), zIndex: 0, content: .shape(.ellipse))
        let id = try XCTUnwrap(model.canvasID)
        XCTAssertTrue(store.perform(.put([ellipse, rectangle, text, ink]), on: id).isSaved)
        model.open(id)
        let before = try store.open(id).objects
        let revision = store.revision
        let ordered = [text.id, ink.id, rectangle.id, ellipse.id]
        for expected in ordered {
            XCTAssertTrue(model.handleKey(DrawKey(characters: "\t", keyCode: 48)))
            XCTAssertEqual(model.selection, [expected])
        }
        XCTAssertFalse(model.handleKey(DrawKey(characters: "\t", keyCode: 48)), "Tab past the last object leaves the board")
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.handleKey(DrawKey(characters: "\t", keyCode: 48, shift: true)))
        XCTAssertEqual(model.selection, [ellipse.id])
        XCTAssertTrue(model.handleKey(DrawKey(characters: "", keyCode: 123)))
        XCTAssertEqual(model.selection, [rectangle.id])
        XCTAssertTrue(model.handleKey(DrawKey(characters: "", keyCode: 126)))
        XCTAssertEqual(model.selection, [ink.id])
        XCTAssertTrue(model.handleKey(DrawKey(characters: "", keyCode: 125)))
        XCTAssertEqual(model.selection, [rectangle.id])
        XCTAssertTrue(model.handleKey(DrawKey(characters: "", keyCode: 124)))
        XCTAssertEqual(model.selection, [ellipse.id])
        XCTAssertFalse(model.handleKey(DrawKey(characters: "", keyCode: 123, option: true)))
        XCTAssertEqual(try store.open(id).objects, before)
        XCTAssertEqual(store.revision, revision, "navigation changes selection and viewport, never the drawing")
    }

    func testAuditB4VoiceOverNamesEveryObjectAndKeepsStableLiveFrames() throws {
        let objects: [DrawObject] = [
            .init(frame: DrawFrame(x: 20, y: 40), content: .text("Launch plan")),
            .init(frame: DrawFrame(x: 20, y: 110), content: .shape(.rectangle)),
            .init(frame: DrawFrame(x: 180, y: 110), content: .shape(.ellipse)),
            .init(frame: DrawFrame(x: 20, y: 180), content: .shape(.line)),
            .init(frame: DrawFrame(x: 180, y: 180), content: .shape(.arrow)),
            .init(frame: DrawFrame(x: 20, y: 250), content: .stroke([.init(x: 0, y: 0), .init(x: 20, y: 20)])),
            .init(frame: DrawFrame(x: 180, y: 250), content: .image(.init(original: Data([1]), pixelWidth: 20, pixelHeight: 20)))
        ]
        let id = try XCTUnwrap(model.canvasID)
        XCTAssertTrue(store.perform(.put(objects), on: id).isSaved)
        model.open(id)
        let window = NSWindow(contentRect: board.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = board
        defer { window.close() }
        let children = board.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        XCTAssertEqual(children.count, objects.count)
        let first = try XCTUnwrap(children.first)
        let names = children.compactMap { $0.accessibilityLabel() }.joined(separator: " ")
        for kind in ["Launch plan", "Rectangle", "Ellipse", "Line", "Arrow", "Pen stroke", "Image"] {
            XCTAssertTrue(names.contains(kind), "every kind has a useful name: \(kind)")
        }
        XCTAssertTrue(first.accessibilityPerformPress())
        XCTAssertEqual(model.selection, [objects[0].id])
        let before = first.accessibilityFrame()
        XCTAssertGreaterThan(before.width, 0)
        XCTAssertGreaterThan(before.height, 0)
        model.setViewport(DrawViewport(x: 27, y: -35, zoom: 1.4), byUser: true)
        let again = try XCTUnwrap((board.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        XCTAssertTrue(first === again, "viewport updates retain the element identity")
        XCTAssertNotEqual(again.accessibilityFrame(), before)
        model.deleteSelection()
        XCTAssertEqual(board.accessibilityChildren()?.count, objects.count - 1)
        XCTAssertFalse(first.accessibilityPerformPress(), "a removed element cannot select a stale object")
    }

    func testAuditB4TabLeavesTheBoardAtBothEndsOfItsNativeKeyViewLoop() throws {
        final class Stop: NSView { override var acceptsFirstResponder: Bool { true } }
        let id = try XCTUnwrap(model.canvasID)
        let object = DrawObject(frame: DrawFrame(x: 50, y: 70), content: .shape(.rectangle))
        XCTAssertTrue(store.perform(.put([object]), on: id).isSaved)
        model.open(id)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        let before = Stop(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        let after = Stop(frame: CGRect(x: 40, y: 0, width: 30, height: 30))
        root.addSubview(before); root.addSubview(board); root.addSubview(after)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.autorecalculatesKeyViewLoop = false
        before.nextKeyView = board; board.nextKeyView = after; after.nextKeyView = before
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(board))
        board.keyDown(with: key(.keyDown, "\t", code: 48))
        XCTAssertEqual(model.selection, [object.id])
        XCTAssertTrue(window.firstResponder === board)
        board.keyDown(with: key(.keyDown, "\t", code: 48))
        XCTAssertTrue(window.firstResponder === after)
        XCTAssertTrue(window.makeFirstResponder(board))
        model.select([object.id])
        let backwards = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        board.keyDown(with: backwards)
        XCTAssertTrue(window.firstResponder === before)
    }

    /// Board points are y-down; AppKit's view points are y-up.
    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: board.bounds.height - point.y),
                           modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func key(_ type: NSEvent.EventType, _ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    private func stroke(from: CGPoint, to: CGPoint) {
        board.mouseDown(with: mouse(.leftMouseDown, from))
        board.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 + 8)))
        board.mouseDragged(with: mouse(.leftMouseDragged, to))
        board.mouseUp(with: mouse(.leftMouseUp, to))
    }

    private func waitForInstall(after count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while board.rasterInstalls <= count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return board.rasterInstalls > count
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testAccessibilityKeepsTheZoomReadableWhenThePillSaysFit() {
        model.setTool(.pen)
        stroke(from: CGPoint(x: 40, y: 100), to: CGPoint(x: 200, y: 160))
        for zoom in [0.1, 0.5, 1.0, 4.0] {
            model.setViewport(DrawViewport(x: 10000, y: 10000, zoom: zoom), byUser: true)
            model.viewportState.isFlashing = false
            XCTAssertEqual(model.viewportState.pillLabel, "Fit")
            let value = board.accessibilityValue() as? String ?? ""
            XCTAssertTrue(value.contains("\(Int(zoom * 100)) %"), "zoom remains readable: \(value)")
        }
    }

    func testInputNeverRastersOnTheMainThread() {
        XCTAssertTrue(waitForInstall(after: 0), "The first raster installs")
        DrawRasterProbe.reset()
        let installs = board.rasterInstalls
        model.setTool(.pen)
        stroke(from: CGPoint(x: 40, y: 100), to: CGPoint(x: 200, y: 160))
        model.scroll(dx: 30, dy: 20, command: false, at: CGPoint(x: 100, y: 100))
        model.magnify(by: 0.3, at: CGPoint(x: 100, y: 100))
        model.scroll(dx: 0, dy: 10, command: true, at: CGPoint(x: 100, y: 100))
        model.setTool(.select)
        model.selectAll()
        board.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 120, y: 140)))
        board.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 160, y: 180)))
        board.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 160, y: 180)))
        XCTAssertEqual(DrawRasterProbe.mainThreadRasters, 0, "No input handler rasters synchronously")
        XCTAssertTrue(waitForInstall(after: installs))
        XCTAssertGreaterThan(DrawRasterProbe.rasters, 0)
        XCTAssertEqual(DrawRasterProbe.mainThreadRasters, 0, "Committed content renders on the background renderer")
        XCTAssertEqual(model.objects.count, 1)
    }

    /// Repeatable event-to-live-layer timings. Recorded before and after an
    /// ink change on the Air, with enough existing content to keep the raster
    /// worker busy. This logs measurements; it imposes no invented speed gate.
    func testInkTimingOnPopulatedBoard() throws {
        model.thumbnailSettleDelay = 60
        let canvasID = try XCTUnwrap(model.canvasID)
        let imageData = Draw3Images.encoded(width: 20, height: 20)
        let populated: [DrawObject] = (0..<440).map { index in
            let x = Double((index % 22) * 15), y = Double((index / 22) * 17)
            let content: DrawContent
            switch index % 11 {
            case 0: content = .text("Canvas text \(index)")
            case 1: content = .shape(.rectangle)
            case 2: content = .image(DrawImage(original: imageData, pixelWidth: 20, pixelHeight: 20))
            default: content = .stroke((0..<32).map { n in DrawPoint(x: x + Double(n), y: y + sin(Double(n) / 6) * 8) })
            }
            return DrawObject(frame: DrawFrame(x: x, y: y, width: 40, height: 20), zIndex: Int64(index), content: content)
        }
        XCTAssertTrue(store.perform(.put(populated), on: canvasID).isSaved)
        model.open(canvasID)
        _ = waitForInstall(after: board.rasterInstalls)
        model.setTool(.pen)
        for run in 0..<3 {
            model.pointerDown(at: CGPoint(x: 40, y: 160))
            var durations: [Double] = []
            for i in 0..<1_200 {
                let x = 40 + Double(i % 800) * 0.35
                let y = 160 + sin(Double(i) * 0.06) * 25
                let begin = DispatchTime.now().uptimeNanoseconds
                model.pointerDragged(to: CGPoint(x: x, y: y))
                durations.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000)
            }
            let finish = DispatchTime.now().uptimeNanoseconds
            model.pointerUp()
            let finishMS = Double(DispatchTime.now().uptimeNanoseconds - finish) / 1_000_000
            durations.sort()
            print("CANVAS_INK_TIMING run=\(run) objects=440 samples=1200 p50_ms=\(durations[600]) p95_ms=\(durations[1140]) max_ms=\(durations.last!) finish_ms=\(finishMS)")
            XCTAssertEqual(model.objects.count, 441)
            model.undo()
        }
    }

    func testPressAfterAPanIsHandledAtOnce() {
        model.setTool(.pen)
        board.keyDown(with: key(.keyDown, " ", code: 49))
        board.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
        board.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 150, y: 130)))
        board.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 150, y: 130)))
        board.keyUp(with: key(.keyUp, " ", code: 49))
        XCTAssertEqual(model.viewport.x, 50, accuracy: 0.01, "Space-drag pans")
        XCTAssertTrue(model.objects.isEmpty)
        model.scroll(dx: -12, dy: 6, command: false, at: .zero)
        board.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 60)))
        guard case .ink = model.live else { return XCTFail("The press right after a pan starts the stroke") }
        board.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 90, y: 80)))
        XCTAssertEqual(model.objects.count, 1)
    }

    func testSecondBoardClickStillDrawsAndErasesWhenNotSelecting() {
        model.setTool(.pen)
        let point = CGPoint(x: 85, y: 120)
        board.mouseDown(with: mouse(.leftMouseDown, point, clicks: 2))
        board.mouseUp(with: mouse(.leftMouseUp, point, clicks: 2))
        XCTAssertEqual(model.objects.count, 1, "double-clicking the board with Pen draws a dot")

        model.setTool(.eraser)
        board.mouseDown(with: mouse(.leftMouseDown, point, clicks: 2))
        board.mouseUp(with: mouse(.leftMouseUp, point, clicks: 2))
        XCTAssertTrue(model.objects.isEmpty, "double-clicking a stroke with Eraser removes it")
    }

    func testUndoRedoWhileTypingPreservesTheMiddleOfTheLineCaret() throws {
        let window = NSWindow(contentRect: board.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = board
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(board))

        model.setTool(.text)
        board.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 115)))
        let editor = try XCTUnwrap(board.editor)
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText("Hello world", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(model.editing?.text, "Hello world")

        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.insertText("X", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.editing?.text, "Hello Xworld")

        model.undo()
        XCTAssertEqual(editor.string, "Hello world")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 0), "Undo returns the caret to the edit")
        model.redo()
        XCTAssertEqual(editor.string, "Hello Xworld")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 0), "Redo returns the caret after the insertion")
    }

    func testNativeTextMovementAndStyledInsertionRespectTheBoxStyle() throws {
        let window = NSWindow(contentRect: board.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = board
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(board))

        model.setTool(.text)
        board.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 115)))
        let editor = try XCTUnwrap(board.editor)
        editor.insertText("alpha beta\nsecond", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(model.editing?.text, "alpha beta\nsecond")

        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.moveToBeginningOfLine(nil)
        XCTAssertEqual(editor.selectedRange().location, 0)
        editor.moveToEndOfLine(nil)
        XCTAssertEqual(editor.selectedRange().location, 10)
        editor.moveWordLeft(nil)
        XCTAssertTrue((0..<10).contains(editor.selectedRange().location))

        let expectedAttributes = editor.typingAttributes
        editor.setSelectedRange(NSRange(location: 6, length: 4))
        editor.insertText(NSAttributedString(string: "👩🏽‍🚀", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.systemRed
        ]), replacementRange: editor.selectedRange())

        XCTAssertEqual(model.editing?.text, "alpha 👩🏽‍🚀\nsecond")
        XCTAssertEqual(editor.string, model.editing?.text)
        let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        // The emoji itself is drawn from the emoji font (font fallback), so
        // the box's one size is what must hold, not the font's name.
        XCTAssertEqual(font.pointSize, (expectedAttributes[.font] as? NSFont)?.pointSize,
                       "Text boxes have one size even when rich text is inserted")
        let after = try XCTUnwrap(editor.textStorage?.attribute(.font, at: editor.string.utf16.count - 1, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(after, expectedAttributes[.font] as? NSFont, "Text after the insertion keeps the box's font")
        let colour = try XCTUnwrap(editor.textStorage?.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(colour, expectedAttributes[.foregroundColor] as? NSColor, "Text boxes use the swatch's colour")
    }

    func testEndingTextEditingDoesNotTakeFocusFromAnotherControl() throws {
        final class SearchControl: NSView {
            override var acceptsFirstResponder: Bool { true }
        }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        root.addSubview(board)
        let search = SearchControl(frame: CGRect(x: 20, y: 465, width: 180, height: 30))
        root.addSubview(search)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }

        XCTAssertTrue(window.makeFirstResponder(board))
        model.setTool(.text)
        board.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 115)))
        let editor = try XCTUnwrap(board.editor)
        editor.insertText("Draft", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(model.editing?.text, "Draft")

        XCTAssertTrue(window.makeFirstResponder(search))
        model.endEditing()
        XCTAssertTrue(window.firstResponder === search, "Clicking Search should end the box edit without stealing the next control's focus")
    }

    func testEditorTextRendersAtTheCurrentZoomWhileTyping() throws {
        let window = NSWindow(contentRect: board.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = board
        defer { window.close() }

        XCTAssertTrue(window.makeFirstResponder(board))
        model.setTool(.text)
        board.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 115)))
        let editor = try XCTUnwrap(board.editor)
        editor.insertText("Zoom", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(model.editing?.text, "Zoom")
        let pointSize = try XCTUnwrap(model.editing?.pointSize)

        for zoom in [CGFloat(2), 0.25, 4, 1] {
            model.setViewport(DrawViewport(x: 5, y: 10, zoom: zoom), byUser: true)
            let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, pointSize * zoom, accuracy: 0.01, "The live editor follows every zoom change")
            XCTAssertEqual(editor.string, "Zoom")
        }
    }

    func testBoardMouseUpRetainsShiftConstraintForShapeAndResize() throws {
        model.pickShape(.rectangle)
        let from = CGPoint(x: 60, y: 110), to = CGPoint(x: 145, y: 138)
        board.mouseDown(with: mouse(.leftMouseDown, from))
        board.mouseDragged(with: mouse(.leftMouseDragged, to, flags: [.shift]))
        guard case .shape(_, let start, let end) = model.live else { return XCTFail("No constrained shape preview") }
        let previewFrame = DrawGeometry.boxFrame(from: start, to: end)
        XCTAssertEqual(previewFrame.width, previewFrame.height, accuracy: 0.01)
        board.mouseUp(with: mouse(.leftMouseUp, to, flags: [.shift]))
        let object = try XCTUnwrap(model.objects.first)
        XCTAssertEqual(object.frame, previewFrame)

        model.select([object.id])
        let handle = try XCTUnwrap(model.handleSpots.first { $0.handle == .bottomRight })
        let resizeEnd = CGPoint(x: handle.point.x + 75, y: handle.point.y + 12)
        board.mouseDown(with: mouse(.leftMouseDown, handle.point))
        board.mouseDragged(with: mouse(.leftMouseDragged, resizeEnd, flags: [.shift]))
        guard case .resize(let preview) = model.live else { return XCTFail("No constrained resize preview") }
        let resized = try XCTUnwrap(preview.current.first)
        board.mouseUp(with: mouse(.leftMouseUp, resizeEnd, flags: [.shift]))
        XCTAssertEqual(model.objects.first, resized)
        model.undo()
        XCTAssertEqual(model.objects.first, object, "Resizing takes one Undo step")
    }

    func testNothingRendersWhileHidden() {
        XCTAssertTrue(waitForInstall(after: 0))
        model.setShown(false)
        DrawRasterProbe.reset()
        let requests = board.rasterRequests, installs = board.rasterInstalls
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 40, y: 100))
        model.pointerDragged(to: CGPoint(x: 140, y: 120))
        model.pointerUp()
        model.scroll(dx: 20, dy: 20, command: false, at: .zero)
        board.setFrameSize(CGSize(width: 340, height: 480))
        spin(0.3)
        XCTAssertEqual(board.rasterRequests, requests)
        XCTAssertEqual(board.rasterInstalls, installs)
        XCTAssertEqual(DrawRasterProbe.rasters, 0)
        model.setShown(true)
        XCTAssertTrue(waitForInstall(after: installs), "Showing the board again renders what changed")
    }

    func testStrokeSurvivesResizeAndZoomOnTheBoard() {
        model.setTool(.pen)
        board.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 40, y: 100)))
        board.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 80, y: 120)))
        board.setFrameSize(CGSize(width: 360, height: 500))
        model.magnify(by: -0.2, at: CGPoint(x: 100, y: 100))
        board.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 120, y: 140)))
        XCTAssertNotNil(model.live, "Resize and zoom never cancel a stroke")
        board.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 120, y: 140)))
        XCTAssertEqual(model.objects.count, 1)
    }

    func testKeysReachTheModelThroughTheBoard() {
        board.keyDown(with: key(.keyDown, "e", code: 14))
        XCTAssertEqual(model.tool, .eraser)
        board.keyDown(with: key(.keyDown, "r", code: 15))
        XCTAssertEqual(model.tool, .shape)
        XCTAssertEqual(model.shape, .rectangle)
    }
}
