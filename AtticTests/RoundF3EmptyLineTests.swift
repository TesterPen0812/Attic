import AppKit
import XCTest
@testable import Attic

/// O18-04 / K-02: the empty Body line ("Type /") sits exactly where the line
/// it becomes sits, after every kind of block and by every route, live and
/// after reopening. Measured on AppKit's own caret and TextKit's baseline.
@MainActor
final class RoundF3EmptyLineTests: RoundF3TestCase {
    func blocks(_ kind: String) -> [NoteBlock] {
        switch kind {
        case "title": [.text("Title py")]
        case "body": [.text("Title"), .text("Body py")]
        case "quote": [.text("Title"), .text("Quote py", style: "quote")]
        case "callout": [.text("Title"), callout("Callout py")]
        case "code": [.text("Title"), code("let x = 1", language: "swift")]
        case "bullet": [.text("Title"), .text("Item py", style: "bullet")]
        case "heading": [.text("Title"), heading("Heading py", 2)]
        case "table": [.text("Title"), .table(NoteTable(texts: [["A", "B"], ["c", "d"]]))]
        default: []
        }
    }

    /// Puts the caret on an empty Body line at the note's end by `route`;
    /// false when that route does not lead to one for this block.
    func reach(_ route: String, _ e: NoteEditorEngine, _ text: NoteEditorTextView) -> Bool {
        text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
        switch route {
        case "return":
            text.insertNewline(nil)
            if e.paragraphStyle(at: e.textStorage.length) != .body { text.insertNewline(nil) }
        case "below": _ = e.startLineBelowFinalBlock()
        case "pick-body": text.insertNewline(nil); _ = e.perform(.paragraph(.body))
        default: break
        }
        settle(text)
        let end = e.textStorage.length
        return e.paragraphStyle(at: end) == .body && text.selectedRange() == NSRange(location: end, length: 0)
            && (e.textStorage.string as NSString).character(at: end - 1) == 0x0A
    }

    func testEmptyBodyLineMatchesTheTypedLineAfterEveryBlock() throws {
        try requireKeyWindowTests()
        var rows: [String] = []
        for kind in ["title", "body", "quote", "callout", "code", "bullet", "heading", "table"] {
            for route in ["return", "below", "pick-body", "reopen"] {
                let source = blocks(kind) + (route == "reopen" ? [.text("")] : [])
                let (e, text) = editor(source)
                guard reach(route, e, text) else { rows.append("\(kind)/\(route): n/a"); continue }
                let empty = try caret(text)
                let end = e.textStorage.length
                text.insertText("x", replacementRange: NSRange(location: end, length: 0))
                text.setSelectedRange(NSRange(location: end, length: 0)) // before the letter: same x
                let typed = try caret(text)
                rows.append(String(format: "%@/%@: empty (%.2f, %.2f) base %.2f | typed (%.2f, %.2f) base %.2f",
                                   kind, route, empty.frame.minY, empty.frame.height, empty.baseline,
                                   typed.frame.minY, typed.frame.height, typed.baseline))
                XCTAssertEqual(empty.baseline, typed.baseline, accuracy: 0.01, "\(kind)/\(route): no jump on the first letter")
                XCTAssertEqual(empty.frame.minY, typed.frame.minY, accuracy: 0.01, "\(kind)/\(route): same caret top")
                XCTAssertEqual(empty.frame.height, typed.frame.height, accuracy: 0.01, "\(kind)/\(route): same caret height")
                XCTAssertEqual(empty.frame.minX, typed.frame.minX, accuracy: 0.01, "\(kind)/\(route): same caret x")
                text.setSelectedRange(NSRange(location: end + 1, length: 0))
                // Undo the letter: back to the same empty line.
                text.undoManager?.undo(); settle(text)
                if e.textStorage.length == end {
                    let undone = try caret(text)
                    XCTAssertEqual(undone.baseline, empty.baseline, accuracy: 0.01, "\(kind)/\(route): Undo returns the empty line")
                }
            }
        }
        rows.forEach { print("F3-EMPTY", $0) }
    }
}
