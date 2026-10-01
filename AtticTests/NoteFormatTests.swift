import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// `attic.note/1`: stable ids, capability checks, read-only future formats
/// kept as their original bytes, opaque unknown blocks (requirement 1).
final class NoteFormatTests: XCTestCase {
    func testTaskSnapshotAndOrdinaryNormalizationPreserveBodyIDsFilesMarksAndOtherCapabilities() throws {
        let id = UUID()
        var body = NoteBlock.text("Rich body")
        body.id = id
        body.marks = [.init(.bold, offset: 0, length: 4)]
        let file = NoteBlock.file(attachmentID: UUID(), filename: "original.txt", contentTypeIdentifier: "public.plain-text", byteCount: 12)
        var document = NoteDocument(blocks: [.text("Old title"), body, file], requires: ["text", "inline-marks-v1", "file-v1"],
            extras: ["futureDisplayHint": .string("keep")])
        let originalBody = document.blocks.dropFirst()
        document = try document.taskSnapshot(title: "Current task title")
        XCTAssertTrue(document.requires.contains("taskNote"))
        XCTAssertEqual(document.title, "Current task title")
        let ordinary = try document.ordinarySnapshot(title: "Preserved title")
        XCTAssertFalse(ordinary.requires.contains("taskNote"))
        XCTAssertEqual(ordinary.requires, ["text", "inline-marks-v1", "file-v1"])
        XCTAssertEqual(Array(ordinary.blocks.dropFirst()), Array(originalBody))
        XCTAssertEqual(ordinary.extras, document.extras)
        XCTAssertEqual(NoteContentCodec.decode(try NoteContentCodec.encode(document)).document, document)
        var unknown = document; unknown.requires.append("unknown-semantics")
        XCTAssertThrowsError(try unknown.ordinarySnapshot(title: "Must refuse"))
        XCTAssertThrowsError(try unknown.taskSnapshot(title: "Must refuse"))
    }
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
        let body = "Ship on [date:2026-10-01].\n- [ ] Buy cake\n![image](attic://image/\(imageID.uuidString))\n"
        let edited = try NoteAgentTextParser.document(title: "Launch notes", body: body, base: base)
        XCTAssertEqual(edited.blocks[0], base.blocks[0])
        XCTAssertEqual(edited.blocks[1], base.blocks[1], "an unchanged line keeps its date id")
        XCTAssertEqual(edited.blocks[2].id, checklistID, "unticked by the agent, same item")
        XCTAssertFalse(edited.blocks[2].checked)
        XCTAssertEqual(edited.blocks[3].id, imageID)
        XCTAssertEqual(edited.blocks[3].attachmentID, attachmentID)
        XCTAssertEqual(Set(edited.objectIDs).count, edited.objectIDs.count, "ids stay unique")

        let duplicated = "Ship on [date:2026-10-01].\n- [ ] Buy cake\n![image](attic://image/\(imageID.uuidString))\n![image](attic://image/\(imageID.uuidString))"
        XCTAssertThrowsError(try NoteAgentTextParser.document(title: "Launch notes", body: duplicated, base: base),
            "the A1 guard forbids adding an object through a text replacement")

        XCTAssertThrowsError(try NoteAgentTextParser.document(
            title: "T", body: "![image](attic://image/\(UUID().uuidString))", base: base))
    }

    func testDayParsingIsStrict() {
        XCTAssertNotNil(NoteDay(isoString: "2026-02-28"))
        XCTAssertNil(NoteDay(isoString: "2026-02-30"))
        XCTAssertNil(NoteDay(isoString: "26-02-01"))
        XCTAssertNil(NoteDay(isoString: "2026-2-1"))
    }

    @MainActor func testStructureAndMarksRoundTripWithDeepHeadingAndObjectBoundary() throws {
        var heading = NoteBlock.text("Imported", style: "heading")
        heading.level = 5
        var list = NoteBlock.text("A😀B\u{FFFC}C", style: "bullet")
        list.indent = 2
        list.inlines = [NoteInline(id: dateID, kind: .date(NoteDay(year: 2026, month: 10, day: 1)!))]
        list.marks = [NoteMark(.bold, offset: 0, length: 4),
                      NoteMark(.link, offset: 5, length: 1, url: "https://example.com")]
        let document = NoteDocument(blocks: [.text("Title"), heading, list, .divider()])
        let bytes = try NoteContentCodec.encode(document)
        let json = try XCTUnwrap(JSONDecoder().decode(NoteJSON.self, from: bytes).objectValue)
        XCTAssertEqual(Set(json["requires"]?.arrayValue?.compactMap(\.stringValue) ?? []),
                       ["structure-v1", "inline-marks-v1"])
        guard case let .editable(decoded) = NoteContentCodec.decode(bytes) else { return XCTFail("not editable") }
        XCTAssertEqual(decoded.blocks, document.blocks)
        XCTAssertEqual(decoded.blocks[1].level, 5)
        XCTAssertEqual(try NoteContentCodec.encode(decoded), bytes)
        XCTAssertEqual(NoteTextKitRoundTrip.document(afterRoundTrip: decoded).blocks, document.blocks)
        XCTAssertTrue(NoteMarkdownExport.markdown(decoded).contains("##### Imported"))
    }

    func testOlderEditorRejectsNewCapabilitiesWithoutChangingBytes() throws {
        var block = NoteBlock.text("bold")
        block.marks = [NoteMark(.bold, offset: 0, length: 4)]
        let bytes = try NoteContentCodec.encode(NoteDocument(blocks: [.text("T"), block]))
        let json = try XCTUnwrap(JSONDecoder().decode(NoteJSON.self, from: bytes).objectValue)
        let required = Set(json["requires"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        XCTAssertFalse(required.isSubset(of: ["text", "checklist", "image", "date"]), "older slice-1 preview must open read-only")
        let olderFixture = Data(#"{"format":1,"requires":["inline-marks-v1"],"blocks":[{"kind":"text","text":"T"}]}"#.utf8)
        XCTAssertEqual(NoteContentCodec.decode(olderFixture).isEditable, true, "this build knows the capability")
        let corrupt = Data(#"{"format":1,"requires":["inline-marks-v1"],"blocks":[{"kind":"text","text":"T"},{"kind":"text","text":"abc","marks":[{"kind":"bold","offset":2,"length":2}]}]}"#.utf8)
        guard case let .readOnly(original, .unsupportedContent, _) = NoteContentCodec.decode(corrupt) else { return XCTFail() }
        XCTAssertEqual(original, corrupt)
    }

    func testMarkOffsetFuzzNeverProducesWritableShiftedRange() {
        for offset in -2...7 {
            for length in -1...7 {
                let json = #"{"format":1,"requires":["inline-marks-v1"],"blocks":[{"kind":"text","text":"T"},{"kind":"text","text":"A😀￼B","inline":[{"kind":"date","id":"\#(dateID.uuidString)","offset":3,"date":"2026-10-01"}],"marks":[{"kind":"bold","offset":\#(offset),"length":\#(length)}]}]}"#
                let editable = NoteContentCodec.decode(Data(json.utf8)).isEditable
                let units = Array("A😀\u{FFFC}B".utf16)
                let valid = offset >= 0 && length > 0 && offset + length <= units.count &&
                    !units[offset..<min(units.count, offset + length)].contains(NoteDocument.objectUnit) &&
                    offset != 2 && offset + length != 2
                XCTAssertEqual(editable, valid, "offset \(offset), length \(length)")
            }
        }
    }

    func testEncoderRefusesMarkAcrossObjectOrEmojiBoundary() {
        var block = NoteBlock.text("A😀\u{FFFC}B")
        block.inlines = [NoteInline(id: dateID, kind: .date(NoteDay(year: 2026, month: 10, day: 1)!))]
        block.marks = [NoteMark(.bold, offset: 2, length: 1)]
        XCTAssertThrowsError(try NoteContentCodec.encode(NoteDocument(blocks: [.text("T"), block])))
        block.marks = [NoteMark(.bold, offset: 1, length: 3)]
        XCTAssertThrowsError(try NoteContentCodec.encode(NoteDocument(blocks: [.text("T"), block])))
    }

    func testStyledFirstBlockIsReadOnlyInsteadOfSilentlyBecomingATitle() {
        let raw = Data(#"{"format":1,"requires":["structure-v1"],"blocks":[{"kind":"text","text":"T","style":"heading","level":2}]}"#.utf8)
        guard case let .readOnly(original, .unsupportedContent, _) = NoteContentCodec.decode(raw) else { return XCTFail() }
        XCTAssertEqual(original, raw)
    }

    func testMarkdownExportsNumberedSequenceAndAllMarks() {
        var first = NoteBlock.text("Read", style: "number")
        first.marks = [NoteMark(.bold, offset: 0, length: 4)]
        var second = NoteBlock.text("Visit", style: "number")
        second.marks = [NoteMark(.link, offset: 0, length: 5, url: "https://example.com")]
        let document = NoteDocument(blocks: [.text("Plan"), first, second])
        XCTAssertEqual(NoteMarkdownExport.markdown(document),
                       "# Plan\n\n1. **Read**\n2. [Visit](https://example.com)")
    }

    func testAgentTextRefusesLossyRichEditsButKeepsCheckboxMetadataAndObjects() throws {
        var heading = NoteBlock.text("Hi 😀", style: "heading")
        heading.level = 2
        heading.marks = [NoteMark(.bold, offset: 0, length: 2)]
        var checked = NoteBlock.checklist("Due \u{FFFC}")
        checked.indent = 2
        checked.marks = [NoteMark(.italic, offset: 0, length: 3)]
        checked.inlines = [NoteInline(id: dateID, kind: .date(NoteDay(year: 2026, month: 10, day: 1)!))]
        let base = NoteDocument(blocks: [.text("Title"), heading, checked])
        let body = NoteTextExport.agentBody(base)
        XCTAssertEqual(try NoteAgentTextParser.document(title: "Title", body: body, base: base), base)
        var renamed = base
        renamed.blocks[0].text = "New title"
        XCTAssertEqual(try NoteAgentTextParser.document(title: "New title", body: body, base: base), renamed)
        let ticked = try NoteAgentTextParser.document(title: "Title", body: body.replacingOccurrences(of: "- [ ]", with: "- [x]"), base: base)
        var expected = base
        expected.blocks[2].checked = true
        XCTAssertEqual(ticked, expected)
        XCTAssertThrowsError(try NoteAgentTextParser.document(title: "Title", body: body.replacingOccurrences(of: "Hi 😀", with: "Bye 😀"), base: base)) {
            XCTAssertEqual($0 as? NoteAgentTextError, .lossyFormatting)
        }
        XCTAssertThrowsError(try NoteAgentTextParser.document(title: "Title", body: body + "\nNew text", base: base))
    }

    func testFragmentContextAllowsStyledFirstBlockButSavedDocumentDoesNot() throws {
        var first = NoteBlock.text("Heading", style: "heading")
        first.level = 2
        first.marks = [NoteMark(.bold, offset: 0, length: 7)]
        let fragment = NoteDocument(blocks: [first, .image(attachmentID: UUID())])
        let data = try NoteContentCodec.encode(fragment, context: .fragment)
        guard case let .editable(decoded) = NoteContentCodec.decode(data, context: .fragment) else { return XCTFail() }
        XCTAssertEqual(decoded.blocks, fragment.blocks)
        XCTAssertThrowsError(try NoteContentCodec.encode(fragment))
        XCTAssertFalse(NoteContentCodec.decode(data).isEditable)
    }
}

/// Command metadata and routing without a window or application host.
@MainActor
final class NotesShortcutMetadataTests: XCTestCase {
    func testOwnerShortcutsAreSharedByEveryFormatMenuAndHaveNoNotesCollisions() {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("Body")]))
        let router = NoteCommandRouter(engine: engine)
        for surface: NoteCommandSurface in [.noteMenu, .contextMenu, .menuBar, .formatPopover, .selectionBar] {
            let menu = router.formatMenuCommands(from: surface)
            let expected: [(String, KeyEquivalent, EventModifiers)] = [
                ("Quote", "4", [.command, .option]), ("Mono", "5", [.command, .option]),
                ("Checklist", "9", [.command, .shift])
            ]
            for (title, key, modifiers) in expected {
                XCTAssertEqual(menu.first { $0.title == title }?.shortcut, KeyboardShortcut(key, modifiers: modifiers))
            }
            for title in ["Highlight", "Code"] { XCTAssertNil(menu.first { $0.title == title }?.shortcut) }
        }
        let labels = NoteCommandCatalog.allCommands.compactMap(NoteCommandCatalog.shortcutLabel)
        XCTAssertEqual(labels.count, Set(labels).count, "each Notes chord routes to one command")
        XCTAssertEqual(NoteCommandCatalog.shortcutLabel(.paragraph(.quote)), "⌥⌘4")
        XCTAssertEqual(NoteCommandCatalog.shortcutLabel(.paragraph(.mono)), "⌥⌘5")
    }

    func testOptionCommandDigitsUseTheLayoutTranslationLikeShiftCommandLists() throws {
        let cases: [(String, UInt16, NoteFormatCommand)] = [
            ("¢", 21, .paragraph(.quote)), ("∞", 23, .paragraph(.mono))
        ]
        for (characters, keyCode, command) in cases {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            XCTAssertEqual(NoteCommandCatalog.command(for: event), command)
        }
        for modifiers: NSEvent.ModifierFlags in [.command, [.command, .option, .shift], [.command, .control]] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: "4", charactersIgnoringModifiers: "4",
                isARepeat: false, keyCode: 21))
            XCTAssertNil(NoteCommandCatalog.command(for: event))
        }
    }
}
