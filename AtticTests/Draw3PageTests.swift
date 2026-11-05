import AppKit
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Attic

/// Test images, encoded the way a file on disk would be.
enum Draw3Images {
    static func encoded(width: Int, height: Int, type: UTType = .png, dpi: Double? = nil,
                        red: CGFloat = 0.9, green: CGFloat = 0.2, blue: CGFloat = 0.1) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The pixel at (x, y) from the top-left, as 0–255 RGBA.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return bytes.map(Int.init)
    }
}

/// Draw job 3, the page: images, resize handles, thumbnails, Export… and
/// Copy as Image, the save notice and quit (Planning.md, Accepted
/// "2026-10-31 · Draw: the canvas page").
@MainActor
final class Draw3PageTests: XCTestCase {
    private var store: DrawStore!
    private var model: DrawPageModel!
    private var folder: URL!

    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        AtticDraw.enabledOverride = true
        folder = ownedTemporaryDirectory(prefix: "Draw3Page")
        DrawImageActions.darkOverride = false
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        use(DrawInMemoryStore())
    }

    override func tearDown() {
        model?.pasteboard.releaseGlobally()
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        AtticDraw.enabledOverride = nil
        DrawImageActions.darkOverride = nil
        DrawPageModel.importLoadHook = nil
        super.tearDown()
    }

    private func use(_ next: DrawStore) {
        model?.pasteboard.releaseGlobally()
        store = next
        model = DrawPageModel(store: next)
        model.pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-draw3-\(UUID().uuidString)"))
        model.setBoard(size: CGSize(width: 320, height: 460),
                       clearInsets: NSEdgeInsets(top: 48.5, left: 15.5, bottom: 48.5, right: 15.5))
        model.start()
    }

    private func persistentStore(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> DrawPersistentStore {
        DrawPersistentStore(container: try ModelContainer(for: Schema(PersistenceController.appModelTypes),
                                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)),
                            save: save)
    }

    private var stored: [DrawObject] { (try? store.open(model.canvasID!).objects) ?? [] }

    private func drag(_ points: [CGPoint], shift: Bool = false) {
        model.pointerDown(at: points[0], shift: shift)
        for point in points.dropFirst() { model.pointerDragged(to: point, shift: shift) }
        model.pointerUp()
    }

    private func put(_ object: DrawObject) {
        XCTAssertTrue(model.perform(.put([object])).isSaved)
    }

    private func spot(_ handle: DrawHandle, file: StaticString = #filePath, line: UInt = #line) -> CGPoint {
        guard let spot = model.handleSpots.first(where: { $0.handle == handle }) else {
            XCTFail("No \(handle) handle", file: file, line: line)
            return .zero
        }
        return spot.point
    }

    private func imageObject(_ data: Data, width: Int, height: Int, type: String = "public.png",
                             frame: DrawFrame = DrawFrame(x: 40, y: 80, width: 100, height: 50)) -> DrawObject {
        DrawObject(frame: frame, zIndex: model.topZ + 1,
                   content: .image(DrawImage(original: data, pixelWidth: width, pixelHeight: height, contentType: type)))
    }

    private func wait(_ timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    // MARK: Images on the board

    func testDroppingAnImageFilePlacesItAtTheDropPointFittedOneUndoStep() async throws {
        let data = Draw3Images.encoded(width: 1200, height: 600)
        let file = folder.appendingPathComponent("wide.png")
        try data.write(to: file)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-draw3-drop-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let drop = CGPoint(x: 160, y: 220)
        let task = try XCTUnwrap(model.importImages(from: pasteboard, at: drop))
        await task.value

        XCTAssertEqual(model.objects.count, 1)
        let object = try XCTUnwrap(model.objects.first)
        guard case .image(let image) = object.content else { return XCTFail("Not an image") }
        XCTAssertEqual(image.original, data, "The store keeps the exact original bytes")
        XCTAssertEqual(image.pixelWidth, 1200)
        XCTAssertEqual(image.pixelHeight, 600)
        XCTAssertEqual(image.contentType, UTType.png.identifier)
        XCTAssertEqual(object.frame.width / object.frame.height, 2, accuracy: 0.001, "The aspect ratio is kept")
        XCTAssertLessThan(object.frame.width, model.clearRect.width, "Scaled down to fit the view")
        let centre = model.viewport.world(drop)
        XCTAssertEqual(object.frame.x + object.frame.width / 2, centre.x, accuracy: 0.5)
        XCTAssertEqual(object.frame.y + object.frame.height / 2, centre.y, accuracy: 0.5)
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertTrue(model.objects.isEmpty)
        XCTAssertFalse(model.canUndo, "Placing an image is one Undo step")
    }

    func testCommandVPastesImageDataAtTheViewCentreAtNaturalSize() async throws {
        let data = Draw3Images.encoded(width: 120, height: 80, type: .jpeg, dpi: 144)
        model.pasteboard.clearContents()
        model.pasteboard.setData(data, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        XCTAssertTrue(model.pasteboardHasImage)
        XCTAssertTrue(model.isEnabled(.paste))
        XCTAssertTrue(model.handleKey(DrawKey(characters: "v", command: true)))
        await model.pendingImport?.value

        let object = try XCTUnwrap(model.objects.first)
        guard case .image(let image) = object.content else { return XCTFail("Not an image") }
        XCTAssertEqual(image.original, data)
        XCTAssertEqual(image.contentType, UTType.jpeg.identifier)
        XCTAssertEqual(object.frame.width, 60, accuracy: 0.01, "Natural size: 120 px at 144 dpi is 60 pt")
        XCTAssertEqual(object.frame.height, 40, accuracy: 0.01)
        let centre = model.viewport.world(CGPoint(x: model.clearRect.midX, y: model.clearRect.midY))
        XCTAssertEqual(object.frame.x + 30, centre.x, accuracy: 0.5)
        XCTAssertEqual(object.frame.y + 20, centre.y, accuracy: 0.5)
    }

    private func imageFile(_ name: String, width: Int = 60, height: Int = 40) throws -> (URL, Data) {
        let data = Draw3Images.encoded(width: width, height: height)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file)
        return (file, data)
    }

    private func filePasteboard(_ file: URL) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-draw3-file-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        return pasteboard
    }

    func testAnImportThatFinishesAfterASwitchLandsOnTheCanvasItWasDroppedOn() async throws {
        let (file, data) = try imageFile("late.png")
        let origin = try XCTUnwrap(model.canvasID)
        let drop = CGPoint(x: 160, y: 220)
        let centre = model.viewport.world(drop)
        let task = try XCTUnwrap(model.importImages(from: filePasteboard(file), at: drop))
        model.newCanvas()
        let other = try XCTUnwrap(model.canvasID)
        XCTAssertNotEqual(other, origin)
        await task.value
        XCTAssertTrue(model.objects.isEmpty, "The canvas now open is left alone")
        let landed = try store.open(origin).objects
        XCTAssertEqual(landed.count, 1, "The drop is never lost")
        guard case .image(let image) = landed.first?.content else { return XCTFail("Not an image") }
        XCTAssertEqual(image.original, data)
        let frame = try XCTUnwrap(landed.first?.frame)
        XCTAssertEqual(frame.x + frame.width / 2, centre.x, accuracy: 0.5, "Where it was dropped")
        XCTAssertEqual(frame.y + frame.height / 2, centre.y, accuracy: 0.5)
        XCTAssertNil(model.saveNotice)
        model.open(origin)
        XCTAssertEqual(model.objects.map(\.id), landed.map(\.id))
        XCTAssertTrue(model.canUndo, "Its Undo step belongs to that canvas")
        model.undo()
        XCTAssertTrue(model.objects.isEmpty)
    }

    func testQuitWaitsForEveryImportInFlight() async throws {
        let (slow, _) = try imageFile("slow.png"), (fast, _) = try imageFile("fast.png", width: 30, height: 30)
        DrawPageModel.importLoadHook = { names in
            if names == ["slow.png"] { try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        XCTAssertNotNil(model.importImages(from: filePasteboard(slow), at: nil))
        XCTAssertNotNil(model.importImages(from: filePasteboard(fast), at: nil))
        let ready = await model.prepareToQuit()
        XCTAssertTrue(ready)
        XCTAssertEqual(stored.filter(\.isImage).count, 2, "Quit waited for both imports, not only the latest")
    }

    func testQuitReturnsPromptlyWhileAnImportIsStillOwnedAndCanFinish() async throws {
        let id = try XCTUnwrap(model.canvasID)
        let token = UUID()
        let (stream, release) = AsyncStream<Void>.makeStream()
        let importTask = Task { @MainActor in
            for await _ in stream {}
            _ = store.perform(.put([DrawObject(content: .text("Completed import"))]), on: id)
            model.importFinished(token)
        }
        model.importStarted(token, importTask)

        let began = ContinuousClock.now
        let ready = await model.prepareToQuit()
        XCTAssertFalse(ready, "quit must be refused while the import remains in flight")
        XCTAssertLessThan(began.duration(to: .now), .seconds(2), "a stuck import must not hold up the quit reply")
        XCTAssertNotNil(model.saveNotice, "existing notice shows that the import is still running")
        XCTAssertTrue(model.saveNotice?.isInformational == true, "A running import is not a save failure")

        model.dismissSaveError()
        XCTAssertNil(model.saveNotice, "Dismiss must clear the import notice without cancelling the import")

        release.finish()
        await importTask.value
        XCTAssertEqual(try store.open(id).objects.count, 1, "refusing quit kept the import alive to save")
        XCTAssertNil(model.saveNotice)
        let finished = await model.prepareToQuit()
        XCTAssertTrue(finished)
    }

    func testSlowRegenerableThumbnailDoesNotBlockQuitAfterContentIsSaved() async {
        model.thumbnailRenderer = { _, _ in
            try? await Task.sleep(for: .seconds(3))
            return nil
        }
        model.setTool(.pen)
        drag([CGPoint(x: 60, y: 100), CGPoint(x: 130, y: 140)])
        let began = ContinuousClock.now
        let ready = await model.prepareToQuit()
        XCTAssertTrue(ready)
        XCTAssertLessThan(began.duration(to: .now), .seconds(2))
        XCTAssertEqual(stored.count, 1, "the stroke was committed before the thumbnail")
    }

    func testDrawObjectsOnThePasteboardStillPasteAsObjects() async throws {
        put(DrawObject(frame: DrawFrame(x: 10, y: 10, width: 40, height: 40), content: .shape(.rectangle)))
        model.selectAll()
        model.copySelection()
        model.paste()
        XCTAssertEqual(model.objects.count, 2)
        XCTAssertFalse(model.objects.contains(where: \.isImage))
    }

    func testOriginalBytesRoundTripThroughTheDurableStore() async throws {
        let durable = try persistentStore()
        use(durable)
        let data = Draw3Images.encoded(width: 64, height: 32, type: .jpeg)
        model.pasteboard.clearContents()
        model.pasteboard.setData(data, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        model.paste()
        await model.pendingImport?.value
        let reopened = DrawPersistentStore(container: durable.container)
        let object = try XCTUnwrap(reopened.open(model.canvasID!).objects.first)
        XCTAssertEqual(object.content, .image(DrawImage(original: data, pixelWidth: 64, pixelHeight: 32,
                                                        contentType: UTType.jpeg.identifier)))
    }

    func testSaveImageWritesTheOriginalBytesNamedAfterTheCanvas() async throws {
        let data = Draw3Images.encoded(width: 40, height: 20, type: .jpeg)
        put(imageObject(data, width: 40, height: 20, type: UTType.jpeg.identifier))
        XCTAssertTrue(store.perform(.rename("Holiday"), on: model.canvasID!).isSaved)
        model.setTool(.select)
        model.select([model.objects[0].id])
        XCTAssertEqual(model.selectionActions, [.saveImage, .duplicate, .delete, .more])
        var asked: (name: String, types: [UTType])?
        let destination = folder.appendingPathComponent("Holiday.jpeg")
        model.images.chooseDestination = { name, types in
            asked = (name, types)
            return destination
        }
        model.saveSelectedImage()
        await model.images.lastTask?.value
        XCTAssertEqual(asked?.name, "Holiday.jpeg")
        XCTAssertEqual(asked?.types, [.jpeg])
        XCTAssertEqual(try Data(contentsOf: destination), data, "Byte for byte, in the original type")
    }

    func testDuplicateAndDeleteForOneImageAndItsWayThroughRecentlyDeleted() throws {
        let data = Draw3Images.encoded(width: 40, height: 20)
        put(imageObject(data, width: 40, height: 20))
        let original = model.objects[0]
        model.setTool(.select)
        model.select([original.id])
        model.duplicateSelection()
        XCTAssertEqual(model.objects.count, 2)
        let copy = try XCTUnwrap(model.objects.first { $0.id != original.id })
        XCTAssertEqual(copy.content, original.content)
        model.undo()
        XCTAssertEqual(model.objects.map(\.id), [original.id], "Duplicate is one Undo step")

        model.select([original.id])
        model.deleteSelection()
        XCTAssertTrue(model.objects.isEmpty)
        let entries = DrawRecentlyDeleted.entries(store: store, now: Date(), calendar: .current)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        guard case .draw(let item) = entry.source else { return XCTFail("Not a Draw row") }
        XCTAssertEqual(item.objectID, original.id)
        XCTAssertNil(DrawRecentlyDeleted.restore([item], store: store).failure)
        XCTAssertTrue(wait { model.objects.map(\.id) == [original.id] }, "The restored image is back on the board")
        XCTAssertEqual(model.objects.first?.content, original.content)
    }

    // MARK: Resize handles

    func testShapeCornerResizesFreelyAndShiftKeepsProportions() {
        put(DrawObject(frame: DrawFrame(x: 100, y: 100, width: 80, height: 40), content: .shape(.rectangle)))
        model.setTool(.select)
        model.select([model.objects[0].id])
        let corner = spot(.bottomRight)
        drag([corner, CGPoint(x: corner.x + 10, y: corner.y + 20), CGPoint(x: corner.x + 20, y: corner.y + 40)])
        var frame = model.objects[0].frame
        XCTAssertEqual(frame.x, 100, accuracy: 0.01)
        XCTAssertEqual(frame.width, 100, accuracy: 0.01)
        XCTAssertEqual(frame.height, 80, accuracy: 0.01)
        let next = spot(.bottomRight)
        drag([next, CGPoint(x: next.x + 40, y: next.y)], shift: true)
        frame = model.objects[0].frame
        XCTAssertEqual(frame.width / frame.height, 100.0 / 80.0, accuracy: 0.001, "Shift keeps proportions")
        XCTAssertEqual(frame.width, 140, accuracy: 0.01)
    }

    func testImagesAlwaysKeepTheirAspectRatio() {
        put(imageObject(Draw3Images.encoded(width: 40, height: 20), width: 40, height: 20,
                        frame: DrawFrame(x: 50, y: 60, width: 200, height: 100)))
        model.setTool(.select)
        model.select([model.objects[0].id])
        let corner = spot(.topLeft)
        drag([corner, CGPoint(x: corner.x - 50, y: corner.y + 5)])
        let frame = model.objects[0].frame
        XCTAssertEqual(frame.width / frame.height, 2, accuracy: 0.001)
        XCTAssertEqual(frame.width, 250, accuracy: 0.01)
        XCTAssertEqual(frame.x + frame.width, 250, accuracy: 0.01, "The opposite corner stays put")
        XCTAssertEqual(frame.y + frame.height, 160, accuracy: 0.01)
    }

    func testTextBoxSidesChangeItsWidthAndTheTextReflows() {
        model.setTool(.text)
        model.pointerDown(at: CGPoint(x: 40, y: 120))
        model.typed("one two three four five six seven")
        model.endEditing()
        let box = model.objects[0]
        model.setTool(.select)
        model.select([box.id])
        XCTAssertEqual(Set(model.handleSpots.map(\.handle)), [.left, .right])
        let right = spot(.right)
        drag([right, CGPoint(x: right.x - box.frame.width / 2, y: right.y)])
        let narrow = model.objects[0]
        XCTAssertEqual(narrow.textWidth ?? 0, box.frame.width / 2, accuracy: 1)
        XCTAssertEqual(narrow.frame.width, narrow.textWidth ?? 0, accuracy: 0.01)
        XCTAssertGreaterThan(narrow.frame.height, box.frame.height, "The text wraps onto more lines")
        XCTAssertEqual(narrow.frame.x, box.frame.x, accuracy: 0.01)
    }

    func testStrokesScaleAndLinesMoveTheDraggedEnd() {
        put(DrawObject(frame: DrawGeometry.strokeFrame([DrawPoint(x: 100, y: 100), DrawPoint(x: 200, y: 150)]),
                       content: .stroke([DrawPoint(x: 100, y: 100), DrawPoint(x: 150, y: 140), DrawPoint(x: 200, y: 150)])))
        model.setTool(.select)
        model.select([model.objects[0].id])
        let corner = spot(.bottomRight)
        drag([corner, CGPoint(x: corner.x + 100, y: corner.y + 50)])
        guard case .stroke(let points) = model.objects[0].content else { return XCTFail("Not a stroke") }
        XCTAssertEqual(points.first?.x ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(points.last?.x ?? 0, 300, accuracy: 1.5)
        XCTAssertEqual(points.last?.y ?? 0, 200, accuracy: 1.5)

        model.select([])
        put(DrawObject(frame: DrawGeometry.lineFrame(from: CGPoint(x: 20, y: 300), to: CGPoint(x: 120, y: 300)),
                       zIndex: model.topZ + 1, content: .shape(.arrow)))
        let arrow = model.objects.last!
        model.select([arrow.id])
        let end = spot(.end)
        drag([end, CGPoint(x: end.x + 30, y: end.y + 40)])
        let (a, b) = DrawGeometry.endpoints(model.object(arrow.id)!.frame)
        XCTAssertEqual(a, CGPoint(x: 20, y: 300))
        XCTAssertEqual(b.x, 150, accuracy: 0.01)
        XCTAssertEqual(b.y, 340, accuracy: 0.01)
    }

    func testSeveralObjectsScaleAsAGroupInOneUndoStepAndOneSave() throws {
        let durable = try persistentStore()
        use(durable)
        let left = DrawObject(frame: DrawFrame(x: 100, y: 100, width: 40, height: 40), zIndex: 1, content: .shape(.rectangle))
        let right = DrawObject(frame: DrawFrame(x: 160, y: 120, width: 40, height: 20), zIndex: 2, content: .shape(.ellipse))
        XCTAssertTrue(model.perform(.put([left, right])).isSaved)
        model.setTool(.select)
        model.selectAll()
        XCTAssertEqual(Set(model.handleSpots.map(\.handle)), [.topLeft, .topRight, .bottomLeft, .bottomRight])
        durable.metrics.reset()
        let revision = durable.revision
        let corner = spot(.bottomRight)
        var path = [corner]
        for step in 1...12 { path.append(CGPoint(x: corner.x + CGFloat(step) * 5, y: corner.y + CGFloat(step) * 5)) }
        drag(path)
        XCTAssertEqual(durable.metrics.saveAttempts, 1, "One save per drag, at the end")
        XCTAssertEqual(durable.revision, revision + 1)
        let scaledLeft = try XCTUnwrap(model.object(left.id)), scaledRight = try XCTUnwrap(model.object(right.id))
        XCTAssertEqual(scaledLeft.frame.x, 100, accuracy: 0.5, "The group scales from the opposite corner")
        XCTAssertGreaterThan(scaledLeft.frame.width, 40)
        XCTAssertGreaterThan(scaledRight.frame.x, 160)
        XCTAssertEqual(scaledRight.frame.width / scaledLeft.frame.width, 1, accuracy: 0.01)
        model.undo()
        XCTAssertEqual(model.object(left.id)?.frame, left.frame)
        XCTAssertEqual(model.object(right.id)?.frame, right.frame)
        model.undo()
        XCTAssertNil(model.object(left.id), "The drag was one Undo step: the next one takes back the placing")
        XCTAssertFalse(model.canUndo)
    }

    func testTextInAResizedGroupScalesWithItInOneSaveAndOneUndoStep() throws {
        let durable = try persistentStore()
        use(durable)
        var box = DrawObject(frame: DrawFrame(x: 100, y: 100), zIndex: 1, content: .text("one two three four five six"))
        box.textWidth = 60
        DrawPageModel.measure(&box, text: box.text)
        var free = DrawObject(frame: DrawFrame(x: 100, y: 240), zIndex: 2, content: .text("free width"))
        DrawPageModel.measure(&free, text: free.text)
        let shape = DrawObject(frame: DrawFrame(x: 100, y: 200, width: 80, height: 30), zIndex: 3, content: .shape(.rectangle))
        XCTAssertTrue(model.perform(.put([box, free, shape])).isSaved)
        model.setTool(.select)
        model.selectAll()
        durable.metrics.reset()
        let corner = spot(.bottomRight)
        var path = [corner]
        for step in 1...10 { path.append(CGPoint(x: corner.x + CGFloat(step) * 10, y: corner.y + CGFloat(step) * 10)) }
        drag(path)
        XCTAssertEqual(durable.metrics.saveAttempts, 1, "One save per drag")
        let scaledShape = try XCTUnwrap(model.object(shape.id))
        let s = scaledShape.frame.width / shape.frame.width
        XCTAssertGreaterThan(s, 1.2)
        let text = try XCTUnwrap(model.object(box.id)), loose = try XCTUnwrap(model.object(free.id))
        XCTAssertEqual(text.frame.x, 100, accuracy: 0.5, "The group scales from the opposite corner")
        XCTAssertEqual(text.frame.width, box.frame.width * s, accuracy: 0.5, "The box grows with the group")
        XCTAssertEqual(text.frame.height, box.frame.height * s, accuracy: 0.5, "Same lines, larger: no reflow")
        XCTAssertEqual(text.textWidth ?? 0, 60 * s, accuracy: 0.5)
        XCTAssertEqual(loose.frame.width, free.frame.width * s, accuracy: 0.5)
        XCTAssertEqual(loose.frame.height, free.frame.height * s, accuracy: 0.5)
        XCTAssertEqual(loose.frame.y, 100 + (240 - 100) * s, accuracy: 0.5)
        model.undo()
        XCTAssertEqual(model.object(box.id), box, "One Undo step puts the text back")
        XCTAssertEqual(model.object(free.id), free)
        XCTAssertEqual(model.object(shape.id)?.frame, shape.frame)
    }

    func testHandlesTakePressesBeyondTheirSixPointsAndShowAResizeCursor() {
        put(DrawObject(frame: DrawFrame(x: 100, y: 100, width: 80, height: 40), content: .shape(.rectangle)))
        model.setTool(.select)
        model.select([model.objects[0].id])
        let corner = spot(.topRight)
        XCTAssertEqual(model.handleSpot(at: CGPoint(x: corner.x + 5, y: corner.y - 5))?.handle, .topRight)
        XCTAssertNil(model.handleSpot(at: CGPoint(x: corner.x + 12, y: corner.y - 12)))
        for handle in [DrawHandle.topLeft, .bottomRight, .left, .end] {
            XCTAssertNotEqual(DrawBoardView.cursor(for: handle), NSCursor.arrow)
        }
    }

    // MARK: Thumbnails

    func testThumbnailIsWrittenOnceEditsSettleWithoutUndoDateOrOrder() throws {
        let durable = try persistentStore()
        use(durable)
        model.thumbnailSettleDelay = 0.05
        model.setTool(.pen)
        drag([CGPoint(x: 60, y: 100), CGPoint(x: 90, y: 120), CGPoint(x: 130, y: 100)])
        let id = try XCTUnwrap(model.canvasID)
        let date = try XCTUnwrap(durable.library().first?.updatedAt)
        XCTAssertTrue(wait { (try? durable.library().first?.thumbnail) != nil }, "The thumbnail renders once edits settle")
        let thumbnail = try XCTUnwrap(durable.library().first?.thumbnail)
        let image = try XCTUnwrap(Draw3Images.cgImage(thumbnail))
        XCTAssertEqual(CGSize(width: image.width, height: image.height), DrawThumbnail.pixelSize)
        XCTAssertEqual(try durable.library().first?.updatedAt, date)
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertTrue(model.objects.isEmpty, "Undo undoes the stroke, not the thumbnail")
        XCTAssertFalse(durable.canUndo(on: id))
    }

    func testSwitchingCanvasesRendersThePreviousThumbnailAtOnce() throws {
        let durable = try persistentStore()
        use(durable)
        model.thumbnailSettleDelay = 600
        model.setTool(.pen)
        drag([CGPoint(x: 60, y: 100), CGPoint(x: 130, y: 140)])
        let first = try XCTUnwrap(model.canvasID)
        model.newCanvas()
        XCTAssertTrue(wait { (try? durable.library().first { $0.id == first }?.thumbnail) != nil })
        model.setTool(.pen)
        drag([CGPoint(x: 60, y: 100), CGPoint(x: 130, y: 140)])
        let second = try XCTUnwrap(model.canvasID)
        model.setShown(true)
        model.setShown(false)
        XCTAssertTrue(wait { (try? durable.library().first { $0.id == second }?.thumbnail) != nil },
                      "Closing the session renders its thumbnail")
        XCTAssertEqual(try durable.library().map(\.id), [second, first])
    }

    func testEmptyCanvasKeepsTheEmptyCard() throws {
        let durable = try persistentStore()
        use(durable)
        model.thumbnailSettleDelay = 0.01
        model.setTool(.pen)
        drag([CGPoint(x: 60, y: 100), CGPoint(x: 130, y: 140)])
        XCTAssertTrue(wait { (try? durable.library().first?.thumbnail) != nil })
        model.selectAll()
        model.deleteSelection()
        XCTAssertTrue(wait { (try? durable.library().first?.thumbnail) == nil }, "Nothing drawn: no thumbnail, the empty card")
    }

    func testALateRenderNeverBringsBackAThumbnailAfterTheLastObjectGoes() async throws {
        let durable = try persistentStore()
        use(durable)
        model.thumbnailSettleDelay = 600
        let gate = Draw3Gate()
        model.thumbnailRenderer = { _, _ in
            await gate.wait()
            return Data([7, 7, 7])
        }
        put(DrawObject(frame: DrawFrame(x: 20, y: 30, width: 100, height: 50), content: .shape(.rectangle)))
        model.flushThumbnail()
        model.selectAll()
        model.deleteSelection()
        model.flushThumbnail()
        XCTAssertNil(try durable.library().first?.thumbnail)
        gate.open()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(try durable.library().first?.thumbnail, "The card stays empty")
    }

    // MARK: Export… and Copy as Image

    func testPNGExportRejectsOversizedFiniteCanvasBeforeBitmapAllocation() {
        for width in [CGFloat(Int.max), 50_000, 20_000] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: width == 20_000 ? 20_000 : 100)
            XCTAssertNil(DrawExport.pngPixelSize(for: bounds))
        }
    }

    private func exportBoard() {
        put(DrawObject(frame: DrawFrame(x: 20, y: 30, width: 100, height: 50), content: .shape(.rectangle)))
        put(DrawObject(frame: DrawFrame(x: 200, y: 300, width: 60, height: 20), zIndex: 2, content: .shape(.ellipse)))
    }

    private var exportBounds: CGRect {
        DrawGeometry.union(model.objects)!.insetBy(dx: -DrawExport.margin, dy: -DrawExport.margin)
    }

    func testExportPNGCoversTheContentAtTwiceOnTheBoardColourWithoutDots() async throws {
        exportBoard()
        XCTAssertTrue(store.perform(.rename("Plan"), on: model.canvasID!).isSaved)
        var asked: (name: String, types: [UTType])?
        let destination = folder.appendingPathComponent("Plan.png")
        model.images.chooseDestination = { name, types in asked = (name, types); return destination }
        model.images.exportCanvas(model.canvasID!)
        await model.images.lastTask?.value
        XCTAssertEqual(asked?.name, "Plan")
        XCTAssertEqual(asked?.types, [.png, .pdf])
        let image = try XCTUnwrap(Draw3Images.cgImage(Data(contentsOf: destination)))
        XCTAssertEqual(image.width, Int((exportBounds.width * 2).rounded(.up)))
        XCTAssertEqual(image.height, Int((exportBounds.height * 2).rounded(.up)))
        // The margin and an empty stretch where the board's dots would be.
        for (x, y) in [(2, 2), (image.width - 3, 3), (image.width / 2, image.height / 2), (40, image.height - 40)] {
            XCTAssertEqual(Draw3Images.pixel(image, x: x, y: y), [255, 255, 255, 255], "Board colour at \(x), \(y)")
        }
    }

    func testExportPDFIsVectorWithImagesAtFullResolution() async throws {
        put(imageObject(Draw3Images.encoded(width: 400, height: 200), width: 400, height: 200,
                        frame: DrawFrame(x: 0, y: 0, width: 100, height: 50)))
        put(DrawObject(frame: DrawFrame(x: 120, y: 10, width: 40, height: 40), zIndex: 5, content: .shape(.rectangle)))
        let destination = folder.appendingPathComponent("Board.pdf")
        model.images.chooseDestination = { _, _ in destination }
        model.images.exportCanvas(model.canvasID!)
        await model.images.lastTask?.value
        let document = try XCTUnwrap(CGPDFDocument(destination as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, exportBounds.width, accuracy: 0.5)
        XCTAssertEqual(box.height, exportBounds.height, accuracy: 0.5)
        var widths: [Int] = []
        if let dictionary = page.dictionary {
            var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
               CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects {
                CGPDFDictionaryApplyBlock(objects, { _, value, _ in
                    var stream: CGPDFStreamRef?
                    if CGPDFObjectGetValue(value, .stream, &stream), let stream, let info = CGPDFStreamGetDictionary(stream) {
                        var width: CGPDFInteger = 0
                        if CGPDFDictionaryGetInteger(info, "Width", &width) { widths.append(width) }
                    }
                    return true
                }, nil)
            }
        }
        XCTAssertEqual(widths, [400], "One image, at its full 400 px; the shapes stay vectors")
    }

    func testCopyAsImageForTheCanvasTheSelectionAndOneImage() async throws {
        exportBoard()
        model.images.copyCanvas(model.canvasID!)
        await model.images.lastTask?.value
        let whole = try XCTUnwrap(model.pasteboard.data(forType: .png).flatMap(Draw3Images.cgImage))
        XCTAssertEqual(whole.width, Int((exportBounds.width * 2).rounded(.up)))

        model.setTool(.select)
        model.select([model.objects[0].id])
        XCTAssertTrue(model.isEnabled(.copyAsImage))
        model.runMore(.copyAsImage)
        await model.images.lastTask?.value
        let part = try XCTUnwrap(model.pasteboard.data(forType: .png).flatMap(Draw3Images.cgImage))
        let expected = DrawGeometry.bounds(model.objects[0]).insetBy(dx: -DrawExport.margin, dy: -DrawExport.margin)
        XCTAssertEqual(part.width, Int((expected.width * 2).rounded(.up)))

        let jpeg = Draw3Images.encoded(width: 30, height: 30, type: .jpeg)
        put(imageObject(jpeg, width: 30, height: 30, type: UTType.jpeg.identifier))
        model.select([model.objects.last!.id])
        model.runMore(.copyAsImage)
        await model.images.lastTask?.value
        XCTAssertEqual(model.pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)), jpeg,
                       "One image: the original data too")
        XCTAssertNotNil(model.pasteboard.data(forType: .png))
    }

    func testCopyAsImageForOneImageIsOneItemWithTheOriginalByteForByte() async throws {
        model.setTool(.select)
        for type in [UTType.png, .jpeg] {
            let original = Draw3Images.encoded(width: 30, height: 20, type: type, red: 0.1, green: 0.6, blue: 0.3)
            put(imageObject(original, width: 30, height: 20, type: type.identifier))
            let object = try XCTUnwrap(model.objects.last)
            model.select([object.id])
            model.runMore(.copyAsImage)
            await model.images.lastTask?.value
            let items = model.pasteboard.pasteboardItems ?? []
            XCTAssertEqual(items.count, 1, "\(type): one item, so a paste gives one picture")
            let item = try XCTUnwrap(items.first)
            XCTAssertEqual(item.data(forType: NSPasteboard.PasteboardType(type.identifier)), original,
                           "\(type): the original, byte for byte")
            // A PNG of the image itself (no board background), for apps that only read PNG.
            let png = try XCTUnwrap(item.data(forType: .png).flatMap(Draw3Images.cgImage), "\(type): a PNG too")
            XCTAssertEqual([png.width, png.height], [30, 20], "\(type): the image at its own pixels")
        }
    }

    func testAFailedExportOrSaveImageKeepsTheOldFileAndSaysSo() async throws {
        struct Injected: Error {}
        exportBoard()
        let destination = folder.appendingPathComponent("Board.png"), trashed = folder.appendingPathComponent("Trashed")
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        let old = Data("the old file".utf8)
        try old.write(to: destination)
        model.images.chooseDestination = { _, _ in destination }
        // A Trash the test can see.
        func testFiles() -> DrawFileWriter {
            var files = DrawFileWriter()
            files.trash = { url in try FileManager.default.moveItem(at: url, to: trashed.appendingPathComponent(UUID().uuidString)) }
            return files
        }
        func folderFiles() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != "Trashed" }
        }

        // Writing the new file fails: Export….
        model.images.files = testFiles()
        model.images.files.write = { _, _ in throw Injected() }
        model.images.exportCanvas(model.canvasID!)
        await model.images.lastTask?.value
        XCTAssertEqual(try? Data(contentsOf: destination), old, "The old file is untouched")
        let notice = try XCTUnwrap(model.saveNotice, "The failure shows")
        XCTAssertFalse(notice.canRetry)
        XCTAssertEqual(try folderFiles(), ["Board.png"], "Nothing staged is left behind")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trashed.path).isEmpty)
        model.dismissSaveError()
        XCTAssertNil(model.saveNotice)

        // Swapping it in fails: Save Image.
        put(imageObject(Draw3Images.encoded(width: 20, height: 20), width: 20, height: 20))
        model.images.files = testFiles()
        model.images.files.replace = { _, _, _ in throw Injected() }
        model.images.saveImage(model.objects.last!)
        await model.images.lastTask?.value
        XCTAssertEqual(try? Data(contentsOf: destination), old)
        XCTAssertNotNil(model.saveNotice)
        XCTAssertEqual(try folderFiles(), ["Board.png"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trashed.path).isEmpty)
        model.dismissSaveError()

        // A save that works replaces it; the old file goes to the Trash.
        model.images.files = testFiles()
        model.images.exportCanvas(model.canvasID!)
        await model.images.lastTask?.value
        XCTAssertNotNil(Draw3Images.cgImage(try Data(contentsOf: destination)), "The new PNG is in place")
        let binned = try FileManager.default.contentsOfDirectory(at: trashed, includingPropertiesForKeys: nil)
        XCTAssertEqual(try binned.map { try Data(contentsOf: $0) }, [old], "The old file is in the Trash, whole")
        XCTAssertEqual(try folderFiles(), ["Board.png"])
        XCTAssertNil(model.saveNotice)
    }

    func testExportAndCopyAsImageAreGreyedWhileTheCanvasIsEmpty() {
        func enabled(_ command: DrawLibraryMenuModel.Command) -> Bool? {
            model.library.rows.first { $0.kind == .command(command) }?.isEnabled
        }
        XCTAssertEqual(enabled(.export), false)
        XCTAssertEqual(enabled(.copyAsImage), false)
        exportBoard()
        XCTAssertEqual(enabled(.export), true)
        XCTAssertEqual(enabled(.copyAsImage), true)
    }

    // MARK: The canvas menu

    func testTheMenuListFitsThreeCanvasesWithoutScrolling() {
        for name in ["One", "Two", "Three"] {
            model.newCanvas(name: name)
            model.setTool(.pen)
            drag([CGPoint(x: 60, y: 100), CGPoint(x: 130, y: 140)])
        }
        let rows = model.library.rows
        XCTAssertEqual(rows.filter { $0.canvas != nil }.count, 3)
        let needed = DrawLibraryMetrics.listHeight(rows)
        XCTAssertGreaterThan(needed, DrawLibraryMetrics.maxListHeight, "The old default scrolls")
        let room = DrawPageMetrics.menuListRoom(boardHeight: PanelGeometry.minimumHeight, chromeTop: 15.5, chromeBottom: 15.5)
        XCTAssertLessThanOrEqual(needed, room, "At the panel's smallest height the list fits without scrolling")
    }

    func testDrawMenuRoomNeverExceedsShortAvailableHeight() {
        let available = DrawPageMetrics.menuListRoom(boardHeight: 110, chromeTop: 15.5, chromeBottom: 15.5)
        XCTAssertGreaterThan(available, 0)
        XCTAssertLessThan(available, DrawLibraryMetrics.maxListHeight,
                           "a short display must scroll rather than force the default menu height")
        XCTAssertEqual(DrawPageMetrics.menuListRoom(boardHeight: 0, chromeTop: 15.5, chromeBottom: 15.5), 0)
    }

    // MARK: Save problems

    func testARetrySaveShowsAndRetryWorks() throws {
        var fail = true
        let durable = try persistentStore(save: { context in
            if fail { throw NSError(domain: "Injected", code: 1) }
            try context.save()
        })
        use(durable)
        model.setTool(.pen)
        drag([CGPoint(x: 60, y: 100), CGPoint(x: 130, y: 140)])
        let notice = try XCTUnwrap(model.saveNotice)
        XCTAssertTrue(notice.canRetry)
        XCTAssertFalse(notice.message.isEmpty)
        fail = false
        model.retrySave()
        XCTAssertNil(model.saveNotice)
        XCTAssertFalse(durable.hasUnsettledEdits)
        XCTAssertEqual(try DrawPersistentStore(container: durable.container).open(model.canvasID!).objects.count, 1)
    }

    func testDrawingAgainAfterAFailedSaveKeepsBothStrokesAndRetrySavesThemInOrder() async throws {
        var fail = true
        let durable = try persistentStore(save: { context in
            if fail { throw NSError(domain: "Injected", code: 1) }
            try context.save()
        })
        use(durable)
        model.setTool(.pen)
        drag([CGPoint(x: 60, y: 100), CGPoint(x: 130, y: 140)])
        XCTAssertNotNil(model.saveNotice)
        drag([CGPoint(x: 60, y: 200), CGPoint(x: 130, y: 260)])
        XCTAssertEqual(model.objects.count, 2, "Input keeps working: the second stroke stays on the board")
        XCTAssertNotNil(model.saveNotice, "The notice stays until they are saved")
        let blocked = await model.prepareToQuit()
        XCTAssertFalse(blocked, "Quit waits for both")
        fail = false
        model.retrySave()
        XCTAssertNil(model.saveNotice)
        XCTAssertFalse(durable.hasUnsettledEdits)
        let saved = try DrawPersistentStore(container: durable.container).open(model.canvasID!).objects
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.map(\.id), model.objects.map(\.id), "Saved in drawing order")
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertEqual(model.objects.map(\.id), [saved[0].id], "Undo takes back the second stroke first")
    }

    func testAHeldSaveShowsAndRetryReconciles() throws {
        let repository = Draw3HeldRepository()
        use(DrawStore(repository: repository))
        model.setTool(.pen)
        drag([CGPoint(x: 60, y: 100), CGPoint(x: 130, y: 140)])
        let notice = try XCTUnwrap(model.saveNotice)
        XCTAssertTrue(notice.canRetry, "Held shows with the same Retry route")
        model.retrySave()
        XCTAssertNotNil(model.saveNotice, "Still held: the notice stays")
        repository.reconcileOutcome = .committed
        model.retrySave()
        XCTAssertNil(model.saveNotice)
        XCTAssertFalse(store.hasUnsettledEdits)
    }

    // MARK: Quit

    func testQuitFinishesTheStrokeInProgress() async {
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 60, y: 100))
        model.pointerDragged(to: CGPoint(x: 120, y: 140))
        let ready = await model.prepareToQuit()
        XCTAssertTrue(ready)
        XCTAssertEqual(stored.count, 1, "The stroke is saved before quit")
    }

    func testAHeldEditStopsQuitUntilItSettles() async {
        let repository = Draw3HeldRepository()
        use(DrawStore(repository: repository))
        model.setTool(.pen)
        drag([CGPoint(x: 60, y: 100), CGPoint(x: 130, y: 140)])
        let blocked = await model.prepareToQuit()
        XCTAssertFalse(blocked)
        repository.reconcileOutcome = .committed
        let ready = await model.prepareToQuit()
        XCTAssertTrue(ready)
    }

    func testARetryEditIsRetriedAtQuit() async throws {
        var fail = true
        let durable = try persistentStore(save: { context in
            if fail { throw NSError(domain: "Injected", code: 1) }
            try context.save()
        })
        use(durable)
        model.setTool(.pen)
        drag([CGPoint(x: 60, y: 100), CGPoint(x: 130, y: 140)])
        XCTAssertTrue(durable.hasUnsettledEdits)
        fail = false
        let ready = await model.prepareToQuit()
        XCTAssertTrue(ready)
        XCTAssertFalse(durable.hasUnsettledEdits)
    }
}

/// A repository whose saves are held until the test lets them settle.
@MainActor
final class Draw3HeldRepository: DrawRepository {
    private let memory = DrawMemoryRepository()
    var reconcileOutcome: DrawWriteOutcome = .held("Mixed")
    /// Once set, writes save (the store's trouble is over).
    var writesCommit = false

    func library() throws -> [DrawCanvas] { memory.library() }
    func load(_ id: UUID) throws -> DrawSnapshot? { memory.load(id) }
    func textMatches(_ words: [String], in id: UUID) throws -> [UUID] { memory.textMatches(words, in: id) }
    func write(_ change: DrawChange) -> DrawWriteOutcome { writesCommit ? memory.write(change) : .held("Mixed") }
    func reconcile(_ change: DrawChange) -> DrawWriteOutcome {
        if case .committed = reconcileOutcome { _ = memory.write(change) }
        return reconcileOutcome
    }
    func discardAttempt(for id: UUID) {}
    func deletedImageHeaders() throws -> [DrawDeletedImage] { [] }
    func purge(canvases: [UUID: Date], images: [UUID: DrawImageTarget]) -> DrawRepositoryPurge { DrawRepositoryPurge() }
}

/// No stalls with images: the board's input never decodes or rasters on the
/// main thread, also with a 6000 × 4000 image on the board.
@MainActor
final class Draw3BoardTests: XCTestCase {
    private var model: DrawPageModel!
    private var board: DrawBoardView!

    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        AtticDraw.enabledOverride = true
        model = DrawPageModel(store: DrawInMemoryStore())
        model.pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-draw3-board-\(UUID().uuidString)"))
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
        AtticDraw.enabledOverride = nil
        super.tearDown()
    }

    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: board.bounds.height - point.y),
                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func waitForInstall(after count: Int, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while board.rasterInstalls <= count, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return board.rasterInstalls > count
    }

    func testALargeImageNeverDecodesOrRastersOnTheMainThread() throws {
        let data = Draw3Images.encoded(width: 6000, height: 4000, type: .jpeg)
        let file = ownedTemporaryDirectory(prefix: "Draw3Large")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let url = file.appendingPathComponent("large.jpg")
        try data.write(to: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-draw3-large-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        XCTAssertTrue(waitForInstall(after: 0))
        DrawImageDecodeProbe.reset()
        DrawRasterProbe.reset()

        // Sample before the import: its raster may finish in the same run-loop
        // turn that publishes the object. Sampling afterward waits for a
        // second raster that no operation requested.
        let installs = board.rasterInstalls
        // The drop handler only starts the import.
        XCTAssertTrue(board.acceptDrop(from: pasteboard, at: CGPoint(x: 160, y: 200)))
        XCTAssertEqual(DrawImageDecodeProbe.mainThreadDecodes, 0)
        // A synchronous test that spins the run loop: the raster arrives on
        // the main queue, which an async test's main-actor job would hold.
        let deadline = Date().addingTimeInterval(20)
        while model.objects.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(model.objects.count, 1)
        XCTAssertTrue(waitForInstall(after: installs))

        // Select, move, resize, pan and zoom it.
        model.setTool(.select)
        let centre = model.viewport.screen(CGPoint(x: DrawGeometry.bounds(model.objects[0]).midX,
                                                   y: DrawGeometry.bounds(model.objects[0]).midY))
        board.mouseDown(with: mouse(.leftMouseDown, centre))
        board.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: centre.x + 20, y: centre.y + 10)))
        board.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: centre.x + 20, y: centre.y + 10)))
        let corner = try XCTUnwrap(model.handleSpots.first { $0.handle == .bottomRight }).point
        board.mouseDown(with: mouse(.leftMouseDown, corner))
        for step in 1...6 { board.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: corner.x + CGFloat(step) * 6, y: corner.y))) }
        board.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: corner.x + 36, y: corner.y)))
        model.scroll(dx: 30, dy: 20, command: false, at: CGPoint(x: 100, y: 100))
        model.magnify(by: 0.5, at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(DrawImageDecodeProbe.mainThreadDecodes, 0, "No input handler decodes")
        XCTAssertEqual(DrawRasterProbe.mainThreadRasters, 0, "No input handler rasters")
        XCTAssertTrue(waitForInstall(after: board.rasterInstalls))
        XCTAssertGreaterThan(DrawImageDecodeProbe.decodes, 0, "The image decodes on the renderer")
        XCTAssertEqual(DrawImageDecodeProbe.mainThreadDecodes, 0)
        XCTAssertLessThan(DrawImageDecodeProbe.largestPixelSide, 6000, "Downsampled to the size on screen")
    }
}

/// Holds an async step until the test opens it.
final class Draw3Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiting = waiters
        waiters = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}
