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
