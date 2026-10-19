import AppKit
import XCTest
@testable import Attic

/// DG1: a table was drawn over the note's title, the body and a callout
/// (its grips and add buttons with it) while the text flowed underneath:
/// its hosted view kept a stale frame. The invariant: every view hosted
/// for an attachment sits at its text's place (its layout fragment's
/// attachment frame) after any move, drag, scroll, relayout, resize,
/// appearance change or reopen.
@MainActor
final class NoteAttachmentFrameTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var engines: [NoteEditorEngine] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        engines.removeAll()
        super.tearDown()
    }

    // MARK: Harness

    /// The owner's note (title, body, code, quote, callout, Mermaid,
    /// table), with filler below so the note scrolls in a short window.
    private func makeNote(height: CGFloat = 300, filler: Int = 40) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("TEST")]))
        engines.append(engine)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: height)
        textView.textContainerInset = NSSize(width: 28, height: 0)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        // On screen: TextKit hosts attachment views (and draws paragraphs
        // in views of their own) only for a window that is.
        window.orderFrontRegardless()
        window.makeFirstResponder(textView)
        let end = NSRange(location: engine.textStorage.length, length: 0)
        textView.setSelectedRange(end)
        textView.insertNewline(nil)
        var markdown = NoteFormatCaptureScene.dragTestNote
        for index in 0..<filler { markdown += "\nFiller line \(index) so the note scrolls.\n" }
        _ = engine.pasteMarkdown(markdown, at: textView.selectedRange())
        engine.history.reset()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        settle(engine, textView)
        return (engine, textView)
    }

    private func settle(_ engine: NoteEditorEngine, _ textView: NoteEditorTextView) {
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        textView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func scroll(_ textView: NoteEditorTextView, to y: CGFloat) {
        guard let scrollView = textView.enclosingScrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func table(_ engine: NoteEditorEngine) throws -> NoteTableAttachment {
        try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
    }

    private func block(_ engine: NoteEditorEngine, containing text: String) throws -> NSRange {
        let location = (engine.textStorage.string as NSString).range(of: text).location
        XCTAssertNotEqual(location, NSNotFound, text)
        return engine.blockRange(at: location)
    }

    /// Each table view in the text view's window that isn't where its
    /// text is, described (empty when all are in place).
    private func misplaced(_ engine: NoteEditorEngine, _ textView: NoteEditorTextView) -> [String] {
        guard let layoutManager = textView.textLayoutManager else { return ["no layout manager"] }
        var problems: [String] = []
        for case let (attachment as NoteTableAttachment, range) in engine.objects() {
            guard let view = attachment.hostedView, view.window != nil else { continue }
            let chain = sequence(first: view as NSView, next: \.superview).dropFirst().prefix(3)
                .map { String(describing: type(of: $0)) }.joined(separator: " < ")
            guard view.window === textView.window, view.isDescendant(of: textView) else {
                problems.append("table at \(range.location) is hosted outside the note's text view (\(chain))")
                continue
            }
            guard let location = engine.textRange(for: NSRange(location: range.location, length: 0))?.location,
                  let fragment = layoutManager.textLayoutFragment(for: location) else {
                problems.append("table at \(range.location) has no layout fragment"); continue
            }
            let inFragment = fragment.frameForTextAttachment(at: location)
            let origin = textView.textContainerOrigin
            let expected = inFragment.offsetBy(dx: fragment.layoutFragmentFrame.minX + origin.x,
                                               dy: fragment.layoutFragmentFrame.minY + origin.y)
            let actual = view.convert(view.bounds, to: textView)
            if abs(actual.minY - expected.minY) > 1 || abs(actual.minX - expected.minX) > 1 {
                problems.append("table at \(range.location): shown at \(actual.origin), its text at \(expected.origin) "
                                + "(parked \(view.isParked), \(chain))")
            }
        }
        return problems
    }

    private func assertInPlace(_ engine: NoteEditorEngine, _ textView: NoteEditorTextView, _ step: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let problems = misplaced(engine, textView)
        XCTAssertTrue(problems.isEmpty, "\(step): \(problems.joined(separator: "; "))", file: file, line: line)
    }

    // MARK: Moves

    func testBlockMovesPastATableKeepItAtItsText() throws {
        let (engine, textView) = makeNote()
        assertInPlace(engine, textView, "opened")
        let quote = try block(engine, containing: "Testing qoutes")
        let after = try block(engine, containing: "Filler line 3 ")
        XCTAssertTrue(engine.moveBlock(quote, to: NSMaxRange(after)))
        settle(engine, textView)
        assertInPlace(engine, textView, "quote moved below the table")
        let moved = try block(engine, containing: "Testing qoutes")
        let body = try block(engine, containing: "My name is tester")
        XCTAssertTrue(engine.moveBlock(moved, to: NSMaxRange(body)))
        settle(engine, textView)
        assertInPlace(engine, textView, "quote moved back above the table")
        XCTAssertTrue(engine.history.undo())
        settle(engine, textView)
        assertInPlace(engine, textView, "undo")
        XCTAssertTrue(engine.history.redo())
        settle(engine, textView)
        assertInPlace(engine, textView, "redo")
    }

    func testMovingTheTableItselfKeepsItAtItsText() throws {
        let (engine, textView) = makeNote()
        let range = try XCTUnwrap(engine.range(ofTable: try table(engine)))
        let tableBlock = engine.blockRange(at: range.location)
        let body = try block(engine, containing: "My name is tester")
        XCTAssertTrue(engine.moveBlock(tableBlock, to: NSMaxRange(body)))
        settle(engine, textView)
        assertInPlace(engine, textView, "table moved to the top")
        XCTAssertTrue(engine.history.undo())
        settle(engine, textView)
        assertInPlace(engine, textView, "undo")
    }

    /// The owner's case: a cell had the keyboard (the grips and add
    /// buttons showed), the table scrolled out of view (parked), and a
    /// block moved above it before it came back.
    func testAFocusedTableScrolledOutThenMovedComesBackAtItsText() throws {
        let (engine, textView) = makeNote()
        let view = try table(engine).tableView
        scroll(textView, to: view.convert(view.bounds, to: textView).minY - 40)
        settle(engine, textView)
        view.activate(NoteTable.Position(row: 1, column: 0), caret: .end)
        settle(engine, textView)
        assertInPlace(engine, textView, "focused")
        scroll(textView, to: 4_000)
        settle(engine, textView)
        XCTAssertTrue(view.isParked, "scrolled out with a cell's keyboard: parked")
        assertInPlace(engine, textView, "scrolled out (parked)")
        let quote = try block(engine, containing: "Testing qoutes")
        let after = try block(engine, containing: "Filler line 30 ")
        XCTAssertTrue(engine.moveBlock(quote, to: NSMaxRange(after)))
        settle(engine, textView)
        assertInPlace(engine, textView, "a block moved from above it while parked")
        scroll(textView, to: 0)
        settle(engine, textView)
        assertInPlace(engine, textView, "scrolled back to the top")
        XCTAssertTrue(engine.history.undo())
        settle(engine, textView)
        assertInPlace(engine, textView, "undo")
    }

    func testAFocusedTableKeepsItsPlaceWhileBlocksMoveAboveIt() throws {
        let (engine, textView) = makeNote(height: 700)
        let view = try table(engine).tableView
        view.activate(NoteTable.Position(row: 1, column: 0), caret: .end)
        settle(engine, textView)
        let quote = try block(engine, containing: "Testing qoutes")
        let after = try block(engine, containing: "Filler line 2 ")
        XCTAssertTrue(engine.moveBlock(quote, to: NSMaxRange(after)))
        settle(engine, textView)
        assertInPlace(engine, textView, "moved below while focused")
        XCTAssertTrue(engine.history.undo())
        settle(engine, textView)
        assertInPlace(engine, textView, "undo while focused")
    }

    // MARK: Scroll, resize, appearance, reopen

    func testScrollingResizingAndAppearanceKeepItAtItsText() throws {
        let (engine, textView) = makeNote()
        for y in stride(from: 0, through: 1_200, by: 150) {
            scroll(textView, to: CGFloat(y))
            settle(engine, textView)
            assertInPlace(engine, textView, "scrolled to \(y)")
        }
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        scrollView.setFrameSize(NSSize(width: 260, height: scrollView.frame.height))
        settle(engine, textView)
        assertInPlace(engine, textView, "narrower")
        engine.update(design: AtticDesignContext(mode: .dark))
        settle(engine, textView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        assertInPlace(engine, textView, "dark")
        scrollView.setFrameSize(NSSize(width: 320, height: scrollView.frame.height))
        settle(engine, textView)
        assertInPlace(engine, textView, "wider again")
    }

    func testReopeningTheNoteHostsTheTableAtItsText() throws {
        let (engine, textView) = makeNote(height: 700)
        let old = try XCTUnwrap(textView.window)
        let (scrollView, reopened) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
        reopened.textContainerInset = NSSize(width: 28, height: 0)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        window.orderFrontRegardless()
        settle(engine, reopened)
        // The old page stays up for its outgoing transition and lays out once more.
        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()
        settle(engine, reopened)
        assertInPlace(engine, reopened, "reopened")
        old.close()
        settle(engine, reopened)
        assertInPlace(engine, reopened, "old page closed")
    }
}
