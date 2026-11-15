import Foundation
import SwiftData
import XCTest
@testable import Attic

/// File-backed regression candidates for Draw round 6. Execution is performed
/// by the owner's Mac runner, not by the authoring chat.
@MainActor
final class DrawR6RecoveryLoadTests: XCTestCase {
    private struct RecordInventory: Decodable {
        var records: [UUID: DrawRecoveryJournal.Record]
    }

    func testDS6FailedCompleteLoadNeverSubstitutesARenamesEmptyObjectPatch() throws {
        let root = ownedTemporaryDirectory(prefix: "DrawR6CompleteLoad")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journalURL = root.appendingPathComponent("DrawRecovery-v1.json")
        let bytes = Data(repeating: 73, count: 65_536)
        let image = DrawObject(content: .image(DrawImage(original: bytes, pixelWidth: 128, pixelHeight: 128)))
        let text = DrawObject(content: .text("Keep the whole canvas"))
        var canvasID: UUID!
        weak var discarded: DrawStore?

        do {
            let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
            var refuseRetirement = false
            let journal = DrawRecoveryJournal(fileURL: journalURL, writeData: { data, url in
                if refuseRetirement,
                   let inventory = try? JSONDecoder().decode(RecordInventory.self, from: data),
                   inventory.records.isEmpty {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: url, options: .atomic)
            })
            let repository = DrawSwiftDataRepository(container: container, metrics: DrawSaveMetrics(),
                save: { try $0.save() }, recovery: journal)
            let store = DrawStore(repository: repository, recovery: journal)
            discarded = store
            canvasID = store.create(name: "Before").id
            XCTAssertTrue(store.perform(.put([image, text]), on: canvasID).isSaved)
            refuseRetirement = true
            _ = store.perform(.rename("Committed rename"), on: canvasID)
            XCTAssertEqual(try repository.load(canvasID)?.canvas.name, "Committed rename")
            XCTAssertFalse(journal.records.isEmpty, "the fixture leaves a committed but unretired operation")
        }
        XCTAssertNil(discarded, "simulate process loss without a clean close")

        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let journal = DrawRecoveryJournal(fileURL: journalURL)
        let backend = DrawSwiftDataRepository(container: container, metrics: DrawSaveMetrics(),
            save: { try $0.save() }, recovery: journal)
        let fault = CompleteLoadFault(backend)
        let reopened = DrawStore(repository: fault, recovery: journal)
        XCTAssertThrowsError(try reopened.open(canvasID),
            "a failed full load must not cache the rename's empty sparse patch as a complete canvas")
        XCTAssertTrue(reopened.hasUnsettledEdits, "unreadable recovery remains owned")

        fault.refusesLoad = false
        _ = reopened.retry(on: canvasID)
        let restored = try reopened.open(canvasID)
        XCTAssertEqual(restored.canvas.name, "Committed rename")
        XCTAssertEqual(Set(restored.objects.map(\.id)), Set([image.id, text.id]))
        XCTAssertEqual(restored.objects.first { $0.id == text.id }?.text, "Keep the whole canvas")
        let restoredImage = try XCTUnwrap(restored.objects.first { $0.id == image.id })
        guard case let .image(payload) = restoredImage.content else { return XCTFail("image content lost") }
        XCTAssertEqual(payload.original, bytes)
        XCTAssertEqual(try backend.load(canvasID)?.objects.count, 2,
            "the fresh physical read still contains both original objects")
    }
}

/// Inject failure only at the full-canvas read boundary. All persistence and
/// reconciliation still use the real file-backed SwiftData repository.
@MainActor
private final class CompleteLoadFault: DrawRepository {
    let backend: DrawSwiftDataRepository
    var refusesLoad = true
    init(_ backend: DrawSwiftDataRepository) { self.backend = backend }
    func library() throws -> [DrawCanvas] { try backend.library() }
    func load(_ id: UUID) throws -> DrawSnapshot? {
        if refusesLoad { throw CocoaError(.fileReadNoPermission) }
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
