import Foundation
import SwiftData
import XCTest
@testable import AtticMobile

@MainActor
final class PhoneDocumentTransactionTests: XCTestCase {
    private let raw = Data(#"{ "format":1, "blocks":[{"kind":"text","text":"Head"},{"kind":"text","text":"Before"}],"futureCount":18446744073709551615 }"#.utf8)

    private func seed(_ db: ModelContainer, bytes: Data, id: UUID = UUID(), revision: UUID = UUID()) throws -> UUID {
        let context = ModelContext(db)
        let row = NoteItem(id: id, title: "Head")
        row.content = bytes; row.contentFormat = 1; row.contentFingerprint = nil
        row.revision = 7; row.revisionID = revision
        context.insert(row)
        try context.save()
        return row.id
    }

    func testClearingExistingDocumentPreservesIdentityMetadataHistoryAndLinks() throws {
        let db = try PersistenceController.makeContainer(inMemory: true)
        let id = UUID(), revision = UUID(), versionID = UUID(), linkID = UUID(), targetID = UUID()
        _ = try seed(db, bytes: raw, id: id, revision: revision)
        _ = try seed(db, bytes: raw, id: id, revision: revision)
        let setup = ModelContext(db), stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for row in try setup.fetch(FetchDescriptor<NoteItem>()) {
            row.tags = ["kept"]; row.pinnedAt = stamp
        }
        setup.insert(NoteVersion(id: versionID, noteID: id, createdAt: stamp, reason: .leave,
            content: raw, contentFormat: 1, title: "Head", body: "Before", attachmentIDs: [], sourceRevisionID: revision))
        setup.insert(ItemLink(id: linkID, source: AtticItemRef(.note, id),
            target: AtticItemRef(.task, targetID), kind: .reference, createdAt: stamp))
        try setup.save()

        var saves = 0
        let library = PhoneLibrary(container: db, save: { saves += 1; try $0.save() })
        let opened = try library.openDocument(id: id)
        let cleared = try library.saveDocument(opened, edits: [.text(block: 0, ""), .text(block: 1, "")])
        XCTAssertEqual(cleared.note.id, id)
        XCTAssertEqual(cleared.revision, 8)
        XCTAssertNotEqual(cleared.revisionID, revision)
        XCTAssertEqual(saves, 1)

        let reader = ModelContext(db), rows = try reader.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.id == id && $0.deletedAt == nil && $0.tags == ["kept"] &&
            $0.pinnedAt == stamp && $0.title.isEmpty && $0.body.isEmpty && $0.revision == 8 &&
            $0.revisionID == cleared.revisionID && $0.content == cleared.content })
        let versions = try reader.fetch(FetchDescriptor<NoteVersion>())
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.id, versionID)
        XCTAssertEqual(versions.first?.noteID, id)
        XCTAssertEqual(versions.first?.content, raw)
        let links = try reader.fetch(FetchDescriptor<ItemLink>())
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.id, linkID)
        XCTAssertEqual(links.first?.sourceID, id)
        XCTAssertEqual(links.first?.targetID, targetID)
        XCTAssertNil(links.first?.deletedAt)

        let reopened = try library.openDocument(id: id)
        XCTAssertEqual(reopened.blocks.map(\.text), ["", ""])
        XCTAssertNil(reopened.readOnlyReason)
        let unchanged = try library.saveDocument(reopened, edits: [.text(block: 0, "")])
        XCTAssertEqual(unchanged.content, cleared.content)
        XCTAssertEqual(unchanged.revisionID, cleared.revisionID)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(try library.notes().contains { $0.id == id })
    }

    func testBlankCaptureAndLegacyTitleBodyUpdateRemainRejected() throws {
        let db = try PersistenceController.makeContainer(inMemory: true)
        let library = PhoneLibrary(container: db)
        XCTAssertThrowsError(try library.createNote(title: " ", body: "\n")) {
            XCTAssertEqual($0 as? PhoneLibrary.Failure, .emptyNote)
        }
        let existing = try library.createNote(title: "Head", body: "Before")
        XCTAssertThrowsError(try library.updateNote(existing, title: "", body: "")) {
            XCTAssertEqual($0 as? PhoneLibrary.Failure, .emptyNote)
        }
        let reopened = try library.openNote(id: existing.note.id)
        XCTAssertEqual(reopened.content, existing.content)
        XCTAssertEqual(reopened.revisionID, existing.revisionID)
    }

    func testNoOpAvoidsEveryWriteAndChangedContentReachesEveryReplicaVerbatim() throws {
        let db = try PersistenceController.makeContainer(inMemory: true)
        let id = UUID(), revision = UUID()
        _ = try seed(db, bytes: raw, id: id, revision: revision)
        _ = try seed(db, bytes: raw, id: id, revision: revision)
        var saves = 0
        let library = PhoneLibrary(container: db, save: { saves += 1; try $0.save() })
        let doc = try library.openDocument(id: id)
        let unchanged = try library.saveDocument(doc, edits: [.text(block: 1, "Before")])
        XCTAssertEqual(unchanged.content, raw)
        XCTAssertNil(unchanged.contentFingerprint)
        XCTAssertEqual(unchanged.revisionID, revision)
        XCTAssertEqual(saves, 0)
        let changed = try library.saveDocument(doc, edits: [.text(block: 1, "After")])
        let expected = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "Before", with: "After").utf8)
        XCTAssertEqual(changed.content, expected)
        XCTAssertEqual(saves, 1)
        let reader = ModelContext(db)
        let rows = try reader.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.content == expected && $0.body == "After" && $0.revision == 8 && $0.revisionID == changed.revisionID })
        XCTAssertNotEqual(changed.revisionID, revision)
    }

    func testStalePhysicalCopyAndFailedStorageCannotOverwriteAnyBytes() throws {
        let db = try PersistenceController.makeContainer(inMemory: true)
        let id = UUID(), revision = UUID()
        _ = try seed(db, bytes: raw, id: id, revision: revision)
        let library = PhoneLibrary(container: db, save: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let doc = try library.openDocument(id: id)
        XCTAssertThrowsError(try library.saveDocument(doc, edits: [.text(block: 1, "Unsaved")]))
        let divergent = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "Before", with: "Fork").utf8)
        _ = try seed(db, bytes: divergent, id: id, revision: revision)
        XCTAssertThrowsError(try library.saveDocument(doc, edits: [])) { XCTAssertEqual($0 as? PhoneNoteDocument.Failure, .stale) }
        let reader = ModelContext(db)
        let rows = try reader.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(Set(rows.compactMap(\.content)), [raw, divergent])
        XCTAssertTrue(rows.allSatisfy { $0.revision == 7 && $0.revisionID == revision && $0.contentFingerprint == nil })
    }
}
