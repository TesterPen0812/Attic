import SwiftData
import XCTest
@testable import Attic

final class CanvasSessionTests: XCTestCase {
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
