import AppKit
import XCTest
@testable import Attic

/// O18-03: a table cell being edited (its own TextKit 2 text view) and the
/// same cell drawn (string drawing) put every line on the same baseline,
/// and AppKit's caret in the cell is the font's natural height.
@MainActor
final class RoundF3TableCellTests: RoundF3TestCase {
    /// Baselines of the drawn cell, in the table view: string drawing lays
    /// the text out as TextKit 1 does.
    func drawnBaselines(_ string: NSAttributedString, in rect: CGRect) -> [CGFloat] {
        let storage = NSTextStorage(attributedString: string)
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        let container = NSTextContainer(size: CGSize(width: rect.width, height: 100_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var result: [CGFloat] = []
        var glyph = 0
        while glyph < manager.numberOfGlyphs {
            var range = NSRange()
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            result.append(rect.minY + line.minY + manager.location(forGlyphAt: glyph).y)
            glyph = NSMaxRange(range)
        }
        if manager.extraLineFragmentTextContainer != nil {
            let extra = manager.extraLineFragmentRect
            result.append(rect.minY + extra.minY + (manager.extraLineFragmentUsedRect.height > 0 ? extra.height - 3 : extra.height - 3))
        }
        return result
    }

    func testLiveCellAndDrawnCellShareEveryBaselineAndTheCaretIsNatural() throws {
        let long = "A cell long enough to wrap onto more lines"
        let natural = NoteTextStyle.naturalLineHeight(NoteTextStyle.font(for: AtticNoteType.body))
        for content in ["Ab py", "a\u{2028}b", "a\u{2028}\u{2028}b", "a\u{2028}", long] {
            for header in [true, false] {
                let rows = header ? [[content, "x"], ["y", "z"]] : [["H", "x"], [content, "z"]]
                let (e, text) = editor([.text("Title"), .table(NoteTable(texts: rows)), .text("After")], height: 400)
                let table = try XCTUnwrap(e.tableViews().first)
                let position = NoteTable.Position(row: header ? 0 : 1, column: 0)
                let before = table.grid.rowHeights
                let drawn = drawnBaselines(table.cellString(position), in: table.grid.drawnTextRect(position))
                table.activate(position, caret: .end); settle(table.editor); settle(text)
                let editor = table.editor
                XCTAssertEqual(table.grid.rowHeights, before, "\(content): editing never changes the row's height")
                var live: [CGFloat] = []
                editor.textLayoutManager?.enumerateTextLayoutFragments(from: editor.textLayoutManager!.documentRange.location, options: [.ensuresLayout]) { f in
                    for l in f.textLineFragments {
                        live.append(editor.frame.minY + f.layoutFragmentFrame.minY + l.typographicBounds.minY + l.glyphOrigin.y)
                    }
                    return true
                }
                XCTAssertEqual(live.count, drawn.count, "\(content) header \(header): line count")
                // An empty line has no glyph whose drawn baseline can be read;
                // the lines around it pin it.
                let parts = content.components(separatedBy: "\u{2028}")
                for (i, (a, b)) in zip(live, drawn).enumerated() where parts.count == 1 || !parts[i].isEmpty {
                    XCTAssertEqual(a, b, accuracy: 0.01, "\(content) header \(header): live = drawn baseline")
                }
                // AppKit's caret on each line of the cell.
                let string = editor.string as NSString
                var starts = [0]
                for i in 0..<string.length where string.character(at: i) == 0x2028 { starts.append(i + 1) }
                for start in starts {
                    editor.setSelectedRange(NSRange(location: start, length: 0)); settle(editor)
                    let frames = indicatorFrames(editor)
                    XCTAssertEqual(frames.count, 1, "\(content): one native caret")
                    if let frame = frames.first {
                        XCTAssertEqual(frame.height, natural, accuracy: 0.01, "\(content) at \(start): natural caret")
                    }
                }
                render(text, "f3-table-\(header ? "header" : "body")-\(content.count)")
            }
        }
    }
}
