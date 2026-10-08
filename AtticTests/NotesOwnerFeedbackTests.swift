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

    // MARK: 4b. The search's keys never take an input method's keys

    func testWhileComposingEscTheArrowsAndReturnBelongToTheInputMethod() {
        for keyCode: UInt16 in [53, 125, 126, 36, 76] {
            XCTAssertEqual(NotesLibraryView.keyAction(keyCode: keyCode, modifiers: [], characters: nil,
                                                      composing: true, fieldFocused: true), .passThrough, "key \(keyCode)")
        }
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 51, modifiers: .command, characters: nil,
                                                  composing: true, fieldFocused: true), .passThrough)
        // Without a composition they are the list's.
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 53, modifiers: [], characters: nil, composing: false, fieldFocused: true), .escape)
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 125, modifiers: [], characters: nil, composing: false, fieldFocused: true), .move(1))
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 126, modifiers: [], characters: nil, composing: false, fieldFocused: false), .move(-1))
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 36, modifiers: [], characters: "\r", composing: false, fieldFocused: true), .open)
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 3, modifiers: .command, characters: "f", composing: false, fieldFocused: false), .find)
    }

    func testTypingStartsTheSearchOnlyOutsideTheFieldAndNeverAsRawText() {
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 40, modifiers: [], characters: "k",
                                                  composing: false, fieldFocused: false), .startSearch)
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 40, modifiers: [], characters: "k",
                                                  composing: false, fieldFocused: true), .passThrough,
                       "in the field, the field types")
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 40, modifiers: .command, characters: "k",
                                                  composing: false, fieldFocused: false), .passThrough)
    }

    func testTheKeystrokeThatStartsASearchGoesThroughTheTextInputSystem() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let window = NSWindow(contentRect: textView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = textView
        windows.append(window)
        window.makeFirstResponder(textView)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        NotesLibraryKeys.deliver(event, to: textView)
        XCTAssertEqual(textView.string, "k", "delivered as a keystroke the text system interprets")
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

// The approved p2-38 refinement: native geometry and semantic editing boundaries.
@MainActor
extension NotesOwnerFeedbackTests {
    private func styled(_ text: String, _ style: String, level: Int? = nil) -> NoteBlock {
        var block = NoteBlock.text(text)
        block.style = style
        block.level = level
        return block
    }

    func testTypographyGroupsEmptySectionsWithoutChangingTheirContent() throws {
        let blocks: [NoteBlock] = [.text("CIA impact"), styled("Incident", "heading", level: 2),
            .text("Prose"), styled("Confidentiality", "heading", level: 3), .text(""),
            styled("Integrity", "heading", level: 3), styled("Availability", "heading", level: 3), .text("Body")]
        let (engine, _) = makeEngine(blocks)
        XCTAssertEqual(engine.document().blocks, blocks)
        let style = engine.style
        XCTAssertEqual(style.titleFont.pointSize, 22)
        XCTAssertEqual(style.headingFont.pointSize, 18)
        XCTAssertEqual(style.subheadingFont.pointSize, 15.5)
        XCTAssertEqual(style.bodyFont.pointSize, 14)
        XCTAssertEqual(style.monoFont.pointSize, 12)
        func paragraph(_ text: String) throws -> NSParagraphStyle {
            let location = (engine.textStorage.string as NSString).range(of: text).location
            return try XCTUnwrap(engine.textStorage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
        }
        XCTAssertEqual(try paragraph("Confidentiality").paragraphSpacingBefore, 11)
        XCTAssertEqual(try paragraph("Integrity").paragraphSpacingBefore, 10)
        XCTAssertEqual(try paragraph("Availability").paragraphSpacingBefore, 10)
        XCTAssertEqual(try paragraph("Availability").paragraphSpacing, 6)
        let blank = (engine.textStorage.string as NSString).range(of: "\n\n").location + 1
        XCTAssertEqual((engine.textStorage.attribute(.paragraphStyle, at: blank, effectiveRange: nil) as? NSParagraphStyle)?.maximumLineHeight, 8)
    }

    func testMonoFragmentsJoinAcrossEmptyAndWrappedLinesAndSeparateFromProse() throws {
        let blocks: [NoteBlock] = [.text("Title"), styled(String(repeating: "identifier ", count: 18), "mono"),
            styled("", "mono"), styled("last line", "mono"), .text("prose"), styled("separate", "mono")]
        let (engine, view) = makeEngine(blocks)
        let manager = try XCTUnwrap(engine.layoutManager)
        manager.ensureLayout(for: engine.contentStorage.documentRange)
        var fragments: [NoteCodeLayoutFragment] = []
        manager.enumerateTextLayoutFragments(from: engine.contentStorage.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let code = fragment as? NoteCodeLayoutFragment { fragments.append(code) }
            return true
        }
        XCTAssertEqual(fragments.count, 4)
        guard fragments.count == 4 else { return }
        XCTAssertEqual(fragments.map(\.startsBlock), [true, false, false, true])
        XCTAssertEqual(fragments.map(\.endsBlock), [false, false, true, true])
        XCTAssertEqual(fragments.map(\.topMargin), [12, 0, 0, 12])
        XCTAssertEqual(fragments.map(\.bottomMargin), [0, 0, 12, 12])
        XCTAssertGreaterThan(fragments[0].textLineFragments.count, 1, "long code wraps inside the card")
        XCTAssertEqual(fragments[0].renderingSurfaceBounds.width, view.textContainer!.size.width, accuracy: 1)
        XCTAssertEqual(engine.document().blocks, blocks, "layout never rewrites empty paragraphs")
        for fragment in fragments {
            for line in fragment.textLineFragments {
                XCTAssertGreaterThanOrEqual(line.typographicBounds.minX + fragment.layoutFragmentFrame.minX, 12)
                XCTAssertLessThanOrEqual(line.typographicBounds.maxX + fragment.layoutFragmentFrame.minX, view.textContainer!.size.width - 12 + 1)
            }
        }
    }

    func testFinalEmptyMonoLineHasBottomPaddingAndUpdatesOnFormatUndo() throws {
        let (engine, view) = makeEngine([.text("Title"), styled("code", "mono"), styled("", "mono")])
        let manager = try XCTUnwrap(engine.layoutManager)
        let end = engine.textStorage.length
        func fragments() -> [NoteCodeLayoutFragment] {
            manager.ensureLayout(for: engine.contentStorage.documentRange)
            var result: [NoteCodeLayoutFragment] = []
            manager.enumerateTextLayoutFragments(from: engine.contentStorage.documentRange.location,
                                                options: [.ensuresLayout, .ensuresExtraLineFragment]) {
                if let fragment = $0 as? NoteCodeLayoutFragment { result.append(fragment) }
                return true
            }
            return result
        }
        XCTAssertEqual(fragments().last?.bottomMargin, 12)
        view.setSelectedRange(NSRange(location: end, length: 0))
        XCTAssertTrue(engine.perform(.paragraph(.body)))
        XCTAssertEqual(fragments().last?.endsBlock, true)
        XCTAssertEqual(fragments().last?.bottomMargin, 12)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.paragraphStyle(at: end), .mono)
        XCTAssertEqual(fragments().last?.bottomMargin, 12)
        XCTAssertEqual(engine.document().blocks.last?.text, "")
    }

    func testTagReservesAndFormattingAcrossAnEmptySectionRefreshDependentHeadings() throws {
        let (engine, view) = makeEngine([.text("Title"), styled("A", "heading", level: 2), .text(""), styled("B", "heading", level: 2)])
        func spacing(_ text: String) throws -> CGFloat {
            let at = (engine.textStorage.string as NSString).range(of: text).location
            return try XCTUnwrap(engine.textStorage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle).paragraphSpacingBefore
        }
        XCTAssertEqual(try spacing("A"), 10)
        engine.setTitleReserves(tagLine: 18, trailing: 20)
        XCTAssertEqual(try spacing("A"), 0, "tag space is included immediately")
        engine.setTitleReserves(tagLine: 0, trailing: 20)
        XCTAssertEqual(try spacing("A"), 10)
        let a = (engine.textStorage.string as NSString).range(of: "A")
        view.setSelectedRange(a)
        XCTAssertTrue(engine.perform(.paragraph(.body)))
        XCTAssertEqual(try spacing("B"), 11, "looks through the empty paragraph")
        let reopened = NoteEditorEngine(noteID: engine.noteID, document: engine.document())
        let b = (reopened.textStorage.string as NSString).range(of: "B").location
        XCTAssertEqual((reopened.textStorage.attribute(.paragraphStyle, at: b, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore, try spacing("B"))
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(try spacing("B"), 10)
    }

    func testCodeCheckingFiltersOnlyCodeAndRespectsFormattingUndo() throws {
        var inline = NoteBlock.text("prose inlinecodetypo prose")
        inline.marks = [NoteMark(.code, offset: 6, length: 14)]
        let (engine, view) = makeEngine([.text("Title"), styled("codetypo", "mono"), inline])
        XCTAssertTrue(view.isContinuousSpellCheckingEnabled)
        let string = engine.textStorage.string as NSString
        let code = string.range(of: "codetypo")
        let prose = string.range(of: "prose")
        let inlineCode = string.range(of: "inlinecodetypo")
        let results = [code, prose, inlineCode].map { NSTextCheckingResult.spellCheckingResult(range: $0) }
        func checked() -> [NSTextCheckingResult] {
            engine.textView(view, didCheckTextIn: NSRange(location: 0, length: string.length),
                            types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                            options: [:], results: results, orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: 3)
        }
        XCTAssertEqual(checked().map(\.range), [prose])
        view.setSelectedRange(code)
        XCTAssertTrue(engine.perform(.paragraph(.body), selection: code))
        XCTAssertEqual(checked().map(\.range), [code, prose])
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(checked().map(\.range), [prose])
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(checked().map(\.range), [code, prose])
    }

    func testMonoTypingNewlinesPasteUndoAndPersistenceKeepStyleBoundaries() throws {
        let (engine, view) = makeEngine([.text("Title"), styled("first", "mono"), .text("body")])
        let start = (engine.textStorage.string as NSString).range(of: "first").location
        view.setSelectedRange(NSRange(location: start + 5, length: 0))
        view.insertNewline(nil)
        view.insertText("second", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), .mono)
        let beforePaste = engine.document()
        XCTAssertTrue(engine.pastePlainText("\nthird", at: view.selectedRange()))
        let pasted = engine.document()
        XCTAssertEqual(pasted.blocks.last?.text, "body")
        XCTAssertNil(pasted.blocks.last?.style)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document(), beforePaste)
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(engine.document(), pasted)
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: pasted) else { return XCTFail("save") }
        let saved = try XCTUnwrap(store.notes.first { $0.id == id })
        guard case let .editable(reopened) = NoteContentCodec.decode(saved.content!) else { return XCTFail("reopen") }
        XCTAssertEqual(reopened, pasted)
    }
}
