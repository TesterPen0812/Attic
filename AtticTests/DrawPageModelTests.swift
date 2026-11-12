import AppKit
import XCTest
@testable import Attic

/// The Draw page's tools, strips, selection, keys and zoom against the
/// in-memory store (Planning.md, Accepted "Draw: the canvas page", D1–D6).
@MainActor
final class DrawPageModelTests: XCTestCase {
    private var store: DrawInMemoryStore!
    private var model: DrawPageModel!

    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
        AtticDraw.enabledOverride = true
        store = DrawInMemoryStore()
        model = DrawPageModel(store: store)
        model.pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-draw-tests-\(UUID().uuidString)"))
        model.setBoard(size: CGSize(width: 320, height: 460),
                       clearInsets: NSEdgeInsets(top: 48.5, left: 15.5, bottom: 48.5, right: 15.5))
        model.start()
    }

    override func tearDown() {
        model.pasteboard.releaseGlobally()
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        AtticDraw.enabledOverride = nil
        super.tearDown()
    }

    private var stored: [DrawObject] { (try? store.open(model.canvasID!).objects) ?? [] }

    private func drag(_ points: [CGPoint], shift: Bool = false) {
        model.pointerDown(at: points[0], shift: shift)
        for point in points.dropFirst() { model.pointerDragged(to: point, shift: shift) }
        model.pointerUp()
    }

    private func stroke(at y: CGFloat = 100) {
        model.setTool(.pen)
        drag([CGPoint(x: 60, y: y), CGPoint(x: 90, y: y + 10), CGPoint(x: 130, y: y)])
    }

    func testExternalCanvasRenameDeferredDuringPanAppliesOnPointerUp() throws {
        let id = try XCTUnwrap(model.canvasID)
        XCTAssertTrue(store.perform(.rename("Before pan"), on: id).isSaved)
        model.syncExternalChanges()
        model.pointerDown(at: CGPoint(x: 100, y: 100), panButton: true)
        XCTAssertTrue(store.perform(.rename("During pan"), on: id).isSaved)
        model.syncExternalChanges()
        XCTAssertEqual(model.canvasName, "Before pan")
        model.pointerUp()
        XCTAssertEqual(model.canvasName, "During pan")
    }

    func testExternalCanvasDeleteDuringPanSwitchesAfterPointerUp() throws {
        stroke()
        let deletedID = try XCTUnwrap(model.canvasID)
        model.pointerDown(at: CGPoint(x: 100, y: 100), panButton: true)
        XCTAssertTrue(store.perform(.deleteCanvas, on: deletedID).isSaved)
        model.syncExternalChanges()
        XCTAssertEqual(model.canvasID, deletedID, "live input retains its original canvas")
        model.pointerUp()
        XCTAssertNotEqual(model.canvasID, deletedID, "deletion is reconciled once the pan ends")
        XCTAssertFalse(try store.library().contains { $0.id == deletedID })
    }

    func testExternalCanvasRestoreDuringPanKeepsTheCompletedViewport() throws {
        stroke()
        let id = try XCTUnwrap(model.canvasID)
        model.pointerDown(at: CGPoint(x: 100, y: 100), panButton: true)
        XCTAssertTrue(store.perform(.deleteCanvas, on: id).isSaved)
        XCTAssertTrue(store.perform(.restoreCanvas, on: id).isSaved)
        model.syncExternalChanges()
        model.pointerDragged(to: CGPoint(x: 140, y: 120))
        let completedView = model.viewport
        model.pointerUp()
        XCTAssertEqual(model.canvasID, id)
        XCTAssertEqual(model.viewport, completedView, "restore must not reset a live pan")
    }

    func testExternalRenameDuringInkKeepsTheFinishedStrokeAndNewName() throws {
        let id = try XCTUnwrap(model.canvasID)
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 60, y: 100))
        model.pointerDragged(to: CGPoint(x: 90, y: 120))
        XCTAssertTrue(store.perform(.rename("Renamed during ink"), on: id).isSaved)
        model.syncExternalChanges()
        model.pointerUp()
        XCTAssertEqual(model.canvasName, "Renamed during ink")
        XCTAssertEqual(try store.open(id).objects.count, 1, "input must settle before external revision merges")
    }

    private func key(_ characters: String, code: UInt16 = 0, command: Bool = false, shift: Bool = false) -> Bool {
        model.handleKey(DrawKey(characters: characters, keyCode: code, command: command, shift: shift))
    }

    func testAuditA5EscapeClosesSearchBeforeChangingBoardState() {
        model.openSearch()
        model.search.query = "plan"
        XCTAssertTrue(key("\u{1B}", code: DrawKey.escapeCode))
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.search.query, "")
    }

    func testAuditA6CommandZRestoresDeletedCanvasWhileToastOffersUndo() throws {
        stroke()
        let deleted = try XCTUnwrap(model.canvasID)
        let toasts = PanelToastCenter()
        model.library.toasts = toasts
        model.library.perform(.delete)
        XCTAssertNotNil(toasts.current)
        XCTAssertNotEqual(model.canvasID, deleted)
        XCTAssertTrue(key("z", command: true))
        XCTAssertEqual(model.canvasID, deleted)
        XCTAssertTrue(try store.library().contains { $0.id == deleted })
    }

    func testAuditA7OpeningBeforeBoardLayoutFitsOnceRealSizeArrives() throws {
        stroke()
        let fresh = DrawPageModel(store: store)
        fresh.setBoard(size: .zero, clearInsets: model.clearInsets)
        fresh.start()
        fresh.setBoard(size: CGSize(width: 320, height: 460), clearInsets: model.clearInsets)
        let expected = DrawViewport.fit(DrawGeometry.union(fresh.objects), in: fresh.clearRect)
        XCTAssertEqual(fresh.viewport, expected)
        XCTAssertGreaterThan(fresh.viewport.zoom, DrawViewport.minZoom)
        fresh.setViewport(DrawViewport(x: 15, y: 20, zoom: 0.5), byUser: true)
        fresh.setBoard(size: CGSize(width: 400, height: 500), clearInsets: model.clearInsets)
        XCTAssertEqual(fresh.viewport, DrawViewport(x: 15, y: 20, zoom: 0.5), "resizing preserves a user-chosen view")
    }

    // MARK: Tools reach the store

    func testPenStoresOneSmoothedStroke() {
        stroke()
        XCTAssertEqual(stored.count, 1)
        guard case .stroke(let samples) = stored[0].content else { return XCTFail("Not a stroke") }
        XCTAssertGreaterThan(samples.count, 3, "The raw samples are smoothed into a curve")
        XCTAssertEqual(stored[0].style.size, .medium)
        XCTAssertEqual(model.tool, .pen)
    }

    func testEraserRemovesWholeStrokesOnly() {
        stroke()
        model.setTool(.shape)
        drag([CGPoint(x: 60, y: 200), CGPoint(x: 160, y: 260)])
        XCTAssertEqual(stored.count, 2)
        model.setTool(.eraser)
        drag([CGPoint(x: 90, y: 80), CGPoint(x: 90, y: 130), CGPoint(x: 100, y: 230)])
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].content, .shape(.rectangle), "The eraser leaves shapes alone")
    }

    func testEraserUsesStrokeSamplesEvenWhenStoredFrameIsStale() throws {
        let id = try XCTUnwrap(model.canvasID)
        let samples = [DrawPoint(x: 90, y: 100), DrawPoint(x: 110, y: 100)]
        let stroke = DrawObject(frame: DrawFrame(x: 0, y: 0, width: 1, height: 1),
                                content: .stroke(samples))
        XCTAssertTrue(store.perform(.put([stroke]), on: id).isSaved)
        model.syncExternalChanges()
        model.setTool(.eraser)
        drag([CGPoint(x: 100, y: 92), CGPoint(x: 100, y: 108)])
        XCTAssertTrue(stored.isEmpty, "The broad-phase must preserve hit-testing against actual samples")
        XCTAssertTrue(store.perform(.put([stroke]), on: id).isSaved)
        model.syncExternalChanges()
        drag([CGPoint(x: 40, y: 100), CGPoint(x: 160, y: 100)])
        XCTAssertTrue(stored.isEmpty, "A horizontal path must hit between two endpoints outside the stroke bounds")
    }

    func testEraserRespectsThinPressureNibAndCrossesStrokesUnderShapes() throws {
        let light = DrawObject(frame: DrawFrame(x: 60, y: 100, width: 40, height: 0),
                               style: DrawStyle(colour: .blue, size: .small, corners: .square),
                               content: .stroke([DrawPoint(x: 60, y: 100, pressure: 0), DrawPoint(x: 100, y: 100, pressure: 0)]))
        let covered = DrawObject(frame: DrawFrame(x: 60, y: 150, width: 40, height: 0),
                                 style: DrawStyle(colour: .green, size: .large, corners: .square),
                                 content: .stroke([DrawPoint(x: 60, y: 150, pressure: 1), DrawPoint(x: 100, y: 150, pressure: 1)]))
        let shape = DrawObject(frame: DrawFrame(x: 50, y: 140, width: 70, height: 30),
                               zIndex: 100, content: .shape(.rectangle))
        XCTAssertTrue(model.perform(.put([light, covered, shape])).isSaved)
        model.setTool(.eraser)
        // 5pt cursor reach + 0.375pt half-width of a 0-pressure thin pen.
        drag([CGPoint(x: 65, y: 105.5), CGPoint(x: 105, y: 105.5)])
        XCTAssertTrue(stored.contains(where: { $0.id == light.id }), "outside the visible thin nib must not erase")
        drag([CGPoint(x: 80, y: 133), CGPoint(x: 80, y: 170)])
        XCTAssertFalse(stored.contains(where: { $0.id == covered.id }), "fast crossing must erase under a shape")
        XCTAssertTrue(stored.contains(where: { $0.id == shape.id }), "eraser never removes shapes")
    }

    func testPenPressureSmoothsAndSurvivesMoveAndResize() throws {
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 60, y: 100), pressure: 0)
        model.pointerDragged(to: CGPoint(x: 90, y: 120), pressure: 0.5)
        model.pointerUp(at: CGPoint(x: 130, y: 100), pressure: 1)
        let original = try XCTUnwrap(stored.first)
        guard case .stroke(let points) = original.content else { return XCTFail("Not a stroke") }
        XCTAssertGreaterThan(points.count, 3)
        XCTAssertEqual(points.first?.pressure, 0)
        XCTAssertEqual(points.last?.pressure, 1)
        XCTAssertTrue(points.contains { ($0.pressure ?? 0) > 0 && ($0.pressure ?? 0) < 1 })
        let moved = original.translated(by: DrawPoint(x: 12, y: 20), id: original.id)
        guard case .stroke(let translated) = moved.content else { return XCTFail("Move lost ink") }
        XCTAssertEqual(translated.map(\.pressure), points.map(\.pressure))
        let resized = DrawPageModel.resized([moved], handle: .bottomRight,
                                           delta: CGPoint(x: 50, y: 20), shift: false)
        guard case .stroke(let stretched) = resized.first?.content else { return XCTFail("Resize lost ink") }
        XCTAssertEqual(stretched.map(\.pressure), points.map(\.pressure))
        let data = try JSONEncoder().encode(moved)
        let roundTripped = try JSONDecoder().decode(DrawObject.self, from: data)
        XCTAssertEqual(roundTripped, moved)
    }

    func testPressureInkRendersThinAtLightContactAndBroadAtFirmContact() {
        let outline = DrawInk.pressureOutline([
            DrawPoint(x: 20, y: 20, pressure: 0),
            DrawPoint(x: 120, y: 20, pressure: 1),
        ], baseWidth: 10)
        XCTAssertFalse(outline.contains(CGPoint(x: 30, y: 25)), "light nib stays narrower than 10pt")
        XCTAssertTrue(outline.contains(CGPoint(x: 110, y: 25)), "firm nib grows beyond 10pt")
        XCTAssertTrue(outline.contains(CGPoint(x: 20, y: 20)))
        XCTAssertTrue(outline.contains(CGPoint(x: 120, y: 20)))
    }

    func testTabletPressureIsNotResetByAnInterleavedMouseRelease() throws {
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 60, y: 100))
        model.pointerDragged(to: CGPoint(x: 90, y: 120), pressure: 0.8)
        model.pointerDragged(to: CGPoint(x: 100, y: 110))
        model.pointerUp(at: CGPoint(x: 130, y: 100))
        let saved = try XCTUnwrap(stored.first)
        guard case .stroke(let points) = saved.content else { return XCTFail("Not a stroke") }
        XCTAssertEqual(try XCTUnwrap(points.last?.pressure), 0.8, accuracy: 0.0001)
    }

    func testTextPlacesABoxAndTypesStraightAway() {
        model.setTool(.text)
        model.pointerDown(at: CGPoint(x: 80, y: 120))
        XCTAssertNotNil(model.editing)
        model.typed("H")
        model.typed("Hi")
        XCTAssertEqual(stored.map(\.text), ["Hi"])
        XCTAssertGreaterThan(stored[0].frame.width, 6)
        model.endEditing()
        XCTAssertEqual(model.tool, .select)
    }

    func testVeryNarrowWrappingKeepsEmojiAndRTLTextIntact() {
        let samples = [
            "Start 👩🏽‍🚀 אבג 🧑‍💻 End",
            "Start\r👩🏽‍🚀\rאבג End",
            String(repeating: "á👩‍👩‍👧‍👧אבג", count: 48)
        ]
        for text in samples {
            for width in [CGFloat(0.01), 0.5, 2, 8, 15, 55] {
                let lines = DrawText.lines(text, size: 14, width: width)
                XCTAssertEqual(lines.joined(), text, "Wrap at \(width)pt must not lose source characters")
                XCTAssertEqual(lines.flatMap { Array($0) }, Array(text), "A wrapped line must not split a grapheme")
            }
        }
    }

    func testShapeIsDraggedOutThenReturnsToSelectWithNothingSelected() {
        model.clickTool(.shape)
        model.pickShape(.ellipse)
        drag([CGPoint(x: 60, y: 200), CGPoint(x: 160, y: 260)])
        XCTAssertEqual(stored.map(\.content), [.shape(.ellipse)])
        XCTAssertEqual(model.tool, .select)
        XCTAssertTrue(model.selection.isEmpty, "No auto-select after adding (owner decision)")
    }

    func testRectanglesStartSquareAndStyleRoundsThem() {
        model.pickShape(.rectangle)
        drag([CGPoint(x: 60, y: 200), CGPoint(x: 160, y: 260)])
        XCTAssertEqual(stored[0].style.corners, .square)
        model.select([stored[0].id])
        XCTAssertTrue(model.selectionHasRectangle)
        model.styleSelection(corners: .rounded)
        XCTAssertEqual(stored[0].style.corners, .rounded)
    }

    func testLineKeepsItsDirection() {
        model.pickShape(.line)
        drag([CGPoint(x: 160, y: 200), CGPoint(x: 60, y: 260)])
        let (a, b) = DrawGeometry.endpoints(stored[0].frame)
        XCTAssertEqual(a.x, 160, accuracy: 0.01)
        XCTAssertEqual(b.x, 60, accuracy: 0.01)
    }

    func testShiftConstrainedShapeCommitsTheGeometryShownBeforeMouseUp() throws {
        model.pickShape(.rectangle)
        let end = CGPoint(x: 160, y: 260)
        model.pointerDown(at: CGPoint(x: 60, y: 200))
        model.pointerDragged(to: end, shift: true)
        guard case .shape(_, let start, let previewEnd) = model.live else { return XCTFail("Missing shape preview") }
        let preview = DrawGeometry.boxFrame(from: start, to: previewEnd)
        XCTAssertEqual(preview.width, preview.height, accuracy: 0.01)
        model.pointerUp(at: end)
        let saved = try XCTUnwrap(stored.first)
        XCTAssertEqual(saved.frame, preview, "Mouse-up must preserve Shift-constrained geometry")
    }

    func testShiftConstrainedResizeCommitsTheGeometryShownBeforeMouseUp() throws {
        let rectangle = DrawObject(frame: DrawFrame(x: 60, y: 140, width: 90, height: 50),
                                   content: .shape(.rectangle))
        XCTAssertTrue(model.perform(.put([rectangle])).isSaved)
        model.setTool(.select)
        model.select([rectangle.id])
        let corner = try XCTUnwrap(model.handleSpots.first { $0.handle == .bottomRight })
        let end = CGPoint(x: corner.point.x + 80, y: corner.point.y + 10)
        model.pointerDown(at: corner.point)
        model.pointerDragged(to: end, shift: true)
        guard case .resize(let preview) = model.live else { return XCTFail("Missing resize preview") }
        let expected = try XCTUnwrap(preview.current.first)
        XCTAssertNotEqual(expected.frame, rectangle.frame)
        model.pointerUp(at: end)
        XCTAssertEqual(stored.first, expected, "Mouse-up must preserve Shift-constrained resize")
    }

    // MARK: Strips (Shape, D1, D2) and D3

    func testShapeWidensInPlaceAndEscapeFoldsIt() {
        model.clickTool(.shape)
        XCTAssertEqual(model.strip, .shape)
        XCTAssertFalse(model.isUndoShown, "Undo folds away while the shapes are open")
        XCTAssertTrue(model.escape())
        XCTAssertNil(model.strip)
        XCTAssertTrue(model.isUndoShown)
        model.clickTool(.shape)
        model.pickShape(.arrow)
        XCTAssertNil(model.strip, "Picking one closes them")
        XCTAssertEqual(model.shape, .arrow)
    }

    func testPressOnTheBoardWithShapesOpenDrawsTheShapeStraightAway() {
        model.clickTool(.shape)
        model.pointerDown(at: CGPoint(x: 60, y: 200))
        XCTAssertNil(model.strip)
        guard case .shape = model.live else { return XCTFail("The press starts the current shape") }
        model.pointerUp(at: CGPoint(x: 150, y: 260))
        XCTAssertEqual(stored.count, 1)
    }

    func testSwatchWidensIntoTheColours() {
        model.clickSwatch()
        XCTAssertEqual(model.strip, .colour)
        XCTAssertFalse(model.isUndoShown)
        model.clickTool(.shape)
        XCTAssertEqual(model.strip, .shape, "Only one strip is open at a time")
        model.clickSwatch()
        model.pickColour(.blue)
        XCTAssertNil(model.strip)
        XCTAssertEqual(model.colour, .blue)
        model.clickSwatch()
        model.pointerDown(at: CGPoint(x: 60, y: 200))
        XCTAssertNil(model.strip, "A press on the board closes the colours")
        XCTAssertNil(model.live, "…without drawing")
        model.clickSwatch()
        XCTAssertTrue(model.escape())
        XCTAssertTrue(model.isUndoShown)
    }

    func testSecondClickOnPenOrTextWidensItsWidths() {
        model.clickTool(.eraser)
        model.clickTool(.pen)
        XCTAssertEqual(model.tool, .pen)
        XCTAssertNil(model.strip, "The first click only picks the tool")
        model.clickTool(.pen)
        XCTAssertEqual(model.strip, .pen)
        model.pickSize(.large, for: .pen)
        XCTAssertEqual(model.strokeSize, .large)
        XCTAssertNil(model.strip)
        model.clickTool(.text)
        model.clickTool(.text)
        XCTAssertEqual(model.strip, .text)
        XCTAssertTrue(model.escape())
        XCTAssertNil(model.strip)
    }

    func testStyleOpensInsideTheSelectionBarAndEscapeFoldsIt() {
        stroke()
        model.setTool(.select)
        model.select([stored[0].id])
        model.toggleSelectionStyle()
        XCTAssertTrue(model.isSelectionStyleOpen)
        model.styleSelection(colour: .green)
        XCTAssertEqual(stored[0].style.colour, .green)
        XCTAssertTrue(model.isSelectionStyleOpen, "Picking keeps Style open")
        XCTAssertTrue(model.escape())
        XCTAssertFalse(model.isSelectionStyleOpen)
        XCTAssertEqual(model.selection, [stored[0].id], "Escape closes Style before clearing the selection")
    }

    // MARK: Selection bar by kind

    func testSelectionBarContentsByKind() {
        stroke()
        stroke(at: 200)
        let image = DrawObject(frame: DrawFrame(x: 40, y: 300, width: 80, height: 60), zIndex: 10,
                               content: .image(DrawImage(original: Data([1, 2, 3]), pixelWidth: 2, pixelHeight: 2)))
        model.perform(.put([image]))
        let ids = stored.map(\.id)
        let strokes = stored.filter { !$0.isImage }.map(\.id)
        model.setTool(.select)
        model.select([strokes[0]])
        XCTAssertEqual(model.selectionActions, [.style, .delete, .more])
        model.select(strokes)
        XCTAssertEqual(model.selectionActions, [.style, .duplicate, .delete, .more])
        model.select([image.id])
        XCTAssertEqual(model.selectionActions, [.saveImage, .duplicate, .delete, .more])
        model.select(ids)
        XCTAssertEqual(model.selectionActions, [.style, .duplicate, .delete, .more])
        XCTAssertTrue(model.isEnabled(.copyAsImage), "Draw 3: Copy as Image works on the selection")
        XCTAssertEqual(DrawMoreCommand.allCases.map(\.title),
                       ["Cut", "Copy", "Paste", "Duplicate", "Copy as Image", "Bring to Front", "Send to Back", "Delete"])
    }

    func testSelectionBarHidesWhileDrawing() {
        stroke()
        model.setTool(.select)
        model.select([stored[0].id])
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 200, y: 300))
        XCTAssertTrue(model.isDrawingLive)
        XCTAssertTrue(model.selectionActions.isEmpty)
        model.pointerUp()
        XCTAssertFalse(model.isDrawingLive)
    }

    // MARK: Keys

    func testLetterKeysPickTools() {
        let expected: [(String, DrawTool, DrawShape?)] = [("v", .select, nil), ("p", .pen, nil), ("e", .eraser, nil), ("t", .text, nil),
                                                          ("r", .shape, .rectangle), ("o", .shape, .ellipse), ("l", .shape, .line),
                                                          ("a", .shape, .arrow)]
        for (letter, tool, shape) in expected {
            XCTAssertTrue(key(letter), letter)
            XCTAssertEqual(model.tool, tool, letter)
            if let shape { XCTAssertEqual(model.shape, shape, letter) }
        }
    }

    func testCommandKeys() {
        stroke()
        stroke(at: 200)
        XCTAssertTrue(key("z", command: true))
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(key("z", command: true, shift: true))
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(key("a", command: true))
        XCTAssertEqual(Set(model.selection), Set(stored.map(\.id)))
        XCTAssertEqual(model.tool, .select)
        XCTAssertTrue(key("d", command: true))
        XCTAssertEqual(stored.count, 4)
        XCTAssertEqual(model.selection.count, 2, "⌘D selects the copies")
        XCTAssertTrue(key("c", command: true))
        XCTAssertTrue(model.canPaste)
        XCTAssertTrue(key("x", command: true))
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(key("v", command: true))
        XCTAssertEqual(stored.count, 4)
    }

    func testSendToBackPutsEverySelectedObjectBehindUnselectedAndUndoesTogether() {
        let bottom = DrawObject(zIndex: 1, content: .shape(.rectangle))
        let middle = DrawObject(zIndex: 2, content: .shape(.ellipse))
        let front = DrawObject(zIndex: 3, content: .shape(.arrow))
        let top = DrawObject(zIndex: 4, content: .shape(.line))
        XCTAssertTrue(model.perform(.put([bottom, middle, front, top])).isSaved)
        model.select([front.id, top.id])
        model.runMore(.sendToBack)

        XCTAssertEqual(stored.map(\.id), [front.id, top.id, bottom.id, middle.id],
                       "Both selected objects must move behind the old bottom, without a z-index tie")
        XCTAssertEqual(stored.count, 4)
        model.undo()
        XCTAssertEqual(stored, [bottom, middle, front, top], "The group reorder is one Undo step")
        model.redo()
        XCTAssertEqual(stored.map(\.id), [front.id, top.id, bottom.id, middle.id])
    }

    func testMovingSelectedStrokeAndShapeTracksHandlesAndSavesOnlyOnRelease() throws {
        let points = (0..<3000).map { DrawPoint(x: 180 + Double($0) / 15, y: 300 + sin(Double($0) / 10) * 15) }
        let stroke = DrawObject(frame: DrawGeometry.strokeFrame(points), zIndex: 1, content: .stroke(points))
        let shape = DrawObject(frame: DrawFrame(x: 70, y: 140, width: 55, height: 30),
                               zIndex: 2, content: .shape(.rectangle))
        XCTAssertTrue(model.perform(.put([stroke, shape])).isSaved)
        model.setViewport(DrawViewport(x: 0, y: 0, zoom: 1), byUser: true)
        model.setTool(.select)
        model.select([stroke.id, shape.id])
        let before = model.handleSpots
        let original = stored
        let delta = CGPoint(x: 23, y: 16)
        model.pointerDown(at: CGPoint(x: 90, y: 155))
        model.pointerDragged(to: CGPoint(x: 90 + delta.x, y: 155 + delta.y))
        guard case .move = model.live else { return XCTFail("Expected a live selection move") }
        XCTAssertEqual(stored, original, "A live drag does not persist intermediate frames")
        for (first, current) in zip(before, model.handleSpots) {
            XCTAssertEqual(first.handle, current.handle)
            XCTAssertEqual(current.point.x, first.point.x + delta.x, accuracy: 0.01)
            XCTAssertEqual(current.point.y, first.point.y + delta.y, accuracy: 0.01)
        }
        model.pointerUp()
        XCTAssertEqual(model.object(shape.id)?.frame.x, shape.frame.x + Double(delta.x))
        XCTAssertEqual(model.object(stroke.id)?.frame.x, stroke.frame.x + Double(delta.x))
        model.undo()
        XCTAssertEqual(stored, original, "Both objects move and undo in one save")
    }

    func testInkEraseColourAndWidthUndoRedoThirtyStepsExactly() {
        var history: [[DrawObject]] = [stored]
        for index in 0..<25 {
            model.setTool(.pen)
            drag([CGPoint(x: 60, y: 100 + CGFloat(index) * 18),
                  CGPoint(x: 90, y: 105 + CGFloat(index) * 18),
                  CGPoint(x: 130, y: 100 + CGFloat(index) * 18)])
            history.append(stored)
        }
        let target = stored[0].id
        model.setTool(.select)
        model.select([target])
        model.styleSelection(colour: .red)
        history.append(stored)
        model.styleSelection(size: .large)
        history.append(stored)
        model.setTool(.eraser)
        drag([CGPoint(x: 90, y: 90), CGPoint(x: 90, y: 108)])
        XCTAssertLessThan(stored.count, 25, "eraser removes whole strokes")
        history.append(stored)

        for index in stride(from: history.count - 2, through: 0, by: -1) {
            XCTAssertTrue(key("z", command: true))
            XCTAssertEqual(stored, history[index], "undo exactly restores step \(index)")
        }
        XCTAssertFalse(model.canUndo)
        for index in 1..<history.count {
            XCTAssertTrue(key("z", command: true, shift: true))
            XCTAssertEqual(stored, history[index], "redo exactly restores step \(index)")
        }
        XCTAssertFalse(model.canRedo)
        model.undo() // The toolbar's action is the same undo path.
        XCTAssertEqual(stored, history[history.count - 2])
    }

    func testDeleteReturnAndEscape() {
        model.setTool(.text)
        model.pointerDown(at: CGPoint(x: 80, y: 120))
        model.typed("Note")
        model.endEditing()
        model.select([stored[0].id])
        XCTAssertTrue(key("\r", code: DrawKey.returnCode))
        XCTAssertEqual(model.editing?.id, stored[0].id, "Return edits the selected text box")
        model.endEditing()
        model.select([stored[0].id])
        XCTAssertTrue(key("\u{1b}", code: DrawKey.escapeCode))
        XCTAssertTrue(model.selection.isEmpty)
        model.select([stored[0].id])
        XCTAssertTrue(key("\u{7f}", code: DrawKey.deleteCode))
        XCTAssertTrue(stored.isEmpty)
    }

    func testSpaceDragPans() {
        model.spaceHeld = true
        let before = model.viewport
        drag([CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 130)])
        XCTAssertEqual(model.viewport.x, before.x + 40, accuracy: 0.01)
        XCTAssertEqual(model.viewport.y, before.y + 30, accuracy: 0.01)
        XCTAssertTrue(stored.isEmpty, "Space-drag never draws")
    }

    // MARK: Zoom (D5)

    func testZoomStaysBetweenTenAndFourHundredPercent() {
        model.magnify(by: 50, at: CGPoint(x: 160, y: 230))
        XCTAssertEqual(model.viewport.zoom, 4, accuracy: 0.0001)
        for _ in 0..<40 { model.scroll(dx: 0, dy: -25, command: true, at: CGPoint(x: 160, y: 230)) }
        XCTAssertEqual(model.viewport.zoom, 0.1, accuracy: 0.0001)
        XCTAssertTrue(key("0", code: DrawKey.zeroCode, shift: true))
        XCTAssertEqual(model.viewport.zoom, 1, accuracy: 0.0001)
        XCTAssertTrue(model.viewportState.pillShown, "The pill shows the level for a moment")
        XCTAssertEqual(model.viewportState.pillLabel, "100 %")
    }

    func testPillReadsFitWhileNothingIsInViewAndAClickFits() {
        stroke()
        XCTAssertFalse(model.viewportState.isLost)
        model.scroll(dx: -2000, dy: 0, command: false, at: .zero)
        XCTAssertTrue(model.viewportState.isLost)
        XCTAssertTrue(model.viewportState.pillShown)
        model.viewportState.isFlashing = false
        XCTAssertEqual(model.viewportState.pillLabel, "Fit")
        XCTAssertTrue(key("1", code: DrawKey.oneCode, shift: true))
        XCTAssertFalse(model.viewportState.isLost)
        XCTAssertTrue(model.viewport.anyInView(stored.map(DrawGeometry.bounds), clear: model.clearRect))
    }

    func testEmptyBoardNeverReadsFit() {
        model.scroll(dx: -2000, dy: 0, command: false, at: .zero)
        XCTAssertFalse(model.viewportState.isLost, "The empty board shows nothing")
    }

    // MARK: Strokes survive

    func testStrokeFinishesAsDrawnOnHideAndPageSwitch() throws {
        model.setShown(true)
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 60, y: 100))
        model.pointerDragged(to: CGPoint(x: 120, y: 140))
        model.setShown(false)
        XCTAssertEqual(stored.count, 1, "Hiding finishes the stroke as drawn")
        XCTAssertNil(model.live)
        model.setShown(true)
        let first = try XCTUnwrap(model.canvasID)
        model.pointerDown(at: CGPoint(x: 60, y: 200))
        model.pointerDragged(to: CGPoint(x: 120, y: 240))
        model.newCanvas()
        XCTAssertNil(model.live)
        XCTAssertEqual(try store.open(first).objects.filter { $0.deletedAt == nil }.count, 2,
                       "Switching canvas finishes the stroke on the canvas it was drawn on")
    }

    func testStrokeSurvivesZoomAndResizeMidStroke() {
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 60, y: 100))
        model.pointerDragged(to: CGPoint(x: 80, y: 110))
        model.magnify(by: 0.5, at: CGPoint(x: 160, y: 230))
        model.pointerDragged(to: CGPoint(x: 100, y: 120))
        model.setBoard(size: CGSize(width: 360, height: 500), clearInsets: model.clearInsets)
        model.scroll(dx: 10, dy: 10, command: false, at: .zero)
        model.pointerDragged(to: CGPoint(x: 140, y: 130))
        guard case .ink(let trace) = model.live else { return XCTFail("The stroke is still live") }
        XCTAssertEqual(trace.samples.count, 4)
        model.pointerUp()
        XCTAssertEqual(stored.count, 1)
    }

    // MARK: Text boxes

    func testRepeatedSingleObjectSavesKeepLayerOrderAndZChangesStillReorder() {
        let bottom = DrawObject(zIndex: 1, content: .shape(.rectangle))
        var writing = DrawObject(zIndex: 2, content: .text("A"))
        let top = DrawObject(zIndex: 3, content: .shape(.ellipse))
        XCTAssertTrue(model.perform(.put([bottom, writing, top])).isSaved)
        for text in ["AB", "ABC", "ABCD"] {
            writing.content = .text(text)
            XCTAssertTrue(model.perform(.put([writing])).isSaved)
            XCTAssertEqual(model.objects.map(\.id), [bottom.id, writing.id, top.id])
        }
        model.undo()
        XCTAssertEqual(model.objects.map(\.text), ["", "ABC", ""])
        writing.zIndex = 4
        XCTAssertTrue(model.perform(.put([writing])).isSaved)
        XCTAssertEqual(model.objects.map(\.id), [bottom.id, top.id, writing.id])
        XCTAssertEqual(model.objects.last?.text, "ABCD")
    }

    func testUndoWorksWhileTyping() {
        model.setTool(.text)
        model.pointerDown(at: CGPoint(x: 80, y: 120))
        model.typed("a")
        model.typed("ab")
        model.typed("abc")
        model.undo()
        XCTAssertEqual(model.editing?.text, "ab")
        XCTAssertEqual(stored.map(\.text), ["ab"])
        model.undo()
        model.undo()
        XCTAssertEqual(model.editing?.text, "", "Undoing the first character leaves the box open and empty")
        XCTAssertTrue(stored.isEmpty)
        model.typed("x")
        XCTAssertEqual(stored.map(\.text), ["x"])
        model.redo()
        XCTAssertEqual(stored.map(\.text), ["x"], "Typing after Undo starts a new branch")
    }

    func testUndoRedoRestoresTextMoveAndStyleInOrder() throws {
        model.setTool(.text)
        model.pointerDown(at: CGPoint(x: 80, y: 120))
        model.typed("Draft")
        let typed = stored
        let box = try XCTUnwrap(typed.first)
        model.endEditing()

        var moved = box
        moved.frame.x += 40
        XCTAssertTrue(model.perform(.put([moved])).isSaved)
        XCTAssertEqual(stored, [moved])
        model.select([moved.id])
        model.styleSelection(colour: .red)
        let styled = stored
        XCTAssertEqual(styled.first?.style.colour, .red)

        model.undo()
        XCTAssertEqual(stored, [moved], "First Undo restores the previous colour")
        model.undo()
        XCTAssertEqual(stored, typed, "Second Undo restores the original position")
        model.undo()
        XCTAssertTrue(stored.isEmpty, "Third Undo removes the first typed content")

        model.redo()
        XCTAssertEqual(stored, typed)
        model.redo()
        XCTAssertEqual(stored, [moved])
        model.redo()
        XCTAssertEqual(stored, styled, "Redo restores text, position and style exactly")
    }

    func testSwatchStylesTheOpenTextBox() {
        model.setTool(.text)
        model.pointerDown(at: CGPoint(x: 80, y: 120))
        model.typed("Hello")
        model.clickSwatch()
        model.pickColour(.red)
        XCTAssertNotNil(model.editing, "The box stays open")
        XCTAssertEqual(model.editing?.style.colour, .red)
        XCTAssertEqual(stored.first?.style.colour, .red)
        let width = stored[0].frame.width
        model.clickTool(.text)
        model.pickSize(.large, for: .text)
        XCTAssertEqual(stored.first?.style.size, .large)
        XCTAssertGreaterThan(stored[0].frame.width, width, "A larger size measures wider")
    }

    // MARK: "+"

    func testPlusStartsANewEmptyCanvasThatStaysADraft() throws {
        stroke()
        let first = model.canvasID
        model.newCanvas()
        XCTAssertNotEqual(model.canvasID, first)
        XCTAssertTrue(model.objects.isEmpty)
        XCTAssertEqual(model.tool, .pen)
        XCTAssertEqual(try store.library().map(\.id), [first!], "Nothing is saved until the first content")
    }

    func testRevealOpensTheCanvasAndSelectsTheTextBox() throws {
        model.setTool(.text)
        model.pointerDown(at: CGPoint(x: 900, y: 900))
        model.typed("Far away")
        model.endEditing()
        let canvas = model.canvasID!
        let box = stored[0].id
        model.newCanvas()
        model.reveal(canvasID: canvas, objectID: box)
        XCTAssertEqual(model.canvasID, canvas)
        XCTAssertEqual(model.selection, [box])
        XCTAssertTrue(model.clearRect.intersects(model.viewport.screen(DrawGeometry.bounds(stored[0]))))
    }

    // MARK: D4 and the library seam

    func testCapsuleFilterReturnOpensTheFirstMatch() throws {
        model.newCanvas(name: "Alpha")
        stroke()
        let alpha = try XCTUnwrap(model.canvasID)
        model.newCanvas(name: "Beta")
        stroke()
        let beta = try XCTUnwrap(model.canvasID)
        model.open(alpha)
        model.openFilter()
        XCTAssertTrue(model.isFiltering)
        model.library.filter = "Bet"
        model.library.openFirstMatch()
        XCTAssertEqual(model.canvasID, beta)
        XCTAssertFalse(model.isFiltering, "Choosing closes the capsule's filter")
        XCTAssertEqual(model.library.filter, "")
        XCTAssertEqual(model.library.currentCanvasID, beta)
    }

    func testEscapeAndAPressOnTheBoardCloseTheFilter() {
        model.openFilter()
        model.library.filter = "zz"
        XCTAssertTrue(model.escape())
        XCTAssertFalse(model.isFiltering)
        XCTAssertEqual(model.library.filter, "")
        model.openFilter()
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(model.isFiltering)
        XCTAssertNil(model.live, "The press only closes the menu")
    }

    func testSearchRevealsTheMatchingTextBox() throws {
        model.setTool(.text)
        model.pointerDown(at: CGPoint(x: 80, y: 120))
        model.typed("Needle")
        model.endEditing()
        let canvas = try XCTUnwrap(model.canvasID)
        model.newCanvas()
        model.openSearch()
        model.search.query = "Needle"
        model.search.openHighlighted()
        XCTAssertEqual(model.canvasID, canvas)
        XCTAssertEqual(model.selection.count, 1)
        model.closeSearch()
        XCTAssertEqual(model.search.query, "")
    }

    func testOpeningSharedSearchEndsTheCurrentTextEditAndFindsItsSavedText() throws {
        model.setTool(.text)
        model.pointerDown(at: CGPoint(x: 80, y: 120))
        model.typed("Find this draft")
        XCTAssertNotNil(model.editing)

        model.openSearch()
        XCTAssertNil(model.editing, "Opening the top Search finishes the active text box")
        model.search.query = "draft"
        let result = try XCTUnwrap(model.search.results.first)
        XCTAssertEqual(result.canvas.id, model.canvasID)
        XCTAssertEqual(result.textBoxIDs, stored.map(\.id))
    }

    // Red-first Draw integration audit, 11 Nov. These intentionally assert the intended safety contract.
    func testDA1SecondaryPanDuringInkMustKeepTheUnfinishedStroke() throws {
        let id = try XCTUnwrap(model.canvasID)
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 60, y: 100))
        model.pointerDragged(to: CGPoint(x: 90, y: 120))
        // The middle button can be pressed before the pen's mouse-up.
        model.pointerDown(at: CGPoint(x: 90, y: 120), panButton: true)
        model.pointerDragged(to: CGPoint(x: 110, y: 130))
        model.pointerUp()
        XCTAssertEqual(try store.open(id).objects.filter { if case .stroke = $0.content { true } else { false } }.count,
                       1, "The secondary pan must not discard ink that was already drawn")
    }

    func testDA1SecondaryPanSettlesShapeAndEraseAndWaitsForItsOwnButtonUp() throws {
        let id = try XCTUnwrap(model.canvasID)
        model.setTool(.shape)
        model.pointerDown(at: CGPoint(x: 70, y: 170))
        model.pointerDragged(to: CGPoint(x: 125, y: 215))
        model.pointerDown(at: CGPoint(x: 140, y: 230), panButton: true)
        XCTAssertEqual(try store.open(id).objects.filter { if case .shape = $0.content { true } else { false } }.count, 1)
        guard case .pan = model.live else { return XCTFail("Secondary pan must own the pointer") }
        model.pointerUp(panButton: false)
        XCTAssertNotNil(model.live, "The first button release must not end the second button's pan")
        let startViewport = model.viewport
        model.pointerDragged(to: CGPoint(x: 160, y: 250), panButton: false)
        XCTAssertEqual(model.viewport, startViewport, "Primary drag must not move a middle-button pan")
        model.pointerDragged(to: CGPoint(x: 160, y: 250), panButton: true)
        XCTAssertNotEqual(model.viewport, startViewport)
        model.pointerUp(panButton: true)
        XCTAssertNil(model.live)

        model.setViewport(DrawViewport(), byUser: true)
        let samples = [DrawPoint(x: 80, y: 320), DrawPoint(x: 140, y: 320)]
        let stroke = DrawObject(frame: DrawGeometry.strokeFrame(samples), content: .stroke(samples))
        XCTAssertTrue(model.perform(.put([stroke])).isSaved)
        model.setTool(.eraser)
        model.pointerDown(at: CGPoint(x: 95, y: 320))
        model.pointerDragged(to: CGPoint(x: 120, y: 320))
        model.pointerDown(at: CGPoint(x: 150, y: 330), panButton: true)
        XCTAssertFalse(try store.open(id).objects.contains(where: { $0.id == stroke.id }),
                       "The interrupted eraser must save the removal")
        model.pointerUp(panButton: false)
        XCTAssertNotNil(model.live)
        model.pointerUp(panButton: true)
        XCTAssertNil(model.live)
    }

    func testDA2ExternalAgentDeleteDuringInkMustNotLeaveAResurrectableStaleObject() throws {
        let id = try XCTUnwrap(model.canvasID)
        let target = DrawObject(frame: DrawFrame(x: 40, y: 60, width: 60, height: 20),
                                content: .text("Agent deletes me"))
        XCTAssertTrue(model.perform(.put([target])).isSaved)
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 180, y: 150))
        model.pointerDragged(to: CGPoint(x: 210, y: 170))
        // Store writes are immediate; the page's observation callback is queued asynchronously.
        XCTAssertTrue(store.perform(.remove([target.id]), on: id).isSaved)
        model.pointerUp(at: CGPoint(x: 230, y: 180))
        XCTAssertFalse(model.objects.contains(where: { $0.id == target.id }),
                       "The model must incorporate an external delete before the owner uses stale content")
        // Follow-up owner action must not silently revive the deleted text box.
        model.setTool(.select)
        model.select([target.id])
        let stale = model.selectedObjects.map { $0.translated(by: DrawPoint(x: 10, y: 10), id: $0.id) }
        if !stale.isEmpty { XCTAssertTrue(model.perform(.put(stale)).isSaved) }
        XCTAssertFalse(try store.open(id).objects.contains(where: { $0.id == target.id }),
                       "An agent-deleted box must remain deleted after the owner moves a selection")
    }

    func testDA2ExternalRestyleAndMoveDuringOwnerMovePreservesBothChanges() throws {
        let id = try XCTUnwrap(model.canvasID)
        let box = DrawObject(frame: DrawFrame(x: 70, y: 150, width: 80, height: 30), content: .text("Shared"))
        XCTAssertTrue(model.perform(.put([box])).isSaved)
        model.setTool(.select)
        model.select([box.id])
        model.pointerDown(at: CGPoint(x: 90, y: 165))
        model.pointerDragged(to: CGPoint(x: 105, y: 175))
        var agent = box
        agent.frame.x += 80
        agent.style.colour = .red
        XCTAssertTrue(store.perform(.put([agent]), on: id).isSaved)
        model.pointerUp()
        let saved = try XCTUnwrap(store.open(id).objects.first { $0.id == box.id })
        XCTAssertEqual(saved.frame.x, agent.frame.x + 15, accuracy: 0.01)
        XCTAssertEqual(saved.frame.y, agent.frame.y + 10, accuracy: 0.01)
        XCTAssertEqual(saved.style.colour, .red, "The gesture must keep the agent's restyle")
    }

    func testDA2ExternalRestyleDuringSelectionResizeSurvivesCommit() throws {
        let id = try XCTUnwrap(model.canvasID)
        let shape = DrawObject(frame: DrawFrame(x: 70, y: 150, width: 60, height: 45), content: .shape(.rectangle))
        XCTAssertTrue(model.perform(.put([shape])).isSaved)
        model.setTool(.select)
        model.select([shape.id])
        let corner = try XCTUnwrap(model.handleSpots.first { $0.handle == .bottomRight })
        model.pointerDown(at: corner.point)
        model.pointerDragged(to: CGPoint(x: corner.point.x + 20, y: corner.point.y + 15))
        var agent = shape
        agent.style.colour = .red
        XCTAssertTrue(store.perform(.put([agent]), on: id).isSaved)
        model.pointerUp()
        let saved = try XCTUnwrap(store.open(id).objects.first { $0.id == shape.id })
        XCTAssertEqual(saved.style.colour, .red)
        XCTAssertEqual(saved.frame.width, shape.frame.width + 20, accuracy: 0.01)
        XCTAssertEqual(saved.frame.height, shape.frame.height + 15, accuracy: 0.01)
    }

    func testDA3AgentMoveOfLiveTextBoxMustSurviveTheOwnersNextKeystroke() throws {
        let id = try XCTUnwrap(model.canvasID)
        model.setTool(.text)
        model.beginText(at: CGPoint(x: 80, y: 140))
        model.typed("Before")
        model.endEditing()
        let original = try XCTUnwrap(store.open(id).objects.first)
        model.edit(original.id)
        var moved = original
        moved.frame.x += 90
        moved.frame.y += 40
        XCTAssertTrue(store.perform(.put([moved]), on: id).isSaved)
        model.syncExternalChanges()
        XCTAssertEqual(model.object(original.id)?.frame.x, moved.frame.x, "The external move reaches the board")
        model.typed("Before!")
        let after = try XCTUnwrap(store.open(id).objects.first)
        XCTAssertEqual(after.frame.x, moved.frame.x, "Typing must retain the agent's new text position")
        XCTAssertEqual(after.frame.y, moved.frame.y, "Typing must retain the agent's new text position")
    }

    func testDA3TypingBeforeStoreObservationRebasesWidthScaleAndRestyle() throws {
        let id = try XCTUnwrap(model.canvasID)
        model.beginText(at: CGPoint(x: 80, y: 140))
        model.typed("Before")
        model.endEditing()
        let original = try XCTUnwrap(store.open(id).objects.first)
        model.edit(original.id)
        var changed = original
        changed.frame.x += 40
        changed.frame.y += 30
        changed.textWidth = 115
        changed.textScale = 1.4
        changed.style.colour = .red
        DrawPageModel.measure(&changed, text: changed.text)
        XCTAssertTrue(store.perform(.put([changed]), on: id).isSaved)
        // Deliberately do not call syncExternalChanges: typing is faster than the observer.
        model.typed("Before!")
        let edit = try XCTUnwrap(model.editing)
        XCTAssertEqual(edit.origin.x, changed.frame.x)
        XCTAssertEqual(edit.origin.y, changed.frame.y)
        XCTAssertEqual(edit.width, 115)
        XCTAssertEqual(edit.scale, 1.4, accuracy: 0.0001)
        let stored = try XCTUnwrap(store.open(id).objects.first)
        XCTAssertEqual(stored.frame.x, changed.frame.x)
        XCTAssertEqual(stored.frame.y, changed.frame.y)
        XCTAssertEqual(stored.textWidth, 115)
        XCTAssertEqual(stored.textScale ?? 1, 1.4, accuracy: 0.0001)
        XCTAssertEqual(stored.style.colour, .red)
        XCTAssertEqual(stored.text, "Before!")
    }

    func testDA3ExternalTextConflictEndsEditAndKeepsOwnerTextInUndoHistory() throws {
        let id = try XCTUnwrap(model.canvasID)
        model.beginText(at: CGPoint(x: 80, y: 140))
        model.typed("Owner typed text")
        model.endEditing()
        let original = try XCTUnwrap(store.open(id).objects.first)
        model.edit(original.id)
        var agent = original
        agent.content = .text("Agent's different text")
        XCTAssertTrue(store.perform(.put([agent]), on: id).isSaved)
        model.syncExternalChanges()
        XCTAssertNil(model.editing, "A conflicting live edit must close")
        model.typed("Stale editor write")
        XCTAssertEqual(try store.open(id).objects.first?.text, "Agent's different text")
        XCTAssertTrue(store.undo(on: id).isSaved)
        XCTAssertEqual(try store.open(id).objects.first?.text, "Owner typed text",
                       "Previously committed owner typing remains recoverable")
    }

    func testDA3ExternalDeleteOfEditedBoxCannotBeUndoneByTyping() throws {
        let id = try XCTUnwrap(model.canvasID)
        model.beginText(at: CGPoint(x: 80, y: 140))
        model.typed("Owner's saved sentence")
        model.endEditing()
        let original = try XCTUnwrap(store.open(id).objects.first)
        model.edit(original.id)
        XCTAssertTrue(store.perform(.remove([original.id]), on: id).isSaved)
        model.typed("Owner's saved sentence!")
        XCTAssertNil(model.editing)
        XCTAssertFalse(try store.open(id).objects.contains(where: { $0.id == original.id }))
        XCTAssertTrue(store.undo(on: id).isSaved)
        XCTAssertEqual(try store.open(id).objects.first?.text, "Owner's saved sentence")
    }

    func testHunt16AgentDeletesCurrentCanvasDuringInkNeverTransfersStrokeToAnotherCanvas() throws {
        let erased = try XCTUnwrap(model.canvasID)
        let survivor = store.create(name: "Surviving board")
        let kept = DrawObject(frame: DrawFrame(x: 60, y: 130, width: 65, height: 45),
                              content: .shape(.rectangle))
        XCTAssertTrue(store.perform(.put([kept]), on: survivor.id).isSaved)

        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 100, y: 200))
        model.pointerDragged(to: CGPoint(x: 140, y: 225))
        // The agent removes the entire canvas while the gesture is in flight.
        XCTAssertTrue(store.performAgent(.deleteCanvas, on: erased).isSaved)
        model.pointerUp(at: CGPoint(x: 170, y: 240))

        XCTAssertEqual(model.canvasID, survivor.id)
        XCTAssertEqual(try store.open(survivor.id).objects, [kept],
                       "A stroke begun on a deleted board must never be saved to an unrelated board")
        XCTAssertNil(model.live)
        XCTAssertFalse(model.isDrawingLive)
    }

    func testHunt16AgentDeletesCanvasBeforePasteNeverPastesIntoReplacement() throws {
        let originalID = try XCTUnwrap(model.canvasID)
        let copied = DrawObject(frame: DrawFrame(x: 75, y: 100, width: 55, height: 35),
                                content: .shape(.rectangle))
        XCTAssertTrue(model.perform(.put([copied])).isSaved)
        model.setTool(.select)
        model.select([copied.id])
        model.copySelection()

        let surviving = store.create(name: "Another board")
        let kept = DrawObject(frame: DrawFrame(x: 190, y: 190, width: 45, height: 42),
                              content: .shape(.ellipse))
        XCTAssertTrue(store.perform(.put([kept]), on: surviving.id).isSaved)
        XCTAssertTrue(store.performAgent(.deleteCanvas, on: originalID).isSaved)
        model.paste() // Old board disappears when the pending agent change is reconciled.

        XCTAssertEqual(model.canvasID, surviving.id)
        XCTAssertEqual(try store.open(surviving.id).objects, [kept],
                       "Paste begun on a removed canvas must not insert content into its replacement")
    }

    func testHunt16AgentAddBeforeOwnerPasteDoesNotJoinPastedSelection() throws {
        let id = try XCTUnwrap(model.canvasID)
        let copied = DrawObject(frame: DrawFrame(x: 65, y: 90, width: 55, height: 35),
                                content: .shape(.rectangle))
        XCTAssertTrue(model.perform(.put([copied])).isSaved)
        model.setTool(.select)
        model.select([copied.id])
        model.copySelection()

        // The agent saves a new unrelated object before the asynchronous
        // observation callback has refreshed the owner's canvas.
        let agent = DrawObject(frame: DrawFrame(x: 160, y: 180, width: 50, height: 32),
                               zIndex: 1, content: .shape(.ellipse))
        XCTAssertTrue(store.performAgent(.put([agent]), on: id).isSaved)
        model.paste()

        let saved = try store.open(id).objects
        let pasted = try XCTUnwrap(saved.first { $0.id != copied.id && $0.id != agent.id })
        XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(model.selection, [pasted.id],
                       "Paste must never select an unrelated object the agent just added")
        model.deleteSelection()
        XCTAssertTrue(try store.open(id).objects.contains { $0.id == agent.id },
                      "Deleting the pasted object must leave the agent's independent object intact")
    }

}
