import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Phase 2 audit fix B2: ⌘Z in Notes follows the focus. The text under the
/// caret (the note, or the library's search) answers first; the library's
/// history answers in All notes when that text has nothing to undo; and the
/// delete toast never owns the key.
///
/// The Notes page is hosted as the panel hosts it, in a transparent window
/// behind everything, and real key events go through the same order AppKit uses: the
/// local key monitor (`NotesLibraryKeys`) first, then the window's view
/// hierarchy (`performKeyEquivalent`, where SwiftUI's `keyboardShortcut`
/// lives), then the Edit menu's Undo, which reaches `undo:` on the first
/// responder. The pure `keyAction` decision function alone cannot show which
/// of these wins.
@MainActor
final class NotesKeyboardUndoTests: XCTestCase {
    /// A window that counts as key without being made key. The test
    /// dispatches what gets past the local monitors in AppKit's order itself.
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
        override func sendEvent(_ event: NSEvent) {}
    }

    /// Who took a key.
    private enum Route: Equatable {
        /// The library's local key monitor consumed it.
        case monitor
        /// A key equivalent in the window's views (a SwiftUI shortcut) took it.
        case viewKeyEquivalent
        /// The Edit menu's Undo/Redo, delivered to the first responder.
        case firstResponder
        case nobody
    }

    @MainActor private struct Harness {
        let window: KeyWindow
        let host: NSHostingView<AnyView>
        let store: NoteStore
        let noteDraft: NoteDraftController
        let toasts: PanelToastCenter
        var controller: NotesPageController { noteDraft.pages }
    }

    private var windows: [NSWindow] = []
    private let gate = PersistenceGate()

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()
    }

    private func spin(_ seconds: TimeInterval = 0.25) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Notes are created in the order given: the last one is the newest and
    /// the first row of All notes.
    private func makeHarness(titles: [String]) throws -> (Harness, [UUID]) {
        let gate = gate
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        var ids: [UUID] = []
        for title in titles {
            guard case let .success((id, _)) = store.createDocumentNote(
                id: UUID(), document: NoteDocument(blocks: [.text(title)]), tags: nil) else {
                throw NSError(domain: "create", code: 1)
            }
            ids.append(id)
        }
        let noteDraft = NoteDraftController(noteStore: store)
        let toasts = PanelToastCenter()
        toasts.holdDuration = 600
        let size = CGSize(width: 320, height: 520)
        let root = KeyboardUndoRoot(noteDraft: noteDraft, store: store, toasts: toasts, size: size)
            .atticDesign(AtticDesignContext(controls: .craft))
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)
        let window = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Behind everything and fully transparent: SwiftUI only runs its
        // update cycle for a window that is on screen, as other tests here do.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderBack(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        spin()
        return (Harness(window: window, host: host, store: store, noteDraft: noteDraft, toasts: toasts), ids)
    }

    /// What the library's history and the notes look like: a key the library
    /// used to Undo or Redo changes it.
    private func libraryFingerprint(_ harness: Harness) -> [AnyHashable] {
        [harness.controller.libraryUndoStepID, harness.controller.canRedoLibrary,
         harness.store.notes.map(\.id)]
    }

    /// One key, through AppKit's order. Returns who took it.
    @discardableResult
    private func press(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], toTheLibrary: Bool = false, in harness: Harness) throws -> Route {
        let window = harness.window
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false, keyCode: keyCode))
        // 1. Local monitors see the event before anything else. Which of the
        // monitors runs first is not defined, so a probe monitor cannot say
        // whether the library's took it. The library's own effect can: its
        // history moved. (The keys that only the library uses are sent
        // without dispatching further, and their effects are asserted.)
        let before = libraryFingerprint(harness)
        NSApp.sendEvent(event)
        defer { spin(0.15) }
        if toTheLibrary || libraryFingerprint(harness) != before { return .monitor }
        guard flags.contains(.command) else { return .nobody }
        // 2. A command key is offered to the window's views.
        if window.performKeyEquivalent(with: event) { return .viewKeyEquivalent }
        // 3. Then the Edit menu: Undo / Redo go to the first responder.
        if keyCode == 6 {
            let action = Selector(flags.contains(.shift) ? "redo:" : "undo:")
            if window.firstResponder?.tryToPerform(action, with: nil) == true { return .firstResponder }
        }
        return .nobody
    }

    private func editorText(_ harness: Harness) -> String {
        harness.controller.active?.engine.plainText ?? ""
    }

    /// Opens `id` in the editor with the caret in its text.
    private func openAndFocus(_ id: UUID, in harness: Harness) throws -> NoteEditorTextView {
        XCTAssertTrue(harness.controller.open(noteID: id))
        harness.controller.dismissLibrary()
        spin(0.4)
        let textView = try XCTUnwrap(harness.controller.active?.engine.textView)
        XCTAssertTrue(harness.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        return textView
    }

    /// Selects `B` in All notes with ↓ from the open note `A` (the first row)
    /// and deletes it with ⌘⌫, all through real key events.
    private func deleteSecondRowFromLibrary(in harness: Harness, opening first: UUID, deleting second: UUID) throws {
        _ = try openAndFocus(first, in: harness)
        XCTAssertTrue(harness.controller.showLibrary())
        spin(0.4)
        try press("\u{F701}", keyCode: 125, toTheLibrary: true, in: harness)
        try press("\u{7F}", keyCode: 51, .command, toTheLibrary: true, in: harness)
        XCTAssertNil(harness.store.note(withID: second), "the row was deleted")
        XCTAssertNotNil(harness.store.note(withID: first))
    }

    // MARK: Delete B, return to the same A, type, Undo

    func testTypingUndoAfterDeletingAnotherNoteAndReturningToTheSameNoteUndoesTheTyping() throws {
        let (harness, ids) = try makeHarness(titles: ["Beta", "Alpha"])
        let (beta, alpha) = (ids[0], ids[1])
        try deleteSecondRowFromLibrary(in: harness, opening: alpha, deleting: beta)
        let toast = try XCTUnwrap(harness.toasts.current, "the delete posted its toast")
        XCTAssertEqual(toast.message, "Note deleted")
        XCTAssertFalse(toast.answersUndoKey, "Notes' toast never takes ⌘Z")
        let step = try XCTUnwrap(harness.controller.libraryUndoStepID)

        // Esc goes back to the same note A: its session id did not change.
        try press("\u{1B}", keyCode: 53, toTheLibrary: true, in: harness)
        spin(0.4)
        XCTAssertEqual(harness.controller.active?.noteID, alpha)
        XCTAssertFalse(harness.controller.isLibraryPresented)
        XCTAssertNil(harness.toasts.current, "the toast does not follow the person into the note")

        let textView = try XCTUnwrap(harness.controller.active?.engine.textView)
        XCTAssertTrue(harness.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.insertText(" typed", replacementRange: textView.selectedRange())
        XCTAssertTrue(editorText(harness).contains("typed"))

        let route = try press("z", keyCode: 6, .command, in: harness)
        XCTAssertEqual(route, .firstResponder, "⌘Z is the text's")
        XCTAssertFalse(editorText(harness).contains("typed"), "the typing was undone")
        XCTAssertNil(harness.store.note(withID: beta), "the delete was not undone by the typing's ⌘Z")
        XCTAssertEqual(harness.controller.libraryUndoStepID, step, "and it is still the library's next Undo")
    }

    /// The bug itself: a delete toast on screen while the caret is in the
    /// note. The toast's button must not answer ⌘Z; the same press with a
    /// toast that does claim the key (Tasks') is taken by the view hierarchy,
    /// which shows this harness can see the difference.
    func testAToastThatDoesNotClaimTheKeyLeavesCommandZToTheText() throws {
        let (harness, ids) = try makeHarness(titles: ["Alpha"])
        let textView = try openAndFocus(ids[0], in: harness)
        textView.insertText(" more", replacementRange: textView.selectedRange())
        var fired = 0

        harness.toasts.show("Note deleted", answersUndoKey: false) { fired += 1 }
        spin()
        XCTAssertNotNil(harness.toasts.current)
        XCTAssertEqual(try press("z", keyCode: 6, .command, in: harness), .firstResponder)
        XCTAssertEqual(fired, 0, "the toast's action did not run")
        XCTAssertFalse(editorText(harness).contains("more"))

        // Control: Tasks' toast keeps ⌘Z, and takes it before the text.
        textView.insertText(" again", replacementRange: textView.selectedRange())
        harness.toasts.show("Task deleted") { fired += 1 }
        spin()
        XCTAssertEqual(try press("z", keyCode: 6, .command, in: harness), .viewKeyEquivalent)
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(editorText(harness).contains("again"), "so the text kept its typing")
    }

    // MARK: Search-field Undo while a delete toast is visible

    func testSearchFieldUndoWhileTheDeleteToastShowsUndoesTheSearchTextThenTheLibrary() throws {
        let (harness, ids) = try makeHarness(titles: ["Beta", "Alpha"])
        let (beta, alpha) = (ids[0], ids[1])
        try deleteSecondRowFromLibrary(in: harness, opening: alpha, deleting: beta)
        XCTAssertNotNil(harness.toasts.current)

        try press("f", keyCode: 3, .command, toTheLibrary: true, in: harness)
        spin(0.6)
        let field = try XCTUnwrap(harness.window.firstResponder as? NSTextView, "the search field has the keyboard")
        field.insertText("zzq", replacementRange: NSRange(location: 0, length: field.string.utf16.count))
        field.breakUndoCoalescing()
        XCTAssertEqual(field.string, "zzq")
        XCTAssertTrue(field.undoManager?.canUndo == true)
        XCTAssertNotNil(harness.toasts.current, "the toast is still on screen")

        // First ⌘Z: the field's text. The toast and the library stay put.
        XCTAssertEqual(try press("z", keyCode: 6, .command, in: harness), .firstResponder)
        XCTAssertEqual(field.string, "", "the search text was undone")
        XCTAssertNil(harness.store.note(withID: beta), "the deleted note stayed deleted")

        // Second ⌘Z: the field has nothing left, so the library answers.
        XCTAssertEqual(try press("z", keyCode: 6, .command, in: harness), .monitor)
        XCTAssertNotNil(harness.store.note(withID: beta), "the library's Undo restored the note")
    }

    // MARK: The last row, after the toast has gone

    func testUndoOfDeletingTheLastNoteWorksFromTheEmptyLibraryAfterTheToastExpires() throws {
        let (harness, ids) = try makeHarness(titles: ["Only"])
        let only = ids[0]
        _ = try openAndFocus(only, in: harness)
        XCTAssertTrue(harness.controller.showLibrary())
        spin(0.4)
        try press("\u{7F}", keyCode: 51, .command, toTheLibrary: true, in: harness)
        XCTAssertNil(harness.store.note(withID: only), "the last note is deleted")
        XCTAssertTrue(harness.controller.isLibraryPresented)
        XCTAssertNotNil(harness.toasts.current)

        // The toast expires: the empty library has no row to right-click.
        harness.toasts.dismiss()
        spin()
        XCTAssertNil(harness.toasts.current)
        XCTAssertTrue(harness.store.notes.isEmpty)

        // The library's own commands (its background menu) offer Undo and
        // Redo with no row: enabled and named for the step.
        var commands = NotesEditorPage.historyCommands(for: harness.controller)
        let undo = try XCTUnwrap(commands.first { $0.identifier == NotesLibraryView.undoIdentifier })
        XCTAssertEqual(undo.title, "Undo Delete Note")
        XCTAssertFalse(undo.isDisabled)

        // The key: ⌘Z with no field text goes to the library's history.
        XCTAssertEqual(try press("z", keyCode: 6, .command, in: harness), .monitor)
        XCTAssertNotNil(harness.store.note(withID: only), "the note is back")

        // And through the menu command, Redo then Undo again.
        commands = NotesEditorPage.historyCommands(for: harness.controller)
        XCTAssertTrue(NotesLibraryView.run(NotesLibraryView.redoIdentifier, in: commands))
        XCTAssertNil(harness.store.note(withID: only), "Redo deleted it again")
        commands = NotesEditorPage.historyCommands(for: harness.controller)
        XCTAssertTrue(NotesLibraryView.run(NotesLibraryView.undoIdentifier, in: commands))
        XCTAssertNotNil(harness.store.note(withID: only), "Undo from the menu command restored it")
    }
}

private struct KeyboardUndoRoot: View {
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var store: NoteStore
    @ObservedObject var toasts: PanelToastCenter
    let size: CGSize
    @StateObject private var uiState = PanelUIState()

    var body: some View {
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        NotesEditorPage(controller: noteDraft.pages, noteStore: store, noteDraft: noteDraft, uiState: uiState, layout: layout)
            .environment(\.atticPanelToasts, toasts)
            .overlay(alignment: .bottom) {
                // The shell's toast, so its button (and any key it claims)
                // is in the window's views as in the panel.
                PanelNoticeStack(toasts: toasts, notice: nil, onRetry: {}, onDismissNotice: {})
                    .padding(.bottom, 60)
            }
            .frame(width: size.width, height: size.height)
    }
}
