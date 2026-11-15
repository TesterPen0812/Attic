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
        guard let object = element as? NSObject, object.responds(to: NSSelectorFromString("accessibilityValue")) else { return nil }
        return object.value(forKey: "accessibilityValue") as? String
    }

    /// The real panel on Notes with one note open whose body says "quote"
    /// three times.
    private func withNote(document: NoteDocument? = nil, _ body: (_ host: AtticPanelHostingView, _ panel: NSPanel, _ draft: NoteDraftController,
                                   _ engine: NoteEditorEngine, _ library: () -> NotesLibraryModel?) throws -> Void) throws {
        let suite = "AdaptiveFind.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        _ = try notes.createDocumentNote(id: id, document: document ?? NoteDocument(blocks: [
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
        engine.find.inputSourceIdentifier = { "com.apple.keylayout.ABC" }
        try body(host, panel, draft, engine, { library.value })
    }

    // MARK: The row

    func testFindOpensInTheTopRowFoldsTheRowAndLeavesTheNoteStill() throws {
        try withNote { host, _, _, engine, _ in
            let layout = PanelPageLayout(cornerSize: 52, panelSize: host.bounds.size)
            let scroll = try XCTUnwrap(engine.scrollView)
            let insetBefore = scroll.contentInsets.top
            for id in ["panel-pin-button", "panel-more-button", "notes-search-button"] {
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
            for id in ["panel-pin-button", "panel-more-button", "notes-search-button", "notes-header-title"] {
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
            for id in ["panel-pin-button", "panel-more-button", "notes-search-button"] {
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

    func testNB2FindOwnsItsPersistentNativeClientBeforePublishingOpen() throws {
        try requireKeyWindowTests()
        try withNote { host, panel, _, engine, _ in
            panel.makeKeyAndOrderFront(nil)
            let note = try XCTUnwrap(engine.textView)
            XCTAssertTrue(panel.makeFirstResponder(note))
            let original = engine.document()
            let field = try XCTUnwrap(descendants(of: host).compactMap { $0 as? AtticNativeSearchInput.Field }
                .first { $0.accessibilityIdentifier() == NoteFindController.fieldIdentifier },
                "the real Find field must already be attached while closed")
            let identity = ObjectIdentifier(field)
            XCTAssertFalse(engine.find.isShown)
            NSApp.sendEvent(key(3, "f", flags: .command, in: panel))
            XCTAssertTrue(engine.find.isShown)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            XCTAssertTrue(panel.firstResponder === editor, "ownership must be synchronous, not a later mounting retry")
            NSApp.sendEvent(key(0, "a", in: panel))
            XCTAssertEqual(editor.string, "a")
            NSApp.sendEvent(key(53, "\u{1b}", in: panel))
            spin(0.5)
            XCTAssertFalse(engine.find.isShown)
            let closedField = try XCTUnwrap(descendants(of: host).compactMap { $0 as? AtticNativeSearchInput.Field }
                .first { $0.accessibilityIdentifier() == NoteFindController.fieldIdentifier })
            XCTAssertEqual(ObjectIdentifier(closedField), identity)
            NSApp.sendEvent(key(3, "f", flags: .command, in: panel))
            XCTAssertTrue(panel.firstResponder === editor, "reopening reuses the same native input client")
            XCTAssertEqual(engine.document(), original)
        }
    }

    func testNB6BurstAfterNativeCommandFindNeverLeaksIntoTheNote() throws {
        try requireKeyWindowTests()
        try withNote { _, panel, _, engine, _ in
            panel.makeKeyAndOrderFront(nil)
            let view = try XCTUnwrap(engine.textView)
            XCTAssertTrue(panel.makeFirstResponder(view))
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            let beforeControl = engine.textStorage.string
            NSApp.sendEvent(key(6, "z", in: panel))
            XCTAssertEqual(engine.textStorage.string, beforeControl + "z", "prove NSApp delivered native input before testing ownership")
            let original = engine.document()
            NSApp.sendEvent(key(3, "f", flags: .command, in: panel))
            XCTAssertTrue(engine.find.isShown, "NSApp delivered Command-F before the burst")
            for _ in 0..<300 { NSApp.sendEvent(key(0, "a", in: panel)) }
            XCTAssertEqual(engine.document(), original, "all forwarded events are really delivered; no cap may release typing into the note")
            XCTAssertEqual(engine.find.query, String(repeating: "a", count: 300))
            XCTAssertTrue(engine.find.isShown)
            spin(1.2)
            NSApp.sendEvent(key(11, "b", in: panel))
            XCTAssertEqual(engine.document(), original, "no expiry may release later typing")
            XCTAssertEqual(engine.find.query, String(repeating: "a", count: 300) + "b")
        }
    }

    func testNB1MarkedFindReturnAndEscapeStayWithTheNativeInputClient() throws {
        try requireKeyWindowTests()
        for (code, characters) in [(UInt16(36), "\r"), (UInt16(53), "\u{1b}")] {
            try withNote { host, panel, _, engine, _ in
                panel.makeKeyAndOrderFront(nil)
                let plain = NSTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
                plain.stringValue = "quote"
                let nativePanel = NSPanel(contentRect: CGRect(x: -4000, y: -4000, width: 220, height: 50),
                    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
                nativePanel.isReleasedWhenClosed = false
                nativePanel.contentView = plain
                nativePanel.makeKeyAndOrderFront(nil)
                defer { nativePanel.contentView = nil; nativePanel.close() }
                XCTAssertTrue(nativePanel.makeFirstResponder(plain))
                let native = try XCTUnwrap(plain.currentEditor() as? NSTextView)
                native.setMarkedText("quote", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 5))
                NSApp.sendEvent(key(code, characters, in: nativePanel))
                let expectedText = native.string, expectedMarked = native.hasMarkedText()
                nativePanel.orderOut(nil)
                panel.makeKeyAndOrderFront(nil)
                XCTAssertTrue(panel.makeFirstResponder(engine.textView))
                NSApp.sendEvent(key(3, "f", flags: .command, in: panel))
                spin(0.1)
                engine.find.query = "quote"
                spin(0.1)
                let field = try XCTUnwrap(descendants(of: host).compactMap { $0 as? AtticNativeSearchInput.Field }
                    .first { $0.accessibilityIdentifier() == NoteFindController.fieldIdentifier })
                XCTAssertTrue(panel.makeFirstResponder(field))
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                editor.setMarkedText("quote", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 5))
                XCTAssertTrue(editor.hasMarkedText())
                XCTAssertTrue(engine.find.isShown, "Find is open before the marked event")
                let index = engine.find.index, original = engine.document()
                NSApp.sendEvent(key(code, characters, in: panel))
                XCTAssertTrue(engine.find.isShown, "candidate Escape must not close Find")
                XCTAssertEqual(engine.find.index, index, "candidate Return must not also navigate")
                XCTAssertEqual(editor.string, expectedText)
                XCTAssertEqual(editor.hasMarkedText(), expectedMarked, "the same native input client processing must occur")
                XCTAssertEqual(engine.document(), original)
            }
        }
    }

    func testNB1QueryNavigationRemainsOrderedAndKeepsFindFocusForTableMatches() throws {
        try requireKeyWindowTests()
        let document = NoteDocument(blocks: [.text("Title"), .text("a"), .table(NoteTable(texts: [["a"]]))])
        try withNote(document: document) { _, panel, _, engine, _ in
            panel.makeKeyAndOrderFront(nil)
            XCTAssertTrue(panel.makeFirstResponder(engine.textView))
            let original = engine.document()
            NSApp.sendEvent(key(3, "f", flags: .command, in: panel))
            NSApp.sendEvent(key(0, "a", in: panel))
            XCTAssertEqual(engine.find.query, "a")
            XCTAssertEqual(engine.find.matches.count, 2)
            XCTAssertEqual(engine.find.index, 0)
            NSApp.sendEvent(key(36, "\r", in: panel))
            XCTAssertEqual(engine.find.query, "a", "navigation observes only input preceding Return")
            XCTAssertEqual(engine.find.index, 1)
            XCTAssertNotNil(engine.find.matches.last?.tableID)
            let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
            let field = try XCTUnwrap(editor.delegate as? NSTextField)
            XCTAssertEqual(field.accessibilityIdentifier(), NoteFindController.fieldIdentifier,
                           "the owner requires Find focus even when the match is in a table")
            NSApp.sendEvent(key(11, "b", in: panel))
            XCTAssertEqual(engine.find.query, "ab")
            XCTAssertEqual(engine.document(), original)
            spin(0.7)
            XCTAssertEqual(engine.find.query, "ab")
            XCTAssertEqual(engine.document(), original)
        }
    }

    func testNB3NonASCIICommandMatchesNativeInterpretationWithoutPhysicalCutFallback() throws {
        try requireKeyWindowTests()
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        AtticNativeSearchInput.QueryCell.makeFieldEditorForTesting = {
            let editor = IsolatedClipboardEditor(usingTextLayoutManager: false)
            editor.clipboard = clipboard
            return editor
        }
        defer { AtticNativeSearchInput.QueryCell.makeFieldEditorForTesting = nil }
        try withNote { host, panel, _, engine, _ in
            panel.makeKeyAndOrderFront(nil)
            let plain = NSTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
            plain.cell = AtticNativeSearchInput.QueryCell(textCell: "token")
            plain.isEditable = true
            plain.isSelectable = true
            plain.stringValue = "token"
            let nativePanel = NSPanel(contentRect: CGRect(x: -4000, y: -4000, width: 220, height: 50),
                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            nativePanel.isReleasedWhenClosed = false
            nativePanel.contentView = plain
            nativePanel.makeKeyAndOrderFront(nil)
            defer { nativePanel.contentView = nil; nativePanel.close() }
            clipboard.clearContents(); clipboard.setString("sentinel", forType: .string)
            XCTAssertTrue(nativePanel.makeFirstResponder(plain))
            let native = try XCTUnwrap(plain.currentEditor() as? NSTextView)
            native.selectAll(nil)
            NSApp.sendEvent(key(7, "ф", flags: .command, ignoring: "ф", in: nativePanel))
            let expectedText = native.string
            let expectedClipboard = clipboard.string(forType: .string)
            nativePanel.orderOut(nil)
            panel.makeKeyAndOrderFront(nil)
            XCTAssertTrue(panel.makeFirstResponder(engine.textView))
            let original = engine.document()
            engine.find.query = "token"
            clipboard.clearContents(); clipboard.setString("sentinel", forType: .string)
            NSApp.sendEvent(key(3, "f", flags: .command, in: panel))
            NSApp.sendEvent(key(7, "ф", flags: .command, ignoring: "ф", in: panel))
            spin(0.8)
            XCTAssertEqual(engine.find.query, expectedText)
            XCTAssertEqual(clipboard.string(forType: .string), expectedClipboard)
            XCTAssertEqual(engine.document(), original)
        }
    }

    // MARK: First-key speed

    func testBG72ComposingDeadKeyBeforeFindFieldMountsStaysWithNativeInput() throws {
        try withNote { host, panel, _, engine, _ in
            let original = engine.textStorage.string
            panel.makeFirstResponder(engine.textView)
            engine.find.show()
            // A dead key can have no characters. Keep it through the field
            // handoff, then finish the composition in the native editor.
            let deadKey = key(14, "", flags: .option)
            let finishingKey = key(14, "e")
            XCTAssertTrue(engine.find.typeAhead(deadKey), "Find must capture the composing dead key")
            XCTAssertEqual(engine.find.query, "", "an unfinished composition must not be inserted as plain text")
            XCTAssertEqual(engine.textStorage.string, original, "the composing sequence must not edit the note")
            spin(0.8)
            let field = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == NoteFindController.fieldIdentifier })
            let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
            XCTAssertTrue(editor.delegate as? NSTextField === field)
            editor.interpretKeyEvents([finishingKey])
            spin(0.2)
            let acrossHandoff = editor.string
            XCTAssertFalse(acrossHandoff.isEmpty, "composition completes in Find")
            XCTAssertEqual(engine.find.query, acrossHandoff, "Find must search the native editor's composed value")

            // The exact same events must be interpreted the same way when
            // both arrive at the already-mounted editor (input-source safe).
            let native = try XCTUnwrap(field as? AtticNativeSearchInput.Field)
            let updates = native.representableUpdateCount
            engine.find.query = ""
            // Begin the comparison after the outside clear reaches AppKit;
            // until then, the previous composition's late-commit guard applies.
            let deadline = Date().addingTimeInterval(1)
            repeat { spin(0.01) }
            while (native.representableUpdateCount == updates || !editor.string.isEmpty) && Date() < deadline
            XCTAssertGreaterThan(native.representableUpdateCount, updates, "the native field applied the outside clear")
            XCTAssertEqual(editor.string, "", "the comparison starts with the cleared native field")
            editor.string = ""
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.interpretKeyEvents([deadKey, finishingKey])
            spin(0.2)
            XCTAssertEqual(acrossHandoff, editor.string, "the handoff preserves native input-method composition")
            XCTAssertEqual(engine.textStorage.string, original, "no composing key changes the note body")
            XCTAssertFalse(engine.find.typeAhead(key(0, "a")), "the field owns subsequent input")
        }
    }

    /// A marked-text (Japanese or Chinese style) composition in the mounted
    /// field stays with the input context: Find's type-ahead never claims its
    /// keys, and only the committed text becomes the query. A unit test cannot
    /// switch the input source, so the marked text is driven through the
    /// field editor's own NSTextInputClient entry points.
    func testBG72MarkedTextCompositionInTheMountedFieldStaysWithNativeInput() throws {
        try withNote { host, panel, _, engine, _ in
            let original = engine.textStorage.string
            panel.makeFirstResponder(engine.textView)
            engine.find.show()
            spin(0.8)
            let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
            let notFound = NSRange(location: NSNotFound, length: 0)
            editor.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: notFound)
            XCTAssertTrue(editor.hasMarkedText(), "the composition is under way")
            XCTAssertFalse(engine.find.typeAhead(key(0, "n")), "Find never claims keys once the field owns input")
            editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: notFound)
            XCTAssertTrue(editor.hasMarkedText())
            editor.insertText("日本", replacementRange: notFound)
            spin(0.2)
            XCTAssertFalse(editor.hasMarkedText(), "the candidate committed")
            XCTAssertEqual(engine.find.query, "日本", "Find searches what the input method committed")
            XCTAssertEqual(engine.textStorage.string, original, "the composition never edits the note")
        }
    }

    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [], ignoring: String? = nil, in panel: NSPanel) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                         isARepeat: false, keyCode: code)!
    }

    /// Round 2, Dot R-2: ⌘F then ⌘V before Find's field has mounted pasted
    /// over the note's selection. The field takes the paste; the note, its
    /// saved document and its Undo stack are left as they were.
    func testPasteWhileFindsFieldMountsGoesToTheFieldNeverTheNote() throws {
        try requireKeyWindowTests()
        try withNote { host, panel, draft, engine, _ in
            panel.makeKeyAndOrderFront(nil)
            let view = try XCTUnwrap(engine.textView)
            XCTAssertTrue(panel.makeFirstResponder(view))
            let original = engine.textStorage.string
            let saved = engine.document()
            let undoBefore = engine.history.undoOps.map(ObjectIdentifier.init)
            let redoBefore = engine.history.redoOps.map(ObjectIdentifier.init)
            let session = try XCTUnwrap(draft.pages.active)
            view.setSelectedRange((original as NSString).range(of: "quotes"))
            let board = NSPasteboard.general
            let kept = board.string(forType: .string)
            defer { board.clearContents(); if let kept { board.setString(kept, forType: .string) } }
            board.clearContents()
            board.setString("warm", forType: .string)
            let formerMenu = NSApp.mainMenu
            let menu = NSMenu()
            let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            edit.submenu = NSMenu(title: "Edit")
            let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            paste.target = view // the selected note is the pending handoff's responder
            edit.submenu?.addItem(paste)
            menu.addItem(edit)
            NSApp.mainMenu = menu
            defer { NSApp.mainMenu = formerMenu }
            // Enter the exact local-monitor callback, then let AppKit deliver
            // any unclaimed event through the native menu and editor.
            @MainActor func send(_ event: NSEvent) {
                if let forwarded = engine.find.routeKeyDown(event), !menu.performKeyEquivalent(with: forwarded) {
                    NSApp.sendEvent(forwarded)
                }
            }
            send(key(3, "f", flags: .command, in: panel))
            XCTAssertTrue(engine.find.isShown, "⌘F opens Find through the note's key monitor")
            // No run-loop turn: the field has not mounted yet. The separate
            // failed-mount regression covers expiry and discarding queued input.
            send(key(9, "v", flags: .command, in: panel))
            XCTAssertEqual(engine.textStorage.string, original, "the note's selection is not replaced")
            spin(0.8)
            let field = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == NoteFindController.fieldIdentifier }, "the top row's field")
            XCTAssertEqual(engine.textStorage.string, original)
            XCTAssertEqual(engine.document(), saved, "the saved document is unchanged")
            XCTAssertTrue(draft.pages.save(session))
            XCTAssertEqual(draft.pages.store.loadDocument(noteID: session.noteID)?.content.document, saved,
                           "saving during the handoff preserves the document")
            XCTAssertEqual(engine.history.undoOps.map(ObjectIdentifier.init), undoBefore, "the Undo stack is unchanged")
            XCTAssertEqual(engine.history.redoOps.map(ObjectIdentifier.init), redoBefore, "the Redo stack is unchanged")
            XCTAssertEqual(engine.find.query, "warm", "the clipboard text is the query")
            XCTAssertEqual(field.stringValue, "warm")
            engine.find.close(returnFocus: false)
        }
    }

    func testEditingCommandsWhileFindMountsAreClaimedForTheField() throws {
        try requireKeyWindowTests()
        try withNote { _, panel, _, engine, _ in
            panel.makeKeyAndOrderFront(nil)
            let view = try XCTUnwrap(engine.textView)
            XCTAssertTrue(panel.makeFirstResponder(view))
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertFalse(engine.history.undoOps.isEmpty, "the note has an Undo step to protect")
            let board = NSPasteboard.general
            let kept = board.string(forType: .string)
            defer { board.clearContents(); if let kept { board.setString(kept, forType: .string) } }
            board.clearContents()
            board.setString("field input", forType: .string)
            let original = engine.document()
            let undo = engine.history.undoOps.map(ObjectIdentifier.init)
            let historyLog = engine.history.log
            let priorChange = engine.onTextChange
            var changes = 0
            engine.onTextChange = { changes += 1; priorChange?() }
            defer { engine.onTextChange = priorChange }
            engine.find.show()
            for (code, characters, flags) in [
                (UInt16(0), "a", NSEvent.ModifierFlags.command), (7, "x", .command),
                (8, "c", .command), (6, "z", .command), (6, "z", [.command, .shift]),
                (51, "\u{7f}", []), (117, "\u{f728}", []), (51, "\u{7f}", .option),
                (9, "v", [.command, .option, .shift])
            ] {
                XCTAssertNil(engine.find.routeKeyDown(key(code, characters, flags: flags, in: panel)),
                             "editing key \(code) is claimed while the field mounts")
            }
            XCTAssertNotNil(engine.find.routeKeyDown(key(1, "s", flags: .command, in: panel)),
                            "global commands retain their routing")
            XCTAssertNotNil(engine.find.routeKeyDown(key(8, "c", flags: [.command, .option, .shift], in: panel)),
                            "Copy as Markdown remains a global note command")
            XCTAssertEqual(engine.document(), original)
            spin(0.8)
            XCTAssertEqual(engine.document(), original, "replaying editing commands never changes the note")
            XCTAssertEqual(engine.history.undoOps.map(ObjectIdentifier.init), undo)
            XCTAssertEqual(engine.history.log, historyLog)
            XCTAssertEqual(changes, 0, "Find's Undo/Redo must not traverse the note, even if both would cancel out")
            engine.find.close(returnFocus: false)
        }
    }

    /// Round 2, Opus R-6: plain keys typed ahead are one search each. The
    /// field takes the query as it stands; it does not interpret the keys a
    /// second time (another search per key at the handoff).
    func testPlainKeysTypedAheadRunOneSearchEachAcrossTheHandoff() throws {
        try withNote { host, panel, _, engine, _ in
            panel.makeFirstResponder(engine.textView)
            engine.find.show()
            let base = engine.find.refreshCount
            for (code, characters) in [(UInt16(11), "b"), (31, "o"), (16, "y"), (14, "e")] {
                XCTAssertTrue(engine.find.typeAhead(key(code, characters)))
            }
            XCTAssertEqual(engine.find.refreshCount - base, 4, "one search per typed key")
            spin(0.8)
            XCTAssertEqual(engine.find.refreshCount - base, 4, "mounting the field starts no second search per key")
            let field = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == NoteFindController.fieldIdentifier })
            let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
            XCTAssertEqual(field.stringValue, "boye")
            XCTAssertEqual(editor.string, "boye")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0), "the caret after what was typed")
            XCTAssertEqual(engine.find.query, "boye")
            engine.find.close(returnFocus: false)
        }
    }

    /// Round 2, Opus R-8: an input method's keys typed before the field
    /// mounts stay with native input. The raw letters are never the query
    /// (nothing searches "ni"), the composition is marked text in the field
    /// editor, and only the committed text becomes the query. The field
    /// editor here composes the way an input method does (the key events
    /// make marked text); a unit test cannot switch the real input source.
    func testBG72InputMethodKeysBeforeTheFieldMountsNeverSearchTheRawLetters() throws {
        try withNote { host, panel, _, engine, _ in
            let original = engine.textStorage.string
            AtticNativeSearchInput.QueryCell.makeFieldEditorForTesting = { ComposingEditor(usingTextLayoutManager: false) }
            defer { AtticNativeSearchInput.QueryCell.makeFieldEditorForTesting = nil }
            engine.find.inputSourceIdentifier = { "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese" }
            engine.find.query = "quote"
            var queries: [String] = []
            let observation = engine.find.$query.sink { queries.append($0) }
            defer { observation.cancel() }
            panel.makeFirstResponder(engine.textView)
            engine.find.show()
            let base = engine.find.refreshCount
            XCTAssertTrue(engine.find.typeAhead(key(45, "n")), "Find holds the key for the field")
            XCTAssertTrue(engine.find.typeAhead(key(34, "i")))
            XCTAssertEqual(engine.find.query, "quote", "the raw letters are not the query")
            XCTAssertEqual(engine.find.refreshCount, base, "nothing searched the raw letters")
            XCTAssertEqual(engine.textStorage.string, original, "the note is untouched")
            spin(0.8)
            let editor = try XCTUnwrap(panel.firstResponder as? ComposingEditor, "the field's editor has the keyboard")
            XCTAssertEqual(editor.romaji, "ni", "the typed-ahead keys went to the editor, not the query")
            XCTAssertTrue(editor.hasMarkedText(), "the pre-mount keys are still a native marked composition")
            let field = try XCTUnwrap(editor.delegate as? AtticNativeSearchInput.Field)
            let updates = field.representableUpdateCount
            engine.find.refresh() // nonempty query publishes matches and runs updateNSView while marked
            spin(0.1)
            XCTAssertGreaterThan(field.representableUpdateCount, updates, "the guarded representable path actually ran")
            XCTAssertTrue(editor.hasMarkedText(), "a binding refresh must not cancel the native composition")
            XCTAssertEqual(editor.string, "に")
            XCTAssertTrue(queries.allSatisfy { $0 == "quote" }, "no intermediate marked text is searched: \(queries)")
            XCTAssertFalse(queries.contains("ni"), "no search of the raw romaji at any point: \(queries)")
            editor.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
            spin(0.2)
            XCTAssertFalse(editor.hasMarkedText(), "the candidate committed")
            XCTAssertEqual(engine.find.query, "日本", "Find searches what the input method committed")
            XCTAssertEqual(engine.textStorage.string, original)
            engine.find.close(returnFocus: false)
        }
    }

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

    func testR3NativeEditingSelectorsDuringFindHandoffNeverEditTheNote() throws {
        try requireKeyWindowTests()
        try withNote { host, panel, _, engine, _ in
            panel.makeKeyAndOrderFront(nil)
            let view = try XCTUnwrap(engine.textView)
            let original = engine.document()
            let undo = engine.history.undoOps.map(ObjectIdentifier.init)
            final class NativeOracle: NSTextView {
                var receivedCommand = false
                override func doCommand(by selector: Selector) {
                    receivedCommand = true
                    super.doCommand(by: selector)
                }
            }
            let chords: [(UInt16, String, NSEvent.ModifierFlags)] = [
                (51, "\u{7f}", .command), (51, "\u{7f}", [.option, .command]),
                (40, "\u{b}", .control), (4, "\u{8}", .control), (2, "\u{4}", .control),
                (0, "\u{1}", .control), (14, "\u{5}", .control),
                (123, "\u{f702}", [.option, .shift]), (124, "\u{f703}", .command)
            ]
            for (code, characters, flags) in chords {
                XCTAssertTrue(panel.makeFirstResponder(view))
                view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
                engine.find.query = "old query"
                let open = key(3, "f", flags: .command, in: panel)
                XCTAssertNil(engine.find.routeKeyDown(open))
                let event = key(code, characters, flags: flags, ignoring: [40: "k", 4: "h", 2: "d", 0: "a", 14: "e"][Int(code)], in: panel)
                let oracle = NativeOracle(usingTextLayoutManager: false)
                oracle.isFieldEditor = true
                oracle.string = "old query"
                oracle.selectAll(nil)
                oracle.interpretKeyEvents([event])
                let forwarded = engine.find.routeKeyDown(event)
                if oracle.receivedCommand {
                    XCTAssertNil(forwarded, "native editing selector for code \(code), \(flags.rawValue) belongs to Find")
                } else {
                    XCTAssertNotNil(forwarded, "an unbound chord is not a native editing command on this Mac")
                }
                if let forwarded { panel.sendEvent(forwarded) }
                XCTAssertEqual(engine.document(), original, "no handoff key changes note bytes")
                spin(0.65)
                let field = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSTextField }
                    .first { $0.accessibilityIdentifier() == NoteFindController.fieldIdentifier })
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                XCTAssertEqual(editor.string, oracle.string, "native command acts on the eventual query")
                XCTAssertEqual(editor.selectedRange(), oracle.selectedRange())
                XCTAssertEqual(engine.document(), original)
                XCTAssertEqual(engine.history.undoOps.map(ObjectIdentifier.init), undo)
                engine.find.close()
                spin(0.1)
            }
            XCTAssertTrue(panel.makeFirstResponder(view))
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            XCTAssertNil(engine.find.routeKeyDown(key(3, "f", flags: .command, in: panel)))
            // Keep both the field's mount and its expiry timer off the run loop.
            Thread.sleep(forTimeInterval: 1.05)
            let late = engine.find.routeKeyDown(key(51, "\u{7f}", flags: .command, in: panel))
            XCTAssertNil(late, "an editing key that discovers expiry still cannot reach the note")
            if let late { panel.sendEvent(late) }
            XCTAssertFalse(engine.find.isShown)
            XCTAssertEqual(engine.document(), original)
            XCTAssertEqual(engine.history.undoOps.map(ObjectIdentifier.init), undo)
        }
    }

    func testR3NonLatinMenuEquivalentWhileFindMountsPastesOnlyIntoFind() throws {
        try requireKeyWindowTests()
        try withNote { _, panel, _, engine, _ in
            panel.makeKeyAndOrderFront(nil)
            let view = try XCTUnwrap(engine.textView)
            XCTAssertTrue(panel.makeFirstResponder(view))
            view.selectAll(nil)
            let original = engine.document()
            let undo = engine.history.undoOps.map(ObjectIdentifier.init)
            let board = NSPasteboard.general
            let kept = board.string(forType: .string)
            defer { board.clearContents(); if let kept { board.setString(kept, forType: .string) } }
            board.clearContents(); board.setString("new query", forType: .string)
            let oldMenu = NSApp.mainMenu
            let menu = NSMenu()
            let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "м")
            paste.target = view
            menu.addItem(paste)
            NSApp.mainMenu = menu
            defer { NSApp.mainMenu = oldMenu }
            XCTAssertNil(engine.find.routeKeyDown(key(3, "f", flags: .command, in: panel)))
            XCTAssertNotNil(engine.find.routeKeyDown(key(0, "q", flags: .command, in: panel)),
                            "a logical global equivalent on a remapped Latin layout is not Select All")
            let event = key(9, "м", flags: .command, in: panel)
            let forwarded = engine.find.routeKeyDown(event)
            XCTAssertNil(forwarded, "physical V is Paste on a non-Latin layout")
            if let forwarded, !menu.performKeyEquivalent(with: forwarded) { panel.sendEvent(forwarded) }
            spin(0.7)
            XCTAssertEqual(engine.find.query, "new query")
            XCTAssertEqual(engine.document(), original)
            XCTAssertEqual(engine.history.undoOps.map(ObjectIdentifier.init), undo)
            engine.find.close(returnFocus: false)
        }
    }

    func testR3ReturnWaitsForQueuedPasteBeforeRevealingATableMatch() throws {
        try requireKeyWindowTests()
        try withNote(document: NoteDocument(blocks: [.text("Title"), .text("new query"),
                .table(NoteTable(texts: [["old query", "other"]]))])) { _, panel, _, engine, _ in
            panel.makeKeyAndOrderFront(nil)
            let view = try XCTUnwrap(engine.textView)
            XCTAssertTrue(panel.makeFirstResponder(view))
            engine.find.show()
            spin(0.65)
            engine.find.query = "old query"
            XCTAssertNotNil(engine.find.matches.first?.tableID)
            engine.find.close()
            spin(0.15)
            let original = engine.document()
            let board = NSPasteboard.general
            let kept = board.string(forType: .string)
            defer { board.clearContents(); if let kept { board.setString(kept, forType: .string) } }
            board.clearContents(); board.setString("new query", forType: .string)
            for event in [key(3, "f", flags: .command, in: panel),
                          key(9, "v", flags: .command, in: panel), key(36, "\r", in: panel)] {
                if let forwarded = engine.find.routeKeyDown(event) { panel.sendEvent(forwarded) }
            }
            spin(0.8)
            XCTAssertEqual(engine.find.query, "new query", "the queued paste is applied before navigation")
            XCTAssertNil(engine.find.matches.first?.tableID, "navigation uses the new matches")
            XCTAssertTrue(engine.find.fieldFocused, "the stale table match must not take focus")
            XCTAssertTrue((panel.firstResponder as? NSTextView)?.isFieldEditor == true)
            XCTAssertEqual(engine.document(), original)
            engine.find.close(returnFocus: false)
        }
    }

    func testR3MissingFindFieldExpiresWithoutReplayingIntoTheNote() throws {
        try requireKeyWindowTests()
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("Body")]))
        let (scroll, view) = engine.makeView()
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let panel = KeyPanel(contentRect: CGRect(x: -4000, y: -4000, width: 320, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = scroll; panel.makeKeyAndOrderFront(nil)
        defer { engine.detachView(); panel.contentView = nil; panel.close() }
        engine.find.inTopRow = true
        engine.find.inputSourceIdentifier = { "com.apple.keylayout.ABC" }
        XCTAssertTrue(panel.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        XCTAssertNil(engine.find.routeKeyDown(key(3, "f", flags: .command, in: panel)))
        XCTAssertNil(engine.find.routeKeyDown(key(0, "a", in: panel)))
        spin(1.1)
        let event = key(11, "b", in: panel)
        if let forwarded = engine.find.routeKeyDown(event) { panel.sendEvent(forwarded) }
        XCTAssertEqual(engine.document().blocks.last?.text, "Bodyb", "typing resumes after the bounded handoff")
        // A field appearing late never replays the held 'a' into the note.
        engine.find.topRowFieldAppeared()
        XCTAssertEqual(engine.document().blocks.last?.text, "Bodyb")
        XCTAssertFalse(engine.find.isShown, "failed mounting ends Find instead of invisibly retaining input")
    }

    func testR3PendingFindInputHasABoundedQueue() throws {
        try requireKeyWindowTests()
        try withNote { _, panel, _, engine, _ in
            panel.makeKeyAndOrderFront(nil)
            XCTAssertTrue(panel.makeFirstResponder(engine.textView))
            let original = engine.document()
            engine.find.inputHandoffUptime = { 0 } // This guard must not pass because of the time bound.
            engine.find.show()
            // No run-loop turn: the field cannot mount. Exceed the input cap.
            for index in 0..<1024 {
                if index % 32 == 0 {
                    XCTAssertNotNil(engine.find.routeKeyDown(key(1, "s", flags: .command, in: panel)),
                                    "a full queue must still let genuine global shortcuts through")
                }
                _ = engine.find.routeKeyDown(key(0, "a", flags: .command, in: panel))
            }
            XCTAssertFalse(engine.find.isShown, "a failed mount cannot retain an unbounded queue")
            XCTAssertEqual(engine.document(), original, "overflow discards pending edits")
        }
    }

    func testR3NoteFormattingDuringFindHandoffNeverChangesTheNote() throws {
        try requireKeyWindowTests()
        try withNote { _, panel, _, engine, _ in
            panel.makeKeyAndOrderFront(nil)
            let view = try XCTUnwrap(engine.textView)
            XCTAssertTrue(panel.makeFirstResponder(view))
            view.selectAll(nil)
            let original = engine.document()
            let undo = engine.history.undoOps.map(ObjectIdentifier.init)
            for event in [key(3, "f", flags: .command, in: panel), key(11, "b", flags: .command, in: panel)] {
                if let forwarded = engine.find.routeKeyDown(event) { panel.sendEvent(forwarded) }
            }
            XCTAssertEqual(engine.document(), original, "a local formatting shortcut is not a global command during Find handoff")
            XCTAssertEqual(engine.history.undoOps.map(ObjectIdentifier.init), undo)
            spin(0.65)
            XCTAssertEqual(engine.document(), original)
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
            library()?.clearSearch()
            draft.pages.dismissLibrary()
            spin(1.0)
            XCTAssertTrue(draft.pages.showLibrary())
            spin(1.0)
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


/// A deterministic input-method driver for the real field's native
/// NSTextInputClient. No input source or system setting is changed.
private final class ComposingEditor: NSTextView {
    var romaji = ""
    override func interpretKeyEvents(_ events: [NSEvent]) {
        for event in events { romaji += event.characters ?? "" }
        let marked = romaji == "ni" ? "に" : romaji
        setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
                      replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

/// Redirect only Cut's clipboard destination to an isolated fixture board.
/// Native event interpretation and selection/deletion are shared by both
/// compared clients; the owner's general clipboard is never read or changed.
private final class IsolatedClipboardEditor: NSTextView {
    var clipboard: NSPasteboard?
    override func cut(_ sender: Any?) {
        guard let clipboard, writeSelection(to: clipboard, types: [.string]) else { return }
        delete(sender)
    }
}
