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
            let schema = Schema([CanvasBoardItem.self, CanvasStrokeItem.self, CanvasImageItem.self, CanvasSemanticObjectItem.self])
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
            let new = CanvasStrokeItem(canvasID: board)
            let binary = try CanvasCoreInkCodec.encode(.init(color: "ink", width: 3,
                samples: (0..<CanvasCoreInkCodec.maximumSamples).map { .init(x: Double($0), y: 0, time: UInt64($0), pressure: nil) }))
            new.payloadVersion = 2; new.binaryPayload = binary; context.insert(new); try context.save()
            let fresh = ModelContext(container)
            XCTAssertEqual(try fresh.fetch(FetchDescriptor<CanvasStrokeItem>()).first { $0.id == new.id }?.binaryPayload, binary)
            XCTAssertEqual(try CanvasCoreInkCodec.decode(binary).samples.count, 81_000)
            XCTAssertEqual(try fresh.fetch(FetchDescriptor<CanvasStrokeItem>()).filter { $0.id == logical }.map(\.payload).filter { $0 == good }.count, 3)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("fixture.store").path))
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
        let schema = Schema([CanvasStrokeItem.self])
        let container = try ModelContainer(for: schema, configurations: [.init("fixture", schema: schema, url: root.appendingPathComponent("fixture.store"), cloudKitDatabase: .none)])
        let boards = (0..<20).map { _ in UUID() }
        let seed = ModelContext(container); seed.autosaveEnabled = false
        for board in boards { for i in 0..<2_000 {
            let row = CanvasStrokeItem(canvasID: board, payload: Data(repeating: UInt8(i % 255), count: 64))
            row.binaryPayload = Data(repeating: 17, count: 4_096)
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
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<CanvasStrokeItem>()), 40_000)
    }
}
