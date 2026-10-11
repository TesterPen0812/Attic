import AppKit
import XCTest
@testable import Attic

@MainActor
final class MarqueeSelectionTests: XCTestCase {
    func testWholeBlockCopyOffersRichTextAndMarkdown() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [
            .text("Title"), .text("Alpha", style: "quote"), .text("Beta")
        ]))
        let (_, text) = engine.makeView()
        let start = (text.string as NSString).range(of: "Alpha").location
        text.setSelectedRange(NSRange(location: start, length: text.string.utf16.count - start))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(text.writeSelection(to: board, types: [.rtf, .string, TasksTextExport.markdownType]))
        XCTAssertNotNil(board.data(forType: .rtf))
        XCTAssertEqual(board.string(forType: TasksTextExport.markdownType), "> Alpha\n\nBeta")
    }
}
