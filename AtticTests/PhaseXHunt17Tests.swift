import AppKit
import XCTest
@testable import Attic

/// Find-only hunt on 5acbf65b. Owned documents and private pasteboards only.
@MainActor
final class PhaseXHunt17Tests: XCTestCase {
    private func canonical(_ document: NoteDocument) -> NoteDocument {
        NoteEditorEngine(noteID: UUID(), document: document).document()
    }

    private func pasted(_ document: NoteDocument) throws -> NoteDocument {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Target"), .text("")]))
        let (scroll, view) = engine.makeView()
        defer { engine.detachView(); withExtendedLifetime((scroll, view)) {} }
        let markdown = NoteMarkdownExport.markdown(document)
        XCTAssertTrue(engine.pasteMarkdown(markdown, at: NSRange(location: 7, length: 0)))
        var read = engine.document()
        read.blocks.removeFirst()
        read.blocks[0].style = nil; read.blocks[0].level = nil
        return read
    }

    func testLiteralBodySyntaxMatrixSurvivesMarkdown() throws {
        for text in ["www.example.com", "person@example.com", "a|b", "1) prose", "0. prose", "0001. prose",
                     "a\u{2028}b", "a\u{2028}\u{2028}b", "\u{00a0}a\u{00a0}", "a  b", "a\tb",
                     "<https://example.com>", "![alt](x)", "[^1]", "atticTableEnd"] {
            let source = canonical(NoteDocument(blocks: [.text("Title"), .text(text), .text("After")]))
            let read = try pasted(source)
            XCTAssertEqual(read.blocks.map(\.text), source.blocks.map(\.text), text.debugDescription)
            XCTAssertEqual(read.blocks.map(\.style), source.blocks.map(\.style), text.debugDescription)
            XCTAssertEqual(read.blocks.map(\.marks), source.blocks.map(\.marks), text.debugDescription)
        }
    }

    func testLinkDestinationMatrixSurvivesMarkdown() throws {
        for url in ["https://example.com/a_(b)?x=1&y=2", "https://example.com/a%20b", "mailto:person@example.com",
                    "https://example.com/a\"b", "https://example.com/é", "https://example.com/a b", "https://example.com/a'b",
                    "https://example.com/a#fragment", "https://example.com/a[b]", "https://example.com/a\\b"] {
            var block = NoteBlock.text("link")
            block.marks = [NoteMark(.link, offset: 0, length: 4, url: url)]
            let source = canonical(NoteDocument(blocks: [.text("Title"), block]))
            let read = try pasted(source)
            XCTAssertEqual(read.blocks.map(\.text), source.blocks.map(\.text), url)
            // URL's equivalent percent encoding is not a user-visible change.
            XCTAssertEqual(read.blocks.flatMap(\.marks).compactMap { $0.url.flatMap(URL.init(string:)) },
                           source.blocks.flatMap(\.marks).compactMap { $0.url.flatMap(URL.init(string:)) }, url)
        }
    }

    func testNestedFencedCodeKeepsLiteralExtensionSpellings() throws {
        for (name, markdown) in [
            ("list fence", "- item\n\n  ```html\n  <u>x</u>\n  ```"),
            ("indented list fence", "- item\n\n    ```html\n    <u>x</u>\n    ```"),
            ("inline list fence", "- ```html\n  <u>x</u>\n  ```"),
            ("quoted fence", "> ```html\n> <u>x</u>\n> ```"),
            ("list numeric", "- ```html\n  &#65;\n  ```"),
            ("list break", "- ```html\n  <br>\n  ```")
        ] {
            let native = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full))
            let literal = String(native.characters).trimmingCharacters(in: .newlines)
            let read = try NoteMarkdownImport.document(markdown)
            let importedText = read.blocks.map(\.text).joined(separator: "\n")
            let expected = name == "list numeric" ? "&#65;" : (name == "list break" ? "<br>" : "<u>x</u>")
            XCTAssertTrue(literal.contains(expected), "Foundation control: \(name) \(literal)")
            // Attic cannot represent compound list+code/quote+code styles.
            // Literal code content must survive even when containers flatten.
            XCTAssertTrue(importedText.contains(expected), "\(name): \(importedText.debugDescription)")
        }
    }

    func testSoftBreakThroughEveryInlineMarkSurvivesMarkdown() throws {
        for kind in NoteMark.Kind.allCases {
            for text in ["a\u{2028}b", "a\u{2028}\u{2028}b", "\u{2028}a", "a\u{2028}"] {
                var block = NoteBlock.text(text)
                block.marks = [NoteMark(kind, offset: 0, length: text.utf16.count,
                                       url: kind == .link ? "https://example.com" : nil)]
                let source = canonical(NoteDocument(blocks: [.text("Title"), block]))
                let read = try pasted(source)
                XCTAssertEqual(read.blocks.map(\.text), source.blocks.map(\.text), "\(kind) \(text.debugDescription)")
                XCTAssertEqual(read.blocks.map(\.marks), source.blocks.map(\.marks), "\(kind) \(text.debugDescription)")
            }
        }
    }

    func testH17_01NestedCodePasteDoesNotDeleteLiteralTagsOrEntities() throws {
        // Minimal fenced list item, valid CommonMark. Compare with the native
        // parser, then use the actual plain-paste dispatch into a note body.
        for literal in ["<u>x</u>", "&#65;", "<br>", "|a|b|\n|---|---|\n|c|d|"] {
            let markdown = "- ```html\n  " + literal.replacingOccurrences(of: "\n", with: "\n  ") + "\n  ```"
            let native = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full))
            XCTAssertEqual(String(native.characters).trimmingCharacters(in: .newlines), literal)
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
            let (scroll, view) = engine.makeView()
            defer { engine.detachView(); withExtendedLifetime((scroll, view)) {} }
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.setString(markdown, forType: .string)
            view.setSelectedRange(NSRange(location: 6, length: 0))
            let before = try NoteContentCodec.encode(engine.document())
            XCTAssertTrue(engine.handlePaste(board))
            XCTAssertEqual(engine.document().blocks.dropFirst().map(\.text).joined(separator: "\n"), literal, literal)
            let actual = try NoteContentCodec.encode(engine.document())
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before)
            XCTAssertTrue(engine.history.redo())
            XCTAssertEqual(try NoteContentCodec.encode(engine.document()), actual)
        }
    }

    func testH17_02TwoInteriorShiftReturnsRemainTwoAfterMarkdownPaste() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("a")]))
        let (scroll, view) = engine.makeView()
        defer { engine.detachView(); withExtendedLifetime((scroll, view)) {} }
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.insertLineBreak(nil); view.insertLineBreak(nil)
        view.insertText("b", replacementRange: view.selectedRange())
        let source = engine.document()
        XCTAssertEqual(source.blocks.last?.text, "a\u{2028}\u{2028}b")
        let bytes = try NoteContentCodec.encode(source)
        guard case let .editable(decoded) = NoteContentCodec.decode(bytes) else { return XCTFail("decode") }
        XCTAssertEqual(try NoteContentCodec.encode(canonical(decoded)), bytes, "save/reopen control")
        let read = try pasted(source)
        XCTAssertEqual(read.blocks.last?.text, "a\u{2028}\u{2028}b")
        print("H17_02 markdown=\(NoteMarkdownExport.markdown(source).debugDescription)")
    }

    func testH17_04MarkdownTableCellsSurviveSurroundingBacktickProse() throws {
        for markdown in ["`before\n|X|\n|-|\n`", "`before\n|a|b|\n|---|---|\n|c|d|\nafter`"] {
            let native = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full))
            // CommonMark's table interrupts the paragraph; these backticks
            // are unmatched prose delimiters, not a multiline code span.
            XCTAssertTrue(native.runs.contains { run in
                run.presentationIntent?.components.contains(where: {
                    if case .tableCell = $0.kind { true } else { false }
                }) == true
            }, "independent CommonMark table control")
            let cells = markdown.contains("|X|") ? [["X"]] : [["a", "b"], ["c", "d"]]
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
            let (scroll, view) = engine.makeView()
            defer { engine.detachView(); withExtendedLifetime((scroll, view)) {} }
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.setString(markdown, forType: .string)
            view.setSelectedRange(NSRange(location: 6, length: 0))
            XCTAssertTrue(engine.handlePaste(board))
            XCTAssertEqual(engine.document().blocks.compactMap(\.table).map(\.texts), [cells],
                           "Every cell must survive the structural preprocessing")
            XCTAssertFalse(engine.plainText.contains("atticTable"), "Parse-only atoms must never reach saved text")
        }
    }

    func testH17_03UnlinkedAddressesStayUnlinkedAfterCopyAsMarkdown() throws {
        for text in ["www.a.co", "a@b.co"] {
            let source = canonical(NoteDocument(blocks: [.text("Title"), .text(text)]))
            XCTAssertTrue(source.blocks.last!.marks.isEmpty)
            let read = try pasted(source)
            XCTAssertEqual(read.blocks.last?.text, text)
            XCTAssertEqual(read.blocks.last?.marks, [], "Literal text must not acquire a clickable link")
        }
    }

    /// A live text-only reference model extends the earlier command generator
    /// with random soft breaks, arbitrary in-paragraph positions, and actual
    /// view detachment/recreation at every note visit. No parser or codec is
    /// used to calculate the expected text or the expected Undo/Redo state.
    func testGeneratedSoftBreakEditsAcrossRemountedNoteVisits() async throws {
        for seed in 0..<8 {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let ids = [UUID(), UUID()]
            for id in ids {
                guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Title"), .text("ab")])) else { return XCTFail("seed") }
            }
            let controller = NotesPageController(store: store,
                journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "H17-Visits")),
                saveDelay: .seconds(600), pauseVersionDelay: .seconds(600))
            await controller.startAndWait()
            var expected = ["ab", "ab"]
            var random = UInt64(seed) + 0x1717
            func next(_ count: Int) -> Int {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                return Int(random >> 33) % count
            }
            for step in 0..<64 {
                let note = next(2), peer = 1 - note
                guard await controller.openDurably(noteID: ids[note]) else { return XCTFail("open") }
                let engine = try XCTUnwrap(controller.active?.engine)
                let (scroll, view) = engine.makeView()
                let at = next(expected[note].utf16.count + 1)
                let beforeText = expected[note]
                let beforeBytes = try NoteContentCodec.encode(engine.document())
                let selection = NSRange(location: 6 + at, length: 0)
                view.setSelectedRange(selection)
                if next(3) == 0, at < expected[note].utf16.count {
                    expected[note] = (expected[note] as NSString).replacingCharacters(in: NSRange(location: at, length: 1), with: "")
                    XCTAssertTrue(engine.performEdit(NSRange(location: 6 + at, length: 1), with: NSAttributedString(), name: "Delete"))
                } else {
                    let text = ["x", "y", "\u{2028}"][next(3)]
                    expected[note] = (expected[note] as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: text)
                    view.insertText(text, replacementRange: selection)
                }
                let label = "seed=\(seed) step=\(step) note=\(note)"
                XCTAssertEqual(engine.document().blocks.last?.text, expected[note], label)
                let afterBytes = try NoteContentCodec.encode(engine.document())
                let afterSelection = view.selectedRange()
                engine.detachView()
                guard await controller.openDurably(noteID: ids[peer]),
                      await controller.openDurably(noteID: ids[note]) else { return XCTFail("switch") }
                let (remountedScroll, remounted) = engine.makeView()
                XCTAssertEqual(try NoteContentCodec.encode(engine.document()), afterBytes, label + " remount")
                XCTAssertTrue(engine.history.undo(), label)
                XCTAssertEqual(engine.document().blocks.last?.text, beforeText, label + " Undo text")
                XCTAssertEqual(try NoteContentCodec.encode(engine.document()), beforeBytes, label + " Undo bytes")
                // A deletion selects the removed character when replayed;
                // compare bytes and the independently known insertion caret.
                if expected[note].utf16.count > beforeText.utf16.count {
                    XCTAssertEqual(remounted.selectedRange(), selection, label + " Undo selection")
                }
                XCTAssertTrue(engine.history.redo(), label)
                XCTAssertEqual(try NoteContentCodec.encode(engine.document()), afterBytes, label + " Redo")
                XCTAssertEqual(remounted.selectedRange(), afterSelection, label + " Redo selection")
                engine.detachView()
                withExtendedLifetime((scroll, view, remountedScroll, remounted)) {}
            }
            _ = await controller.prepareToLeaveDurably(.quit)
        }
        print("H17_GENERATED remounted note visits: 8 seeds x 64 operations = 512")
    }
}
