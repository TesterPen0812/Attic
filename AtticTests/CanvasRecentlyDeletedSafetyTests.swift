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
