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

    func testPF22ColdOpenFetchesPayloadsInBatchesWithoutChangingObjects() throws {
        let container = try container()
        let seeded = ModelContext(container)
        seeded.autosaveEnabled = false
        let canvas = DrawCanvas(name: "Payload load")
        let canvasRecord = DrawCanvasRecord()
        try canvasRecord.apply(canvas)
        seeded.insert(canvasRecord)
        let sample = [DrawPoint(x: 1, y: 3, pressure: 0.4), DrawPoint(x: 2, y: 4, pressure: 1)]
        let objects = (0..<2_000).map { index in
            DrawObject(frame: DrawFrame(x: Double(index), y: 2, width: 2, height: 1),
                       zIndex: Int64(index), content: .stroke(sample))
        }
        for object in objects {
            let row = DrawObjectRecord()
            try row.apply(object, canvasID: canvas.id)
            seeded.insert(row)
            let payload = DrawPayloadRecord()
            payload.apply(try XCTUnwrap(DrawCodec.payload(object)), id: object.id, canvasID: canvas.id, role: "object")
            seeded.insert(payload)
        }
        try seeded.save()

        let reader = DrawPersistentStore(container: container)
        reader.metrics.reset()
        let found = try reader.open(canvas.id)
        XCTAssertEqual(found.objects, objects)
        XCTAssertGreaterThan(reader.metrics.payloadBytesRead, 0)
        XCTAssertLessThanOrEqual(reader.metrics.payloadFetches, 4,
                                 "opening thousands of binary objects must issue a bounded number of payload queries")
        print("DRAW_PF22_REMAINING_MAIN_DECODES=\(reader.metrics.payloadDecodesOnMain)")
    }

    func testPF23SearchFiltersMetadataBeforeReadingThumbnailsAndReusesItAcrossQueries() throws {
        let container = try container()
        let seeded = ModelContext(container)
        seeded.autosaveEnabled = false
        let bytes = Data(repeating: 37, count: 256)
        for index in 0..<500 {
            let canvas = DrawCanvas(name: "Board \(index)", thumbnail: bytes)
            let record = DrawCanvasRecord()
            try record.apply(canvas)
            seeded.insert(record)
            let payload = DrawPayloadRecord()
            payload.apply(bytes, id: canvas.id, canvasID: canvas.id, role: "thumbnail")
            seeded.insert(payload)
        }
        try seeded.save()

        let reader = DrawPersistentStore(container: container)
        reader.metrics.reset()
        for query in ["Missing A", "Missing B", "Missing C", "Missing D"] {
            XCTAssertTrue(try reader.search(query).isEmpty)
        }
        XCTAssertEqual(reader.metrics.thumbnailBytesRead, 0, "nonmatches must never hydrate thumbnail bytes")
        XCTAssertEqual(reader.metrics.metadataRowsRead, 500,
                       "typing at one metadata revision must reuse the canvas summaries")
        let found = try reader.search("Board 499")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.canvas.thumbnail, bytes, "a visible match retains its original thumbnail")
        XCTAssertEqual(reader.metrics.thumbnailBytesRead, bytes.count,
                       "hydrate only the matched canvas")
        let broad = try reader.search("Board")
        XCTAssertEqual(broad.count, 500)
        XCTAssertLessThanOrEqual(reader.metrics.thumbnailBytesRead - bytes.count, 12 * bytes.count,
                                 "a broad search must defer offscreen thumbnail bodies until those rows appear")
        let offscreen = try XCTUnwrap(broad.last)
        XCTAssertNil(offscreen.canvas.thumbnail)
        XCTAssertEqual(try reader.searchThumbnail(offscreen.canvas.id)?.thumbnail, bytes,
                       "scrolling a matching row into view can fetch its existing thumbnail")
        XCTAssertLessThanOrEqual(reader.metrics.thumbnailBytesRead - bytes.count, 13 * bytes.count)
        reader.metrics.thumbnailBytesRead = 0
        let menu = try reader.presentationLibrary()
        XCTAssertEqual(menu.count, 500)
        XCTAssertLessThanOrEqual(reader.metrics.thumbnailBytesRead, 12 * bytes.count,
                                 "the unfiltered menu must avoid reading hundreds of offscreen thumbnails")
    }

    func testR6ThumbnailWritesOnOtherCanvasesLeaveRealizedRowsCachedBodiesAlone() throws {
        let container = try container()
        let seeded = ModelContext(container)
        seeded.autosaveEnabled = false
        let bytes = Data(repeating: 37, count: 256)
        for index in 0..<120 {
            let canvas = DrawCanvas(name: "Board \(index)", thumbnail: bytes)
            let record = DrawCanvasRecord()
            try record.apply(canvas)
            seeded.insert(record)
            let payload = DrawPayloadRecord()
            payload.apply(bytes, id: canvas.id, canvasID: canvas.id, role: "thumbnail")
            seeded.insert(payload)
        }
        try seeded.save()

        let reader = DrawPersistentStore(container: container)
        let menu = try reader.presentationLibrary()
        let realized = menu[12..<24].map(\.id)
        for id in realized { XCTAssertEqual(try reader.searchThumbnail(id)?.thumbnail, bytes) }
        let other = menu[0].id
        var reread = 0
        for index in 0..<10 {
            XCTAssertTrue(reader.perform(.thumbnail(Data(repeating: UInt8(100 + index), count: 64), dark: true), on: other).isSaved)
            reader.metrics.reset()
            for id in realized { XCTAssertEqual(try reader.searchThumbnail(id)?.thumbnail, bytes) }
            reread += reader.metrics.metadataRowsRead + reader.metrics.thumbnailBytesRead
        }
        XCTAssertEqual(reread, 0,
                       "a thumbnail write on another canvas must not refetch the realized rows' metadata or bodies")
        let own = realized[0]
        let fresh = Data(repeating: 9, count: 64)
        XCTAssertTrue(reader.perform(.thumbnail(fresh, dark: true), on: own).isSaved)
        XCTAssertEqual(try reader.searchThumbnail(own)?.thumbnail, fresh, "a canvas's own write is seen at once")
        XCTAssertTrue(reader.perform(.thumbnail(nil, dark: true), on: own).isSaved)
        XCTAssertNil(try reader.searchThumbnail(own)?.thumbnail, "a cleared thumbnail is seen at once")
    }

    func testGuardedAgentDrawWriteRefusesDivergentPhysicalCanvasAndObjectReplicas() throws {
        let container = try container()
        let draw = DrawPersistentStore(container: container)
        let canvas = draw.create(name: "Original")
        let object = DrawObject(content: .text("Original"))
        XCTAssertTrue(draw.perform(.put([object]), on: canvas.id).isSaved)

        let seeded = ModelContext(container)
        seeded.autosaveEnabled = false
        let originalCanvas = try XCTUnwrap(seeded.fetch(FetchDescriptor<DrawCanvasRecord>())
            .first { $0.id == canvas.id })
        let otherCanvas = originalCanvas.copy()
        otherCanvas.name = "Owner's other canvas"
        otherCanvas.updatedAt = originalCanvas.updatedAt.addingTimeInterval(-10)
        seeded.insert(otherCanvas)
        let originalObject = try XCTUnwrap(seeded.fetch(FetchDescriptor<DrawObjectRecord>())
            .first { $0.id == object.id })
        let otherObject = originalObject.copy()
        otherObject.header = originalObject.header.replacingOccurrences(of: "Original", with: "AAAA")
        otherObject.textIndex = "AAAA"
        seeded.insert(otherObject)
        try seeded.save()

        XCTAssertFalse(draw.performAgent(.rename("Agent rename"), on: canvas.id).isSaved)
        let fresh = ModelContext(container)
        XCTAssertEqual(Set(try fresh.fetch(FetchDescriptor<DrawCanvasRecord>())
            .filter { $0.id == canvas.id }.map(\.name)), ["Original", "Owner's other canvas"])

        // Once the canvas family agrees, the independently divergent object
        // family still must stop the next agent write.
        let repair = ModelContext(container)
        let canvases = try repair.fetch(FetchDescriptor<DrawCanvasRecord>())
        let canonical = try XCTUnwrap(canvases.first { $0.id == canvas.id && $0.name == "Original" })
        for row in canvases where row.id == canvas.id {
            row.name = canonical.name
            row.updatedAt = canonical.updatedAt
        }
        try repair.save()
        let moved = DrawObject(id: object.id, frame: DrawFrame(x: 4, y: 5, width: 100, height: 50),
                               content: .text("Original"))
        XCTAssertFalse(draw.performAgent(.put([moved]), on: canvas.id).isSaved,
                       "Divergent object replicas must refuse the whole agent write")
        XCTAssertEqual(Set(try ModelContext(container).fetch(FetchDescriptor<DrawObjectRecord>())
            .filter { $0.id == object.id }.map(\.textIndex)), ["Original", "AAAA"])
    }

    func testRecoveredDrawUndoRefusesDivergentReplicaAndAgreedReplicasBothMutate() throws {
        let container = try container()
        let draw = DrawPersistentStore(container: container)
        let board = draw.create(name: "Before")
        XCTAssertTrue(draw.perform(.put([stroke()]), on: board.id).isSaved)
        XCTAssertTrue(draw.perform(.rename("After"), on: board.id).isSaved)
        let step = try XCTUnwrap(draw.undoStepID(on: board.id))
        let proof = try XCTUnwrap(draw.agentUndoProof(on: board.id, stepID: step))
        let context = ModelContext(container)
        let copy = try XCTUnwrap(context.fetch(FetchDescriptor<DrawCanvasRecord>())
            .first { $0.id == board.id }).copy()
        copy.name = "Owner's revision"
        copy.updatedAt = copy.updatedAt.addingTimeInterval(-10)
        context.insert(copy)
        try context.save()

        let recovered = DrawPersistentStore(container: container)
        XCTAssertFalse(recovered.undoAgentStep(on: board.id, proof: proof).isSaved)
        let rows = try ModelContext(container).fetch(FetchDescriptor<DrawCanvasRecord>()).filter { $0.id == board.id }
        XCTAssertEqual(Set(rows.map(\.name)), ["After", "Owner's revision"])

        let reconcile = ModelContext(container)
        let original = try XCTUnwrap(rows.first { $0.name == "After" })
        for row in try reconcile.fetch(FetchDescriptor<DrawCanvasRecord>()) where row.id == board.id {
            row.name = "After"
            row.updatedAt = original.updatedAt
        }
        try reconcile.save()
        XCTAssertTrue(DrawPersistentStore(container: container).undoAgentStep(on: board.id, proof: proof).isSaved)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<DrawCanvasRecord>())
            .filter { $0.id == board.id }.map(\.name), ["Before", "Before"])
    }

    // MARK: Thumbnails

    func testThumbnailWriteSkipsUndoKeepsTheDateAndTheOrder() throws {
        let clock = Clock(), container = try container()
        let store = DrawPersistentStore(container: container, now: clock.now)
        let a = store.create(name: "A")
        let first = stroke(), second = stroke()
        XCTAssertTrue(store.perform(.put([first]), on: a.id).isSaved)
        XCTAssertTrue(store.perform(.put([second]), on: a.id).isSaved)
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

        // Undo still undoes the strokes, and only the strokes.
        XCTAssertTrue(store.undo(on: a.id).isSaved)
        XCTAssertEqual(try store.open(a.id).objects, [first])
        XCTAssertEqual(try DrawPersistentStore(container: container).library().first { $0.id == a.id }?.thumbnail,
                       bytes, "Undoing an earlier edit keeps the newer thumbnail")
        XCTAssertTrue(store.undo(on: a.id).isSaved)
        XCTAssertTrue(try store.open(a.id).objects.isEmpty)
        XCTAssertFalse(store.canUndo(on: a.id), "The thumbnail was never an Undo step")
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

    // MARK: Batch 3: payload replicas before a purge

    /// A deleted canvas with an image, and a deleted image on a live canvas,
    /// whose object headers agree; only their payload rows are replicated.
    private func payloadReplicaFixture(_ store: DrawPersistentStore, container: ModelContainer,
                                       _ diverge: (DrawPayloadRecord) -> Void) throws -> (targets: [DrawPurgeTarget], ids: Set<UUID>) {
        let board = store.create(name: "Board"), boardImage = image()
        XCTAssertTrue(store.perform(.put([boardImage]), on: board.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: board.id).isSaved)
        let host = store.create(name: "Host"), picture = image(bytes: 90)
        XCTAssertTrue(store.perform(.put([picture, stroke()]), on: host.id).isSaved)
        XCTAssertTrue(store.perform(.remove([picture.id]), on: host.id).isSaved)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for row in try context.fetch(FetchDescriptor<DrawPayloadRecord>()) where row.id == boardImage.id || row.id == picture.id {
            let copy = row.copy()
            diverge(copy)
            context.insert(copy)
        }
        try context.save()
        let canvasDate = try XCTUnwrap(store.library(deleted: true).first { $0.id == board.id }?.deletedAt)
        let imageDate = try XCTUnwrap(store.deletedImages().first { $0.object.id == picture.id }?.object.deletedAt)
        return ([.canvas(board.id, deletedAt: canvasDate), .image(canvas: host.id, object: picture.id, deletedAt: imageDate)],
                [boardImage.id, picture.id])
    }

    private func payloadRows(_ container: ModelContainer, _ ids: Set<UUID>) throws -> Int {
        try ModelContext(container).fetch(FetchDescriptor<DrawPayloadRecord>()).filter { ids.contains($0.id) }.count
    }

    func testDisagreeingPayloadReplicasSurviveDeletePermanently() throws {
        let divergences: [(String, (DrawPayloadRecord) -> Void)] = [
            ("a different original", { $0.apply(Data([1, 2, 3]), id: $0.id, canvasID: $0.canvasID, role: $0.role) }),
            ("the same digest over different bytes", { $0.bytes = Data([4, 5, 6]) }),
            ("a different parent", { $0.canvasID = UUID() }),
        ]
        for (name, diverge) in divergences {
            let container = try container()
            let store = DrawPersistentStore(container: container)
            let fixture = try payloadReplicaFixture(store, container: container, diverge)
            XCTAssertEqual(store.purge(fixture.targets), DrawPurgeReport(removed: 0, kept: 2), "Kept with \(name)")
            XCTAssertEqual(try payloadRows(container, fixture.ids), 4, "Every payload replica stays with \(name)")
            XCTAssertEqual(try store.library(deleted: true).count, 1)
            XCTAssertEqual(try store.deletedImages().count, 1)
        }
    }

    func testDisagreeingPayloadReplicasSurviveEmptyAndTheThirtyDayRemoval() throws {
        let clock = Clock(), container = try container()
        let store = DrawPersistentStore(container: container, now: clock.now)
        let fixture = try payloadReplicaFixture(store, container: container) {
            $0.apply(Data([1, 2, 3]), id: $0.id, canvasID: $0.canvasID, role: $0.role)
        }
        let model = RecentlyDeletedModel(library: nil, draw: { store })
        model.reload()
        model.requestEmpty()
        model.confirmEmpty()
        XCTAssertEqual(try payloadRows(container, fixture.ids), 4, "Empty keeps disagreeing payloads")
        XCTAssertEqual(try store.library(deleted: true).count, 1)
        XCTAssertEqual(try store.deletedImages().count, 1)
        clock.advance(40 * 86_400)
        XCTAssertEqual(DrawRecentlyDeleted.purgeExpired(store: store, now: clock.now(), calendar: .current),
                       DrawPurgeReport(removed: 0, kept: 2))
        XCTAssertEqual(try payloadRows(container, fixture.ids), 4, "The 30-day removal keeps them too")
    }

    /// E-4: a confirmed purge with only kept Draw rows is not an emptying.
    func testE4KeptDrawRowsDoNotPlayEmptiedAndKeepWarning() throws {
        let container = try container()
        let store = DrawPersistentStore(container: container)
        let fixture = try payloadReplicaFixture(store, container: container) {
            $0.apply(Data([1, 2, 3]), id: $0.id, canvasID: $0.canvasID, role: $0.role)
        }
        XCTAssertEqual(store.purge(fixture.targets), DrawPurgeReport(removed: 0, kept: 2))

        var cues: [AtticSounds.Cue] = []
        let sounds = AtticSounds.shared
        sounds.lastPlayed = -.infinity
        sounds.settingEnabled = { true }
        sounds.systemAllows = { true }
        sounds.clock = { 20_000 }
        sounds.output = { cues.append($0) }
        defer {
            sounds.settingEnabled = nil
            sounds.output = nil
            sounds.systemAllows = { true }
            sounds.clock = { ProcessInfo.processInfo.systemUptime }
            sounds.lastPlayed = -.infinity
        }

        let model = RecentlyDeletedModel(library: nil, draw: { store })
        model.reload()
        model.requestEmpty()
        model.confirmEmpty()
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertEqual(model.message?.tone, .warning, "kept-item warning remains")
        XCTAssertFalse(cues.contains(.emptied), "nothing was removed")
    }

    func testAgreeingPayloadReplicasAllGoOnEveryPurgePath() throws {
        // Delete Permanently.
        do {
            let container = try container()
            let store = DrawPersistentStore(container: container)
            let fixture = try payloadReplicaFixture(store, container: container) { _ in }
            XCTAssertEqual(store.purge(fixture.targets), DrawPurgeReport(removed: 2, kept: 0))
            XCTAssertEqual(try payloadRows(container, fixture.ids), 0)
        }
        // Empty.
        do {
            let container = try container()
            let store = DrawPersistentStore(container: container)
            let fixture = try payloadReplicaFixture(store, container: container) { _ in }
            let model = RecentlyDeletedModel(library: nil, draw: { store })
            model.reload()
            model.requestEmpty()
            model.confirmEmpty()
            XCTAssertEqual(try payloadRows(container, fixture.ids), 0)
            XCTAssertTrue(try store.library(deleted: true).isEmpty)
        }
        // The 30-day removal.
        do {
            let clock = Clock(), container = try container()
            let store = DrawPersistentStore(container: container, now: clock.now)
            let fixture = try payloadReplicaFixture(store, container: container) { _ in }
            clock.advance(40 * 86_400)
            XCTAssertEqual(DrawRecentlyDeleted.purgeExpired(store: store, now: clock.now(), calendar: .current).removed, 2)
            XCTAssertEqual(try payloadRows(container, fixture.ids), 0)
        }
    }

    // MARK: Batch 3: edits after a failed save

    /// A durable store whose saves fail while `fail` is set, recording the
    /// object rows each successful save inserted, in order.
    private final class SaveLog {
        var fail = true
        var inserted: [UUID] = []
    }

    private func flakyStore(_ log: SaveLog, container: ModelContainer) -> DrawPersistentStore {
        DrawPersistentStore(container: container, save: { context in
            if log.fail { throw Injected() }
            let rows = context.insertedModelsArray.compactMap { $0 as? DrawObjectRecord }.map(\.id)
            try context.save()
            log.inserted += rows
        })
    }

    func testEscapeDropsOnlyTheQueuedRenameAndKeepsAnEarlierFailedDrawingEdit() throws {
        let log = SaveLog(), container = try container()
        log.fail = false
        let store = flakyStore(log, container: container)
        let canvas = store.create(name: "Original")
        let first = stroke(), second = stroke()
        XCTAssertTrue(store.perform(.put([first]), on: canvas.id).isSaved)
        log.fail = true
        guard case .retry = store.perform(.put([second]), on: canvas.id) else {
            return XCTFail("The drawing save should be retryable")
        }
        XCTAssertFalse(store.perform(.rename("Discarded"), on: canvas.id).isSaved)
        XCTAssertEqual(store.pendingEdits[canvas.id]?.count, 2)

        XCTAssertTrue(store.abandonPendingRename(on: canvas.id, named: "Discarded", restoring: "Original"))
        XCTAssertEqual(try store.open(canvas.id).canvas.name, "Original")
        XCTAssertEqual(Set(try store.open(canvas.id).objects.map(\.id)), [first.id, second.id])
        XCTAssertEqual(store.pendingEdits[canvas.id]?.count, 1, "the earlier failed drawing still needs Retry")

        log.fail = false
        XCTAssertTrue(store.retry(on: canvas.id).isSaved)
        XCTAssertNil(store.pendingEdits[canvas.id])
        let reopened = DrawPersistentStore(container: container)
        XCTAssertEqual(try reopened.open(canvas.id).canvas.name, "Original", "the abandoned name cannot save later")
        XCTAssertEqual(Set(try reopened.open(canvas.id).objects.map(\.id)), [first.id, second.id])
        XCTAssertTrue(store.undo(on: canvas.id).isSaved)
        XCTAssertEqual(try store.open(canvas.id).objects.map(\.id), [first.id], "only saved edits enter Undo")
    }

    func testAnEditAfterAFailedSaveQueuesAndRetrySavesBothInOrder() throws {
        let log = SaveLog(), container = try container()
        let store = flakyStore(log, container: container)
        let board = store.create()
        let first = stroke(), second = stroke()
        guard case .retry = store.perform(.put([first]), on: board.id) else { return XCTFail("The first save fails, ready for Retry") }
        XCTAssertFalse(store.perform(.put([second]), on: board.id).isSaved)
        XCTAssertEqual(Set(try store.open(board.id).objects.map(\.id)), [first.id, second.id], "Input keeps working: both show")
        XCTAssertEqual(Set(store.pendingEdits[board.id]?.objects.map(\.id) ?? []), [first.id, second.id])
        XCTAssertFalse(store.canUndo(on: board.id), "Undo waits until they are saved")

        log.fail = false
        XCTAssertTrue(store.retry(on: board.id).isSaved)
        XCTAssertFalse(store.hasUnsettledEdits)
        XCTAssertEqual(log.inserted, [first.id, second.id], "Saved in the order they were made")
        XCTAssertEqual(Set(try DrawPersistentStore(container: container).open(board.id).objects.map(\.id)), [first.id, second.id])

        // Undo takes them back one at a time, the latest first.
        XCTAssertTrue(store.undo(on: board.id).isSaved)
        XCTAssertEqual(try store.open(board.id).objects.map(\.id), [first.id])
        XCTAssertTrue(store.undo(on: board.id).isSaved)
        XCTAssertTrue(try store.open(board.id).objects.isEmpty)
        XCTAssertFalse(store.canUndo(on: board.id))
        XCTAssertTrue(store.redo(on: board.id).isSaved)
        XCTAssertEqual(try store.open(board.id).objects.map(\.id), [first.id])
    }

    func testTwoFailuresInARowLoseNothingAndALaterSaveSavesEveryEditInOrder() throws {
        let log = SaveLog(), container = try container()
        let store = flakyStore(log, container: container)
        let board = store.create()
        let first = stroke(), second = stroke(), third = stroke()
        XCTAssertFalse(store.perform(.put([first]), on: board.id).isSaved)
        XCTAssertFalse(store.perform(.put([second]), on: board.id).isSaved, "The second save fails too")
        XCTAssertFalse(store.retry(on: board.id).isSaved, "And so does Retry")
        XCTAssertTrue(store.hasUnsettledEdits, "Quit still waits")
        XCTAssertEqual(store.pendingEdits[board.id]?.count, 2, "Both count as unsaved")
        XCTAssertEqual(Set(try store.open(board.id).objects.map(\.id)), [first.id, second.id])

        log.fail = false
        XCTAssertTrue(store.perform(.put([third]), on: board.id).isSaved, "A later successful save takes the held ones with it")
        XCTAssertFalse(store.hasUnsettledEdits)
        XCTAssertEqual(log.inserted, [first.id, second.id, third.id])
        XCTAssertEqual(Set(try DrawPersistentStore(container: container).open(board.id).objects.map(\.id)),
                       [first.id, second.id, third.id])
        for remaining in [[first.id, second.id], [first.id], []] {
            XCTAssertTrue(store.undo(on: board.id).isSaved)
            XCTAssertEqual(Set(try store.open(board.id).objects.map(\.id)), Set(remaining))
        }
    }

    func testEditsQueuedBehindAHeldSaveSettleOnceItReconciles() throws {
        let repository = Draw3HeldRepository()
        let store = DrawStore(repository: repository)
        let board = store.create()
        let first = stroke(), second = stroke()
        guard case .held = store.perform(.put([first]), on: board.id) else { return XCTFail("Held") }
        XCTAssertFalse(store.perform(.put([second]), on: board.id).isSaved)
        XCTAssertEqual(Set(try store.open(board.id).objects.map(\.id)), [first.id, second.id])
        repository.reconcileOutcome = .committed
        repository.writesCommit = true
        XCTAssertTrue(store.reconcile(on: board.id).isSaved)
        XCTAssertFalse(store.hasUnsettledEdits)
        XCTAssertEqual(Set(try repository.load(board.id)?.objects.map(\.id) ?? []), [first.id, second.id])
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
