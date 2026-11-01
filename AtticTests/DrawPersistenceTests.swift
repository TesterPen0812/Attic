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
    }

    func testPersistentClipboardContract() throws {
        try DrawStoreContractTests().clipboardContract(DrawPersistentStore(container: container()))
    }

    func testPersistentTypingAndDeletedImagesContract() throws {
        try DrawStoreContractTests().typingContract(DrawPersistentStore(container: container()))
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
