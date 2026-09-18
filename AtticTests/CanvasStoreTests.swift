import Foundation
import SwiftData
import XCTest
@testable import Attic

final class CanvasStoreTests: XCTestCase {
    @MainActor
    func testSemanticTextAtAcceptedLimitSurvivesWorstCaseJSONEscaping() throws {
        let store = try makeTestCanvasStore()
        let text = String(repeating: "\u{0001}", count: 65_536)
        let content = CanvasSemanticContent(text: text, color: .ink, strokeWidth: 3)
        XCTAssertTrue(content.isValid)
        let saved = try XCTUnwrap(store.addSemanticObject(content: content,
            transform: CanvasImageTransform(center: .zero, width: 160, height: 48, zIndex: 0)))
        XCTAssertGreaterThan(saved.payload.count, 131_072)
        XCTAssertEqual(saved.content?.text, text)
        XCTAssertEqual(CanvasStore(container: store.container).semanticObjects.first?.content?.text, text)
        XCTAssertFalse(CanvasSemanticContent(text: text + "x", color: .ink, strokeWidth: 3).isValid)
    }

    @MainActor
    func testSemanticDuplicateMutationFailureDeletionAndRestoreAffectEveryReplica() throws {
        let store = try makeTestCanvasStore()
        let original = try XCTUnwrap(store.addSemanticObject(
            content: CanvasSemanticContent(text: "Original", color: .blue, strokeWidth: 3),
            transform: CanvasImageTransform(center: .zero, width: 120, height: 48, zIndex: 0)))
        let seed = ModelContext(store.container)
        let duplicate = CanvasSemanticObjectItem(id: original.id)
        duplicate.payload = original.payload
        duplicate.mutationVersion = 7
        duplicate.width = 120
        duplicate.height = 48
        seed.insert(duplicate)
        try seed.save()
        let gate = PersistenceGate()
        let editingStore = CanvasStore(container: store.container, persist: gate.save)
        var changed = try XCTUnwrap(editingStore.semanticObjects.first)
        changed.transform.center = CanvasPoint(x: 91, y: -75)
        gate.shouldFail = true
        XCTAssertFalse(editingStore.updateSemanticObject(changed))
        XCTAssertEqual(editingStore.semanticObjects.first?.transform.center, .zero)
        XCTAssertTrue(try ModelContext(store.container).fetch(FetchDescriptor<CanvasSemanticObjectItem>()).allSatisfy { $0.centerX == 0 })
        gate.shouldFail = false
        XCTAssertTrue(editingStore.updateSemanticObject(changed))
        var rows = try ModelContext(store.container).fetch(FetchDescriptor<CanvasSemanticObjectItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.centerX == 91 && $0.centerY == -75 && $0.mutationVersion == 8 })
        XCTAssertTrue(editingStore.deleteSemanticObject(original.id))
        rows = try ModelContext(store.container).fetch(FetchDescriptor<CanvasSemanticObjectItem>())
        XCTAssertTrue(rows.allSatisfy { $0.tombstoned && $0.mutationVersion == 9 })
        var contents = CanvasBoardContents(strokes: [], images: [])
        contents.semanticObjects = [changed]
        XCTAssertTrue(editingStore.restoreBoardContents(contents).succeeded)
        rows = try ModelContext(store.container).fetch(FetchDescriptor<CanvasSemanticObjectItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { !$0.tombstoned && $0.mutationVersion == 10 && $0.payload == original.payload })
    }

    @MainActor
    func testUnknownSemanticPayloadIsRetainedThroughTransformDeleteAndUndo() throws {
        let store = try makeTestCanvasStore()
        let context = ModelContext(store.container)
        let row = CanvasSemanticObjectItem()
        row.kind = "future-chart"
        row.payloadVersion = 92
        row.payload = Data([0, 255, 128, 12])
        let payload = row.payload
        let id = row.id
        context.insert(row)
        try context.save()
        store.refresh()
        let session = CanvasSession(store: store)
        let object = try XCTUnwrap(session.semanticObjects.first)
        XCTAssertNil(object.content)
        XCTAssertEqual(object.title, "Unsupported object")
        session.selectSemanticObject(id)
        XCTAssertTrue(session.nudgeSelectedSemanticObject(CGSize(width: 20, height: 30)))
        XCTAssertTrue(session.deleteSemanticObject(id))
        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.clear())
        XCTAssertTrue(session.undo())
        let saved = try XCTUnwrap(ModelContext(store.container).fetch(FetchDescriptor<CanvasSemanticObjectItem>()).first)
        XCTAssertEqual(saved.payload, payload)
        XCTAssertEqual(saved.payloadVersion, 92)
        XCTAssertEqual(saved.kind, "future-chart")
        XCTAssertFalse(saved.tombstoned)
    }

    @MainActor
    func testCopiedLegacyStoreOpensAdditivelyWithoutRewritingInkOrImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasSchemaFixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        let copyDirectory = root.appendingPathComponent("upgraded", isDirectory: true)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        let strokeID = UUID()
        let imageID = UUID()
        let legacyInk = try CanvasStrokeCodec.encode(color: .red, width: 3, points: [.zero, CanvasPoint(x: 10, y: 20)])
        let legacyImage = Data([12, 11, 10, 9])
        try autoreleasepool {
            let schema = Schema([TaskItem.self, NoteItem.self, NoteAttachment.self, CanvasBoardItem.self, CanvasStrokeItem.self, CanvasImageItem.self])
            let configuration = ModelConfiguration("fixture", schema: schema, url: originalDirectory.appendingPathComponent("fixture.store"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(CanvasBoardItem(clearGeneration: 2))
            for index in 0..<128 {
                context.insert(CanvasStrokeItem(id: index < 2 ? strokeID : UUID(), payload: index == 127 ? Data([255]) : legacyInk,
                    boardGeneration: index == 126 ? 1 : 2, mutationVersion: Int64(index + 1)))
            }
            context.insert(CanvasImageItem(id: imageID, encodedData: legacyImage, pixelWidth: 2, pixelHeight: 2, width: 48, height: 48, boardGeneration: 2))
            try context.save()
        }
        try FileManager.default.copyItem(at: originalDirectory, to: copyDirectory)
        let schema = Schema([TaskItem.self, NoteItem.self, NoteAttachment.self, CanvasBoardItem.self, CanvasStrokeItem.self, CanvasImageItem.self, CanvasSemanticObjectItem.self])
        let configuration = ModelConfiguration("fixture", schema: schema, url: copyDirectory.appendingPathComponent("fixture.store"), cloudKitDatabase: .none)
        let upgraded = try ModelContainer(for: schema, configurations: [configuration])
        let store = CanvasStore(container: upgraded)
        XCTAssertTrue(store.semanticObjects.isEmpty)
        XCTAssertNotNil(store.addSemanticObject(content: CanvasSemanticContent(text: "New semantic text", color: .ink, strokeWidth: 3),
            transform: CanvasImageTransform(center: .zero, width: 160, height: 48, zIndex: 1)))
        let context = ModelContext(upgraded)
        let strokes = try context.fetch(FetchDescriptor<CanvasStrokeItem>())
        XCTAssertEqual(strokes.count, 128)
        XCTAssertEqual(strokes.filter { $0.id == strokeID }.count, 2)
        XCTAssertEqual(strokes.filter { $0.payload == legacyInk }.count, 127)
        XCTAssertEqual(strokes.filter { $0.payload == Data([255]) }.count, 1)
        XCTAssertEqual(strokes.filter { $0.boardGeneration == 1 }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CanvasImageItem>()).first?.encodedData, legacyImage)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CanvasImageItem>()).first?.id, imageID)
    }

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
    func testFailedCreateAndDeleteSavesRestorePreviousSelectionAndKeepSaveError() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let store = CanvasStore(container: container, persist: gate.save)
        let alpha = try XCTUnwrap(store.createCanvas(name: "Alpha"))
        let beta = try XCTUnwrap(store.createCanvas(name: "Beta"))
        let stroke = try XCTUnwrap(store.addStroke(color: .ink, width: 3, points: [.zero, CanvasPoint(x: 9, y: 9)]))
        let saveError = PersistenceGate.Failure().localizedDescription
        gate.shouldFail = true

        XCTAssertNil(store.createCanvas(name: "Gamma"))
        XCTAssertEqual(store.selectedCanvasID, beta.id)
        XCTAssertEqual(store.canvases.map(\.id), [alpha.id, beta.id])
        XCTAssertEqual(store.strokes.map(\.id), [stroke.id])
        XCTAssertEqual(store.lastErrorMessage, saveError)

        XCTAssertFalse(store.deleteCanvas(beta.id))
        XCTAssertEqual(store.selectedCanvasID, beta.id)
        XCTAssertEqual(store.canvases.map(\.id), [alpha.id, beta.id])
        XCTAssertEqual(store.strokes.map(\.id), [stroke.id])
        XCTAssertEqual(store.lastErrorMessage, saveError)

        let verification = ModelContext(container)
        let boards = try verification.fetch(FetchDescriptor<CanvasBoardItem>())
        XCTAssertEqual(Set(boards.map(\.id)), [alpha.id, beta.id])
        XCTAssertTrue(boards.allSatisfy { !$0.tombstoned })
        XCTAssertTrue(try verification.fetch(FetchDescriptor<CanvasStrokeItem>()).allSatisfy { !$0.tombstoned })
    }

    @MainActor
    func testFailedBoardSaveFallsBackWhenPreviousSelectionIsNoLongerLive() throws {
        for operation in ["create", "delete"] {
            let container = try PersistenceController.makeContainer(inMemory: true)
            let gate = PersistenceGate()
            let store = CanvasStore(container: container, persist: gate.save)
            let alpha = try XCTUnwrap(store.createCanvas(name: "Alpha"))
            let beta = try XCTUnwrap(store.createCanvas(name: "Beta"))
            let external = ModelContext(container)
            let board = try XCTUnwrap(external.fetch(FetchDescriptor<CanvasBoardItem>()).first { $0.id == beta.id })
            board.tombstoned = true
            board.mutationVersion += 1
            board.deletedAt = Date(timeIntervalSince1970: 2_000)
            board.updatedAt = Date(timeIntervalSince1970: 2_000)
            try external.save()
            gate.shouldFail = true

            if operation == "create" {
                XCTAssertNil(store.createCanvas(name: "Gamma"), operation)
            } else {
                XCTAssertFalse(store.deleteCanvas(beta.id), operation)
            }
            XCTAssertEqual(store.selectedCanvasID, alpha.id, operation)
            XCTAssertEqual(store.canvases.map(\.id), [alpha.id], operation)
            XCTAssertEqual(store.lastErrorMessage, PersistenceGate.Failure().localizedDescription, operation)
        }
    }

    @MainActor
    func testFailedPreparationOnCreateCanvasRestoresPreviousSelectionAndKeepsPreparationError() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let preparation = CanvasPresentationPreparationGate()
        let store = CanvasStore(container: container, loadReplicas: preparation.load)
        let alpha = try XCTUnwrap(store.createCanvas(name: "Alpha"))
        let beta = try XCTUnwrap(store.createCanvas(name: "Beta"))
        let stroke = try XCTUnwrap(store.addStroke(
            color: .ink,
            width: 3,
            points: [.zero, CanvasPoint(x: 9, y: 9)]
        ))
        let preparationError = "Canvas could not prepare its saved presentation: "
            + CanvasPresentationPreparationGate.Failure().localizedDescription
        preparation.failNextRead()

        XCTAssertNil(store.createCanvas(name: "Gamma"))
        XCTAssertEqual(store.selectedCanvasID, beta.id)
        XCTAssertEqual(store.canvases.map(\.id), [alpha.id, beta.id])
        XCTAssertEqual(store.strokes.map(\.id), [stroke.id])
        XCTAssertEqual(store.lastErrorMessage, preparationError)

        let verification = ModelContext(container)
        let boards = try verification.fetch(FetchDescriptor<CanvasBoardItem>())
        XCTAssertEqual(Set(boards.map(\.id)), [alpha.id, beta.id])
        XCTAssertTrue(boards.allSatisfy { !$0.tombstoned })
    }

    @MainActor
    func testFailedPreparationOnDeleteCanvasRestoresPreviousSelectionAndKeepsPreparationError() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let preparation = CanvasPresentationPreparationGate()
        let store = CanvasStore(container: container, loadReplicas: preparation.load)
        let alpha = try XCTUnwrap(store.createCanvas(name: "Alpha"))
        let beta = try XCTUnwrap(store.createCanvas(name: "Beta"))
        let stroke = try XCTUnwrap(store.addStroke(
            color: .ink,
            width: 3,
            points: [.zero, CanvasPoint(x: 9, y: 9)]
        ))
        let preparationError = "Canvas could not prepare its saved presentation: "
            + CanvasPresentationPreparationGate.Failure().localizedDescription
        preparation.failNextRead()

        XCTAssertFalse(store.deleteCanvas(beta.id))
        XCTAssertEqual(store.selectedCanvasID, beta.id)
        XCTAssertEqual(store.canvases.map(\.id), [alpha.id, beta.id])
        XCTAssertEqual(store.strokes.map(\.id), [stroke.id])
        XCTAssertEqual(store.lastErrorMessage, preparationError)

        let verification = ModelContext(container)
        let boards = try verification.fetch(FetchDescriptor<CanvasBoardItem>())
        XCTAssertEqual(Set(boards.map(\.id)), [alpha.id, beta.id])
        XCTAssertTrue(boards.allSatisfy { !$0.tombstoned })
        XCTAssertTrue(try verification.fetch(FetchDescriptor<CanvasStrokeItem>())
            .allSatisfy { !$0.tombstoned })
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

    // MARK: - PERF-A1 canvas-scoped replica reads

    @MainActor
    func testSameIDReplicaOnAnotherCanvasIsNotShownOrRewrittenBySelectedCanvasMutations() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let otherBoard = UUID()
        let sharedID = UUID()
        seed.insert(CanvasBoardItem(id: CanvasBoardItem.logicalBoardID, name: "Canvas", sortIndex: 0))
        seed.insert(CanvasBoardItem(id: otherBoard, name: "Other", sortIndex: 1))
        for _ in 0..<2 {
            seed.insert(try storedStroke(id: sharedID, points: [.zero, CanvasPoint(x: 4, y: 4)]))
        }
        let foreign = try storedStroke(
            id: sharedID,
            color: .red,
            points: [.zero, CanvasPoint(x: 9, y: 9)],
            mutationVersion: 7
        )
        foreign.canvasID = otherBoard
        seed.insert(foreign)
        try seed.save()

        let store = CanvasStore(container: container)
        XCTAssertEqual(store.selectedCanvasID, CanvasBoardItem.logicalBoardID)
        XCTAssertEqual(store.strokes.map(\.id), [sharedID])
        XCTAssertEqual(store.strokes.first?.color, .ink)

        XCTAssertTrue(store.setDeleted(true, strokeIDs: [sharedID]))
        XCTAssertTrue(store.strokes.isEmpty)
        let verification = ModelContext(container)
        var rows = try verification.fetch(FetchDescriptor<CanvasStrokeItem>())
        var local = rows.filter { $0.canvasID == CanvasBoardItem.logicalBoardID }
        XCTAssertEqual(local.count, 2)
        XCTAssertTrue(local.allSatisfy { $0.tombstoned && $0.mutationVersion == 2 })
        var remote = try XCTUnwrap(rows.first { $0.canvasID == otherBoard })
        XCTAssertFalse(remote.tombstoned)
        XCTAssertEqual(remote.mutationVersion, 7)

        XCTAssertTrue(store.setDeleted(false, strokeIDs: [sharedID]))
        XCTAssertEqual(store.strokes.map(\.id), [sharedID])
        XCTAssertEqual(store.strokes.first?.color, .ink)
        rows = try ModelContext(container).fetch(FetchDescriptor<CanvasStrokeItem>())
        local = rows.filter { $0.canvasID == CanvasBoardItem.logicalBoardID }
        XCTAssertTrue(local.allSatisfy { !$0.tombstoned && $0.mutationVersion == 3 })
        remote = try XCTUnwrap(rows.first { $0.canvasID == otherBoard })
        XCTAssertEqual(remote.mutationVersion, 7)

        XCTAssertTrue(store.selectCanvas(otherBoard))
        XCTAssertEqual(store.strokes.map(\.id), [sharedID])
        XCTAssertEqual(store.strokes.first?.color, .red)
    }

    @MainActor
    func testUnboardedLegacyDefaultContentKeepsTheDefaultCanvasListedFromAnotherCanvas() throws {
        enum LegacyContent: String, CaseIterable {
            case stroke, image, semanticObject, tombstonedStrokeOnly
        }
        let defaultID = CanvasBoardItem.logicalBoardID
        for legacy in LegacyContent.allCases {
            let container = try PersistenceController.makeContainer(inMemory: true)
            let seed = ModelContext(container)
            let otherBoard = UUID()
            // No physical default board row: only content claims the default id.
            seed.insert(CanvasBoardItem(id: otherBoard, name: "Other", sortIndex: 1))
            switch legacy {
            case .stroke:
                seed.insert(try storedStroke(points: [.zero, CanvasPoint(x: 2, y: 2)]))
            case .image:
                seed.insert(CanvasImageItem(
                    encodedData: Data([0x89, 0x50, 0x4E, 0x47]),
                    pixelWidth: 2,
                    pixelHeight: 2
                ))
            case .semanticObject:
                seed.insert(CanvasSemanticObjectItem())
            case .tombstonedStrokeOnly:
                seed.insert(try storedStroke(points: [.zero, CanvasPoint(x: 2, y: 2)], tombstoned: true))
            }
            try seed.save()
            let expectsDefault = legacy != .tombstonedStrokeOnly

            let store = CanvasStore(container: container)
            XCTAssertEqual(store.canvases.contains { $0.id == defaultID }, expectsDefault, legacy.rawValue)
            XCTAssertTrue(store.selectCanvas(otherBoard), legacy.rawValue)
            XCTAssertEqual(store.canvases.contains { $0.id == defaultID }, expectsDefault, legacy.rawValue)

            // Presentation now loads only the other canvas's content, so the
            // default canvas must still be discovered without loading its rows.
            XCTAssertNotNil(store.addStroke(color: .ink, width: 3, points: [.zero, CanvasPoint(x: 1, y: 1)]))
            XCTAssertEqual(store.selectedCanvasID, otherBoard, legacy.rawValue)
            XCTAssertEqual(store.strokes.count, 1, legacy.rawValue)
            XCTAssertEqual(store.canvases.contains { $0.id == defaultID }, expectsDefault, legacy.rawValue)
            XCTAssertEqual(
                CanvasStore(container: container).canvases.contains { $0.id == defaultID },
                expectsDefault,
                legacy.rawValue
            )
            if legacy == .stroke {
                XCTAssertTrue(store.selectCanvas(defaultID))
                XCTAssertEqual(store.strokes.count, 1)
            }
        }
    }

    @MainActor
    func testRefreshAfterSelectedCanvasIsDeletedElsewhereShowsTheFallbackCanvasContent() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let otherBoard = UUID()
        let defaultStroke = try storedStroke(points: [.zero, CanvasPoint(x: 3, y: 3)])
        let otherStroke = try storedStroke(color: .red, points: [.zero, CanvasPoint(x: 5, y: 5)])
        otherStroke.canvasID = otherBoard
        seed.insert(CanvasBoardItem(id: CanvasBoardItem.logicalBoardID, name: "Canvas", sortIndex: 0))
        seed.insert(CanvasBoardItem(id: otherBoard, name: "Other", sortIndex: 1))
        seed.insert(defaultStroke)
        seed.insert(otherStroke)
        try seed.save()
        let defaultStrokeID = defaultStroke.id
        let otherStrokeID = otherStroke.id

        let store = CanvasStore(container: container)
        XCTAssertTrue(store.selectCanvas(otherBoard))
        XCTAssertEqual(store.strokes.map(\.id), [otherStrokeID])

        let external = ModelContext(container)
        let board = try XCTUnwrap(external.fetch(FetchDescriptor<CanvasBoardItem>()).first { $0.id == otherBoard })
        board.tombstoned = true
        board.mutationVersion += 1
        board.deletedAt = Date(timeIntervalSince1970: 2_000)
        board.updatedAt = Date(timeIntervalSince1970: 2_000)
        try external.save()

        store.refresh()

        XCTAssertEqual(store.selectedCanvasID, CanvasBoardItem.logicalBoardID)
        XCTAssertFalse(store.canvases.contains { $0.id == otherBoard })
        XCTAssertEqual(store.strokes.map(\.id), [defaultStrokeID])
        XCTAssertNotNil(store.addStroke(color: .ink, width: 3, points: [.zero, CanvasPoint(x: 6, y: 6)]))
        XCTAssertEqual(store.strokes.count, 2)
        XCTAssertTrue(store.strokes.allSatisfy { $0.canvasID == CanvasBoardItem.logicalBoardID })
    }

    @MainActor
    func testDeletingMoreStrokesThanTheIdentifierPredicateLimitTouchesEveryReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let otherBoard = UUID()
        let count = CanvasStore.replicaIdentifierPredicateLimit + 20
        let ids = (0..<count).map { _ in UUID() }
        let payload = try CanvasStrokeCodec.encode(color: .ink, width: 3, points: [.zero, CanvasPoint(x: 1, y: 1)])
        seed.insert(CanvasBoardItem(id: CanvasBoardItem.logicalBoardID, name: "Canvas", sortIndex: 0))
        seed.insert(CanvasBoardItem(id: otherBoard, name: "Other", sortIndex: 1))
        for (index, id) in ids.enumerated() {
            for _ in 0..<2 {
                seed.insert(CanvasStrokeItem(
                    id: id,
                    payloadVersion: CanvasStrokeCodec.currentVersion,
                    payload: payload,
                    createdAt: Date(timeIntervalSince1970: Double(index))
                ))
            }
        }
        seed.insert(CanvasStrokeItem(id: ids[0], canvasID: otherBoard, payload: payload))
        try seed.save()

        let store = CanvasStore(container: container)
        XCTAssertEqual(store.strokes.count, count)

        for (deleted, version) in [(true, Int64(2)), (false, Int64(3))] {
            XCTAssertTrue(store.setDeleted(deleted, strokeIDs: Set(ids)))
            XCTAssertEqual(store.strokes.count, deleted ? 0 : count)
            let rows = try ModelContext(container).fetch(FetchDescriptor<CanvasStrokeItem>())
            let local = rows.filter { $0.canvasID == CanvasBoardItem.logicalBoardID }
            XCTAssertEqual(local.count, 2 * count)
            XCTAssertTrue(local.allSatisfy { $0.tombstoned == deleted && $0.mutationVersion == version })
            let remote = try XCTUnwrap(rows.first { $0.canvasID == otherBoard })
            XCTAssertFalse(remote.tombstoned)
            XCTAssertEqual(remote.mutationVersion, 1)
        }
    }

    /// `save()` resolves presentation from the pending context before it
    /// persists, so the canvas-scoped predicates must see unsaved changes: an
    /// insert, a `canvasID` move into and out of a predicate, and a tombstone,
    /// through `fetch`, `idList.contains` and `fetchCount` alike.
    @MainActor
    func testCanvasScopedReplicaReadsSeeUnsavedChangesInTheContext() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let boardA = UUID()
        let boardB = UUID()
        let defaultID = CanvasBoardItem.logicalBoardID
        // No physical default board row, so a load from another canvas counts
        // the default canvas's live content instead of fetching it.
        seed.insert(CanvasBoardItem(id: boardA, name: "A", sortIndex: 1))
        seed.insert(CanvasBoardItem(id: boardB, name: "B", sortIndex: 2))
        let legacy = try storedStroke(points: [.zero, CanvasPoint(x: 1, y: 1)])
        let moving = try storedStroke(points: [.zero, CanvasPoint(x: 2, y: 2)])
        moving.canvasID = boardA
        let staying = try storedStroke(points: [.zero, CanvasPoint(x: 3, y: 3)])
        staying.canvasID = boardA
        let existing = try storedStroke(points: [.zero, CanvasPoint(x: 4, y: 4)])
        existing.canvasID = boardB
        for stroke in [legacy, moving, staying, existing] {
            seed.insert(stroke)
        }
        try seed.save()
        let (legacyID, movingID, stayingID, existingID) = (legacy.id, moving.id, staying.id, existing.id)

        let store = CanvasStore(container: container)
        XCTAssertTrue(store.selectCanvas(boardB))
        let context = store.context
        XCTAssertTrue(try CanvasStoredReplicas.load(from: context, contentCanvasID: boardB)
            .hasUnboardedLegacyDefaultContent)

        let inserted = try storedStroke(points: [.zero, CanvasPoint(x: 5, y: 5)])
        inserted.canvasID = boardB
        context.insert(inserted)
        let insertedID = inserted.id
        let pendingMove = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasStrokeItem>(
            predicate: #Predicate { $0.id == movingID }
        )).first)
        pendingMove.canvasID = boardB
        let pendingTombstone = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasStrokeItem>(
            predicate: #Predicate { $0.id == legacyID }
        )).first)
        pendingTombstone.tombstoned = true
        XCTAssertTrue(context.hasChanges)

        func assertReadsSeeTheChanges(in context: ModelContext, _ label: String) throws {
            let onB = try CanvasStoredReplicas.load(from: context, contentCanvasID: boardB)
            XCTAssertEqual(Set(onB.strokes.map(\.id)), [existingID, insertedID, movingID], label)
            XCTAssertFalse(onB.hasUnboardedLegacyDefaultContent, label)
            XCTAssertEqual(
                try CanvasStoredReplicas.load(from: context, contentCanvasID: boardA).strokes.map(\.id),
                [stayingID],
                label
            )
            let idList = [insertedID, movingID, stayingID]
            XCTAssertEqual(Set(try context.fetch(FetchDescriptor<CanvasStrokeItem>(
                predicate: #Predicate { $0.canvasID == boardB && idList.contains($0.id) }
            )).map(\.id)), [insertedID, movingID], label)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<CanvasStrokeItem>(
                predicate: #Predicate { $0.canvasID == defaultID && !$0.tombstoned }
            )), 0, label)
            XCTAssertEqual(try context.fetch(FetchDescriptor<CanvasStrokeItem>(
                predicate: #Predicate { $0.canvasID == defaultID && !$0.tombstoned }
            )).count, 0, label)
        }

        try assertReadsSeeTheChanges(in: context, "pending")
        XCTAssertEqual(
            Set(try store.storedStrokeReplicas(matching: [insertedID, movingID, stayingID]).keys),
            [insertedID, movingID],
            "pending"
        )
        // The changes really are unsaved: another context still sees the store.
        let unsaved = try CanvasStoredReplicas.load(from: ModelContext(container), contentCanvasID: boardB)
        XCTAssertEqual(unsaved.strokes.map(\.id), [existingID])
        XCTAssertTrue(unsaved.hasUnboardedLegacyDefaultContent)

        try context.save()
        try assertReadsSeeTheChanges(in: ModelContext(container), "saved")
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

    func load(_ context: ModelContext, contentCanvasID: UUID) throws -> CanvasStoredReplicas {
        guard !shouldRejectReads else { throw Failure() }
        return try CanvasStoredReplicas.load(from: context, contentCanvasID: contentCanvasID)
    }
}

/// Drives the presentation-preparation failure arm of
/// `save(restoringSelectionOnFailure:)`. `save()` resolves the pending
/// mutation through the injectable `loadReplicas` seam before it persists, so
/// one injected read failure throws there; the reload that follows the restore
/// reads normally again. No production seam is added or changed.
@MainActor
private final class CanvasPresentationPreparationGate {
    struct Failure: LocalizedError {
        var errorDescription: String? {
            "Injected presentation-preparation failure."
        }
    }

    private var failsNextRead = false

    func failNextRead() {
        failsNextRead = true
    }

    func load(_ context: ModelContext, contentCanvasID: UUID) throws -> CanvasStoredReplicas {
        if failsNextRead {
            failsNextRead = false
            throw Failure()
        }
        return try CanvasStoredReplicas.load(from: context, contentCanvasID: contentCanvasID)
    }
}
