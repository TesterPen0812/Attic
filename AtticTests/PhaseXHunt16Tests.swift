import AppKit
import XCTest
@testable import Attic

/// Find-only hunt on d8f1730e. Owned in-memory documents and private boards only.
@MainActor
final class PhaseXHunt16Tests: XCTestCase {
    private func canonical(_ document: NoteDocument) -> NoteDocument {
        NoteEditorEngine(noteID: UUID(), document: document).document()
    }

    private func roundTrip(_ document: NoteDocument) throws -> NoteDocument {
        let markdown = NoteMarkdownExport.markdown(document)
        print("H16 markdown=\(markdown.debugDescription)")
        return canonical(try NoteMarkdownImport.document(markdown))
    }

    func testBodyWhitespaceSurvivesMarkdownRoundTrip() throws {
        for text in ["    indented prose", " trailing  ", "   ", "\tTabbed", "one  two"] {
            let original = canonical(NoteDocument(blocks: [.text("Title"), .text(text), .text("After")]))
            let read = try roundTrip(original)
            XCTAssertEqual(read.blocks.map(\.text), original.blocks.map(\.text), text.debugDescription)
            XCTAssertEqual(read.blocks.map(\.style), original.blocks.map(\.style), text.debugDescription)
        }
    }

    func testCalloutBesideOrdinaryQuoteKeepsContainerIdentity() throws {
        for calloutFirst in [true, false] {
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("One"), .text("Two")]))
            XCTAssertTrue(engine.perform(.paragraph(calloutFirst ? .callout(icon: "💡") : .quote), selection: NSRange(location: 6, length: 0)))
            XCTAssertTrue(engine.perform(.paragraph(calloutFirst ? .quote : .callout(icon: "💡")), selection: NSRange(location: 10, length: 0)))
            let original = engine.document(), read = try roundTrip(original)
            XCTAssertEqual(read.blocks.map(\.text), original.blocks.map(\.text))
            XCTAssertEqual(read.blocks.map(\.callout), original.blocks.map(\.callout))
        }
    }

    func testInlineMarksSurviveMarkdownRoundTrip() throws {
        for mark in [NoteMark.Kind.bold, .italic, .underline, .strikethrough, .highlight, .code] {
            for text in ["hello", " hello ", "two words"] {
                var block = NoteBlock.text(text)
                block.marks = [NoteMark(mark, offset: 0, length: text.utf16.count)]
                let original = canonical(NoteDocument(blocks: [.text("Title"), block]))
                let read = try roundTrip(original)
                XCTAssertEqual(read.blocks.map(\.text), original.blocks.map(\.text), "\(mark) \(text.debugDescription)")
                XCTAssertEqual(read.blocks.last?.marks, original.blocks.last?.marks, "\(mark) \(text.debugDescription)")
            }
        }
    }

    func testOverlappingInlineMarksKeepTextAndCoverage() throws {
        var block = NoteBlock.text("abcdef")
        block.marks = [NoteMark(.bold, offset: 0, length: 4), NoteMark(.italic, offset: 2, length: 4)]
        let original = canonical(NoteDocument(blocks: [.text("Title"), block]))
        let read = try roundTrip(original)
        XCTAssertEqual(read.blocks.last?.text, "abcdef")
        XCTAssertEqual(read.blocks.last?.marks, original.blocks.last?.marks)
    }

    func testWholeNoteMarkdownKeepsTableHeaderAndCellBreaks() throws {
        for header in [true, false] {
            let table = NoteTable(texts: [["A", "B"], ["before\nafter", "left | right"]], headerRow: header)
            let original = canonical(NoteDocument(blocks: [.text("Title"), .table(table), .text("After")]))
            let read = try roundTrip(original)
            let got = try XCTUnwrap(read.blocks.compactMap(\.table).first)
            XCTAssertEqual(got.headerRow, header)
            XCTAssertEqual(got.rows.map { $0.cells.map(\.text) }, table.rows.map { $0.cells.map(\.text) })
        }
    }

    func testCalloutEmptyParagraphMatrixIsByteExact() throws {
        for icon in ["", "💡", "⚠️"] {
            for lines in [["", ""], ["", "After"], ["Before", ""], ["", "", "After"], ["Before", "", "After"]] {
                var blocks = [NoteBlock.text("Title")]
                blocks += lines.map { text in var b = NoteBlock.text(text, style: "quote"); b.callout = icon; return b }
                let original = canonical(NoteDocument(blocks: blocks)), read = try roundTrip(original)
                XCTAssertEqual(try NoteContentCodec.encode(read), try NoteContentCodec.encode(original), "\(icon) \(lines)")
            }
        }
    }

    func testRTFDNestedFileWrapperKeepsAttachment() throws {
        let source = NSMutableAttributedString(string: "Before ")
        let content = Data("owned payload".utf8)
        let child = FileWrapper(regularFileWithContents: content); child.preferredFilename = "content.txt"
        let package = FileWrapper(directoryWithFileWrappers: ["content.txt": child]); package.preferredFilename = "bundle.rtfd"
        source.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: package)))
        source.append(NSAttributedString(string: " After"))
        let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let read = try XCTUnwrap(NotePasteReader.read(data, type: .rtfd))
        XCTAssertTrue(read.text.string.contains("[Attachment]") || !read.files.isEmpty || !read.images.isEmpty)
        XCTAssertTrue(read.text.string.contains("Before")); XCTAssertTrue(read.text.string.contains("After"))
    }

    func testHTMLPasteKeepsBothTablesAndInterveningProse() throws {
        let html = "<table><tr><td>First</td><td>A</td></tr></table><p>Middle</p><table><tr><td>Second</td><td>B</td></tr></table>"
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
        let (_, view) = engine.makeView(); defer { engine.detachView() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString(html, forType: .html)
        view.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(view.readSelection(from: board, type: .html))
        for word in ["First", "A", "Middle", "Second", "B"] {
            XCTAssertTrue(engine.plainText.contains(word), "Clipboard word lost: \(word); pasted: \(engine.plainText)")
        }
    }

    func testHTMLTablePasteKeepsEmbeddedImageOutsideTheTable() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let html = "<img src='data:image/png;base64," + png.base64EncodedString() + "'><table><tr><td>A</td><td>B</td></tr></table>"
        let data = Data(html.utf8)
        XCTAssertEqual(try XCTUnwrap(NotePasteReader.read(data, type: .html)).images.count, 1, "rich reader can retain the actual embedded bytes")
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
        let (_, view) = engine.makeView(); defer { engine.detachView() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setData(data, forType: .html)
        view.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(view.readSelection(from: board, type: .html))
        XCTAssertEqual(engine.document().blocks.filter { $0.kind == .image }.count, 1)
        XCTAssertEqual(engine.stagedAttachments(for: engine.document()).map(\.data), [png])
    }

    func testMarkdownPasteKeepsTrailingEmptyParagraphFormatting() throws {
        for style: NoteParagraphStyle in [.body, .heading(2), .quote, .callout(icon: "💡"), .mono] {
            let source = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
            if style != .body { XCTAssertTrue(source.perform(.paragraph(style), selection: NSRange(location: 6, length: 0))) }
            let original = source.document()
            let markdown = NoteMarkdownExport.markdown(original)
            // Import itself must retain the format; distinguish the insertion route.
            XCTAssertEqual(canonical(try NoteMarkdownImport.document(markdown)).blocks.map(\.style), original.blocks.map(\.style))
            let target = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Target"), .text("")]))
            let (_, view) = target.makeView(); defer { target.detachView() }
            view.setSelectedRange(NSRange(location: 7, length: 0))
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.setString(markdown, forType: .string)
            XCTAssertTrue(target.handlePaste(board))
            XCTAssertEqual(target.document().blocks.last?.style, original.blocks.last?.style, "trailing \(style)")
            XCTAssertEqual(target.document().blocks.last?.level, original.blocks.last?.level, "trailing \(style)")
        }
    }


    /// Manual shrink of the generated delimiter failure: three letters,
    /// two overlapping commands through the real formatting route.
    func testMinimizedCrossingMarksFromFormatCommandsRoundTrip() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("abc")]))
        XCTAssertTrue(engine.perform(.mark(.bold), selection: NSRange(location: 6, length: 2)))
        XCTAssertTrue(engine.perform(.mark(.italic), selection: NSRange(location: 7, length: 2)))
        let original = try XCTUnwrap(engine.document().blocks.last)
        XCTAssertEqual(original.text, "abc")
        XCTAssertEqual(coverage(original), [Set(["bold"]), Set(["bold", "italic"]), Set(["italic"])])
        let read = try XCTUnwrap(roundTrip(engine.document()).blocks.last)
        XCTAssertEqual(read.text, "abc")
        XCTAssertEqual(coverage(read), coverage(original))
    }

    private struct MarkStep: CustomStringConvertible {
        let kind: NoteMark.Kind
        let start: Int
        let length: Int
        var description: String { "\(kind.rawValue)(\(start),\(length))" }
    }

    private func coverage(_ block: NoteBlock) -> [Set<String>] {
        var result = Array(repeating: Set<String>(), count: block.text.utf16.count)
        for mark in block.marks {
            for offset in mark.offset..<min(result.count, mark.offset + mark.length) { result[offset].insert(mark.kind.rawValue) }
        }
        return result
    }

    /// A separate character-by-character mark model, with real note visits
    /// between the edit, Undo and Redo. The existing H15 model covers the
    /// insert/delete/list/callout/code/table/move/paste command vocabulary.
    func testGeneratedInlineMarkVisitsAndMarkdownRoundTripWithShrinking() async throws {
        func fails(_ steps: [MarkStep]) throws -> Bool {
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("abcdef")]))
            for step in steps { _ = engine.perform(.mark(step.kind), selection: NSRange(location: 6 + step.start, length: step.length)) }
            let original = engine.document(), read = try roundTrip(original)
            guard let before = original.blocks.last, let after = read.blocks.last else { return true }
            return before.text != after.text || coverage(before) != coverage(after)
        }
        for seed in 0..<8 {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let ids = [UUID(), UUID()]
            for id in ids {
                guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Title"), .text("abcdef")])) else { return XCTFail("seed") }
            }
            let controller = NotesPageController(store: store,
                journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "H16-MarkVisits")),
                saveDelay: .seconds(600), pauseVersionDelay: .seconds(600))
            await controller.startAndWait()
            var engines: [NoteEditorEngine] = [], scrolls: [NSScrollView] = []
            for id in ids {
                guard await controller.openDurably(noteID: id) else { return XCTFail("open") }
                let engine = try XCTUnwrap(controller.active?.engine); engines.append(engine)
                scrolls.append(engine.makeView().0)
            }
            defer { engines.forEach { $0.detachView() }; withExtendedLifetime(scrolls) {} }
            var models = Array(repeating: Array(repeating: Set<String>(), count: 6), count: 2)
            var sequences = [[MarkStep](), [MarkStep]()]
            var rng = UInt64(seed) + 0x1616
            func next() -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int((rng >> 32) & 0x7fff_ffff) }
            for _ in 0..<12 {
                let note = next() % 2, peer = 1 - note, start = next() % 6
                let step = MarkStep(kind: next() % 2 == 0 ? .bold : .italic, start: start, length: 1 + next() % (6 - start))
                guard await controller.openDurably(noteID: ids[note]) else { return XCTFail("visit") }
                let engine = engines[note], before = try NoteContentCodec.encode(engine.document()), previous = models[note]
                let remove = (start..<start + step.length).allSatisfy { models[note][$0].contains(step.kind.rawValue) }
                for offset in start..<start + step.length {
                    if remove { models[note][offset].remove(step.kind.rawValue) } else { models[note][offset].insert(step.kind.rawValue) }
                }
                XCTAssertTrue(engine.perform(.mark(step.kind), selection: NSRange(location: 6 + start, length: step.length)))
                XCTAssertEqual(coverage(try XCTUnwrap(engine.document().blocks.last)), models[note])
                let after = try NoteContentCodec.encode(engine.document())
                guard await controller.openDurably(noteID: ids[peer]), await controller.openDurably(noteID: ids[note]) else { return XCTFail("undo visit") }
                XCTAssertTrue(engine.history.undo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before)
                XCTAssertEqual(coverage(try XCTUnwrap(engine.document().blocks.last)), previous)
                guard await controller.openDurably(noteID: ids[peer]), await controller.openDurably(noteID: ids[note]) else { return XCTFail("redo visit") }
                XCTAssertTrue(engine.history.redo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), after)
                XCTAssertEqual(coverage(try XCTUnwrap(engine.document().blocks.last)), models[note])
                XCTAssertEqual(coverage(try XCTUnwrap(engines[peer].document().blocks.last)), models[peer])
                sequences[note].append(step)
                if try fails(sequences[note]) {
                    var minimal = sequences[note], changed = true
                    while changed {
                        changed = false
                        for index in minimal.indices {
                            var candidate = minimal; candidate.remove(at: index)
                            if try fails(candidate) { minimal = candidate; changed = true; break }
                        }
                    }
                    return XCTFail("H16 inline serializer: seed=\(seed), note=\(note), deletion-minimal commands=\(minimal)")
                }
            }
        }
    }

}


/// These fixtures keep FG's default invisible policy; no key-window opt-in.
@MainActor
final class PhaseXHunt16GeometryTests: RoundF3TestCase {
    // Use the insertion-indicator segment type from RoundF3CaretTests.
    private func segment(_ text: NSTextView, at offset: Int) throws -> CGRect {
        let layout = try XCTUnwrap(text.textLayoutManager), content = try XCTUnwrap(layout.textContentManager)
        let start = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: offset))
        var rect: CGRect?
        layout.enumerateTextSegments(in: NSTextRange(location: start), type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in rect = frame; return false }
        return try XCTUnwrap(rect).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    }

    func testHeadlessNativeSegmentsMatchStockAndTypedBlankLineControls() throws {
        for width: CGFloat in [340, 420] {
            var mixed = NoteBlock.text("Body 👩🏽‍💻 e\u{301} inline\u{2028}\u{2028}after")
            mixed.marks = [NoteMark(.code, offset: 0, length: 4)]
            let (engine, text) = editor([.text("Title"), mixed, .text(""), .text("After")], width: width, height: 560)
            let native = NSTextView(usingTextLayoutManager: true)
            native.frame = text.frame; native.isRichText = false; native.isVerticallyResizable = true
            native.textContainerInset = text.textContainerInset; native.textContainer?.lineFragmentPadding = 0
            let copy = NSMutableAttributedString(attributedString: engine.textStorage)
            let originalString = text.string as NSString
            let blanks = (0..<originalString.length).filter { index in
                originalString.character(at: index) == 0x0A && (index == 0 || originalString.character(at: index - 1) == 0x0A)
            }
            // F3 deliberately moves spacing out of a blank line's caret.
            // Its oracle is the same line typed (RoundF3BlankLineTests),
            // rather than stock's unadjusted 18.5 pt empty-line selection.
            for offset in blanks.reversed() {
                copy.insert(NSAttributedString(string: "x", attributes: engine.textStorage.attributes(at: offset, effectiveRange: nil)), at: offset)
            }
            native.textStorage?.setAttributedString(copy)
            native.typingAttributes = text.typingAttributes
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 560)); scroll.documentView = native
            host(scroll, text: native, width: width, height: 560); settle(native)
            let string = text.string as NSString
            var offset = 0
            while offset < string.length {
                let stockOffset = offset + blanks.filter { $0 < offset }.count
                text.setSelectedRange(NSRange(location: offset, length: 0))
                native.setSelectedRange(NSRange(location: stockOffset, length: 0))
                native.typingAttributes = text.typingAttributes
                let ours = try segment(text, at: offset), stock = try segment(native, at: stockOffset)
                let a = try XCTUnwrap(NoteLineGeometry.line(at: ours, in: text))
                let b = try XCTUnwrap(NoteLineGeometry.line(at: stock, in: native))
                XCTAssertEqual(ours.minY - a.baseline, stock.minY - b.baseline, accuracy: 0.01, "width=\(width), offset=\(offset)")
                XCTAssertEqual(ours.height, stock.height, accuracy: 0.01, "width=\(width), offset=\(offset)")
                offset = NSMaxRange(string.rangeOfComposedCharacterSequence(at: offset))
            }
            XCTAssertFalse(text.window?.isVisible ?? true)
        }
    }

    private func drawnHintBaseline(_ hint: NSView) throws -> CGFloat {
        let bitmap = try XCTUnwrap(hint.bitmapImageRepForCachingDisplay(in: hint.bounds))
        hint.cacheDisplay(in: hint.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / hint.bounds.width
        var first: Int?
        for x in 0..<bitmap.pixelsWide where first == nil {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { first = x; break }
        }
        let start = try XCTUnwrap(first, "hint must actually draw")
        var bottom = 0
        for x in (start + Int(2 * scale))..<min(bitmap.pixelsWide, start + Int(ceil(4.6 * scale))) {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 { bottom = max(bottom, y) }
        }
        return hint.frame.minY + CGFloat(bottom + 1) / scale
    }

    func testHeadlessReopenedHintBaselineMatchesTypedText() throws {
        for preceding in [NoteBlock.text("Body"), callout("Callout"), code("let x = 1")] {
            let original = NoteDocument(blocks: [.text("Title"), preceding, .text("")])
            let bytes = try NoteContentCodec.encode(original)
            guard case let .editable(decoded) = NoteContentCodec.decode(bytes) else { return XCTFail("decode") }
            let (engine, text) = editor(decoded.blocks, height: 560)
            text.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            let format = NoteFormatControls(engine: engine, textView: text, scrollView: try XCTUnwrap(text.enclosingScrollView), design: AtticDesignContext(mode: .dark))
            controls.append(format); format.refresh(); settle(text)
            XCTAssertTrue(format.isHintVisible)
            let hint = try XCTUnwrap(descendants(text).compactMap { $0 as? NoteSlashHintLabel }.first { !$0.isHidden })
            let before = try drawnHintBaseline(hint)
            XCTAssertEqual(try NoteContentCodec.encode(engine.document()), bytes)
            text.insertText("x", replacementRange: text.selectedRange()); settle(text)
            let frame = try segment(text, at: engine.textStorage.length)
            let line = try XCTUnwrap(NoteLineGeometry.line(at: frame, in: text))
            XCTAssertEqual(before, NoteLineGeometry.drawnBaseline(line.baseline, in: text), accuracy: 0.01)
            XCTAssertFalse(text.window?.isVisible ?? true)
        }
    }
}
