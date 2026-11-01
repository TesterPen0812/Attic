import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// N4, Idea B (Accepted 2026-11-01, "Adaptive picks"): Find in an open note
/// opens in the panel's top row the way Search opens. Pin, the title and •••
/// fold away, "2/7 ‹ ›" sits at the field's end, Return and ⇧Return step,
/// Escape restores the row, and the note never moves. On an open note the
/// Search button opens Find; over All notes it still searches the notes.
@MainActor
final class AdaptiveFindTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
    }

    override func tearDown() {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        super.tearDown()
    }

    // MARK: Harness

    private func elements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject) }
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func element(_ identifier: String, in host: NSView) -> AnyObject? {
        host.layoutSubtreeIfNeeded()
        return elements(host).first { ($0.accessibilityIdentifier?() ?? "") == identifier }
    }

    private func frame(of identifier: String, in host: NSView) -> CGRect? {
        guard let element = element(identifier, in: host), let screen = element.accessibilityFrame?(),
              let window = host.window, screen.width > 0 else { return nil }
        let local = host.convert(window.convertFromScreen(screen), from: nil)
        return host.isFlipped ? local : CGRect(x: local.minX, y: host.bounds.height - local.maxY,
                                               width: local.width, height: local.height)
    }

    private func press(_ identifier: String, in host: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let control = try XCTUnwrap(element(identifier, in: host), "\(identifier) is on screen", file: file, line: line)
        XCTAssertTrue(control.accessibilityPerformPress?() ?? false, "\(identifier) presses", file: file, line: line)
    }

    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants(of:)) }

    /// What VoiceOver reads for a text element.
    private func spoken(_ identifier: String, in host: NSView) -> String? {
        guard let element = element(identifier, in: host) else { return nil }
        if let label = element.accessibilityLabel?(), !label.isEmpty { return label }
        return element.accessibilityValue?() as? String
    }

    /// The real panel on Notes with one note open whose body says "quote"
    /// three times.
    private func withNote(_ body: (_ host: AtticPanelHostingView, _ panel: NSPanel, _ draft: NoteDraftController,
                                   _ engine: NoteEditorEngine, _ library: () -> NotesLibraryModel?) throws -> Void) throws {
        let suite = "AdaptiveFind.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        _ = try notes.createDocumentNote(id: id, document: NoteDocument(blocks: [
            .text("Boiler replacement"),
            .text("We need three quotes by Friday."),
            .text("Warmflow sent a quote; HeatRight's quote follows."),
        ]), tags: []).get()
        let state = PanelUIState()
        let size = CGSize(width: 320, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let draft = NoteDraftController(noteStore: notes)
        final class Box { var value: NotesLibraryModel? }
        let library = Box()
        NotesEditorPage.lifetimeProbe = { _, model in library.value = model }
        defer { NotesEditorPage.lifetimeProbe = nil }
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state,
                                     settings: settings, tasksPageState: TasksPageState()),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer {
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            spin(0.3)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        state.selectSection(.notes)
        spin(1.5)
        if draft.pages.isLibraryPresented { draft.pages.dismissLibrary() }
        XCTAssertTrue(draft.pages.open(noteID: id), "the note opens")
        spin(1.0)
        XCTAssertFalse(draft.pages.isLibraryPresented, "a note is open")
        let engine = try XCTUnwrap(draft.pages.active?.engine, "the open note's engine")
        try body(host, panel, draft, engine, { library.value })
    }

    // MARK: The row

    func testFindOpensInTheTopRowFoldsTheRowAndLeavesTheNoteStill() throws {
        try withNote { host, _, _, engine, _ in
            let layout = PanelPageLayout(cornerSize: 52, panelSize: host.bounds.size)
            let scroll = try XCTUnwrap(engine.scrollView)
            let insetBefore = scroll.contentInsets.top
            for id in ["panel-pin-button", "panel-settings-button", "notes-search-button"] {
                XCTAssertNotNil(element(id, in: host), "\(id) at rest")
            }

            XCTAssertTrue(engine.find.handleKey(key(3, "f", flags: .command)), "⌘F opens Find")
            spin(0.8)
            XCTAssertTrue(engine.find.isShown)
            XCTAssertTrue(engine.find.shownInTopRow, "on the Notes page Find takes the top row")
            let field = try XCTUnwrap(frame(of: "note-find-bar", in: host), "Find's field")
            let expected = PanelTopRowLayout.fieldFrame(layout)
            XCTAssertEqual(field.minX, expected.minX, accuracy: 1, "the field fills the row")
            XCTAssertEqual(field.maxX, expected.maxX, accuracy: 1)
            XCTAssertEqual(field.minY, expected.minY, accuracy: 1)
            XCTAssertEqual(field.height, PanelTopRowLayout.control, accuracy: 0.5)
            for id in ["panel-pin-button", "panel-settings-button", "notes-search-button", "notes-header-title"] {
                XCTAssertNil(element(id, in: host), "\(id) folds away")
            }
            XCTAssertEqual(scroll.contentInsets.top, insetBefore, accuracy: 0.001, "nothing pushes the note down")
            XCTAssertEqual(engine.find.clearance, 0)
            XCTAssertFalse(descendants(of: scroll).contains { $0.accessibilityIdentifier() == NoteFindController.fieldIdentifier },
                           "the two-row card is gone")

            // Escape restores exactly what folded.
            XCTAssertTrue(engine.find.handleKey(key(53, "\u{1b}")), "Escape ends Find")
            spin(0.8)
            XCTAssertFalse(engine.find.isShown)
            XCTAssertNil(element("note-find-bar", in: host))
            for id in ["panel-pin-button", "panel-settings-button", "notes-search-button"] {
                XCTAssertNotNil(element(id, in: host), "\(id) is back")
            }
            XCTAssertEqual(scroll.contentInsets.top, insetBefore, accuracy: 0.001)
        }
    }

    func testTheCountSitsAtTheFieldsEndAndReturnSteps() throws {
        try withNote { host, _, _, engine, _ in
            engine.find.show()
            spin(0.8)
            engine.find.query = "quote"
            spin(0.3)
            XCTAssertEqual(engine.find.matches.count, 3, "the title is not searched; the body has three")
            XCTAssertEqual(engine.find.index, 0)
            let count = try XCTUnwrap(element("note-find-count", in: host), "the count")
            _ = count
            XCTAssertEqual(spoken("note-find-count", in: host), "1/3")
            let countFrame = try XCTUnwrap(frame(of: "note-find-count", in: host))
            let next = try XCTUnwrap(frame(of: "note-find-next", in: host))
            let previous = try XCTUnwrap(frame(of: "note-find-previous", in: host))
            let all = try XCTUnwrap(frame(of: "note-find-all-notes", in: host))
            let field = try XCTUnwrap(frame(of: "note-find-bar", in: host))
            XCTAssertLessThan(countFrame.maxX, previous.minX + 0.5, "count, then ‹")
            XCTAssertLessThan(previous.maxX, next.minX + 0.5, "‹, then ›")
            XCTAssertLessThan(next.maxX, all.minX + 0.5, "›, then All notes")
            XCTAssertEqual(next.width, NoteFindTopRowField.Metrics.step, accuracy: 0.5, "22 pt steps (44 px)")
            XCTAssertEqual(all.height, NoteFindTopRowField.Metrics.allNotesHeight, accuracy: 0.5, "20 pt pill (40 px)")
            XCTAssertLessThan(all.maxX, field.maxX - AtticControlSize.headerControl + 0.5, "× ends the field")

            engine.find.fieldFocused = true
            XCTAssertTrue(engine.find.handleKey(key(36, "\r")), "Return steps")
            XCTAssertEqual(engine.find.index, 1)
            XCTAssertTrue(engine.find.handleKey(key(36, "\r")))
            XCTAssertEqual(engine.find.index, 2)
            XCTAssertTrue(engine.find.handleKey(key(36, "\r", flags: .shift)), "⇧Return steps back")
            XCTAssertEqual(engine.find.index, 1)
            spin(0.2)
            XCTAssertEqual(spoken("note-find-count", in: host), "2/3")
            XCTAssertEqual(engine.textView?.selectedRange(), engine.find.matches[1].noteRange, "the match is selected")

            try press("note-find-next", in: host)
            spin(0.2)
            XCTAssertEqual(engine.find.index, 2, "› steps")
            try press("note-find-previous", in: host)
            spin(0.2)
            XCTAssertEqual(engine.find.index, 1, "‹ steps back")

            engine.find.query = "zebra"
            spin(0.2)
            XCTAssertEqual(spoken("note-find-count", in: host), "No matches")
            engine.find.close(returnFocus: false)
        }
    }

    func testTheCountReadsAsTheDraftDoes() {
        XCTAssertEqual(NoteFindTopRowField.count(query: "", matches: 0, index: nil), "", "nothing while empty")
        XCTAssertEqual(NoteFindTopRowField.count(query: "q", matches: 0, index: nil), "No matches")
        XCTAssertEqual(NoteFindTopRowField.count(query: "q", matches: 7, index: 1), "2/7")
        XCTAssertEqual(NoteFindTopRowField.count(query: "q", matches: 7, index: nil), "7")
    }

    // MARK: First-key speed

    func testKeysTypedBeforeTheFieldArrivesGoToTheQuery() throws {
        try withNote { host, panel, _, engine, _ in
            let text = engine.textStorage.string
            panel.makeFirstResponder(engine.textView)
            engine.find.show()
            // The same key event: the field is not drawn yet.
            XCTAssertTrue(engine.find.typeAhead(key(11, "b")), "the first key is the query's")
            XCTAssertTrue(engine.find.typeAhead(key(31, "o")))
            XCTAssertTrue(engine.find.typeAhead(key(16, "y")))
            XCTAssertTrue(engine.find.typeAhead(key(51, "\u{7f}")), "Delete edits the query")
            XCTAssertFalse(engine.find.typeAhead(key(3, "f", flags: .command)), "⌘ keys are not typing")
            XCTAssertEqual(engine.find.query, "bo")
            XCTAssertEqual(engine.textStorage.string, text, "the note is untouched")
            spin(0.8)
            let field = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == NoteFindController.fieldIdentifier }, "the top row's field")
            XCTAssertEqual(field.stringValue, "bo", "the field shows what was typed")
            let editor = try XCTUnwrap(panel.firstResponder as? NSTextView, "the field has the keyboard")
            XCTAssertTrue(editor.delegate as? NSTextField === field)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0), "the caret after what was typed")
            XCTAssertFalse(engine.find.typeAhead(key(11, "b")), "once the field has the keyboard it types itself")

            // Reopened, the last query is selected and the first key replaces it.
            engine.find.close()
            spin(0.5)
            engine.find.show()
            XCTAssertTrue(engine.find.typeAhead(key(12, "q")))
            XCTAssertEqual(engine.find.query, "q", "the first key replaces the last query")
            engine.find.close(returnFocus: false)
        }
    }

    // MARK: The Search button

    func testSearchFindsOnANoteAndSearchesOverAllNotesAndItsTooltipSaysWhich() throws {
        try withNote { host, _, draft, engine, library in
            let onNote = try XCTUnwrap(element("notes-search-button", in: host))
            XCTAssertEqual(onNote.accessibilityLabel?(), "Find in note (⌘F)", "the tooltip names Find on a note")
            XCTAssertEqual(NotesEditorPage.searchButtonLabel(onNote: true), "Find in note (⌘F)")
            try press("notes-search-button", in: host)
            spin(0.8)
            XCTAssertTrue(engine.find.isShown, "Search opens Find on an open note")
            XCTAssertFalse(draft.pages.isLibraryPresented, "the note stays")
            XCTAssertNotNil(element("note-find-bar", in: host))
            XCTAssertNil(element("notes-search", in: host), "not the notes' search")

            // All notes at the field's end carries the query on.
            engine.find.query = "quote"
            spin(0.2)
            try press("note-find-all-notes", in: host)
            spin(1.0)
            XCTAssertFalse(engine.find.isShown, "Find ends")
            XCTAssertTrue(draft.pages.isLibraryPresented, "All notes")
            XCTAssertEqual(library()?.query, "quote", "the query goes on to the notes' search")
            XCTAssertNotNil(element("notes-search", in: host), "the notes' search is open")

            // Over All notes, Search searches the notes.
            try press("search-close", in: host)
            spin(0.8)
            let offNote = try XCTUnwrap(element("notes-search-button", in: host))
            XCTAssertEqual(offNote.accessibilityLabel?(), "Search notes (⌘F)", "the tooltip names the notes' search")
            try press("notes-search-button", in: host)
            spin(0.8)
            XCTAssertNotNil(element("notes-search", in: host), "the notes' search")
            XCTAssertNil(element("note-find-bar", in: host), "not Find")
        }
    }

    // MARK: Elsewhere

    /// Find off the Notes page (a task's page) keeps its card and engine.
    func testFindOutsideTheTopRowKeepsItsCard() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("one needle, two needle")]),
                                      design: AtticDesignContext(mode: .light))
        let (scroll, _) = engine.makeView()
        scroll.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        XCTAssertFalse(engine.find.inTopRow)
        let inset = scroll.contentInsets.top
        engine.find.show()
        XCTAssertFalse(engine.find.shownInTopRow)
        XCTAssertEqual(engine.find.clearance, NoteFindController.height)
        XCTAssertEqual(scroll.contentInsets.top, inset + NoteFindController.height, "the card makes room")
        engine.find.query = "needle"
        XCTAssertEqual(engine.find.matches.count, 2)
        engine.find.close(returnFocus: false)
        XCTAssertEqual(scroll.contentInsets.top, inset)
    }
}
