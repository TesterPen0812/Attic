import AppKit
import XCTest
@testable import Attic

/// O18-03's open cases (D3): blank lines. A blank line sits exactly where a
/// typed one would, and AppKit's caret on it is the font's natural height,
/// never stretched by the line spacing. Oracle: the same note with a letter
/// on every blank line.
@MainActor
final class RoundF3BlankLineTests: RoundF3TestCase {
    /// The caret at every line start (and the note's end): its baseline and
    /// height, AppKit's own indicator.
    func carets(_ e: NoteEditorEngine, _ text: NoteEditorTextView) throws -> [Caret] {
        let string = e.textStorage.string as NSString
        var starts: [Int] = []
        var location = 0
        while location < string.length {
            let r = string.paragraphRange(for: NSRange(location: location, length: 0))
            starts.append(r.location)
            // A line separator inside a paragraph starts a line too.
            for i in r.location..<NSMaxRange(r) where string.character(at: i) == 0x2028 { starts.append(i + 1) }
            location = NSMaxRange(r)
        }
        if string.length > 0, string.character(at: string.length - 1) == 0x0A { starts.append(string.length) }
        return try starts.dropFirst().map { start in
            text.setSelectedRange(NSRange(location: start, length: 0))
            return try caret(text)
        }
    }

    func fill(_ blocks: [NoteBlock]) -> [NoteBlock] {
        blocks.enumerated().map { index, block in
            guard index > 0 else { return block }
            var b = block
            if b.text.isEmpty { b.text = "x" }
            b.text = b.text.replacingOccurrences(of: "\u{2028}\u{2028}", with: "\u{2028}x\u{2028}")
            if b.text.hasSuffix("\u{2028}") { b.text += "x" }
            return b
        }
    }

    func assertSameLines(_ name: String, _ blocks: [NoteBlock], file: StaticString = #filePath, line: UInt = #line) throws {
        let (e, text) = editor(blocks, height: 400)
        let ours = try carets(e, text)
        render(text, "f3-blank-\(name)")
        let (r, rt) = editor(fill(blocks), height: 400)
        let filled = try carets(r, rt)
        XCTAssertEqual(ours.count, filled.count, "\(name): line count", file: file, line: line)
        let natural = NoteTextStyle.naturalLineHeight(NoteTextStyle.font(for: AtticNoteType.body))
        let string = e.textStorage.string as NSString
        let blankAboveLast = string.length >= 2 && string.hasSuffix("\n\n") && blocks.count > 2
        for (i, (a, b)) in zip(ours, filled).enumerated() {
            // The one exception, by design: the blank line right above the
            // note's empty last line gives way so that last line (where the
            // caret and the hint are) sits exactly on its typed place.
            if blankAboveLast, i == ours.count - 2 { continue }
            XCTAssertEqual(a.baseline, b.baseline, accuracy: 0.01, "\(name) line \(i): baseline", file: file, line: line)
            XCTAssertEqual(a.frame.minY, b.frame.minY, accuracy: 0.01, "\(name) line \(i): caret top", file: file, line: line)
            XCTAssertEqual(a.frame.height, natural, accuracy: 0.01, "\(name) line \(i): natural caret height", file: file, line: line)
        }
        print("F3-BLANK", name, ours.map { String(format: "%.2f/%.1f", $0.baseline, $0.frame.height) }.joined(separator: " "))
    }

    func testBlankLinesSitWhereTypedLinesWouldWithANaturalCaret() throws {
        try requireKeyWindowTests()
        let long = "A paragraph long enough to wrap over several lines in this narrow column of the note"
        try assertSameLines("leading", [.text("Title"), .text(""), .text("Body py")])
        try assertSameLines("interior", [.text("Title"), .text("A"), .text(""), .text("B")])
        try assertSameLines("several", [.text("Title"), .text("A"), .text(""), .text(""), .text(""), .text("B")])
        try assertSameLines("trailing-extra", [.text("Title"), .text("A"), .text("")])
        try assertSameLines("trailing-several", [.text("Title"), .text("A"), .text(""), .text(""), .text("")])
        try assertSameLines("line-separator", [.text("Title"), .text("a\u{2028}\u{2028}b")])
        try assertSameLines("line-separator-end", [.text("Title"), .text("a\u{2028}")])
        try assertSameLines("wrapping", [.text("Title"), .text(long), .text(""), .text(long)])
    }

    /// The same blank lines made live: Return several times, deleting the
    /// last glyph, Undo and Redo, and reopening, all land on the oracle.
    func testBlankLinesMadeLiveMatchTheReopenedNote() throws {
        try requireKeyWindowTests()
        let (e, text) = editor([.text("Title"), .text("A")], height: 400)
        text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
        for _ in 0..<3 { text.insertNewline(nil) }
        settle(text)
        let live = try carets(e, text)
        let (r, rt) = editor([.text("Title"), .text("A"), .text(""), .text(""), .text("")], height: 400)
        let reopened = try carets(r, rt)
        XCTAssertEqual(live.count, reopened.count)
        for (a, b) in zip(live, reopened) {
            XCTAssertEqual(a.baseline, b.baseline, accuracy: 0.01, "Return ×3 = reopened")
            XCTAssertEqual(a.frame.height, b.frame.height, accuracy: 0.01)
        }
        // Delete the last glyph of a one-letter last line.
        let (d, dt) = editor([.text("Title"), .text("A"), .text("x")], height: 400)
        dt.setSelectedRange(NSRange(location: d.textStorage.length, length: 0))
        let typed = try caret(dt)
        dt.deleteBackward(nil); settle(dt)
        let emptied = try caret(dt)
        XCTAssertEqual(emptied.baseline, typed.baseline, accuracy: 0.01, "deleting the last glyph keeps the line")
        XCTAssertEqual(emptied.frame.height, typed.frame.height, accuracy: 0.01)
        dt.undoManager?.undo(); settle(dt)
        XCTAssertEqual(try caret(dt).baseline, typed.baseline, accuracy: 0.01, "Undo")
        dt.undoManager?.redo(); settle(dt)
        XCTAssertEqual(try caret(dt).baseline, emptied.baseline, accuracy: 0.01, "Redo")
        // Undo the Returns (one typing step) and Redo them: each state
        // matches its reopened twin.
        text.undoManager?.undo(); settle(text)
        let undone = try carets(e, text)
        let (t, tt) = editor([.text("Title"), .text("A")], height: 400)
        XCTAssertEqual(undone.map(\.baseline), try carets(t, tt).map(\.baseline), "Undo")
        text.undoManager?.redo(); settle(text)
        XCTAssertEqual(try carets(e, text).map(\.baseline), reopened.map(\.baseline), "Redo")
    }
}
