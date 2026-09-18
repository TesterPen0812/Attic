import CoreText
import SwiftData
import XCTest
@testable import Attic

final class CanvasSessionTests: XCTestCase {
    @MainActor
    func testSemanticTextPlacementTransformsLayersAndHistoryPreserveCharacters() async throws {
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store)
        let clickedPoint = CanvasPoint(x: -193, y: 287)
        XCTAssertTrue(session.prepareTextPlacement("Hello 👋\nمرحبا", prefersDarkSurface: false))
        guard case let .text(placement)? = session.pendingPlacement else { return XCTFail("Expected text placement") }
        let placed = await session.completePendingText(placement, at: clickedPoint)
        XCTAssertTrue(placed)
        let original = try XCTUnwrap(session.semanticObjects.first)
        XCTAssertEqual(original.transform.center, clickedPoint)
        XCTAssertEqual(original.content?.text, "Hello 👋\nمرحبا")
        XCTAssertTrue(session.images.isEmpty)
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertNil(session.pendingPlacement)
        XCTAssertEqual(session.tool, .select)
        XCTAssertTrue(session.nudgeSelectedSemanticObject(CGSize(width: 10, height: -4)))
        XCTAssertEqual(session.selectedSemanticObject?.transform.center, CanvasPoint(x: -183, y: 283))
        XCTAssertTrue(session.resizeSelectedSemanticObject(by: 1.5))
        XCTAssertEqual(session.selectedSemanticObject?.transform.width, original.transform.width * 1.5)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.selectedSemanticObject?.transform.width, original.transform.width)
        XCTAssertTrue(session.redo())
        let prepared = CanvasPreparedImage(encodedData: Data([1, 2, 3]), contentType: "public.png", pixelWidth: 20, pixelHeight: 20)
        XCTAssertTrue(session.importPreparedImage(prepared, at: .zero))
        XCTAssertNil(session.selectedSemanticObjectID)
        let image = try XCTUnwrap(session.images.first)
        XCTAssertGreaterThan(image.zIndex, original.transform.zIndex)
        session.selectSemanticObject(original.id)
        XCTAssertTrue(session.moveSelectedSemanticLayer(forward: true))
        XCTAssertGreaterThan(try XCTUnwrap(session.selectedSemanticObject).transform.zIndex, image.zIndex)
        XCTAssertTrue(session.moveSelectedSemanticLayer(forward: false))
        XCTAssertLessThan(try XCTUnwrap(session.selectedSemanticObject).transform.zIndex, image.zIndex)
        var content = try XCTUnwrap(session.selectedSemanticObject?.content)
        content.text = "Changed 📝\nSecond line"
        content.fontWeight = "bold"
        content.alignment = "center"
        XCTAssertTrue(session.editSemanticObject(original.id, content: content))
        XCTAssertEqual(session.selectedSemanticObject?.content, content)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.selectedSemanticObject?.content?.text, original.content?.text)
        XCTAssertTrue(session.redo())
        XCTAssertTrue(session.deleteSemanticObject(original.id))
        XCTAssertTrue(session.semanticObjects.isEmpty)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.semanticObjects.first?.content, content)
        XCTAssertEqual(CanvasStore(container: store.container).semanticObjects.first?.content, content)
    }

    @MainActor
    func testFailedSemanticPlacementRetainsTextAndCanRetryWithoutDuplicate() async throws {
        let gate = PersistenceGate()
        let session = CanvasSession(store: try makeTestCanvasStore(persist: gate.save))
        XCTAssertTrue(session.prepareTextPlacement("Do not lose this", prefersDarkSurface: false))
        guard case let .text(placement)? = session.pendingPlacement else { return XCTFail("Expected pending text") }
        gate.shouldFail = true
        let failed = await session.completePendingText(placement, at: CanvasPoint(x: 34, y: 78))
        XCTAssertFalse(failed)
        XCTAssertEqual(session.pendingPlacement, .text(placement))
        XCTAssertTrue(session.semanticObjects.isEmpty)
        gate.shouldFail = false
        let saved = await session.completePendingText(placement, at: CanvasPoint(x: 34, y: 78))
        XCTAssertTrue(saved)
        XCTAssertNil(session.pendingPlacement)
        XCTAssertEqual(session.semanticObjects.count, 1)
        XCTAssertEqual(session.semanticObjects.first?.transform.center, CanvasPoint(x: 34, y: 78))
        XCTAssertEqual(session.tool, .select)
    }

    @MainActor
    func testRefusedBoardOperationsKeepHistoryPlacementAndSurface() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.completeStroke(points: [.zero, CanvasPoint(x: 20, y: 30)]))
        XCTAssertTrue(session.prepareTextPlacement("Keep placing", prefersDarkSurface: false))
        let placement = try XCTUnwrap(session.pendingPlacement)
        let undoCount = session.undoCommandCount
        let epoch = session.interactionCancellationEpoch
        let boardID = session.selectedCanvasID
        XCTAssertGreaterThan(undoCount, 0)

        XCTAssertNil(session.createCanvas(name: "   "))
        XCTAssertFalse(session.selectCanvas(UUID()))
        XCTAssertFalse(session.deleteSelectedCanvas())
        XCTAssertEqual(session.selectedCanvasID, boardID)
        XCTAssertEqual(session.undoCommandCount, undoCount)
        XCTAssertTrue(session.canUndo)
        XCTAssertEqual(session.pendingPlacement, placement)
        XCTAssertEqual(session.interactionCancellationEpoch, epoch)
        XCTAssertTrue(session.undo())

        // Real board changes still reset history, placement, and the surface.
        let second = try XCTUnwrap(session.createCanvas(name: "Second"))
        XCTAssertEqual(session.selectedCanvasID, second.id)
        XCTAssertEqual(session.undoCommandCount, 0)
        XCTAssertNil(session.pendingPlacement)
        XCTAssertGreaterThan(session.interactionCancellationEpoch, epoch)
        let changes: [() -> Bool] = [{ session.selectCanvas(boardID) }, { session.deleteSelectedCanvas() }]
        for change in changes {
            XCTAssertTrue(session.completeStroke(points: [.zero, CanvasPoint(x: 40, y: 10)]))
            let before = session.interactionCancellationEpoch
            XCTAssertTrue(change())
            XCTAssertEqual(session.undoCommandCount, 0)
            XCTAssertGreaterThan(session.interactionCancellationEpoch, before)
        }
    }

    @MainActor
    func testImageBatchAndHistoryKeepOneSelectionKind() async throws {
        let prepared = CanvasPreparedImage(encodedData: Data([1, 2, 3]), contentType: "public.png", pixelWidth: 20, pixelHeight: 20)
        let session = CanvasSession(store: try makeTestCanvasStore(), prepareImage: { _ in prepared })
        XCTAssertTrue(session.insertShape(.rectangle, from: .zero, to: CanvasPoint(x: 80, y: 60)))
        let semanticID = try XCTUnwrap(session.selectedSemanticObjectID)
        let result = await session.importImageBatch(CanvasImageImportBatch(target: session.captureImageImportTarget(),
            items: [CanvasImageImportRequest(source: .data(Data([1])), center: .zero)]))
        XCTAssertNotNil(result.items.first?.outcome.importedImageID)
        XCTAssertNil(session.selectedSemanticObjectID)
        XCTAssertNotNil(session.selectedImageID)
        XCTAssertTrue(session.undo())
        session.selectSemanticObject(semanticID)
        XCTAssertTrue(session.redo())
        XCTAssertNotNil(session.selectedImageID)
        XCTAssertNil(session.selectedSemanticObjectID)
    }

    @MainActor
    func testMixedSemanticClearUndoIsAtomicAndFailedUndoCanBeRetried() async throws {
        let gate = PersistenceGate()
        let store = try makeTestCanvasStore(persist: gate.save)
        let session = CanvasSession(store: store)
        XCTAssertTrue(session.completeStroke(points: [.zero, CanvasPoint(x: 20, y: 30)]))
        XCTAssertTrue(session.importPreparedImage(CanvasPreparedImage(encodedData: Data([4, 5, 6]), contentType: "public.png", pixelWidth: 40, pixelHeight: 50), at: .zero))
        let placed = await session.insertText("Persistent text", at: CanvasPoint(x: 150, y: 50), prefersDarkSurface: false)
        XCTAssertTrue(placed)
        let semanticID = try XCTUnwrap(session.semanticObjects.first?.id)
        let saves = gate.saveCount
        gate.shouldFail = true
        XCTAssertFalse(session.clear())
        XCTAssertEqual(session.semanticObjects.count, 1)
        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertEqual(session.images.count, 1)
        gate.shouldFail = false
        XCTAssertTrue(session.clear())
        XCTAssertEqual(gate.saveCount, saves + 1)
        let generation = session.boardGeneration
        gate.shouldFail = true
        XCTAssertFalse(session.undo())
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.semanticObjects.isEmpty)
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.images.isEmpty)
        let failedRestoreContext = ModelContext(store.container)
        XCTAssertTrue(try failedRestoreContext.fetch(FetchDescriptor<CanvasSemanticObjectItem>()).allSatisfy { $0.boardGeneration < generation })
        XCTAssertTrue(try failedRestoreContext.fetch(FetchDescriptor<CanvasStrokeItem>()).allSatisfy { $0.boardGeneration < generation })
        XCTAssertTrue(try failedRestoreContext.fetch(FetchDescriptor<CanvasImageItem>()).allSatisfy { $0.boardGeneration < generation })
        gate.shouldFail = false
        XCTAssertTrue(session.undo())
        XCTAssertEqual(gate.saveCount, saves + 2)
        XCTAssertEqual(session.semanticObjects.first?.id, semanticID)
        XCTAssertEqual(session.semanticObjects.first?.boardGeneration, generation)
        XCTAssertEqual(session.images.count, 1)
        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertTrue(session.redo())
        let reloaded = CanvasStore(container: store.container)
        XCTAssertTrue(reloaded.semanticObjects.isEmpty)
        XCTAssertTrue(reloaded.images.isEmpty)
        XCTAssertTrue(reloaded.strokes.isEmpty)
    }

    @MainActor
    func testRestoresViewportAndToolPerBoardWithoutHistoryOrSelection() throws {
        let suite = "CanvasViewStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store, viewStateDefaults: defaults)
        let firstID = session.selectedCanvasID
        let firstViewport = CanvasViewport(center: CanvasPoint(x: 83, y: -42), scale: 2.5)
        session.setViewport(firstViewport)
        session.selectTool(.eraser)
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: 1, y: 2)]))
        let second = try XCTUnwrap(session.createCanvas(name: "Second"))
        XCTAssertEqual(session.viewport, CanvasViewport())
        XCTAssertEqual(session.tool, .pen)
        let secondViewport = CanvasViewport(center: CanvasPoint(x: -91, y: 115), scale: 0.5)
        session.setViewport(secondViewport)
        session.selectTool(.select)
        XCTAssertTrue(session.selectCanvas(firstID))
        XCTAssertEqual(session.viewport, firstViewport)
        XCTAssertEqual(session.tool, .eraser)
        XCTAssertTrue(session.selectCanvas(second.id))
        session.flushViewState()
        let restored = CanvasSession(store: CanvasStore(container: store.container), viewStateDefaults: defaults)
        XCTAssertEqual(restored.selectedCanvasID, second.id)
        XCTAssertEqual(restored.viewport, secondViewport)
        XCTAssertEqual(restored.tool, .select)
        XCTAssertFalse(restored.canUndo)
        XCTAssertNil(restored.selectedImageID)
        XCTAssertTrue(restored.selectCanvas(firstID))
        XCTAssertEqual(restored.viewport, firstViewport)
    }

    @MainActor
    func testImageReplacementRollsBackOnSaveFailureAndUndoRestoresOriginalBytes() async throws {
        let gate = PersistenceGate()
        let store = try makeTestCanvasStore(persist: gate.save)
        let replacement = CanvasPreparedImage(encodedData: Data([9, 8, 7]), contentType: "public.png", pixelWidth: 90, pixelHeight: 70)
        let session = CanvasSession(store: store, prepareImage: { _ in replacement })
        let original = CanvasPreparedImage(encodedData: Data([1, 2, 3]), contentType: "public.png", pixelWidth: 40, pixelHeight: 30)
        XCTAssertTrue(session.importPreparedImage(original, at: CanvasPoint(x: 12, y: 25)))
        let image = try XCTUnwrap(session.images.first)
        gate.shouldFail = true
        let failed = await session.replaceImage(image.id, from: URL(fileURLWithPath: "/unused-replacement-fixture"))
        XCTAssertFalse(failed)
        XCTAssertEqual(session.images.first?.encodedData, original.encodedData)
        gate.shouldFail = false
        let succeeded = await session.replaceImage(image.id, from: URL(fileURLWithPath: "/unused-replacement-fixture"))
        XCTAssertTrue(succeeded)
        XCTAssertEqual(session.images.first?.encodedData, replacement.encodedData)
        XCTAssertEqual(session.images.first?.transform, image.transform)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.images.first?.encodedData, original.encodedData)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.images.first?.encodedData, replacement.encodedData)
        XCTAssertEqual(try ModelContext(store.container).fetch(FetchDescriptor<CanvasImageItem>()).count, 1)
    }

    @MainActor
    func testStableEditCommandRouteIsCanvasScopedAndToolbarIndependent() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.completeStroke(points: [
            CanvasPoint(x: 1, y: 2),
            CanvasPoint(x: 3, y: 4)
        ]))

        for section in PanelSection.allCases where !section.isCanvas {
            XCTAssertFalse(CanvasEditCommandRoute.canUndo(
                session: session,
                section: section
            ))
            XCTAssertFalse(CanvasEditCommandRoute.undo(
                session: session,
                section: section
            ))
            XCTAssertEqual(session.strokes.count, 1)
        }

        XCTAssertTrue(CanvasEditCommandRoute.canUndo(
            session: session,
            section: .canvas
        ))
        XCTAssertTrue(CanvasEditCommandRoute.undo(
            session: session,
            section: .canvas
        ))
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(CanvasEditCommandRoute.canRedo(
            session: session,
            section: .canvas
        ))
        XCTAssertTrue(CanvasEditCommandRoute.redo(
            session: session,
            section: .canvas
        ))
        XCTAssertEqual(session.strokes.count, 1)
    }

    @MainActor
    func testNarrowingTextResizeGrowsHeightSoPersistedTextIsNotClipped() async throws {
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store)
        let placed = await session.insertText(
            "Narrowing a text box must never hide the words that wrap onto later lines",
            at: CanvasPoint(x: 10, y: 20),
            prefersDarkSurface: false
        )
        XCTAssertTrue(placed)
        let original = try XCTUnwrap(session.semanticObjects.first)
        XCTAssertTrue(canvasSemanticTextIsFullyVisible(original))

        var narrowed = original.transform
        narrowed.width = 96
        narrowed.center.x -= (original.transform.width - narrowed.width) / 2
        XCTAssertFalse(canvasSemanticTextIsFullyVisible(original, transform: narrowed))
        XCTAssertTrue(session.transformSemanticObject(original.id, to: narrowed))

        let resized = try XCTUnwrap(session.semanticObjects.first)
        XCTAssertEqual(resized.transform.width, 96)
        XCTAssertEqual(resized.worldRect.minX, original.worldRect.minX, accuracy: 0.001)
        XCTAssertEqual(resized.worldRect.minY, original.worldRect.minY, accuracy: 0.001)
        XCTAssertGreaterThan(resized.transform.height, original.transform.height)
        XCTAssertTrue(canvasSemanticTextIsFullyVisible(resized))
        let persisted = try XCTUnwrap(CanvasStore(container: store.container).semanticObjects.first)
        XCTAssertEqual(persisted.transform, resized.transform)
        XCTAssertTrue(canvasSemanticTextIsFullyVisible(persisted))

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.semanticObjects.first?.transform, original.transform)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.semanticObjects.first?.transform, resized.transform)

        // Negative controls: a move keeps the fitted size, and a height-only
        // shrink that would clip is refitted rather than persisted.
        var moved = resized.transform
        moved.center.x += 5
        XCTAssertTrue(session.transformSemanticObject(original.id, to: moved))
        XCTAssertEqual(session.semanticObjects.first?.transform, moved)
        var squashed = moved
        squashed.height = CanvasImagePlacement.minimumDimension
        squashed.center.y -= (moved.height - squashed.height) / 2
        XCTAssertFalse(session.transformSemanticObject(original.id, to: squashed))
        XCTAssertEqual(session.semanticObjects.first?.transform, moved)
        XCTAssertTrue(canvasSemanticTextIsFullyVisible(try XCTUnwrap(session.semanticObjects.first)))
    }

    @MainActor
    func testKeyboardSemanticResizeSharesPointerMinimumDimension() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.insertShape(.rectangle, from: CanvasPoint(x: 0, y: 0), to: CanvasPoint(x: 100, y: 80)))
        let shape = try XCTUnwrap(session.selectedSemanticObject)
        XCTAssertNil(shape.content?.text)
        let rect = shape.worldRect
        let pointerFloor = CanvasImagePlacement.resizedTransform(
            from: shape.transform,
            handle: .bottomRight,
            to: CanvasPoint(x: rect.minX, y: rect.minY),
            preserveAspectRatio: false
        )
        XCTAssertEqual(pointerFloor.width, CanvasImagePlacement.minimumDimension)
        XCTAssertEqual(pointerFloor.height, CanvasImagePlacement.minimumDimension)

        for _ in 0..<12 { _ = session.resizeSelectedSemanticObject(by: 0.5) }
        let keyboardFloor = try XCTUnwrap(session.selectedSemanticObject?.transform)
        XCTAssertEqual(keyboardFloor.width, pointerFloor.width)
        XCTAssertEqual(keyboardFloor.height, pointerFloor.height)
        XCTAssertFalse(session.resizeSelectedSemanticObject(by: 0.5))

        // Growth is unaffected by the floor.
        XCTAssertTrue(session.resizeSelectedSemanticObject(by: 2))
        XCTAssertEqual(session.selectedSemanticObject?.transform.width, CanvasImagePlacement.minimumDimension * 2)

        // Keyboard narrowing of text honours the same floor and still fits.
        let placed = await session.insertText("Keyboard shrink keeps every word", at: CanvasPoint(x: 400, y: 0), prefersDarkSurface: false)
        XCTAssertTrue(placed)
        for _ in 0..<12 { _ = session.resizeSelectedSemanticObject(by: 0.5) }
        let text = try XCTUnwrap(session.selectedSemanticObject)
        XCTAssertEqual(text.transform.width, CanvasImagePlacement.minimumDimension)
        XCTAssertGreaterThanOrEqual(text.transform.height, CanvasImagePlacement.minimumDimension)
        XCTAssertTrue(canvasSemanticTextIsFullyVisible(text))
    }

    @MainActor
    func testCompletedStrokeSupportsUndoAndRedo() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let points = [
            CanvasPoint(x: 1, y: 2),
            CanvasPoint(x: 3, y: 4)
        ]

        XCTAssertTrue(session.completeStroke(points: points))
        let strokeID = try XCTUnwrap(session.strokes.first?.id)
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canRedo)

        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertFalse(session.canUndo)
        XCTAssertTrue(session.canRedo)

        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.strokes.map(\.id), [strokeID])
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canRedo)
    }

    @MainActor
    func testInsertedShapeRemainsSemanticAndUsesHistoryAndCurrentStyle() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        session.selectColor(.blue)
        session.setWidth(6.5)

        XCTAssertTrue(session.insertShape(
            .ellipse,
            from: CanvasPoint(x: -20, y: -60),
            to: CanvasPoint(x: 100, y: 20)
        ))
        let object = try XCTUnwrap(session.semanticObjects.first)
        XCTAssertEqual(object.content?.color, .blue)
        XCTAssertEqual(object.content?.strokeWidth, 6.5)
        XCTAssertEqual(object.content?.shape, .ellipse)
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.canUndo)

        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.semanticObjects.isEmpty)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.semanticObjects.map(\.id), [object.id])
    }

    @MainActor
    func testShapePlacementMustBeArmedAndUsesDraggedEndpoints() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let start = CanvasPoint(x: 18, y: -12)
        let end = CanvasPoint(x: -42, y: 75)

        XCTAssertFalse(session.completePendingShape(
            .rectangle,
            from: start,
            to: end
        ))
        XCTAssertTrue(session.strokes.isEmpty)

        session.prepareShapePlacement(.rectangle)
        XCTAssertEqual(session.pendingPlacement, .shape(.rectangle))
        XCTAssertTrue(session.completePendingShape(
            .rectangle,
            from: start,
            to: end
        ))
        XCTAssertNil(session.pendingPlacement)
        let object = try XCTUnwrap(session.semanticObjects.first)
        XCTAssertEqual(object.worldRect, CGRect(x: -42, y: -12, width: 60, height: 87))
        XCTAssertEqual(object.content?.shape, .rectangle)
        XCTAssertTrue(session.strokes.isEmpty)
    }

    @MainActor
    func testPreparingTextDefersInsertionAndToolSelectionCancelsPlacement() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())

        XCTAssertTrue(session.prepareTextPlacement(
            "  Place me here  ",
            prefersDarkSurface: true
        ))
        XCTAssertEqual(
            session.pendingPlacement,
            .text(CanvasTextPlacement(
                text: "Place me here",
                prefersDarkSurface: true
            ))
        )
        XCTAssertTrue(session.images.isEmpty)

        session.selectTool(.eraser)
        XCTAssertNil(session.pendingPlacement)
        XCTAssertEqual(session.tool, .eraser)
    }

    @MainActor
    func testOneEraseGestureIsOneHistoryCommandForEveryHitStroke() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.completeStroke(
            points: [CanvasPoint(x: 0, y: 0)]
        ))
        XCTAssertTrue(session.completeStroke(
            points: [CanvasPoint(x: 10, y: 10)]
        ))
        let ids = Set(session.strokes.map(\.id))
        XCTAssertEqual(ids.count, 2)

        XCTAssertTrue(session.erase(strokeIDs: ids))
        XCTAssertTrue(session.strokes.isEmpty)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(Set(session.strokes.map(\.id)), ids)

        XCTAssertTrue(session.redo())
        XCTAssertTrue(session.strokes.isEmpty)
    }

    @MainActor
    func testClearUndoRestoresInkWithoutDecrementingGeneration() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.completeStroke(
            points: [CanvasPoint(x: -2, y: 8)]
        ))
        let originalID = try XCTUnwrap(session.strokes.first?.id)

        XCTAssertTrue(session.clear())
        let generationAfterClear = session.boardGeneration
        XCTAssertTrue(session.strokes.isEmpty)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.boardGeneration, generationAfterClear)
        XCTAssertEqual(session.strokes.map(\.id), [originalID])

        XCTAssertTrue(session.redo())
        XCTAssertGreaterThan(session.boardGeneration, generationAfterClear)
        XCTAssertTrue(session.strokes.isEmpty)
    }

    @MainActor
    func testMixedClearUndoRestoresStrokeAndImageWithOnePersistenceSave() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let store = CanvasStore(container: container, persist: gate.save)
        let session = CanvasSession(store: store)
        XCTAssertTrue(session.completeStroke(
            points: [CanvasPoint(x: -12, y: 8)]
        ))
        XCTAssertTrue(session.importPreparedImage(
            CanvasPreparedImage(
                encodedData: Data([0x89, 0x50, 0x4E, 0x47]),
                contentType: "public.png",
                pixelWidth: 120,
                pixelHeight: 80
            ),
            at: CanvasPoint(x: 40, y: 20)
        ))
        let strokeID = try XCTUnwrap(session.strokes.first?.id)
        let imageID = try XCTUnwrap(session.images.first?.id)

        XCTAssertTrue(session.clear())
        let generationAfterClear = session.boardGeneration
        let saveCountAfterClear = gate.saveCount
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.images.isEmpty)

        XCTAssertTrue(session.undo())

        XCTAssertEqual(gate.saveCount, saveCountAfterClear + 1)
        XCTAssertEqual(session.strokes.map(\.id), [strokeID])
        XCTAssertEqual(session.images.map(\.id), [imageID])
        XCTAssertTrue(session.strokes.allSatisfy {
            $0.boardGeneration == generationAfterClear
        })
        XCTAssertTrue(session.images.allSatisfy {
            $0.boardGeneration == generationAfterClear
        })

        let verificationContext = ModelContext(container)
        let strokeRows = try verificationContext.fetch(
            FetchDescriptor<CanvasStrokeItem>()
        )
        let imageRows = try verificationContext.fetch(
            FetchDescriptor<CanvasImageItem>()
        )
        XCTAssertTrue(strokeRows.allSatisfy {
            !$0.tombstoned && $0.boardGeneration == generationAfterClear
        })
        XCTAssertTrue(imageRows.allSatisfy {
            !$0.tombstoned && $0.boardGeneration == generationAfterClear
        })
    }

    @MainActor
    func testClearUndoRestoresAlreadyVisibleLegacyImageAboveCurrentImportCap() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seedContext = ModelContext(container)
        let imageID = UUID()
        let legacyPayload = Data(
            repeating: 0xA5,
            count: CanvasImageImportPolicy.standard.maximumEncodedBytes + 1
        )
        seedContext.insert(CanvasImageItem(
            id: imageID,
            encodedData: legacyPayload,
            contentType: "public.png",
            pixelWidth: 320,
            pixelHeight: 180,
            centerX: 20,
            centerY: -10,
            width: 320,
            height: 180,
            zIndex: 0,
            boardGeneration: 0,
            mutationVersion: 1
        ))
        try seedContext.save()

        let session = CanvasSession(store: CanvasStore(container: container))
        XCTAssertEqual(session.images.map(\.id), [imageID])
        XCTAssertEqual(session.images.first?.encodedData.count, legacyPayload.count)

        XCTAssertTrue(session.clear())
        let clearedGeneration = session.boardGeneration
        XCTAssertTrue(session.images.isEmpty)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.images.map(\.id), [imageID])
        XCTAssertEqual(session.images.first?.encodedData, legacyPayload)
        XCTAssertEqual(session.images.first?.boardGeneration, clearedGeneration)
    }

    @MainActor
    func testMixedClearUndoRollsBackStrokeWhenImageRestoreStageFails() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let session = CanvasSession(store: store)
        XCTAssertTrue(session.completeStroke(
            points: [CanvasPoint(x: 3, y: 7)]
        ))
        XCTAssertTrue(session.importPreparedImage(
            CanvasPreparedImage(
                encodedData: Data([0x89, 0x50, 0x4E, 0x47]),
                contentType: "public.png",
                pixelWidth: 64,
                pixelHeight: 64
            ),
            at: CanvasPoint(x: 16, y: 24)
        ))
        XCTAssertTrue(session.clear())
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.images.isEmpty)

        let storedImages = try store.context.fetch(
            FetchDescriptor<CanvasImageItem>()
        )
        XCTAssertEqual(storedImages.count, 1)
        storedImages[0].mutationVersion = Int64.max
        try store.context.save()

        XCTAssertFalse(session.undo())

        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.images.isEmpty)
        XCTAssertTrue(session.canUndo)
        let verificationContext = ModelContext(container)
        let strokeRows = try verificationContext.fetch(
            FetchDescriptor<CanvasStrokeItem>()
        )
        XCTAssertEqual(strokeRows.count, 1)
        XCTAssertNotEqual(
            strokeRows[0].boardGeneration,
            session.boardGeneration
        )
    }

    @MainActor
    func testMixedClearUndoRollsBackBothKindsWhenPersistenceFailsAfterStaging() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let persistence = PersistenceGate()
        let store = CanvasStore(container: container, persist: persistence.save)
        let session = CanvasSession(store: store)
        XCTAssertTrue(session.completeStroke(
            points: [CanvasPoint(x: -5, y: 11)]
        ))
        XCTAssertTrue(session.importPreparedImage(
            CanvasPreparedImage(
                encodedData: Data([0x89, 0x50, 0x4E, 0x47]),
                contentType: "public.png",
                pixelWidth: 96,
                pixelHeight: 64
            ),
            at: CanvasPoint(x: 14, y: 22)
        ))
        let strokeID = try XCTUnwrap(session.strokes.first?.id)
        let imageID = try XCTUnwrap(session.images.first?.id)
        XCTAssertTrue(session.clear())
        let clearedGeneration = session.boardGeneration

        persistence.shouldFail = true
        XCTAssertFalse(session.undo())

        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.images.isEmpty)
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canRedo)
        let verificationContext = ModelContext(container)
        let strokeRows = try verificationContext.fetch(
            FetchDescriptor<CanvasStrokeItem>()
        )
        let imageRows = try verificationContext.fetch(
            FetchDescriptor<CanvasImageItem>()
        )
        XCTAssertEqual(strokeRows.map(\.id), [strokeID])
        XCTAssertEqual(imageRows.map(\.id), [imageID])
        XCTAssertTrue(strokeRows.allSatisfy {
            $0.boardGeneration != clearedGeneration
        })
        XCTAssertTrue(imageRows.allSatisfy {
            $0.boardGeneration != clearedGeneration
        })

        persistence.shouldFail = false
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.strokes.map(\.id), [strokeID])
        XCTAssertEqual(session.images.map(\.id), [imageID])
    }

    @MainActor
    func testFailedPersistenceDoesNotCreateUndoHistory() throws {
        let gate = PersistenceGate()
        gate.shouldFail = true
        let store = try makeTestCanvasStore(persist: gate.save)
        let session = CanvasSession(store: store)

        XCTAssertFalse(session.completeStroke(
            points: [CanvasPoint(x: 0, y: 0)]
        ))

        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
        XCTAssertNotNil(session.lastErrorMessage)
    }

    @MainActor
    func testNewOperationClearsRedoStack() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.completeStroke(
            points: [CanvasPoint(x: 0, y: 0)]
        ))
        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.canRedo)

        XCTAssertTrue(session.completeStroke(
            points: [CanvasPoint(x: 20, y: 20)]
        ))

        XCTAssertFalse(session.canRedo)
        XCTAssertTrue(session.canUndo)
        XCTAssertEqual(session.strokes.count, 1)
    }

    @MainActor
    func testImportedSemanticChangeInvalidatesSessionHistory() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let session = CanvasSession(store: store)
        XCTAssertTrue(session.completeStroke(
            points: [CanvasPoint(x: 0, y: 0)]
        ))
        XCTAssertTrue(session.canUndo)

        let externalContext = ModelContext(container)
        externalContext.insert(CanvasStrokeItem(
            payloadVersion: CanvasStrokeCodec.currentVersion,
            payload: try CanvasStrokeCodec.encode(
                color: .blue,
                width: 4,
                points: [CanvasPoint(x: 50, y: 50)]
            ),
            boardGeneration: store.boardGeneration,
            mutationVersion: 1
        ))
        try externalContext.save()
        store.refresh()
        await Task.yield()

        XCTAssertEqual(session.strokes.count, 2)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
    }

    @MainActor
    func testWidthRemainsContinuousButClampedToSupportedRange() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())

        session.setWidth(4.625)
        XCTAssertEqual(session.width, 4.625)
        session.setWidth(100)
        XCTAssertEqual(session.width, CanvasSession.maximumWidth)
        session.setWidth(-10)
        XCTAssertEqual(session.width, CanvasSession.minimumWidth)
    }
}

/// Mirrors `CanvasSemanticRenderer.draw`: text is laid out inside the object's
/// world rect inset by 4 points and clipped to it.
@MainActor
func canvasSemanticTextIsFullyVisible(
    _ object: CanvasSemanticObject,
    transform: CanvasImageTransform? = nil
) -> Bool {
    guard let content = object.content, let text = content.text else { return false }
    let geometry = transform ?? object.transform
    let path = CGPath(
        rect: CGRect(x: 0, y: 0, width: max(1, geometry.width - 8), height: max(1, geometry.height - 8)),
        transform: nil
    )
    let frame = CTFramesetterCreateFrame(
        CanvasSemanticRenderer.framesetter(content), CFRange(location: 0, length: 0), path, nil
    )
    return CTFrameGetVisibleStringRange(frame).length == (text as NSString).length
}
