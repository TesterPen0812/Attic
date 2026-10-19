import AppKit
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class RoundFX1Tests: XCTestCase {
    private func engine() -> NoteEditorEngine {
        NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
    }

    func testRTFDMixedAttachmentsKeepExactBytesNamesOrderAndUndo() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pdfView = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        pdfView.string = "Owned PDF"
        let fixtures: [(String, Data)] = [
            ("contract.pdf", pdfView.dataWithPDF(inside: pdfView.bounds)),
            ("café image.png", try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))),
            ("résumé notes.txt", Data("Keep exact text\n日本語".utf8)),
            ("payload {one}\\copy.bin", Data([0, 255, 1, 2, 3]))
        ]
        let source = NSMutableAttributedString(string: "Before ")
        for (name, bytes) in fixtures {
            let wrapper = FileWrapper(regularFileWithContents: bytes); wrapper.preferredFilename = name
            source.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            source.append(NSAttributedString(string: " Between "))
        }
        source.append(NSAttributedString(string: "After ¬ literal"))
        let data = try source.data(from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let engine = engine(), before = try NoteContentCodec.encode(engine.document())
        let (_, view) = engine.makeView(); defer { engine.detachView() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setData(data, forType: .rtfd); view.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(view.readSelection(from: board, type: .rtfd))
        let document = engine.document()
        let objects = document.blocks.filter { $0.kind == .file || $0.kind == .image }
        XCTAssertEqual(objects.map(\.kind), [.file, .image, .file, .file])
        let staged = engine.stagedAttachments(for: document)
        for (object, fixture) in zip(objects, fixtures) {
            let payload = try XCTUnwrap(staged.first { $0.id == object.attachmentID })
            XCTAssertEqual(payload.filename, fixture.0)
            XCTAssertEqual(payload.data, fixture.1)
            XCTAssertTrue(payload.payloadIsVerified)
        }
        XCTAssertEqual(staged.count, fixtures.count)
        XCTAssertTrue(document.blocks.first { $0.filename == "contract.pdf" }?.contentTypeIdentifier == "com.adobe.pdf")
        let prose = document.blocks.filter { $0.kind == .text }.map(\.text).joined()
        XCTAssertEqual(prose, "TitleBefore  Between  Between  Between  Between After ¬ literal")
        XCTAssertFalse(prose.contains("\u{fffc}")); XCTAssertFalse(prose.contains("ATTICPASTE"))
        let after = try NoteContentCodec.encode(document)
        guard case let .editable(decoded) = NoteContentCodec.decode(after) else { return XCTFail("decode") }
        XCTAssertEqual(try NoteContentCodec.encode(NoteEditorEngine(noteID: UUID(), document: decoded).document()), after)
        engine.undoCommand(); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before)
        engine.redoCommand(); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), after)
        XCTAssertEqual(engine.stagedAttachments(for: engine.document()).map(\.data), staged.map(\.data))
        engine.onFragmentAdmission = { _, _ in "Owned refusal" }
        XCTAssertFalse(engine.pasteRichText(data, type: .rtfd, at: NSRange(location: 6, length: 0)))
        XCTAssertEqual(try NoteContentCodec.encode(engine.document()), after)
        XCTAssertEqual(engine.stagedAttachments(for: engine.document()), staged)
    }

    func testUnavailableRTFDResourcesUsePlaceholderWithoutReadingPaths() throws {
        let rtf = #"{\rtf1\ansi Before {\NeXTGraphic missing.pdf \width0 \height0}\'ac After {\NeXTGraphic https://example.invalid/file.pdf \width0 \height0}\'ac End}"#
        let wrapper = FileWrapper(directoryWithFileWrappers: ["TXT.rtf": FileWrapper(regularFileWithContents: Data(rtf.utf8)),
            "missing.pdf": FileWrapper(symbolicLinkWithDestinationURL: URL(fileURLWithPath: "/etc/hosts"))])
        let engine = engine()
        XCTAssertTrue(engine.pasteRichText(try XCTUnwrap(wrapper.serializedRepresentation), type: .rtfd,
            at: NSRange(location: 6, length: 0)))
        XCTAssertEqual(engine.document().blocks.dropFirst().map(\.text), ["Before [Attachment] After [Attachment] End"])
        XCTAssertTrue(engine.stagedAttachments(for: engine.document()).isEmpty)
    }

    func testHTMLListsKeepEditableStartsNestedKindsAndChecklistText() throws {
        let engine = engine()
        let html = "<ol start='7'><li>Seven<ul><li>Child</li></ul></li><li>Eight</li></ol><ul><li>[ ] Task</li><li>[x] Done</li></ul>"
        XCTAssertTrue(engine.pasteRichText(Data(html.utf8), type: .html, at: NSRange(location: 6, length: 0)))
        let blocks = Array(engine.document().blocks.dropFirst())
        // The native HTML reader supplies a terminal paragraph; keep it too.
        XCTAssertEqual(blocks.map(\.text), ["Seven", "Child", "Eight", "[ ] Task", "[x] Done", ""])
        XCTAssertEqual(blocks.map(\.style), ["number", "bullet", "number", "bullet", "bullet", nil])
        XCTAssertEqual(blocks.map(\.start), [7, nil, nil, nil, nil, nil])
        XCTAssertEqual(blocks.map(\.indent), [nil, 1, nil, nil, nil, nil])
        XCTAssertEqual(engine.listMarker(at: (engine.textStorage.string as NSString).range(of: "Eight").location), .number("8."))
    }

    func testOtherNativeListMarkersKeepTheirStartingOrdinalAndAdjacentRestarts() throws {
        for marker in ["lower-alpha", "upper-alpha", "lower-roman", "upper-roman", "circle", "square"] {
            let engine = engine()
            let html = "<ol start='7' style='list-style-type: \(marker)'><li>Seven</li><li>Eight</li></ol>"
            let read = try XCTUnwrap(NotePasteReader.read(Data(html.utf8), type: .html))
            let list = try XCTUnwrap((read.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last)
            XCTAssertTrue(engine.pasteRichText(Data(html.utf8), type: .html, at: NSRange(location: 6, length: 0)))
            let bullets = ["circle", "square"].contains(marker)
            XCTAssertEqual(engine.document().blocks.dropFirst().map(\.text), bullets ? ["Seven", "Eight", ""] :
                [list.marker(forItemNumber: 7) + " Seven", list.marker(forItemNumber: 8) + " Eight", ""], marker)
            XCTAssertEqual(engine.document().blocks.dropFirst().map(\.style), bullets ? ["bullet", "bullet", nil] : [nil, nil, nil])
        }
        let engine = engine()
        XCTAssertTrue(engine.pasteRichText(Data("<ol start='7'><li>Seven</li></ol><ol start='12'><li>Twelve</li></ol>".utf8),
            type: .html, at: NSRange(location: 6, length: 0)))
        XCTAssertEqual(engine.document().blocks.dropFirst().map(\.start), [7, 12, nil])
    }

    func testHTMLTypeAttributeKeepsLetterAndRomanMarkers() {
        for (type, seven, eight) in [("a", "g.", "h."), ("A", "G.", "H."), ("i", "vii.", "viii."), ("I", "VII.", "VIII.")] {
            let engine = engine()
            let html = "<ol type='\(type)' start='7'><li>Seven</li><li>Eight</li></ol>"
            XCTAssertTrue(engine.pasteRichText(Data(html.utf8), type: .html, at: NSRange(location: 6, length: 0)))
            XCTAssertEqual(engine.document().blocks.dropFirst().map(\.text), [seven + " Seven", eight + " Eight", ""], type)
            XCTAssertTrue(engine.document().blocks.dropFirst().allSatisfy { $0.style == nil })
        }
    }

    func testRTFDUnstorableAttachmentsKeepReadablePlaceholders() throws {
        for bytes in [Data(), Data(repeating: 1, count: Int(AttachmentLimits.maxBytesPerAttachment) + 1)] {
            let rtf = #"{\rtf1\ansi Before {\NeXTGraphic owned.bin \width0 \height0}\'ac After}"#
            let wrapper = FileWrapper(directoryWithFileWrappers: [
                "TXT.rtf": FileWrapper(regularFileWithContents: Data(rtf.utf8)),
                "owned.bin": FileWrapper(regularFileWithContents: bytes)])
            let engine = engine()
            XCTAssertTrue(engine.pasteRichText(try XCTUnwrap(wrapper.serializedRepresentation), type: .rtfd,
                at: NSRange(location: 6, length: 0)))
            XCTAssertEqual(engine.document().blocks.dropFirst().map(\.text), ["Before [Attachment] After"])
            XCTAssertTrue(engine.stagedAttachments(for: engine.document()).isEmpty)
        }
    }

    func testMarkdownEmptyParagraphMatrixAndSeparateCalloutsRoundTripExactly() throws {
        var heading = NoteBlock.text("", style: "heading"); heading.level = 3
        var box = NoteBlock.text("First", style: "quote"); box.callout = "💡"
        var separate = box; separate.text = ""; separate.calloutStart = true
        var continued = box; continued.text = "Continued"
        for empty in [NoteBlock.text(""), heading, .text("", style: "quote")] {
            for tail in [[NoteBlock.text("After")], []] {
                let original = NoteDocument(blocks: [.text("Title"), empty, empty] + tail)
                let canonical = NoteEditorEngine(noteID: UUID(), document: original).document()
                let markdown = NoteMarkdownExport.markdown(canonical)
                let imported = NoteEditorEngine(noteID: UUID(), document: try NoteMarkdownImport.document(markdown)).document()
                XCTAssertEqual(try NoteContentCodec.encode(imported), try NoteContentCodec.encode(canonical), markdown)
            }
        }
        let original = NoteDocument(blocks: [.text("Title"), box, separate, continued])
        let imported = try NoteMarkdownImport.document(NoteMarkdownExport.markdown(original))
        XCTAssertEqual(imported.blocks.map(\.text), original.blocks.map(\.text))
        XCTAssertEqual(imported.blocks.map(\.calloutStart), [false, false, true, false])
        let external = try NoteMarkdownImport.document("> [!TIP]\n> First\n\n> [!TIP]\n> Second")
        XCTAssertEqual(external.blocks.map(\.text), ["First", "Second"])
        XCTAssertEqual(external.blocks.map(\.calloutStart), [false, true])
    }

    func testMarkdownOrdinaryExportBytesAndLiteralHTMLCodeStayUnchanged() throws {
        var box = NoteBlock.text("One", style: "quote"); box.callout = "💡"
        var continued = box; continued.text = "Two"
        var number = NoteBlock.text("Seven", style: "number"); number.start = 7
        let doc = NoteDocument(blocks: [.text("Title"), .text("Body"), box, continued, number,
            .text("Eight", style: "number"), .text("Quoted", style: "quote")])
        XCTAssertEqual(NoteMarkdownExport.markdown(doc), "# Title\n\nBody\n\n> [!NOTE]\n> 💡 One\n>\n> Two\n\n7. Seven\n8. Eight\n\n> Quoted")
        XCTAssertEqual(NoteMarkdownExport.markdown(NoteDocument(blocks: [.text("   "), .text("Body")])), "Body")
        let literal = "<br>\n## <br>\n> <br>\n<!-- attic:callout-start -->\n\n> [!NOTE]"
        let imported = try NoteMarkdownImport.document("```\n" + literal + "\n```")
        XCTAssertEqual(imported.blocks.map(\.text).joined(separator: "\n"), literal)
        XCTAssertTrue(imported.blocks.allSatisfy { $0.style == "mono" && !$0.calloutStart })
        let prose = NoteDocument(blocks: [.text("Title"), .text("<br>"), .text("<!-- attic:callout-start -->")])
        XCTAssertEqual(try NoteMarkdownImport.document(NoteMarkdownExport.markdown(prose)).blocks.map(\.text), prose.blocks.map(\.text))
    }
}

/// Find-only regressions and controls against ce4eb33e. All fixtures are owned
/// by the test; no application store, general pasteboard or visible window.
@MainActor
final class PhaseXHunt15Tests: XCTestCase {
    private func bytes(_ document: NoteDocument) throws -> Data {
        try NoteContentCodec.encode(document)
    }

    func testH15_01SeparateCalloutsSurviveMarkdownExportImport() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks:
            [.text("Title"), .text("First"), .text("Second")]))
        for word in ["First", "Second"] {
            XCTAssertTrue(engine.perform(.paragraph(.callout(icon: "💡")),
                selection: (engine.textStorage.string as NSString).range(of: word)))
        }
        let original = engine.document()
        XCTAssertTrue(original.blocks[2].calloutStart, "real format picks create separate boxes")
        let saved = try bytes(original)
        guard case let .editable(reopened) = NoteContentCodec.decode(saved) else { return XCTFail("decode") }
        XCTAssertEqual(try bytes(NoteEditorEngine(noteID: UUID(), document: reopened).document()), saved)
        let markdown = NoteMarkdownExport.markdown(original)
        let importedFragment = try NoteMarkdownImport.document(markdown)
        let imported = NoteEditorEngine(noteID: UUID(), document: importedFragment).document()
        print("H15-01 markdown=\(markdown.debugDescription) starts=\(imported.blocks.map(\.calloutStart))")
        XCTAssertEqual(imported.blocks.map(\.text), original.blocks.map(\.text))
        XCTAssertEqual(imported.blocks.map(\.callout), original.blocks.map(\.callout))
        XCTAssertTrue(imported.blocks[2].calloutStart, "the second same-icon box must remain separate")
        XCTAssertEqual(try bytes(imported), saved, "lossless text-only Markdown round-trip")
    }

    func testH15_02EmptyFormattedLinesSurviveMarkdownExportImport() throws {
        for paragraph: NoteParagraphStyle in [.body, .heading(2), .quote, .callout(icon: "💡"), .mono] {
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks:
                [.text("Title"), .text(""), .text("After")]))
            if paragraph != .body {
                XCTAssertTrue(engine.perform(.paragraph(paragraph), selection: NSRange(location: 6, length: 0)))
            }
            let original = engine.document(), saved = try bytes(original)
            guard case let .editable(reopened) = NoteContentCodec.decode(saved) else { return XCTFail("decode") }
            XCTAssertEqual(try bytes(NoteEditorEngine(noteID: UUID(), document: reopened).document()), saved)
            let markdown = NoteMarkdownExport.markdown(original)
            let importedFragment = try NoteMarkdownImport.document(markdown)
            let imported = NoteEditorEngine(noteID: UUID(), document: importedFragment).document()
            print("H15-02 style=\(paragraph) markdown=\(markdown.debugDescription) blocks=\(imported.blocks)")
            XCTAssertEqual(try bytes(imported), saved, "empty \(paragraph) paragraph must survive")
        }
    }

    func testH15_03RTFDFileAttachmentDoesNotSilentlyDisappear() throws {
        let source = NSMutableAttributedString(string: "Before ")
        let pdfView = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        pdfView.string = "Owned test contract"
        let pdf = pdfView.dataWithPDF(inside: pdfView.bounds)
        let provider = try XCTUnwrap(CGDataProvider(data: pdf as CFData))
        XCTAssertEqual(try XCTUnwrap(CGPDFDocument(provider)).numberOfPages, 1)
        let wrapper = FileWrapper(regularFileWithContents: pdf)
        wrapper.preferredFilename = "contract.pdf"
        source.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        source.append(NSAttributedString(string: " After"))
        let data = try source.data(from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let package = try XCTUnwrap(FileWrapper(serializedRepresentation: data))
        XCTAssertTrue(try XCTUnwrap(package.fileWrappers).values.contains { $0.regularFileContents == pdf },
            "the real PDF is physically embedded in the source RTFD")
        if let rtf = package.fileWrappers?["TXT.rtf"]?.regularFileContents {
            var images: [NotePasteReader.Image] = []
            let safe = try XCTUnwrap(NotePasteReader.sanitizeRTF(rtf, resources: ["contract.pdf": pdf], images: &images))
            print("H15-03 RTF", String(decoding: rtf, as: UTF8.self).debugDescription)
            print("H15-03 SAFE", String(decoding: safe, as: UTF8.self).debugDescription)
        }
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        let board = NSPasteboard(name: .init("H15-RTFD-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setData(data, forType: .rtfd)
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        XCTAssertTrue(view.readSelection(from: board, type: .rtfd))
        XCTAssertTrue(engine.plainText.contains("Before"))
        XCTAssertTrue(engine.plainText.contains("After"))
        print("H15-03 pasted=\(engine.plainText.debugDescription)")
        // The established unsupported-attachment policy in pasteRichText is a
        // readable [Attachment], rather than silently joining its neighbours.
        XCTAssertTrue(engine.plainText.contains("[Attachment]") ||
            engine.document().blocks.contains { $0.kind == .file },
            "keep the file or at least the promised readable placeholder")
    }

    func testH15_04HTMLOrderedListKeepsStartingNumber() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
        let html = Data("<ol start='7'><li>Seven</li><li>Eight</li></ol>".utf8)
        XCTAssertTrue(engine.pasteRichText(html, type: .html, at: NSRange(location: 6, length: 0)))
        let read = try XCTUnwrap(NotePasteReader.read(html, type: .html))
        read.text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: read.text.length)) { value, _, _ in
            let lists = (value as? NSParagraphStyle)?.textLists ?? []
            print("H15-04 SOURCE", read.text.string.debugDescription,
                lists.map { "format=\($0.markerFormat.rawValue) start=\($0.startingItemNumber)" })
        }
        let items = engine.document().blocks.filter { $0.style == "number" }
        XCTAssertEqual(items.map(\.text), ["Seven", "Eight"])
        XCTAssertEqual(items.first?.start, 7, "a pasted list starting at 7 must not restart at 1")
        print("H15-04 markdown=\(NoteMarkdownExport.markdown(engine.document()).debugDescription)")
    }

    func testUntouchedCalloutsAndEmptyLinesKeepSavedBytes() throws {
        var callout = NoteBlock.text("One", style: "quote"); callout.callout = "💡"
        var next = NoteBlock.text("Two", style: "quote"); next.callout = "💡"; next.calloutStart = true
        var empty = NoteBlock.text("", style: "heading"); empty.level = 2
        for blocks in [[.text("Title"), callout, next, .text("")], [.text("Title"), empty, .text("After")]] {
            let source = NoteDocument(blocks: blocks), saved = try bytes(source)
            let engine = NoteEditorEngine(noteID: UUID(), document: source)
            let (_, _) = engine.makeView()
            XCTAssertEqual(try bytes(engine.document()), saved)
            engine.detachView()
        }
    }

    private struct Reference: Equatable {
        var texts = ["alpha", "beta"]
        var styles = ["body", "body"]
        var cells = [["h1", "h2"], ["v1", "v2"]]
    }

    func testGeneratedCommandsUndoRedoAcrossNoteSwitches() async throws {
        for seed in 0..<6 {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let ids = [UUID(), UUID()]
            for (index, id) in ids.enumerated() {
                guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [
                    .text("Note \(index)"), .text("alpha"), .text("beta"),
                    .table(NoteTable(texts: [["h1", "h2"], ["v1", "v2"]]))])) else { return XCTFail("seed") }
            }
            let controller = NotesPageController(store: store,
                journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "H15-Visits")),
                saveDelay: .seconds(600), pauseVersionDelay: .seconds(600))
            await controller.startAndWait()
            var models = [Reference(), Reference()]
            var engines: [NoteEditorEngine] = [], views: [NoteEditorTextView] = [], scrolls: [NSScrollView] = []
            for id in ids {
                guard await controller.openDurably(noteID: id) else { return XCTFail("open") }
                let engine = try XCTUnwrap(controller.active?.engine)
                let (scroll, view) = engine.makeView()
                engines.append(engine); views.append(view); scrolls.append(scroll)
            }
            defer { engines.forEach { $0.detachView() }; withExtendedLifetime(scrolls) {} }
            var rng = UInt64(seed) + 0x1515
            func next() -> Int {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                return Int((rng >> 32) & 0x7fff_ffff)
            }
            for step in 0..<60 {
                let note = next() % 2, peer = 1 - note, line = next() % 2, kind = next() % 11
                guard await controller.openDurably(noteID: ids[peer]),
                      await controller.openDurably(noteID: ids[note]) else { return XCTFail("visit") }
                let engine = engines[note], view = views[note]
                let before = engine.document(), beforeBytes = try bytes(before)
                let peerBytes = try bytes(engines[peer].document())
                let beforeModel = models[note]
                let start = 7 + (line == 0 ? 0 : models[note].texts[0].utf16.count + 1)
                let end = start + models[note].texts[line].utf16.count
                var selection = NSRange(location: end, length: 0)
                view.setSelectedRange(selection)
                let generation = engine.history.recordingGeneration
                let table = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
                let label = "seed=\(seed) step=\(step) note=\(note) kind=\(kind) line=\(line)"
                switch kind {
                case 0:
                    let text = ["x", "e\u{301}", "👩🏽‍💻"][next() % 3]
                    models[note].texts[line] += text
                    view.insertText(text, replacementRange: selection)
                case 1:
                    if let last = models[note].texts[line].last, models[note].texts[line].count > 1 {
                        models[note].texts[line].removeLast()
                        XCTAssertTrue(engine.performEdit(NSRange(location: end - last.utf16.count, length: last.utf16.count),
                            with: NSAttributedString(), name: "Delete"), label)
                    }
                case 2:
                    // Only line 0 changes style: the neighbour stays Body, so
                    // a code/callout command cannot target a multi-line run.
                    let styles: [(NoteParagraphStyle, String)] = [(.body, "body"), (.bullet, "bullet"),
                        (.number, "number"), (.callout(icon: "💡"), "callout"), (.mono, "mono")]
                    let picked = styles[next() % styles.count]
                    models[note].styles[0] = picked.1
                    selection = NSRange(location: 7, length: 0); view.setSelectedRange(selection)
                    _ = engine.perform(.paragraph(picked.0), selection: selection)
                case 3:
                    models[note].texts[line] += "p"
                    XCTAssertTrue(engine.pastePlainText("p", at: selection), label)
                case 4:
                    // Markdown is pasted only into the ordinary Body neighbour.
                    let at = 8 + models[note].texts[0].utf16.count + models[note].texts[1].utf16.count
                    models[note].texts[1] += "q"
                    selection = NSRange(location: at, length: 0); view.setSelectedRange(selection)
                    XCTAssertTrue(engine.pasteMarkdown("**q**", at: selection), label)
                case 5:
                    models[note].cells[1][0] += "t"
                    XCTAssertTrue(engine.changeTable(table, name: "Cell") { $0.rows[1].cells[0].text += "t" }, label)
                case 6:
                    models[note].cells.swapAt(0, 1)
                    XCTAssertTrue(engine.moveRow(of: table, from: 0, to: 1), label)
                case 7:
                    for row in models[note].cells.indices { models[note].cells[row].swapAt(0, 1) }
                    XCTAssertTrue(engine.moveColumn(of: table, from: 0, to: 1), label)
                case 8:
                    // Move two ordinary paragraphs; styled-run moves have
                    // separate coverage in the existing generated suite.
                    if models[note].styles == ["body", "body"] {
                        models[note].texts.swapAt(0, 1)
                        selection = NSRange(location: 7, length: 0); view.setSelectedRange(selection)
                        XCTAssertTrue(engine.perform(.moveDown, selection: selection), label)
                    }
                case 9:
                    selection = NSRange(location: start, length: 1); view.setSelectedRange(selection)
                    _ = engine.perform(.mark(.bold), selection: selection)
                default:
                    models[note].texts[line] += "gh"
                    engine.history.beginGroup()
                    view.insertText("g", replacementRange: selection)
                    view.insertText("h", replacementRange: view.selectedRange())
                    engine.history.endGroup()
                }
                func checkModel() {
                    let actual = engine.document()
                    let lines = Array(actual.blocks.filter { $0.kind == .text }.dropFirst())
                    XCTAssertEqual(lines.map(\.text), models[note].texts, label)
                    XCTAssertEqual(lines.map { $0.callout == nil ? ($0.style ?? "body") : "callout" }, models[note].styles, label)
                    XCTAssertEqual(actual.blocks.first { $0.kind == .table }?.table?.texts, models[note].cells, label)
                }
                checkModel()
                guard generation != engine.history.recordingGeneration else {
                    XCTAssertEqual(models[note], beforeModel, label); continue
                }
                let after = try bytes(engine.document()), afterSelection = view.selectedRange()
                guard await controller.openDurably(noteID: ids[peer]),
                      await controller.openDurably(noteID: ids[note]) else { return XCTFail("revisit") }
                XCTAssertTrue(engine.history.undo(), label)
                XCTAssertEqual(try bytes(engine.document()), beforeBytes, label + " Undo")
                XCTAssertEqual(view.selectedRange(), selection, label + " Undo selection")
                guard await controller.openDurably(noteID: ids[peer]),
                      await controller.openDurably(noteID: ids[note]) else { return XCTFail("revisit redo") }
                XCTAssertTrue(engine.history.redo(), label)
                XCTAssertEqual(try bytes(engine.document()), after, label + " Redo")
                XCTAssertEqual(view.selectedRange(), afterSelection, label + " Redo selection")
                XCTAssertEqual(try bytes(engines[peer].document()), peerBytes, label + " peer unchanged")
                checkModel()
                // Reopening is independent of live attributed storage.
                guard case let .editable(decoded) = NoteContentCodec.decode(after) else { return XCTFail("decode") }
                XCTAssertEqual(try bytes(NoteEditorEngine(noteID: UUID(), document: decoded).document()), after, label + " reopen")
            }
            _ = await controller.prepareToLeaveDurably(.quit)
        }
        print("H15_GENERATED seeds=6 operations=360 with note switches, Undo, Redo and reopen")
    }
}

@MainActor
final class PhaseXHunt15LayoutTests: RoundF3TestCase {
    func testH15_05EndKeyReachesTheBottomOfTheFinalObject() throws {
        let objects: [(String, NoteBlock)] = [
            ("table", .table(NoteTable(texts: [["a", "b"], ["c\u{2028}d", "e"]]))),
            ("image", .image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400))
        ]
        for (label, object) in objects {
            for blank in [false, true] {
                for fromEnd in [false, true] {
                    let prefix = [.text("Title")] + (0..<24).map { NoteBlock.text("Line \($0)") }
                    let (engine, view) = editor(prefix + (blank ? [.text("")] : []) + [object], height: 560)
                    let scroll = try XCTUnwrap(view.enclosingScrollView)
                    if fromEnd { view.doCommand(by: NSSelectorFromString("moveToEndOfDocument:")) }
                    else { view.setSelectedRange(NSRange(location: 0, length: 0)) }
                    settle(view)
                    let beforeSelection = view.selectedRange()
                    if fromEnd {
                        XCTAssertEqual(beforeSelection, NSRange(location: engine.textStorage.length, length: 0),
                            "Command-Down reaches the actual end")
                    }
                    let before = try NoteContentCodec.encode(engine.document())
                    let bottom = try XCTUnwrap(engine.trailingBlockBottom()) + view.textContainerOrigin.y
                    // StandardKeyBinding.dict maps End (Fn-Right) to this exact
                    // command. This fixture uses the real panel's 560 pt height.
                    view.doCommand(by: NSSelectorFromString("scrollToEndOfDocument:")); settle(view)
                    let deadline = Date().addingTimeInterval(1)
                    while bottom > view.visibleRect.maxY + 0.5, Date() < deadline {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                    }
                    print("H15-05", label, "blank", blank, "fromEnd", fromEnd, "bottom", bottom,
                        "visible", view.visibleRect, "selection", view.selectedRange(),
                        "last glyph", engine.rect(for: NSRange(location: engine.textStorage.length - 1, length: 1)) as Any)
                    XCTAssertLessThanOrEqual(bottom, view.visibleRect.maxY + 0.5,
                        "\(label), blank=\(blank), fromEnd=\(fromEnd): End reaches the final object")
                    XCTAssertEqual(view.selectedRange(), beforeSelection, "scrolling preserves the caret")
                    XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before, "scrolling never edits")
                    // Positive control: the document has enough scrollable room.
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, view.bounds.maxY - scroll.contentSize.height)))
                    scroll.reflectScrolledClipView(scroll.contentView); settle(view)
                    XCTAssertLessThanOrEqual(bottom, view.visibleRect.maxY + 0.5,
                        "\(label): direct scrolling can reach the same bottom")
                }
            }
        }
    }

    func testTrailingBlocksAndTheirReopenedExtentsFitTheDocument() throws {
        let cases: [(String, NoteBlock)] = [
            ("body", .text("Mixed 👩🏽‍💻 e\u{301} text\u{2028}last")),
            ("callout", callout("Callout\u{2028}last")),
            ("empty callout", callout("")),
            ("code", code("let x = 1\u{2028}", language: "swift")),
            ("quote", .text("Quote", style: "quote")),
            ("empty heading", heading("", 2)),
            ("bullet", .text("List", style: "bullet")),
            ("table", .table(NoteTable(texts: [["a", "b"], ["c\u{2028}d", "e"]]))),
            ("image", .image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400)),
            ("file", .file(attachmentID: UUID(), filename: "owned.txt", contentTypeIdentifier: "public.plain-text", byteCount: 4)),
            ("divider", .divider())
        ]
        // FX1b: the old 60 pt host is below the panel's 460 pt minimum.
        // Retain every extent/scroll assertion at reachable panel sizes.
        for (width, height): (CGFloat, CGFloat) in [(340, 460), (340, 560), (420, 460), (420, 560)] {
            for (label, block) in cases {
                let original = NoteDocument(blocks: [.text("Title"), .text("Above"), .text(""), block])
                let data = try NoteContentCodec.encode(original)
                guard case let .editable(decoded) = NoteContentCodec.decode(data) else { return XCTFail("decode") }
                for (route, source) in [("live", original), ("reopened", decoded)] {
                    let (engine, view) = editor(source.blocks, width: width, height: height)
                    view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0)); settle(view)
                    let bottom = try XCTUnwrap(engine.trailingBlockBottom(), "\(label)/\(route)") + view.textContainerOrigin.y
                    XCTAssertLessThanOrEqual(bottom, view.bounds.maxY + 0.5, "\(label)/\(route): fragment fits")
                    engine.layoutManager?.enumerateTextLayoutFragments(from: engine.contentStorage.documentRange.location, options: [.ensuresLayout]) { fragment in
                        if let fragment = fragment as? NoteBlockLayoutFragment {
                            let painted = fragment.paintedBottom + fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y
                            XCTAssertLessThanOrEqual(painted, view.bounds.maxY + 0.5, "\(label)/\(route): decoration fits")
                        }
                        return true
                    }
                    XCTAssertEqual(try NoteContentCodec.encode(engine.document()), data, "layout never edits \(label)/\(route)")
                    view.scrollToEndOfDocument(nil); settle(view)
                    // Native scrolling may animate. Wait for the requested geometry,
                    // without changing the expected bottom or its half-point bound.
                    let deadline = Date().addingTimeInterval(1)
                    while bottom > view.visibleRect.maxY + 0.5, Date() < deadline {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                    }
                    print("H15-EXTENT", label, route, "bottom", bottom, "document", view.frame, "visible", view.visibleRect)
                    XCTAssertLessThanOrEqual(bottom, view.visibleRect.maxY + 0.5, "\(label)/\(route): scroll reaches bottom")
                    XCTAssertFalse(view.window?.isVisible ?? true)
                }
            }
        }
    }

    func testEndAfterPastingATallFinalTableHostsItsVisibleBottom() throws {
        let markdown = "| Row | Value |\n| --- | --- |\n" + (0..<32).map { "| \($0) | Value \($0) |" }.joined(separator: "\n")
        for command in ["scrollToEndOfDocument:", "moveToEndOfDocument:"] {
            let (engine, view) = editor([.text("Title"), .text("")], height: 460)
            let scroll = try XCTUnwrap(view.enclosingScrollView)
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 40, left: 0, bottom: 64, right: 0)
            XCTAssertTrue(engine.pasteMarkdown(markdown, at: NSRange(location: engine.textStorage.length, length: 0)))
            view.doCommand(by: NSSelectorFromString(command))
            // Let AppKit draw naturally: settle() would explicitly lay out
            // the viewport and could hide a missing command-time handoff.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let table = try XCTUnwrap(engine.tableViews().first, command)
            XCTAssertTrue(table.isDescendant(of: view), command + ": table is actually hosted")
            XCTAssertGreaterThan(table.canvas.visibleRect.height, 0, command + ": table bottom is painted")
            XCTAssertLessThanOrEqual(table.bounds.maxY, table.visibleRect.maxY + 0.5, command + ": last row is visible")
            XCTAssertFalse(view.window?.isVisible ?? true)
        }
    }

    func testTallFinalObjectsReachTheirRealEndAboveTheBottomControls() throws {
        let objects: [(String, NoteBlock)] = [
            ("table", .table(NoteTable(texts: (0..<32).map { ["Row \($0)", "Value \($0)"] }))),
            ("image", .image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 2400))
        ]
        for (width, height): (CGFloat, CGFloat) in [(340, 460), (340, 560), (420, 460), (420, 560)] {
            for (label, object) in objects {
                for blank in [false, true] {
                    let original = NoteDocument(blocks: [.text("Title"), .text("Above"), object] + (blank ? [.text("")] : []))
                    let data = try NoteContentCodec.encode(original)
                    guard case let .editable(decoded) = NoteContentCodec.decode(data) else { return XCTFail("decode") }
                    for (state, source) in [("live", original), ("reopened", decoded)] {
                        for command in ["scrollToEndOfDocument:", "moveToEndOfDocument:", "scroll-to-end"] {
                            let context = "\(label)/\(state)/\(width)x\(height)/blank=\(blank)/\(command)"
                            let (engine, view) = editor(source.blocks, width: width, height: height)
                            let scroll = try XCTUnwrap(view.enclosingScrollView)
                            // V-02: the clip includes the floating controls. Only
                            // the area outside these covered bands is clear; the
                            // bottom inset includes the 12 pt resting margin.
                            scroll.automaticallyAdjustsContentInsets = false
                            scroll.contentInsets = NSEdgeInsets(top: 40, left: 0, bottom: 64, right: 0)
                            view.setSelectedRange(NSRange(location: 0, length: 0)); settle(view)
                            let objectRange = try XCTUnwrap(engine.objects().first?.1)
                            let objectRect = try XCTUnwrap(engine.rect(for: objectRange))
                            XCTAssertGreaterThan(objectRect.height, scroll.contentView.bounds.height, context + ": object exceeds viewport")
                            let before = try NoteContentCodec.encode(engine.document())
                            let selection = view.selectedRange()
                            let bottom = try XCTUnwrap(engine.trailingBlockBottom()) + view.textContainerOrigin.y
                            XCTAssertLessThanOrEqual(bottom, view.bounds.maxY + 0.5, context + ": fragment fits")
                            if command == "scroll-to-end" {
                                scroll.contentView.scroll(to: NSPoint(x: 0, y: view.bounds.maxY - scroll.contentSize.height + scroll.contentInsets.bottom))
                                scroll.reflectScrolledClipView(scroll.contentView)
                            } else {
                                view.doCommand(by: NSSelectorFromString(command))
                            }
                            settle(view)
                            func clearBottom() -> CGFloat {
                                view.convert(scroll.contentView.bounds, from: scroll.contentView).maxY - scroll.contentInsets.bottom
                            }
                            let deadline = Date().addingTimeInterval(1)
                            while bottom > clearBottom() + 0.5, Date() < deadline {
                                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                            }
                            print("FX1b-END", context, "object", objectRect, "bottom", bottom,
                                  "document", view.frame, "clearBottom", clearBottom())
                            XCTAssertLessThanOrEqual(bottom, clearBottom() + 0.5, context + ": scroll reaches real bottom plus margin")
                            if command == "moveToEndOfDocument:" {
                                XCTAssertEqual(view.selectedRange(), NSRange(location: engine.textStorage.length, length: 0), context)
                            } else {
                                XCTAssertEqual(view.selectedRange(), selection, context + ": scrolling preserves caret")
                            }
                            XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before, context + ": scrolling never edits")
                            XCTAssertFalse(view.window?.isVisible ?? true)
                        }
                    }
                }
            }
        }
    }
}

/// Run separately with the existing key-window opt-in, under the Air lock.
/// These are never-ordered stock/Attic fixtures, with no keyboard events.
@MainActor
final class PhaseXHunt15NativeTests: RoundF3TestCase {
    func testMixedInlineFontsAndEmojiUseStocksNativeCaretFrame() throws {
        try requireKeyWindowTests()
        for paragraph in [NoteParagraphStyle.body, .heading(2)] {
            let (engine, view) = editor([.text("Title"), .text("plain 👩🏽‍💻 code suffix"), .text("After")])
            let line = (engine.textStorage.string as NSString).range(of: "plain")
            if paragraph != .body { XCTAssertTrue(engine.perform(.paragraph(paragraph), selection: line)) }
            XCTAssertTrue(engine.perform(.mark(.code), selection: (engine.textStorage.string as NSString).range(of: "code")))
            let native = NSTextView(usingTextLayoutManager: true)
            native.frame = CGRect(x: 0, y: 0, width: 340, height: 300)
            native.isRichText = false; native.isVerticallyResizable = true
            native.textContainerInset = view.textContainerInset
            native.textContainer?.lineFragmentPadding = 0
            native.textStorage?.setAttributedString(engine.textStorage)
            native.typingAttributes = view.typingAttributes
            let scroll = NSScrollView(frame: native.frame); scroll.documentView = native
            host(scroll, text: native, height: 300)
            for word in ["plain", "👩🏽‍💻", "code", "suffix"] {
                let at = (engine.textStorage.string as NSString).range(of: word).location
                view.setSelectedRange(NSRange(location: at, length: 0))
                native.setSelectedRange(NSRange(location: at, length: 0))
                let ours = try caret(view), stock = try caret(native)
                XCTAssertEqual(ours.frame.height, stock.frame.height, accuracy: 0.01, "\(paragraph)/\(word)")
                XCTAssertEqual(ours.frame.minY - ours.baseline, stock.frame.minY - stock.baseline,
                    accuracy: 0.01, "\(paragraph)/\(word): native top relative to baseline")
            }
        }
    }

    func testBlankAndLineSeparatorBaselinesStayExactAfterReopening() throws {
        try requireKeyWindowTests()
        for blocks in [
            [NoteBlock.text("Title"), .text("A"), .text(""), .text("B\u{2028}\u{2028}C")],
            [.text("Title"), callout("A"), .text("")],
            [.text("Title"), code("let x = 1"), .text("")]
        ] {
            let (engine, view) = editor(blocks)
            let saved = try NoteContentCodec.encode(engine.document())
            guard case let .editable(decoded) = NoteContentCodec.decode(saved) else { return XCTFail("decode") }
            let (_, reopened) = editor(decoded.blocks)
            let string = view.string as NSString
            var offsets = [6]
            for at in 6..<string.length where [0x0A, 0x2028].contains(string.character(at: at)) { offsets.append(at + 1) }
            for at in offsets {
                view.setSelectedRange(NSRange(location: at, length: 0))
                reopened.setSelectedRange(NSRange(location: at, length: 0))
                let live = try caret(view), readback = try caret(reopened)
                XCTAssertEqual(live.baseline, readback.baseline, accuracy: 0.01, "offset \(at)")
                XCTAssertEqual(live.frame, readback.frame, "offset \(at): exact native frame after reopen")
            }
        }
    }
}
