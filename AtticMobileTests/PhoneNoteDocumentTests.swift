import Foundation
import SwiftData
import XCTest
@testable import AtticMobile

final class PhoneNoteDocumentTests: XCTestCase {
    private typealias Document = PhoneNoteDocument
    private typealias Snapshot = PhoneNoteDocument.Snapshot

    private func snapshot(_ bytes: Data?, format: Int = 1) -> Snapshot {
        .init(noteID: UUID(), content: bytes, contentFormat: format, contentFingerprint: nil,
              revision: 12, revisionID: nil, taskID: nil)
    }

    private func resource(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }

    private func keep(_ data: Data, name: String, type: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testExchangeReturnsOriginalNoteAndAvailableFileWithoutRecreatingMissingImage() throws {
        let raw = try resource("exchange-note", "json"), file = try resource("exchange-file", "txt")
        let schema = Schema([NoteItem.self, NoteAttachment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let writer = ModelContext(container)
        let seed = NoteItem(title: "Cached title", body: "Do not rebuild from this projection")
        seed.content = raw; seed.contentFingerprint = nil; seed.revision = 12
        let base = Snapshot(seed), doc = Document(base)
        XCTAssertNil(doc.readOnlyReason)
        XCTAssertEqual(doc.blocks.map(\.kind), [.text, .text, .table, .file, .image, .checklist])
        let fileBlock = try XCTUnwrap(doc.blocks.first { $0.kind == .file })
        let fileID = try XCTUnwrap(fileBlock.attachmentID)
        let asset = NoteAttachment(id: fileID, noteID: base.noteID, originalFilename: try XCTUnwrap(fileBlock.filename),
            contentTypeIdentifier: try XCTUnwrap(fileBlock.contentTypeIdentifier), byteCount: try XCTUnwrap(fileBlock.byteCount),
            sortIndex: 0, contentDigest: NoteItem.fingerprint(file), payload: file)
        writer.insert(seed); writer.insert(asset)
        try writer.save()

        let reader = ModelContext(container)
        let stored = try XCTUnwrap(reader.fetch(FetchDescriptor<NoteItem>()).first)
        let assets = try reader.fetch(FetchDescriptor<NoteAttachment>())
        let storedFile = try XCTUnwrap(assets.first { $0.id == fileID && $0.noteID == stored.id })
        let imageID = try XCTUnwrap(doc.blocks.first { $0.kind == .image }?.attachmentID)
        XCTAssertFalse(assets.contains { $0.id == imageID })
        let current = Snapshot(stored)
        guard case let .unchanged(bytes) = try doc.saving([], against: current) else { return XCTFail("No-op requested a write") }
        XCTAssertNil(stored.contentFingerprint)
        XCTAssertNil(stored.revisionID)
        XCTAssertEqual(stored.revision, 12)
        XCTAssertFalse(reader.hasChanges)
        let returned = try XCTUnwrap(bytes)
        let returnedFile = try XCTUnwrap(storedFile.payload)
        XCTAssertEqual(returned, raw)
        XCTAssertEqual(returnedFile, Data("Synthetic file: Attic exchange v1.\n".utf8))
        XCTAssertEqual(storedFile.byteCount, Int64(returnedFile.count))
        keep(returned, name: "exchange-note.json", type: "public.json")
        keep(returnedFile, name: "exchange-file.txt", type: "public.plain-text")
        let edits: [Document.Edit] = [.text(block: 0, "Changed title"), .checked(block: 5, true)]
        guard case let .changed(edited) = try doc.saving(edits, against: current) else { return XCTFail("Edit discarded") }
        // Compare the entire wire image, not a post-decode projection.
        let expected = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "Exchange title", with: "Changed title")
            .replacingOccurrences(of: "\"checked\":false", with: "\"checked\":true")
        XCTAssertEqual(edited, Data(expected.utf8))
        guard case let .editable(reopened) = NoteContentCodec.decode(edited) else { return XCTFail("Invalid edited bytes") }
        XCTAssertEqual(reopened.attachmentIDs, [fileID, imageID])
        XCTAssertEqual(storedFile.payload, file)
        XCTAssertEqual(storedFile.payloadFingerprint, NoteItem.fingerprint(file))
        XCTAssertEqual(stored.content, raw) // preparation alone never installs a write
        XCTAssertEqual(reopened.blocks[0].text, "Changed title")
        XCTAssertTrue(reopened.blocks[5].checked)
        for index in [1, 2, 3, 4] {
            XCTAssertFalse(doc.canEditText(at: index))
            XCTAssertThrowsError(try doc.saving([.text(block: index, "flatten")], against: base))
        }
    }

    func testOnlyEditedTokenChangesEvenWithEscapesNestedFieldsAndLargeDecimals() throws {
        let original = #"{ "x":{"text":"old","blocks":["}\\\""]}, "format":1, "blocks" : [{"kind":"text","te\u0078t":"\u006fld","n":0.123456789012345678901},{"kind":"text","text":"old","marks":[],"inline":[]}] }"#
        let raw = Data(original.utf8), base = snapshot(raw), doc = Document(base)
        XCTAssertEqual(try doc.saving([.text(block: 0, "old")], against: base), .unchanged(raw))
        XCTAssertEqual(try doc.saving([.text(block: 0, "first"), .text(block: 0, "old")], against: base), .unchanged(raw))
        let changed = try doc.saving([.text(block: 0, "new")], against: base)
        XCTAssertEqual(changed, .changed(Data(original.replacingOccurrences(of: #""\u006fld""#, with: #""new""#).utf8)))
        let unicode = try doc.saving([.text(block: 0, "e\u{301}\"\\🧪")], against: base)
        guard case let .changed(bytes) = unicode else { return XCTFail("Missing edit") }
        let edited = try XCTUnwrap(NoteContentCodec.decode(bytes).document?.blocks.first?.text)
        XCTAssertTrue(edited.utf8.elementsEqual("e\u{301}\"\\🧪".utf8))
        let decomposed = snapshot(bytes)
        guard case .changed = try Document(decomposed).saving([.text(block: 0, "é\"\\🧪")], against: decomposed)
        else { return XCTFail("Distinct Unicode spelling is a real edit") }
    }

    func testUnsafeDocumentsRetainOriginalBytesAndRejectAnyEdit() throws {
        let plain = #"{"format":1,"blocks":[{"kind":"text","text":"hello"}]}"#
        let inputs: [(String, Int)] = [(plain, 0), (plain, 9), ("not JSON", 1),
            (plain.replacingOccurrences(of: "\"format\":1", with: "\"format\":2"), 1),
            (#"{"format":1,"requires":["future"],"blocks":[{"kind":"text","text":"hello"}]}"#, 1),
            (#"{"format":1,"requires":["taskNote"],"blocks":[{"kind":"text","text":"hello"}]}"#, 1),
            (#"{"format":1,"blocks":[{"kind":"text","text":"hello"},{"kind":"future","data":42}]}"#, 1),
            (#"{"format":1,"blocks":[{"kind":"text","text":"\uFFFC","inline":[{"kind":"future","offset":0,"id":"00000000-0000-4000-8000-000000000001"}]}]}"#, 1),
            (#"{"format":1,"blocks":[{"kind":"text","text":"a","te\u0078t":"b"}]}"#, 1),
            (#"{"format":1,"blocks":[],"blocks":[{"kind":"text","text":"x"}]}"#, 1)]
        for (source, format) in inputs {
            let raw = Data(source.utf8), base = snapshot(raw, format: format), doc = Document(base)
            XCTAssertNotNil(doc.readOnlyReason, source)
            XCTAssertFalse(doc.canEditText(at: 0), source)
            XCTAssertEqual(try doc.saving([], against: base), .unchanged(raw), source)
            XCTAssertThrowsError(try doc.saving([.text(block: 0, "replace")], against: base), source)
        }
        let missing = snapshot(nil)
        XCTAssertEqual(try Document(missing).saving([], against: missing), .unchanged(nil))
        XCTAssertThrowsError(try Document(missing).saving([.text(block: 0, "x")], against: missing))
    }

    func testStaleSnapshotsDoNotReturnEvenOldNoOpBytes() throws {
        let raw = try resource("exchange-note", "json"), base = snapshot(raw), doc = Document(base)
        let mutations: [(inout Snapshot) -> Void] = [{ $0.noteID = UUID() }, { $0.revision += 1 },
            { $0.revisionID = UUID() }, { $0.contentFormat = 2 }, { $0.content?.append(32) },
            { $0.contentFingerprint = "changed" }, { $0.taskID = UUID() }]
        for mutate in mutations {
            var current = base; mutate(&current)
            for edits: [Document.Edit] in [[], [.text(block: 0, "new")]] {
                XCTAssertThrowsError(try doc.saving(edits, against: current)) {
                    XCTAssertEqual($0 as? Document.Failure, .stale)
                }
            }
        }
        var last = base; last.revision = .max
        XCTAssertEqual(try Document(last).saving([], against: last), .unchanged(raw))
        XCTAssertThrowsError(try Document(last).saving([.text(block: 0, "new")], against: last))
        var linked = base; linked.taskID = UUID()
        XCTAssertNotNil(Document(linked).readOnlyReason)
    }

    func testChecklistDefaultAndInvalidBatchAreSafe() throws {
        let raw = Data(#"{"format":1,"blocks":[{"kind":"text","text":"A"},{"kind":"checklist","id":"00000000-0000-4000-8000-000000000001","text":"Task"}]}"#.utf8)
        let base = snapshot(raw), doc = Document(base)
        XCTAssertEqual(try doc.saving([.checked(block: 1, false)], against: base), .unchanged(raw))
        guard case let .changed(bytes) = try doc.saving([.checked(block: 1, true), .text(block: 1, "B")], against: base)
        else { return XCTFail("Missing checklist edit") }
        let reopened = try XCTUnwrap(NoteContentCodec.decode(bytes).document)
        XCTAssertEqual(reopened.blocks.last?.checked, true)
        XCTAssertEqual(reopened.blocks.last?.text, "B")
        let bad: [Document.Edit] = [.text(block: -1, "x"), .checked(block: 20, true), .checked(block: 0, true),
            .text(block: 0, "x\u{FFFC}"), .text(block: 1, "x\ny")]
        for edit in bad {
            XCTAssertThrowsError(try doc.saving([.checked(block: 1, true), edit], against: base))
        }
        XCTAssertEqual(try doc.saving([], against: base), .unchanged(raw))
    }
}
