import AppKit
import XCTest
@testable import Attic

/// O18-01 (a block at the note's end is never cut off) and O18-02 / K-01
/// (Return inside a box: the empty line is the box's last, with its padding
/// and rounded corners, and the first letter moves nothing).
@MainActor
final class RoundF3BoxTests: RoundF3TestCase {
    /// Everything painted as boxes and bars, unioned per kind, in the text
    /// view's coordinates; and whether the lowest slice ends the box.
    struct Painted { var box: CGRect?; var ends: Bool }
    func painted(_ e: NoteEditorEngine, _ text: NSTextView) -> Painted {
        var union: CGRect?
        var ends = false
        let origin = text.textContainerOrigin
        e.layoutManager?.enumerateTextLayoutFragments(from: e.contentStorage.documentRange.location, options: [.ensuresLayout]) { f in
            guard let f = f as? NoteBlockLayoutFragment else { return true }
            for r in [f.calloutBoxRect, f.monoBlockRect, f.quoteBar, f.lastLineBoxRect, f.lastLineQuoteBar].compactMap({ $0 }) {
                let a = r.offsetBy(dx: f.layoutFragmentFrame.minX + origin.x, dy: f.layoutFragmentFrame.minY + origin.y)
                union = union.map { $0.union(a) } ?? a
            }
            switch f.decoration {
            case let .callout(_, _, end, exits): ends = end || exits
            case let .mono(_, end, exits): ends = end || exits
            case let .quote(_, _, below): ends = !below
            default: break
            }
            return true
        }
        return Painted(box: union, ends: ends)
    }

    func box(_ kind: String, _ text: String) -> NoteBlock {
        switch kind {
        case "callout": callout(text)
        case "code": code(text, language: "swift")
        case "diagram": code(text, language: "mermaid")
        default: .text(text, style: "quote")
        }
    }

    func testReturnInsideABoxEndsTheBoxUnderTheEmptyLineAndTypingMovesNothing() throws {
        try requireKeyWindowTests()
        for kind in ["callout", "code", "diagram", "quote"] {
            let (e, text) = editor([.text("Title"), box(kind, "First py")], height: 160)
            text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
            text.insertNewline(nil); settle(text)
            let end = e.textStorage.length
            XCTAssertEqual(e.paragraphStyle(at: end), e.paragraphStyle(at: end - 2), "\(kind): Return continues the box")
            let empty = painted(e, text), emptyCaret = try caret(text)
            render(text, "f3-k01-\(kind)-return-empty")
            XCTAssertTrue(empty.ends, "\(kind): the empty line's slice ends the box (rounded, padded)")
            text.insertText("x", replacementRange: NSRange(location: end, length: 0)); settle(text)
            let typed = painted(e, text), typedCaret = try caret(text)
            render(text, "f3-k01-\(kind)-return-typed")
            let a = try XCTUnwrap(empty.box, kind), b = try XCTUnwrap(typed.box, kind)
            XCTAssertEqual(a.minY, b.minY, accuracy: 0.01, "\(kind): box top")
            XCTAssertEqual(a.maxY, b.maxY, accuracy: 0.01, "\(kind): the box does not grow on the first letter")
            XCTAssertEqual(emptyCaret.baseline, typedCaret.baseline, accuracy: 0.01, "\(kind): the line does not move")
            XCTAssertEqual(emptyCaret.frame.height, typedCaret.frame.height, accuracy: 0.01, "\(kind): same native caret")
            if kind != "quote" {
                // The caret is inside the box, with the box's padding under it.
                XCTAssertLessThan(emptyCaret.frame.maxY, a.maxY - 4, "\(kind): the caret sits inside the box")
            }
            XCTAssertLessThanOrEqual(a.maxY, text.bounds.maxY + 0.5, "\(kind): the box is inside the document")
            // Deleting the letter returns exactly to the empty line's box.
            text.deleteBackward(nil); settle(text)
            let deleted = painted(e, text)
            XCTAssertEqual(try XCTUnwrap(deleted.box).maxY, a.maxY, accuracy: 0.01, "\(kind): deleting the letter keeps the box")
            XCTAssertEqual(try caret(text).baseline, emptyCaret.baseline, accuracy: 0.01, "\(kind): and the line")
            // Undo and Redo of the Return keep the geometry consistent.
            text.undoManager?.undo(); settle(text)
            text.undoManager?.redo(); settle(text)
            if e.textStorage.length == end {
                XCTAssertEqual(try XCTUnwrap(painted(e, text).box).maxY, a.maxY, accuracy: 0.01, "\(kind): Undo/Redo")
            }
        }
    }

    /// O18-01: whatever ends the note, its painted bottom is inside the
    /// document, so it scrolls fully into view.
    func testABlockEndingTheNoteIsInsideTheDocument() throws {
        try requireKeyWindowTests()
        let image = NoteBlock.image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400)
        let cases: [(String, [NoteBlock])] = [
            ("callout", [.text("Wet"), callout("Callout py")]),
            ("code", [.text("Wet"), code("let x = 1")]),
            ("diagram", [.text("Wet"), code("graph TD", language: "mermaid")]),
            ("quote", [.text("Wet"), .text("Quote py", style: "quote")]),
            ("table", [.text("Wet"), .table(NoteTable(texts: [["A", "B"], ["c", "d"]]))]),
            ("image", [.text("Wet"), image]),
            ("callout-empty-line", [.text("Wet"), callout("Callout py"), .text("")]),
        ]
        for (name, blocks) in cases {
            let (e, text) = editor(blocks, height: 50)
            text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0)); settle(text)
            let bottom = try XCTUnwrap(e.trailingBlockBottom(), name) + text.textContainerOrigin.y
            let box = painted(e, text).box
            XCTAssertLessThanOrEqual(bottom, text.bounds.maxY + 0.5, "\(name): the block's fragment fits")
            if let box { XCTAssertLessThanOrEqual(box.maxY, text.bounds.maxY + 0.5, "\(name): its painted box fits") }
            // Scrolled fully down, the whole block shows.
            text.scrollToEndOfDocument(nil); settle(text)
            let visible = text.visibleRect
            if let box { XCTAssertLessThanOrEqual(box.maxY, visible.maxY + 0.5, "\(name): scrolls fully into view") }
            render(text.enclosingScrollView!, "f3-o1801-\(name)-scrolled")
        }
        // An empty callout picked on the last line.
        let (e, text) = editor([.text("Wet"), .text("")], height: 50)
        text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
        XCTAssertTrue(e.perform(.paragraph(.callout(icon: "💡")))); settle(text)
        let picked = try XCTUnwrap(painted(e, text).box)
        XCTAssertLessThanOrEqual(picked.maxY, text.bounds.maxY + 0.5, "picked callout fits")
    }
}
