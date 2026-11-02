import Foundation
import SwiftData
import XCTest
@testable import AtticMobile

@MainActor
final class NoteStoreMobileTests: XCTestCase {
    func testMobileNoteStoreSharesSemanticsWithoutCloudKitInTests() throws {
        XCTAssertNil(PersistenceController.makeConfiguration(inMemory: true).cloudKitContainerIdentifier)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = PhoneLibrary(container: container)
        let opened = try store.createNote(title: "  From   iPhone ", body: "  sync me ")
        XCTAssertEqual(opened.note.title, "From iPhone")
        XCTAssertEqual(opened.note.body, "sync me")
        let updated = try store.updateNote(opened, body: "updated")
        XCTAssertEqual(updated.note.body, "updated")
        XCTAssertEqual(updated.revision, opened.revision + 1)
        XCTAssertNotEqual(updated.revisionID, opened.revisionID)
        let verificationContext = ModelContext(container)
        let row = try XCTUnwrap(verificationContext.fetch(FetchDescriptor<NoteItem>()).first)
        let bytes = try XCTUnwrap(row.content)
        guard case let .editable(document) = NoteContentCodec.decode(bytes) else { return XCTFail("Not a native note") }
        XCTAssertEqual(document.blocks.map(\.text), ["From iPhone", "updated"])
        XCTAssertEqual(row.plainText, "From iPhone\nupdated")
        XCTAssertEqual(row.contentFingerprint, NoteItem.fingerprint(bytes))
        XCTAssertThrowsError(try store.createNote(title: " ", body: "\n\t"))
    }

    func testRichAndUnreadableBytesRemainExactAcrossOpenNoOpAndMetadataWrites() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let assetID = UUID()
        let doc = NoteDocument(blocks: [.text("Rich"), .image(id: UUID(), attachmentID: assetID)],
                               extras: ["futureHint": .string("preserve me")])
        let rich = try NoteContentCodec.encode(doc) + Data(" \n".utf8)
        let inputs: [(Int, Data?)] = [(1, rich), (7, rich), (1, Data([0, 255])), (0, nil),
                                      (1, Data(#"{"format":8,"blocks":[{"kind":"text","text":"future"}]}"#.utf8))]
        let ids = inputs.map { format, bytes -> UUID in
            let note = NoteItem(title: "Preview", body: "Projection")
            note.content = bytes
            note.contentFormat = format
            note.revisionID = UUID()
            note.revision = 9
            note.contentFingerprint = nil
            seed.insert(note)
            return note.id
        }
        let payload = Data([255, 2, 0, 1])
        let asset = NoteAttachment(id: assetID, noteID: ids[0], originalFilename: "image.bin",
                                  byteCount: Int64(payload.count), sortIndex: 0,
                                  contentDigest: NoteItem.fingerprint(payload), payload: payload)
        seed.insert(asset)
        try seed.save()
        let store = PhoneLibrary(container: container)
        for (index, id) in ids.enumerated() {
            let base = try store.openNote(id: id)
            XCTAssertEqual(base.content, inputs[index].1)
            try store.updateNote(base, body: base.note.body)
            XCTAssertThrowsError(try store.updateNote(base, body: "Flattened")) {
                XCTAssertEqual($0 as? PhoneLibrary.Failure, .readOnlyNote)
            }
            try store.updateNoteMetadata(id: id, tags: ["#Work", "work", "Trip Planner"], pinned: true)
            let fresh = try store.openNote(id: id)
            XCTAssertEqual(fresh.content, base.content)
            XCTAssertEqual(fresh.contentFormat, base.contentFormat)
            XCTAssertEqual(fresh.revisionID, base.revisionID)
            XCTAssertEqual(fresh.revision, 9)
            XCTAssertNil(fresh.contentFingerprint)
            XCTAssertEqual(fresh.note.updatedAt, base.note.updatedAt)
            XCTAssertEqual(fresh.note.tags, ["trip-planner", "work"])
            XCTAssertNotNil(fresh.note.pinnedAt)
        }
        let verificationContext = ModelContext(container)
        let saved = try XCTUnwrap(verificationContext.fetch(FetchDescriptor<NoteAttachment>()).first)
        XCTAssertEqual(saved.id, assetID)
        XCTAssertEqual(saved.payload, payload)
    }

    func testNoncanonicalPlainNoOpSkipsSaveAndRetainsLegacyNilDigest() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let raw = Data(#"{ "format":1,"blocks":[{"text":"Title", "kind":"text"},{"text":"body","kind":"text"}] }"#.utf8)
        let row = NoteItem(title: "Title", body: "body")
        row.content = raw
        row.contentFingerprint = nil
        seed.insert(row)
        try seed.save()
        let store = PhoneLibrary(container: container, save: { _ in XCTFail("No-op called save") })
        let base = try store.openNote(id: row.id)
        let noOp = try store.updateNote(base, title: "Title", body: "body")
        XCTAssertEqual(noOp.content, raw)
        XCTAssertNil(noOp.contentFingerprint)
        XCTAssertEqual(noOp.revision, 0)
        XCTAssertNil(noOp.revisionID)
    }

    func testStaleEditRefusesChangedRevisionAndAlsoBytesWithSameToken() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = PhoneLibrary(container: container)
        let old = try store.createNote(title: "First", body: "Untouched")
        let current = try store.updateNote(old, title: "New title")
        XCTAssertThrowsError(try store.updateNote(old, body: "Stale")) {
            XCTAssertEqual($0 as? PhoneLibrary.Failure, .staleNote)
        }
        let other = ModelContext(container)
        let row = try XCTUnwrap(other.fetch(FetchDescriptor<NoteItem>()).first)
        let newerBytes = try XCTUnwrap(row.content) + Data("\n".utf8)
        row.content = newerBytes
        try other.save()
        XCTAssertThrowsError(try store.updateNote(current, body: "Overwrite")) {
            XCTAssertEqual($0 as? PhoneLibrary.Failure, .staleNote)
        }
        let saved = try store.openNote(id: row.id)
        XCTAssertEqual(saved.content, newerBytes)
        XCTAssertEqual(saved.revisionID, current.revisionID)
    }

    func testDivergentReplicaBlocksContentEditAndAgreeingReplicasPreserveOwnMetadata() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = PhoneLibrary(container: container)
        let base = try store.createNote(title: "First", body: "Shared body", tags: ["Original"], pinned: true)
        let seed = ModelContext(container)
        let other = NoteItem(id: base.note.id, title: "First", body: "Divergent body", createdAt: .distantPast)
        other.revision = base.revision
        other.revisionID = base.revisionID
        other.tags = ["Replica"]
        seed.insert(other)
        try seed.save()
        XCTAssertEqual(try store.notes().map(\.id), [base.note.id])
        XCTAssertThrowsError(try store.updateNote(base, body: "Trying")) {
            XCTAssertEqual($0 as? PhoneLibrary.Failure, .staleNote)
        }
        other.content = base.content
        other.body = base.note.body
        try seed.save()
        let edited = try store.updateNote(base, body: "New")
        let verificationContext = ModelContext(container)
        let rows = try verificationContext.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.body == "New" && $0.content == edited.content && $0.revisionID == edited.revisionID })
        XCTAssertEqual(Set(rows.map(\.tagsRaw)), ["original", "replica"])
        XCTAssertEqual(rows.filter(\.isPinned).count, 1)
        try store.updateNoteMetadata(id: base.note.id, tags: ["every copy"], pinned: false)
        let metadataContext = ModelContext(container)
        let after = try metadataContext.fetch(FetchDescriptor<NoteItem>())
        XCTAssertTrue(after.allSatisfy { $0.tags == ["every-copy"] && !$0.isPinned && $0.revisionID == edited.revisionID })
    }

    func testRevisionAndFormatChangesAreStaleEvenWhenBytesAgree() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = PhoneLibrary(container: container)
        let base = try store.createNote(title: "Same bytes")
        let writer = ModelContext(container)
        let row = try XCTUnwrap(writer.fetch(FetchDescriptor<NoteItem>()).first)
        row.revisionID = UUID()
        try writer.save()
        XCTAssertThrowsError(try store.updateNote(base, title: "Overwrite")) {
            XCTAssertEqual($0 as? PhoneLibrary.Failure, .staleNote)
        }
        row.revisionID = base.revisionID
        row.revision += 1
        try writer.save()
        XCTAssertThrowsError(try store.updateNote(base, title: "Overwrite")) {
            XCTAssertEqual($0 as? PhoneLibrary.Failure, .staleNote)
        }
        row.revision = base.revision
        row.contentFormat += 1
        try writer.save()
        XCTAssertThrowsError(try store.updateNote(base, title: "Overwrite")) {
            XCTAssertEqual($0 as? PhoneLibrary.Failure, .staleNote)
        }
        XCTAssertEqual(try store.openNote(id: base.note.id).content, base.content)
    }

    func testNoteSaveFailureRetainsOriginalRevisionBytesAndMetadata() throws {
        enum Injected: Error { case save }
        let container = try PersistenceController.makeContainer(inMemory: true)
        let reader = PhoneLibrary(container: container)
        let base = try reader.createNote(title: "Original", body: "Still here", tags: ["Kept"], pinned: true)
        let failing = PhoneLibrary(container: container, save: { context in
            let staged = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first)
            XCTAssertEqual(staged.body, "Attempted")
            XCTAssertNotEqual(staged.revisionID, base.revisionID)
            throw Injected.save
        })
        XCTAssertThrowsError(try failing.updateNote(base, body: "Attempted")) { XCTAssertTrue($0 is Injected) }
        let after = try reader.openNote(id: base.note.id)
        XCTAssertEqual(after.content, base.content)
        XCTAssertEqual(after.contentFingerprint, base.contentFingerprint)
        XCTAssertEqual(after.revisionID, base.revisionID)
        XCTAssertEqual(after.revision, base.revision)
        XCTAssertEqual(after.note.body, "Still here")
        XCTAssertEqual(after.note.pinnedAt, base.note.pinnedAt)
        XCTAssertEqual(after.note.tags, ["kept"])
    }
}
