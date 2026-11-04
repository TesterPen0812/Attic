import AppKit
import XCTest
@testable import Attic

/// The removed Notes helper stays absent on every formerly covered line.
@MainActor
final class RoundF3HintTests: RoundF3TestCase {
    // Accepted 2 Nov, UX audit B3: remove the “Type /” helper. Empty
    // lines must stay editable without drawing it, live and after reopen.
    func testRemovedHelperStaysAbsentLiveAndAfterReopening() throws {
        try requireKeyWindowTests()
        for (name, blocks, live) in [("after-body", [NoteBlock.text("Title"), .text("Body py")], true),
                                     ("after-callout", [.text("Title"), callout("Callout py")], true),
                                     ("after-code", [.text("Title"), code("let x = 1")], true),
                                     ("reopened", [.text("Title"), callout("Callout py"), .text("")], false),
                                     ("under-title", [.text("Title"), .text("")], false)] {
            let (e, text) = editor(blocks)
            text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
            if live { _ = e.startLineBelowFinalBlock(); settle(text) }
            let format = NoteFormatControls(engine: e, textView: text,
                scrollView: try XCTUnwrap(text.enclosingScrollView), design: AtticDesignContext(mode: .dark))
            controls.append(format)
            format.refresh(); settle(text)
            XCTAssertFalse(format.isHintVisible, "\(name): B3 removes the helper")
            XCTAssertFalse(descendants(text).contains { !$0.isHidden && $0 is NoteSlashHintLabel })
            let before = e.plainText
            text.insertText("T", replacementRange: text.selectedRange()); settle(text)
            XCTAssertEqual(e.plainText, before + "T", "\(name): the empty line still accepts typing")
            XCTAssertFalse(format.isHintVisible)
        }
    }
}
