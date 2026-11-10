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
    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: board.bounds.height - point.y),
                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
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
