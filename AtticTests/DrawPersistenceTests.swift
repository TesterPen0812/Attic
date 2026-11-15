import CoreData
import Foundation
import SwiftData
import SQLite3
import XCTest
@testable import Attic

@MainActor
final class DrawPersistenceTests: XCTestCase {
    private struct Injected: Error {}

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DrawTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        return root
    }

    private func container(at root: URL? = nil) throws -> ModelContainer {
        if let root {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return try ModelContainer(for: Schema(PersistenceController.appModelTypes), configurations:
                ModelConfiguration(url: root.appendingPathComponent("draw.store"), cloudKitDatabase: .none))
        }
        return try ModelContainer(for: Schema(PersistenceController.appModelTypes), configurations:
            ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    func testPersistentContract() throws {
        try DrawStoreContractTests().contract(DrawPersistentStore(container: container()))
        try DrawStoreContractTests().tagContract(DrawPersistentStore(container: container()))
    }

    func testDA4PersistentSavedAgentUndoKeepsEarlierOwnerInkReachable() throws {
        let store = DrawPersistentStore(container: try container())
        let board = store.create(name: "Owner and agent")
        let ink = DrawObject(content: .stroke([DrawPoint(x: 10, y: 10)]))
        let rectangle = DrawObject(content: .shape(.rectangle))
        XCTAssertTrue(store.perform(.put([ink]), on: board.id).isSaved)
        XCTAssertTrue(store.perform(.put([rectangle]), on: board.id).isSaved)
        let stepID = try XCTUnwrap(store.undoStepID(on: board.id))
        let proof = try XCTUnwrap(store.agentUndoProof(on: board.id, stepID: stepID))

        XCTAssertTrue(store.undoAgentStep(on: board.id, proof: proof).isSaved)
        XCTAssertEqual(try store.open(board.id).objects.map(\.id), [ink.id])
        XCTAssertTrue(store.undo(on: board.id).isSaved, "Restore the agent rectangle")
        XCTAssertEqual(Set(try store.open(board.id).objects.map(\.id)), Set([ink.id, rectangle.id]))
        XCTAssertTrue(store.undo(on: board.id).isSaved, "Remove the agent rectangle")
        XCTAssertTrue(store.undo(on: board.id).isSaved, "Remove the owner's ink")
        XCTAssertTrue(try store.open(board.id).objects.isEmpty)
    }

    func testPersistentClipboardContract() throws {
        try DrawStoreContractTests().clipboardContract(DrawPersistentStore(container: container()))
    }

    func testPersistentTypingAndDeletedImagesContract() throws {
        try DrawStoreContractTests().typingContract(DrawPersistentStore(container: container()))
    }

    func testTextSavedDuringEditingSurvivesAnUncleanRelaunch() throws {
        let root = try temporaryDirectory()
        var canvasID = UUID()
        try autoreleasepool {
            let store = DrawPersistentStore(container: try container(at: root))
            let model = DrawPageModel(store: store)
            model.start()
            canvasID = try XCTUnwrap(model.canvasID)
            model.setTool(.text)
            model.pointerDown(at: CGPoint(x: 80, y: 120))
            model.typed("Draft")
            model.typed("Draft 👩🏽‍🚀")
            // An unclean relaunch after the bounded 250 ms typing window
            // still has the most recent durable text, without blur or quit.
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            XCTAssertNotNil(model.editing, "No blur or graceful shutdown should be needed to save text")
            XCTAssertFalse(store.hasUnsettledEdits)
            XCTAssertEqual(try store.open(canvasID).objects.map(\.text), ["Draft 👩🏽‍🚀"])
        }

        let reopened = DrawPersistentStore(container: try container(at: root))
        XCTAssertEqual(try reopened.open(canvasID).objects.map(\.text), ["Draft 👩🏽‍🚀"])
        XCTAssertFalse(reopened.canUndo(on: canvasID), "Undo history is session-scoped")
    }

    func testFinishedInkSurvivesUncleanRelaunchWhileUnfinishedInkWasNeverCommitted() throws {
        let root = try temporaryDirectory()
        var canvasID = UUID()
        var completed: [DrawObject] = []
        try autoreleasepool {
            let store = DrawPersistentStore(container: try container(at: root))
            let model = DrawPageModel(store: store)
            model.start()
            canvasID = try XCTUnwrap(model.canvasID)
            model.pointerDown(at: CGPoint(x: 20, y: 60), pressure: 0.3)
            model.pointerDragged(to: CGPoint(x: 50, y: 80), pressure: 0.7)
            model.pointerUp(at: CGPoint(x: 90, y: 60), pressure: 1)
            XCTAssertEqual(model.objects.count, 1, "Completed ink is visible on mouse-up")
            // A crash before the queued checkpoint can lose this stroke.
            // Explicitly settle it to test a crash after the durable boundary.
            model.flushAcknowledgedDraw()
            completed = try store.open(canvasID).objects
            XCTAssertEqual(completed.count, 1)
            XCTAssertFalse(store.hasUnsettledEdits)
            // Simulate a kill before mouse-up. Never run the graceful-quit
            // path (which deliberately finishes the active second stroke).
            model.pointerDown(at: CGPoint(x: 20, y: 120))
            model.pointerDragged(to: CGPoint(x: 50, y: 140))
            XCTAssertEqual(try store.open(canvasID).objects, completed)
        }

        let relaunched = DrawPersistentStore(container: try container(at: root))
        XCTAssertEqual(try relaunched.open(canvasID).objects, completed,
                       "a saved stroke survives unclean termination, unfinished input was never saved")
        XCTAssertFalse(relaunched.canUndo(on: canvasID), "history is session-scoped; saved ink survives a relaunch")
        guard case .stroke(let samples) = completed[0].content else { return XCTFail("Stored object is not a stroke") }
        XCTAssertEqual(samples.first?.pressure, 0.3)
        XCTAssertEqual(samples.last?.pressure, 1)
    }

    func testFailedFirstSaveRollsBackKeepsDraftAndRetriesOnce() throws {
        let container = try container()
        var fail = true
        let store = DrawPersistentStore(container: container, save: { context in
            XCTAssertFalse(context.autosaveEnabled)
            if fail { throw Injected() }
            try context.save()
        })
        let board = store.create()
        let stroke = DrawObject(content: .stroke([DrawPoint(x: 2, y: 3)]))
        guard case .retry = store.perform(.put([stroke]), on: board.id) else { return XCTFail("Expected Retry") }
        XCTAssertTrue(store.hasUnsettledEdits)
        XCTAssertEqual(try store.open(board.id).objects, [stroke])
        XCTAssertEqual(store.revision, 0)
        XCTAssertFalse(store.canUndo(on: board.id))
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<DrawCanvasRecord>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<DrawObjectRecord>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<DrawPayloadRecord>()), 0)
        fail = false
        XCTAssertTrue(store.retry(on: board.id).isSaved)
        XCTAssertEqual(store.revision, 1)
        XCTAssertTrue(store.canUndo(on: board.id))
        XCTAssertFalse(store.hasUnsettledEdits)
        XCTAssertEqual(store.retry(on: board.id), .unchanged)
        XCTAssertEqual(try DrawPersistentStore(container: container).open(board.id).objects, [stroke])
    }

    func testFailedDrawImageRefusesLaterEditAndRecoversAfterDiskRelaunch() throws {
        let root = try temporaryDirectory()
        let image = DrawObject(content: .image(DrawImage(
            original: Data((0...255).map(UInt8.init)), pixelWidth: 32, pixelHeight: 8
        )))
        var boardID = UUID()
        try autoreleasepool {
            let store = DrawPersistentStore(container: try container(at: root), save: { _ in throw Injected() })
            boardID = store.create(name: "Draft").id
            guard case .retry = store.perform(.put([image]), on: boardID) else { return XCTFail("Expected failed save") }
            guard case .held = store.perform(.rename("Refused"), on: boardID) else { return XCTFail("Expected refused edit") }
            XCTAssertEqual(store.pendingEdits[boardID]?.count, 1)
            XCTAssertEqual(try store.open(boardID).objects, [image])
        }

        try autoreleasepool {
            let store = DrawPersistentStore(container: try container(at: root))
            XCTAssertTrue(store.hasUnsettledEdits, "relaunch must not discard the failed edit")
            XCTAssertEqual(store.pendingEdits[boardID]?.count, 1)
            XCTAssertEqual(try store.open(boardID).objects, [image], "the image's original bytes survive recovery")
            XCTAssertEqual(try store.open(boardID).canvas.name, "Draft")
            XCTAssertTrue(try store.library().contains { $0.id == boardID }, "the recovery must be reachable")
            XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<DrawCanvasRecord>()), 0)
            XCTAssertTrue(store.retry(on: boardID).isSaved)
            XCTAssertFalse(store.hasUnsettledEdits)
        }
        let finished = DrawPersistentStore(container: try container(at: root))
        XCTAssertEqual(try finished.open(boardID).objects, [image])
        XCTAssertEqual(try finished.open(boardID).canvas.name, "Draft")
        XCTAssertFalse(finished.hasUnsettledEdits)
    }

    func testMixedDrawSaveStaysHeldAfterRelaunchUntilFreshPhysicalRowsProveIt() throws {
        let root = try temporaryDirectory()
        let persistentContainer = try container(at: root)
        var mix = false
        var boardID = UUID()
        try autoreleasepool {
            let store = DrawPersistentStore(container: persistentContainer, save: { context in
                try context.save()
                if mix {
                    let external = ModelContext(persistentContainer)
                    external.autosaveEnabled = false
                    try XCTUnwrap(external.fetch(FetchDescriptor<DrawCanvasRecord>()).first).name = "External conflict"
                    try external.save()
                    throw Injected()
                }
            })
            boardID = store.create(name: "Before").id
            XCTAssertTrue(store.perform(.put([DrawObject(content: .text("saved"))]), on: boardID).isSaved)
            mix = true
            guard case .held = store.perform(.rename("After"), on: boardID) else { return XCTFail("Expected ambiguous hold") }
        }

        let recovered = DrawPersistentStore(container: try container(at: root))
        XCTAssertEqual(try recovered.open(boardID).canvas.name, "After")
        guard case .held = recovered.pendingEdits[boardID]?.outcome else { return XCTFail("Recovered edit must stay held") }
        guard case .held = recovered.retry(on: boardID) else { return XCTFail("Cannot overwrite mixed physical rows") }
        let repair = ModelContext(recovered.container)
        repair.autosaveEnabled = false
        try XCTUnwrap(repair.fetch(FetchDescriptor<DrawCanvasRecord>()).first).name = "After"
        try repair.save()
        XCTAssertTrue(recovered.reconcile(on: boardID).isSaved)
        XCTAssertFalse(recovered.hasUnsettledEdits)
    }

    func testUnreadableRecoveryCheckpointCannotPurgeDrawData() throws {
        let root = try temporaryDirectory()
        let original = DrawPersistentStore(container: try container(at: root))
        let canvas = original.create(name: "Keep this drawing")
        XCTAssertTrue(original.perform(.put([DrawObject(content: .text("keep"))]), on: canvas.id).isSaved)
        XCTAssertTrue(original.perform(.deleteCanvas, on: canvas.id).isSaved)
        let deletedAt = try XCTUnwrap(original.open(canvas.id).canvas.deletedAt)
        let checkpoint = root.appendingPathComponent("DrawRecovery-v1.json")
        let unreadable = Data("{invalid recovery".utf8)
        try unreadable.write(to: checkpoint, options: .atomic)

        let relaunched = DrawPersistentStore(container: try container(at: root))
        XCTAssertNotNil(relaunched.recoveryIssue)
        XCTAssertTrue(relaunched.hasUnsettledEdits)
        let purged = relaunched.purge([.canvas(canvas.id, deletedAt: deletedAt)])
        XCTAssertEqual(purged.removed, 0, "unknown recovery ownership must block irreversible purges")
        XCTAssertEqual(purged.kept, 1)
        XCTAssertNotNil(try relaunched.open(canvas.id).canvas.deletedAt)
        XCTAssertEqual(try Data(contentsOf: checkpoint), unreadable, "preserve the damaged checkpoint")
    }

    func testRecoveryCheckpointWithoutSessionHistoryIDsStillReopens() throws {
        let root = try temporaryDirectory()
        let object = DrawObject(content: .text("recover from older checkpoint"))
        var canvasID = UUID()
        try autoreleasepool {
            let store = DrawPersistentStore(container: try container(at: root), save: { _ in throw Injected() })
            canvasID = store.create(name: "Draft").id
            guard case .retry = store.perform(.put([object]), on: canvasID) else { return XCTFail("Expected failed save") }
        }

        // D-02 checkpoints precede D-04's in-session history identifiers.
        // Removing that field simulates the existing on-disk format.
        func withoutHistoryIDs(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if object["beforePersisted"] != nil, object["afterPersisted"] != nil {
                    object["id"] = nil
                }
                for (key, part) in object { object[key] = withoutHistoryIDs(part) }
                return object
            }
            if let values = value as? [Any] { return values.map(withoutHistoryIDs) }
            return value
        }
        let checkpoint = root.appendingPathComponent("DrawRecovery-v1.json")
        let archive = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint))
        try JSONSerialization.data(withJSONObject: withoutHistoryIDs(archive)).write(to: checkpoint, options: .atomic)

        let relaunched = DrawPersistentStore(container: try container(at: root))
        XCTAssertNil(relaunched.recoveryIssue, "D-04 must not invalidate D-02's recovery files")
        XCTAssertTrue(relaunched.hasUnsettledEdits)
        XCTAssertEqual(try relaunched.open(canvasID).objects, [object])
    }

    func testThrowAfterSavePublishesExactAfterOnce() throws {
        let container = try container()
        let store = DrawPersistentStore(container: container, save: { context in
            try context.save()
            throw Injected()
        })
        let board = store.create()
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("finished"))]), on: board.id).isSaved)
        XCTAssertEqual(store.revision, 1)
        XCTAssertTrue(store.canUndo(on: board.id))
        XCTAssertEqual(store.reconcile(on: board.id), .unchanged)
        XCTAssertEqual(store.revision, 1)
    }

    func testMixedOutcomeHoldsAndCannotRetryOrAdvanceHistory() throws {
        let container = try container()
        var interfere = false
        let store = DrawPersistentStore(container: container, save: { context in
            try context.save()
            if interfere {
                let other = ModelContext(container)
                other.autosaveEnabled = false
                let row = try XCTUnwrap(other.fetch(FetchDescriptor<DrawCanvasRecord>()).first)
                row.name = "External mixture"
                try other.save()
                throw Injected()
            }
        })
        let board = store.create()
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("before"))]), on: board.id).isSaved)
        interfere = true
        guard case .held = store.perform(.rename("after"), on: board.id) else { return XCTFail("Expected hold") }
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(try store.open(board.id).canvas.name, "after")
        XCTAssertFalse(store.canUndo(on: board.id))
        guard case .held = store.retry(on: board.id) else { return XCTFail("Cannot blindly Retry mixed state") }
        guard case .held = store.reconcile(on: board.id) else { return XCTFail("Mixed state remains held") }
        XCTAssertThrowsError(try store.reload(board.id))
        let repaired = ModelContext(container)
        repaired.autosaveEnabled = false
        try XCTUnwrap(repaired.fetch(FetchDescriptor<DrawCanvasRecord>()).first).name = "after"
        try repaired.save()
        XCTAssertTrue(store.reconcile(on: board.id).isSaved)
        XCTAssertEqual(store.revision, 2)
        XCTAssertEqual(store.reconcile(on: board.id), .unchanged)
    }

    func testUnreadableOutcomeHoldsUntilFreshReadCanProveAfterState() throws {
        let container = try container()
        let store = DrawPersistentStore(container: container, save: { context in
            try context.save()
            let other = ModelContext(container)
            other.autosaveEnabled = false
            try XCTUnwrap(other.fetch(FetchDescriptor<DrawCanvasRecord>()).first).tagsJSON = "unreadable"
            try other.save()
            throw Injected()
        })
        let board = store.create()
        guard case .held = store.perform(.put([DrawObject(content: .text("draft"))]), on: board.id) else { return XCTFail("Expected hold") }
        XCTAssertEqual(store.revision, 0)
        let repair = ModelContext(container)
        repair.autosaveEnabled = false
        try XCTUnwrap(repair.fetch(FetchDescriptor<DrawCanvasRecord>()).first).tagsJSON = "[]"
        try repair.save()
        XCTAssertTrue(store.reconcile(on: board.id).isSaved)
        XCTAssertEqual(store.revision, 1)
    }

    func testEveryPhysicalReplicaIsMutatedDeletedAndRestored() throws {
        let container = try container()
        let store = DrawPersistentStore(container: container)
        let board = store.create(name: "One")
        var object = DrawObject(content: .text("old"))
        XCTAssertTrue(store.perform(.put([object]), on: board.id).isSaved)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let canvas = try XCTUnwrap(context.fetch(FetchDescriptor<DrawCanvasRecord>()).first)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<DrawObjectRecord>()).first)
        context.insert(canvas.replica())
        context.insert(row.replica())
        try context.save()
        object.content = .text("new")
        XCTAssertTrue(store.perform(.put([object]), on: board.id).isSaved)
        XCTAssertTrue(store.perform(.rename("Renamed"), on: board.id).isSaved)
        XCTAssertTrue(store.perform(.remove([object.id]), on: board.id).isSaved)
        var fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<DrawObjectRecord>()).count, 2)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<DrawObjectRecord>()).allSatisfy { $0.deletedAt != nil && $0.textIndex == "new" })
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<DrawCanvasRecord>()).allSatisfy { $0.name == "Renamed" })
        XCTAssertEqual(try store.library().count, 1)
        XCTAssertTrue(store.perform(.restoreObjects([object.id]), on: board.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: board.id).isSaved)
        fresh = ModelContext(container)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<DrawCanvasRecord>()).allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(store.perform(.restoreCanvas, on: board.id).isSaved)
        XCTAssertEqual(try DrawPersistentStore(container: container).open(board.id).objects, [object])
    }

    func testMutationsIncludeSameUUIDWithDivergentParent() throws {
        let container = try container()
        let store = DrawPersistentStore(container: container)
        let board = store.create()
        var object = DrawObject(content: .text("old"))
        XCTAssertTrue(store.perform(.put([object]), on: board.id).isSaved)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let replica = try XCTUnwrap(context.fetch(FetchDescriptor<DrawObjectRecord>()).first).replica()
        replica.canvasID = UUID()
        context.insert(replica)
        try context.save()
        object.content = .text("new")
        XCTAssertTrue(store.perform(.put([object]), on: board.id).isSaved)
        XCTAssertTrue(store.perform(.remove([object.id]), on: board.id).isSaved)
        let fresh = ModelContext(container)
        let rows = try fresh.fetch(FetchDescriptor<DrawObjectRecord>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.canvasID == board.id && $0.textIndex == "new" && $0.deletedAt != nil })
    }

    func testFinishedStrokeAndExactImageSurviveReopeningSameFile() throws {
        let root = try temporaryDirectory()
        let id = UUID()
        let stroke = DrawObject(content: .stroke([DrawPoint(x: 0.125, y: -90), DrawPoint(x: 4, y: 5)]))
        let image = DrawObject(content: .image(DrawImage(original: Data((0...255).map(UInt8.init)), pixelWidth: 40, pixelHeight: 20)))
        var boardID: UUID = id
        try autoreleasepool {
            let store = DrawPersistentStore(container: try container(at: root))
            boardID = store.create(name: "Durable").id
            XCTAssertTrue(store.perform(.put([stroke, image]), on: boardID).isSaved)
        }
        try autoreleasepool {
            let store = DrawPersistentStore(container: try container(at: root))
            let snapshot = try store.open(boardID)
            XCTAssertEqual(Set(snapshot.objects.map(\.id)), [stroke.id, image.id])
            XCTAssertEqual(snapshot.objects.first { $0.id == stroke.id }, stroke)
            XCTAssertEqual(snapshot.objects.first { $0.id == image.id }, image)
        }
    }

    func testFailedUndoKeepsHistoryUntilRetryAndReloadUsesFreshValues() throws {
        let container = try container()
        var fail = false
        let store = DrawPersistentStore(container: container, save: { context in
            if fail { throw Injected() }; try context.save()
        })
        let board = store.create()
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("a"))]), on: board.id).isSaved)
        XCTAssertTrue(store.perform(.rename("b"), on: board.id).isSaved)
        fail = true
        guard case .retry = store.undo(on: board.id) else { return XCTFail("Expected Retry") }
        XCTAssertEqual(store.revision, 2)
        fail = false
        XCTAssertTrue(store.retry(on: board.id).isSaved)
        XCTAssertTrue(store.canRedo(on: board.id))
        let external = DrawPersistentStore(container: container)
        XCTAssertTrue(external.perform(.rename("imported"), on: board.id).isSaved)
        try store.reload(board.id)
        XCTAssertEqual(try store.open(board.id).canvas.name, "imported")
        XCTAssertFalse(store.canRedo(on: board.id))
    }

    func testDuplicatePayloadReplicasRetainExactBytesThroughDeleteAndRestore() throws {
        let container = try container()
        let store = DrawPersistentStore(container: container)
        let board = store.create()
        var image = DrawObject(content: .image(DrawImage(original: Data([1, 2, 3]), pixelWidth: 3, pixelHeight: 1)))
        XCTAssertTrue(store.perform(.put([image]), on: board.id).isSaved)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(try XCTUnwrap(context.fetch(FetchDescriptor<DrawPayloadRecord>()).first).replica())
        context.insert(try XCTUnwrap(context.fetch(FetchDescriptor<DrawObjectRecord>()).first).replica())
        try context.save()
        image.content = .image(DrawImage(original: Data([255, 0, 9]), pixelWidth: 3, pixelHeight: 1))
        XCTAssertTrue(store.perform(.put([image]), on: board.id).isSaved)
        XCTAssertTrue(store.perform(.remove([image.id]), on: board.id).isSaved)
        XCTAssertEqual(try store.deletedImages(in: board.id).first?.content, image.content)
        XCTAssertTrue(store.perform(.restoreObjects([image.id]), on: board.id).isSaved)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<DrawPayloadRecord>()).count, 2)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<DrawPayloadRecord>()).allSatisfy { $0.bytes == Data([255, 0, 9]) })
    }

    func testDivergentBinaryReplicasPresentTheSameWinnerRegardlessOfInsertionOrder() throws {
        let originals = [Data([1]), Data([2])].sorted { DrawCodec.digest($0) < DrawCodec.digest($1) }
        for order in [originals, originals.reversed().map { $0 }] {
            let container = try container()
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let canvas = DrawCanvas()
            let board = DrawCanvasRecord()
            try board.apply(canvas); context.insert(board)
            let id = UUID()
            for original in order {
                let object = DrawObject(id: id, content: .image(DrawImage(original: original, pixelWidth: 1, pixelHeight: 1)))
                let row = DrawObjectRecord(); try row.apply(object, canvasID: canvas.id); context.insert(row)
                let payload = DrawPayloadRecord(); payload.apply(original, id: id, canvasID: canvas.id, role: "object"); context.insert(payload)
            }
            try context.save()
            let store = DrawPersistentStore(container: container)
            XCTAssertEqual(try store.open(canvas.id).objects.first?.content,
                           .image(DrawImage(original: try XCTUnwrap(originals.last), pixelWidth: 1, pixelHeight: 1)))
        }
    }

    func testOldCanvasRowsRemainByteForByteUnchanged() throws {
        let container = try container()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let board = CanvasBoardItem(name: "Old #untouched", sortIndex: 42)
        board.tagsRaw = "old tags"; board.clearGeneration = 19; board.deletedContentCount = 2
        let stroke = CanvasStrokeItem(canvasID: board.id, payload: Data([255, 0, 99]))
        let image = CanvasImageItem(canvasID: board.id, encodedData: Data([1, 0, 2]), pixelWidth: 3, pixelHeight: 1)
        let semantic = CanvasSemanticObjectItem(canvasID: board.id)
        semantic.payload = Data([5, 6]); semantic.kind = "legacy"
        context.insert(board); context.insert(stroke); context.insert(image); context.insert(semantic)
        try context.save()
        func bytes() throws -> Data {
            let fresh = ModelContext(container)
            // All persisted attributes, including raw payloads and bookkeeping.
            let boards = try fresh.fetch(FetchDescriptor<CanvasBoardItem>()).map { row in
                [row.id.uuidString, row.name, String(row.sortIndex), String(row.formatVersion), String(row.clearGeneration), String(row.mutationVersion), String(row.tombstoned), String(row.createdAt.timeIntervalSinceReferenceDate.bitPattern), String(row.updatedAt.timeIntervalSinceReferenceDate.bitPattern), row.deletedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil", row.tagsRaw, row.purgedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil", row.recentlyDeletedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil", String(describing: row.deletedContentCount)]
            }
            let strokes = try fresh.fetch(FetchDescriptor<CanvasStrokeItem>()).map { row in
                [row.id.uuidString, row.canvasID.uuidString, String(row.payloadVersion), row.payload.base64EncodedString(), String(row.boardGeneration), String(row.mutationVersion), String(row.tombstoned), String(row.createdAt.timeIntervalSinceReferenceDate.bitPattern), String(row.updatedAt.timeIntervalSinceReferenceDate.bitPattern), row.deletedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil"]
            }
            let images = try fresh.fetch(FetchDescriptor<CanvasImageItem>()).map { row in
                [row.id.uuidString, row.canvasID.uuidString, row.encodedData.base64EncodedString(), String(row.encodedByteCount), row.contentDigest, row.contentType, String(row.pixelWidth), String(row.pixelHeight), String(row.centerX), String(row.centerY), String(row.width), String(row.height), String(row.zIndex), String(row.boardGeneration), String(row.mutationVersion), String(row.tombstoned), String(row.createdAt.timeIntervalSinceReferenceDate.bitPattern), String(row.updatedAt.timeIntervalSinceReferenceDate.bitPattern), row.deletedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil"]
            }
            let semantics = try fresh.fetch(FetchDescriptor<CanvasSemanticObjectItem>()).map { row in
                [row.id.uuidString, row.canvasID.uuidString, row.kind, String(row.payloadVersion), row.payload.base64EncodedString(), String(row.centerX), String(row.centerY), String(row.width), String(row.height), String(row.rotation), String(row.zIndex), String(row.boardGeneration), String(row.mutationVersion), String(row.tombstoned), String(row.createdAt.timeIntervalSinceReferenceDate.bitPattern), String(row.updatedAt.timeIntervalSinceReferenceDate.bitPattern), row.deletedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil"]
            }
            return try JSONSerialization.data(withJSONObject: [boards, strokes, images, semantics], options: [.sortedKeys])
        }
        let before = try bytes()
        let store = DrawPersistentStore(container: container)
        XCTAssertTrue(try store.library().isEmpty)
        let new = store.create()
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("new"))]), on: new.id).isSaved)
        _ = try store.search("new")
        _ = try store.duplicate(new.id)
        XCTAssertTrue(store.perform(.deleteCanvas, on: new.id).isSaved)
        XCTAssertTrue(store.perform(.restoreCanvas, on: new.id).isSaved)
        XCTAssertEqual(try bytes(), before)
    }

    func testSaveCostIsChangedOnlyAtZeroTwoThousandAndTenThousandObjects() throws {
        for count in [0, 2_000, 10_000] {
            let container = try container()
            let store = DrawPersistentStore(container: container)
            let board = store.create()
            if count > 0 {
                XCTAssertTrue(store.perform(.put((0..<count).map { DrawObject(zIndex: Int64($0), content: .shape(.rectangle)) }), on: board.id).isSaved)
            }
            store.metrics.reset()
            let stroke = DrawObject(content: .stroke([DrawPoint(x: 1, y: 2)]))
            XCTAssertTrue(store.perform(.put([stroke]), on: board.id).isSaved)
            XCTAssertEqual(store.metrics.saveAttempts, 1)
            XCTAssertEqual(store.metrics.objectRowsRead, 0, "\(count): untouched objects must not be fetched")
            XCTAssertEqual(store.metrics.payloadBytesRead, 0)
            XCTAssertEqual(store.metrics.objectRowsWritten, 1)
            XCTAssertEqual(store.metrics.payloadRowsWritten, 1)
            store.metrics.reset()
            XCTAssertEqual(try store.library().count, 1)
            _ = try store.search("missing")
            XCTAssertEqual(store.metrics.objectRowsRead, 0)
            XCTAssertEqual(store.metrics.payloadBytesRead, 0)
        }
    }

    func testStyleChangesDoNotMaterialiseOrRewriteUnchangedOriginals() throws {
        let store = DrawPersistentStore(container: try container())
        let board = store.create()
        var image = DrawObject(content: .image(DrawImage(original: Data(repeating: 29, count: 1_000_000), pixelWidth: 1000, pixelHeight: 1000)))
        var stroke = DrawObject(content: .stroke((0..<400).map { DrawPoint(x: Double($0), y: Double($0)) }))
        XCTAssertTrue(store.perform(.put([image, stroke]), on: board.id).isSaved)
        store.metrics.reset()
        image.style.colour = .orange; stroke.style.size = .large
        XCTAssertTrue(store.perform(.put([image, stroke]), on: board.id).isSaved)
        XCTAssertEqual(store.metrics.objectRowsRead, 2)
        XCTAssertEqual(store.metrics.objectRowsWritten, 2)
        XCTAssertEqual(store.metrics.payloadBytesRead, 0)
        XCTAssertEqual(store.metrics.payloadRowsWritten, 0)
    }

    func testSQLChangedFamilyLookupsUseIndexesAndLibraryTableHasNoBinaryBodies() throws {
        let root = try temporaryDirectory()
        let store = DrawPersistentStore(container: try container(at: root))
        let board = store.create()
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("index"))]), on: board.id).isSaved)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("draw.store").path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        func query(_ sql: String) throws -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "DrawSQL", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
            }
            defer { sqlite3_finalize(statement) }
            var rows: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "NULL"
                }.joined(separator: " | "))
            }
            return rows
        }
        for sql in [
            "EXPLAIN QUERY PLAN SELECT Z_PK FROM ZDRAWCANVASRECORD WHERE ZID = X'00'",
            "EXPLAIN QUERY PLAN SELECT Z_PK FROM ZDRAWOBJECTRECORD WHERE ZID IN (X'01')",
            "EXPLAIN QUERY PLAN SELECT Z_PK FROM ZDRAWOBJECTRECORD WHERE ZCANVASID = X'00' AND ZID IN (X'01')",
            "EXPLAIN QUERY PLAN SELECT Z_PK FROM ZDRAWPAYLOADRECORD WHERE ZROLE = 'object' AND ZID IN (X'01')",
            "EXPLAIN QUERY PLAN SELECT Z_PK FROM ZDRAWPAYLOADRECORD WHERE ZCANVASID = X'00' AND ZROLE = 'object' AND ZID IN (X'01')"
        ] {
            let plan = try query(sql).joined(separator: "\n")
            XCTAssertTrue(plan.contains("SEARCH") && plan.contains("INDEX"), plan)
            XCTAssertFalse(plan.contains("SCAN"), plan)
        }
        let columns = try query("SELECT name, type FROM pragma_table_info('ZDRAWCANVASRECORD')")
        XCTAssertTrue(columns.filter { $0.contains("BLOB") }.allSatisfy {
            $0.hasPrefix("ZID |") || $0.hasPrefix("ZTHUMBNAILID |")
        }, "Only UUIDs may be binary in library metadata: \(columns)")
    }
}

// Round 6: each checkpoint test uses an actual SQLite-backed store and
// deliberately drops its owner rather than calling a clean shutdown path.
extension DrawPersistenceTests {
    func testR6DS2AFailedWriteFreezesEveryDrawMutationWithoutGrowingItsTail() throws {
        let root = try temporaryDirectory()
        let container = try container(at: root)
        var fail = false
        let store = DrawPersistentStore(container: container, save: { context in
            if fail { throw Injected() }
            try context.save()
        })
        let first = store.create(name: "First")
        let other = store.create(name: "Other")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("before"))]), on: other.id).isSaved)
        XCTAssertTrue(store.perform(.saveCanvas, on: first.id).isSaved)
        fail = true
        guard case .retry = store.perform(.rename("held"), on: first.id) else {
            return XCTFail("A failed save should own an unresolved operation")
        }
        XCTAssertEqual(DrawPageModel(store: store).saveNotice?.message, store.admissionRefusalMessage,
                       "An ordinary frozen save must show Draw's exact Retry notice")
        let before = try store.open(other.id)
        let attempts = store.metrics.saveAttempts
        let journal = root.appendingPathComponent("DrawRecovery-v1.json")
        let checkpoint = try Data(contentsOf: journal)

        for result in [
            store.perform(.rename("refused"), on: other.id),
            store.perform(.tags(["refused"]), on: other.id),
            store.perform(.put([DrawObject(content: .text("refused"))]), on: other.id),
            store.performTypingBurst([.rename("no typing save")], on: other.id),
            store.performAgent(.rename("agent refused"), on: other.id),
            store.undo(on: other.id),
            store.redo(on: other.id)
        ] {
            guard case .held = result else { return XCTFail("Frozen Draw mutation must be refused, got \(result)") }
        }
        XCTAssertEqual(try store.open(other.id), before)
        XCTAssertEqual(store.metrics.saveAttempts, attempts)
        XCTAssertEqual(try Data(contentsOf: journal), checkpoint,
                       "The failed edit owns the only checkpoint; no later route writes another")
        XCTAssertEqual(store.pendingEdits.count, 1)
        XCTAssertEqual(store.pendingEdits[first.id]?.count, 1)
        fail = false
        XCTAssertTrue(store.retry(on: first.id).isSaved)
        XCTAssertTrue(store.perform(.rename("now allowed"), on: other.id).isSaved)
    }

    func testR6DS16OneCompleteCheckpointThenRetirementAndFrozenAttemptWritesNothing() throws {
        let root = try temporaryDirectory(), container = try container(at: root)
        var checkpoints = 0, saves = 0, failSave = false
        let journal = DrawRecoveryJournal(fileURL: root.appendingPathComponent("DrawRecovery-v1.json"), writeData: { data, url in
            checkpoints += 1
            try data.write(to: url, options: .atomic)
        })
        let store = DrawStore(repository: DrawSwiftDataRepository(container: container, metrics: DrawSaveMetrics(), save: { context in
            saves += 1
            if failSave { throw Injected() }
            try context.save()
        }, recovery: journal), recovery: journal)
        let canvas = store.create(name: "Save count")
        XCTAssertTrue(store.perform(.saveCanvas, on: canvas.id).isSaved)
        checkpoints = 0; saves = 0
        XCTAssertTrue(store.perform(.rename("one"), on: canvas.id).isSaved)
        XCTAssertEqual(checkpoints, 2, "One complete recovery proof and one retirement")
        XCTAssertEqual(saves, 1, "Exactly one SQLite commit")
        failSave = true
        guard case .retry = store.perform(.rename("failed"), on: canvas.id) else { return XCTFail("Expected failed save") }
        let savedChecks = checkpoints, savedAttempts = saves
        guard case .held = store.perform(.rename("refused"), on: canvas.id) else { return XCTFail("Expected frozen refusal") }
        XCTAssertEqual(checkpoints, savedChecks, "Frozen attempt cannot serialize recovery")
        XCTAssertEqual(saves, savedAttempts, "Frozen attempt cannot enter SQLite")
    }

    func testR6DS8CommittedButUnretiredSaveBlocksPurgeAndRetriesCleanupOnly() throws {
        let root = try temporaryDirectory(), container = try container(at: root)
        var retireFails = false, interruptAfterSave = false, saves = 0
        let journal = DrawRecoveryJournal(fileURL: root.appendingPathComponent("DrawRecovery-v1.json"), writeData: { data, url in
            if retireFails { throw Injected() }
            try data.write(to: url, options: .atomic)
        })
        let store = DrawStore(repository: DrawSwiftDataRepository(container: container, metrics: DrawSaveMetrics(), save: { context in
            saves += 1
            try context.save()
            if interruptAfterSave { retireFails = true }
        }, recovery: journal), recovery: journal)
        let canvas = store.create(name: "Protected")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("original"))]), on: canvas.id).isSaved)
        interruptAfterSave = true
        _ = store.perform(.deleteCanvas, on: canvas.id)
        XCTAssertNotNil(try store.open(canvas.id).canvas.deletedAt)
        XCTAssertTrue(store.hasUnsettledEdits, "Retirement is an unresolved operation")
        let attempts = saves
        let deletion = try XCTUnwrap(store.open(canvas.id).canvas.deletedAt)
        let purged = store.purge([.canvas(canvas.id, deletedAt: deletion)])
        XCTAssertEqual(purged.removed, 0)
        guard case .held = store.perform(.thumbnail(Data([1, 2, 3]), dark: false), on: canvas.id) else {
            return XCTFail("An unjournaled thumbnail must not destroy the proof")
        }
        XCTAssertEqual(saves, attempts)
        retireFails = false; interruptAfterSave = false
        XCTAssertTrue(store.retry(on: canvas.id).isSaved)
        XCTAssertEqual(saves, attempts, "Cleanup must not repeat the user's deletion")
        XCTAssertFalse(store.hasUnsettledEdits)
        XCTAssertNotNil(try DrawPersistentStore(container: try self.container(at: root)).open(canvas.id).canvas.deletedAt)
    }

    func testR6DS7JournalReadFailureBlocksAndRecoversWithReadRetry() throws {
        let root = try temporaryDirectory()
        let original = DrawPersistentStore(container: try container(at: root))
        let canvas = original.create(name: "Kept")
        XCTAssertTrue(original.perform(.put([DrawObject(content: .text("safe"))]), on: canvas.id).isSaved)
        let file = root.appendingPathComponent("DrawRecovery-v1.json")
        let intact = try Data(contentsOf: file)
        try Data("{corrupt".utf8).write(to: file, options: .atomic)
        let recovered = DrawPersistentStore(container: try container(at: root))
        XCTAssertNotNil(recovered.recoveryIssue)
        guard case .held = recovered.perform(.rename("refused"), on: canvas.id) else { return XCTFail("Expected refusal") }
        XCTAssertEqual(try recovered.open(canvas.id).canvas.name, "Kept")
        try intact.write(to: file, options: .atomic)
        _ = recovered.reconcile(on: canvas.id) // The existing Retry surface must re-read the journal.
        XCTAssertNil(recovered.recoveryIssue, "A repaired/transient read error must be retryable without reopening Attic")
        XCTAssertTrue(recovered.perform(.rename("restored"), on: canvas.id).isSaved)
    }

    func testR6DS12EvictionExpiresAnOfferAndDropsAllColdHistory() throws {
        let root = try temporaryDirectory()
        let store = DrawPersistentStore(container: try container(at: root))
        let canvas = store.create(name: "Cold")
        let image = DrawObject(content: .image(DrawImage(
            original: Data(repeating: 33, count: 64_000), pixelWidth: 100, pixelHeight: 100)))
        XCTAssertTrue(store.perform(.put([image]), on: canvas.id).isSaved)
        let offered = try XCTUnwrap(store.undoStepID(on: canvas.id))
        let token = store.pinHistoryStep(offered)
        for index in 0..<10 {
            let other = store.create(name: "New \(index)")
            XCTAssertTrue(store.perform(.put([DrawObject(content: .text("saved"))]), on: other.id).isSaved)
        }
        XCTAssertFalse(store.cachedCanvasIDs.contains(canvas.id))
        XCTAssertFalse(store.canUndo(on: canvas.id), "Zero cold history after saved body eviction")
        XCTAssertNil(store.undoStepID(on: canvas.id))
        XCTAssertEqual(try store.open(canvas.id).objects, [image], "No saved data lost by eviction")
        XCTAssertFalse(store.canUndo(on: canvas.id), "Reopen has a new empty session history")
        withExtendedLifetime(token) {}
    }

    func testR6DS1NoDurableCheckpointLeavesVisibleMemoryOnlyWorkAndRefusesQuit() async throws {
        let root = try temporaryDirectory(), container = try container(at: root)
        let journal = DrawRecoveryJournal(fileURL: root.appendingPathComponent("DrawRecovery-v1.json"),
                                          writeData: { _, _ in throw Injected() })
        let metrics = DrawSaveMetrics()
        let store = DrawStore(repository: DrawSwiftDataRepository(container: container, metrics: metrics,
            save: { try $0.save() }, recovery: journal), recovery: journal)
        let model = DrawPageModel(store: store)
        model.start()
        let id = try XCTUnwrap(model.canvasID)
        let text = DrawObject(content: .text("Memory only"))
        let result = store.perform(.put([text]), on: id)
        XCTAssertFalse(result.isSaved, "An edit is landed only after a durable acknowledgement")
        XCTAssertEqual(try store.open(id).objects, [text], "Keep unsaved work visible")
        XCTAssertEqual(metrics.saveAttempts, 0, "No database commit before recovery proof")
        XCTAssertTrue(store.hasUnsettledEdits)
        let ready = await model.prepareToQuit()
        XCTAssertFalse(ready)
    }

    func testR6DS3LibraryRenameSettlesEarlierBufferedRedoBeforePreparingTitle() throws {
        let root = try temporaryDirectory()
        let store = DrawPersistentStore(container: try container(at: root))
        let model = DrawPageModel(store: store)
        model.start()
        let id = try XCTUnwrap(model.canvasID)
        let image = DrawObject(content: .shape(.rectangle))
        XCTAssertTrue(store.perform(.put([image]), on: id).isSaved)
        model.open(id)
        model.undoAcknowledged()
        model.flushAcknowledgedDraw()
        XCTAssertTrue(try store.open(id).objects.isEmpty)
        model.redoAcknowledged() // Still in the original 20 ms page buffer.
        model.library.perform(.rename)
        model.library.nameDraft = "After redo"
        model.library.commitRename()
        model.flushAcknowledgedDraw()
        XCTAssertEqual(try store.open(id).objects, [image], "Redo has to settle before Rename clears it")
        XCTAssertEqual(try store.open(id).canvas.name, "After redo")
        XCTAssertTrue(store.undo(on: id).isSaved)
        XCTAssertEqual(try store.open(id).objects, [image], "Rename was the most recent Undo step")
    }

    func testR6DS10StrictHundredSessionStepsExpireEarliestOfferedUndo() throws {
        let root = try temporaryDirectory()
        let store = DrawPersistentStore(container: try container(at: root))
        let id = store.create(name: "Cap").id
        XCTAssertTrue(store.perform(.saveCanvas, on: id).isSaved)
        XCTAssertTrue(store.perform(.rename("first"), on: id).isSaved)
        let first = try XCTUnwrap(store.undoStepID(on: id))
        let token = store.pinHistoryStep(first)
        for index in 0..<110 {
            XCTAssertTrue(store.perform(.rename("name \(index)"), on: id).isSaved)
        }
        XCTAssertEqual(store.historyChanges(on: id)?.undo.count, 100,
                       "An offer never permits the session history to outgrow 100 whole steps")
        var count = 0
        while store.canUndo(on: id), store.undo(on: id).isSaved { count += 1 }
        XCTAssertEqual(count, 100)
        XCTAssertEqual(try store.open(id).canvas.name, "name 9")
        withExtendedLifetime(token) {}
    }

    func testR6DS6FailedFullRecoveryLoadNeverCachesSparseBeforeImage() throws {
        let root = try temporaryDirectory(), originalContainer = try container(at: root)
        var failRetirement = false
        var interruptNextRetirement = false
        let journal = DrawRecoveryJournal(fileURL: root.appendingPathComponent("DrawRecovery-v1.json"),
            writeData: { data, url in
                if failRetirement { throw Injected() }
                try data.write(to: url, options: .atomic)
            })
        let store = DrawStore(repository: DrawSwiftDataRepository(container: originalContainer,
            metrics: DrawSaveMetrics(), save: { context in
                try context.save()
                if interruptNextRetirement { failRetirement = true }
            }, recovery: journal), recovery: journal)
        let canvas = store.create(name: "Complete")
        let image = DrawObject(content: .image(DrawImage(original: Data([7, 9, 11]), pixelWidth: 3, pixelHeight: 1)))
        let note = DrawObject(content: .text("precious text"))
        XCTAssertTrue(store.perform(.put([image, note]), on: canvas.id).isSaved)
        failRetirement = false
        interruptNextRetirement = true
        // Fail retirement for the metadata-only rename, leaving a proof that
        // says the rename committed while the full board still has two items.
        _ = store.perform(.rename("Renamed"), on: canvas.id)
        let context = ModelContext(originalContainer)
        context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<DrawObjectRecord>())
        let corrupt = try XCTUnwrap(rows.first { $0.id == note.id })
        let correctHeader = corrupt.header
        corrupt.header = "{broken"
        try context.save()

        // An unclean relaunch constructs a fresh owner while the complete
        // load throws. A sparse rename's objectsBefore is empty by design.
        let reopened = DrawPersistentStore(container: try container(at: root))
        XCTAssertThrowsError(try reopened.open(canvas.id),
                             "A full-load error cannot masquerade as an empty or sparse board")
        let page = DrawPageModel(store: reopened)
        XCTAssertTrue(page.saveNotice?.canRetry == true,
                      "A full-canvas recovery load error must have a visible Retry, even without a pending edit projection")
        XCTAssertTrue(page.saveNotice?.message.contains("complete canvas") == true)
        let repair = ModelContext(originalContainer)
        repair.autosaveEnabled = false
        try XCTUnwrap(repair.fetch(FetchDescriptor<DrawObjectRecord>()).first { $0.id == note.id }).header = correctHeader
        try repair.save()
        page.retrySave()
        let snapshot = try reopened.open(canvas.id)
        XCTAssertEqual(Set(snapshot.objects.map(\.id)), Set([image.id, note.id]))
        XCTAssertEqual(snapshot.canvas.name, "Renamed")
        XCTAssertNil(page.saveNotice, "Retry must withdraw the load-error notice after the complete board becomes available")
    }

    func testR6DS3RecentlyDeletedRestoreFlushesAdmittedImageDeletionFirst() throws {
        let root = try temporaryDirectory()
        let store = DrawPersistentStore(container: try container(at: root))
        let page = DrawPageModel(store: store)
        page.start()
        let id = try XCTUnwrap(page.canvasID)
        let image = DrawObject(content: .image(DrawImage(original: Data([1, 2, 3]), pixelWidth: 1, pixelHeight: 1)))
        XCTAssertTrue(page.perform(.put([image])).isSaved)
        page.performAcknowledged(.remove([image.id]))
        let result = DrawRecentlyDeleted.restoreTracked([DrawDeletedItem(canvasID: id, objectID: image.id)], store: store)
        XCTAssertEqual(result.restored, 1)
        page.flushLiveInput()
        XCTAssertTrue(try store.open(id).objects.contains(where: { $0.id == image.id }),
                      "Restore must execute after the already-admitted deletion, not before it")
    }

    func testR6DS12RemovingHistoryByPurgeOrReloadWithdrawsItsOffers() throws {
        let root = try temporaryDirectory()
        let store = DrawPersistentStore(container: try container(at: root))
        let deleted = store.create(name: "Purge")
        XCTAssertTrue(store.perform(.saveCanvas, on: deleted.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: deleted.id).isSaved)
        let purgeToken = try XCTUnwrap(store.pinHistoryStep(try XCTUnwrap(store.undoStepID(on: deleted.id))) as? DrawHistoryOffer)
        let timestamp = try XCTUnwrap(store.open(deleted.id).canvas.deletedAt)
        XCTAssertEqual(store.purge([.canvas(deleted.id, deletedAt: timestamp)]).removed, 1)
        XCTAssertFalse(purgeToken.isActive, "A permanently removed canvas cannot retain a usable Undo offer")

        let refreshed = store.create(name: "Reload")
        XCTAssertTrue(store.perform(.saveCanvas, on: refreshed.id).isSaved)
        XCTAssertTrue(store.perform(.rename("Current"), on: refreshed.id).isSaved)
        let reloadToken = try XCTUnwrap(store.pinHistoryStep(try XCTUnwrap(store.undoStepID(on: refreshed.id))) as? DrawHistoryOffer)
        try store.reload(refreshed.id)
        XCTAssertFalse(reloadToken.isActive, "Replacing the session history must invalidate offers attached to its old steps")
    }

    func testR6DS9QuitAdmissionCannotApproveUnflushedInputDuringProviderWait() async throws {
        let root = try temporaryDirectory()
        let store = DrawPersistentStore(container: try container(at: root))
        let page = DrawPageModel(store: store)
        page.start()
        let id = try XCTUnwrap(page.canvasID)
        let importToken = UUID()
        let finishing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            page.importFinished(importToken)
        }
        page.importStarted(importToken, finishing)
        let termination = Task { await page.prepareToQuit() }
        try await Task.sleep(for: .milliseconds(40))
        guard case .held = store.perform(.rename("late during Quit"), on: id) else {
            return XCTFail("Input admission must close before the first provider await")
        }
        let late = DrawObject(content: .shape(.rectangle))
        page.performAcknowledged(.put([late]))
        let ready = await termination.value
        let saved = try store.open(id).objects.contains { $0.id == late.id }
        XCTAssertTrue(!ready || saved || !page.objects.contains(where: { $0.id == late.id }),
                      "Quit cannot approve a visible uncheckpointed input received during its await")
        await finishing.value
    }

    func testR6DS11EvictionReleasesHugeNameAndTagHistoryInsteadOfUnderchargingIt() throws {
        let root = try temporaryDirectory()
        let store = DrawPersistentStore(container: try container(at: root))
        let id = store.create(name: "Large metadata").id
        XCTAssertTrue(store.perform(.saveCanvas, on: id).isSaved)
        for index in 0..<100 {
            XCTAssertTrue(store.perform(.rename(String(repeating: "A", count: 8000) + " \(index)"), on: id).isSaved)
            XCTAssertTrue(store.perform(.tags(["tag-\(index)"]), on: id).isSaved)
        }
        XCTAssertEqual(store.historyChanges(on: id)?.undo.count, 100)
        for index in 0..<10 {
            let next = store.create(name: "resident \(index)")
            XCTAssertTrue(store.perform(.saveCanvas, on: next.id).isSaved)
        }
        XCTAssertFalse(store.cachedCanvasIDs.contains(id))
        XCTAssertEqual(store.historyChanges(on: id)?.undo.count, 0,
                       "No metadata payload or uncounted tag/name history survives body eviction")
        XCTAssertFalse(store.canUndo(on: id))
        XCTAssertEqual(try store.open(id).canvas.name.suffix(3), " 99")
    }

    func testR6DS13GroupedUndoReportsPartialWhenCompensationCannotSave() throws {
        let root = try temporaryDirectory(), container = try container(at: root)
        var saves = 0
        var failed = Set<Int>()
        let store = DrawPersistentStore(container: container, save: { context in
            saves += 1
            if failed.contains(saves) { throw Injected() }
            try context.save()
        })
        let a = store.create(name: "A"), b = store.create(name: "B")
        for id in [a.id, b.id] {
            XCTAssertTrue(store.perform(.saveCanvas, on: id).isSaved)
            XCTAssertTrue(store.perform(.deleteCanvas, on: id).isSaved)
        }
        let restored = DrawRecentlyDeleted.restoreTracked([
            DrawDeletedItem(canvasID: a.id, objectID: nil),
            DrawDeletedItem(canvasID: b.id, objectID: nil)
        ], store: store)
        XCTAssertEqual(restored.restored, 2)
        let group = try XCTUnwrap(RecentlyDeletedRestoreUndo.make(drawStore: store,
            actions: restored.actions, librarySteps: [], restored: 2))
        saves = 0; failed = [2, 3]
        let result = group.undo()
        XCTAssertTrue(String(describing: result).contains("partial"),
                      "The group must report that B was undone while A and compensation failed")
        XCTAssertNotNil(try store.open(b.id).canvas.deletedAt)
        XCTAssertTrue(store.hasUnsettledEdits)
        failed = []
        XCTAssertTrue(store.retry(on: a.id).isSaved)
        XCTAssertEqual(group.undo(), .applied, "Ordered Retry settles only what remains")
        XCTAssertNotNil(try store.open(a.id).canvas.deletedAt)
        XCTAssertNotNil(try store.open(b.id).canvas.deletedAt)
        let relaunched = DrawPersistentStore(container: try self.container(at: root))
        XCTAssertNotNil(try relaunched.open(a.id).canvas.deletedAt)
        XCTAssertNotNil(try relaunched.open(b.id).canvas.deletedAt)
    }

    func testR6DS14LegacyV1MixedUndoRedoTailDrainsInOrderWithMissingStepIDs() throws {
        struct LegacyRecord: Codable {
            var edits: [DrawStore.Pending]
            var proof: Data? = nil
            var unattempted = true
        }
        struct LegacyArchive: Codable {
            var version = 1
            var records: [UUID: LegacyRecord]
        }
        let root = try temporaryDirectory()
        var canvasID = UUID()
        try autoreleasepool {
            let owner = DrawPersistentStore(container: try container(at: root))
            canvasID = owner.create(name: "before").id
            XCTAssertTrue(owner.perform(.saveCanvas, on: canvasID).isSaved)
        }
        let before = try DrawPersistentStore(container: try container(at: root)).open(canvasID).canvas
        var after = before
        after.name = "after"
        after.updatedAt = before.updatedAt.addingTimeInterval(1)
        let change = DrawChange(canvasID: canvasID, before: before, after: after,
                                objectsBefore: [:], objectsAfter: [:])
        let forward = DrawStore.Step(change: change, before: before, after: after,
                                      beforePersisted: true, afterPersisted: true)
        let oldEdits: [DrawStore.Pending] = [
            DrawStore.Pending(step: forward, action: .edit),
            DrawStore.Pending(step: forward.reversed, action: .undo),
            DrawStore.Pending(step: forward, action: .redo)
        ]
        let file = root.appendingPathComponent("DrawRecovery-v1.json")
        let encoded = try JSONEncoder().encode(LegacyArchive(records: [canvasID: LegacyRecord(edits: oldEdits)]))
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        func eraseIDs(_ value: Any) -> Any {
            if var dictionary = value as? [String: Any] {
                if dictionary["beforePersisted"] != nil { dictionary["id"] = nil }
                if dictionary["step"] != nil { dictionary["id"] = nil }
                for (key, member) in dictionary { dictionary[key] = eraseIDs(member) }
                return dictionary
            }
            return (value as? [Any])?.map(eraseIDs) ?? value
        }
        oldJSON = try XCTUnwrap(eraseIDs(oldJSON) as? [String: Any])
        try JSONSerialization.data(withJSONObject: oldJSON).write(to: file, options: .atomic)

        // Existing on-disk tails are finite recovery work even though normal
        // inputs must no longer append to a tail.
        let recovered = DrawPersistentStore(container: try container(at: root))
        XCTAssertNil(recovered.recoveryIssue)
        XCTAssertEqual(recovered.pendingEdits[canvasID]?.count, 3)
        XCTAssertTrue(recovered.retry(on: canvasID).isSaved)
        XCTAssertFalse(recovered.hasUnsettledEdits)
        XCTAssertEqual(try recovered.open(canvasID).canvas.name, "after")
        XCTAssertEqual(try DrawPersistentStore(container: try container(at: root)).open(canvasID).canvas.name, "after")
        XCTAssertEqual(recovered.historyChanges(on: canvasID)?.undo.count, 1)
    }

    func testR6DS5DeleteFromLibraryWhileFrozenIsRefusedAndNeverReplayed() throws {
        let root = try temporaryDirectory()
        var fail = false
        let store = DrawPersistentStore(container: try container(at: root), save: { context in
            if fail { throw Injected() }
            try context.save()
        })
        let page = DrawPageModel(store: store)
        page.start()
        let first = try XCTUnwrap(page.canvasID)
        let other = store.create(name: "Keep visible")
        XCTAssertTrue(store.perform(.saveCanvas, on: first).isSaved)
        XCTAssertTrue(store.perform(.saveCanvas, on: other.id).isSaved)
        fail = true
        guard case .retry = store.perform(.rename("blocked"), on: first) else { return XCTFail("Expected blocked owner") }
        page.open(other.id)
        page.library.perform(.delete)
        XCTAssertNil(store.pendingEdits[other.id], "A refused Delete must not enter the pending sequence")
        XCTAssertNil(try store.open(other.id).canvas.deletedAt)
        fail = false
        XCTAssertTrue(store.retry(on: first).isSaved)
        XCTAssertNil(try DrawPersistentStore(container: try container(at: root)).open(other.id).canvas.deletedAt)
    }

    func testR6DS9NestedQuitPreparationReopensAdmissionWhenOuterQuitIsRefused() async throws {
        let store = DrawPersistentStore(container: try container())
        let page = DrawPageModel(store: store)
        page.start()
        let canvasID = try XCTUnwrap(page.canvasID)
        XCTAssertTrue(store.perform(.saveCanvas, on: canvasID).isSaved)

        // AppCoordinator closes admission before waiting for other pages.
        // Draw's inner preparation may succeed, but a later Task failure
        // still refuses Quit. Both admission owners must then be released.
        store.closeAdmissionForQuit()
        let drawReady = await page.prepareToQuit()
        XCTAssertTrue(drawReady)
        XCTAssertTrue(store.admissionClosed, "The outer Quit gate remains closed")
        store.reopenAdmissionAfterQuit() // The outer Task check refuses Quit.
        XCTAssertFalse(store.admissionClosed, "A refused Quit must restore ordinary Draw input")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("still editable"))]), on: canvasID).isSaved)
    }

    func testR6DS2FrozenPointerAndAgentCreateRefuseBeforeStartingNewWork() throws {
        let root = try temporaryDirectory()
        var fail = false
        let store = DrawPersistentStore(container: try container(at: root), save: { context in
            if fail { throw Injected() }
            try context.save()
        })
        let page = DrawPageModel(store: store)
        page.start()
        let owner = try XCTUnwrap(page.canvasID)
        let other = store.create(name: "View remains available")
        XCTAssertTrue(store.perform(.saveCanvas, on: owner).isSaved)
        XCTAssertTrue(store.perform(.saveCanvas, on: other.id).isSaved)
        fail = true
        guard case .retry = store.perform(.rename("unresolved"), on: owner) else {
            return XCTFail("Expected a failed owner write")
        }
        page.open(other.id)
        page.setTool(.pen)
        page.pointerDown(at: CGPoint(x: 60, y: 100))
        XCTAssertNil(page.live, "A new ink gesture must be rejected before drawing provisional ink")
        page.pointerDragged(to: CGPoint(x: 120, y: 140))
        page.pointerUp()
        XCTAssertTrue(try store.open(other.id).objects.isEmpty)

        let before = store.cachedCanvasIDs
        let tasks = try makeTestStore()
        let agent = AgentActions(tasks: AgentTaskTools(store: tasks,
            library: AtticLibrary(tasks: tasks)), draw: store)
        XCTAssertThrowsError(try agent.drawAction("draw_create_canvas", ["name": "Refused"], beforeMutation: {}))
        XCTAssertEqual(store.cachedCanvasIDs, before,
                       "An agent's refused create must not insert an orphaned draft before admission")
        let listing = try agent.drawAction("draw_list_canvases", [:], beforeMutation: {}).0
        let listJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listing.utf8)) as? [String: Any])
        XCTAssertEqual(listJSON["draw_mutations_paused"] as? Bool, true,
                       "Agent listing must disclose a global Draw fence")
        let reading = try agent.drawAction("draw_read_canvas", ["canvas_id": owner.uuidString], beforeMutation: {}).0
        let readJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reading.utf8)) as? [String: Any])
        XCTAssertEqual(readJSON["canvas_save_unsettled"] as? Bool, true,
                       "Agent reads must not report provisional content as committed")
        XCTAssertEqual(readJSON["draw_mutations_paused"] as? Bool, true)
    }

    func testR6DS15AgentResizesFlatLinesAlongTheirNonzeroAxisInBothDirections() throws {
        let root = try temporaryDirectory()
        let lines: [DrawObject] = [
            DrawObject(frame: DrawFrame(x: 30, y: 30, width: 80, height: 0), content: .shape(.line)),
            DrawObject(frame: DrawFrame(x: 180, y: 30, width: -80, height: 0), content: .shape(.line)),
            DrawObject(frame: DrawFrame(x: 300, y: 30, width: 0, height: 80), content: .shape(.line)),
            DrawObject(frame: DrawFrame(x: 420, y: 180, width: 0, height: -80), content: .shape(.line))
        ]
        var boardID = UUID()
        try autoreleasepool {
            let store = DrawPersistentStore(container: try container(at: root))
            let board = store.create(name: "Flat lines")
            boardID = board.id
            XCTAssertTrue(store.perform(.put(lines), on: board.id).isSaved)
            let tasks = try makeTestStore()
            let agent = AgentActions(tasks: AgentTaskTools(store: tasks,
                library: AtticLibrary(tasks: tasks)), draw: store)

            for line in lines {
                let response = try agent.drawAction("draw_read_canvas", ["canvas_id": board.id.uuidString], beforeMutation: {}).0
                let JSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
                let rows = try XCTUnwrap(JSON["objects"] as? [[String: Any]])
                let token = try XCTUnwrap(rows.first(where: { $0["id"] as? String == line.id.uuidString })?["object_token"] as? String)
                let isHorizontal = line.frame.height == 0
                let requestedWidth = isHorizontal ? 120.0 : 0.0
                let requestedHeight = isHorizontal ? 0.0 : 120.0
                _ = try agent.drawAction("draw_resize_object", [
                    "canvas_id": board.id.uuidString, "object_id": line.id.uuidString,
                    "object_token": token, "width": requestedWidth, "height": requestedHeight
                ], beforeMutation: {})
                let resized = try XCTUnwrap(try store.open(board.id).objects.first(where: { $0.id == line.id }))
                let covered = DrawGeometry.frame(resized.frame)
                XCTAssertEqual(Double(covered.width), requestedWidth, accuracy: 0.01)
                XCTAssertEqual(Double(covered.height), requestedHeight, accuracy: 0.01)
                if isHorizontal {
                    XCTAssertEqual(resized.frame.width.sign, line.frame.width.sign, "Endpoint order must survive horizontal resize")
                    XCTAssertEqual(resized.frame.height, 0)
                } else {
                    XCTAssertEqual(resized.frame.height.sign, line.frame.height.sign, "Endpoint order must survive vertical resize")
                    XCTAssertEqual(resized.frame.width, 0)
                }
            }
        } // Crash: release the store and agent without preparing Draw to quit.
        let reopened = DrawPersistentStore(container: try container(at: root))
        XCTAssertEqual(try reopened.open(boardID).objects.count, lines.count)
        for line in lines {
            let actual = try XCTUnwrap(try reopened.open(boardID).objects.first(where: { $0.id == line.id }))
            let covered = DrawGeometry.frame(actual.frame)
            XCTAssertEqual(Double(line.frame.height == 0 ? covered.width : covered.height), 120, accuracy: 0.01)
        }
    }
}

// Test-only replica fixtures: production never inserts replicas deliberately.
private extension DrawCanvasRecord {
    func replica() -> DrawCanvasRecord {
        let copy = DrawCanvasRecord()
        copy.id = id; copy.name = name; copy.tagsJSON = tagsJSON
        copy.createdAt = createdAt; copy.updatedAt = updatedAt; copy.deletedAt = deletedAt
        copy.thumbnailID = thumbnailID; copy.textIndex = textIndex
        return copy
    }
}
private extension DrawObjectRecord {
    func replica() -> DrawObjectRecord {
        let copy = DrawObjectRecord()
        copy.id = id; copy.canvasID = canvasID; copy.header = header; copy.formatVersion = formatVersion
        copy.zIndex = zIndex; copy.deletedAt = deletedAt; copy.textIndex = textIndex; copy.payloadDigest = payloadDigest
        return copy
    }
}
private extension DrawPayloadRecord {
    func replica() -> DrawPayloadRecord {
        let copy = DrawPayloadRecord()
        copy.id = id; copy.canvasID = canvasID; copy.role = role; copy.formatVersion = formatVersion
        copy.digest = digest; copy.bytes = bytes
        return copy
    }
}
