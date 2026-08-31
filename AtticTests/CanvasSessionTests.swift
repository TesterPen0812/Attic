import SwiftData
import XCTest
@testable import Attic

final class CanvasSessionTests: XCTestCase {
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
    func testInsertedShapeUsesStrokeHistoryAndCurrentStyle() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        session.selectColor(.blue)
        session.setWidth(6.5)

        XCTAssertTrue(session.insertShape(
            .ellipse,
            from: CanvasPoint(x: -20, y: -60),
            to: CanvasPoint(x: 100, y: 20)
        ))
        let stroke = try XCTUnwrap(session.strokes.first)
        XCTAssertEqual(stroke.color, .blue)
        XCTAssertEqual(stroke.width, 6.5)
        XCTAssertEqual(stroke.points.count, 65)
        XCTAssertTrue(session.canUndo)

        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.strokes.map(\.id), [stroke.id])
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
        XCTAssertEqual(
            try XCTUnwrap(session.strokes.first).points,
            [
                CanvasPoint(x: -42, y: -12),
                CanvasPoint(x: 18, y: -12),
                CanvasPoint(x: 18, y: 75),
                CanvasPoint(x: -42, y: 75),
                CanvasPoint(x: -42, y: -12)
            ]
        )
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
