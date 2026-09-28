import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The owner's first hands-on feedback on slice 2: Format acts on the
/// paragraphs at the caret or selection only; the editor view is never
/// rebuilt while the person stays on the note; All notes' back button and
/// search.
@MainActor
final class NotesOwnerFeedbackTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private func makeEngine(_ blocks: [NoteBlock]) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks))
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        window.makeFirstResponder(textView)
        return (engine, textView)
    }

    private func objectCharacters(_ engine: NoteEditorEngine) -> [Int] {
        var result: [Int] = []
        engine.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: engine.textStorage.length)) { value, range, _ in
            if value != nil { result.append(contentsOf: range.location..<NSMaxRange(range)) }
        }
        return result
    }

    // MARK: 1. Format acts on the caret's or the selection's paragraphs

    func testChecklistFromTheCaretChangesOnlyItsParagraph() {
        let (engine, textView) = makeEngine([.text("Title"), .text("Alpha"), .text("Beta"), .text("Gamma")])
        let beta = (engine.textStorage.string as NSString).range(of: "Beta").location
        textView.setSelectedRange(NSRange(location: beta + 2, length: 0))
        XCTAssertEqual(engine.paragraphFormat(in: textView.selectedRange()), .body)
        XCTAssertTrue(engine.applyParagraphFormat(.checklist))
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .text, .checklist, .text])
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Title", "Alpha", "Beta", "Gamma"])
        XCTAssertEqual(objectCharacters(engine).count, 1, "one box, nowhere else")
        XCTAssertEqual(textView.selectedRange().location, beta + 3, "the caret stays in its word")
        XCTAssertTrue(engine.applyParagraphFormat(.body))
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .text, .text, .text])
    }

    func testChecklistFromATwoParagraphSelectionChangesThoseTwoAsOneUndoStep() {
        let (engine, textView) = makeEngine([.text("Title"), .text("Alpha"), .text("Beta"), .text("Gamma"), .text("Delta")])
        let string = engine.textStorage.string as NSString
        let start = string.range(of: "lpha").location
        let end = string.range(of: "Be").location + 2
        textView.setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertTrue(engine.applyParagraphFormat(.checklist))
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .checklist, .checklist, .text, .text])
        XCTAssertEqual(engine.paragraphFormat(in: textView.selectedRange()), .checklist)
        XCTAssertTrue(engine.history.undo(), "one Undo")
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .text, .text, .text, .text])
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .checklist, .checklist, .text, .text])
    }

    func testAWholeLineSelectionDoesNotReachTheNextLineAndTheTitleIsNeverFormatted() {
        let (engine, textView) = makeEngine([.text("Title"), .text("Alpha"), .text("Beta")])
        let string = engine.textStorage.string as NSString
        let alpha = string.range(of: "Alpha").location
        textView.setSelectedRange(NSRange(location: alpha, length: 6)) // "Alpha\n"
        XCTAssertEqual(engine.formattableParagraphs(in: textView.selectedRange()).count, 1)
        textView.setSelectedRange(NSRange(location: 0, length: string.length))
        XCTAssertTrue(engine.applyParagraphFormat(.checklist), "select all: every body paragraph")
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .checklist, .checklist], "the title stays text")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertNil(engine.paragraphFormat(in: textView.selectedRange()), "nothing to format on the title")
        XCTAssertFalse(engine.applyParagraphFormat(.checklist))
    }

    func testAnImageLineIsNeverGivenACheckbox() {
        let image = NoteBlock.image(attachmentID: UUID(), pixelWidth: 4, pixelHeight: 4)
        let (engine, textView) = makeEngine([.text("Title"), .text("Alpha"), image, .text("Beta")])
        textView.setSelectedRange(NSRange(location: 6, length: engine.textStorage.length - 6))
        XCTAssertTrue(engine.applyParagraphFormat(.checklist))
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .checklist, .image, .checklist])
    }

    // MARK: 2. The editor view stays while you stay on the note

    func testAChangeOfControlMaterialNeverRedrawsTheNote() {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .checklist("Box")]))
        engine.update(design: AtticDesignContext(controls: .liquidGlass))
        let before = engine.appearanceRefreshCount
        engine.update(design: AtticDesignContext(controls: .craft))
        engine.update(design: AtticDesignContext(reduceMotion: true, controls: .liquidGlass))
        XCTAssertEqual(engine.appearanceRefreshCount, before, "the panel turning key or not redraws nothing")
        engine.update(design: AtticDesignContext(mode: .dark))
        XCTAssertEqual(engine.appearanceRefreshCount, before + 1, "Dark does")
    }

    func testTheTextViewIsNeverReplacedWhileTypingSavingSnapshottingAndTheKeyStateChanges() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [
            .text("Blink"), .text("Body"), .checklist("Box")
        ])) else { return XCTFail("fixture") }
        let noteDraft = NoteDraftController(noteStore: store)
        let designBox = DesignBox()
        let size = CGSize(width: 320, height: 520)
        let root = OwnerFeedbackRoot(noteDraft: noteDraft, store: store, design: designBox, size: size)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        let controller = noteDraft.pages
        spin()
        XCTAssertTrue(controller.open(noteID: id))
        spin()
        let session = try XCTUnwrap(controller.active)
        let textView = try XCTUnwrap(session.engine.textView)
        let scrollView = try XCTUnwrap(session.engine.scrollView)
        let refreshes = session.engine.appearanceRefreshCount
        func assertSameView(_ step: String) {
            XCTAssertTrue(controller.active === session, step)
            XCTAssertTrue(session.engine.textView === textView, "the text view survives \(step)")
            XCTAssertTrue(session.engine.scrollView === scrollView, step)
            XCTAssertTrue(textView.window === window, step)
        }
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: session.engine.textStorage.length, length: 0))
        for character in " more words" {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        spin()
        assertSameView("typing")
        await controller.runDueSave(session)
        spin()
        XCTAssertEqual(session.state, .clean)
        assertSameView("autosave")
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        spin()
        assertSameView("the pause snapshot")
        controller.present()
        spin()
        assertSameView("presenting again")
        for material in [AtticControlMaterial.craft, .liquidGlass, .craft] {
            designBox.design = AtticDesignContext(controls: material)
            spin()
        }
        assertSameView("the panel turning key and back")
        XCTAssertEqual(session.engine.appearanceRefreshCount, refreshes, "and nothing was redrawn")
        textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        await controller.runDueSave(session)
        spin()
        assertSameView("a second save")
    }

    private func spin(_ seconds: TimeInterval = 0.25) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: 3. All notes' back button

    func testTheBackButtonPointsToTheNoteAndTheLibrarySlidesFromTheLeft() {
        XCTAssertEqual(NotesEditorPage.libraryButtonGlyph(libraryShown: false), "rectangle.stack")
        XCTAssertEqual(NotesEditorPage.libraryButtonGlyph(libraryShown: true), "chevron.right",
                       "the note is to the right")
        XCTAssertEqual(NotesEditorPage.libraryEdge, .leading)
        XCTAssertEqual(NotesEditorPage.noteEdge, .trailing)
    }

    // MARK: 4. The quiet search

    func testSearchTakesTheLabelLineOnlyWhileItIsInUse() {
        XCTAssertFalse(NotesLibraryView.searchShown(open: false, focused: false, query: ""))
        XCTAssertTrue(NotesLibraryView.searchShown(open: true, focused: false, query: ""),
                      "opening shows the field before it can take the keyboard")
        XCTAssertTrue(NotesLibraryView.searchShown(open: false, focused: true, query: ""))
        XCTAssertTrue(NotesLibraryView.searchShown(open: false, focused: false, query: "kyoto"), "a query keeps the field")
        XCTAssertEqual(NotesLibraryView.typedSearchText(KeyEquivalent("k"), modifiers: []), "k")
        XCTAssertEqual(NotesLibraryView.typedSearchText(KeyEquivalent("K"), modifiers: .shift), "K")
        XCTAssertNil(NotesLibraryView.typedSearchText(KeyEquivalent("f"), modifiers: .command), "shortcuts don't type")
        XCTAssertNil(NotesLibraryView.typedSearchText(.downArrow, modifiers: []))
        XCTAssertNil(NotesLibraryView.typedSearchText(.space, modifiers: []), "a leading space starts nothing")
    }
}

@MainActor
private final class DesignBox: ObservableObject {
    @Published var design = AtticDesignContext(controls: .liquidGlass)
}

private struct OwnerFeedbackRoot: View {
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var store: NoteStore
    @ObservedObject var design: DesignBox
    let size: CGSize
    @StateObject private var uiState = PanelUIState()

    var body: some View {
        NotesEditorPage(controller: noteDraft.pages, noteStore: store, noteDraft: noteDraft, uiState: uiState,
                        layout: PanelPageLayout(cornerSize: 52, panelSize: size))
            .frame(width: size.width, height: size.height)
            .atticDesign(design.design)
    }
}
