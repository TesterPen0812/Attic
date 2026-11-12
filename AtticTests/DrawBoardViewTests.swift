import AppKit
import ImageIO
import XCTest
import SwiftUI
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

    /// Regression for the owner's 10 Nov recording: a large selected image
    /// and ink must keep receiving committed pixels during a moving pinch.
    /// A worker cannot finish in between consecutive viewport samples.
    func testCommittedBoardKeepsRenderingDuringContinuousViewportChanges() throws {
        XCTAssertTrue(waitForInstall(after: 0))
        DrawRasterProbe.setTestDelay(0.15)
        defer { DrawRasterProbe.setTestDelay(0) }
        let id = try XCTUnwrap(model.canvasID)
        let image = Draw3Images.encoded(width: 1170, height: 1428, red: 0.55, green: 0.57, blue: 0.57)
        var objects: [DrawObject] = [
            DrawObject(frame: DrawFrame(x: 0, y: 0, width: 585, height: 714),
                       content: .image(DrawImage(original: image, pixelWidth: 1170, pixelHeight: 1428)))
        ]
        objects += (0..<320).map { index in
            let x = Double(index % 20) * 29, y = Double(index / 20) * 42
            let points = (0..<28).map { n in DrawPoint(x: x + Double(n), y: y + sin(Double(n) / 5) * 6) }
            return DrawObject(frame: DrawGeometry.strokeFrame(points), zIndex: Int64(index + 1), content: .stroke(points))
        }
        XCTAssertTrue(store.perform(.put(objects), on: id).isSaved)
        model.open(id)
        let before = board.rasterInstalls
        DrawRasterProbe.reset()
        for sample in 0..<110 {
            let zoom = CGFloat(0.5 + Double(sample % 32) / 32 * 2.5)
            model.setViewport(DrawViewport(x: CGFloat(-sample * 3), y: CGFloat(sample), zoom: zoom), byUser: true)
            spin(0.008)
        }
        XCTAssertGreaterThan(board.rasterInstalls, before,
                             "At least one complete raster must land before a continuous pinch/pan ends")
        XCTAssertEqual(DrawRasterProbe.mainThreadRasters, 0)
    }

    /// Air-only diagnostic, measuring the exact raster input size seen in the
    /// recording at 2x plus a few hundred representative ink objects.
    func testLargeImageRasterTimingAtTwoTimes() async {
        let image = Draw3Images.encoded(width: 1170, height: 1428, red: 0.55, green: 0.57, blue: 0.57)
        var objects: [DrawObject] = [
            DrawObject(frame: DrawFrame(x: 0, y: 0, width: 585, height: 714),
                       content: .image(DrawImage(original: image, pixelWidth: 1170, pixelHeight: 1428)))
        ]
        objects += (0..<320).map { index in
            let x = Double(index % 20) * 29, y = Double(index / 20) * 42
            let points = (0..<28).map { n in DrawPoint(x: x + Double(n), y: y + sin(Double(n) / 5) * 6) }
            return DrawObject(frame: DrawGeometry.strokeFrame(points), zIndex: Int64(index + 1), content: .stroke(points))
        }
        let request = DrawRasterRequest(key: DrawRasterKey(viewport: DrawViewport(),
                                     size: CGSize(width: 600, height: 740), scale: 2), objects: objects)
        let readings = await Task.detached(priority: .userInitiated) {
            (0..<4).map { _ -> Double in
                let start = DispatchTime.now().uptimeNanoseconds
                _ = DrawRaster.render(request)
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
        }.value
        print("CANVAS_BOARD_RASTER_2X image=1170x1428 strokes=320 samples_ms=\(readings)")
    }

    func testWorldRasterAlwaysCoversObjectsAndTracksSelectionAtEveryViewport() throws {
        let id = try XCTUnwrap(model.canvasID)
        let image = DrawObject(frame: DrawFrame(x: 80, y: 30, width: 585, height: 714),
                               content: .image(DrawImage(original: Draw3Images.encoded(width: 1170, height: 1428),
                                                         pixelWidth: 1170, pixelHeight: 1428)))
        XCTAssertTrue(store.perform(.put([image]), on: id).isSaved)
        model.open(id)
        let deadline = Date().addingTimeInterval(5)
        while board.installedKey?.revision != model.contentRevision, Date() < deadline { spin(0.01) }
        let backing = try XCTUnwrap(board.installedKey)
        let worldRect = CGRect(x: -backing.viewport.x / backing.viewport.zoom,
                               y: -backing.viewport.y / backing.viewport.zoom,
                               width: backing.size.width / backing.viewport.zoom,
                               height: backing.size.height / backing.viewport.zoom)
        XCTAssertTrue(worldRect.contains(DrawGeometry.bounds(image)), "The complete selected image stays in the backing")

        let rasterLayer = try XCTUnwrap(board.layer?.sublayers?[1])
        let requests = board.rasterRequests
        for viewport in [DrawViewport(x: -600, y: 45, zoom: 0.1),
                         DrawViewport(x: 15, y: -400, zoom: 4),
                         DrawViewport(x: -150, y: -100, zoom: 0.5)] {
            model.setViewport(viewport, byUser: true)
            let expected = viewport.screen(worldRect)
            let actual = rasterLayer.convert(rasterLayer.bounds, to: board.layer)
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.1)
            XCTAssertEqual(actual.minY, board.bounds.height - expected.maxY, accuracy: 0.1)
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.1)
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.1)
        }
        XCTAssertEqual(board.rasterRequests, requests, "Pan and zoom only transform the complete backing")
        XCTAssertEqual(DrawRasterProbe.mainThreadRasters, 0)
    }

    func testZoomRefinesTheWorldImageAtScreenResolutionAfterGesturesSettle() throws {
        let id = try XCTUnwrap(model.canvasID)
        let image = DrawObject(frame: DrawFrame(x: 0, y: 0, width: 585, height: 714),
                               content: .image(DrawImage(original: Draw3Images.encoded(width: 1170, height: 1428),
                                                         pixelWidth: 1170, pixelHeight: 1428)))
        XCTAssertTrue(store.perform(.put([image]), on: id).isSaved)
        let baseline = board.rasterInstalls
        model.open(id)
        XCTAssertTrue(waitForInstall(after: baseline), "Complete world raster lands before zooming")
        let previous = board.detailInstalls
        DrawRasterProbe.reset()
        let started = DispatchTime.now().uptimeNanoseconds
        model.setViewport(DrawViewport(x: 0, y: 0, zoom: 3.5), byUser: true)
        let deadline = Date().addingTimeInterval(2)
        while board.detailInstalls == previous && Date() < deadline { spin(0.005) }
        XCTAssertGreaterThan(board.detailInstalls, previous, "The stopped zoom gets its sharp viewport raster")
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        print("CANVAS_BOARD_DETAIL latency_ms=\(ms)")
        XCTAssertFalse(try XCTUnwrap(board.layer?.sublayers?[2]).isHidden)
        XCTAssertEqual(DrawRasterProbe.mainThreadRasters, 0)
    }

    /// Diagnostic opt-in on the Air: capture only this offscreen NSWindow's
    /// board layer. Each contact sheet places the old viewport-clipped
    /// transport above the actual board's world-raster transport.
    func testWindowOnlyFrameSheetsForScriptedPinchAndPan() async throws {
        guard ProcessInfo.processInfo.environment["CANVAS_BOARD_FRAME_DIR"]?.isEmpty == false else {
            throw XCTSkip("Air capture requires CANVAS_BOARD_FRAME_DIR")
        }
        let canvas = try XCTUnwrap(model.canvasID)
        let image = DrawObject(frame: DrawFrame(x: 0, y: 0, width: 585, height: 714),
                               content: .image(DrawImage(original: Draw3Images.encoded(width: 1170, height: 1428),
                                                         pixelWidth: 1170, pixelHeight: 1428)))
        var objects = [image]
        objects += (0..<320).map { index in
            let x = Double(index % 20) * 29, y = Double(index / 20) * 42
            let points = (0..<28).map { n in DrawPoint(x: x + Double(n), y: y + sin(Double(n) / 5) * 6) }
            return DrawObject(frame: DrawGeometry.strokeFrame(points), zIndex: Int64(index + 1), content: .stroke(points))
        }
        XCTAssertTrue(store.perform(.put(objects), on: canvas).isSaved)
        model.open(canvas)
        model.setTool(.select)
        model.select([image.id])
        // This is an async @MainActor test. A synchronous RunLoop spin can
        // starve the dispatch-to-main raster installation until the next await.
        let deadline = Date().addingTimeInterval(5)
        while board.installedKey?.revision != model.contentRevision, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard board.installedKey?.revision == model.contentRevision else {
            XCTFail("Capture requires a complete backing at the current content revision")
            return
        }
        XCTAssertNotNil(board.layer?.sublayers?[1].contents, "Capture requires the installed world raster")

        let window = NSWindow(contentRect: board.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = board
        defer { window.close() }
        let layers = try XCTUnwrap(board.layer?.sublayers)
        let base = layers[1]
        let detail = layers[2]

        // Capture exactly the old viewport-clipped raster once, then carry
        // it across the same transform as the committed layer did before.
        let oldKey = DrawRasterKey(revision: model.contentRevision, viewport: model.viewport,
                                   size: board.bounds.size, scale: 2)
        let oldRequest = DrawRasterRequest(key: oldKey, objects: model.objects)
        let oldRendered = await Task.detached(priority: .userInitiated) {
            DrawRaster.render(oldRequest)
        }.value
        let oldImage = try XCTUnwrap(oldRendered).image
        let old = CALayer()
        old.actions = DrawBoardView.noActions
        old.anchorPoint = .zero
        old.position = .zero
        old.bounds = CGRect(origin: .zero, size: oldKey.size)
        old.contents = oldImage
        old.contentsScale = oldKey.scale
        board.layer?.insertSublayer(old, above: base)
        defer { old.removeFromSuperlayer() }

        func snapshot() -> CGImage? {
            let width = Int(board.bounds.width), height = Int(board.bounds.height)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            board.layer?.render(in: context)
            return context.makeImage()
        }

        func sheet(_ name: String, _ viewports: [DrawViewport]) throws {
            let width = Int(board.bounds.width), height = Int(board.bounds.height)
            guard let sheet = CGContext(data: nil, width: width * viewports.count, height: height * 2,
                                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return XCTFail("Could not make window-only frame sheet")
            }
            for (index, viewport) in viewports.enumerated() {
                model.setViewport(viewport, byUser: true)
                CATransaction.flush()
                let s = viewport.zoom / oldKey.viewport.zoom
                old.setAffineTransform(CGAffineTransform(a: s, b: 0, c: 0, d: s,
                    tx: viewport.x - s * oldKey.viewport.x,
                    ty: board.bounds.height - s * oldKey.size.height + s * oldKey.viewport.y - viewport.y))
                let inset = CGRect(x: CGFloat(index * width), y: CGFloat(height),
                                   width: CGFloat(width), height: CGFloat(height))
                base.isHidden = true
                detail.isHidden = true
                old.isHidden = false
                if let frame = snapshot() { sheet.draw(frame, in: inset) }
                base.isHidden = false
                old.isHidden = true
                if let frame = snapshot() { sheet.draw(frame, in: inset.offsetBy(dx: 0, dy: -CGFloat(height))) }
            }
            let data = NSMutableData()
            guard let sheetImage = sheet.makeImage(),
                  let output = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                return XCTFail("Could not create \(name) PNG")
            }
            CGImageDestinationAddImage(output, sheetImage, nil)
            XCTAssertTrue(CGImageDestinationFinalize(output))
            let attachment = XCTAttachment(data: data as Data, uniformTypeIdentifier: "public.png")
            attachment.name = "\(name)-old-above-new.png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        try sheet("pinch-in", [DrawViewport(x: 10, y: 15, zoom: 0.65),
                                DrawViewport(x: -90, y: -200, zoom: 1.3),
                                DrawViewport(x: -210, y: -410, zoom: 2.1),
                                DrawViewport(x: -350, y: -700, zoom: 3.5)])
        try sheet("pinch-out", [DrawViewport(x: -350, y: -700, zoom: 3.5),
                                 DrawViewport(x: -210, y: -410, zoom: 2.1),
                                 DrawViewport(x: -70, y: -145, zoom: 0.85),
                                 DrawViewport(x: 90, y: 130, zoom: 0.2)])
        try sheet("two-finger-pan", [DrawViewport(x: 0, y: 0, zoom: 0.6),
                                     DrawViewport(x: -120, y: -60, zoom: 0.6),
                                     DrawViewport(x: -240, y: -120, zoom: 0.6),
                                     DrawViewport(x: -360, y: -180, zoom: 0.6)])
        print("CANVAS_BOARD_FRAME_SHEETS attachments=3 old_above_new=3")
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

    /// Measures input dispatch to the next committed layer/editor-frame
    /// candidate inside the invisible host; no display refresh or vblank is
    /// claimed. Both object counts share the same board and synthetic inputs.
    func testHunt16StrokeAndTypingInputFrameCandidateAt20And2000Objects() throws {
        model.thumbnailSettleDelay = 60
        let bytes = Draw3Images.encoded(width: 8, height: 8)
        for count in [20, 2_000] {
            let canvas = store.create(name: "hunt-timing-\(count)")
            let contents: [DrawObject] = (0..<count).map { n in
                let frame = DrawFrame(x: Double((n % 50) * 23), y: Double((n / 50) * 23),
                                      width: 19, height: 18)
                let value: DrawContent
                switch n % 13 {
                case 0: value = .text("Text \(n)")
                case 1: value = .image(DrawImage(original: bytes, pixelWidth: 8, pixelHeight: 8))
                default: value = .shape(.rectangle)
                }
                return DrawObject(frame: frame, zIndex: Int64(n), content: value)
            }
            XCTAssertTrue(store.perform(.put(contents), on: canvas.id).isSaved)
            model.open(canvas.id)
            model.setViewport(DrawViewport(), byUser: true)
            model.setTool(.pen)
            model.pointerDown(at: CGPoint(x: 40, y: 160))
            var strokeTimes: [Double] = []
            for n in 0..<48 {
                let start = DispatchTime.now().uptimeNanoseconds
                model.pointerDragged(to: CGPoint(x: 40 + Double(n) * 2, y: 160 + sin(Double(n) / 4) * 18))
                strokeTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            model.pointerUp()
            model.undo() // Typing starts with exactly the requested object count.

            model.beginText(at: CGPoint(x: 30, y: 330))
            var typingTimes: [Double] = []
            var text = ""
            for _ in 0..<36 {
                text += "x"
                let start = DispatchTime.now().uptimeNanoseconds
                board.editorTextChanged(text)
                typingTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            model.endEditing()
            for (kind, timings) in [("stroke", strokeTimes), ("typing", typingTimes)] {
                let sorted = timings.sorted()
                let p50 = sorted[sorted.count / 2]
                let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
                print("DRAW_HUNT16_INPUT_FRAME_CANDIDATE kind=\(kind) objects=\(count) " +
                      "p50_ms=\(p50) p95_ms=\(p95) max_ms=\(sorted.last!)")
            }
            XCTAssertEqual(try store.open(canvas.id).objects.count, count + 1)
        }
    }

    func testHunt16DeletedCanvasNeverLeavesItsLiveInkOverlayOnNextBoard() throws {
        let deletedID = try XCTUnwrap(model.canvasID)
        let survivor = store.create(name: "Other drawing")
        let object = DrawObject(frame: DrawFrame(x: 40, y: 130, width: 60, height: 30),
                                content: .shape(.rectangle))
        XCTAssertTrue(store.perform(.put([object]), on: survivor.id).isSaved)
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 110, y: 180))
        model.pointerDragged(to: CGPoint(x: 145, y: 205))
        XCTAssertTrue(store.performAgent(.deleteCanvas, on: deletedID).isSaved)
        model.pointerUp(at: CGPoint(x: 160, y: 215))
        XCTAssertEqual(model.canvasID, survivor.id)
        XCTAssertTrue(board.pendingOverlays.isEmpty,
                      "Live ink from a deleted canvas must never become an overlay on the surviving board")
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

/// Owner, 12 Nov: leaving Draw for another page showed Draw's strokes and
/// shapes over that page for about a second. The page going out stays
/// opaque while the switch's spring carries it a panel width aside
/// (`PanelPageMotion.pageOpacityAnimation`), so anything the board draws
/// outside its own frame lands on the page coming in. Hosted through
/// SwiftUI as the panel hosts it, frame by frame along the real spring.
@MainActor
final class DrawPageSwitchBleedTests: XCTestCase {
    private final class Travel: ObservableObject { @Published var x: CGFloat = 0 }

    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
    }

    override func tearDown() {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        super.tearDown()
    }

    func testLeavingDrawNeverDrawsItsContentOverTheDestinationPage() throws {
        let store = DrawInMemoryStore()
        let model = DrawPageModel(store: store)
        model.pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-draw-bleed-\(UUID().uuidString)"))
        defer { model.setShown(false); model.pasteboard.releaseGlobally() }
        let size = CGSize(width: 320, height: 460)
        let travel = Travel()
        struct Host: View {
            let model: DrawPageModel
            @ObservedObject var travel: Travel
            var body: some View {
                ZStack {
                    Color.clear
                    DrawBoardRepresentable(model: model, clearInsets: NSEdgeInsets())
                        .modifier(PanelPageVisibility(isCurrent: true, restingOffset: 0, disablesWhenHidden: true))
                        .offset(x: travel.x)
                }
            }
        }
        let hosting = NSHostingView(rootView: Host(model: model, travel: travel).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        model.start()
        model.setShown(true)
        let board = try XCTUnwrap(model.board as? DrawBoardView)

        // Ink, a rectangle and a large drawn shape, zoomed so the drawing
        // runs past both sides of the board (as the owner's did).
        let id = try XCTUnwrap(model.canvasID)
        let points = (0..<40).map { n in DrawPoint(x: Double(n) * 8, y: 200 + sin(Double(n) / 4) * 30) }
        let objects = [
            DrawObject(frame: DrawGeometry.strokeFrame(points), zIndex: 1, content: .stroke(points)),
            DrawObject(frame: DrawFrame(x: 10, y: 60, width: 300, height: 120), zIndex: 2, content: .shape(.rectangle)),
            DrawObject(frame: DrawFrame(x: 0, y: 260, width: 320, height: 180), zIndex: 3, content: .shape(.ellipse))
        ]
        XCTAssertTrue(store.perform(.put(objects), on: id).isSaved)
        let installs = board.rasterInstalls
        model.open(id)
        model.setViewport(DrawViewport(x: -320, y: -200, zoom: 3), byUser: true)
        let deadline = Date().addingTimeInterval(5)
        while board.rasterInstalls <= installs, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertGreaterThan(board.rasterInstalls, installs, "the drawing must be on the board before the switch")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let motion = PanelPageMotion.current(reduceMotion: false)
        let spring = try XCTUnwrap(motion.spring)
        let curve = Spring(duration: spring.response, bounce: spring.bounce)
        XCTAssertNotNil(motion.pageOpacityAnimation(incoming: false), "the page going out stays drawn while it travels")
        for destination in [PanelPage.notes, .tasks, .calendar] {
            travel.x = 0
            model.setShown(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            // The switch begins: Draw is no longer current (DrawPageHost).
            model.setShown(false)
            let side = PanelPage.canvas.side(from: destination)
            XCTAssertNotEqual(side, 0)
            var frame = 0
            var time: TimeInterval = 0
            while time <= motion.settleDuration {
                let x = side * CGFloat(curve.value(target: Double(size.width), time: time))
                travel.x = x
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                hosting.layoutSubtreeIfNeeded()
                let leaked = Self.paintedPixels(hosting, size: size, outside: board.convert(board.bounds, to: hosting))
                XCTAssertEqual(leaked, 0, "Draw → \(destination.rawValue), frame \(frame) (x \(Int(x))): Draw drew \(leaked) px over the destination page")
                if leaked > 0 { break }
                frame += 1
                time += 1.0 / 60
            }
            XCTAssertGreaterThan(frame, 10, "Draw → \(destination.rawValue): the switch must be sampled across its frames")
        }
    }

    /// Non-transparent pixels the hosting view renders inside the panel but
    /// outside `pageFrame` (the area the page coming in occupies).
    private static func paintedPixels(_ view: NSView, size: CGSize, outside pageFrame: CGRect) -> Int {
        guard let layer = view.layer else { return -1 }
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return -1 }
        layer.render(in: context)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let left = Int(max(0, min(size.width, pageFrame.minX).rounded(.down)))
        let right = Int(max(0, min(size.width, pageFrame.maxX).rounded(.up)))
        var count = 0
        for row in 0..<height {
            for column in 0..<width where column < left || column >= right {
                if pixels[(row * width + column) * 4 + 3] > 8 { count += 1 }
            }
        }
        return count
    }
}
