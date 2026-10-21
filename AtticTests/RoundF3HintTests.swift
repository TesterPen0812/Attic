import AppKit
import XCTest
@testable import Attic

/// O18-04: the "Type /" hint's letters stand on the empty line's real
/// TextKit baseline, live and after reopening, so the first typed letter
/// lands exactly where the hint's letters were.
@MainActor
final class RoundF3HintTests: RoundF3TestCase {
    /// The hint's drawn baseline in the text view: the bottom of its first
    /// letter ("T", no descender, no overshoot), found in its own pixels.
    func drawnHintBaseline(_ host: NSView, in text: NSTextView) throws -> CGFloat {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        // The first letter's columns: from the first inked column, 5 pt wide.
        var first: Int?
        for x in 0..<rep.pixelsWide where first == nil {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { first = x; break }
        }
        let start = try XCTUnwrap(first, "the hint drew nothing")
        // The T's stem only (its middle columns): its bar is wider, and the
        // "y" kerned under it descends. A low threshold keeps a 1x stem.
        var bottom = 0
        for x in (start + Int(2 * scale))..<min(rep.pixelsWide, start + Int(ceil(4.6 * scale))) {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 { bottom = max(bottom, y) }
        }
        return host.frame.minY + CGFloat(bottom + 1) / scale
    }

    func hint(_ e: NoteEditorEngine, _ text: NoteEditorTextView) throws -> NSView {
        let format = NoteFormatControls(engine: e, textView: text, scrollView: text.enclosingScrollView!, design: AtticDesignContext(mode: .dark))
        controls.append(format)
        format.refresh(); settle(text)
        XCTAssertTrue(format.isHintVisible)
        return try XCTUnwrap(descendants(text).first { !$0.isHidden && $0 is NoteSlashHintLabel })
    }

    func testTheHintStandsOnTheLinesBaselineLiveAndAfterReopening() throws {
        try requireKeyWindowTests()
        for (name, blocks, live) in [("after-body", [NoteBlock.text("Title"), .text("Body py")], true),
                                     ("after-callout", [.text("Title"), callout("Callout py")], true),
                                     ("after-code", [.text("Title"), code("let x = 1")], true),
                                     ("reopened", [.text("Title"), callout("Callout py"), .text("")], false),
                                     ("under-title", [.text("Title"), .text("")], false)] {
            let (e, text) = editor(blocks)
            text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
            if live { _ = e.startLineBelowFinalBlock(); settle(text) }
            let line = try caret(text)
            let host = try hint(e, text)
            let drawn = try drawnHintBaseline(host, in: text)
            render(text, "f3-hint-\(name)")
            print("F3-HINT", name, line.baseline, drawn, host.frame)
            let pixel = 1 / (text.window?.backingScaleFactor ?? 2)
            // TextKit draws a line's glyphs on the device pixel at or below
            // its baseline; the hint's letters land on that same pixel row.
            XCTAssertEqual(drawn, line.baseline, accuracy: pixel + 0.01, "\(name): the hint stands on the line's baseline")
            // The first typed letter's bottom lands on the hint's pixel row.
            let x = host.frame.minX
            text.insertText("T", replacementRange: text.selectedRange()); settle(text)
            XCTAssertTrue(host.isHidden, "\(name): the hint goes with the first letter")
            let rep = try XCTUnwrap(text.bitmapImageRepForCachingDisplay(in: text.bounds))
            text.cacheDisplay(in: text.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / text.bounds.width
            var bottom = 0
            let rows = Int((line.baseline - 13) * scale)..<min(rep.pixelsHigh, Int((line.baseline + 6) * scale))
            for px in Int((x + 2) * scale)..<Int(ceil((x + 4.6) * scale)) {
                for py in rows where (rep.colorAt(x: px, y: py)?.alphaComponent ?? 0) > 0.5
                    && (rep.colorAt(x: px, y: py)?.brightnessComponent ?? 0) > 0.4 { bottom = max(bottom, py) }
            }
            XCTAssertEqual(CGFloat(bottom + 1) / scale, drawn, accuracy: 0.01, "\(name): the typed letter stands where the hint's did")
        }
    }
}
