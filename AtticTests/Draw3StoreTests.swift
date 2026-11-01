import Foundation
import SwiftData
import XCTest
@testable import Attic

/// Draw job 3, the store: quiet thumbnail writes, Delete Permanently, Empty
/// and the 30-day removal across replicas, and the library-wide
/// `deletedImages()` from metadata only.
@MainActor
final class Draw3StoreTests: XCTestCase {
    private struct Injected: Error {}

    /// A clock the test moves on.
    private final class Clock {
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func now() -> Date { date }
        func advance(_ seconds: TimeInterval = 60) { date = date.addingTimeInterval(seconds) }
    }

    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        AtticDraw.enabledOverride = true
    }

    override func tearDown() {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        AtticDraw.enabledOverride = nil
        super.tearDown()
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(PersistenceController.appModelTypes), configurations:
            ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func image(bytes: Int = 64) -> DrawObject {
        DrawObject(frame: DrawFrame(x: 10, y: 10, width: 40, height: 20),
                   content: .image(DrawImage(original: Data((0..<bytes).map { UInt8($0 % 251) }), pixelWidth: 80, pixelHeight: 40,
                                             contentType: "public.png")))
    }

    private func stroke() -> DrawObject {
        DrawObject(content: .stroke([DrawPoint(x: 1, y: 2), DrawPoint(x: 30, y: 40)]))
    }

    // MARK: Thumbnails

    func testThumbnailWriteSkipsUndoKeepsTheDateAndTheOrder() throws {
        let clock = Clock(), container = try container()
        let store = DrawPersistentStore(container: container, now: clock.now)
        let a = store.create(name: "A")
        XCTAssertTrue(store.perform(.put([stroke()]), on: a.id).isSaved)
        clock.advance()
        let b = store.create(name: "B")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("b"))]), on: b.id).isSaved)
        let order = try store.library().map(\.id)
        XCTAssertEqual(order, [b.id, a.id])
        let date = try XCTUnwrap(store.library().first { $0.id == a.id }?.updatedAt)
        clock.advance()

        let bytes = Data([1, 2, 3, 4])
        XCTAssertTrue(store.perform(.thumbnail(bytes), on: a.id).isSaved)
        let after = try store.library()
        XCTAssertEqual(after.map(\.id), order, "A thumbnail never moves a canvas in the menu")
        XCTAssertEqual(after.first { $0.id == a.id }?.updatedAt, date, "A thumbnail never changes the canvas's date")
        XCTAssertEqual(after.first { $0.id == a.id }?.thumbnail, bytes)
        XCTAssertFalse(store.hasUnsettledEdits)

        // Undo still undoes the stroke, and only the stroke.
        XCTAssertTrue(store.undo(on: a.id).isSaved)
        XCTAssertTrue(try store.open(a.id).objects.isEmpty)
        XCTAssertFalse(store.canUndo(on: a.id), "The thumbnail was never an Undo step")
        XCTAssertEqual(try DrawPersistentStore(container: container).library(deleted: false).first { $0.id == a.id }?.thumbnail,
                       bytes, "Undoing an earlier edit keeps the newer thumbnail")
    }

    func testAFailedThumbnailWriteNeverBlocksTheNextEdit() throws {
        var fail = true
        let store = DrawPersistentStore(container: try container(), save: { context in
            if fail { throw Injected() }
            try context.save()
        })
        let board = store.create()
        fail = false
        XCTAssertTrue(store.perform(.put([stroke()]), on: board.id).isSaved)
        fail = true
        XCTAssertFalse(store.perform(.thumbnail(Data([9])), on: board.id).isSaved)
        XCTAssertFalse(store.hasUnsettledEdits, "A thumbnail is not an edit: nothing waits for Retry")
        fail = false
        XCTAssertTrue(store.perform(.put([stroke()]), on: board.id).isSaved)
        XCTAssertTrue(store.canUndo(on: board.id))
    }

    // MARK: Permanent delete

    func testDeletePermanentlyRemovesEveryReplicaOfACanvasAndAnImage() throws {
        let container = try container()
        let store = DrawPersistentStore(container: container)
        let gone = store.create(name: "Gone")
        let goneImage = image()
        XCTAssertTrue(store.perform(.put([goneImage, stroke()]), on: gone.id).isSaved)
        XCTAssertTrue(store.perform(.thumbnail(Data([7])), on: gone.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: gone.id).isSaved)
        let kept = store.create(name: "Kept")
        let picture = image(bytes: 90), note = DrawObject(content: .text("stays"))
        XCTAssertTrue(store.perform(.put([picture, note]), on: kept.id).isSaved)
        XCTAssertTrue(store.perform(.remove([picture.id]), on: kept.id).isSaved)

        // Imported replicas of the canvas, its image and the picture.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for row in try context.fetch(FetchDescriptor<DrawCanvasRecord>()) where row.id == gone.id { context.insert(row.copy()) }
        for row in try context.fetch(FetchDescriptor<DrawObjectRecord>()) where row.id == goneImage.id || row.id == picture.id {
            context.insert(row.copy())
        }
        for row in try context.fetch(FetchDescriptor<DrawPayloadRecord>()) where row.id == picture.id { context.insert(row.copy()) }
        try context.save()

        let deletedCanvas = try XCTUnwrap(store.library(deleted: true).first)
        let deletedImage = try XCTUnwrap(store.deletedImages().first)
        XCTAssertEqual(deletedImage.object.id, picture.id)
        let report = store.purge([.canvas(gone.id, deletedAt: try XCTUnwrap(deletedCanvas.deletedAt)),
                                  .image(canvas: kept.id, object: picture.id, deletedAt: try XCTUnwrap(deletedImage.object.deletedAt))])
        XCTAssertEqual(report, DrawPurgeReport(removed: 2, kept: 0))

        let fresh = ModelContext(container)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<DrawCanvasRecord>()).allSatisfy { $0.id == kept.id })
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<DrawObjectRecord>()).allSatisfy { $0.canvasID == kept.id && $0.id != picture.id })
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<DrawPayloadRecord>()).allSatisfy { $0.canvasID == kept.id && $0.id != picture.id })
        XCTAssertTrue(try store.library(deleted: true).isEmpty)
        XCTAssertTrue(try store.deletedImages().isEmpty)
        XCTAssertEqual(try store.open(kept.id).objects.map(\.id), [note.id])
        XCTAssertEqual(try DrawPersistentStore(container: container).open(kept.id).objects.map(\.id), [note.id])
    }

    func testPurgeIsSkippedWhileReplicasDisagreeOrTheDeletionMoved() throws {
        let container = try container()
        let store = DrawPersistentStore(container: container)
        let board = store.create(name: "Board")
        XCTAssertTrue(store.perform(.put([stroke()]), on: board.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: board.id).isSaved)
        let live = store.create(name: "Live")
        let picture = image()
        XCTAssertTrue(store.perform(.put([picture]), on: live.id).isSaved)
        XCTAssertTrue(store.perform(.remove([picture.id]), on: live.id).isSaved)
        let canvasDate = try XCTUnwrap(store.library(deleted: true).first?.deletedAt)
        let imageDate = try XCTUnwrap(store.deletedImages().first?.object.deletedAt)

        // A divergent canvas replica and a divergent image replica.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let canvas = try XCTUnwrap(context.fetch(FetchDescriptor<DrawCanvasRecord>()).first { $0.id == board.id }).copy()
        canvas.name = "Other device"
        context.insert(canvas)
        let object = try XCTUnwrap(context.fetch(FetchDescriptor<DrawObjectRecord>()).first { $0.id == picture.id }).copy()
        object.zIndex += 5
        context.insert(object)
        try context.save()

        let targets: [DrawPurgeTarget] = [.canvas(board.id, deletedAt: canvasDate),
                                          .image(canvas: live.id, object: picture.id, deletedAt: imageDate)]
        XCTAssertEqual(store.purge(targets), DrawPurgeReport(removed: 0, kept: 2))
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<DrawCanvasRecord>()).filter { $0.id == board.id }.count, 2)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<DrawObjectRecord>()).filter { $0.id == picture.id }.count, 2)

        // Once they agree, they go; a target whose deletion moved stays.
        for row in try fresh.fetch(FetchDescriptor<DrawCanvasRecord>()) where row.id == board.id { row.name = "Board" }
        for row in try fresh.fetch(FetchDescriptor<DrawObjectRecord>()) where row.id == picture.id { row.zIndex = object.zIndex - 5 }
        try fresh.save()
        XCTAssertEqual(store.purge([.canvas(board.id, deletedAt: canvasDate.addingTimeInterval(1))]), DrawPurgeReport(removed: 0, kept: 1))
        XCTAssertEqual(store.purge(targets), DrawPurgeReport(removed: 2, kept: 0))
    }

    func testThirtyDayRemovalTakesOnlyWhatIsOlderThanThirtyDays() throws {
        let clock = Clock(), container = try container(), calendar = Calendar(identifier: .gregorian)
        let store = DrawPersistentStore(container: container, now: clock.now)
        let old = store.create(name: "Old")
        XCTAssertTrue(store.perform(.put([stroke()]), on: old.id).isSaved)
        let host = store.create(name: "Host")
        let oldImage = image(), newImage = image(bytes: 70)
        XCTAssertTrue(store.perform(.put([oldImage, newImage]), on: host.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: old.id).isSaved)
        XCTAssertTrue(store.perform(.remove([oldImage.id]), on: host.id).isSaved)
        clock.advance(20 * 86_400)
        let recent = store.create(name: "Recent")
        XCTAssertTrue(store.perform(.put([stroke()]), on: recent.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: recent.id).isSaved)
        XCTAssertTrue(store.perform(.remove([newImage.id]), on: host.id).isSaved)
        clock.advance(11 * 86_400)

        let report = DrawRecentlyDeleted.purgeExpired(store: store, now: clock.now(), calendar: calendar)
        XCTAssertEqual(report.removed, 2)
        XCTAssertEqual(try store.library(deleted: true).map(\.id), [recent.id])
        XCTAssertEqual(try store.deletedImages().map(\.object.id), [newImage.id])
        XCTAssertEqual(try store.library().map(\.id), [host.id])
    }

    func testThirtyDayRemovalSkipsDisagreeingReplicas() throws {
        let clock = Clock(), container = try container()
        let store = DrawPersistentStore(container: container, now: clock.now)
        let board = store.create(name: "Board")
        XCTAssertTrue(store.perform(.put([stroke()]), on: board.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: board.id).isSaved)
        let context = ModelContext(container)
        let copy = try XCTUnwrap(context.fetch(FetchDescriptor<DrawCanvasRecord>()).first).copy()
        copy.textIndex = "diverged"
        context.insert(copy)
        try context.save()
        clock.advance(40 * 86_400)
        XCTAssertEqual(DrawRecentlyDeleted.purgeExpired(store: store, now: clock.now(), calendar: .current).kept, 1)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<DrawCanvasRecord>()).count, 2)
    }

    // MARK: Recently Deleted

    func testDeletedImagesReadsMetadataOnly() throws {
        let container = try container()
        let writer = DrawPersistentStore(container: container)
        var expected: Set<UUID> = []
        for name in ["One", "Two"] {
            let canvas = writer.create(name: name)
            let picture = image(bytes: 200_000), other = image(bytes: 100_000)
            XCTAssertTrue(writer.perform(.put([picture, other, stroke()]), on: canvas.id).isSaved)
            XCTAssertTrue(writer.perform(.thumbnail(Data(repeating: 3, count: 5_000)), on: canvas.id).isSaved)
            XCTAssertTrue(writer.perform(.remove([picture.id]), on: canvas.id).isSaved)
            expected.insert(picture.id)
        }
        let reader = DrawPersistentStore(container: container)
        reader.metrics.reset()
        let found = try reader.deletedImages()
        XCTAssertEqual(Set(found.map(\.object.id)), expected)
        XCTAssertEqual(reader.metrics.payloadBytesRead, 0, "No original bytes are read")
        XCTAssertEqual(reader.metrics.thumbnailBytesRead, 0, "No thumbnails are read")
        XCTAssertEqual(reader.metrics.objectRowsRead, 2, "Only deleted object rows are read")
        for entry in found {
            guard case .image(let header) = entry.object.content else { return XCTFail("Not an image") }
            XCTAssertTrue(header.original.isEmpty)
            XCTAssertEqual(header.pixelWidth, 80)
            XCTAssertNil(entry.canvas.thumbnail)
        }
        XCTAssertEqual(Set(found.map(\.canvas.name)), ["One", "Two"])
    }

    func testRecentlyDeletedDeletesDrawRowsPermanentlyAndEmpties() throws {
        let store = DrawPersistentStore(container: try container())
        let first = store.create(name: "First"), second = store.create(name: "Second"), host = store.create(name: "Host")
        let picture = image()
        XCTAssertTrue(store.perform(.put([stroke()]), on: first.id).isSaved)
        XCTAssertTrue(store.perform(.put([stroke()]), on: second.id).isSaved)
        XCTAssertTrue(store.perform(.put([picture, stroke()]), on: host.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: first.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: second.id).isSaved)
        XCTAssertTrue(store.perform(.remove([picture.id]), on: host.id).isSaved)

        let model = RecentlyDeletedModel(library: nil, draw: { store })
        model.reload()
        XCTAssertEqual(model.entries.count, 3)
        XCTAssertTrue(model.entries.allSatisfy(\.canDeletePermanently))
        let firstEntry = try XCTUnwrap(model.entries.first { $0.title == "First" })
        model.requestDelete([firstEntry])
        XCTAssertEqual(model.emptyRequest?.count, 1)
        model.confirmEmpty()
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Second", "Image"])
        XCTAssertTrue(try store.library(deleted: true).allSatisfy { $0.id == second.id })

        model.requestEmpty()
        XCTAssertEqual(model.emptyRequest?.count, 2)
        model.confirmEmpty()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(try store.library(deleted: true).isEmpty)
        XCTAssertTrue(try store.deletedImages().isEmpty)
        XCTAssertEqual(try store.library().map(\.id), [host.id])
    }
}

// Test-only replica fixtures: production never inserts replicas deliberately.
extension DrawCanvasRecord {
    func copy() -> DrawCanvasRecord {
        let copy = DrawCanvasRecord()
        copy.id = id; copy.name = name; copy.tagsJSON = tagsJSON
        copy.createdAt = createdAt; copy.updatedAt = updatedAt; copy.deletedAt = deletedAt
        copy.thumbnailID = thumbnailID; copy.textIndex = textIndex
        return copy
    }
}

extension DrawObjectRecord {
    func copy() -> DrawObjectRecord {
        let copy = DrawObjectRecord()
        copy.id = id; copy.canvasID = canvasID; copy.header = header; copy.formatVersion = formatVersion
        copy.zIndex = zIndex; copy.deletedAt = deletedAt; copy.textIndex = textIndex; copy.payloadDigest = payloadDigest
        return copy
    }
}

extension DrawPayloadRecord {
    func copy() -> DrawPayloadRecord {
        let copy = DrawPayloadRecord()
        copy.id = id; copy.canvasID = canvasID; copy.role = role; copy.formatVersion = formatVersion
        copy.digest = digest; copy.bytes = bytes
        return copy
    }
}
