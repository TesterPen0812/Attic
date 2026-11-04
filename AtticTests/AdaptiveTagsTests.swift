import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// N6 (Adaptive picks, 2026-11-01): a note's tags are edited in the tag
/// line under its title. The line becomes the editor in place (chips with
/// ×, a "Find or add a tag" field, at most two lines of matches) and goes
/// back to coloured text at rest. It replaces the shared tag picker that
/// dropped over the note. Hosted as the panel hosts the Notes page, in a
/// window that is never shown or made key (key events: CI's key panel).
/// Reduce Motion and Reduce Transparency are on (the instant, solid path).
@MainActor
final class AdaptiveTagsTests: XCTestCase {
    private var windows: [NSWindow] = []
    private let gate = PersistenceGate()

    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private struct Harness {
        let window: NSWindow
        let host: NSView
        let store: NoteStore
        let noteDraft: NoteDraftController
        let session: NoteSession
    }

    override func setUp() async throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
    }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeHarness(keyPanel: Bool = false, open title: String = "Plan") throws -> Harness {
        let store = try makeTestNoteStore(persist: { [gate] in try gate.save($0) },
                                          attachmentFileStore: makeTestAttachmentFileStore())
        _ = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Plan"), .text("Body")]),
                                     tags: ["launch-october"])
        _ = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Other"), .text("Body")]),
                                     tags: ["launch", "kyoto"])
        _ = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Third"), .text("Body")]),
                                     tags: ["launch"])
        _ = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Bare"), .text("Body")]), tags: [])
        let noteDraft = NoteDraftController(noteStore: store)
        let size = CGSize(width: 320, height: 520)
        var context = AtticDesignContext()
        context.controls = .craft
        context.reduceMotion = true
        context.reduceTransparency = true
        let root = AdaptiveTagsNotesRoot(noteDraft: noteDraft, store: store, uiState: PanelUIState(),
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
        let note = try XCTUnwrap(store.notes.first { $0.title == title })
        XCTAssertTrue(noteDraft.pages.open(noteID: note.id))
        noteDraft.pages.dismissLibrary() // Match a person opening saved writing.
        spin(0.4)
        host.layoutSubtreeIfNeeded()
        let session = try XCTUnwrap(noteDraft.pages.active)
        return Harness(window: window, host: host, store: store, noteDraft: noteDraft, session: session)
    }

    // MARK: Accessibility (what VoiceOver reaches through the note's text)

    private func withAccessibility(_ body: () throws -> Void) rethrows {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        try body()
    }

    private func descendants(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { descendants($0 as AnyObject) }
    }

    /// The elements VoiceOver reaches through the note's text view (its
    /// accessories, the tag line among them).
    private func elements(_ harness: Harness) throws -> [AnyObject] {
        let textView = try XCTUnwrap(harness.session.engine.textView)
        textView.layoutSubtreeIfNeeded()
        return descendants(textView)
    }

    private func label(_ element: AnyObject) -> String { (element.accessibilityLabel?() ?? nil) ?? "" }
    private func identifier(_ element: AnyObject) -> String { (element.accessibilityIdentifier?() ?? nil) ?? "" }

    private func element(_ harness: Harness, label wanted: String) throws -> AnyObject {
        try XCTUnwrap(try elements(harness).first { label($0) == wanted }, "no element “\(wanted)”")
    }

    private func press(_ harness: Harness, _ wanted: String) throws {
        let target = try element(harness, label: wanted)
        XCTAssertTrue(target.accessibilityPerformPress?() ?? false, "pressing “\(wanted)”")
        spin(0.3)
        harness.host.layoutSubtreeIfNeeded()
    }

    private func matches(_ harness: Harness) throws -> [String] {
        try elements(harness).filter { identifier($0).hasPrefix("notes-tag-match-") }.map(label)
    }

    private func lit(_ harness: Harness) throws -> [String] {
        try elements(harness).filter { identifier($0).hasPrefix("notes-tag-match-") && ($0.isAccessibilitySelected?() ?? false) }
            .map(label)
    }

    private func isEditorOpen(_ harness: Harness) throws -> Bool {
        try elements(harness).contains { identifier($0) == "notes-tag-editor" }
    }

    private func setQuery(_ harness: Harness, _ text: String) throws {
        let editor = try XCTUnwrap(harness.window.firstResponder as? NSTextView, "the tag field has the keyboard")
        XCTAssertTrue(editor.isFieldEditor, "the field, not the note's text, has the keyboard")
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.3)
    }

    // MARK: Opening in place

    /// A click on a tag turns the tag line itself into the editor: the
    /// chips, the field and the matches are in the note's text (reached
    /// through it by VoiceOver), not in a card over it. The note's own tag
    /// is a chip, never a match; the others follow by count.
    func testATagClickMakesTheTagLineTheEditorInPlace() throws {
        try withAccessibility {
            let harness = try makeHarness()
            let rest = harness.session.engine.style.tagLineHeight
            XCTAssertGreaterThan(rest, 0, "the tag line shows under the title")
            XCTAssertFalse(try isEditorOpen(harness))
            XCTAssertFalse(try elements(harness).contains { label($0).hasPrefix("Remove #") }, "no chips at rest")
            try press(harness, "Tag launch-october")
            XCTAssertTrue(try isEditorOpen(harness), "the tag line is the editor")
            XCTAssertNoThrow(try element(harness, label: "Remove #launch-october"))
            XCTAssertNoThrow(try element(harness, label: "Find or add a tag"))
            XCTAssertEqual(try matches(harness), ["Add #launch, 2", "Add #kyoto, 1"])
            XCTAssertEqual(try lit(harness), [], "an empty field lights nothing")
            XCTAssertNil(harness.window.childWindows?.first { $0.isVisible }, "no card over the note")
            // The body moved down once, to the editor's measured height:
            // the chips' line and the matches' fixed two lines.
            let open = harness.session.engine.style.tagLineHeight
            XCTAssertGreaterThanOrEqual(open, NoteTagLineEditorMetrics.chipHeight + NoteTagLineEditorMetrics.suggestionAreaHeight)
            XCTAssertEqual((harness.window.firstResponder as? NSTextView)?.isFieldEditor, true, "the field has the keyboard")
        }
    }

    /// Adding and removing in the line: a match becomes a chip (and leaves
    /// the matches), a chip's × takes the tag off. Each is one Undo step of
    /// the note, as the shared picker's were, and the body stays put while
    /// the chips fit their line.
    func testAddingAndRemovingInTheTagLine() throws {
        try withAccessibility {
            let harness = try makeHarness()
            let engine = harness.session.engine
            try press(harness, "Tag launch-october")
            let open = engine.style.tagLineHeight
            try press(harness, "Add #kyoto, 1")
            XCTAssertEqual(Set(engine.tags), ["launch-october", "kyoto"])
            XCTAssertNoThrow(try element(harness, label: "Remove #kyoto"))
            XCTAssertEqual(try matches(harness), ["Add #launch, 2"])
            XCTAssertEqual(engine.style.tagLineHeight, open, "a chip that fits its line doesn't move the body")
            XCTAssertTrue(try isEditorOpen(harness), "adding keeps the editor open")
            try press(harness, "Remove #launch-october")
            XCTAssertEqual(engine.tags, ["kyoto"])
            XCTAssertTrue(try matches(harness).contains { $0.hasPrefix("Add #launch-october") }, "it is a match again")
            XCTAssertEqual(engine.history.undoActionName, "Edit Tags")
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(Set(engine.tags), ["launch-october", "kyoto"])
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(engine.tags, ["launch-october"])
        }
    }

    /// Typing lights only what was typed (the shared picker's rule, F5):
    /// the exact tag though another starts the same way, "Add" for a new
    /// name (a prefix never lights the first match), nothing when empty.
    func testTypingFiltersAndLightsOnlyWhatWasTyped() throws {
        try withAccessibility {
            let harness = try makeHarness()
            try press(harness, "Tag launch-october")
            try setQuery(harness, "launch")
            XCTAssertEqual(try matches(harness), ["Add #launch, 2"], "the note's own #launch-october is a chip")
            XCTAssertEqual(try lit(harness), ["Add #launch, 2"])
            try setQuery(harness, "laun")
            XCTAssertEqual(try matches(harness), ["Add #laun", "Add #launch, 2"])
            XCTAssertEqual(try lit(harness), ["Add #laun"], "a prefix lights what was typed")
            try setQuery(harness, "#Paris")
            XCTAssertEqual(try lit(harness), ["Add #paris"])
            try press(harness, "Add #paris")
            XCTAssertEqual(Set(harness.session.engine.tags), ["launch-october", "paris"], "a new name is added")
            try setQuery(harness, "")
            XCTAssertEqual(try lit(harness), [])
        }
    }

    /// A click in the text closes the editor and leaves the keyboard there;
    /// the line is coloured text again and the body moves back once.
    func testAClickInTheTextClosesTheEditor() throws {
        try withAccessibility {
            let harness = try makeHarness()
            let engine = harness.session.engine
            let rest = engine.style.tagLineHeight
            try press(harness, "Tag launch-october")
            XCTAssertGreaterThan(engine.style.tagLineHeight, rest)
            let textView = try XCTUnwrap(engine.textView)
            XCTAssertTrue(harness.window.makeFirstResponder(textView))
            spin(0.4)
            harness.host.layoutSubtreeIfNeeded()
            XCTAssertFalse(try isEditorOpen(harness), "the click in the text closed it")
            XCTAssertNoThrow(try element(harness, label: "Tag launch-october"), "coloured text again")
            XCTAssertTrue(harness.window.firstResponder === textView, "the keyboard stays in the text")
            XCTAssertEqual(engine.style.tagLineHeight, rest, "the body moved back")
        }
    }

    /// Typing `#tag` in the title still adds a tag, beside the line.
    func testATitleHashtagStillAddsATag() throws {
        let harness = try makeHarness()
        let engine = harness.session.engine
        let textView = try XCTUnwrap(engine.textView)
        XCTAssertTrue(harness.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        for character in " #trip " {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        spin(0.3)
        XCTAssertEqual(Set(engine.tags), ["launch-october", "trip"])
    }

    /// An already-open editor's matches follow the shared inventory when a
    /// task's tags change (the E1 card's guarantee, kept in place).
    func testOpenMatchesFollowTheSharedInventory() throws {
        try withAccessibility {
            let harness = try makeHarness()
            let tasks = TaskStore(container: harness.store.container)
            let library = AtticLibrary(tasks: tasks, notes: harness.store)
            try press(harness, "Tag launch-october")
            let task = try XCTUnwrap(tasks.create(title: "Task-only tag"))
            XCTAssertTrue(tasks.setTags(["cu2taskonly", "launch"], for: task))
            spin(0.4)
            harness.host.layoutSubtreeIfNeeded()
            XCTAssertEqual(try matches(harness), ["Add #launch, 3", "Add #cu2taskonly, 1", "Add #kyoto, 1"])
            XCTAssertTrue(tasks.setTags([], for: task))
            spin(0.4)
            harness.host.layoutSubtreeIfNeeded()
            XCTAssertEqual(try matches(harness), ["Add #launch, 2", "Add #kyoto, 1"])
            withExtendedLifetime(library) {}
        }
    }

    // MARK: The line's room, with no tags and read-only

    private func accessories(_ document: NoteDocument, readOnly: Bool = false)
        -> (NoteEditorEngine, NotesPageChrome, NoteTitleAccessories, NSWindow) {
        let engine = NoteEditorEngine(noteID: UUID(), document: document, readOnly: readOnly)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        textView.textContainerInset = NSSize(width: 28, height: 0)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 520), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        let chrome = NotesPageChrome()
        var design = AtticDesignContext()
        design.reduceMotion = true
        design.reduceTransparency = true
        let accessories = NoteTitleAccessories(engine: engine, textView: textView, scrollView: scrollView, chrome: chrome,
                                               design: design, headerBottom: 40, isUntouched: { false },
                                               tagEditor: { AnyView(EmptyView()) })
        return (engine, chrome, accessories, window)
    }

    private func settle(_ engine: NoteEditorEngine, _ accessories: NoteTitleAccessories) {
        for _ in 0..<3 {
            engine.textView?.layoutSubtreeIfNeeded()
            accessories.layout()
            spin(0.1)
        }
    }

    /// ⋯ → Tags… on a note with no tags opens the editor in the tag line
    /// too (the line shows while it is the editor), and closing it gives
    /// the room back. The editor's height holds while typing changes the
    /// matches (the matches keep two lines' room).
    func testTagsFromTheMenuOpenTheLineWithNoTags() {
        let (engine, chrome, accessories, _) = accessories(NoteDocument(blocks: [.text("Bare"), .text("Body")]))
        defer { accessories.invalidate(); engine.detachView() }
        settle(engine, accessories)
        XCTAssertEqual(engine.style.tagLineHeight, 0, "no tags, no line")
        chrome.presentTagEditor()
        XCTAssertEqual(chrome.tagEditor, .tags, "the tag line, never the ⋯'s card")
        settle(engine, accessories)
        let m = NoteTagLineEditorMetrics.self
        let open = engine.style.tagLineHeight
        XCTAssertEqual(open, m.chipHeight + m.suggestionAreaHeight, accuracy: 1, "the field's line and two lines of matches")
        chrome.tagEditor = nil
        settle(engine, accessories)
        XCTAssertEqual(engine.style.tagLineHeight, 0, "closing gives the room back")
    }

    /// Chips that run past their line wrap, and the field keeps at least
    /// its minimum width (starting a line of its own when less is left).
    func testChipsWrapAndTheFieldKeepsItsWidth() {
        let many = (1...9).map { "project-\($0)" }
        let (engine, chrome, accessories, _) = accessories(NoteDocument(blocks: [.text("Many"), .text("Body")]))
        defer { accessories.invalidate(); engine.detachView() }
        engine.setTags(many)
        settle(engine, accessories)
        chrome.presentTagEditor()
        settle(engine, accessories)
        let m = NoteTagLineEditorMetrics.self
        XCTAssertGreaterThan(engine.style.tagLineHeight, 2 * m.chipHeight + m.lineSpacing + m.suggestionAreaHeight - 1,
                             "nine chips wrap at 264 pt")
    }

    /// A read-only note (a version being viewed) never opens the editor.
    func testAReadOnlyNoteKeepsItsTagLine() {
        let (engine, chrome, accessories, _) = accessories(NoteDocument(blocks: [.text("Old"), .text("Body")]), readOnly: true)
        defer { accessories.invalidate(); engine.detachView() }
        chrome.presentTagEditor()
        XCTAssertNil(chrome.tagEditor)
    }

    // MARK: Matches

    func testMatchesListOtherTagsByCountAndTheTypedNameFirst() {
        typealias M = NoteTagLineMatch
        let counts = ["launch-october": 1, "launch": 2, "kyoto": 1, "paris": 5]
        XCTAssertEqual(M.make(query: "", counts: counts, excluding: ["launch-october"]).map(\.id),
                       ["paris", "launch", "kyoto"])
        XCTAssertEqual(M.make(query: "launch", counts: counts, excluding: []).map(\.id), ["launch", "launch-october"],
                       "the exact tag first, then those it starts")
        XCTAssertEqual(M.make(query: "aun", counts: counts, excluding: []).map(\.id),
                       ["new:aun", "launch", "launch-october"], "a new name first, then those containing it")
        XCTAssertEqual(M.make(query: "#Launch", counts: counts, excluding: ["launch"]).map(\.id), ["launch-october"],
                       "the note's own tag is neither a match nor new")
        XCTAssertEqual(M.typedHighlight("launch", in: M.make(query: "launch", counts: counts, excluding: [])), "launch")
        XCTAssertNil(M.typedHighlight("launch", in: M.make(query: "launch", counts: counts, excluding: ["launch"])),
                     "never a prefix match")
        XCTAssertNil(M.typedHighlight("", in: M.make(query: "", counts: counts, excluding: [])))
    }

    /// At 320 pt (a 264 pt column) the matches stop at two lines; with no
    /// width known yet, the first four.
    func testMatchesFitTwoLinesAt320() {
        typealias M = NoteTagLineMatch
        let all = (1...20).map { M(name: "tag-number-\($0)", count: $0, isNew: false) }
        let column: CGFloat = 320 - 2 * 28
        let shown = M.fitting(all, width: column)
        XCTAssertGreaterThan(shown.count, 1)
        XCTAssertLessThan(shown.count, all.count)
        XCTAssertEqual(shown, Array(all.prefix(shown.count)), "in order")
        let spacing = NoteTagLineEditorMetrics.suggestionSpacing
        var lines = 1
        var used: CGFloat = -spacing
        for match in shown {
            if used + spacing + match.width > column { lines += 1; used = -spacing }
            used += spacing + match.width
        }
        XCTAssertLessThanOrEqual(lines, 2)
        XCTAssertEqual(M.fitting(all, width: 0).count, 4)
    }

    // MARK: Keys (CI's key panel)

    /// ↓ Return adds the highlighted match; typing and Return adds what was
    /// typed; Backspace in an empty field takes the last tag off; Esc
    /// closes and gives the keyboard back to the text.
    func testTheTagLineKeysOnAKeyPanel() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("CI only: real key events need a key panel, which locally would take the keyboard")
        }
        try withAccessibility {
            let harness = try makeHarness(keyPanel: true)
            let window = harness.window
            XCTAssertTrue(window.isKeyWindow)
            let engine = harness.session.engine
            try press(harness, "Tag launch-october")
            XCTAssertEqual((window.firstResponder as? NSTextView)?.isFieldEditor, true, "the tag field has the keyboard")
            @MainActor func key(_ characters: String, _ code: UInt16) {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                 isARepeat: false, keyCode: code)!
                    NSApp.postEvent(event, atStart: false)
                }
                var count = 0
                while count < 64, let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(next)
                    count += 1
                }
                spin(0.2)
            }
            key("\u{F701}", 125)
            XCTAssertEqual(try lit(harness), ["Add #launch, 2"], "↓ lights the first match")
            key("\r", 36)
            XCTAssertEqual(Set(engine.tags), ["launch-october", "launch"], "Return added it")
            try setQuery(harness, "kyoto")
            key("\r", 36)
            XCTAssertEqual(Set(engine.tags), ["launch-october", "launch", "kyoto"])
            key("\u{7F}", 51)
            XCTAssertEqual(engine.tags, ["kyoto", "launch"], "Backspace in an empty field took the last chip off")
            key("\u{1B}", 53)
            spin(0.3)
            XCTAssertFalse(try isEditorOpen(harness), "Esc closed it")
            XCTAssertTrue(window.firstResponder === engine.textView, "the keyboard is back in the text")
        }
    }
}

private struct AdaptiveTagsNotesRoot: View {
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var store: NoteStore
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var toasts: PanelToastCenter
    let size: CGSize

    var body: some View {
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        NotesEditorPage(controller: noteDraft.pages, noteStore: store, noteDraft: noteDraft, uiState: uiState, layout: layout)
            .environment(\.atticPanelToasts, toasts)
            .frame(width: size.width, height: size.height)
            .background(AtticPanelStageSurface(cornerSize: 0))
    }
}
