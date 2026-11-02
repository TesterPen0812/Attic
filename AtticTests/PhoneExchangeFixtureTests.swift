import Foundation
import XCTest
@testable import Attic

/// Independent producer: the two attachments come from native Mac models, never from the phone fixtures.
@MainActor
final class PhoneExchangeFixtureTests: XCTestCase {
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    private func sample() throws -> (Data, Data) {
        let payload = Data("Synthetic file: Attic exchange v1.\n".utf8)
        let attachment = NoteAttachment(id: id(8), noteID: id(99), originalFilename: "example.txt",
            contentTypeIdentifier: "public.plain-text", byteCount: Int64(payload.count), sortIndex: 0,
            contentDigest: NoteItem.fingerprint(payload), payload: payload)
        var title = NoteBlock.text("Exchange title", id: id(1))
        title.extras["hint"] = .string("preserve me")
        var rich = NoteBlock.text("🧪 mark \u{FFFC}", id: id(2))
        rich.marks = [NoteMark(.bold, offset: 3, length: 4)]
        rich.inlines = [.init(id: id(3), kind: .date(try XCTUnwrap(NoteDay(isoString: "2026-01-02"))),
                              extras: ["label": .string("synthetic")])]
        let table = NoteTable(columns: [.init(id: id(4), align: .right, extras: ["unit": .string("kg")])],
            rows: [.init(id: id(5), cells: [.init("42", extras: ["unitVisible": .bool(true)])],
                         extras: ["rowHint": .int(7)])], extras: ["tableHint": .null])
        let file = NoteBlock.file(id: id(7), attachmentID: attachment.id, filename: attachment.originalFilename,
            contentTypeIdentifier: attachment.contentTypeIdentifier, byteCount: attachment.byteCount)
        let document = NoteDocument(blocks: [title, rich, .table(table, id: id(6)), file,
            .image(id: id(9), attachmentID: id(10), widthFraction: 0.5), // intentionally missing asset
            .checklist("Pack kit", id: id(11))], requires: ["text", "date"],
            extras: ["extension": .object(["counter": .uint(UInt64.max)])])
        return (try NoteContentCodec.encode(document), try XCTUnwrap(attachment.payload))
    }

    private func keep(_ bytes: Data, name: String, type: String) {
        let item = XCTAttachment(data: bytes, uniformTypeIdentifier: type)
        item.name = name
        item.lifetime = .keepAlways
        add(item)
    }

    func testProduceMacExchange() throws {
        let (note, file) = try sample()
        let (again, sameFile) = try sample()
        XCTAssertEqual(note, again)
        XCTAssertEqual(file, sameFile)
        XCTAssertTrue(NoteContentCodec.decode(note).isEditable)
        keep(note, name: "exchange-note.json", type: "public.json")
        keep(file, name: "exchange-file.txt", type: "public.plain-text")
    }

    /// For the return leg, the lead stages the exported phone attachments as these resources.
    func testMacReopensExchangeResources() throws {
        let bundle = Bundle(for: PhoneExchangeFixtureTests.self)
        let returned = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "exchange-note", withExtension: "json")))
        let file = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "exchange-file", withExtension: "txt")))
        let (original, originalFile) = try sample()
        XCTAssertEqual(returned, original)
        XCTAssertEqual(file, originalFile)
        guard case let .editable(doc) = NoteContentCodec.decode(returned) else { return XCTFail("Mac cannot reopen the phone bytes") }
        XCTAssertEqual(doc.attachmentIDs, [id(8), id(10)])
        XCTAssertEqual(doc.blocks[1].marks, [NoteMark(.bold, offset: 3, length: 4)])
        XCTAssertEqual(doc.blocks[2].table?.rows.first?.cells.first?.text, "42")
    }
}
