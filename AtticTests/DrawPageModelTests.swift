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
}
