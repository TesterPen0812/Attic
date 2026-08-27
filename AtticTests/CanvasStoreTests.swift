import Foundation
import SwiftData
import XCTest
@testable import Attic

final class CanvasStoreTests: XCTestCase {
    @MainActor
    func testAddStrokePersistsOneArchiveWithOneSave() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = CanvasStore(
            container: container,
            now: { clock.value },
            persist: gate.save
        )
        let points = [
            CanvasPoint(x: 1, y: 2),
            CanvasPoint(x: 3, y: 4),
            CanvasPoint(x: 5, y: 6)
        ]

        let stroke = try XCTUnwrap(
            store.addStroke(color: .green, width: 5.5, points: points)
        )

        XCTAssertEqual(gate.saveCount, 1)
        XCTAssertEqual(store.strokes, [stroke])
        XCTAssertEqual(stroke.color, .green)
        XCTAssertEqual(stroke.width, 5.5)
        XCTAssertEqual(stroke.points, points)

        let verificationContext = ModelContext(container)
        let rows = try verificationContext.fetch(FetchDescriptor<CanvasStrokeItem>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].payloadVersion, CanvasStrokeCodec.currentVersion)
        let decoded = try CanvasStrokeCodec.decode(
            rows[0].payload,
            expectedVersion: rows[0].payloadVersion
        )
        XCTAssertEqual(decoded.points, points)
    }

    @MainActor
    func testFailedAddRollsBackAndDoesNotExposeUnpersistedInk() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        gate.shouldFail = true
        let store = CanvasStore(container: container, persist: gate.save)

        XCTAssertNil(store.addStroke(
            color: .ink,
            width: 3,
            points: [CanvasPoint(x: 0, y: 0)]
        ))

        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)
        let verificationContext = ModelContext(container)
        XCTAssertEqual(
            try verificationContext.fetchCount(FetchDescriptor<CanvasStrokeItem>()),
            0
        )
    }

    @MainActor
    func testRefreshChoosesOneDeterministicLogicalReplicaWithoutDeletingRows() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        context.insert(try storedStroke(
            id: sharedID,
            points: [CanvasPoint(x: 1, y: 1)],
            mutationVersion: 1,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        context.insert(try storedStroke(
            id: sharedID,
            color: .blue,
            points: [CanvasPoint(x: 2, y: 2)],
            mutationVersion: 2,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        ))
        try context.save()

        let store = CanvasStore(container: container)

        XCTAssertEqual(store.strokes.count, 1)
        XCTAssertEqual(store.strokes.first?.id, sharedID)
        XCTAssertEqual(store.strokes.first?.color, .blue)
        XCTAssertEqual(store.strokes.first?.points, [CanvasPoint(x: 2, y: 2)])
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<CanvasStrokeItem>()),
            2
        )
    }

    @MainActor
    func testEraseAndRestoreMutateEveryPhysicalReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seedContext = ModelContext(container)
        let sharedID = UUID()
        seedContext.insert(try storedStroke(
            id: sharedID,
            points: [CanvasPoint(x: 1, y: 1)],
            mutationVersion: 1
        ))
        seedContext.insert(try storedStroke(
            id: sharedID,
            points: [CanvasPoint(x: 2, y: 2)],
            mutationVersion: 2
        ))
        try seedContext.save()
        let store = CanvasStore(container: container)
        let visible = try XCTUnwrap(store.strokes.first)

        XCTAssertTrue(store.setDeleted(true, strokeIDs: [sharedID]))
        var verificationContext = ModelContext(container)
        var replicas = try verificationContext.fetch(FetchDescriptor<CanvasStrokeItem>())
        XCTAssertEqual(replicas.count, 2)
        XCTAssertTrue(replicas.allSatisfy(\.tombstoned))
        XCTAssertEqual(Set(replicas.map(\.mutationVersion)).count, 1)
        XCTAssertTrue(store.strokes.isEmpty)

        XCTAssertTrue(store.restore([visible]))
        verificationContext = ModelContext(container)
        replicas = try verificationContext.fetch(FetchDescriptor<CanvasStrokeItem>())
        XCTAssertTrue(replicas.allSatisfy { !$0.tombstoned })
        XCTAssertTrue(replicas.allSatisfy { $0.boardGeneration == store.boardGeneration })
        XCTAssertEqual(Set(replicas.map(\.mutationVersion)).count, 1)
        XCTAssertEqual(store.strokes.map(\.id), [sharedID])
    }

    @MainActor
    func testClearAdvancesEveryBoardReplicaToOneGeneration() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(CanvasBoardItem(
            id: CanvasBoardItem.logicalBoardID,
            clearGeneration: 2,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        ))
        context.insert(CanvasBoardItem(
            id: CanvasBoardItem.logicalBoardID,
            clearGeneration: 5,
            updatedAt: Date(timeIntervalSince1970: 5_000)
        ))
        try context.save()
        let store = CanvasStore(container: container)

        XCTAssertEqual(store.boardGeneration, 5)
        XCTAssertTrue(store.clearBoard())

        let verificationContext = ModelContext(container)
        let replicas = try verificationContext.fetch(FetchDescriptor<CanvasBoardItem>())
        XCTAssertEqual(replicas.count, 2)
        XCTAssertTrue(replicas.allSatisfy { $0.clearGeneration == 6 })
        XCTAssertEqual(store.boardGeneration, 6)
    }

    @MainActor
    func testClearGenerationHidesStaleReplicaImportedLater() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        XCTAssertNotNil(store.addStroke(
            color: .ink,
            width: 3,
            points: [CanvasPoint(x: 0, y: 0)]
        ))
        XCTAssertTrue(store.clearBoard())
        XCTAssertEqual(store.boardGeneration, 1)
        XCTAssertTrue(store.strokes.isEmpty)

        let externalContext = ModelContext(container)
        externalContext.insert(try storedStroke(
            points: [CanvasPoint(x: 99, y: 99)],
            boardGeneration: 0,
            mutationVersion: 50,
            updatedAt: Date(timeIntervalSince1970: 9_000)
        ))
        try externalContext.save()

        store.refresh()

        XCTAssertTrue(store.strokes.isEmpty)
        let verificationContext = ModelContext(container)
        XCTAssertEqual(
            try verificationContext.fetchCount(FetchDescriptor<CanvasStrokeItem>()),
            2
        )
    }

    @MainActor
    func testRestoreAfterClearReplaysCapturedStrokeIntoCurrentGeneration() throws {
        let store = try makeTestCanvasStore()
        let original = try XCTUnwrap(store.addStroke(
            color: .orange,
            width: 7,
            points: [CanvasPoint(x: -4, y: 8)]
        ))
        XCTAssertTrue(store.clearBoard())
        let generationAfterClear = store.boardGeneration

        XCTAssertTrue(store.restore([original]))

        let restored = try XCTUnwrap(store.strokes.first)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.color, original.color)
        XCTAssertEqual(restored.width, original.width)
        XCTAssertEqual(restored.points, original.points)
        XCTAssertEqual(restored.boardGeneration, generationAfterClear)
        XCTAssertEqual(store.boardGeneration, generationAfterClear)
    }

    @MainActor
    func testFailedClearReloadsPersistedGenerationAndInk() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let store = CanvasStore(container: container, persist: gate.save)
        let stroke = try XCTUnwrap(store.addStroke(
            color: .ink,
            width: 3,
            points: [CanvasPoint(x: 0, y: 0)]
        ))
        gate.shouldFail = true

        XCTAssertFalse(store.clearBoard())

        XCTAssertEqual(store.boardGeneration, 0)
        XCTAssertEqual(store.strokes.map(\.id), [stroke.id])
        XCTAssertNotNil(store.lastErrorMessage)
    }

    @MainActor
    func testMalformedPayloadIsRetainedButNotRendered() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(CanvasStrokeItem(
            payloadVersion: CanvasStrokeCodec.currentVersion,
            payload: Data("not-json".utf8),
            boardGeneration: 0,
            mutationVersion: 1
        ))
        try context.save()

        let store = CanvasStore(container: container)

        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<CanvasStrokeItem>()),
            1
        )
    }

    @MainActor
    func testCompletedCloudImportRefreshesThroughFreshContext() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        XCTAssertTrue(store.strokes.isEmpty)

        let externalContext = ModelContext(container)
        externalContext.insert(try storedStroke(
            color: .red,
            points: [CanvasPoint(x: 12, y: 34)]
        ))
        try externalContext.save()

        store.handleCloudSyncEvent(CloudSyncEventUpdate(
            id: UUID(),
            kind: .importData,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil
        ))
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(store.strokes.count, 1)
        XCTAssertEqual(store.strokes.first?.color, .red)
        XCTAssertEqual(store.strokes.first?.points, [CanvasPoint(x: 12, y: 34)])
    }

    private func storedStroke(
        id: UUID = UUID(),
        color: CanvasInkColor = .ink,
        width: Double = 3,
        points: [CanvasPoint],
        boardGeneration: Int64 = 0,
        mutationVersion: Int64 = 1,
        tombstoned: Bool = false,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> CanvasStrokeItem {
        CanvasStrokeItem(
            id: id,
            payloadVersion: CanvasStrokeCodec.currentVersion,
            payload: try CanvasStrokeCodec.encode(
                color: color,
                width: width,
                points: points
            ),
            boardGeneration: boardGeneration,
            mutationVersion: mutationVersion,
            tombstoned: tombstoned,
            createdAt: Date(timeIntervalSince1970: 500),
            updatedAt: updatedAt,
            deletedAt: tombstoned ? updatedAt : nil
        )
    }
}
