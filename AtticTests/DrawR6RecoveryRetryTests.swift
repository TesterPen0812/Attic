import Foundation
import SwiftData
import XCTest
@testable import Attic

/// The same entry point as the shell notice's Retry button. These candidates
/// require the owner's Mac runner; authoring them is not an executed result.
@MainActor
final class DrawR6RecoveryRetryTests: XCTestCase {
    private struct Inventory: Decodable {
        var records: [UUID: DrawRecoveryJournal.Record]
    }

    private struct Fixture {
        let root: URL
        let journalURL: URL
        let canvasID: UUID
        let otherCanvasID: UUID
        let image: DrawObject
        let text: DrawObject
        let otherText: DrawObject
        let bytes: Data
    }

    private func interruptedRename() throws -> Fixture {
        let root = ownedTemporaryDirectory(prefix: "DrawR6PageRecovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journalURL = root.appendingPathComponent("DrawRecovery-v1.json")
        let bytes = Data(repeating: 91, count: 65_536)
        let image = DrawObject(content: .image(DrawImage(original: bytes, pixelWidth: 128, pixelHeight: 128)))
        let text = DrawObject(content: .text("All original writing"))
        let otherText = DrawObject(content: .text("Keep browsing here"))
        var canvasID: UUID!
        var otherCanvasID: UUID!
        weak var discarded: DrawStore?
        do {
            let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
            var refuseRetirement = false
            let journal = DrawRecoveryJournal(fileURL: journalURL, writeData: { data, url in
                if refuseRetirement,
                   let inventory = try? JSONDecoder().decode(Inventory.self, from: data),
                   inventory.records.isEmpty {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: url, options: .atomic)
            })
            let backend = DrawSwiftDataRepository(container: container, metrics: DrawSaveMetrics(),
                save: { try $0.save() }, recovery: journal)
            let store = DrawStore(repository: backend, recovery: journal)
            discarded = store
            canvasID = store.create(name: "Before").id
            XCTAssertTrue(store.perform(.put([image, text]), on: canvasID).isSaved)
            otherCanvasID = store.create(name: "Other").id
            XCTAssertTrue(store.perform(.put([otherText]), on: otherCanvasID).isSaved)
            refuseRetirement = true
            _ = store.perform(.rename("Recovered title"), on: canvasID)
            XCTAssertEqual(try backend.load(canvasID)?.canvas.name, "Recovered title")
            XCTAssertNotNil(journal.records[canvasID])
        }
        XCTAssertNil(discarded, "drop the store without any clean-close path")
        return Fixture(root: root, journalURL: journalURL, canvasID: canvasID,
            otherCanvasID: otherCanvasID, image: image, text: text, otherText: otherText, bytes: bytes)
    }

    func testDS6PageNoticeRetriesCompleteLoadAndRestoresOriginalCanvas() throws {
        let fixture = try interruptedRename()
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: fixture.root)
        let journal = DrawRecoveryJournal(fileURL: fixture.journalURL)
        let backend = DrawSwiftDataRepository(container: container, metrics: DrawSaveMetrics(),
            save: { try $0.save() }, recovery: journal)
        let fault = RecoveryPageLoadFault(backend, canvasID: fixture.canvasID)
        let store = DrawStore(repository: fault, recovery: journal)
        let page = DrawPageModel(store: store)
        page.open(fixture.canvasID)
        XCTAssertNil(page.canvasID)
        XCTAssertTrue(page.objects.isEmpty, "no sparse recovery patch is presented as a loaded board")
        let notice = try XCTUnwrap(page.saveNotice)
        XCTAssertEqual(notice.message,
            "Could not load this drawing. Its recovery data has been preserved. Retry to load it.")
        XCTAssertTrue(notice.canRetry, "the existing notice must expose a usable Retry action")
        XCTAssertTrue(store.hasUnsettledEdits)
        let originalJournal = try Data(contentsOf: fixture.journalURL)
        let attempts = fault.loadAttempts

        page.retrySave()
        XCTAssertEqual(fault.loadAttempts, attempts + 1, "one complete-load attempt per Retry")
        XCTAssertNil(page.canvasID)
        XCTAssertTrue(page.objects.isEmpty)
        XCTAssertEqual(page.saveNotice?.canRetry, true, "a second read failure remains retryable")
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), originalJournal)
        XCTAssertTrue(store.hasUnsettledEdits)

        fault.refusesLoad = false
        page.retrySave()
        XCTAssertEqual(page.canvasID, fixture.canvasID, "Retry reopens the originally requested canvas")
        XCTAssertEqual(page.canvasName, "Recovered title")
        XCTAssertEqual(Set(page.objects.map(\.id)), Set([fixture.image.id, fixture.text.id]))
        XCTAssertEqual(page.object(fixture.text.id)?.text, "All original writing")
        let restoredImage = try XCTUnwrap(page.object(fixture.image.id))
        guard case let .image(payload) = restoredImage.content else { return XCTFail("image content lost") }
        XCTAssertEqual(payload.original, fixture.bytes)
        XCTAssertNil(page.saveNotice)
        XCTAssertFalse(store.hasUnsettledEdits)
        XCTAssertNil(journal.records[fixture.canvasID])
        let physical = try XCTUnwrap(backend.load(fixture.canvasID))
        XCTAssertEqual(physical.canvas.name, "Recovered title")
        XCTAssertEqual(Set(physical.objects.map(\.id)), Set([fixture.image.id, fixture.text.id]))
        let settledAttempts = fault.loadAttempts
        page.retrySave()
        XCTAssertEqual(fault.loadAttempts, settledAttempts, "an already settled Retry does not read or replay again")
    }

    func testDS6RecoveryRetryKeepsAnotherCanvasOpen() throws {
        let fixture = try interruptedRename()
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: fixture.root)
        let journal = DrawRecoveryJournal(fileURL: fixture.journalURL)
        let backend = DrawSwiftDataRepository(container: container, metrics: DrawSaveMetrics(),
            save: { try $0.save() }, recovery: journal)
        let fault = RecoveryPageLoadFault(backend, canvasID: fixture.canvasID)
        let store = DrawStore(repository: fault, recovery: journal)
        let page = DrawPageModel(store: store)
        page.open(fixture.canvasID)
        page.open(fixture.otherCanvasID)
        XCTAssertEqual(page.canvasID, fixture.otherCanvasID)
        XCTAssertEqual(page.saveNotice?.canRetry, true)
        let before = page.objects

        fault.refusesLoad = false
        page.retrySave()
        XCTAssertEqual(page.canvasID, fixture.otherCanvasID, "recovery cannot steal the user's later navigation")
        XCTAssertEqual(page.objects, before)
        XCTAssertEqual(page.object(fixture.otherText.id)?.text, "Keep browsing here")
        XCTAssertNil(page.saveNotice)
        XCTAssertFalse(store.hasUnsettledEdits)
        page.open(fixture.canvasID)
        XCTAssertEqual(Set(page.objects.map(\.id)), Set([fixture.image.id, fixture.text.id]))
    }
}

@MainActor
private final class RecoveryPageLoadFault: DrawRepository {
    let backend: DrawSwiftDataRepository
    let canvasID: UUID
    var refusesLoad = true
    private(set) var loadAttempts = 0
    init(_ backend: DrawSwiftDataRepository, canvasID: UUID) {
        self.backend = backend
        self.canvasID = canvasID
    }
    func library() throws -> [DrawCanvas] { try backend.library() }
    func load(_ id: UUID) throws -> DrawSnapshot? {
        if id == canvasID {
            loadAttempts += 1
            if refusesLoad { throw CocoaError(.fileReadNoPermission) }
        }
        return try backend.load(id)
    }
    func textMatches(_ words: [String], in id: UUID) throws -> [UUID] { try backend.textMatches(words, in: id) }
    func write(_ change: DrawChange) -> DrawWriteOutcome { backend.write(change) }
    func reconcile(_ change: DrawChange) -> DrawWriteOutcome { backend.reconcile(change) }
    func recoveryProof(for id: UUID) -> Data? { backend.recoveryProof(for: id) }
    func matchesAgentUndoPrestate(_ change: DrawChange) -> Bool { backend.matchesAgentUndoPrestate(change) }
    func discardAttempt(for id: UUID) { backend.discardAttempt(for: id) }
    func deletedImageHeaders() throws -> [DrawDeletedImage] { try backend.deletedImageHeaders() }
    func purge(canvases: [UUID: Date], images: [UUID: DrawImageTarget]) -> DrawRepositoryPurge {
        backend.purge(canvases: canvases, images: images)
    }
}
