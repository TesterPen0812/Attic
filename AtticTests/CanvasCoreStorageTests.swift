import Foundation
import SwiftData
import XCTest
@testable import Attic

// Independent old schema definitions are used to create the fixture. Using
// today's CanvasStrokeItem here would never exercise additive migration.
private enum P4Legacy {
    @Model final class CanvasBoardItem {
        var id: UUID = UUID(); var name: String = "Canvas"; var sortIndex: Int64 = 0
        var clearGeneration: Int64 = 0; var mutationVersion: Int64 = 1; var tombstoned = false
        var createdAt = Date(); var updatedAt = Date(); var deletedAt: Date? = nil
        var formatVersion = 1; var tagsRaw: String = ""; var purgedAt: Date? = nil; var recentlyDeletedAt: Date? = nil; var deletedContentCount: Int64? = nil
        init(id: UUID) { self.id = id }
    }
    @Model final class CanvasStrokeItem {
        var id: UUID = UUID(); var canvasID: UUID = UUID(); var payloadVersion = 1
        var payload = Data(); var boardGeneration: Int64 = 0; var mutationVersion: Int64 = 1
        var tombstoned = false; var createdAt = Date(); var updatedAt = Date(); var deletedAt: Date? = nil
        init(id: UUID, canvasID: UUID, bytes: Data) { self.id = id; self.canvasID = canvasID; payload = bytes }
    }
    @Model final class CanvasImageItem {
        var id = UUID(); var canvasID = UUID(); @Attribute(.externalStorage) var encodedData = Data()
        var encodedByteCount: Int64 = 0; var contentDigest = ""; var contentType = "public.png"
        var pixelWidth: Int64 = 0; var pixelHeight: Int64 = 0; var centerX = 0.0; var centerY = 0.0
        var width = 1.0; var height = 1.0; var zIndex: Int64 = 0; var boardGeneration: Int64 = 0
        var mutationVersion: Int64 = 1; var tombstoned = false; var createdAt = Date(); var updatedAt = Date(); var deletedAt: Date? = nil
        init() {}
    }
    @Model final class CanvasSemanticObjectItem {
        var id = UUID(); var canvasID = UUID(); var kind = "text"; var payloadVersion = 1; var payload = Data()
        var centerX = 0.0; var centerY = 0.0; var width = 160.0; var height = 48.0; var rotation = 0.0
        var zIndex: Int64 = 0; var boardGeneration: Int64 = 0; var mutationVersion: Int64 = 1
        var tombstoned = false; var createdAt = Date(); var updatedAt = Date(); var deletedAt: Date? = nil
        init() {}
    }
}

private enum P4PreviousCandidate {
@Model
final class CanvasStrokeItem {
    /// Logical stroke identity. This deliberately has no SwiftData unique
    /// constraint because CloudKit cannot enforce one.
    var id: UUID = UUID()
    var canvasID: UUID = CanvasBoardItem.logicalBoardID
    var payloadVersion: Int = 1
    var payload: Data = Data()
    // Provisional v2 contract. Existing JSON is canonical and never replaced
    // by a cache. Spike A's remaining presentation evidence may change these
    // optional fields before the slice 3 migration/schema freeze.
    @Attribute(.externalStorage) var binaryPayload: Data? = nil
    var binaryDigest: String? = nil
    var boundsMinX: Double? = nil
    var boundsMinY: Double? = nil
    var boundsMaxX: Double? = nil
    var boundsMaxY: Double? = nil
    var offsetX: Double = 0
    var offsetY: Double = 0
    var rankOverride: Int64? = nil
    var boardGeneration: Int64 = 0
    var mutationVersion: Int64 = 1
    var tombstoned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        canvasID: UUID = CanvasBoardItem.logicalBoardID,
        payloadVersion: Int = 1,
        payload: Data = Data(),
        boardGeneration: Int64 = 0,
        mutationVersion: Int64 = 1,
        tombstoned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.canvasID = canvasID
        self.payloadVersion = payloadVersion
        self.payload = payload
        self.boardGeneration = boardGeneration
        self.mutationVersion = mutationVersion
        self.tombstoned = tombstoned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}

}

@MainActor
final class CanvasCoreStorageTests: XCTestCase {
    func testP4CopiedStoreAdditivePayloadKeepsEveryLegacyByteAndPhysicalWinner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("P4Copied-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("old"), copy = root.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let board = UUID(), logical = UUID(), date = Date(timeIntervalSince1970: 1_234)
        let good = Data(#"{"version":1,"color":"ink","width":3,"points":[{"x":0,"y":0},{"x":10,"y":20}]}"#.utf8)
        let unknown = Data([255, 11, 17])
        var beforeIDs: Set<Data> = []
        var beforeWinnerID = Data()
        try autoreleasepool {
            let schema = Schema([P4Legacy.CanvasBoardItem.self, P4Legacy.CanvasStrokeItem.self, P4Legacy.CanvasImageItem.self, P4Legacy.CanvasSemanticObjectItem.self])
            let container = try ModelContainer(for: schema, configurations: [.init("fixture", schema: schema, url: original.appendingPathComponent("fixture.store"), cloudKitDatabase: .none)])
            let context = ModelContext(container); context.autosaveEnabled = false
            let parent = P4Legacy.CanvasBoardItem(id: board); parent.clearGeneration = 3; parent.tagsRaw = "legacy"; context.insert(parent)
            for i in 0..<4 {
                let row = P4Legacy.CanvasStrokeItem(id: logical, canvasID: board, bytes: i == 3 ? unknown : good)
                row.mutationVersion = Int64(i + 1); row.boardGeneration = 3; row.createdAt = date; row.updatedAt = date
                row.tombstoned = i == 3; row.deletedAt = i == 3 ? date : nil; context.insert(row)
            }
            try context.save()
            let saved = try context.fetch(FetchDescriptor<P4Legacy.CanvasStrokeItem>())
            // NSManagedObjectID-backed equality is store-instance identity.
            // Compare SwiftData's durable, sorted-key identifier encoding
            // across the two independently opened containers instead.
            beforeIDs = Set(try saved.map { try WorkspaceModelFields.encode($0.persistentModelID) })
            beforeWinnerID = try WorkspaceModelFields.encode(saved.first { $0.mutationVersion == 4 }!.persistentModelID)
        }
        try FileManager.default.copyItem(at: original, to: copy)
        try autoreleasepool {
            let schema = Schema([CanvasBoardItem.self, CanvasStrokeItem.self, CanvasInkPayloadItem.self, CanvasImageItem.self, CanvasSemanticObjectItem.self])
            let container = try ModelContainer(for: schema, configurations: [.init("fixture", schema: schema, url: copy.appendingPathComponent("fixture.store"), cloudKitDatabase: .none)])
            let context = ModelContext(container); context.autosaveEnabled = false
            let rows = try context.fetch(FetchDescriptor<CanvasStrokeItem>())
            XCTAssertEqual(Set(try rows.map { try WorkspaceModelFields.encode($0.persistentModelID) }), beforeIDs)
            XCTAssertEqual(rows.map(\.payload).filter { $0 == good }.count, 3)
            XCTAssertEqual(rows.map(\.payload).filter { $0 == unknown }.count, 1)
            XCTAssertTrue(rows.allSatisfy { $0.binaryPayload == nil && $0.offsetX == 0 && $0.createdAt == date && $0.boardGeneration == 3 })
            let winner = try CanvasStore.winningStrokeReplica(in: rows)
            XCTAssertEqual(try WorkspaceModelFields.encode(winner.persistentModelID), beforeWinnerID)
            XCTAssertTrue(winner.tombstoned); XCTAssertEqual(winner.payload, unknown); XCTAssertEqual(winner.mutationVersion, 4)
            let legacyMetadata = try CanvasCoreMetadataQuery.strokes(canvasID: board, in: context)
            XCTAssertEqual(legacyMetadata.count, 4)
            XCTAssertEqual(Set(legacyMetadata.map(\.physicalURI)).count, 4)
            XCTAssertEqual(legacyMetadata.map(\.version).sorted(), [1, 2, 3, 4])
            XCTAssertTrue(legacyMetadata.first { $0.version == 4 }!.tombstoned)
            XCTAssertTrue(legacyMetadata.allSatisfy { $0.bounds == nil && $0.binaryRowID == nil })
            let new = CanvasStrokeItem(canvasID: board)
            let binary = try CanvasCoreInkCodec.encode(.init(color: "ink", width: 3,
                samples: (0..<CanvasCoreInkCodec.maximumSamples).map { .init(x: Double($0), y: 0, time: UInt64($0), pressure: nil) }))
            let payloadRow = CanvasInkPayloadItem(canvasID: board, strokeID: new.id); payloadRow.bytes = binary
            new.payloadVersion = 2; new.binaryRowID = payloadRow.id
            context.insert(new); context.insert(payloadRow); try context.save()
            let fresh = ModelContext(container)
            XCTAssertNil(try fresh.fetch(FetchDescriptor<CanvasStrokeItem>()).first { $0.id == new.id }?.binaryPayload)
            XCTAssertEqual(try fresh.fetch(FetchDescriptor<CanvasInkPayloadItem>()).first { $0.id == payloadRow.id }?.bytes, binary)
            XCTAssertEqual(try CanvasCoreInkCodec.decode(binary).samples.count, 81_000)
            XCTAssertEqual(try fresh.fetch(FetchDescriptor<CanvasStrokeItem>()).filter { $0.id == logical }.map(\.payload).filter { $0 == good }.count, 3)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("fixture.store").path))
    }
    func testP4PreviousCandidateStoreRetainsExperimentalBinaryColumnDuringAdditiveMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("P4Previous-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("old"), copy = root.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let board = UUID(), id = UUID(), date = Date(timeIntervalSince1970: 1234)
        let binary = try CanvasCoreInkCodec.encode(.init(color: "ink", width: 3,
            samples: [.init(x: 10, y: 20, time: 80_000, pressure: 0.5)]))
        let inline = Data([255, 17, 9])
        var physicalID = Data()
        try autoreleasepool {
            let schema = Schema([P4PreviousCandidate.CanvasStrokeItem.self])
            let container = try ModelContainer(for: schema, configurations: [.init("fixture", schema: schema,
                url: original.appendingPathComponent("fixture.store"), cloudKitDatabase: .none)])
            let context = ModelContext(container); context.autosaveEnabled = false
            let row = P4PreviousCandidate.CanvasStrokeItem(id: id, canvasID: board, payloadVersion: 2,
                payload: inline, mutationVersion: 7, createdAt: date)
            row.binaryPayload = binary; row.offsetX = 40; row.rankOverride = 8
            context.insert(row); try context.save()
            physicalID = try WorkspaceModelFields.encode(row.persistentModelID)
        }
        try FileManager.default.copyItem(at: original, to: copy)
        try autoreleasepool {
            let schema = Schema([CanvasStrokeItem.self, CanvasInkPayloadItem.self])
            let container = try ModelContainer(for: schema, configurations: [.init("fixture", schema: schema,
                url: copy.appendingPathComponent("fixture.store"), cloudKitDatabase: .none)])
            let context = ModelContext(container); context.autosaveEnabled = false
            let row = try XCTUnwrap(context.fetch(FetchDescriptor<CanvasStrokeItem>()).first)
            XCTAssertEqual(try WorkspaceModelFields.encode(row.persistentModelID), physicalID)
            XCTAssertEqual(row.binaryPayload, binary); XCTAssertEqual(row.payload, inline)
            XCTAssertEqual(row.id, id); XCTAssertEqual(row.canvasID, board)
            XCTAssertEqual(row.mutationVersion, 7); XCTAssertEqual(row.createdAt, date)
            XCTAssertEqual(row.offsetX, 40); XCTAssertEqual(row.rankOverride, 8)
            XCTAssertNil(row.binaryRowID)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<CanvasInkPayloadItem>()), 0)
            let metadata = try CanvasCoreMetadataQuery.strokes(canvasID: board, in: context)
            XCTAssertEqual(metadata.count, 1); XCTAssertEqual(metadata.first?.offsetX, 40)
            XCTAssertEqual(metadata.first?.payloadVersion, 2); XCTAssertEqual(metadata.first?.rank, 8)
        }
    }
    func testP4MetadataQueryBudgetRestrictedFetchOf20By2000LeavesBodiesUnrequested() throws {
        if ProcessInfo.processInfo.environment["ATTIC_P4_METADATA_SQL_PROOF"] == "1" {
            // Process-local diagnostic argument domain; no persistent defaults
            // or user store is changed. Run this case alone in a fresh host.
            UserDefaults.standard.setVolatileDomain(["com.apple.CoreData.SQLDebug": 1], forName: UserDefaults.argumentDomain)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("P4Metadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = Schema([CanvasStrokeItem.self, CanvasInkPayloadItem.self])
        let container = try ModelContainer(for: schema, configurations: [.init("fixture", schema: schema, url: root.appendingPathComponent("fixture.store"), cloudKitDatabase: .none)])
        let boards = (0..<20).map { _ in UUID() }
        let seed = ModelContext(container); seed.autosaveEnabled = false
        let legacy = Data(("{\"version\":1,\"color\":\"ink\",\"width\":3,\"points\":[" +
            (0..<400).map { "{\"x\":\($0),\"y\":\($0 % 7)}" }.joined(separator: ",") + "]}").utf8)
        let binary = try CanvasCoreInkCodec.encode(.init(color: "ink", width: 3,
            samples: (0..<400).map { .init(x: Double($0), y: Double($0 % 7), time: UInt64($0 * 8_000), pressure: nil) }))
        for board in boards { for i in 0..<2_000 {
            let row = CanvasStrokeItem(canvasID: board, payload: legacy)
            if i % 2 == 1 {
                let payloadRow = CanvasInkPayloadItem(canvasID: board, strokeID: row.id)
                payloadRow.bytes = binary
                row.payload = Data(); row.payloadVersion = 2; row.binaryRowID = payloadRow.id
                seed.insert(payloadRow)
            }
            row.boundsMinX = Double(i); row.boundsMaxX = Double(i + 1); row.boundsMinY = 0; row.boundsMaxY = 1
            seed.insert(row)
        } }
        try seed.save()
        // CI additionally inspects Core Data's emitted SQL for the restricted
        // SELECT. Getter-count assertions alone would not prove projection.
        print("P4_METADATA_QUERY_BEGIN")
        fflush(stdout)
        let context = ModelContext(container); context.autosaveEnabled = false
        let rows = try CanvasCoreMetadataQuery.strokes(canvasID: boards[0], in: context)
        print("P4_METADATA_QUERY_END")
        fflush(stdout)
        XCTAssertEqual(rows.count, 2_000, "P4MetadataQueryBudget")
        XCTAssertTrue(rows.allSatisfy { $0.canvasID == boards[0] && $0.bounds != nil })
        XCTAssertEqual(Set(rows.map(\.physicalURI)).count, 2_000)
        XCTAssertEqual(rows.filter { $0.binaryRowID != nil }.count, 1_000)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<CanvasStrokeItem>()), 40_000)
    }
}
