import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The combined Tasks + Notes app's fix round (CU reviews of 2026-10-03):
/// the Notes page hosted as the panel hosts it, in a window that is never
/// shown or made key.
@MainActor
final class CombinedFixRoundTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private struct Harness {
        let window: NSWindow
        let host: NSView
        let store: NoteStore
        let noteDraft: NoteDraftController
        @MainActor var controller: NotesPageController { noteDraft.pages }
    }

    private let gate = PersistenceGate()

    /// A key panel that never activates the app (CI's key-window tests).
    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private func makeHarness(context: AtticDesignContext = AtticDesignContext(controls: .craft), keyPanel: Bool = false,
                             seed: (NoteStore) throws -> Void = { _ in }) throws -> Harness {
        let gate = gate
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        try seed(store)
        let noteDraft = NoteDraftController(noteStore: store)
        let size = CGSize(width: 320, height: 520)
        let root = CombinedFixNotesRoot(noteDraft: noteDraft, store: store, uiState: PanelUIState(),
                                        toasts: PanelToastCenter(), size: size)
            .atticDesign(context)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)
        let frame = CGRect(origin: CGPoint(x: -4000, y: -4000), size: size)
        let window = keyPanel
            ? KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        if keyPanel { window.makeKey() }
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        spin()
        host.layoutSubtreeIfNeeded()
        spin()
        return Harness(window: window, host: host, store: store, noteDraft: noteDraft)
    }

    private func type(_ text: String, into textView: NSTextView) {
        for character in text {
            if character == "\n" {
                textView.insertNewline(nil)
            } else {
                textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    private func fixtures() throws -> (image: URL, file: URL) {
        let directory = ownedTemporaryDirectory(prefix: "AtticCombinedFix")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("CU2-image-fixture.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 30).fill()
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let file = directory.appendingPathComponent("CU2-file-fixture.txt")
        try Data("A disposable file for the combined fix round.\n".utf8).write(to: file)
        return (image, file)
    }

    // MARK: P2-01: the title's placeholder is redrawn away

    /// TextKit 2 draws the text in its own fragment views, so typing never
    /// redraws the text view's own layer, where "Title" is drawn. The first
    /// character (typed or pasted) must invalidate the whole placeholder,
    /// not only the caret's old strip, or "Title" stays under the title;
    /// emptying the title draws it again.
    func testTheTitlePlaceholderIsRedrawnAwayWhenTheTitleGetsText() throws {
        let harness = try makeHarness()
        XCTAssertTrue(harness.controller.requestNewNote())
        spin(0.4)
        let engine = try XCTUnwrap(harness.controller.active?.engine)
        let textView = try XCTUnwrap(engine.textView)
        harness.window.makeFirstResponder(textView)
        XCTAssertEqual(engine.textStorage.length, 0)
        let font = engine.style.titleFont
        let width = ("Title" as NSString).size(withAttributes: [.font: font]).width
        let origin = textView.textContainerOrigin
        // The placeholder's last letters, well clear of the caret's strip.
        let tail = NSRect(x: origin.x + width * 0.6, y: origin.y + 2, width: width * 0.4, height: font.capHeight)
        let recorder = DisplayInvalidationRecorder(textView)
        defer { recorder.stop() }
        func covered() -> Bool { recorder.rects.contains { $0.contains(tail) } }
        for entry in ["typed", "pasted"] {
            harness.host.layoutSubtreeIfNeeded()
            textView.display()
            recorder.rects.removeAll()
            if entry == "typed" {
                textView.insertText("C", replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                XCTAssertTrue(engine.pastePlainText("CU2 rendering probe", at: NSRange(location: 0, length: 0)))
            }
            harness.host.layoutSubtreeIfNeeded()
            XCTAssertTrue(covered(), "\(entry): the placeholder's whole line is redrawn: \(recorder.rects)")
            textView.display()
            recorder.rects.removeAll()
            textView.selectAll(nil)
            textView.deleteBackward(nil)
            harness.host.layoutSubtreeIfNeeded()
            XCTAssertEqual(engine.textStorage.length, 0)
            XCTAssertTrue(covered(), "\(entry): emptied, the placeholder is drawn again in full: \(recorder.rects)")
        }
    }


    // MARK: P3-01: `/image` and `/file` are consumed

    /// SwiftUI clears the importer's presentation binding before it calls
    /// the completion: the request it was opened for must survive that.
    func testTheOpenPanelKeepsWhatItWasOpenedForUntilItsCompletion() {
        let chrome = NotesPageChrome()
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title")]))
        let slash = NotesPageChrome.FileRequest.slash(NoteSlashFileTicket(sessionID: UUID(), request: engine.requestSlashFile(
            for: NoteSlashSession(noteID: engine.noteID, range: NSRange(location: 0, length: 0), query: "image"))))
        chrome.fileRequest = slash
        chrome.fileRequest = nil // the binding, as the panel closes
        XCTAssertEqual(chrome.takeFileRequest(), slash)
        XCTAssertNil(chrome.takeFileRequest(), "taken once")
        XCTAssertNil(chrome.fileRequest)
        chrome.fileRequest = .insert
        XCTAssertEqual(chrome.takeFileRequest(), .insert, "with the binding not yet cleared")
        XCTAssertNil(chrome.fileRequest)
        let id = UUID()
        chrome.fileRequest = .locate(id)
        chrome.fileRequest = nil
        XCTAssertEqual(chrome.takeFileRequest(), .locate(id))
    }

    /// The `/` Image or File… row replaces its typed command with the
    /// picture or the file card, at a line's start or after text, as the
    /// other `/` rows consume theirs.
    func testSlashImageAndSlashFileReplaceTheirCommand() throws {
        let harness = try makeHarness()
        XCTAssertTrue(harness.controller.requestNewNote())
        spin(0.4)
        let engine = try XCTUnwrap(harness.controller.active?.engine)
        let textView = try XCTUnwrap(engine.textView)
        harness.window.makeFirstResponder(textView)
        let (image, file) = try fixtures()
        // The open panel is the page's; the test answers for it.
        var request: NoteSlashFileRequest?
        engine.onSlashFileRequest = { request = $0 }
        let sessionID = try XCTUnwrap(harness.controller.active).id
        func ticket() throws -> NoteSlashFileTicket { NoteSlashFileTicket(sessionID: sessionID, request: try XCTUnwrap(request)) }
        type("Attachments\nBefore the image ", into: textView)
        type("/image", into: textView)
        XCTAssertTrue(engine.acceptSlashItem(.imageOrFile))
        harness.controller.importSlashImage(image, for: try ticket())
        for _ in 0..<60 where !engine.textStorage.string.contains(NoteDocument.objectCharacter) { spin(0.05) }
        XCTAssertEqual(engine.textStorage.string, "Attachments\nBefore the image \n\(NoteDocument.objectCharacter)\n")
        type("/file", into: textView)
        XCTAssertTrue(engine.acceptSlashItem(.imageOrFile))
        harness.controller.importSlashImage(file, for: try ticket())
        for _ in 0..<60 where engine.textStorage.string.filter({ $0 == NoteDocument.objectCharacter }).count < 2 { spin(0.05) }
        let text = engine.textStorage.string
        XCTAssertFalse(text.contains("/image") || text.contains("/file"), text.debugDescription)
        XCTAssertEqual(text, "Attachments\nBefore the image \n\(NoteDocument.objectCharacter)\n\(NoteDocument.objectCharacter)\n")
        let blocks = engine.document().blocks
        XCTAssertEqual(blocks.filter { $0.kind == .image }.count, 1)
        XCTAssertEqual(blocks.filter { $0.kind == .file }.count, 1)
        XCTAssertNil(harness.controller.active?.notice)
        // One Undo takes the file back out and leaves the typed `/file`.
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.textStorage.string.hasSuffix("/file"), engine.textStorage.string.debugDescription)
    }

    // MARK: P3-02: clean previews in All notes

    /// A row's preview is the note's text, not its Markdown: the CU review
    /// saw `## Section Alpha - Bullet one - Bullet two 1. N…`.
    @MainActor
    func testLibraryPreviewsShowCleanText() {
        var heading = NoteBlock.text("Section Alpha")
        heading.style = "heading"
        heading.level = 2
        func styled(_ text: String, _ style: String) -> NoteBlock {
            var block = NoteBlock.text(text)
            block.style = style
            return block
        }
        let document = NoteDocument(blocks: [
            .text("CU2 formats"), heading, styled("Bullet one", "bullet"), styled("Bullet two", "bullet"),
            styled("Number one", "number"), styled("A quote", "quote"), styled("let x = 1", "mono"),
            .checklist("Milk"), .text("Plain line")
        ])
        let summary = NoteRowSummary(document: document, filename: { _ in nil })
        XCTAssertEqual(summary.preview, "Section Alpha Bullet one, Bullet two, Number one A quote let x = 1 Milk Plain line")
    }

    // MARK: P3-03: the tag picker's create row is never cut short

    /// The card opens at its rows' width; typing "cu2" adds "New tag
    /// “#cu2”", wider than "#cu2shared": the card grows for it (CU pass 2,
    /// capture 51: "New tag “#c…" in a half-empty card).
    func testTheTagPickerGrowsForItsCreateRow() throws {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 340, height: 560),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 560))
        window.orderFrontRegardless()
        windows.append(window)
        let anchor = NSView(frame: CGRect(x: 40, y: 400, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        let tags = ["cu2shared", "cuqa"]
        presenter.content = AnyView(TaskTagPickerView(allTags: tags, state: { _ in .off }, onToggle: { _ in },
                                                      onCreate: { _, _ in true }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.3)
        let opened = presenter.cardWidth
        let m = AtticDropdownMetrics.self
        XCTAssertGreaterThanOrEqual(opened + 0.5, AtticTagPicker.rowsWidth(tags: tags, create: nil) + m.inset * 2,
                                    "the rows fit as it opens")
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("cu2", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.3)
        let needed = AtticTagPicker.rowsWidth(tags: ["cu2shared"], create: "cu2") + m.inset * 2
        XCTAssertGreaterThan(needed, opened, "the create row is wider than the card it opened as")
        XCTAssertGreaterThanOrEqual(presenter.cardWidth + 0.5, needed, "the card grew for “New tag “#cu2””")
        let host = try XCTUnwrap(presenter.host)
        XCTAssertEqual(host.contentRect.width, presenter.cardWidth, accuracy: 1)
        // Filtering back to fewer, shorter rows never narrows it while open.
        editor.deleteBackward(nil)
        spin(0.3)
        XCTAssertGreaterThanOrEqual(presenter.cardWidth + 0.5, needed)
    }

    // MARK: P2-03: Notes ⋯ → Tags… is the shared E1 tag picker

    private func tagHarness(keyPanel: Bool) throws -> (Harness, NoteSession, AtticDropdownPresenter) {
        let harness = try makeHarness(keyPanel: keyPanel) { store in
            _ = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Plan"), .text("Body")]),
                                         tags: ["launch-october"])
            _ = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Other"), .text("Body")]),
                                         tags: ["launch", "kyoto"])
            _ = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Third"), .text("Body")]),
                                         tags: ["launch"])
        }
        let note = try XCTUnwrap(harness.store.notes.first { $0.title == "Plan" })
        XCTAssertTrue(harness.controller.open(noteID: note.id))
        spin(0.4)
        let session = try XCTUnwrap(harness.controller.active)
        let anchor = NSView(frame: CGRect(x: 200, y: 440, width: 28, height: 28))
        harness.host.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        presenter.label = "Tags"
        presenter.content = AnyView(NoteTagEditor(session: session, store: harness.store) {})
        presenter.present(from: anchor)
        spin(0.4)
        return (harness, session, presenter)
    }

    private func accessibilityElements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { accessibilityElements($0 as AnyObject) }
    }

    /// The note's tag editor is the shared E1 card (an opaque card in the
    /// panel's overlay, not a translucent arrow popover): the note's own
    /// tags first, then by count, each with its count; ticks are marks.
    func testTheNoteTagEditorIsTheSharedE1Card() throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let (_, _, presenter) = try tagHarness(keyPanel: false)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        let host = try XCTUnwrap(presenter.host)
        XCTAssertTrue(presenter.isOpen)
        let items = accessibilityElements(host).compactMap { $0 as? AtticDropdownMenuItem.ItemView }
        XCTAssertEqual(items.compactMap { $0.accessibilityLabel() }, ["#launch-october, 1", "#launch, 2", "#kyoto, 1"],
                       "the note's tag first, then by count, as the tag editor listed them")
        XCTAssertTrue(items.allSatisfy { !$0.isAccessibilitySelected() }, "an empty field lights nothing")
        // Typing lights the exact tag, never the note's own tag listed first.
        let launch = [AtticTagPicker.Tag(name: "launch-october", state: .on), AtticTagPicker.Tag(name: "launch", state: .off)]
        XCTAssertEqual(AtticTagPickerCard.exactMatch("#Launch", in: launch), 1)
        XCTAssertNil(AtticTagPickerCard.exactMatch("laun", in: launch))
        XCTAssertNil(AtticTagPickerCard.exactMatch("", in: launch))
    }

    func testTheOpenNoteE1CardUsesTheSharedInventoryWhenTaskTagsChange() throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let (harness, _, presenter) = try tagHarness(keyPanel: false)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        let tasks = TaskStore(container: harness.store.container)
        let library = AtticLibrary(tasks: tasks, notes: harness.store)
        let model = TasksPageModel(library: library)
        let host = try XCTUnwrap(presenter.host)
        func labels() -> [String] {
            accessibilityElements(host).compactMap { ($0 as? AtticDropdownMenuItem.ItemView)?.accessibilityLabel() }
        }
        XCTAssertEqual(model.cachedTags, library.tags.names) // Warm the composer before the edit.
        let task = try XCTUnwrap(tasks.create(title: "Task-only tag"))
        XCTAssertTrue(tasks.setTags(["cu2taskonly", "launch"], for: task))
        spin(0.4)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(labels(), ["#launch-october, 1", "#launch, 3", "#cu2taskonly, 1", "#kyoto, 1"],
                       "the already-open E1 card refreshes from the cross-page inventory")
        XCTAssertEqual(AtticTagSuggestion.make(typed: try XCTUnwrap(AtticTag.normalize("#CU2TaskOnly")),
                                               counts: harness.store.tagCounts, excluding: []),
                       [AtticTagSuggestion(name: "cu2taskonly", count: 1, isNew: false)])
        XCTAssertEqual(Set(model.tagChoices(for: [task.id])), Set(library.tags.names))
        XCTAssertEqual(Set(model.composerTagChoices), Set(library.tags.names))
        XCTAssertTrue(model.cachedTags.contains("kyoto"), "the warm composer includes note-only tags")
        XCTAssertTrue(tasks.setTags([], for: task))
        spin(0.4)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(labels(), ["#launch-october, 1", "#launch, 2", "#kyoto, 1"],
                       "removing the last task use removes it from the open card")
        withExtendedLifetime(library) {}
    }

    /// The keyboard model, with real key events to a key panel (CI only,
    /// `ATTIC_KEY_WINDOW_TESTS`): ↓ ↓ Return toggles the highlighted tag,
    /// typing lights the exact tag, a new name is added, Esc closes. The CU
    /// review found ↓ ↓ Return moved nothing in the old popover.
    func testTheNoteTagEditorKeysOnAKeyPanel() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("CI only: real key events need a key panel, which locally would take the keyboard")
        }
        let (harness, session, presenter) = try tagHarness(keyPanel: true)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        let window = harness.window
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true, "the tag field has the keyboard")
        func deliver(_ events: [NSEvent]) {
            events.forEach { NSApp.postEvent($0, atStart: false) }
            var count = 0
            while count < 64, let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
                count += 1
            }
            spin(0.2)
        }
        func press(_ characters: String, _ code: UInt16) {
            deliver([NSEvent.EventType.keyDown, .keyUp].map { type in
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            })
        }
        func setQuery(_ text: String) {
            guard let editor = window.firstResponder as? NSTextView else { return XCTFail("the field lost the keyboard") }
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            spin(0.2)
        }
        press("\u{F701}", 125)
        press("\u{F701}", 125)
        press("\r", 36)
        XCTAssertEqual(Set(session.engine.tags), ["launch-october", "launch"], "↓ ↓ Return added the highlighted tag")
        setQuery("kyoto")
        press("\r", 36)
        XCTAssertEqual(Set(session.engine.tags), ["launch-october", "launch", "kyoto"])
        setQuery("launch")
        press("\r", 36)
        XCTAssertEqual(Set(session.engine.tags), ["launch-october", "kyoto"], "Return took the exact tag off")
        // The rows reorder (the note's own tags first); the highlight stays
        // on `#launch`, so Return again adds it back and never touches
        // `#launch-october` (fix round 2, review P2). Space under Full
        // Keyboard Access presses the same highlight.
        press("\r", 36)
        XCTAssertEqual(Set(session.engine.tags), ["launch-october", "kyoto", "launch"], "Return again: the same tag")
        press("\r", 36)
        XCTAssertEqual(Set(session.engine.tags), ["launch-october", "kyoto"])
        // A prefix lights "New tag" for what was typed, never the first match.
        setQuery("launch-oct")
        press("\r", 36)
        XCTAssertEqual(Set(session.engine.tags), ["launch-october", "kyoto", "launch-oct"], "a prefix adds what was typed")
        setQuery("paris")
        press("\r", 36)
        XCTAssertEqual(Set(session.engine.tags), ["launch-october", "kyoto", "launch-oct", "paris"], "a new name is added")
        press("\u{1B}", 53)
        spin(0.3)
        XCTAssertFalse(presenter.isOpen, "Esc closed it")
    }

    // MARK: P2-02: D1 in Notes

    /// The fade's geometry for the Notes page in a 320 × 520 panel: nothing
    /// shows over the header's controls or under the bottom row; the title's
    /// resting line and the last resting line are fully there.
    func testTheNotesFadeEndsBeforeTheControls() {
        let size = CGSize(width: 320, height: 520)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        let restTop = layout.headerBottom + AtticNoteMetrics.titleTopGap
        let bottomControls = layout.chromeInsets.bottom + AtticControlSize.panelButton.height
        let stops = AtticControlsFade.stops(height: size.height, restTop: restTop, bottomControls: bottomControls)
        func opacity(at y: CGFloat) -> Double {
            let location = y / size.height
            guard let upper = stops.firstIndex(where: { $0.location >= location }) else { return stops.last!.opacity }
            guard upper > 0 else { return stops[0].opacity }
            let a = stops[upper - 1], b = stops[upper]
            let t = b.location > a.location ? Double((location - a.location) / (b.location - a.location)) : 1
            return a.opacity + (b.opacity - a.opacity) * t
        }
        for y in stride(from: 0, through: layout.headerBottom, by: 1) {
            XCTAssertEqual(opacity(at: y), 0, accuracy: 0.001, "nothing under the header's controls at \(y)")
        }
        XCTAssertEqual(opacity(at: restTop), 1, accuracy: 0.001, "the title's resting line is fully there")
        let barTop = size.height - bottomControls
        let lastRest = size.height - (bottomControls + AtticSpacing.s12)
        XCTAssertEqual(opacity(at: lastRest), 1, accuracy: 0.001, "the last resting line is fully there")
        for y in stride(from: barTop, through: size.height, by: 1) {
            XCTAssertEqual(opacity(at: y), 0, accuracy: 0.001, "nothing under the bottom row at \(y)")
        }
        XCTAssertGreaterThan(opacity(at: barTop - 3), 0)
        XCTAssertLessThan(opacity(at: barTop - 3), 1, "a short eased ramp before the bottom row")
    }

    /// The fade reaches the AppKit editor: SwiftUI masks the platform view
    /// (the edge veils it replaces were drawn over the text, which stayed
    /// readable under the controls).
    func testTheNoteEditorIsMaskedByTheFade() throws {
        let harness = try makeHarness()
        XCTAssertTrue(harness.controller.requestNewNote())
        spin(0.5)
        let textView = try XCTUnwrap(harness.controller.active?.engine.textView)
        var masked = false
        var view: NSView? = textView.superview
        while let current = view, current !== harness.host {
            if let mask = current.layer?.mask, mask.bounds.height >= 500 { masked = true }
            view = current.superview
        }
        XCTAssertTrue(masked, "a full-height mask over the note's scroll view")
    }

    // MARK: P1-01: inserting a file after an image froze the app

    /// The CU sequence in the whole panel, as the app hosts it (its pages,
    /// its overlay layer), on a key panel with accessibility on (an AX
    /// client, as the CU tool is): `/image` then `/file` through the page's
    /// open-panel route (the open panel's key loss and return included),
    /// then ⋯ Insert's batch path with an image and a file. The CU build
    /// froze at 100 % CPU in SwiftUI's key-view-loop rebuild during the
    /// second insertion; a watchdog ends the run if the main thread sticks.
    /// CI only (`ATTIC_KEY_WINDOW_TESTS`): it needs a key window.
    func testImageThenFileInsertionNeverSticksTheMainThread() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("CI only: the freeze needs a key panel, which locally would take the keyboard")
        }
        let watchdog = Watchdog(seconds: 90, label: "the image-then-file insertion (CU P1-01)")
        defer { watchdog.finish() }
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        UserDefaults.standard.set(true, forKey: NotesEditorSetting.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: NotesEditorSetting.defaultsKey) }
        let suite = "CombinedFixRoundTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let noteDraft = NoteDraftController(noteStore: notes)
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(
                store: store, noteStore: notes,
                canvasSession: CanvasSession(store: CanvasStore(container: container)),
                noteDraft: noteDraft,
                chromeInteractionState: chrome, uiState: state, settings: settings,
                subtaskPanels: SubtaskPanelController(store: store, uiState: state, settings: settings),
                tasksPageState: TasksPageState()
            ),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome
        )
        let content = AtticPanelContentContainer(hostingView: host, visibleSize: size, perimeter: 0)
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.orderFront(nil)
        panel.makeKey()
        // Stands in for the open panel: it takes the key and gives it back.
        let chooser = KeyPanel(contentRect: CGRect(x: -3000, y: -3000, width: 200, height: 120),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        chooser.isReleasedWhenClosed = false
        windows += [panel, chooser]
        defer {
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            spin(0.3)
        }
        spin(1.0)
        state.selectSection(.notes)
        spin(1.0)
        let controller = noteDraft.pages
        XCTAssertTrue(controller.requestNewNote())
        spin(0.5)
        let engine = try XCTUnwrap(controller.active?.engine)
        let textView = try XCTUnwrap(engine.textView)
        panel.makeFirstResponder(textView)
        let (image, file) = try fixtures()
        var request: NoteSlashFileRequest?
        func choose(_ url: URL, slash: Bool) {
            chooser.orderFront(nil)
            chooser.makeKey()
            spin(0.3)
            chooser.orderOut(nil)
            panel.makeKey()
            panel.makeFirstResponder(textView)
            if slash, let request, let session = controller.active {
                controller.importSlashImage(url, for: NoteSlashFileTicket(sessionID: session.id, request: request))
            } else {
                controller.importFiles([url])
            }
            for _ in 0..<60 where controller.active?.isImporting == true { spin(0.05) }
            content.layoutSubtreeIfNeeded()
            spin(0.5)
        }
        // The page's open panel is answered by the test.
        engine.onSlashFileRequest = { request = $0 }
        type("CU2 attachment retry\nBefore the image ", into: textView)
        type("/image", into: textView)
        spin(0.3)
        XCTAssertTrue(engine.acceptSlashItem(.imageOrFile))
        choose(image, slash: true)
        type("/file", into: textView)
        spin(0.3)
        XCTAssertTrue(engine.acceptSlashItem(.imageOrFile))
        choose(file, slash: true)
        XCTAssertEqual(engine.textStorage.string.filter { $0 == NoteDocument.objectCharacter }.count, 2)
        // ⋯ Insert › Image or File…: the batch path, an image then a file.
        choose(image, slash: false)
        choose(file, slash: false)
        XCTAssertEqual(engine.textStorage.string.filter { $0 == NoteDocument.objectCharacter }.count, 4)
        XCTAssertFalse(engine.textStorage.string.contains("/image") || engine.textStorage.string.contains("/file"))
    }

    // MARK: - Fix round 2 (GPT-6.1 review of 6aaec55)

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// P2 (`8008974`): a slow image pick, then another `/file` before the
    /// image has loaded. The late image must not replace the newer command,
    /// and the first request's cancel must not cancel the newer one.
    func testALateSlashCompletionNeverTakesANewerRequest() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Plan"), .text("Body")])) else {
            return XCTFail("seed")
        }
        let (image, file) = try fixtures()
        let data = try Data(contentsOf: image)
        let staged = StagedNoteAttachment(id: UUID(), filename: "late.png", contentTypeIdentifier: "public.png",
                                          byteCount: Int64(data.count), digest: "", data: data)
        let gate = SlowLoadGate()
        let controller = NotesPageController(store: store, journal: nil, imageLoader: { _ in
            await gate.wait()
            return (staged, CGSize(width: 40, height: 30))
        })
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let engine = session.engine
        let (_, view) = engine.makeView()
        var requests: [NoteSlashFileRequest] = []
        engine.onSlashFileRequest = { requests.append($0) }
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        type("\n/image", into: view)
        XCTAssertTrue(engine.acceptSlashItem(.imageOrFile))
        let first = try XCTUnwrap(requests.last)
        controller.importSlashImage(image, for: NoteSlashFileTicket(sessionID: session.id, request: first))
        // Before the image has loaded: another `/` Image or File….
        type(" /fi", into: view)
        XCTAssertTrue(engine.acceptSlashItem(.imageOrFile))
        let second = try XCTUnwrap(requests.last)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(engine.isPending(first), "typing on abandoned the first request")
        first.cancel()
        XCTAssertTrue(engine.isPending(second), "the first request's cancel leaves the newer one")
        await gate.release()
        await waitUntil { session.notice != nil }
        XCTAssertNotNil(session.notice, "the late image says it was not added")
        XCTAssertEqual(engine.textStorage.string, "Plan\nBody\n/image /fi", "the late image replaced nothing")
        XCTAssertTrue(engine.isPending(second), "and left the newer request waiting for its file")
        session.notice = nil
        controller.importSlashImage(file, for: NoteSlashFileTicket(sessionID: session.id, request: second))
        await waitUntil { engine.textStorage.string.contains(NoteDocument.objectCharacter) }
        XCTAssertEqual(engine.textStorage.string, "Plan\nBody\n/image \n\(NoteDocument.objectCharacter)\n",
                       "the file replaced its own command only")
        XCTAssertEqual(engine.document().blocks.filter { $0.kind == .file }.count, 1)
        XCTAssertEqual(engine.document().blocks.filter { $0.kind == .image }.count, 0)
        XCTAssertNil(session.notice)
    }

    /// A completion for a note that is no longer on screen is dropped.
    func testASlashCompletionForAnotherSessionIsDropped() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Plan"), .text("Body")])) else {
            return XCTFail("seed")
        }
        let controller = NotesPageController(store: store, journal: nil)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let engine = session.engine
        let (_, view) = engine.makeView()
        var request: NoteSlashFileRequest?
        engine.onSlashFileRequest = { request = $0 }
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        type("\n/file", into: view)
        XCTAssertTrue(engine.acceptSlashItem(.imageOrFile))
        let (_, file) = try fixtures()
        // The ticket names a different session (the panel was opened from another note).
        controller.importSlashImage(file, for: NoteSlashFileTicket(sessionID: UUID(), request: try XCTUnwrap(request)))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(engine.textStorage.string, "Plan\nBody\n/file")
        XCTAssertTrue(engine.isPending(try XCTUnwrap(request)), "a stale completion cancels nothing")
    }

    /// P2 (`bdadf46`): the highlight is the tag, not the row number. Typing
    /// "launch" lights `#launch` (second, under the note's own
    /// `#launch-october`); pressing it adds it, Notes lists it first, and
    /// the highlight must follow it, so a second Return would take it off
    /// again rather than remove `#launch-october`. A prefix lights only
    /// "New tag", never the first match.
    func testTheTagHighlightFollowsItsTagWhenTheRowsReorder() throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let (harness, session, presenter) = try tagHarness(keyPanel: false)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        let host = try XCTUnwrap(presenter.host)
        func items() -> [AtticDropdownMenuItem.ItemView] {
            accessibilityElements(host).compactMap { $0 as? AtticDropdownMenuItem.ItemView }
        }
        func lit() -> [String] { items().filter { $0.isAccessibilitySelected() }.compactMap { $0.accessibilityLabel() } }
        func setQuery(_ text: String) throws {
            let editor = try XCTUnwrap(harness.window.firstResponder as? NSTextView, "the tag field has the keyboard")
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            spin(0.3)
        }
        try setQuery("launch")
        XCTAssertEqual(items().compactMap { $0.accessibilityLabel() }, ["#launch-october, 1", "#launch, 2"])
        XCTAssertEqual(lit(), ["#launch, 2"], "the exact tag, though the note's own tag is listed first")
        let launch = try XCTUnwrap(items().first { $0.accessibilityLabel() == "#launch, 2" })
        XCTAssertTrue(launch.accessibilityPerformPress())
        spin(0.3)
        XCTAssertEqual(Set(session.engine.tags), ["launch-october", "launch"])
        XCTAssertEqual(items().compactMap { $0.accessibilityLabel() }.first, "#launch, 2", "the rows reordered")
        XCTAssertEqual(lit(), ["#launch, 2"], "the highlight followed its tag, not its row number")
        try setQuery("launch-oct")
        XCTAssertEqual(lit(), ["New tag “#launch-oct”"], "a prefix lights what was typed, never the first match")
        try setQuery("")
        XCTAssertEqual(lit(), [], "an empty field lights nothing")
    }

    /// The tag picker's highlight rule, for both pages.
    func testTheTagPickerHighlightRule() {
        typealias H = AtticTagPickerHighlight
        let tags = [AtticTagPicker.Tag(name: "launch-october", state: .on), AtticTagPicker.Tag(name: "launch", state: .off)]
        XCTAssertEqual(H.typed("#Launch", in: tags, create: nil), .tag("launch"), "exact, `#` and case aside")
        XCTAssertEqual(H.typed("laun", in: tags, create: "laun"), .create)
        XCTAssertNil(H.typed("laun", in: tags, create: nil), "a prefix never lights a tag")
        XCTAssertNil(H.typed("", in: tags, create: nil))
        XCTAssertNil(H.typed("#", in: tags, create: nil))
        let reordered = Array(tags.reversed())
        XCTAssertEqual(H.tag("launch").index(in: tags, create: nil), 1)
        XCTAssertEqual(H.tag("launch").index(in: reordered, create: nil), 0, "found again by name")
        XCTAssertNil(H.tag("kyoto").index(in: tags, create: nil), "filtered away: nothing lit")
        XCTAssertEqual(H.create.index(in: tags, create: "x"), 2)
        XCTAssertNil(H.create.index(in: tags, create: nil))
        XCTAssertEqual(H.at(0, in: tags, create: nil), .tag("launch-october"))
        XCTAssertEqual(H.at(2, in: tags, create: "x"), .create)
        XCTAssertNil(H.at(2, in: tags, create: nil))
        XCTAssertNil(H.at(nil, in: tags, create: "x"))
    }

    /// P3 (`d5e2c0d`): previews drop formatting from the blocks' kinds and
    /// marks, never by stripping patterns from the text.
    func testPreviewsKeepLiteralTextAndDropOnlyFormatting() throws {
        func styled(_ text: String, _ style: String) -> NoteBlock {
            var block = NoteBlock.text(text)
            block.style = style
            return block
        }
        var bold = NoteBlock.text("Bold words stay")
        bold.marks = [NoteMark(.bold, offset: 0, length: 4)]
        var heading = styled("#launch plan", "heading")
        heading.level = 2
        let document = NoteDocument(blocks: [
            .text("Literal text"),
            styled("def __init__(self):", "mono"),
            .text("See https://example.com/__v1__/docs"),
            .text("- typed dash, not a list"),
            .text("2 * 3 = 6 and *stars*"),
            bold, heading,
            styled("Oat milk", "bullet"), styled("Lemons", "number"),
            .checklist("Milk", checked: true), .checklist("Rice"),
            .divider()
        ])
        let expected = "def __init__(self): See https://example.com/__v1__/docs - typed dash, not a list 2 * 3 = 6 and *stars* "
            + "Bold words stay #launch plan Oat milk, Lemons, Milk, Rice"
        let draft = NoteRowSummary(document: document, filename: { _ in nil })
        XCTAssertEqual(draft.preview, expected)
        XCTAssertEqual(draft.checklist?.done, 1)
        XCTAssertEqual(draft.checklist?.total, 2)
        // A stored note reads its document the same way (not its derived text).
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: document) else { return XCTFail("seed") }
        let note = try XCTUnwrap(store.note(withID: id))
        XCTAssertTrue(note.plainText.contains("    def __init__"), "the derived text keeps its markers")
        let stored = NoteRowSummary(note: note, attachments: [])
        XCTAssertEqual(stored, draft)
        // A legacy note's text is shown as written.
        let legacy = try XCTUnwrap(store.create(title: "Legacy", body: "- typed\n__init__ and **this**"))
        XCTAssertEqual(NoteRowSummary(note: legacy, attachments: []).preview, "- typed __init__ and **this**")
    }

    /// P1-01 hypothesis: an overlay host joins, moves between or leaves
    /// parents only outside AppKit's layout pass; inside one it only moves.
    func testOverlayHierarchyChangesWaitForTheEndOfALayoutPass() {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        window.contentView = content
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let other = NSView(frame: NSRect(x: 50, y: 40, width: 200, height: 200))
        content.addSubview(parent)
        content.addSubview(other)
        let view = NSView()
        let a = NSRect(x: 10, y: 10, width: 40, height: 20), b = NSRect(x: 20, y: 30, width: 40, height: 20)
        AtticOverlayHierarchy.layoutPass { AtticOverlayHierarchy.place(view, in: parent, frame: a) }
        XCTAssertNil(view.superview, "no parent change inside a layout pass")
        AtticOverlayHierarchy.layoutPass { AtticOverlayHierarchy.place(view, in: parent, frame: b) }
        XCTAssertEqual(AtticOverlayHierarchy.pendingCount, 1, "coalesced")
        spin(0.05)
        XCTAssertTrue(view.superview === parent)
        XCTAssertEqual(view.frame, b, "the latest request wins")
        AtticOverlayHierarchy.layoutPass { AtticOverlayHierarchy.place(view, in: parent, frame: a) }
        XCTAssertEqual(view.frame, a, "already there: it moves at once")
        XCTAssertEqual(AtticOverlayHierarchy.pendingCount, 0)
        // A move to another parent keeps its place on screen while it waits.
        let target = NSRect(x: 5, y: 5, width: 40, height: 20)
        AtticOverlayHierarchy.layoutPass { AtticOverlayHierarchy.place(view, in: other, frame: target) }
        XCTAssertTrue(view.superview === parent)
        XCTAssertEqual(view.frame, parent.convert(target, from: other))
        spin(0.05)
        XCTAssertTrue(view.superview === other)
        XCTAssertEqual(view.frame, target)
        // Leaving waits too, hidden at once.
        AtticOverlayHierarchy.layoutPass { AtticOverlayHierarchy.remove(view) }
        XCTAssertTrue(view.superview === other)
        XCTAssertTrue(view.isHidden)
        spin(0.05)
        XCTAssertNil(view.superview)
        // Outside a layout pass nothing waits.
        AtticOverlayHierarchy.place(view, in: parent, frame: a)
        XCTAssertTrue(view.superview === parent)
        AtticOverlayHierarchy.remove(view)
        XCTAssertNil(view.superview)
    }

    /// Controls can be constructed by the panel's SwiftUI update inside
    /// layout. Their first attachment must obey the same rule as placement.
    func testOverlayConstructionDuringLayoutDefersEveryInitialAttachment() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("Body")]))
        let (scroll, text) = engine.makeView()
        let chrome = NotesPageChrome()
        var title: NoteTitleAccessories!
        var format: NoteFormatControls!
        var objects: NoteObjectControls!
        let before = Set(text.subviews.map(ObjectIdentifier.init))
        AtticOverlayHierarchy.layoutPass {
            title = NoteTitleAccessories(engine: engine, textView: text, scrollView: scroll, chrome: chrome,
                design: .default, headerBottom: 40, isUntouched: { false }, tagEditor: { AnyView(EmptyView()) })
            format = NoteFormatControls(engine: engine, textView: text, scrollView: scroll,
                design: .default, noteID: engine.noteID, isNewDraft: false)
            objects = NoteObjectControls(engine: engine, textView: text)
            XCTAssertEqual(Set(text.subviews.map(ObjectIdentifier.init)), before,
                           "no overlay attaches during construction in layout")
            // A nested run loop must not make the scheduled flush mutate layout.
            AtticOverlayHierarchy.flush()
            XCTAssertEqual(Set(text.subviews.map(ObjectIdentifier.init)), before,
                           "a flush during layout must also wait")
        }
        let menu = try XCTUnwrap(text.accessoryViews.first)
        let positioned = NSRect(x: 20, y: 25, width: 30, height: 35)
        menu.frame = positioned
        AtticOverlayHierarchy.flush()
        XCTAssertEqual(text.subviews.filter { !before.contains(ObjectIdentifier($0)) }.count, 6,
                       "three title accessories, hint, selection ring and drop line")
        XCTAssertTrue(text.accessoryViews.allSatisfy { $0.superview === text })
        XCTAssertEqual(menu.frame, positioned, "initial attachment preserves geometry computed while waiting")
        AtticOverlayHierarchy.layoutPass {
            objects.invalidate()
            format.invalidate()
            title.invalidate()
            XCTAssertEqual(text.subviews.filter { !before.contains(ObjectIdentifier($0)) }.count, 6,
                           "dismantling waits too")
        }
        AtticOverlayHierarchy.flush()
        XCTAssertEqual(Set(text.subviews.map(ObjectIdentifier.init)), before)
    }

    /// P1-01 hypothesis, on the Notes page: while the note's text lays out
    /// (where the bar, the `/` list and the cards are placed), no hosting
    /// view joins or leaves a parent. The `/` list is made to need its
    /// parent again during a layout pass; it rejoins after the pass, at the
    /// place it had.
    func testNoOverlayJoinsOrLeavesDuringTheTextsLayout() throws {
        let harness = try makeHarness()
        XCTAssertTrue(harness.controller.requestNewNote())
        spin(0.4)
        let engine = try XCTUnwrap(harness.controller.active?.engine)
        let textView = try XCTUnwrap(engine.textView)
        harness.window.makeFirstResponder(textView)
        let recorder = HierarchyMutationRecorder()
        defer { recorder.stop() }
        type("Layout pass\nSome body text to select", into: textView)
        harness.host.layoutSubtreeIfNeeded()
        spin(0.2)
        type("\n/", into: textView)
        harness.host.layoutSubtreeIfNeeded()
        spin(0.2)
        let list = try XCTUnwrap(harness.host.subviews.compactMap { $0 as? AtticOverlayHostingView }.first { $0.menuLabel == "Insert" },
                                 "the `/` list is in the overlay")
        let parent = try XCTUnwrap(list.superview)
        let frame = list.frame
        // Its parent lost it (as when the overlay is rebuilt): the next text
        // layout places it again.
        list.removeFromSuperview()
        textView.needsLayout = true
        harness.host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(recorder.layoutPasses, 0, "the text laid out")
        XCTAssertEqual(recorder.mutationsDuringLayout, [], "nothing joined or left during the text's layout")
        XCTAssertNil(list.superview, "it waits for the pass to end")
        spin(0.1)
        XCTAssertTrue(list.superview === parent, "then rejoins")
        XCTAssertEqual(list.frame, frame, "where it was")
        // Typing, a selection (the bar) and scrolling lay out again.
        type("da", into: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        harness.host.layoutSubtreeIfNeeded()
        spin(0.2)
        engine.scrollView?.contentView.scroll(to: NSPoint(x: 0, y: 20))
        harness.host.layoutSubtreeIfNeeded()
        spin(0.2)
        XCTAssertEqual(recorder.mutationsDuringLayout, [])
    }
}

/// Records the rectangles a view is asked to redraw (`setNeedsDisplay(_:)`,
/// however AppKit or the view itself calls it), by replacing the method on
/// that view's class for the test's duration.
@MainActor
final class DisplayInvalidationRecorder {
    var rects: [NSRect] = []
    private let cls: AnyClass
    private let selector = #selector(NSView.setNeedsDisplay(_:))
    private let original: IMP
    private static var active: DisplayInvalidationRecorder?
    private weak var view: NSView?

    init(_ view: NSView) {
        self.view = view
        cls = Swift.type(of: view)
        let inherited = class_getInstanceMethod(cls, selector)!
        original = method_getImplementation(inherited)
        typealias Setter = @convention(c) (NSView, Selector, NSRect) -> Void
        let call = unsafeBitCast(original, to: Setter.self)
        let selector = selector
        let block: @convention(block) (NSView, NSRect) -> Void = { target, rect in
            MainActor.assumeIsolated {
                if let recorder = DisplayInvalidationRecorder.active, target === recorder.view { recorder.rects.append(rect) }
            }
            call(target, selector, rect)
        }
        Self.active = self
        let added = class_addMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(inherited))
        if !added { method_setImplementation(class_getInstanceMethod(cls, selector)!, imp_implementationWithBlock(block)) }
    }

    func stop() {
        Self.active = nil
        if let method = class_getInstanceMethod(cls, selector) { method_setImplementation(method, original) }
    }
}

/// Ends the test process when the main thread is stuck (a layout or render
/// loop cannot be interrupted from the main thread itself).
final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    init(seconds: TimeInterval, label: String) {
        let deadline = Date().addingTimeInterval(seconds)
        Thread.detachNewThread { [self] in
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                if self.isDone { return }
            }
            FileHandle.standardError.write(Data("WATCHDOG: the main thread did not finish \(label) in \(Int(seconds)) s\n".utf8))
            exit(70)
        }
    }

    private var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }

    func finish() { lock.lock(); done = true; lock.unlock() }
}

private struct CombinedFixNotesRoot: View {
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var store: NoteStore
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var toasts: PanelToastCenter
    let size: CGSize

    var body: some View {
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        NotesEditorPage(controller: noteDraft.pages, noteStore: store, noteDraft: noteDraft, uiState: uiState, layout: layout)
            .environment(\.atticPanelToasts, toasts)
            .overlay(alignment: .top) {
                PanelHeader(isPinned: false, page: .notes, onTogglePin: {}, onSelectPage: { _ in })
                    .padding(.horizontal, layout.chromeInsets.leading)
                    .padding(.top, layout.chromeInsets.top)
            }
            .frame(width: size.width, height: size.height)
            .background(AtticPanelStageSurface(cornerSize: 0))
    }
}

/// Gates a slow image load (fix round 2's late completion).
actor SlowLoadGate {
    private var open = false
    func wait() async {
        while !open { try? await Task.sleep(for: .milliseconds(10)) }
    }
    func release() { open = true }
}

/// Records hosting views (and Attic's own views) joining or leaving a
/// parent while a note's text view lays out, by wrapping `layout` on
/// `NoteEditorTextView` and the hierarchy methods on `NSView` for the
/// test's duration.
@MainActor
final class HierarchyMutationRecorder {
    private(set) var layoutPasses = 0
    private(set) var mutationsDuringLayout: [String] = []
    private var depth = 0
    private var restores: [() -> Void] = []
    private static var active: HierarchyMutationRecorder?

    init() {
        Self.active = self
        typealias Plain = @convention(c) (NSView, Selector) -> Void
        typealias AddOne = @convention(c) (NSView, Selector, NSView) -> Void
        typealias AddPositioned = @convention(c) (NSView, Selector, NSView, Int, NSView?) -> Void
        wrap(NoteEditorTextView.self, #selector(NSView.layout)) { original, selector in
            let call = unsafeBitCast(original, to: Plain.self)
            let block: @convention(block) (NSView) -> Void = { view in
                let recorder = MainActor.assumeIsolated { HierarchyMutationRecorder.active }
                MainActor.assumeIsolated { recorder?.depth += 1; recorder?.layoutPasses += 1 }
                call(view, selector)
                MainActor.assumeIsolated { recorder?.depth -= 1 }
            }
            return imp_implementationWithBlock(block)
        }
        wrap(NSView.self, #selector(NSView.addSubview(_:))) { original, selector in
            let call = unsafeBitCast(original, to: AddOne.self)
            let block: @convention(block) (NSView, NSView) -> Void = { parent, view in
                MainActor.assumeIsolated { HierarchyMutationRecorder.active?.note("add", view) }
                call(parent, selector, view)
            }
            return imp_implementationWithBlock(block)
        }
        wrap(NSView.self, #selector(NSView.addSubview(_:positioned:relativeTo:))) { original, selector in
            let call = unsafeBitCast(original, to: AddPositioned.self)
            let block: @convention(block) (NSView, NSView, Int, NSView?) -> Void = { parent, view, place, relative in
                MainActor.assumeIsolated { HierarchyMutationRecorder.active?.note("add", view) }
                call(parent, selector, view, place, relative)
            }
            return imp_implementationWithBlock(block)
        }
        wrap(NSView.self, #selector(NSView.removeFromSuperview)) { original, selector in
            let call = unsafeBitCast(original, to: Plain.self)
            let block: @convention(block) (NSView) -> Void = { view in
                MainActor.assumeIsolated { HierarchyMutationRecorder.active?.note("remove", view) }
                call(view, selector)
            }
            return imp_implementationWithBlock(block)
        }
    }

    private func note(_ kind: String, _ view: NSView) {
        guard depth > 0 else { return }
        let name = NSStringFromClass(Swift.type(of: view))
        guard view is NSHostingView<AnyView> || name.hasPrefix("Attic.") else { return }
        mutationsDuringLayout.append("\(kind) \(name)")
    }

    private func wrap(_ cls: AnyClass, _ selector: Selector, _ make: (IMP, Selector) -> IMP) {
        guard let method = class_getInstanceMethod(cls, selector) else { return XCTFail("no \(selector) on \(cls)") }
        let original = method_getImplementation(method)
        let replacement = make(original, selector)
        if class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)) {
            // Inherited until now: put the inherited implementation back.
            restores.append { class_replaceMethod(cls, selector, original, method_getTypeEncoding(method)) }
        } else {
            method_setImplementation(method, replacement)
            restores.append { method_setImplementation(method, original) }
        }
    }

    func stop() {
        restores.reversed().forEach { $0() }
        restores.removeAll()
        if Self.active === self { Self.active = nil }
    }
}
