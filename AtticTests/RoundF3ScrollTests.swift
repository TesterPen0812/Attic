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

    // O5-01: every reveal uses the clear viewport, including nonempty ranges.
    func testFX2FindAndNavigationClearBothBandsAtEveryPanelWidth() throws {
        for width: CGFloat in [420, 340, 500] {
            let lines = (1...1000).map { NoteBlock.text(String(format: "Line %04d: planning release notes, research and follow-up.", $0)) }
            let (e, text) = editor([.text("O5 thousand lines")] + lines, width: width, height: 640)
            let scroll = try XCTUnwrap(text.enclosingScrollView)
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 64, left: 0, bottom: 60, right: 0)
            e.find.show()
            for number in [500, 250, 900] {
                let query = String(format: "Line %04d", number)
                let range = (text.string as NSString).range(of: query)
                for fromBottom in [false, true] {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: fromBottom ? text.frame.height - 640 : -scroll.contentInsets.top))
                    e.find.query = query
                    XCTAssertEqual(text.selectedRange(), range)
                    try assertFX2RangeClear(range, in: text, "Find width=\(width) bottom=\(fromBottom)")
                    e.find.next()
                    try assertFX2RangeClear(range, in: text, "Find Next")
                    e.find.next(backward: true)
                    try assertFX2RangeClear(range, in: text, "Find Previous")
                }
            }
            e.find.close()
            let range = (text.string as NSString).range(of: "Line 0500: planning release notes, research and follow-up.")
            scroll.contentView.scroll(to: .zero)
            text.setSelectedRange(range)
            text.scrollRangeToVisible(range)
            try assertFX2RangeClear(range, in: text, "multiline selection / heading / opening reveal")
            // Undo must jump back to an offscreen edit, including a restored selection.
            text.insertText("replacement", replacementRange: range)
            scroll.contentView.scroll(to: .zero)
            text.undo(nil)
            XCTAssertEqual(text.selectedRange(), range)
            try assertFX2RangeClear(range, in: text, "Undo jump")
        }
    }

    func testFX2RevealDoesNotTreatTheCoveredPartOfTheClipAsVisible() throws {
        for width: CGFloat in [420, 340] {
            let (e, text) = editor([.text("Title")] + (0..<1000).map { .text("Line \($0) of a note that fills the panel") }, width: width, height: 640)
            let scroll = try XCTUnwrap(text.enclosingScrollView)
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 140, left: 0, bottom: 60, right: 0)
            let range = (text.string as NSString).range(of: "Line 500")
            let rect = try XCTUnwrap(e.rect(for: range))
            for behindFooter in [true, false] {
                let y = behindFooter ? rect.maxY - 640 + 30 : rect.minY - 70
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                text.setSelectedRange(range)
                text.scrollRangeToVisible(range)
                try assertFX2RangeClear(range, in: text, "covered range width=\(width) footer=\(behindFooter)")
            }
        }
    }

    func testFX2IncrementalFindInAColdThousandLineNote() throws {
        for width: CGFloat in [420, 340] {
            let lines = (1...1000).map { NoteBlock.text(String(format: "Line %04d: planning release notes, research and follow-up.", $0)) }
            let e = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("O5 thousand lines")] + lines))
            engines.append(e)
            let (scroll, text) = e.makeView()
            text.textContainerInset = CGSize(width: 28, height: 0)
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 64, left: 0, bottom: 60, right: 0)
            host(scroll, text: text, width: width, height: 640)
            scroll.layoutSubtreeIfNeeded()
            text.layoutSubtreeIfNeeded()
            text.moveToBeginningOfDocument(nil)
            e.find.show()
            for character in "Line 0500" {
                e.find.query.append(character)
                scroll.layoutSubtreeIfNeeded()
                text.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            let range = (text.string as NSString).range(of: "Line 0500")
            XCTAssertEqual(text.selectedRange(), range)
            try assertFX2RangeClear(range, in: text, "incremental cold Find width=\(width)")
            e.find.next()
            try assertFX2RangeClear(range, in: text, "incremental Find Next width=\(width)")
            render(scroll, "fx2-find-\(Int(width))")
        }
    }

    private func assertFX2RangeClear(_ range: NSRange, in text: NoteEditorTextView, _ label: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        settle(text)
        let rect = try XCTUnwrap(text.engine?.rect(for: range), file: file, line: line)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let visible = text.convert(scroll.contentView.bounds, from: scroll.contentView)
        print("FX2_REVEAL \(label) range=\(range) rect=\(rect) visible=\(visible) insets=\(scroll.contentInsets)")
        XCTAssertGreaterThanOrEqual(rect.minY, visible.minY + scroll.contentInsets.top + 4 - 0.5, label, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, visible.maxY - scroll.contentInsets.bottom - 4 + 0.5, label, file: file, line: line)
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
