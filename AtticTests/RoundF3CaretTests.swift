import AppKit
import XCTest
@testable import Attic

/// O18-03 (owner, 2026-10-17: "native, like TextEdit"): AppKit's own caret,
/// never reframed by Attic, the font's natural height on every line. These
/// replace the fitter's self-referential tests (`PhaseXCaretTests`, F-03 /
/// O14-10), which asserted its own formula on stand-in indicators.
@MainActor
final class RoundF3CaretTests: RoundF3TestCase {
    /// A stock TextKit 2 text view with the same text and attributes, and no
    /// Attic layout, delegate or fitter: TextEdit's caret for that text.
    func stock(_ attributed: NSAttributedString, typing: [NSAttributedString.Key: Any], width: CGFloat = 340) -> NSTextView {
        let text = NSTextView(usingTextLayoutManager: true)
        text.frame = CGRect(x: 0, y: 0, width: width, height: 300)
        text.isRichText = false; text.isVerticallyResizable = true
        text.textContainerInset = CGSize(width: 24, height: 0)
        text.textContainer?.lineFragmentPadding = 0
        text.textStorage?.setAttributedString(attributed)
        text.typingAttributes = typing
        let scroll = NSScrollView(frame: text.frame); scroll.documentView = text
        host(scroll, text: text, height: 300)
        settle(text)
        return text
    }

    /// The caret's top and bottom relative to its line's baseline.
    func shape(_ c: Caret) -> (top: CGFloat, bottom: CGFloat) { (c.frame.minY - c.baseline, c.frame.maxY - c.baseline) }

    func testTitleAndTableCellCaretsAreTextEdits() throws {
        // The title (D2's matrix covers the body, headings, lists, quotes and callouts).
        let (e, text) = editor([.text("Title py"), .text("Body")])
        text.setSelectedRange(NSRange(location: 2, length: 0))
        let ours = try caret(text)
        let native = stock(e.textStorage.attributedSubstring(from: NSRange(location: 0, length: 9)), typing: text.typingAttributes)
        native.setSelectedRange(NSRange(location: 2, length: 0))
        let theirs = try caret(native)
        XCTAssertEqual(shape(ours).top, shape(theirs).top, accuracy: 0.01, "title: AppKit's caret, as TextEdit places it")
        XCTAssertEqual(shape(ours).bottom, shape(theirs).bottom, accuracy: 0.01)
        // A table cell's editor.
        let (te, tt) = editor([.text("Title"), .table(NoteTable(texts: [["Head py", "B"], ["Cell py", "d"]])), .text("After")])
        let table = try XCTUnwrap(te.tableViews().first)
        for (row, label) in [(0, "header"), (1, "body")] {
            table.activate(NoteTable.Position(row: row, column: 0), caret: .end); settle(table.editor); settle(tt)
            let cell = try caret(table.editor)
            let reference = stock(table.editor.textStorage!, typing: table.editor.typingAttributes)
            reference.setSelectedRange(NSRange(location: reference.string.count, length: 0))
            let theirs = try caret(reference)
            XCTAssertEqual(shape(cell).top, shape(theirs).top, accuracy: 0.01, "\(label) cell: TextEdit's caret")
            XCTAssertEqual(shape(cell).bottom, shape(theirs).bottom, accuracy: 0.01)
        }
    }

    /// K-03 (a): the empty title's caret is the same native caret as the
    /// typed title's, before and after the first letter.
    func testTheEmptyTitleCaretIsTheTypedTitlesCaret() throws {
        let (e, text) = editor([.text("")])
        text.setSelectedRange(NSRange(location: 0, length: 0)); settle(text)
        // An empty note has no laid-out line to read a baseline from.
        let empty = Caret(frame: try XCTUnwrap(indicatorFrames(text).first), baseline: 0)
        XCTAssertEqual(indicatorFrames(text).count, 1)
        render(text, "f3-k03-empty-title")
        text.insertText("T", replacementRange: NSRange(location: 0, length: 0))
        text.setSelectedRange(NSRange(location: 0, length: 0))
        let typed = try caret(text)
        render(text, "f3-k03-typed-title")
        XCTAssertEqual(empty.frame.minY, typed.frame.minY, accuracy: 0.01, "same place")
        XCTAssertEqual(empty.frame.height, typed.frame.height, accuracy: 0.01, "same height")
        XCTAssertEqual(empty.frame.height, NoteTextStyle.naturalLineHeight(e.style.titleFont), accuracy: 0.01)
    }

    /// K-03 (b): a click beside a table or an image lands on the nearest text
    /// line with a line-high caret, never a bar the object's height.
    func testAClickBesideAnObjectLandsOnTheNearestTextLine() throws {
        let image = NoteBlock.image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400)
        for (name, object) in [("table", NoteBlock.table(NoteTable(texts: [["A", "B"], ["c", "d"], ["e", "f"]]))), ("image", image)] {
            let (e, text) = editor([.text("Title"), .text("Quote py", style: "quote"), object, .text("After")], height: 400)
            let string = e.textStorage.string as NSString
            let start = string.range(of: "Quote py").location + 9
            let rect = try XCTUnwrap(e.rect(for: NSRange(location: start, length: 1)))
            // What AppKit gives a click in the gap above the object.
            text.setSelectedRange(NSRange(location: start, length: 0))
            text.settleCaretBesideObject(clickedAt: NSPoint(x: rect.minX + 2, y: rect.minY - 2))
            XCTAssertEqual(text.selectedRange(), NSRange(location: start - 1, length: 0), "\(name): the end of the quote")
            let natural = NoteTextStyle.naturalLineHeight(e.style.bodyFont)
            XCTAssertEqual(try caret(text).frame.height, natural, accuracy: 0.01, "\(name): a line-high caret")
            // Past the object's side, low: the start of the line after it.
            text.setSelectedRange(NSRange(location: start + 1, length: 0))
            text.settleCaretBesideObject(clickedAt: NSPoint(x: rect.maxX + 4, y: rect.maxY - 2))
            XCTAssertEqual(text.selectedRange(), NSRange(location: start + 2, length: 0), "\(name): the start of the next line")
            XCTAssertEqual(try caret(text).frame.height, natural, accuracy: 0.01)
            // A keyboard caret beside the object is left where AppKit put it.
            text.setSelectedRange(NSRange(location: start, length: 0))
            XCTAssertEqual(text.selectedRange().location, start)
        }
    }

    /// Attic never reframes the indicator: on every caret position AppKit's
    /// indicator is exactly TextKit's own insertion segment.
    func testTheIndicatorIsAlwaysTextKitsOwnInsertionSegment() throws {
        var c = callout("Callout py"); c.callout = "💡"
        let (e, text) = editor([.text("Title"), .text("Body py"), heading("Heading", 1), .text("Quote", style: "quote"), c,
                                code("let x = 1"), .text("Item", style: "bullet"), .text("")], height: 500)
        let length = e.textStorage.length
        for location in stride(from: 1, through: length, by: 3) {
            text.setSelectedRange(NSRange(location: location, length: 0))
            let ours = try caret(text)
            var segment: CGRect?
            let lm = try XCTUnwrap(e.layoutManager)
            let start = try XCTUnwrap(e.textRange(for: NSRange(location: location, length: 0)))
            lm.enumerateTextSegments(in: start, type: .standard, options: [.rangeNotRequired]) { _, r, _, _ in segment = r; return false }
            let expected = try XCTUnwrap(segment).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
            XCTAssertEqual(ours.frame.minY, expected.minY, accuracy: 0.01, "at \(location)")
            XCTAssertEqual(ours.frame.height, expected.height, accuracy: 0.01, "at \(location)")
        }
    }

    /// Mixed content (D3's open case). Each line's box is the base font's
    /// natural one, fixed (`NoteTextStyle.setLines`), so an emoji, inline
    /// code, a bigger pasted font or a checklist box never changes the
    /// line's pitch, its baseline or AppKit's caret. Measured and printed.
    func testMixedContentKeepsThePitchBaselineAndCaret() throws {
        var code = NoteBlock.text("Say launch now")
        code.marks = [NoteMark(.code, offset: 4, length: 6)]
        let cases: [(String, NoteBlock)] = [("plain", .text("Plain text py")), ("emoji", .text("Emoji 😀🎉 py")),
                                            ("inline-code", code), ("checklist", .checklist("Check py"))]
        let (_, reference) = editor([.text("Title"), .text("Plain text py"), .text("After")])
        reference.setSelectedRange(NSRange(location: 7, length: 0))
        let plain = try caret(reference)
        reference.setSelectedRange(NSRange(location: reference.string.count, length: 0))
        let plainAfter = try caret(reference)
        for (name, block) in cases {
            let (e, text) = editor([.text("Title"), block, .text("After")])
            text.setSelectedRange(NSRange(location: 8, length: 0))
            let line = try caret(text)
            text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
            let after = try caret(text)
            print("F3-MIXED", name, String(format: "line base %.2f caret h %.2f | next base %.2f", line.baseline, line.frame.height, after.baseline))
            XCTAssertEqual(line.baseline, plain.baseline, accuracy: 0.01, "\(name): same baseline")
            XCTAssertEqual(line.frame.height, plain.frame.height, accuracy: 0.01, "\(name): same caret")
            XCTAssertEqual(after.baseline, plainAfter.baseline, accuracy: 0.01, "\(name): the next line does not move")
        }
        // A bigger font pasted into a body line (rich paste keeps it only if
        // the engine lets it; force it in storage to measure the line box).
        let (e, text) = editor([.text("Title"), .text("Big text py"), .text("After")])
        e.textStorage.addAttribute(.font, value: NSFont.systemFont(ofSize: 24), range: NSRange(location: 6, length: 3))
        settle(text)
        text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
        let after = try caret(text)
        print("F3-MIXED big-font", String(format: "next base %.2f (plain %.2f)", after.baseline, plainAfter.baseline))
        XCTAssertEqual(after.baseline, plainAfter.baseline, accuracy: 0.01, "a bigger font keeps the pitch")
    }
}
