import AppKit
import XCTest
@testable import Attic

/// Round O3, the owner's 10-17 Notes items: a block format picked on an
/// empty line shows at once (O17-07), and a click below the last block
/// starts a new line there (O17-08).
@MainActor
final class RoundO3NotesTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var engines: [NoteEditorEngine] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        engines = []
        try await super.tearDown()
    }

    private func editor(_ blocks: [NoteBlock], width: CGFloat = 320) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks))
        engines.append(engine)
        let (scroll, text) = engine.makeView()
        scroll.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        text.textContainerInset = CGSize(width: 24, height: 8)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(text)
        window.contentView?.layoutSubtreeIfNeeded()
        windows.append(window)
        return (engine, text)
    }

    private func settle(_ engine: NoteEditorEngine, _ text: NSTextView) {
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        text.layoutSubtreeIfNeeded()
    }

    private func lastFragment(_ engine: NoteEditorEngine) -> NSTextLayoutFragment? {
        var last: NSTextLayoutFragment?
        engine.layoutManager?.enumerateTextLayoutFragments(from: engine.contentStorage.documentRange.location,
                                                           options: [.ensuresLayout]) { fragment in
            last = fragment
            return true
        }
        return last
    }

    private func fragment(_ engine: NoteEditorEngine, at offset: Int) -> NoteBlockLayoutFragment? {
        guard let location = engine.contentStorage.location(engine.contentStorage.documentRange.location, offsetBy: offset) else { return nil }
        engine.layoutManager?.ensureLayout(for: NSTextRange(location: location))
        return engine.layoutManager?.textLayoutFragment(for: location) as? NoteBlockLayoutFragment
    }

    private func absolute(_ rect: CGRect?, _ fragment: NSTextLayoutFragment) -> CGRect? {
        rect?.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
    }

    private struct Format {
        let name: String
        let style: NoteParagraphStyle
        let block: (String) -> NoteBlock
    }

    private static let formats: [Format] = [
        Format(name: "quote", style: .quote) { .text($0, style: "quote") },
        Format(name: "bullet", style: .bullet) { .text($0, style: "bullet") },
        Format(name: "number", style: .number) { .text($0, style: "number") },
        Format(name: "callout", style: .callout(icon: "💡")) { var b = NoteBlock.text($0, style: "quote"); b.callout = "💡"; return b },
        Format(name: "code", style: .mono) { .text($0, style: "mono") },
        Format(name: "title", style: .heading(1)) { var b = NoteBlock.text($0, style: "heading"); b.level = 1; return b },
        Format(name: "heading", style: .heading(2)) { var b = NoteBlock.text($0, style: "heading"); b.level = 2; return b },
    ]

    private func assertClose(_ a: CGRect?, _ b: CGRect?, _ message: String, accuracy: CGFloat = 0.5,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let a, let b else { return XCTFail("\(message): missing \(String(describing: a)) / \(String(describing: b))", file: file, line: line) }
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, "\(message) x", file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, "\(message) y", file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, "\(message) width", file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, "\(message) height", file: file, line: line)
    }

    /// The decoration a paragraph draws, in the text container's space.
    private func drawn(_ fragment: NoteBlockLayoutFragment) -> CGRect? {
        absolute(fragment.quoteBar ?? fragment.calloutBoxRect ?? fragment.monoBlockRect, fragment)
    }

    private func drawnOnEmptyLine(_ fragment: NoteBlockLayoutFragment) -> CGRect? {
        absolute(fragment.lastLineQuoteBar ?? fragment.lastLineBoxRect, fragment)
    }

    // MARK: O17-07

    /// Every block format picked on the note's empty last line shows at
    /// once, exactly where the first letter puts it: the caret, the bar,
    /// marker or box, and a heading's size. Typing then continues it.
    func testAFormatPickedOnTheEmptyLastLineShowsWhereTheFirstLetterWillBe() throws {
        for format in Self.formats {
            let (engine, text) = editor([.text("Title"), .text("Alpha"), .text("")])
            let (reference, referenceText) = editor([.text("Title"), .text("Alpha"), format.block("x")])
            let end = engine.textStorage.length
            text.setSelectedRange(NSRange(location: end, length: 0))
            XCTAssertTrue(engine.perform(.paragraph(format.style)), format.name)
            settle(engine, text)
            settle(reference, referenceText)
            let letter = reference.textStorage.length - 1
            let caret = try XCTUnwrap(engine.caretRect(at: end))
            let expected = try XCTUnwrap(reference.caretRect(at: letter))
            XCTAssertEqual(caret.minX, expected.minX, accuracy: 0.5, "\(format.name): caret x")
            XCTAssertEqual(caret.minY, expected.minY, accuracy: 0.5, "\(format.name): caret y")
            XCTAssertEqual(caret.height, expected.height, accuracy: 0.5, "\(format.name): caret height")
            let isHeading = format.style == .heading(1) || format.style == .heading(2)
            if isHeading {
                XCTAssertNil((lastFragment(engine) as? NoteBlockLayoutFragment)?.lastLine, "\(format.name): a heading's size is the line's own")
            }
            let picked = try XCTUnwrap(isHeading ? NoteBlockLayoutFragment(textElement: NSTextParagraph(attributedString: .init()), range: nil)
                                                 : lastFragment(engine) as? NoteBlockLayoutFragment, "\(format.name): drawn by Attic")
            let typedFragment = try XCTUnwrap(isHeading ? picked : fragment(reference, at: letter), format.name)
            switch format.style {
            case .quote, .callout, .mono:
                assertClose(drawnOnEmptyLine(picked), drawn(typedFragment), "\(format.name): its bar or box")
            case .bullet, .number:
                guard case let .marker(marker, x) = typedFragment.decoration else { return XCTFail("\(format.name): reference marker") }
                XCTAssertEqual(picked.lastLine, .marker(marker, x: x), "\(format.name): its marker")
            default:
                XCTAssertNil(picked.lastLine, "\(format.name): a heading's size is the line's own")
            }
            if case .callout = format.style {
                XCTAssertEqual(picked.lastLine, .callout(icon: "💡"))
            }
            if case .mono = format.style {
                XCTAssertEqual(picked.lastLine, .mono(label: NoteCodeLanguageName.label(for: nil)))
            }
            // Typing continues the format, with nothing moving.
            text.insertText("x", replacementRange: text.selectedRange())
            settle(engine, text)
            XCTAssertEqual(engine.document().blocks.map(\.style), reference.document().blocks.map(\.style), format.name)
            XCTAssertEqual(engine.document().blocks.map(\.text), ["Title", "Alpha", "x"], format.name)
            assertClose(engine.caretRect(at: engine.textStorage.length), reference.caretRect(at: reference.textStorage.length),
                        "\(format.name): the caret after the letter")
            assertClose(engine.caretRect(at: letter), expected, "\(format.name): the letter's place")
            assertClose(engine.caretRect(at: 7), reference.caretRect(at: 7), "\(format.name): the line above stays")
            if !isHeading {
                let typed = try XCTUnwrap(fragment(engine, at: letter), format.name)
                XCTAssertNil(typed.lastLine, "\(format.name): the empty line is gone")
                XCTAssertEqual(typed.decoration, typedFragment.decoration, format.name)
            }
            XCTAssertNil((fragment(engine, at: 6))?.lastLine, "\(format.name): the line above no longer draws it")
        }
    }

    /// The note's title line, then Return and a format (a new note).
    func testAFormatPickedBelowTheTitleShowsAtOnce() throws {
        let (engine, text) = editor([.text("Title"), .text("")])
        text.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        XCTAssertTrue(engine.perform(.paragraph(.quote)))
        settle(engine, text)
        let fragment = try XCTUnwrap(lastFragment(engine) as? NoteBlockLayoutFragment)
        XCTAssertEqual(fragment.lastLine, .quote(x: 0, joinsAbove: false))
        XCTAssertNotNil(fragment.lastLineQuoteBar)
    }

    /// Return at the end of a quote, callout or code block continues it
    /// on an empty line that already shows the bar or box.
    func testAnEmptyLineThatContinuesABlockShowsItsBarOrBox() throws {
        let (engine, text) = editor([.text("Title"), .text("Alpha", style: "quote"), .text("")])
        text.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        XCTAssertTrue(engine.perform(.paragraph(.quote)))
        settle(engine, text)
        let fragment = try XCTUnwrap(lastFragment(engine) as? NoteBlockLayoutFragment)
        XCTAssertEqual(fragment.lastLine, .quote(x: 0, joinsAbove: true))
        let joined = try XCTUnwrap(fragment.lastLineQuoteBar)
        XCTAssertEqual(joined.minY, try XCTUnwrap(fragment.quoteBar).minY, accuracy: 0.01, "one bar through both lines")
    }

    /// Leaving the empty line keeps its format, on screen too, even when
    /// TextKit lays the line out again while the caret is elsewhere.
    func testLeavingTheEmptyLineKeepsItsFormat() throws {
        for format in Self.formats {
            let (engine, text) = editor([.text("Title"), .text("Alpha"), .text("")])
            let end = engine.textStorage.length
            text.setSelectedRange(NSRange(location: end, length: 0))
            XCTAssertTrue(engine.perform(.paragraph(format.style)))
            settle(engine, text)
            let caret = try XCTUnwrap(engine.caretRect(at: end))
            let picked = (lastFragment(engine) as? NoteBlockLayoutFragment)?.lastLine
            text.setSelectedRange(NSRange(location: 8, length: 0))
            engine.invalidateLayout(NSRange(location: 0, length: end))
            (text.enclosingScrollView?.frame).map { text.enclosingScrollView?.frame.size.width = $0.width - 10 }
            settle(engine, text)
            let away = try XCTUnwrap(engine.caretRect(at: end))
            XCTAssertEqual(away.minY, caret.minY, accuracy: 0.5, "\(format.name): the line keeps its place")
            XCTAssertEqual(away.height, caret.height, accuracy: 0.5, "\(format.name): and its size")
            XCTAssertEqual((lastFragment(engine) as? NoteBlockLayoutFragment)?.lastLine, picked, format.name)
            XCTAssertEqual(engine.document().blocks.last?.style, format.block("").style, format.name)
            text.setSelectedRange(NSRange(location: end, length: 0))
            settle(engine, text)
            assertClose(engine.caretRect(at: end).map { CGRect(x: $0.minX, y: $0.minY, width: 0, height: $0.height) },
                        CGRect(x: caret.minX, y: caret.minY, width: 0, height: caret.height), "\(format.name): back on the line")
        }
    }

    /// Undo takes the format off in one step; Redo puts it back.
    func testUndoRemovesThePickedFormatInOneStep() throws {
        let (engine, text) = editor([.text("Title"), .text("Alpha"), .text("")])
        let end = engine.textStorage.length
        text.setSelectedRange(NSRange(location: end, length: 0))
        settle(engine, text)
        let before = try XCTUnwrap(engine.caretRect(at: end))
        XCTAssertTrue(engine.perform(.paragraph(.callout(icon: "💡"))))
        settle(engine, text)
        XCTAssertNotNil((lastFragment(engine) as? NoteBlockLayoutFragment)?.lastLine)
        let undo = try XCTUnwrap(text.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        settle(engine, text)
        XCTAssertNil(engine.document().blocks.last?.style)
        XCTAssertNil((lastFragment(engine) as? NoteBlockLayoutFragment)?.lastLine)
        assertClose(engine.caretRect(at: end), before, "the line is Body again")
        undo.redo()
        settle(engine, text)
        XCTAssertEqual(engine.document().blocks.last?.callout, "💡")
        XCTAssertEqual((lastFragment(engine) as? NoteBlockLayoutFragment)?.lastLine, .callout(icon: "💡"))
    }

    /// The slash menu takes the same route.
    func testTheSlashMenuShowsTheFormatAtOnce() throws {
        let (engine, text) = editor([.text("Title"), .text("Alpha"), .text("")])
        text.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        text.insertText("/", replacementRange: text.selectedRange())
        text.insertText("quo", replacementRange: text.selectedRange())
        XCTAssertNotNil(engine.slashSession)
        XCTAssertTrue(engine.acceptSlashItem(.quote))
        settle(engine, text)
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Title", "Alpha", ""])
        XCTAssertEqual((lastFragment(engine) as? NoteBlockLayoutFragment)?.lastLine, .quote(x: 0, joinsAbove: false))
    }

    /// An empty line inside the note already carries its format on its
    /// separator: it draws as soon as it is picked.
    func testAnEmptyLineInsideTheNoteShowsItsFormatAtOnce() throws {
        for format in Self.formats where format.style != .heading(1) && format.style != .heading(2) {
            let (engine, text) = editor([.text("Title"), .text("Alpha"), .text(""), .text("Beta")])
            let empty = (engine.textStorage.string as NSString).range(of: "Alpha").location + 6
            text.setSelectedRange(NSRange(location: empty, length: 0))
            XCTAssertTrue(engine.perform(.paragraph(format.style)), format.name)
            settle(engine, text)
            let fragment = try XCTUnwrap(fragment(engine, at: empty), "\(format.name): drawn by Attic")
            switch format.style {
            case .quote: XCTAssertNotNil(fragment.quoteBar, format.name)
            case .callout: XCTAssertNotNil(fragment.calloutBoxRect, format.name)
            case .mono: XCTAssertNotNil(fragment.monoBlockRect, format.name)
            default:
                guard case .marker = fragment.decoration else { return XCTFail(format.name) }
            }
        }
    }

    /// An empty formatted last line saves and opens as the same note, and
    /// an untouched note saves byte for byte as it was read.
    func testAnEmptyFormattedLastLineRoundTrips() throws {
        for format in Self.formats {
            let (engine, text) = editor([.text("Title"), .text("Alpha"), .text("")])
            text.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            XCTAssertTrue(engine.perform(.paragraph(format.style)))
            let saved = engine.document()
            XCTAssertEqual(saved.blocks.last?.style, format.block("").style, format.name)
            XCTAssertEqual(saved.blocks.last?.text, "", format.name)
            let data = try NoteContentCodec.encode(saved)
            let read = try XCTUnwrap(NoteContentCodec.decode(data).document, format.name)
            XCTAssertEqual(read.blocks.map(\.style), saved.blocks.map(\.style), format.name)
            let (reopened, reopenedText) = editor(read.blocks)
            XCTAssertEqual(try NoteContentCodec.encode(reopened.document()), data, "\(format.name): untouched, same bytes")
            settle(reopened, reopenedText)
            if format.style != .heading(1), format.style != .heading(2) {
                XCTAssertNotNil((lastFragment(reopened) as? NoteBlockLayoutFragment)?.lastLine, "\(format.name): shown when opened")
            }
        }
    }

    // MARK: O17-08

    private func event(_ type: NSEvent.EventType, point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber,
                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    /// A click in the empty space below the note's last block, through the
    /// real pointer route (the page's marquee takes blank-space presses).
    private func clickBelow(_ engine: NoteEditorEngine, _ text: NoteEditorTextView) throws {
        settle(engine, text)
        let controller = try XCTUnwrap(text.marquee?.controller)
        let point = CGPoint(x: 120, y: text.finalTextBottom() + 40)
        XCTAssertLessThan(point.y, text.visibleRect.maxY, "the click is on the page")
        _ = controller.handle(event(.leftMouseDown, point: point, in: text))
        _ = controller.handle(event(.leftMouseUp, point: point, in: text))
        settle(engine, text)
    }

    func testAClickBelowABodyParagraphStartsANewLineThere() throws {
        let (engine, text) = editor([.text("Title"), .text("Alpha")])
        let length = engine.textStorage.length
        try clickBelow(engine, text)
        XCTAssertEqual(engine.textStorage.string, "Title\nAlpha\n")
        XCTAssertEqual(text.selectedRange(), NSRange(location: length + 1, length: 0))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Title", "Alpha", ""])
        // A different format can start right there.
        XCTAssertTrue(engine.perform(.paragraph(.quote)))
        XCTAssertEqual(engine.document().blocks.map(\.style), [nil, nil, "quote"])
        // One Undo step each.
        let undo = try XCTUnwrap(text.undoManager)
        undo.undo()
        undo.undo()
        XCTAssertEqual(engine.textStorage.string, "Title\nAlpha")
    }

    func testAClickBelowAnEmptyBodyLineOnlyFocusesIt() throws {
        let (engine, text) = editor([.text("Title"), .text("Alpha"), .text("")])
        text.setSelectedRange(NSRange(location: 2, length: 0))
        try clickBelow(engine, text)
        XCTAssertEqual(engine.textStorage.string, "Title\nAlpha\n", "no stacked empty lines")
        XCTAssertEqual(text.selectedRange(), NSRange(location: engine.textStorage.length, length: 0))
        try clickBelow(engine, text)
        XCTAssertEqual(engine.textStorage.string, "Title\nAlpha\n")
    }

    func testAClickBelowAListQuoteCodeOrCalloutStartsBody() throws {
        for format in Self.formats {
            let (engine, text) = editor([.text("Title"), format.block("Alpha")])
            try clickBelow(engine, text)
            let blocks = engine.document().blocks
            XCTAssertEqual(blocks.map(\.text), ["Title", "Alpha", ""], format.name)
            XCTAssertNil(blocks.last?.style, "\(format.name): a plain Body line, not another item")
            XCTAssertEqual(blocks[1].style, format.block("").style, format.name)
            XCTAssertEqual(text.selectedRange(), NSRange(location: engine.textStorage.length, length: 0), format.name)
            text.undoManager?.undo()
            XCTAssertEqual(engine.document().blocks.map(\.text), ["Title", "Alpha"], "\(format.name): one Undo step")
        }
    }

    func testAClickBelowAnEmptyFormattedLineKeepsItAndStartsBody() throws {
        let (engine, text) = editor([.text("Title"), .text("Alpha"), .text("")])
        text.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        XCTAssertTrue(engine.perform(.paragraph(.quote)))
        try clickBelow(engine, text)
        XCTAssertEqual(engine.document().blocks.map(\.style), [nil, nil, "quote", nil])
        XCTAssertEqual(text.selectedRange(), NSRange(location: engine.textStorage.length, length: 0))
    }

    func testAClickBelowATitleOnlyNoteStartsTheFirstLine() throws {
        let (engine, text) = editor([.text("Title")])
        try clickBelow(engine, text)
        XCTAssertEqual(engine.textStorage.string, "Title\n")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 6, length: 0))
    }

    /// A click beside the text (in the column's margins) is unchanged.
    func testAClickBesideTheTextAddsNothing() throws {
        let (engine, text) = editor([.text("Title"), .text("Alpha"), .text("Beta")])
        settle(engine, text)
        let controller = try XCTUnwrap(text.marquee?.controller)
        let alpha = try XCTUnwrap(engine.caretRect(at: 8))
        let point = CGPoint(x: 4, y: alpha.midY)
        _ = controller.handle(event(.leftMouseDown, point: point, in: text))
        _ = controller.handle(event(.leftMouseUp, point: point, in: text))
        XCTAssertEqual(engine.textStorage.string, "Title\nAlpha\nBeta")
    }
}
