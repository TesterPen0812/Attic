import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Phase X hunt 8 (H10): view-level findings, reproduced headlessly or in
/// never-shown windows. No window here is ordered front or made key.
@MainActor
final class PhaseXHunt8Tests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.contentView = nil
            window.close()
        }
        windows = []
    }

    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func unshownWindow(_ size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func rgba(_ color: NSColor?) -> [Int] {
        guard let color = color?.usingColorSpace(.sRGB) else { return [] }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    // MARK: - H10-01 · Find in note keeps the look it opened with

    /// Find open in a note, then Light/Dark changes (System appearance at
    /// sunset, or Settings): the find bar's field must take the new ink, as
    /// the note's own text does.
    func testH10_01TheFindBarFollowsAnAppearanceChangeWhileOpen() throws {
        let light = AtticDesignContext(mode: .light)
        let dark = AtticDesignContext(mode: .dark)
        XCTAssertNotEqual(rgba(NSColor(light.tokens.color(.heading))), rgba(NSColor(dark.tokens.color(.heading))))
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Find"), .text("alpha beta")]),
                                      design: light)
        let (scroll, _) = engine.makeView()
        let window = unshownWindow(CGSize(width: 320, height: 520))
        let content = try XCTUnwrap(window.contentView)
        scroll.frame = content.bounds
        content.addSubview(scroll)
        engine.find.show()
        spin(0.2)
        func field() -> NSTextField? {
            descendants(of: scroll).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "note-find" }
        }
        XCTAssertEqual(rgba(try XCTUnwrap(field()).textColor), rgba(NSColor(light.tokens.color(.heading))))
        engine.update(design: dark)
        spin(0.2)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(rgba(engine.textView?.insertionPointColor), rgba(NoteTextStyle(design: dark).bodyColor),
                       "the note itself took the dark look")
        XCTExpectFailure("H10-01: the find bar keeps the design it was opened with")
        XCTAssertEqual(rgba(field()?.textColor), rgba(NSColor(dark.tokens.color(.heading))),
                       "the open find bar's field takes the dark ink")
        engine.find.close(returnFocus: false)
    }

    // MARK: - H10-02 · A proposal's comparison keeps the look it opened with

    private final class DesignBox: ObservableObject {
        @Published var design: AtticDesignContext
        init(_ design: AtticDesignContext) { self.design = design }
    }

    private struct ProposalRoot: View {
        @ObservedObject var box: DesignBox
        @ObservedObject var noteDraft: NoteDraftController
        let store: NoteStore
        let uiState: PanelUIState
        let size: CGSize
        var body: some View {
            NotesEditorPage(controller: noteDraft.pages, noteStore: store, noteDraft: noteDraft, uiState: uiState,
                            layout: PanelPageLayout(cornerSize: 52, panelSize: size))
                .frame(width: size.width, height: size.height)
                .atticDesign(box.design)
        }
    }

    /// Reviewing an agent's proposal, then Light/Dark changes: the read-only
    /// comparison must redraw in the new look (History's preview does).
    func testH10_02TheProposalComparisonFollowsAnAppearanceChange() async throws {
        let light = AtticDesignContext(mode: .light)
        let dark = AtticDesignContext(mode: .dark)
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let noteDraft = NoteDraftController(noteStore: store)
        let controller = noteDraft.pages
        await controller.startAndWait()
        let document = NoteDocument(blocks: [.text("My note"), .text("Body")])
        guard case let .success((noteID, revision)) = store.createDocumentNote(id: UUID(), document: document) else {
            return XCTFail("fixture note")
        }
        await XCTAssertTrueAsync(await controller.openDurably(noteID: noteID))
        var proposal = document
        proposal.blocks[1] = .text("Claude's body")
        guard case let .success(.pending(editID)) = store.agentWrite(noteID: noteID, baseRevisionToken: revision.uuidString,
                                                                       document: proposal, agentName: "Claude",
                                                                       disposition: store.agentWriteDisposition(noteID)) else {
            return XCTFail("fixture proposal")
        }
        await XCTAssertTrueAsync(await controller.beginProposalReview(id: editID))
        XCTAssertNotNil(controller.proposalReview)

        let size = CGSize(width: 320, height: 560)
        let box = DesignBox(light)
        let host = NSHostingView(rootView: ProposalRoot(box: box, noteDraft: noteDraft, store: store, uiState: PanelUIState(), size: size))
        host.frame = CGRect(origin: .zero, size: size)
        let window = unshownWindow(size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin(0.3)
        func comparisonText() -> NoteEditorTextView? {
            host.layoutSubtreeIfNeeded()
            return descendants(of: host).compactMap { $0 as? NoteEditorTextView }.first { !$0.isEditable }
        }
        XCTAssertEqual(rgba(try XCTUnwrap(comparisonText()).insertionPointColor), rgba(NoteTextStyle(design: light).bodyColor))
        box.design = dark
        spin(0.3)
        XCTExpectFailure("H10-02: the comparison's read-only note keeps the design it was opened with")
        XCTAssertEqual(rgba(comparisonText()?.insertionPointColor), rgba(NoteTextStyle(design: dark).bodyColor),
                       "the comparison redraws in the dark look")
        controller.endProposalReview()
        spin(0.1)
    }

    // MARK: - H10-03 · A row's picker outlives its row

    /// A row's tag list is open; an agent deletes that task. The list goes
    /// with its row, so the page must leave edit mode (the panel's edit
    /// lock, and the page's shortcuts, which wait for no picker).
    func testH10_03ARowsPickerLetsGoWhenAnAgentDeletesItsTask() throws {
        setenv("ATTIC_UI_TEST_META", "tags@0.3", 1)
        defer { unsetenv("ATTIC_UI_TEST_META") }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container)
        let store = TaskStore(container: container)
        let library = AtticLibrary(tasks: store)
        let model = TasksPageModel(library: library, services: TasksPageServices())
        final class Locks { var values: [Bool] = [] }
        let locks = Locks()
        let size = CGSize(width: AtticLayout.panelSize.width, height: 560)
        var addBar = false
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                             addBarFocused: Binding(get: { addBar }, set: { addBar = $0 }),
                             chrome: TasksPageChrome(editLock: { locks.values.append($0) }))
        let window = unshownWindow(size)
        window.contentView = NSHostingView(rootView: page.atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height))
        spin(1.0)
        let row = try XCTUnwrap(model.rows(for: model.tab).first { !$0.model.tags.isEmpty })
        XCTAssertEqual(locks.values.last, true, "the row's tag list opened: edit mode")
        XCTAssertTrue(library.delete(AtticItemRef(.task, row.id)), "the agent's delete_task route")
        spin(0.5)
        XCTAssertFalse(model.rows(for: model.tab).contains { $0.id == row.id })
        XCTExpectFailure("H10-03: the page's picker state outlives its row")
        XCTAssertEqual(locks.values.last, false, "with its row gone the picker is closed and edit mode ends")
    }

    // MARK: - Coverage: pages kept built behind the current one (no finding)

    private struct PanelFixture {
        let host: AtticPanelHostingView
        let window: NSWindow
        let state: PanelUIState
        let notes: NoteStore
        let noteDraft: NoteDraftController
        let defaultsSuite: String
    }

    private func makePanel() throws -> PanelFixture {
        let suite = "PhaseXHunt8.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let noteDraft = NoteDraftController(noteStore: notes)
        let state = PanelUIState()
        state.updatePanelSize(CGSize(width: 340, height: 560))
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
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
        let window = unshownWindow(CGSize(width: 340, height: 560))
        window.contentView = host
        spin(0.5)
        return PanelFixture(host: host, window: window, state: state, notes: notes, noteDraft: noteDraft, defaultsSuite: suite)
    }

    private func release(_ panel: PanelFixture) {
        panel.host.cancelActiveInteraction(reason: .lostWindow)
        panel.state.releasePageContent()
        spin(0.3)
        UserDefaults(suiteName: panel.defaultsSuite)?.removePersistentDomain(forName: panel.defaultsSuite)
    }

    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: code))
    }

    private func openNoteOnNotes(_ panel: PanelFixture, text: String) throws -> UUID {
        guard case let .success((noteID, _)) = panel.notes.createDocumentNote(
            id: UUID(), document: NoteDocument(blocks: [.text(text), .text("Body")])) else {
            throw NoteDocumentStoreError.saveFailed("fixture note")
        }
        panel.state.selectSection(.notes)
        spin(0.8)
        XCTAssertTrue(panel.noteDraft.pages.open(noteID: noteID))
        spin(0.8)
        return noteID
    }

    /// The Notes page stays built behind Tasks: its note keys (⇧⌘L All
    /// notes, ⌘D Duplicate) must not act on it from there.
    func testCoverageNotesKeysDoNotActFromBehindTasks() throws {
        let panel = try makePanel()
        defer { release(panel) }
        let noteID = try openNoteOnNotes(panel, text: "Kept behind")
        panel.state.selectSection(.tasks)
        spin(0.8)
        let count = panel.notes.notes.count
        _ = panel.window.performKeyEquivalent(with: try key("l", code: 37, [.command, .shift], in: panel.window))
        _ = panel.window.performKeyEquivalent(with: try key("d", code: 2, .command, in: panel.window))
        _ = panel.window.performKeyEquivalent(with: try key("n", code: 45, .command, in: panel.window))
        spin(0.8)
        XCTAssertEqual(panel.state.selectedSection, .tasks)
        XCTAssertFalse(panel.noteDraft.pages.isLibraryPresented, "⇧⌘L did not toggle the hidden page's All notes")
        XCTAssertEqual(panel.notes.notes.count, count, "⌘D did not duplicate the hidden note")
        XCTAssertEqual(panel.noteDraft.pages.active?.noteID, noteID, "⌘N did not start a note behind Tasks")
    }

    /// Typing in a note, then Tasks: ⌘Z there never undoes the hidden
    /// note's typing (the keyboard leaves the note with its page).
    func testCoverageUndoOnTasksNeverReachesTheNoteLeftBehind() throws {
        let panel = try makePanel()
        defer { release(panel) }
        _ = try openNoteOnNotes(panel, text: "Typed")
        let textView = try XCTUnwrap(descendants(of: panel.host).compactMap { $0 as? NoteEditorTextView }.first { $0.isEditable })
        XCTAssertTrue(panel.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        for character in " more" { textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        spin(0.3)
        let engine = try XCTUnwrap(panel.noteDraft.pages.active?.engine)
        let typed = engine.textStorage.string
        XCTAssertTrue(typed.hasSuffix(" more"))
        panel.state.selectSection(.tasks)
        spin(0.8)
        XCTAssertFalse(panel.window.firstResponder is NoteEditorTextView, "the keyboard left the note with its page")
        let undo = try key("z", code: 6, .command, in: panel.window)
        if !panel.window.performKeyEquivalent(with: undo) { panel.window.firstResponder?.keyDown(with: undo) }
        spin(0.3)
        XCTAssertEqual(engine.textStorage.string, typed, "⌘Z on Tasks left the hidden note's typing alone")
    }

    /// VoiceOver (enhanced UI on): with Tasks current, nothing of Canvas or
    /// Notes kept built behind it is in the panel's accessibility tree.
    func testCoverageHiddenPagesAreOutOfTheAccessibilityTree() throws {
        let panel = try makePanel()
        defer { release(panel) }
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        _ = try openNoteOnNotes(panel, text: "Behind")
        panel.state.selectSection(.canvas)
        spin(0.8)
        panel.state.selectSection(.tasks)
        spin(0.8)
        panel.host.layoutSubtreeIfNeeded()
        XCTAssertFalse(descendants(of: panel.host).filter { $0 is CanvasNSView || $0 is NoteEditorTextView }.isEmpty,
                       "Canvas and Notes are kept built behind Tasks")
        var seen = Set<ObjectIdentifier>()
        var hidden: [String] = []
        var queue: [AnyObject] = [panel.host]
        let selector = NSSelectorFromString("accessibilityChildren")
        while let next = queue.popLast(), seen.count < 20_000 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            if next is CanvasNSView || next is NoteEditorTextView { hidden.append(String(describing: type(of: next))) }
            let object = next as? NSObject
            let children = object.flatMap { $0.responds(to: selector) ? $0.perform(selector)?.takeUnretainedValue() as? [Any] : nil } ?? []
            for child in children { queue.append(child as AnyObject) }
        }
        XCTAssertGreaterThan(seen.count, 10, "the Tasks page is in the tree")
        XCTAssertEqual(hidden, [], "no hidden page's view is reachable by VoiceOver")
    }
}
