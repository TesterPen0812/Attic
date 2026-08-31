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
    func testClearReportsPersistedWhenFreshContextReloadFailsWithoutRetry() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let persistence = PersistenceGate()
        let freshContexts = CanvasFreshContextGate()
        let store = CanvasStore(
            container: container,
            persist: persistence.save,
            makeFreshContext: {
                try freshContexts.makeContext(container: container)
            }
        )
        XCTAssertNotNil(store.addStroke(
            color: .blue,
            width: 4,
            points: [CanvasPoint(x: 2, y: 6)]
        ))
        XCTAssertNotNil(store.addImage(
            CanvasPreparedImage(
                encodedData: Data([0x89, 0x50, 0x4E, 0x47]),
                contentType: "public.png",
                pixelWidth: 96,
                pixelHeight: 48
            ),
            center: CanvasPoint(x: 30, y: 40)
        ))
        let generationBeforeClear = store.boardGeneration
        let saveCountBeforeClear = persistence.saveCount
        freshContexts.failNextContextCreation()

        let outcome = store.clearBoardOutcome()

        guard case let .persistedButRefreshFailed(message) = outcome else {
            return XCTFail("Expected a persisted-but-refresh-failed outcome, got \(outcome)")
        }
        XCTAssertTrue(outcome.didPersist)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(persistence.saveCount, saveCountBeforeClear + 1)
        XCTAssertEqual(store.boardGeneration, generationBeforeClear + 1)
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertEqual(store.lastErrorMessage, message)
        XCTAssertTrue(message.contains("saved"))
        XCTAssertTrue(message.contains("refresh failed"))

        let verificationContext = ModelContext(container)
        let boardRows = try verificationContext.fetch(
            FetchDescriptor<CanvasBoardItem>()
        )
        let strokeRows = try verificationContext.fetch(
            FetchDescriptor<CanvasStrokeItem>()
        )
        let imageRows = try verificationContext.fetch(
            FetchDescriptor<CanvasImageItem>()
        )
        XCTAssertTrue(boardRows.allSatisfy {
            $0.clearGeneration == generationBeforeClear + 1
        })
        XCTAssertTrue(strokeRows.allSatisfy {
            $0.boardGeneration == generationBeforeClear
        })
        XCTAssertTrue(imageRows.allSatisfy {
            $0.boardGeneration == generationBeforeClear
        })
    }

    @MainActor
    func testAddStrokeReturnsPersistedObjectWithoutDuplicateRetryWhenPostSaveReloadFails() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let persistence = PersistenceGate()
        let replicaReads = CanvasReplicaReadGate()
        let store = CanvasStore(
            container: container,
            persist: { context in
                try persistence.save(context)
                replicaReads.persistenceDidSucceed()
            },
            loadReplicas: replicaReads.load
        )
        replicaReads.failReadsAfterNextPersistence()

        let firstAttempt = store.addStroke(
            color: .green,
            width: 4,
            points: [CanvasPoint(x: 3, y: 9)]
        )
        let result = firstAttempt ?? store.addStroke(
            color: .green,
            width: 4,
            points: [CanvasPoint(x: 3, y: 9)]
        )

        XCTAssertNotNil(firstAttempt)
        XCTAssertNotNil(result)
        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertEqual(store.strokes.count, 1)
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<CanvasStrokeItem>()),
            1
        )
        XCTAssertTrue(store.lastErrorMessage?.contains("saved") == true)
        XCTAssertTrue(store.lastErrorMessage?.contains("refresh failed") == true)
    }

    @MainActor
    func testCreateCanvasReturnsPersistedBoardWithoutDuplicateRetryWhenPostSaveReloadFails() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let persistence = PersistenceGate()
        let replicaReads = CanvasReplicaReadGate()
        let store = CanvasStore(
            container: container,
            persist: { context in
                try persistence.save(context)
                replicaReads.persistenceDidSucceed()
            },
            loadReplicas: replicaReads.load
        )
        replicaReads.failReadsAfterNextPersistence()

        let firstAttempt = store.createCanvas(name: "Refresh survivor")
        let result = firstAttempt ?? store.createCanvas(name: "Retry duplicate")

        let created = try XCTUnwrap(firstAttempt)
        XCTAssertEqual(result?.id, created.id)
        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertEqual(store.canvases.map(\.id), [created.id])
        XCTAssertEqual(store.selectedCanvasID, created.id)
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<CanvasBoardItem>()),
            1
        )
        XCTAssertTrue(store.lastErrorMessage?.contains("saved") == true)
        XCTAssertTrue(store.lastErrorMessage?.contains("refresh failed") == true)
    }

    @MainActor
    func testClearAppliesPersistedPresentationWhenEveryPostSaveReloadFails() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let persistence = PersistenceGate()
        let replicaReads = CanvasReplicaReadGate()
        let store = CanvasStore(
            container: container,
            persist: { context in
                try persistence.save(context)
                replicaReads.persistenceDidSucceed()
            },
            loadReplicas: replicaReads.load
        )
        XCTAssertNotNil(store.addStroke(
            color: .blue,
            width: 3,
            points: [CanvasPoint(x: 2, y: 7)]
        ))
        let generationBeforeClear = store.boardGeneration
        let saveCountBeforeClear = persistence.saveCount
        replicaReads.failReadsAfterNextPersistence()

        let outcome = store.clearBoardOutcome()

        guard case .persistedButRefreshFailed = outcome else {
            return XCTFail("Expected persisted-but-refresh-failed, got \(outcome)")
        }
        XCTAssertEqual(persistence.saveCount, saveCountBeforeClear + 1)
        XCTAssertEqual(store.boardGeneration, generationBeforeClear + 1)
        XCTAssertTrue(store.strokes.isEmpty)
        let boardRows = try ModelContext(container).fetch(
            FetchDescriptor<CanvasBoardItem>()
        )
        XCTAssertTrue(boardRows.allSatisfy {
            $0.clearGeneration == generationBeforeClear + 1
        })
    }

    @MainActor
    func testUndoAppliesRestoredPresentationWhenEveryPostSaveReloadFails() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let persistence = PersistenceGate()
        let replicaReads = CanvasReplicaReadGate()
        let store = CanvasStore(
            container: container,
            persist: { context in
                try persistence.save(context)
                replicaReads.persistenceDidSucceed()
            },
            loadReplicas: replicaReads.load
        )
        let session = CanvasSession(store: store)
        XCTAssertTrue(session.completeStroke(
            points: [CanvasPoint(x: -4, y: 12)]
        ))
        let strokeID = try XCTUnwrap(session.strokes.first?.id)
        XCTAssertTrue(session.clear())
        let clearedGeneration = session.boardGeneration
        replicaReads.failReadsAfterNextPersistence()

        XCTAssertTrue(session.undo())

        XCTAssertEqual(session.strokes.map(\.id), [strokeID])
        XCTAssertEqual(session.strokes.first?.boardGeneration, clearedGeneration)
        XCTAssertTrue(session.canRedo)
        XCTAssertTrue(session.lastErrorMessage?.contains("saved") == true)
        XCTAssertTrue(session.lastErrorMessage?.contains("refresh failed") == true)
        let rows = try ModelContext(container).fetch(FetchDescriptor<CanvasStrokeItem>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.boardGeneration, clearedGeneration)
    }

    @MainActor
    func testNewImageImportStillRejectsPayloadAboveCurrentImportCap() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let oversizedPayload = Data(
            repeating: 0x5A,
            count: CanvasImageImportPolicy.standard.maximumEncodedBytes + 1
        )

        XCTAssertNil(store.addImage(
            CanvasPreparedImage(
                encodedData: oversizedPayload,
                contentType: "public.png",
                pixelWidth: 128,
                pixelHeight: 128
            ),
            center: .zero
        ))

        XCTAssertTrue(store.images.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<CanvasImageItem>()),
            0
        )
    }

    @MainActor
    func testMultiImageRestoreRollsBackEarlierImageWhenLaterImageIsInvalid() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let blockedID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let prepared = CanvasPreparedImage(
            encodedData: Data([0x89, 0x50, 0x4E, 0x47]),
            contentType: "public.png",
            pixelWidth: 80,
            pixelHeight: 40
        )
        let first = try XCTUnwrap(store.addImage(prepared, center: .zero, id: firstID))
        let blocked = try XCTUnwrap(store.addImage(
            prepared,
            center: CanvasPoint(x: 40, y: 20),
            id: blockedID
        ))
        XCTAssertTrue(store.clearBoard())
        let clearedGeneration = store.boardGeneration
        let invalidBlocked = CanvasPlacedImage(
            id: blocked.id,
            canvasID: blocked.canvasID,
            encodedData: Data(),
            contentType: blocked.contentType,
            pixelWidth: blocked.pixelWidth,
            pixelHeight: blocked.pixelHeight,
            transform: blocked.transform,
            boardGeneration: blocked.boardGeneration,
            mutationVersion: blocked.mutationVersion,
            createdAt: blocked.createdAt,
            updatedAt: blocked.updatedAt
        )

        XCTAssertFalse(store.restoreImages([first, invalidBlocked]))

        XCTAssertTrue(store.images.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)
        let rows = try ModelContext(container).fetch(FetchDescriptor<CanvasImageItem>())
        XCTAssertEqual(Set(rows.map(\.id)), [firstID, blockedID])
        XCTAssertTrue(rows.allSatisfy {
            $0.boardGeneration != clearedGeneration
        })
    }

    @MainActor
    func testFailedMultiStrokeRestoreRollsBackEarlierInserts() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let blockedID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let timestamp = Date(timeIntervalSince1970: 10)
        context.insert(CanvasStrokeItem(
            id: blockedID,
            payload: try CanvasStrokeCodec.encode(
                color: .ink,
                width: 3,
                points: [CanvasPoint(x: 2, y: 3)]
            ),
            mutationVersion: Int64.max,
            tombstoned: true,
            createdAt: timestamp,
            updatedAt: timestamp,
            deletedAt: timestamp
        ))
        try context.save()

        let store = CanvasStore(container: container)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let first = CanvasStroke(
            id: firstID,
            color: .blue,
            width: 3,
            points: [CanvasPoint(x: 8, y: 9)]
        )
        let blockedSnapshot = CanvasStroke(
            id: blockedID,
            color: .red,
            width: 4,
            points: [CanvasPoint(x: 12, y: 13)]
        )

        XCTAssertFalse(store.restore([first, blockedSnapshot]))
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)

        let verification = ModelContext(container)
        let rows = try verification.fetch(FetchDescriptor<CanvasStrokeItem>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, blockedID)
        XCTAssertTrue(rows.first?.tombstoned == true)
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

    #if ATTIC_LOCAL_ONLY
    @MainActor
    func testLocalOnlyStoreCreatesNoDeferredCloudInfrastructure() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let initialStatus = store.cloudSyncStatus

        XCTAssertFalse(CanvasCloudInfrastructurePolicy.isEnabled)
        XCTAssertNil(store.remoteChangeObservation)
        XCTAssertNil(store.cloudKitEventObservation)
        XCTAssertNil(store.cloudImportRefreshTask)
        XCTAssertNil(store.exportActivityToken)
        XCTAssertNil(store.importActivityToken)
        XCTAssertNil(store.exportActivityTimeoutTask)
        XCTAssertNil(store.importActivityTimeoutTask)

        store.beginProtectedCloudSyncActivity(for: .exportData)
        store.handleCloudSyncEvent(CloudSyncEventUpdate(
            id: UUID(),
            kind: .importData,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil
        ))
        XCTAssertNotNil(store.addStroke(
            color: .ink,
            width: 3,
            points: [CanvasPoint(x: 12, y: 34)]
        ))

        XCTAssertEqual(store.cloudSyncStatus, initialStatus)
        XCTAssertNil(store.remoteChangeObservation)
        XCTAssertNil(store.cloudKitEventObservation)
        XCTAssertNil(store.cloudImportRefreshTask)
        XCTAssertNil(store.exportActivityToken)
        XCTAssertNil(store.importActivityToken)
        XCTAssertNil(store.exportActivityTimeoutTask)
        XCTAssertNil(store.importActivityTimeoutTask)
    }
    #else
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
    #endif

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

@MainActor
private final class CanvasFreshContextGate {
    struct Failure: LocalizedError {
        var errorDescription: String? {
            "Injected fresh-context reload failure."
        }
    }

    private var shouldFailNextCreation = false

    func failNextContextCreation() {
        shouldFailNextCreation = true
    }

    func makeContext(container: ModelContainer) throws -> ModelContext {
        if shouldFailNextCreation {
            shouldFailNextCreation = false
            throw Failure()
        }
        return ModelContext(container)
    }
}

@MainActor
private final class CanvasReplicaReadGate {
    struct Failure: LocalizedError {
        var errorDescription: String? {
            "Injected post-save Canvas replica read failure."
        }
    }

    private var shouldFailAfterNextPersistence = false
    private var shouldRejectReads = false

    func failReadsAfterNextPersistence() {
        shouldFailAfterNextPersistence = true
    }

    func persistenceDidSucceed() {
        guard shouldFailAfterNextPersistence else { return }
        shouldFailAfterNextPersistence = false
        shouldRejectReads = true
    }

    func load(_ context: ModelContext) throws -> CanvasStoredReplicas {
        guard !shouldRejectReads else { throw Failure() }
        return try CanvasStoredReplicas.load(from: context)
    }
}
