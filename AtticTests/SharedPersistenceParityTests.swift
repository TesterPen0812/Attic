import Foundation
import SwiftData
import XCTest
#if os(iOS)
@testable import AtticMobile
#else
@testable import Attic
#endif

/// One test source, compiled against each application's actual persistence core.
@MainActor
final class SharedPersistenceParityTests: XCTestCase {
    func testRegisteredSchemaPartitionsAllModelsByScope() throws {
        let shared: Set<String> = [
            "TaskItem", "NoteItem", "NoteAttachment", "DrawCanvasRecord", "DrawObjectRecord",
            "DrawPayloadRecord", "ItemLink", "NoteVersion", "NotePendingEdit", "TagColour",
            "TaskNoteAssociation", "TaskDeletionPreservation"
        ]
        #if os(macOS)
        let local: Set<String> = [
            "CanvasBoardItem", "CanvasStrokeItem", "CanvasImageItem", "CanvasSemanticObjectItem",
            "StoreMaintenance", "OperationReceipt", "TaskAttachmentMigrationRecord"
        ]
        #else
        let local: Set<String> = []
        #endif
        let syncedNames = PersistenceController.syncedModelTypes.map { String(describing: $0) }
        let localNames = PersistenceController.deviceLocalModelTypes.map { String(describing: $0) }
        XCTAssertEqual(syncedNames.sorted(), shared.sorted())
        XCTAssertEqual(localNames.sorted(), local.sorted())
        let expected = shared.union(local).sorted()
        XCTAssertEqual(PersistenceController.appModelTypes.map { String(describing: $0) }.sorted(), expected)
        let container = try PersistenceController.makeContainer(inMemory: true)
        XCTAssertEqual(container.schema.entities.map(\.name).sorted(), expected)
    }

    func testMirroringCannotBeRequestedAndStoreLocationsRemainSeparate() {
        // Construct configurations only; do not create or open a disk store.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stores: [(AtticCloudKitEnvironment, String)] = [
            (.production, "default.store"), (.development, "development.store")
        ]
        for request in [false, true] {
            for (environment, filename) in stores {
                let disk = PersistenceController.makeConfiguration(cloudSyncEnabled: request,
                    environment: environment, storeDirectory: root)
                XCTAssertEqual(disk.url.standardizedFileURL, root.appendingPathComponent(filename).standardizedFileURL)
                XCTAssertNil(disk.cloudKitContainerIdentifier)
                let memory = PersistenceController.makeConfiguration(inMemory: true, cloudSyncEnabled: request,
                    environment: environment, storeDirectory: root)
                XCTAssertTrue(memory.isStoredInMemoryOnly)
                XCTAssertNil(memory.cloudKitContainerIdentifier)
            }
        }
    }

    func testNewNotesUseTheSameNativeFormatAndDerivedText() throws {
        let note = NoteItem(title: "Trip", body: "Map\nMeet")
        let bytes = Data(#"{"blocks":[{"kind":"text","text":"Trip"},{"kind":"text","text":"Map"},{"kind":"text","text":"Meet"}],"format":1}"#.utf8)
        XCTAssertEqual(note.contentFormat, 1)
        XCTAssertEqual(try XCTUnwrap(note.content), bytes)
        XCTAssertEqual(note.contentFingerprint, NoteItem.fingerprint(bytes))
        XCTAssertEqual(note.plainText, "Trip\nMap\nMeet")
    }

    func testMetadataSavePreservesOpaqueNoteAndAttachmentInFreshContext() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let writer = ModelContext(container)
        let raw = Data(#"{ "format":7, "blocks":[{"kind":"future","n":1.00}] }"#.utf8)
        let payload = Data([0, 255, 1, 0])
        let revision = UUID()
        let note = NoteItem(title: "Preview")
        note.content = raw
        note.contentFormat = 7
        note.revisionID = revision
        let asset = NoteAttachment(noteID: note.id, originalFilename: "sample.bin", byteCount: Int64(payload.count),
                                  sortIndex: 0, contentDigest: NoteItem.fingerprint(payload), payload: payload)
        writer.insert(note)
        writer.insert(asset)
        try writer.save()

        let editor = ModelContext(container)
        let existing = try XCTUnwrap(editor.fetch(FetchDescriptor<NoteItem>()).first)
        let stored = try XCTUnwrap(existing.content)
        guard case let .readOnly(original, _, _) = NoteContentCodec.decode(stored) else {
            return XCTFail("Future content must not be admitted to the editor")
        }
        XCTAssertEqual(original, raw)
        existing.tags = ["Travel"]
        try editor.save()

        let reader = ModelContext(container)
        let saved = try XCTUnwrap(reader.fetch(FetchDescriptor<NoteItem>()).first)
        XCTAssertEqual(saved.tags, ["travel"])
        XCTAssertEqual(saved.content, raw)
        XCTAssertEqual(saved.contentFormat, 7)
        XCTAssertEqual(saved.contentFingerprint, NoteItem.fingerprint(raw))
        XCTAssertEqual(saved.revisionID, revision)
        let savedAsset = try XCTUnwrap(reader.fetch(FetchDescriptor<NoteAttachment>()).first)
        XCTAssertEqual(savedAsset.id, asset.id)
        XCTAssertEqual(savedAsset.noteID, saved.id)
        XCTAssertEqual(savedAsset.payload, payload)
        XCTAssertEqual(savedAsset.payloadFingerprint, NoteItem.fingerprint(payload))
    }
}
