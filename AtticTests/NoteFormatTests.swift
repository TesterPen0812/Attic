import XCTest
@testable import Attic

/// `attic.note/1`: stable ids, capability checks, read-only future formats
/// kept as their original bytes, opaque unknown blocks (requirement 1).
final class NoteFormatTests: XCTestCase {
    private let dateID = UUID()
    private let checklistID = UUID()
    private let imageID = UUID()
    private let attachmentID = UUID()

    private func sampleDocument() -> NoteDocument {
        var dated = NoteBlock.text("Ship on \u{FFFC}.")
        dated.inlines = [NoteInline(id: dateID, kind: .date(NoteDay(year: 2026, month: 10, day: 1)!))]
        return NoteDocument(blocks: [
            .text("Launch notes"),
            dated,
            .checklist("Buy cake", id: checklistID, checked: true),
            .image(id: imageID, attachmentID: attachmentID, width: 240, pixelWidth: 1200, pixelHeight: 500),
            .text("")
        ])
    }

    func testDocumentRoundTripsThroughBytes() throws {
        let document = sampleDocument()
        let data = try NoteContentCodec.encode(document)
        guard case let .editable(decoded) = NoteContentCodec.decode(data) else { return XCTFail("not editable") }
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(try NoteContentCodec.encode(decoded), data, "encoding is deterministic")
        XCTAssertEqual(decoded.objectIDs, [dateID, checklistID, imageID])
        XCTAssertEqual(decoded.title, "Launch notes")
    }

    func testNewImageWidthUsesAColumnFractionWhileOldPointWidthsStillDecode() throws {
        let fraction = NoteDocument(blocks: [.text("Images"),
                                             .image(attachmentID: attachmentID, widthFraction: 0.6)])
        guard case let .editable(decoded) = NoteContentCodec.decode(try NoteContentCodec.encode(fraction)) else {
            return XCTFail()
        }
        XCTAssertEqual(decoded.blocks[1].widthFraction, 0.6)
        let old = sampleDocument()
        guard case let .editable(legacyWidth) = NoteContentCodec.decode(try NoteContentCodec.encode(old)) else {
            return XCTFail()
        }
        XCTAssertEqual(legacyWidth.blocks[3].width, 240)
        XCTAssertNil(legacyWidth.blocks[3].widthFraction)
    }

    func testUnknownFieldsAndSixtyFourBitIntegersAreKeptAtEveryLevel() throws {
        let json = """
        {"format":1,"future":{"big":9223372036854775807,"huge":18446744073709551615,"odd":9007199254740993},
         "blocks":[{"kind":"text","text":"T","color":"blue"},
                   {"kind":"text","text":"a\u{FFFC}","inline":[{"kind":"date","id":"\(dateID.uuidString)","offset":1,"date":"2026-10-01","tz":"x"}]},
                   {"kind":"checklist","id":"\(checklistID.uuidString)","text":"x","checked":false,"due":-9223372036854775808}]}
        """
        guard case let .editable(document) = NoteContentCodec.decode(Data(json.utf8)) else { return XCTFail("not editable") }
        XCTAssertEqual(document.extras["future"]?.objectValue?["big"], .int(Int64.max))
        XCTAssertEqual(document.extras["future"]?.objectValue?["huge"], .uint(UInt64.max))
        XCTAssertEqual(document.extras["future"]?.objectValue?["odd"], .int(9_007_199_254_740_993))
        XCTAssertEqual(document.blocks[0].extras["color"], .string("blue"))
        XCTAssertEqual(document.blocks[1].inlines.first?.extras["tz"], .string("x"))
        XCTAssertEqual(document.blocks[2].extras["due"], .int(Int64.min))
        let reencoded = try NoteContentCodec.encode(document)
        guard case let .editable(again) = NoteContentCodec.decode(reencoded) else { return XCTFail() }
        XCTAssertEqual(again, document)
    }

    func testNewerFormatIsReadOnlyAndKeepsItsOriginalBytes() throws {
        // Deliberately odd spacing and key order: only the original bytes are ever written back.
        let bytes = Data("{ \"blocks\" : [ {\"kind\":\"text\",\"text\":\"Hi\"} ],   \"format\": 2 , \"x\":1.50}".utf8)
        guard case let .readOnly(original, reason, preview) = NoteContentCodec.decode(bytes) else { return XCTFail() }
        XCTAssertEqual(original, bytes)
        XCTAssertEqual(reason, .newerFormat(2))
        XCTAssertEqual(preview?.title, "Hi")
    }

    func testUnknownRequiredCapabilityIsReadOnly() {
        let bytes = Data(#"{"format":1,"requires":["tables"],"blocks":[{"kind":"text","text":"Hi"}]}"#.utf8)
        guard case let .readOnly(original, reason, _) = NoteContentCodec.decode(bytes) else { return XCTFail() }
        XCTAssertEqual(original, bytes)
        XCTAssertEqual(reason, .requiresCapabilities(["tables"]))
        let known = Data(#"{"format":1,"requires":["checklist","date"],"blocks":[{"kind":"text","text":"Hi"}]}"#.utf8)
        XCTAssertTrue(NoteContentCodec.decode(known).isEditable)
    }

    func testUnreadableBytesAreReadOnlyAndKept() {
        let bytes = Data("not json".utf8)
        guard case let .readOnly(original, .unreadable, nil) = NoteContentCodec.decode(bytes) else { return XCTFail() }
        XCTAssertEqual(original, bytes)
    }

    func testUnknownKindsAndChangedFieldTypesAreKeptOpaquely() throws {
        let unknown = #"{"kind":"table","id":"\#(UUID().uuidString)","rows":[[1,2]]}"#
        let numericID = #"{"kind":"checklist","id":42,"text":"x"}"#
        let badOffset = #"{"kind":"text","text":"a￼","inline":[{"kind":"date","id":"\#(UUID().uuidString)","offset":0,"date":"2026-10-01"}]}"#
        let noKind = #"{"text":"orphan"}"#
        let json = #"{"format":1,"blocks":[{"kind":"text","text":"T"},\#(unknown),\#(numericID),\#(badOffset),\#(noKind),"just a string"]}"#
        guard case let .readOnly(original, .unsupportedContent, preview) = NoteContentCodec.decode(Data(json.utf8)),
              let document = preview else { return XCTFail() }
        XCTAssertEqual(original, Data(json.utf8))
        XCTAssertEqual(document.blocks.map(\.kind), [.text, .opaque, .opaque, .opaque, .opaque, .opaque])
        let reencoded = try NoteContentCodec.encode(document)
        let originalBlocks = try JSONDecoder().decode(NoteJSON.self, from: Data(json.utf8)).objectValue?["blocks"]
        let newBlocks = try JSONDecoder().decode(NoteJSON.self, from: reencoded).objectValue?["blocks"]
        XCTAssertEqual(originalBlocks, newBlocks, "every unreadable block is written back as it was")
    }

    func testUnknownInlineObjectIsReadOnlyAndKeptVerbatim() throws {
        let id = UUID()
        let json = #"{"format":1,"blocks":[{"kind":"text","text":"T"},{"kind":"text","text":"a￼b","inline":[{"kind":"mention","id":"\#(id.uuidString)","offset":1,"who":"sam"}]}]}"#
        guard case let .readOnly(original, .unsupportedContent, preview) = NoteContentCodec.decode(Data(json.utf8)),
              let document = preview else { return XCTFail() }
        guard case let .opaque(value) = document.blocks[1].inlines.first?.kind else { return XCTFail("opaque inline") }
        XCTAssertEqual(original, Data(json.utf8))
        XCTAssertEqual(value.objectValue?["who"], .string("sam"))
    }

    func testPlainTextAndAgentText() {
        let document = sampleDocument()
        XCTAssertEqual(NoteTextExport.plainText(document), "Launch notes\nShip on 2026-10-01.\n[x] Buy cake\n[Image]\n")
        XCTAssertEqual(NoteTextExport.agentBody(document),
                       "Ship on [date:2026-10-01].\n- [x] Buy cake\n![image](attic://image/\(imageID.uuidString))\n")
    }

    func testAgentTextKeepsObjectsItKeptAndRefusesUnknownImages() throws {
        let base = sampleDocument()
        let body = "Ship on [date:2026-10-01].\n- [ ] Buy cake\nNew line [date:2026-12-25]\n![image](attic://image/\(imageID.uuidString))\n![image](attic://image/\(imageID.uuidString))"
        let edited = try NoteAgentTextParser.document(title: "Launch notes", body: body, base: base)
        XCTAssertEqual(edited.blocks[0], base.blocks[0])
        XCTAssertEqual(edited.blocks[1], base.blocks[1], "an unchanged line keeps its date id")
        XCTAssertEqual(edited.blocks[2].id, checklistID, "unticked by the agent, same item")
        XCTAssertFalse(edited.blocks[2].checked)
        XCTAssertEqual(edited.blocks[3].inlines.count, 1)
        XCTAssertEqual(edited.blocks[4].id, imageID)
        XCTAssertEqual(edited.blocks[5].attachmentID, attachmentID)
        XCTAssertNotEqual(edited.blocks[5].id, imageID, "a second copy is a new placement")
        XCTAssertEqual(Set(edited.objectIDs).count, edited.objectIDs.count, "ids stay unique")

        XCTAssertThrowsError(try NoteAgentTextParser.document(
            title: "T", body: "![image](attic://image/\(UUID().uuidString))", base: base))
    }

    func testDayParsingIsStrict() {
        XCTAssertNotNil(NoteDay(isoString: "2026-02-28"))
        XCTAssertNil(NoteDay(isoString: "2026-02-30"))
        XCTAssertNil(NoteDay(isoString: "26-02-01"))
        XCTAssertNil(NoteDay(isoString: "2026-2-1"))
    }
}
