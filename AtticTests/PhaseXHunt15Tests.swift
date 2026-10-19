import AppKit
import SwiftData
import XCTest
@testable import Attic

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
        for (label, block) in cases {
            let original = NoteDocument(blocks: [.text("Title"), .text("Above"), .text(""), block])
            let data = try NoteContentCodec.encode(original)
            guard case let .editable(decoded) = NoteContentCodec.decode(data) else { return XCTFail("decode") }
            for (route, source) in [("live", original), ("reopened", decoded)] {
                let (engine, view) = editor(source.blocks, height: 60)
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
