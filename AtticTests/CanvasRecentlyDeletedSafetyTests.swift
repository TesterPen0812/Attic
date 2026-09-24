import SwiftData
import XCTest
@testable import Attic

/// Canvas purge never destroys live or divergent content, and a canvas restore
/// is complete or refused (data review findings 1 and 5).
@MainActor
final class CanvasRecentlyDeletedSafetyTests: XCTestCase {
    private let day: TimeInterval = 24 * 3_600

    /// A deleted canvas with one stroke, its board deleted at `clock`.
    private func deletedCanvas(_ clock: MutableNow) throws -> (CanvasStore, UUID, CanvasStroke) {
        let store = try makeTestCanvasStore(now: { clock.value })
        XCTAssertNotNil(store.createCanvas(name: "Keep"))
        let board = try XCTUnwrap(store.createCanvas(name: "Doomed"))
        XCTAssertTrue(store.selectCanvas(board.id))
        let stroke = try XCTUnwrap(store.addStroke(color: .ink, width: 3, points: [.zero, CanvasPoint(x: 1, y: 1)]))
        XCTAssertTrue(store.deleteCanvas(board.id))
        return (store, board.id, stroke)
    }

    private func strokeCount(_ store: CanvasStore, _ canvasID: UUID) throws -> Int {
        try ModelContext(store.container).fetchCount(FetchDescriptor<CanvasStrokeItem>(predicate: #Predicate { $0.canvasID == canvasID }))
    }

    func testCanvasPurgeDefersWhileAnyContentReplicaIsLive() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let (store, canvasID, stroke) = try deletedCanvas(clock)
        // A late replica from another device still shows the stroke.
        let seed = ModelContext(store.container)
        seed.insert(CanvasStrokeItem(id: stroke.id, canvasID: canvasID, payload: Data([1]), mutationVersion: 99))
        try seed.save()

        XCTAssertTrue(store.purgeDeletedCanvases(before: .distantFuture).isEmpty)
        XCTAssertEqual(try strokeCount(store, canvasID), 2, "nothing was destroyed")
    }

    func testCanvasPurgeDefersWhenContentReplicasDisagree() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let (store, canvasID, stroke) = try deletedCanvas(clock)
        let seed = ModelContext(store.container)
        seed.insert(CanvasStrokeItem(id: stroke.id, canvasID: canvasID, payload: Data([2]), mutationVersion: 42,
                                     tombstoned: true, deletedAt: Date(timeIntervalSince1970: 5)))
        try seed.save()
        XCTAssertTrue(store.purgeDeletedCanvases(before: .distantFuture).isEmpty)
        XCTAssertEqual(try strokeCount(store, canvasID), 2)
    }

    func testCanvasPurgeDefersWhenBoardReplicasDisagree() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let (store, canvasID, _) = try deletedCanvas(clock)
        let context = ModelContext(store.container)
        let original = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.id == canvasID })).first)
        let peer = CanvasBoardItem(id: canvasID, name: "Renamed elsewhere", sortIndex: original.sortIndex,
                                   mutationVersion: original.mutationVersion, tombstoned: true,
                                   createdAt: original.createdAt, updatedAt: original.updatedAt, deletedAt: original.deletedAt)
        peer.recentlyDeletedAt = original.recentlyDeletedAt
        peer.deletedContentCount = original.deletedContentCount
        context.insert(peer)
        try context.save()

        XCTAssertTrue(store.purgeDeletedCanvases(before: .distantFuture).isEmpty)
        XCTAssertEqual(try strokeCount(store, canvasID), 1)
    }

    func testCanvasPurgeDefersWhenEqualVersionStrokeReplicasHoldDifferentContent() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let (store, canvasID, stroke) = try deletedCanvas(clock)
        let context = ModelContext(store.container)
        let strokeID = stroke.id
        let original = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasStrokeItem>(
            predicate: #Predicate { $0.id == strokeID }
        )).first)
        XCTAssertTrue(original.tombstoned)
        // Same version, same deletion time, same everything but the ink.
        let peer = CanvasStrokeItem(id: original.id, canvasID: canvasID, payloadVersion: original.payloadVersion,
                                    payload: original.payload + Data([0xFF]), boardGeneration: original.boardGeneration,
                                    mutationVersion: original.mutationVersion, tombstoned: true,
                                    createdAt: original.createdAt, updatedAt: original.updatedAt,
                                    deletedAt: original.deletedAt)
        context.insert(peer)
        try context.save()

        XCTAssertTrue(store.purgeDeletedCanvases(before: .distantFuture).isEmpty)
        XCTAssertEqual(try strokeCount(store, canvasID), 2, "neither version of the stroke was destroyed")

        // Once the copies agree, the purge goes ahead.
        peer.payload = original.payload
        try context.save()
        XCTAssertEqual(store.purgeDeletedCanvases(before: .distantFuture), [canvasID])
        XCTAssertEqual(try strokeCount(store, canvasID), 0)
    }

    func testCanvasPurgeDefersWhenEqualVersionImageReplicasHoldDifferentBytes() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let (store, canvasID, _) = try deletedCanvas(clock)
        let context = ModelContext(store.container)
        let board = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasBoardItem>(
            predicate: #Predicate { $0.id == canvasID }
        )).first)
        let imageID = UUID()
        let created = Date(timeIntervalSince1970: 50_000)
        for bytes in [Data([1, 2, 3]), Data([4, 5, 6])] {
            context.insert(CanvasImageItem(id: imageID, canvasID: canvasID, encodedData: bytes, pixelWidth: 1,
                                           pixelHeight: 1, mutationVersion: 7, tombstoned: true, createdAt: created,
                                           updatedAt: board.deletedAt, deletedAt: board.deletedAt))
        }
        try context.save()

        XCTAssertTrue(store.purgeDeletedCanvases(before: .distantFuture).isEmpty)
        XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<CanvasImageItem>(
            predicate: #Predicate { $0.id == imageID }
        )), 2, "both images are kept")
        XCTAssertEqual(try strokeCount(store, canvasID), 1)
    }

    func testCanvasPurgeReadsImageBytesInsteadOfTrustingAStaleDigest() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let (store, canvasID, _) = try deletedCanvas(clock)
        let context = ModelContext(store.container)
        let board = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasBoardItem>(
            predicate: #Predicate { $0.id == canvasID }
        )).first)
        let imageID = UUID()
        let created = Date(timeIntervalSince1970: 50_000)
        // Both rows claim the same size and digest, but one row's bytes were
        // replaced without its scalars being updated.
        let stale = CanvasImagePayloadMetadata(byteCount: 3, digest: "stale-digest")
        var rows: [CanvasImageItem] = []
        for bytes in [Data([1, 2, 3]), Data([9, 9, 9])] {
            let row = CanvasImageItem(id: imageID, canvasID: canvasID, encodedData: bytes, pixelWidth: 1,
                                      pixelHeight: 1, mutationVersion: 7, tombstoned: true, createdAt: created,
                                      updatedAt: board.deletedAt, deletedAt: board.deletedAt, payloadMetadata: stale)
            context.insert(row)
            rows.append(row)
        }
        try context.save()

        XCTAssertTrue(store.purgeDeletedCanvases(before: .distantFuture).isEmpty)
        let kept = try ModelContext(store.container).fetch(FetchDescriptor<CanvasImageItem>(
            predicate: #Predicate { $0.id == imageID }
        ))
        XCTAssertEqual(Set(kept.map(\.encodedData)), [Data([1, 2, 3]), Data([9, 9, 9])], "both images are kept")

        // Once the bytes really agree, the purge goes ahead.
        rows[1].encodedData = Data([1, 2, 3])
        try context.save()
        XCTAssertEqual(store.purgeDeletedCanvases(before: .distantFuture), [canvasID])
    }

    // MARK: - Restore with divergent content replicas

    /// Records one more hidden object on the deleted board, as a delete that
    /// had hidden it would have.
    private func countOneMoreHiddenObject(_ context: ModelContext, _ canvasID: UUID) throws {
        for board in try context.fetch(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.id == canvasID })) {
            board.deletedContentCount = (board.deletedContentCount ?? 0) + 1
        }
    }

    func testCanvasRestoreIsRefusedWhenStrokeReplicasHoldDifferentInk() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let (store, canvasID, stroke) = try deletedCanvas(clock)
        let context = ModelContext(store.container)
        let strokeID = stroke.id
        let original = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasStrokeItem>(
            predicate: #Predicate { $0.id == strokeID }
        )).first)
        let originalInk = original.payload
        context.insert(CanvasStrokeItem(id: original.id, canvasID: canvasID, payloadVersion: original.payloadVersion,
                                        payload: originalInk + Data([0xFF]), boardGeneration: original.boardGeneration,
                                        mutationVersion: original.mutationVersion, tombstoned: true,
                                        createdAt: original.createdAt, updatedAt: original.updatedAt,
                                        deletedAt: original.deletedAt))
        try context.save()

        XCTAssertFalse(store.restoreCanvas(canvasID))
        XCTAssertFalse(store.canvases.contains { $0.id == canvasID })
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<CanvasStrokeItem>(
            predicate: #Predicate { $0.id == strokeID }
        ))
        XCTAssertEqual(Set(rows.map(\.payload)), [originalInk, originalInk + Data([0xFF])], "neither copy was overwritten")
        XCTAssertTrue(rows.allSatisfy(\.tombstoned))
    }

    func testCanvasRestoreIsRefusedWhenImageReplicasHoldDifferentBytes() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let (store, canvasID, _) = try deletedCanvas(clock)
        let context = ModelContext(store.container)
        let board = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasBoardItem>(
            predicate: #Predicate { $0.id == canvasID }
        )).first)
        let imageID = UUID()
        for bytes in [Data([1, 2, 3]), Data([4, 5, 6])] {
            context.insert(CanvasImageItem(id: imageID, canvasID: canvasID, encodedData: bytes, pixelWidth: 1,
                                           pixelHeight: 1, mutationVersion: 7, tombstoned: true,
                                           createdAt: Date(timeIntervalSince1970: 50_000),
                                           updatedAt: board.deletedAt, deletedAt: board.deletedAt))
        }
        try countOneMoreHiddenObject(context, canvasID)
        try context.save()

        XCTAssertFalse(store.restoreCanvas(canvasID))
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<CanvasImageItem>(
            predicate: #Predicate { $0.id == imageID }
        ))
        XCTAssertEqual(Set(rows.map(\.encodedData)), [Data([1, 2, 3]), Data([4, 5, 6])], "neither copy was overwritten")
        XCTAssertTrue(rows.allSatisfy(\.tombstoned))
    }

    func testCanvasRestoreIsRefusedWhenObjectReplicasHoldDifferentPayloads() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let (store, canvasID, _) = try deletedCanvas(clock)
        let context = ModelContext(store.container)
        let board = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasBoardItem>(
            predicate: #Predicate { $0.id == canvasID }
        )).first)
        let objectID = UUID()
        for payload in [Data("first".utf8), Data("second".utf8)] {
            let row = CanvasSemanticObjectItem(id: objectID, canvasID: canvasID)
            row.payload = payload
            row.mutationVersion = 7
            row.tombstoned = true
            row.createdAt = Date(timeIntervalSince1970: 50_000)
            row.updatedAt = try XCTUnwrap(board.deletedAt)
            row.deletedAt = board.deletedAt
            context.insert(row)
        }
        try countOneMoreHiddenObject(context, canvasID)
        try context.save()

        XCTAssertFalse(store.restoreCanvas(canvasID))
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<CanvasSemanticObjectItem>(
            predicate: #Predicate { $0.id == objectID }
        ))
        XCTAssertEqual(Set(rows.map(\.payload)), [Data("first".utf8), Data("second".utf8)], "neither copy was overwritten")
        XCTAssertTrue(rows.allSatisfy(\.tombstoned))
    }


    func testCanvasRestoreIsRefusedWhenAReplicaWasPurgedOrContentIsMissing() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let (store, canvasID, _) = try deletedCanvas(clock)
        let context = ModelContext(store.container)
        let original = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.id == canvasID })).first)
        let purgedPeer = CanvasBoardItem(id: canvasID, name: "", sortIndex: original.sortIndex, tombstoned: true,
                                         createdAt: original.createdAt, deletedAt: original.deletedAt)
        purgedPeer.purgedAt = Date(timeIntervalSince1970: 50)
        context.insert(purgedPeer)
        try context.save()
        XCTAssertFalse(store.restoreCanvas(canvasID), "a replica already purged makes the restore incomplete")
        context.delete(purgedPeer)
        try context.save()

        try context.fetch(FetchDescriptor<CanvasStrokeItem>(predicate: #Predicate { $0.canvasID == canvasID })).forEach(context.delete)
        try context.save()
        XCTAssertFalse(store.restoreCanvas(canvasID), "the stroke the delete hid is gone")
        XCTAssertFalse(store.canvases.contains { $0.id == canvasID })
    }
}
