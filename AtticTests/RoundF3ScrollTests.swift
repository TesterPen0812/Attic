import AppKit
import XCTest
@testable import Attic

/// V-02 (owner recording, 10-17): content may run under the floating
/// controls (10-17 decision), but the line being typed on is always
/// scrolled into view above the bottom control band (and below the top
/// one): typing, Return, a picked format, a paste and Undo.
@MainActor
final class RoundF3ScrollTests: RoundF3TestCase {
    let top: CGFloat = 40, bottom: CGFloat = 64

    func filledEditor() -> (NoteEditorEngine, NoteEditorTextView) {
        let lines = (0..<30).map { NoteBlock.text("Line \($0) of a note that fills the panel") }
        let (e, text) = editor([.text("Title")] + lines, height: 420)
        let scroll = text.enclosingScrollView!
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
        text.scrollRangeToVisible(text.selectedRange())
        settle(text)
        return (e, text)
    }

    /// The caret's line, measured against the band-free part of the view.
    func assertCaretClearOfTheBands(_ text: NoteEditorTextView, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        settle(text)
        let caret = try XCTUnwrap(indicatorFrames(text).first, what, file: file, line: line)
        let clip = text.enclosingScrollView!.contentView
        let visible = text.convert(clip.bounds, from: clip)
        XCTAssertLessThanOrEqual(caret.maxY, visible.maxY - bottom + 0.5, "\(what): above the bottom controls", file: file, line: line)
        XCTAssertGreaterThanOrEqual(caret.minY, visible.minY + top - 0.5, "\(what): below the top controls", file: file, line: line)
    }

    func testTheLineBeingTypedOnStaysAboveTheBottomControls() throws {
        try requireKeyWindowTests()
        var (e, text) = filledEditor()
        try assertCaretClearOfTheBands(text, "start")
        text.insertNewline(nil); try assertCaretClearOfTheBands(text, "Return")
        text.insertText("typed", replacementRange: text.selectedRange()); try assertCaretClearOfTheBands(text, "typing")
        text.insertNewline(nil); text.insertNewline(nil); try assertCaretClearOfTheBands(text, "Return twice (the hint line)")
        XCTAssertTrue(e.perform(.paragraph(.callout(icon: "💡")))); try assertCaretClearOfTheBands(text, "a picked callout")
        (e, text) = filledEditor()
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents(); board.setString("one\ntwo\nthree\nfour\nfive", forType: .string)
        text.paste(nil); try assertCaretClearOfTheBands(text, "paste")
        board.clearContents(); if let saved { board.setString(saved, forType: .string) }
        text.undoManager?.undo(); try assertCaretClearOfTheBands(text, "Undo")
        render(text.enclosingScrollView!, "f3-v02-after-undo")
    }
}
