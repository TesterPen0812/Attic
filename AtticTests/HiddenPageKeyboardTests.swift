import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Fix B (ops/design/hidden-page-keyboard.lead.md): a page that is not
/// shown never holds the keyboard. The shell keeps hidden pages built in
/// the panel's one hosting view, hidden only in SwiftUI, so an AppKit
/// focus hand-back (`makeFirstResponder`) or the key-view loop can land a
/// responder on a hidden page, and the next keys write there.
///
/// The app's real panel (an `AtticPanelController` and its `AtticPanel`),
/// never key in the invisible unit host. A stray hand-back is
/// `panel.makeFirstResponder(view)`; a key reaches whoever holds the
/// keyboard, as `NSWindow.sendEvent` sends it.
@MainActor
final class HiddenPageKeyboardTests: XCTestCase {
    private var previousModel: DrawPageModel?

    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        AtticDraw.enabledOverride = true
    }

    override func tearDown() {
        if let previousModel { DrawPageModel.replaceShared(previousModel) }
        previousModel = nil
        AtticDraw.enabledOverride = nil
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        super.tearDown()
    }

    // MARK: The rig

    private struct Rig {
        let controller: AtticPanelController
        let panel: AtticPanel
        let uiState: PanelUIState
        let store: TaskStore
        let notes: NoteStore
        let draft: NoteDraftController
        let draw: DrawPageModel
        let defaults: UserDefaults
        let suite: String
    }

    private func makeRig() throws -> Rig {
        let suite = "HiddenPageKeyboardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let persistence = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: persistence)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: persistence,
                                                                attachmentFileStore: makeTestAttachmentFileStore()))
        let draw = DrawPageModel(store: DrawInMemoryStore())
        draw.pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-hidden-keyboard-\(UUID().uuidString)"))
        if previousModel == nil { previousModel = DrawPageModel.shared }
        DrawPageModel.replaceShared(draw)
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let uiState = PanelUIState()
        let draft = NoteDraftController(noteStore: notes)
        let controller = AtticPanelController(
            store: store, noteStore: notes, canvasSession: CanvasSession(store: CanvasStore(container: persistence)),
            noteDraft: draft, settings: AppSettings(defaults: defaults), uiState: uiState
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        let screen = try XCTUnwrap(controller.currentScreen ?? NSScreen.main)
        XCTAssertTrue(controller.show(on: screen, corner: .topRight))
        spin(0.4)
        XCTAssertFalse(panel.isKeyWindow, "the panel is not key")
        return Rig(controller: controller, panel: panel, uiState: uiState, store: store, notes: notes, draft: draft,
                   draw: draw, defaults: defaults, suite: suite)
    }

    private func close(_ rig: Rig) {
        rig.draw.setShown(false)
        rig.panel.orderOut(nil)
        rig.draw.pasteboard.releaseGlobally()
        rig.defaults.removePersistentDomain(forName: rig.suite)
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func show(_ section: PanelSection, _ rig: Rig, settle: TimeInterval = 0.6) {
        rig.uiState.selectSection(section)
        spin(settle)
    }

    private func views<T: NSView>(_ type: T.Type, in panel: NSWindow) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        panel.contentView.map(walk)
        return found
    }

    private func board(_ rig: Rig) throws -> DrawBoardView {
        let deadline = Date().addingTimeInterval(5)
        while views(DrawBoardView.self, in: rig.panel).isEmpty, Date() < deadline { spin(0.05) }
        return try XCTUnwrap(views(DrawBoardView.self, in: rig.panel).first, "the Draw page's board is built")
    }

    private func addBarIfBuilt(_ rig: Rig) -> AtticTokenTextView? {
        views(AtticTokenTextView.self, in: rig.panel).first { $0.accessibilityLabel() == String(localized: "Add a task") }
    }

    /// Opens a note of `blocks` on Notes and returns its editor.
    private func openNote(_ rig: Rig, _ blocks: [NoteBlock]) throws -> NoteEditorTextView {
        guard case let .success((noteID, _)) = rig.notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: blocks))
        else { throw NoteDocumentStoreError.saveFailed("fixture note") }
        show(.notes, rig, settle: 0.8)
        XCTAssertTrue(rig.draft.pages.open(noteID: noteID))
        let marker = try XCTUnwrap(blocks.last?.text)
        let deadline = Date().addingTimeInterval(5)
        func find() -> NoteEditorTextView? {
            views(NoteEditorTextView.self, in: rig.panel).first { $0.string.contains(marker) }
        }
        while find() == nil, Date() < deadline { spin(0.05) }
        return try XCTUnwrap(find(), "the note's editor is built")
    }

    private func key(_ characters: String, code: UInt16, _ panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: code))
    }

    /// A key, delivered to whichever view holds the panel's keyboard (the
    /// window's own `keyDown` only beeps).
    private func press(_ characters: String, code: UInt16, _ rig: Rig) throws {
        let event = try key(characters, code: code, rig.panel)
        (rig.panel.firstResponder as? NSView)?.keyDown(with: event)
        spin(0.05)
    }

    private func holds(_ panel: NSWindow, _ view: NSView) -> Bool {
        (panel.firstResponder as? NSView)?.isDescendant(of: view) == true
    }

    private func responderName(_ panel: NSWindow) -> String {
        panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    }

    // MARK: Writes into a hidden page (red first on the trunk)

    /// Notes: a stray hand-back to the hidden editor, then Delete (the
    /// block marquee from when Notes was shown is kept) and typing. On the
    /// trunk the editor takes the keyboard (red), but the keys write
    /// nothing: a hidden editor is suspended and not editable
    /// (NoteEditorHost.swift, `isEditable = current && ...`), so the write
    /// row is not reachable and stays pinned here.
    func testHiddenNotesEditorRefusesTheKeyboardAndTakesNoDeleteOrTyping() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let editor = try openNote(rig, [.text("Hidden title"), .text("Alpha block"), .text("Beta block")])
        XCTAssertTrue(rig.panel.makeFirstResponder(editor), "shown, the editor takes the keyboard")
        let marquee = try XCTUnwrap(editor.marquee)
        let items = marquee.items()
        XCTAssertGreaterThan(items.count, 1, "the note has blocks to select")
        marquee.select(offsets: [try XCTUnwrap(items[1].id.base as? Int)])
        XCTAssertFalse(marquee.isEmpty, "shown, a block marquee is up")

        show(.tasks, rig)
        XCTAssertFalse(holds(rig.panel, editor), "hiding Notes took the keyboard out of its editor")
        let text = editor.string
        print("HIDDEN_NOTES marqueeKept=\(editor.marquee?.isEmpty == false) responder=\(responderName(rig.panel))")

        rig.panel.makeFirstResponder(editor)
        spin(0.1)
        XCTAssertFalse(holds(rig.panel, editor), "a hidden Notes editor took the keyboard")
        XCTAssertFalse(rig.uiState.interactionLockReasons.contains(.notesEditorFocus),
                       "the hidden Notes page reads focused")
        try press("\u{7f}", code: 51, rig)
        try press("\u{f728}", code: 117, rig)
        for character in "zq" { try press(String(character), code: 0, rig) }
        try press("\r", code: 36, rig)
        XCTAssertEqual(editor.string, text, "a key wrote into the hidden Notes editor")
    }

    /// Tasks: the add-bar row is not reachable in the panel. The panel's
    /// Composer card replaces the page's add bar there, so the bar is
    /// never built (TasksPanelDesignViews.swift, `if !shared`), and the
    /// card is chrome, shown on every page. This pins that reason.
    func testTasksAddBarIsNotBuiltInThePanel() throws {
        let rig = try makeRig()
        defer { close(rig) }
        show(.tasks, rig, settle: 0.8)
        XCTAssertNil(addBarIfBuilt(rig), "the panel builds the Tasks add bar: its typing and Return row is reachable")
    }

    /// Draw (A guards the board's own keys; B refuses the keyboard itself).
    func testHiddenDrawBoardRefusesTheKeyboard() throws {
        let rig = try makeRig()
        defer { close(rig) }
        show(.canvas, rig)
        let board = try board(rig)
        show(.calendar, rig)
        XCTAssertFalse(rig.draw.isShown)
        XCTAssertFalse(holds(rig.panel, board), "hiding Draw took the keyboard out of its board")
        rig.panel.makeFirstResponder(board)
        XCTAssertFalse(holds(rig.panel, board), "a hidden Draw board took the keyboard")
        XCTAssertFalse(board.canBecomeKeyView, "a hidden Draw board is in the key-view loop")
    }

    // MARK: Tab never lands on a hidden page

    /// From Calendar (nothing of its own takes the keyboard), Tab and
    /// Shift-Tab walk the loop; no step lands on a hidden page's view.
    func testTabFromCalendarNeverLandsOnAHiddenPage() throws {
        let rig = try makeRig()
        defer { close(rig) }
        show(.canvas, rig)
        let board = try board(rig)
        let editor = try openNote(rig, [.text("Tab title"), .text("Tab body")])
        show(.calendar, rig)
        rig.panel.makeFirstResponder(nil)
        var landed: [String] = []
        for step in 0..<24 {
            if step < 12 { rig.panel.selectNextKeyView(nil) } else { rig.panel.selectPreviousKeyView(nil) }
            landed.append(responderName(rig.panel))
            for (name, view) in [("Draw board", board as NSView), ("Notes editor", editor)] {
                XCTAssertFalse(holds(rig.panel, view), "step \(step): Tab landed on the hidden \(name)")
            }
        }
        print("HIDDEN_TAB landed=\(landed)")
    }

    // MARK: Show order: the page's own claim and the first key still land

    func testSwitchToDrawGivesTheBoardTheKeyboardAndTheFirstKey() throws {
        let rig = try makeRig()
        defer { close(rig) }
        show(.canvas, rig)
        let board = try board(rig)
        show(.calendar, rig)
        show(.canvas, rig)
        XCTAssertTrue(rig.draw.isShown)
        XCTAssertTrue(holds(rig.panel, board), "Draw's claim on show landed (responder \(responderName(rig.panel)))")
        let tool = rig.draw.tool
        try press("e", code: 14, rig)
        XCTAssertNotEqual(rig.draw.tool, tool, "the first key after the switch reached the board")
        XCTAssertEqual(rig.draw.tool, .eraser)
    }

    func testSwitchBackToNotesRestoresTheEditorAndTheFirstKeyLands() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let editor = try openNote(rig, [.text("Restore title"), .text("Restore body")])
        XCTAssertTrue(rig.panel.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        show(.calendar, rig)
        XCTAssertFalse(holds(rig.panel, editor))
        show(.notes, rig, settle: 0.8)
        XCTAssertTrue(holds(rig.panel, editor), "Notes restored its editor's keyboard (responder \(responderName(rig.panel)))")
        try press("Z", code: 6, rig)
        XCTAssertTrue(editor.string.contains("Z"), "the first key after the switch reached the editor")
    }

    /// Tasks claims only while the panel is key (KeptContentHost), so this
    /// runs where the panel can be made key (CI's key-window lane).
    func testSwitchToTasksTheHostClaimsTheKeyboard() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("needs a key panel: runs on CI only")
        }
        let rig = try makeRig()
        defer { close(rig) }
        show(.tasks, rig, settle: 0.8)
        rig.panel.makeKeyAndOrderFront(nil)
        show(.calendar, rig)
        show(.tasks, rig, settle: 0.8)
        let hosts = views(KeptContentHostingView.self, in: rig.panel).filter(\.isInteractive)
        XCTAssertTrue(hosts.contains { holds(rig.panel, $0) },
                      "the Tasks host's claim on show landed (responder \(responderName(rig.panel)))")
    }

    // MARK: Hide path: a responder on a page that hides ends with the window

    func testHidingAPageLeavesNoResponderOnIt() throws {
        let rig = try makeRig()
        defer { close(rig) }
        show(.canvas, rig)
        let board = try board(rig)
        XCTAssertTrue(holds(rig.panel, board))
        show(.tasks, rig)
        XCTAssertFalse(holds(rig.panel, board), "Draw hid with the keyboard on its board")

        let editor = try openNote(rig, [.text("Hide title"), .text("Hide body")])
        XCTAssertTrue(rig.panel.makeFirstResponder(editor))
        show(.tasks, rig)
        XCTAssertFalse(holds(rig.panel, editor), "Notes hid with the keyboard on its editor")

    }
}
