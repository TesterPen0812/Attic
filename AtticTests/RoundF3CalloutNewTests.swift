import AppKit
import XCTest
@testable import Attic

/// OD callout-new (owner, 2026-10-17): picking Callout on a line outside a
/// callout makes a separate box, even under (or above) a callout with the
/// same icon, also after reopening; Return inside a callout continues it.
@MainActor
final class RoundF3CalloutNewTests: RoundF3TestCase {
    func boxes(_ e: NoteEditorEngine) -> [NoteBlockLayoutFragment.Decoration] {
        var result: [NoteBlockLayoutFragment.Decoration] = []
        e.layoutManager?.enumerateTextLayoutFragments(from: e.contentStorage.documentRange.location, options: [.ensuresLayout]) { f in
            if let f = f as? NoteBlockLayoutFragment, case .callout = f.decoration { result.append(f.decoration) }
            return true
        }
        return result
    }
    func starts(_ e: NoteEditorEngine) -> Int {
        boxes(e).filter { if case let .callout(_, starts, _, _) = $0 { starts } else { false } }.count
    }
    func reopen(_ e: NoteEditorEngine) throws -> (NoteEditorEngine, NoteEditorTextView) {
        let data = try NoteContentCodec.encode(e.document())
        guard case let .editable(document) = NoteContentCodec.decode(data) else { XCTFail("decode"); return editor([]) }
        return editor(document.blocks)
    }

    func testPickingCalloutUnderACalloutStartsANewBoxAndItRoundTrips() throws {
        let icon = "💡"
        // On the empty last line under a callout (Return twice leaves it).
        let (e, text) = editor([.text("Title"), callout("First py", icon: icon)])
        text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
        text.insertNewline(nil); text.insertNewline(nil); settle(text)
        XCTAssertEqual(e.paragraphStyle(at: e.textStorage.length), .body)
        XCTAssertTrue(e.perform(.paragraph(.callout(icon: icon)))); settle(text)
        let last = try XCTUnwrap(e.layoutManager.flatMap { lm -> NoteBlockLayoutFragment? in
            var f: NoteBlockLayoutFragment?
            lm.enumerateTextLayoutFragments(from: e.contentStorage.documentRange.location, options: [.ensuresLayout]) { f = $0 as? NoteBlockLayoutFragment ?? f; return true }
            return f
        })
        XCTAssertEqual(last.lastLine, .callout(icon: icon), "the picked line draws its own box at once")
        let pickedCaret = try caret(text)
        text.insertText("x", replacementRange: text.selectedRange()); settle(text)
        XCTAssertEqual(try caret(text).baseline, pickedCaret.baseline, accuracy: 0.01, "nothing moves on the first letter")
        XCTAssertEqual(starts(e), 2, "two boxes")
        XCTAssertEqual(e.document().blocks.last?.calloutStart, true, "stored on the new callout")
        XCTAssertEqual(e.document().blocks[1].calloutStart, false)
        render(text, "f3-od-callout-new-picked")
        let (r, rt) = try reopen(e)
        XCTAssertEqual(starts(r), 2, "still two boxes after reopening")
        render(rt, "f3-od-callout-new-reopened")
        // Return inside the new callout continues it.
        rt.setSelectedRange(NSRange(location: r.textStorage.length, length: 0))
        rt.insertNewline(nil); rt.insertText("y", replacementRange: rt.selectedRange()); settle(rt)
        XCTAssertEqual(starts(r), 2, "Return inside a callout continues the same box")
        XCTAssertEqual(boxes(r).count, 3)
    }

    func testPickingCalloutOnATypedLineBetweenCalloutsKeepsThreeBoxes() throws {
        let (e, text) = editor([.text("Title"), callout("Above"), .text("Middle"), callout("Below")])
        let middle = (e.textStorage.string as NSString).range(of: "Middle").location
        text.setSelectedRange(NSRange(location: middle, length: 0))
        XCTAssertTrue(e.perform(.paragraph(.callout(icon: "💡")))); settle(text)
        XCTAssertEqual(boxes(e).count, 3)
        XCTAssertEqual(starts(e), 3, "above, middle and below stay separate boxes")
        let (r, _) = try reopen(e)
        XCTAssertEqual(starts(r), 3, "and after reopening")
        // Undo restores the original two boxes and their storage.
        text.undoManager?.undo(); settle(text)
        XCTAssertEqual(e.document().blocks.map(\.calloutStart), [false, false, false, false])
        XCTAssertEqual(starts(e), 2)
    }

    func testReturnInsideASeparateCalloutContinuesIt() throws {
        var separate = callout("BC"); separate.calloutStart = true
        let (e, text) = editor([.text("Title"), callout("A"), separate])
        XCTAssertEqual(starts(e), 2)
        let b = (e.textStorage.string as NSString).range(of: "BC").location
        text.setSelectedRange(NSRange(location: b + 1, length: 0))
        text.insertNewline(nil); settle(text)
        XCTAssertEqual(boxes(e).count, 3)
        XCTAssertEqual(starts(e), 2, "the split-off half continues its box")
        XCTAssertEqual(e.document().blocks.map(\.calloutStart), [false, false, true, false])
    }

    /// Notes nobody touches keep their bytes, and adjacent same-icon
    /// callouts saved before this decision still join (no migration).
    func testUntouchedNotesStayByteIdentical() throws {
        let document = NoteDocument(blocks: [.text("Title"), callout("One"), callout("Two"), .text("After")])
        let original = try NoteContentCodec.encode(document)
        let (e, _) = editor(document.blocks)
        XCTAssertEqual(starts(e), 1, "old adjacent callouts still join")
        XCTAssertEqual(try NoteContentCodec.encode(e.document()), original)
    }
}
