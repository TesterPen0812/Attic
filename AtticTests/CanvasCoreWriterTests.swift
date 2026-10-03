import Foundation
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class CanvasCoreWriterTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!
    private var gate: WorkspaceOperationCoordinator!
    private var writer: CanvasCoreWriter!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("P4Writer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        gate = try WorkspaceOperationCoordinator(container: container, journal: NoteDraftJournal(directory: root.appendingPathComponent("journal")))
        writer = CanvasCoreWriter(gate: gate)
    }
    override func tearDown() async throws {
        writer = nil; gate = nil; container = nil
        try FileManager.default.removeItem(at: root)
    }
    private var ink: CanvasCoreInk {
        .init(color: "ink", width: 3, samples: (0..<400).map { .init(x: Double($0) * 0.5, y: 2, time: UInt64($0 * 8_000), pressure: nil) })
    }
    private func create(_ creation: CanvasCoreCreation = .init()) throws -> CanvasCoreCreation {
        XCTAssertEqual(writer.perform(name: "First ink", patches: try creation.firstInk(ink)), .committed)
        return creation
    }
    private func strokeRows() throws -> [CanvasStrokeItem] { try ModelContext(container).fetch(FetchDescriptor<CanvasStrokeItem>()) }
    private func boardRows() throws -> [CanvasBoardItem] { try ModelContext(container).fetch(FetchDescriptor<CanvasBoardItem>()) }
    func testP4CreationBudgetNoEagerRowsAtomicFirstContentAndOneHistoryGroup() throws {
        let creation = CanvasCoreCreation()
        XCTAssertTrue(try boardRows().isEmpty); XCTAssertTrue(try strokeRows().isEmpty)
        XCTAssertThrowsError(try creation.firstInk(.init(color: "ink", width: 3, samples: [])))
        XCTAssertTrue(try boardRows().isEmpty)
        _ = try create(creation)
        XCTAssertEqual(try boardRows().map(\.id), [creation.boardID])
        XCTAssertEqual(try strokeRows().map(\.id), [creation.firstObjectID])
        XCTAssertEqual(writer.counters.saves, 1); XCTAssertEqual(writer.cursor, 1)
        XCTAssertEqual(writer.history.count, 1); XCTAssertEqual(gate.validationCounters.fastValidations, 1)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<OperationReceipt>()).count, 0)
        XCTAssertEqual(writer.undo(), .committed)
        XCTAssertTrue(try boardRows().allSatisfy(\.tombstoned)); XCTAssertTrue(try strokeRows().allSatisfy(\.tombstoned))
        XCTAssertEqual(writer.redo(), .committed)
        XCTAssertFalse(try XCTUnwrap(strokeRows().first).tombstoned)
    }
    func testP4CreationBudgetBeforeSaveThrowRetriesSameIDsWithoutOrphans() throws {
        let creation = CanvasCoreCreation(), patches = try creation.firstInk(ink)
        gate.save = { _ in throw CanvasCoreError.conflict }
        XCTAssertEqual(writer.perform(name: "First", patches: patches), .notCommitted)
        XCTAssertEqual(writer.cursor, 0); XCTAssertTrue(try boardRows().isEmpty); XCTAssertTrue(try strokeRows().isEmpty)
        gate.save = { try $0.save() }
        XCTAssertEqual(writer.perform(name: "First", patches: patches), .committed)
        XCTAssertEqual(try boardRows().map(\.id), [creation.boardID]); XCTAssertEqual(try strokeRows().map(\.id), [creation.firstObjectID])
    }
    func testP4OutcomeBudgetSaveThenThrowPublishesExactlyOnceWithNoDuplicateFirstContent() throws {
        let creation = CanvasCoreCreation(), patches = try creation.firstInk(ink)
        gate.save = { try $0.save(); throw CanvasCoreError.conflict }
        XCTAssertEqual(writer.perform(name: "First", patches: patches), .committed)
        XCTAssertEqual(writer.counters.publications, 1); XCTAssertEqual(writer.cursor, 1)
        XCTAssertEqual(writer.perform(name: "First replay", patches: patches), .conflict)
        XCTAssertEqual(writer.counters.publications, 1)
        XCTAssertEqual(try strokeRows().count, 1); XCTAssertEqual(try boardRows().count, 1)
    }
    func testP4OutcomeBudgetUnreadableAfterStateHoldsFamiliesAndThenPublishesOnce() throws {
        let creation = CanvasCoreCreation(), patches = try creation.firstInk(ink)
        gate.save = { try $0.save(); throw CanvasCoreError.conflict }
        gate.beforeReconciliationRead = { throw CanvasCoreError.conflict }
        XCTAssertEqual(writer.perform(name: "First", patches: patches), .unknown)
        XCTAssertTrue(writer.hasUnresolvedOutcome); XCTAssertEqual(writer.cursor, 0)
        XCTAssertEqual(writer.perform(name: "Retry", patches: patches), .unknown)
        XCTAssertEqual(writer.resolve(), .unknown); XCTAssertEqual(writer.counters.publications, 0)
        gate.beforeReconciliationRead = nil
        XCTAssertEqual(writer.resolve(), .committed)
        XCTAssertEqual(writer.counters.publications, 1); XCTAssertEqual(writer.resolve(), .conflict)
        XCTAssertEqual(try strokeRows().count, 1)
    }
    func testP4OutcomeBudgetSuccessfulSaveNeverCallsReconciliation() throws {
        gate.beforeReconciliationRead = { XCTFail("P4OutcomeBudget: success reread"); throw CanvasCoreError.conflict }
        _ = try create(); XCTAssertEqual(writer.counters.publications, 1)
    }
    func testP4CommitDeltaBudgetAllPhysicalReplicasOnlyChangedFieldsAndCrossCanvasUUIDSafety() throws {
        let creation = try create(), seed = ModelContext(container)
        let same = CanvasStrokeItem(id: creation.firstObjectID, canvasID: creation.boardID, payload: Data([9]), mutationVersion: 5)
        let foreignBoard = UUID()
        let foreign = CanvasStrokeItem(id: creation.firstObjectID, canvasID: foreignBoard, payload: Data([8]), mutationVersion: 90)
        seed.insert(same); seed.insert(foreign)
        for _ in 0..<2_000 { seed.insert(CanvasStrokeItem(canvasID: creation.boardID, payload: Data([7]))) }
        try seed.save()
        let owner = WorkspaceOwner(entity: .stroke, id: creation.firstObjectID)
        try writer.capture([owner]); writer.resetCounters()
        let patch = CanvasCorePatch(owner: owner, canvasID: creation.boardID, fields: ["offsetX": try WorkspaceModelFields.encode(40.0)])
        XCTAssertEqual(writer.perform(name: "Move", patches: [patch]), .committed)
        XCTAssertEqual(writer.counters.fetchedReplicas, 4); XCTAssertEqual(writer.counters.changedReplicas, 2, "P4CommitDeltaBudget: three object replicas plus one scalar board guard")
        let rows = try strokeRows().filter { $0.id == creation.firstObjectID }
        XCTAssertTrue(rows.filter { $0.canvasID == creation.boardID }.allSatisfy { $0.offsetX == 40 && $0.mutationVersion == 6 })
        XCTAssertEqual(rows.first { $0.canvasID == foreignBoard }?.offsetX, 0)
        XCTAssertEqual(rows.first { $0.canvasID == foreignBoard }?.mutationVersion, 90)
        XCTAssertTrue(rows.contains { $0.payload == Data([9]) }); XCTAssertTrue(rows.contains { $0.payload == Data([8]) })
        XCTAssertEqual(writer.undo(), .committed)
        XCTAssertTrue(try strokeRows().filter { $0.id == creation.firstObjectID }.allSatisfy { $0.offsetX == 0 })
    }
    func testP4HistoryBudgetFailedUndoKeepsCursorRedoAndBytes() throws {
        _ = try create(); let bytes = try XCTUnwrap(strokeRows().first?.binaryPayload)
        gate.save = { _ in throw CanvasCoreError.conflict }
        XCTAssertEqual(writer.undo(), .notCommitted); XCTAssertEqual(writer.cursor, 1); XCTAssertFalse(writer.canRedo)
        XCTAssertEqual(try strokeRows().first?.binaryPayload, bytes); XCTAssertFalse(try XCTUnwrap(strokeRows().first).tombstoned)
        gate.save = { try $0.save() }; XCTAssertEqual(writer.undo(), .committed); XCTAssertEqual(writer.redo(), .committed)
        XCTAssertEqual(try strokeRows().first?.binaryPayload, bytes)
    }
    func testP4HistoryBudgetExternalBarrierHasNoInverseAndLaterLocalUndoStopsAtOrigin() throws {
        let creation = try create(), owner = WorkspaceOwner(entity: .stroke, id: creation.firstObjectID)
        let external = CanvasCorePatch(owner: owner, canvasID: creation.boardID, fields: ["offsetX": try WorkspaceModelFields.encode(4.0)])
        XCTAssertEqual(writer.perform(name: "External", patches: [external], origin: "Claude"), .committed)
        XCTAssertTrue(writer.history.last!.undo.isEmpty); XCTAssertTrue(writer.history.last!.redo.isEmpty)
        XCTAssertEqual(writer.barrierReason, "Edited by Claude: can't undo past this")
        let saves = writer.counters.saves; XCTAssertEqual(writer.undo(), .conflict); XCTAssertEqual(writer.counters.saves, saves)
        let local = CanvasCorePatch(owner: owner, canvasID: creation.boardID, fields: ["offsetX": try WorkspaceModelFields.encode(9.0)])
        XCTAssertEqual(writer.perform(name: "Local", patches: [local]), .committed)
        XCTAssertEqual(writer.undo(), .committed); XCTAssertEqual(try strokeRows().first?.offsetX, 4)
        XCTAssertEqual(writer.undo(), .conflict); XCTAssertEqual(writer.redo(), .committed)
        let count = writer.history.count
        XCTAssertEqual(writer.perform(name: "Already matching", patches: [local], origin: "Claude"), .notCommitted)
        XCTAssertEqual(writer.history.count, count)
    }
    func testP4HistoryBudgetFailedOrUnknownExternalEditAddsNoBarrierUntilConfirmed() throws {
        let creation = try create(), owner = WorkspaceOwner(entity: .stroke, id: creation.firstObjectID)
        let patch = CanvasCorePatch(owner: owner, canvasID: creation.boardID, fields: ["offsetX": try WorkspaceModelFields.encode(4.0)])
        gate.save = { _ in throw CanvasCoreError.conflict }
        XCTAssertEqual(writer.perform(name: "External", patches: [patch], origin: "Agent"), .notCommitted)
        XCTAssertNil(writer.barrierReason)
        gate.save = { try $0.save(); throw CanvasCoreError.conflict }; gate.beforeReconciliationRead = { throw CanvasCoreError.conflict }
        XCTAssertEqual(writer.perform(name: "External", patches: [patch], origin: "Agent"), .unknown)
        XCTAssertNil(writer.barrierReason); gate.beforeReconciliationRead = nil
        XCTAssertEqual(writer.resolve(), .committed); XCTAssertEqual(writer.barrierReason, "Edited by Agent: can't undo past this")
        XCTAssertEqual(writer.history.count, 2)
    }
    func testP4CommitDeltaBudgetTextAndTransformUseOneChangedFamilyAndPreserveLegacyBytes() throws {
        let creation = CanvasCoreCreation()
        let content = try CanvasCoreSemanticContract.decode(Data(#"{"text":"Legacy🙂\n","color":"ink","strokeWidth":3,"fontSize":24}"#.utf8))
        let id = CanvasCoreID(canvasID: creation.boardID, objectID: creation.firstObjectID)
        let first = try CanvasCoreWriter.semanticPatch(id: id, content: content, bounds: .init(minX: 0, minY: 0, maxX: 160, maxY: 48), inserting: true)
        XCTAssertEqual(writer.perform(name: "First text", patches: creation.firstContent(first)), .committed)
        var text = content; text.text = "Edited🙂\n\n"; text.wrapWidth = 100; text.size = .large
        writer.resetCounters()
        let patch = try CanvasCoreWriter.semanticPatch(id: id, content: text, bounds: .init(minX: 0, minY: 0, maxX: 100, maxY: 200), inserting: false)
        XCTAssertEqual(writer.perform(name: "Text", patches: [patch]), .committed)
        XCTAssertEqual(writer.counters.fetchedReplicas, 2); XCTAssertEqual(writer.counters.changedReplicas, 1)
        XCTAssertEqual(writer.undo(), .committed)
        let row = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<CanvasSemanticObjectItem>()).first)
        XCTAssertEqual(try CanvasCoreSemanticContract.decode(row.payload), content)
        let original = row.payload
        let move = CanvasCorePatch(owner: .init(entity: .semantic, id: id.objectID), canvasID: id.canvasID, fields: ["centerX": try WorkspaceModelFields.encode(90.0)])
        XCTAssertEqual(writer.perform(name: "Move", patches: [move]), .committed)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CanvasSemanticObjectItem>()).first?.payload, original)
    }
    func testP4OutcomeBudgetForeignWriteAndReplicaInsertionRejectStaleGuard() throws {
        let creation = try create(), seed = ModelContext(container)
        seed.insert(CanvasStrokeItem(id: creation.firstObjectID, canvasID: creation.boardID))
        try seed.save()
        let patch = CanvasCorePatch(owner: .init(entity: .stroke, id: creation.firstObjectID), canvasID: creation.boardID,
            fields: ["offsetX": try WorkspaceModelFields.encode(30.0)])
        XCTAssertEqual(writer.perform(name: "Stale", patches: [patch]), .conflict)
        XCTAssertEqual(writer.cursor, 1); XCTAssertTrue(try strokeRows().allSatisfy { $0.offsetX == 0 })
    }
    func testP4CreationBudgetDeletedParentCannotAcceptContentOrResurrectADefault() throws {
        let creation = try create(), context = ModelContext(container)
        let parent = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasBoardItem>()).first)
        parent.tombstoned = true; parent.mutationVersion += 1; try context.save()
        let patch = try CanvasCoreWriter.inkPatch(id: .init(canvasID: creation.boardID, objectID: UUID()), ink: ink)
        XCTAssertEqual(writer.perform(name: "Refused", patches: [patch]), .conflict)
        try writer.capture([.init(entity: .board, id: creation.boardID)])
        XCTAssertEqual(writer.perform(name: "Still refused", patches: [patch]), .conflict)
        XCTAssertEqual(try strokeRows().count, 1); XCTAssertTrue(try boardRows().allSatisfy(\.tombstoned))
    }
}
