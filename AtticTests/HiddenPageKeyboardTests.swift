import AppKit
import SwiftData
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

    // MARK: The shell hosted directly (review round, 25 Nov)

    /// The panel's own shell (an `AtticPanelHostingView` in an `AtticPanel`
    /// whose page query reads the shell's state, as the controller sets it),
    /// with the Tasks page state in reach.
    private struct Hosted {
        let panel: AtticPanel
        let host: AtticPanelHostingView
        let state: PanelUIState
        let store: TaskStore
        let tasksState: TasksPageState
        let close: () -> Void
    }

    private func makeHosted() throws -> Hosted {
        let suite = "HiddenPageKeyboardHosted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let tasksState = TasksPageState()
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: NoteDraftController(noteStore: notes),
                                     chromeInteractionState: chrome, uiState: state,
                                     settings: AppSettings(defaults: defaults), tasksPageState: tasksState),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        let content = AtticPanelContentContainer(hostingView: host, visibleSize: size, perimeter: 0)
        let panel = AtticPanel(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.showsPageQuery = { [weak state] page in state.map { PanelPage($0.selectedSection) == page } ?? true }
        panel.orderFront(nil)
        return Hosted(panel: panel, host: host, state: state, store: store, tasksState: tasksState) {
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            panel.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// Review P2 (both): a focus request queued before a switch away from
    /// Tasks (the title editor's async claim, a dropdown's give-back) runs
    /// right after the switch, before the Tasks tab host stops being
    /// interactive. The field is the Tasks page's, so it is refused.
    func testASwitchAwayFromTasksRefusesAQueuedFocusRequestToATasksField() throws {
        let rig = try makeHosted()
        defer { rig.close() }
        rig.state.selectSection(.tasks)
        spin(1.5)
        let model = rig.tasksState.model(for: rig.store, toasts: nil)
        let id = try XCTUnwrap(model.rows(for: .now).first?.id, "the seed has a task on Now")
        model.beginEditingTitle(id)
        func titleField() -> AtticTokenTextView? {
            views(AtticTokenTextView.self, in: rig.panel).first { $0.accessibilityIdentifier() == "AtticTitleField" }
        }
        let deadline = Date().addingTimeInterval(5)
        while titleField() == nil, Date() < deadline { spin(0.05) }
        let field = try XCTUnwrap(titleField(), "the row's title editor is built")
        var ancestor = field.superview
        while let view = ancestor, !(view is KeptContentHostingView) { ancestor = view.superview }
        XCTAssertNotNil(ancestor, "the title editor sits in a Tasks tab host")

        rig.panel.makeFirstResponder(nil)  // the controller's resign on a switch
        rig.state.selectSection(.calendar)
        let interactiveAtSwitch = (ancestor as? KeptContentHostingView)?.isInteractive
        var tokenView = field.superview
        while let view = tokenView, !(view is AtticTokenFieldView) { tokenView = view.superview }
        print("HIDDEN_TASKS_FIELD accepts=\(field.acceptsFirstResponder) editable=\(field.isEditable) "
              + "refuses=\(field.refusesKeyboard) inWindow=\(field.window === rig.panel) "
              + "tag=\(String(describing: tokenView.flatMap(PanelPageKeyboard.membership(of:))))")
        let admitted = rig.panel.makeFirstResponder(field)  // the request queued before it
        print("HIDDEN_TASKS_QUEUED hostInteractive=\(String(describing: interactiveAtSwitch)) admitted=\(admitted) "
              + "tag=\(String(describing: PanelPageKeyboard.membership(of: field.superview ?? field)))")
        XCTAssertFalse(holds(rig.panel, field), "right after the switch, a hidden Tasks field took the keyboard")
        spin(0.5)
        XCTAssertFalse(holds(rig.panel, field), "after the switch settled, a hidden Tasks field holds the keyboard")
    }

    /// Review P2 (both), at its cause: a kept host hands its content the
    /// panel's values by name, and the page was not one of them, so a view
    /// made inside a Tasks tab host could not be tagged with its page.
    func testAKeptHostHandsItsContentThePage() {
        final class Seen { var read = false; var page: PanelPage? }
        struct Probe: NSViewRepresentable {
            let seen: Seen
            func makeNSView(context: Context) -> NSView { record(context); return NSView() }
            func updateNSView(_ view: NSView, context: Context) { record(context) }
            private func record(_ context: Context) { seen.read = true; seen.page = context.environment.atticPanelPage }
        }
        let seen = Seen()
        let window = NSWindow(contentRect: CGRect(x: -6_000, y: -6_000, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: KeptContentHost(drawn: true, interactive: true) { Probe(seen: seen) }
            .environment(\.atticPanelPage, .tasks)
            .frame(width: 100, height: 100))
        window.orderFront(nil)
        waitForTestOperation("the probe inside the host read its environment") {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return seen.read
        }
        XCTAssertEqual(seen.page, .tasks, "a view made inside a kept host does not know its page")
    }

    /// Review P1 (opus2) and P2-1 (opus1): the guard rail never fires
    /// without a real shell, and inside one it fires for an untagged view
    /// of ours under the panel's hosting view.
    func testTheGuardRailFiresOnlyInAShellAndThereForAnUntaggedView() throws {
        let previous = PanelPageKeyboard.reportUnknownResponder
        var reports: [String] = []
        PanelPageKeyboard.reportUnknownResponder = { reports.append($0) }
        defer { PanelPageKeyboard.reportUnknownResponder = previous }

        let bare = AtticPanel(contentRect: CGRect(x: -5_000, y: -5_000, width: 300, height: 100),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bare.isReleasedWhenClosed = false
        defer { bare.close() }
        let loose = AtticTokenFieldView(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
        bare.contentView?.addSubview(loose)
        XCTAssertTrue(bare.makeFirstResponder(loose.textView))
        XCTAssertEqual(reports, [], "the guard rail fired in a panel with no shell")
        reports.removeAll()

        let rig = try makeHosted()
        defer { rig.close() }
        spin(0.4)
        let untagged = AtticTokenFieldView(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
        rig.host.addSubview(untagged)
        defer { untagged.removeFromSuperview() }
        XCTAssertTrue(rig.panel.makeFirstResponder(untagged.textView))
        XCTAssertEqual(reports.count, 1, "an untagged view of ours under the shell took the keyboard unreported: \(reports)")
    }
}

// MARK: - Calendar's agenda rows from the keyboard (P1-b's Tab rows)

extension HiddenPageKeyboardTests {
    /// A task due today, so the agenda lists it on Calendar's first show.
    private func seedTodayTask(_ store: TaskStore, title: String) throws -> UUID {
        let id = UUID()
        let context = ModelContext(store.container)
        let task = TaskItem(id: id, title: title, createdAt: Date())
        task.listOrderVersion = TaskItem.currentListOrderVersion
        task.dueDay = DueDay(date: Date(), calendar: .current)
        context.insert(task)
        try context.save()
        store.refresh()
        return id
    }

    /// A key through the app's queue, as a real one comes (SwiftUI's focus
    /// and key presses, and the ring's local monitor, see only these).
    private func queue(_ characters: String, code: UInt16, _ rig: Rig, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.panel.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(event, atStart: false)
            var count = 0
            while count < 64, let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
                count += 1
            }
        }
        spin(0.3)
    }

    // The rows after Tab on an agenda task row (lead's ruling for P1-b,
    // ops/design/page-host-tech-note.md). Each prints a `CAL_ROW` line, so
    // the trunk's run (B) and the branch's (P-cal) sit side by side.

    private struct AgendaRig {
        let rig: Rig
        let task: UUID
        let board: DrawBoardView
        let editor: NoteEditorTextView
        /// The first responder after each Tab on the way to the row.
        let path: [NSResponder?]
    }

    /// Tabs the trunk takes to the agenda's row under Full Keyboard Access
    /// (fka lane runs 45805534219 and 45808994257: `tabs=58`). Calendar's
    /// own page host may not make the way longer.
    private static let trunkTabsToTheAgendaWithFKA = 58

    /// Rigs made in this process (SCRATCH, first-panel trace).
    private static var rigsMade = 0

    /// A SwiftUI focus stand-in of the panel's own hosting view (the tab
    /// bar's stops), not of a kept host.
    private func isRootProxy(_ view: NSView) -> Bool {
        guard String(describing: type(of: view)) == "KeyViewProxy" else { return false }
        var current = view.superview
        while let candidate = current {
            if candidate is KeptContentHostingView { return false }
            current = candidate.superview
        }
        return true
    }

    private func kvName(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        let frame = view.convert(view.bounds, to: nil)
        var name = String(describing: type(of: view))
        if let open = name.firstIndex(of: "<") { name = String(name[..<open]) + "<>" }
        return "\(name)@\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
    }

    private func kvTag(_ view: NSView) -> String {
        var current: NSView? = view
        while let candidate = current {
            if let membership = PanelPageKeyboard.membership(of: candidate) { return "\(membership)" }
            if let host = candidate as? KeptContentHostingView { return "kept(i=\(host.isInteractive))" }
            current = candidate.superview
        }
        return "-"
    }

    /// SCRATCH (first-panel trace): the nextKeyView chain from the tab
    /// bar's last stop, 40 hops, and where Calendar's host sits.
    private func traceChain(_ rig: Rig, _ label: String) {
        let host = calendarHost(rig)
        let bar = views(NSView.self, in: rig.panel).filter(isRootProxy)
        let last = bar.max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        var hops: [String] = []
        var inChain = false
        var seen = Set<ObjectIdentifier>()
        var next: NSView? = last
        while let view = next, hops.count < 40, seen.insert(ObjectIdentifier(view)).inserted {
            if view === host { inChain = true }
            hops.append("\(kvName(view)) tag=\(kvTag(view)) canKey=\(view.canBecomeKeyView) hidden=\(view.isHiddenOrHasHiddenAncestor)")
            next = view.nextKeyView
        }
        var hostIndex = -1
        var count = 0
        seen.removeAll()
        next = rig.panel.contentView
        while let view = next, count < 400, seen.insert(ObjectIdentifier(view)).inserted {
            if view === host { hostIndex = count }
            count += 1
            next = view.nextKeyView
        }
        print("KV1 \(label) fka=\(NSApp.isFullKeyboardAccessEnabled) auto=\(rig.panel.autorecalculatesKeyViewLoop) fr=\(kvName(rig.panel.firstResponder as? NSView)) "
              + "bar=\(bar.count) last=\(kvName(last)) host=\(kvName(host)) hostCanKey=\(host.map { "\($0.canBecomeKeyView)" } ?? "-") "
              + "hostInChainFromBar=\(inChain) hops=\(hops.count) fromContent=\(count) hostIndex=\(hostIndex) "
              + "hostPrev=\(kvName(host?.previousKeyView)) hostNext=\(kvName(host?.nextKeyView)) hostSubviews=\(host?.subviews.count ?? -1)")
        for (index, hop) in hops.enumerated() { print("KV1 \(label) hop[\(index)] \(hop)") }
    }

    /// One line per Tab: where the keyboard landed (class, frame in the
    /// window, page or kept host) and how often that place came up before,
    /// with whether the agenda's row or the event's head has focus.
    private func traceTab(_ rig: Rig, _ label: String, _ step: Int, seen: inout [String: Int], task: UUID?, event: String? = nil) {
        var place = responderName(rig.panel)
        var tag = "-"
        if let view = rig.panel.firstResponder as? NSView {
            let frame = view.convert(view.bounds, to: nil)
            place += " \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
            var current: NSView? = view
            while let candidate = current {
                if let membership = PanelPageKeyboard.membership(of: candidate) { tag = "\(membership)"; break }
                if let host = candidate as? KeptContentHostingView { tag = "kept(interactive=\(host.isInteractive))"; break }
                current = candidate.superview
            }
        }
        let repeats = seen[place, default: 0]
        seen[place] = repeats + 1
        let row = task.map { AtticTaskRow.keyboardStates[$0]?.focused == true } ?? false
        let head = event.map { CalendarEventRow.headFocus[$0] == true } ?? false
        print("CAL_TAB \(label) step=\(step) fr=\(place) tag=\(tag) rep=\(repeats) row=\(row) head=\(head)")
    }

    /// The real shell with Draw and Notes built (hidden pages with views
    /// that can take the keyboard), Calendar shown with one task due today,
    /// the panel key; then Tab until the agenda's row has the keyboard.
    private func agendaRig(file: StaticString = #filePath, line: UInt = #line) throws -> AgendaRig {
        let rig = try makeRig()
        let task = try seedTodayTask(rig.store, title: "Agenda row")
        show(.canvas, rig)
        let board = try board(rig)
        let editor = try openNote(rig, [.text("Agenda title"), .text("Agenda body")])
        show(.calendar, rig, settle: 1.0)
        // Key and active before the first Tab. (The first panel a test
        // process shows can still hold a stale key-view loop; see below.)
        NSApp.activate(ignoringOtherApps: true)
        rig.panel.makeKey()
        let deadline = Date().addingTimeInterval(3)
        while !(NSApp.isActive && rig.panel.isKeyWindow), Date() < deadline { spin(0.05) }
        spin(0.3)
        rig.panel.makeFirstResponder(nil)
        var tabs = 0
        var recalculated = false
        var path: [NSResponder?] = []
        var seen: [String: Int] = [:]
        let fka = NSApp.isFullKeyboardAccessEnabled
        Self.rigsMade += 1
        let traced = fka && Self.rigsMade <= 2 ? "panel\(Self.rigsMade)" : nil
        if let traced { traceChain(rig, "\(traced) before") }
        while AtticTaskRow.keyboardStates[task]?.focused != true, tabs < (fka ? 160 : 40) {
            queue("\t", code: 48, rig)
            assertNoHiddenPage(rig, board: board, editor: editor, "Tab to the row", file: file, line: line)
            tabs += 1
            path.append(rig.panel.firstResponder)
            traceTab(rig, "rig", tabs, seen: &seen, task: task)
            if let traced, tabs <= 8 { traceChain(rig, "\(traced) tab\(tabs)") }
            if !fka, tabs == 4, AtticTaskRow.keyboardStates[task]?.focused != true, !recalculated {
                var chain: [String] = []
                var next = rig.panel.contentView?.nextValidKeyView
                while let view = next, chain.count < 12 { chain.append(String(describing: type(of: view))); next = view.nextValidKeyView; if next === rig.panel.contentView?.nextValidKeyView { break } }
                print("CAL_ROW rig stuck fr=\(responderName(rig.panel)) auto=\(rig.panel.autorecalculatesKeyViewLoop) chain=\(chain)")
                rig.panel.recalculateKeyViewLoop()
                recalculated = true
            }
        }
        print("CAL_ROW rig active=\(NSApp.isActive) key=\(rig.panel.isKeyWindow) fka=\(fka) tabs=\(tabs) recalculated=\(recalculated)")
        XCTAssertEqual(AtticTaskRow.keyboardStates[task]?.focused, true, "Tab reached the agenda's row", file: file, line: line)
        if fka {
            XCTAssertLessThanOrEqual(tabs, Self.trunkTabsToTheAgendaWithFKA,
                                     "with Full Keyboard Access, Tab reaches the agenda's row in no more Tabs than the trunk", file: file, line: line)
        }
        return AgendaRig(rig: rig, task: task, board: board, editor: editor, path: path)
    }

    private func assertNoHiddenPage(_ rig: Rig, board: NSView, editor: NSView, _ step: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        for (name, view) in [("Draw board", board), ("Notes editor", editor)] {
            XCTAssertFalse(holds(rig.panel, view), "\(step): the keyboard is on the hidden \(name)", file: file, line: line)
        }
        if let responder = rig.panel.firstResponder as? NSView {
            XCTAssertTrue(PanelPageKeyboard.mayTakeKeyboard(responder), "\(step): \(responderName(rig.panel)) sits under a hidden page",
                          file: file, line: line)
        }
    }

    /// Calendar's page host (the one kept host that claims no keyboard).
    private func calendarHost(_ rig: Rig) -> KeptContentHostingView? {
        views(KeptContentHostingView.self, in: rig.panel).first { PanelPageKeyboard.membership(of: $0) == .page(.calendar) }
    }

    private func rowState(_ agenda: AgendaRig) -> String {
        let state = AtticTaskRow.keyboardStates[agenda.task]
        return "fr=\(responderName(agenda.rig.panel)) focused=\(state?.focused ?? false) ring=\(state?.ring ?? false) editing=\(state?.editing ?? false)"
    }

    /// (a) Every key the source binds to a focused agenda row acts. The
    /// row's actions (`CalendarAgendaViews.swift` `taskRow`): toggleDone,
    /// openPage, editTitle; its keys (`AtticTaskKeys.command`, list
    /// commands on, `AtticTaskComponents.swift` `AtticTaskRow` body):
    /// Space → toggleDone, Return → editTitle, ⌘Return and ⇧⌘I → openPage.
    /// ⇧Space, Delete, ⌘B, ⌘C and ⌘D map to actions the row does not
    /// offer (`AtticTaskKeys.offers`), so they are not the row's keys.
    func testCalendarAgendaRowAfterTabEveryBoundKeyActs() throws {
        try requireKeyWindowTests()
        struct Key { let name: String; let characters: String; let code: UInt16; let flags: NSEvent.ModifierFlags }
        let keys = [Key(name: "Space", characters: " ", code: 49, flags: []),
                    Key(name: "Return", characters: "\r", code: 36, flags: []),
                    Key(name: "Cmd-Return", characters: "\r", code: 36, flags: .command),
                    Key(name: "Shift-Cmd-I", characters: "i", code: 34, flags: [.command, .shift])]
        for key in keys {
            let agenda = try agendaRig()
            defer { close(agenda.rig) }
            queue(key.characters, code: key.code, agenda.rig, flags: key.flags)
            let acted: Bool = switch key.name {
            case "Space": agenda.rig.store.task(withID: agenda.task)?.status == .done
            case "Return": AtticTaskRow.keyboardStates[agenda.task]?.editing == true
            default: agenda.rig.uiState.openTaskNoteID == agenda.task
            }
            print("CAL_ROW a key=\(key.name) acted=\(acted) \(rowState(agenda))")
            XCTAssertTrue(acted, "\(key.name) on the focused agenda row acts")
            assertNoHiddenPage(agenda.rig, board: agenda.board, editor: agenda.editor, key.name)
        }
    }

    /// (b) The row shows its focus: the ring the row draws from its focus
    /// and the keyboard-driven state (`AtticTaskRow` `showsFocusRing`).
    func testCalendarAgendaRowAfterTabShowsItsFocus() throws {
        try requireKeyWindowTests()
        let agenda = try agendaRig()
        defer { close(agenda.rig) }
        print("CAL_ROW b \(rowState(agenda))")
        XCTAssertEqual(AtticTaskRow.keyboardStates[agenda.task]?.ring, true, "the focused row draws its ring")
    }

    /// (c) Tab and Shift-Tab never reach a hidden page's view: they land on
    /// the agenda's row, Calendar's one Tab stop with full keyboard access
    /// off. (The trunk also stops on a SwiftUI focus host at the top of the
    /// panel's own hosting view, 101×27, where no ring shows and Space,
    /// Return and ↓ do nothing: a dead stop, lead's case 3, 26 Nov.)
    /// Esc hides the panel, as on the trunk (`row_esc panel=false`).
    func testCalendarAgendaRowAfterTabMovesOnAndEscHides() throws {
        try requireKeyWindowTests()
        let agenda = try agendaRig()
        defer { close(agenda.rig) }
        for step in 0..<8 {
            if step < 4 { queue("\t", code: 48, agenda.rig) } else { queue("\t", code: 48, agenda.rig, flags: .shift) }
            print("CAL_ROW c step=\(step) \(step < 4 ? "Tab" : "Shift-Tab") \(rowState(agenda))")
            assertNoHiddenPage(agenda.rig, board: agenda.board, editor: agenda.editor, "step \(step)")
            XCTAssertEqual(AtticTaskRow.keyboardStates[agenda.task]?.focused, true,
                           "step \(step): \(step < 4 ? "Tab" : "Shift-Tab") lands on the agenda's row")
            XCTAssertTrue(holds(agenda.rig.panel, try XCTUnwrap(calendarHost(agenda.rig))), "step \(step): inside Calendar's page host")
        }
        queue("\u{1b}", code: 53, agenda.rig)
        spin(0.4)
        print("CAL_ROW c esc visible=\(agenda.rig.panel.isVisible) \(rowState(agenda))")
        XCTAssertFalse(agenda.rig.panel.isVisible, "Esc hides the panel")
    }

    // FKA rows (CI's fka lane only: `ATTIC_FULL_KEYBOARD_ACCESS_TESTS`,
    // the setting turned on by `Scripts/with_ci_input_modes.sh` on a hosted
    // runner). An event today comes from the UI-testing calendar.

    private func requireFullKeyboardAccess() throws {
        try requireKeyWindowTests()
        guard ProcessInfo.processInfo.environment["ATTIC_FULL_KEYBOARD_ACCESS_TESTS"] == "1" else {
            throw XCTSkip("needs Full Keyboard Access, which only CI's hosted runner may turn on")
        }
        XCTAssertTrue(NSApp.isFullKeyboardAccessEnabled, "the fka lane turned Full Keyboard Access on")
    }

    private func seedTodayEvent() -> CalendarEvent {
        let start = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()
        let event = CalendarEvent(id: "fka-event-\(UUID().uuidString)", title: "FKA event", start: start,
                                  end: start.addingTimeInterval(30 * 60), isAllDay: false, location: nil,
                                  calendarTitle: "Test", colour: CalendarEventColour(red: 0.35, green: 0.55, blue: 0.85))
        UITestingCalendar.isOn = true
        UITestingCalendar.seeded = [event]
        return event
    }

    private func clearTodayEvent() {
        UITestingCalendar.isOn = false
        UITestingCalendar.seeded = []
    }

    private func eventIsOpen(_ event: CalendarEvent) -> Bool {
        CalendarDraftTerminationRegistry.shared.openRows(for: .docked).contains { $0.rowID == event.id }
    }

    /// Return and Space on an event head (`CalendarEventRow`'s `onKeyPress`):
    /// Return opens the row, Space closes it.
    func testFKAEventHeadAnswersReturnAndSpace() throws {
        try requireFullKeyboardAccess()
        let event = seedTodayEvent()
        defer { clearTodayEvent() }
        let agenda = try agendaRig()
        defer { close(agenda.rig) }
        agenda.rig.panel.makeFirstResponder(nil)
        var steps = 0
        var seen: [String: Int] = [:]
        while CalendarEventRow.headFocus[event.id] != true, steps < 160 {
            queue("\t", code: 48, agenda.rig)
            assertNoHiddenPage(agenda.rig, board: agenda.board, editor: agenda.editor, "Tab \(steps) to the event head")
            steps += 1
            traceTab(agenda.rig, "head", steps, seen: &seen, task: agenda.task, event: event.id)
        }
        XCTAssertEqual(CalendarEventRow.headFocus[event.id], true, "Tab reached the event head")
        queue("\r", code: 36, agenda.rig)
        spin(0.4)
        let openedByReturn = eventIsOpen(event)
        queue(" ", code: 49, agenda.rig)
        spin(0.4)
        let closedBySpace = !eventIsOpen(event)
        print("CAL_FKA head tabs=\(steps) return_opens=\(openedByReturn) space_closes=\(closedBySpace) fr=\(responderName(agenda.rig.panel))")
        XCTAssertTrue(openedByReturn, "Return on the event head opens the row")
        XCTAssertTrue(closedBySpace, "Space on the event head closes it")
        assertNoHiddenPage(agenda.rig, board: agenda.board, editor: agenda.editor, "after Return and Space")
    }

    /// The arrows on the agenda (no Calendar binding: SwiftUI moves focus
    /// itself under Full Keyboard Access). Each arrow from the focused row
    /// keeps the keyboard on the shown page; where it lands is printed.
    func testFKAArrowsOnTheAgendaStayOnTheShownPage() throws {
        try requireFullKeyboardAccess()
        let event = seedTodayEvent()
        defer { clearTodayEvent() }
        let agenda = try agendaRig()
        defer { close(agenda.rig) }
        for (name, characters, code) in [("Down", "\u{F701}", UInt16(125)), ("Up", "\u{F700}", UInt16(126)),
                                         ("Right", "\u{F703}", UInt16(124)), ("Left", "\u{F702}", UInt16(123))] {
            queue(characters, code: code, agenda.rig, flags: [.numericPad, .function])
            print("CAL_FKA arrow=\(name) head=\(CalendarEventRow.headFocus[event.id] ?? false) \(rowState(agenda))")
            assertNoHiddenPage(agenda.rig, board: agenda.board, editor: agenda.editor, name)
            XCTAssertTrue(agenda.rig.panel.isVisible, "\(name) leaves the panel up")
        }
    }

    /// The hidden page a responder lies in, by name (a tagged page that is
    /// not shown, or a kept host out of use: the Tasks tab hosts carry no
    /// page tag); nil when it lies in none.
    private func hiddenPage(of responder: NSResponder?, in panel: AtticPanel) -> String? {
        var current = responder as? NSView
        while let candidate = current {
            if case .page(let page)? = PanelPageKeyboard.membership(of: candidate), !panel.showsPage(page) { return page.rawValue }
            if let host = candidate as? KeptContentHostingView, !host.isInteractive { return "tasks (a kept tab host out of use)" }
            current = candidate.superview
        }
        return nil
    }

    /// Shift-Tab leaves Calendar the way Tab came in. The keyboard is put on
    /// the panel's tab bar first (Tab until a stop of the panel's own host
    /// has it), then Tab walks into Calendar to the agenda's row; Shift-Tab,
    /// at most as many times, walks back to the stop Tab entered Calendar
    /// from: the last one on the way in that is neither inside Calendar's
    /// page host nor the responder holding the row (on the trunk Calendar's
    /// controls sit in the panel's own host, so that is the bar stop it
    /// started from). Every press is logged by first responder.
    func testFKAShiftTabLeavesCalendarTheWayItCameIn() throws {
        try requireFullKeyboardAccess()
        let agenda = try agendaRig()
        defer { close(agenda.rig) }
        let panel = agenda.rig.panel
        let host = calendarHost(agenda.rig)
        func inCalendar(_ responder: NSResponder?) -> Bool {
            guard let host, let view = responder as? NSView else { return false }
            return view === host || view.isDescendant(of: host)
        }
        func onBar(_ responder: NSResponder?) -> Bool { (responder as? NSView).map(isRootProxy) ?? false }
        // The tab bar's first stop: the leftmost stop of the panel's own
        // host in the bar's row (`56,461 27x27` in both arms). On the trunk
        // Calendar's controls are stops of that host too, lower down.
        func firstBarStop() -> NSView? {
            let barTop = panel.contentView.map { $0.convert($0.bounds, to: nil).maxY - 100 } ?? 0
            return views(NSView.self, in: panel).filter { isRootProxy($0) && $0.convert($0.bounds, to: nil).minY >= barTop }
                .min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        }
        var seen: [String: Int] = [:]
        var toBar = 0
        while panel.firstResponder !== firstBarStop() || AtticTaskRow.keyboardStates[agenda.task]?.focused == true, toBar < 160 {
            queue("\t", code: 48, agenda.rig)
            toBar += 1
            traceTab(agenda.rig, "to-bar", toBar, seen: &seen, task: agenda.task)
        }
        let start = panel.firstResponder
        XCTAssertTrue(onBar(start) && start === firstBarStop(), "Tab reached the tab bar's first stop")
        var path: [NSResponder?] = []
        seen = [:]
        while AtticTaskRow.keyboardStates[agenda.task]?.focused != true, path.count < 160 {
            queue("\t", code: 48, agenda.rig)
            assertNoHiddenPage(agenda.rig, board: agenda.board, editor: agenda.editor, "Tab \(path.count) into Calendar")
            path.append(panel.firstResponder)
            traceTab(agenda.rig, "in", path.count, seen: &seen, task: agenda.task)
        }
        XCTAssertEqual(AtticTaskRow.keyboardStates[agenda.task]?.focused, true, "Tab from the bar reached the agenda's row")
        let atRow = panel.firstResponder
        let entry = (path.dropLast().last { $0 !== atRow && !inCalendar($0) } ?? nil) ?? start
        var firstOut: NSResponder?
        var back = 0
        seen = [:]
        while back < path.count {
            queue("\u{19}", code: 48, agenda.rig, flags: .shift)
            assertNoHiddenPage(agenda.rig, board: agenda.board, editor: agenda.editor, "Shift-Tab \(back) out of Calendar")
            back += 1
            traceTab(agenda.rig, "back", back, seen: &seen, task: agenda.task)
            let responder = panel.firstResponder
            if firstOut == nil, responder !== atRow, !inCalendar(responder) { firstOut = responder }
            if responder === entry { break }
        }
        let arrived = panel.firstResponder === entry
        print("CAL_FKA back tabs_in=\(path.count) shift_tabs=\(back) start=\(kvName(start as? NSView)) entry=\(kvName(entry as? NSView)) "
              + "first_out=\(kvName(firstOut as? NSView)) arrived=\(arrived) row=\(AtticTaskRow.keyboardStates[agenda.task]?.focused ?? false)")
        XCTAssertTrue(firstOut === entry, "the first stop Shift-Tab reaches outside Calendar is the one Tab entered from")
        XCTAssertTrue(arrived, "Shift-Tab, at most as many times as Tab, lands on the stop Tab entered Calendar from")
    }

    /// With the keyboard inside Calendar (the agenda's row) under Full
    /// Keyboard Access: ⌘Z after Space, Esc, and what the global hotkey
    /// runs (`AppCoordinator.swift` `newTaskHotKey.action` → `showNewTask`
    /// → `revealProgrammatically(openComposer: true, section: .tasks)`).
    func testFKAInsideCalendarUndoEscAndHotkey() throws {
        try requireFullKeyboardAccess()
        do {
            let agenda = try agendaRig()
            defer { close(agenda.rig) }
            queue(" ", code: 49, agenda.rig)
            let afterSpace = agenda.rig.store.task(withID: agenda.task).map { "\($0.status)" } ?? "nil"
            queue("z", code: 6, agenda.rig, flags: .command)
            spin(0.3)
            let afterUndo = agenda.rig.store.task(withID: agenda.task).map { "\($0.status)" } ?? "nil"
            print("CAL_FKA undo after_space=\(afterSpace) after_cmdz=\(afterUndo) visible=\(agenda.rig.panel.isVisible) fr=\(kvName(agenda.rig.panel.firstResponder as? NSView))")
            assertNoHiddenPage(agenda.rig, board: agenda.board, editor: agenda.editor, "⌘Z")
            XCTAssertTrue(agenda.rig.panel.isVisible, "⌘Z leaves the panel up")
            // As on the trunk (fka run 45820518839: `after_space=done after_cmdz=todo`).
            XCTAssertEqual(afterSpace, "done", "Space on the row marks the task done")
            XCTAssertEqual(afterUndo, "todo", "⌘Z undoes it, as on the trunk")
        }
        do {
            let agenda = try agendaRig()
            defer { close(agenda.rig) }
            queue("\u{1b}", code: 53, agenda.rig)
            spin(0.4)
            print("CAL_FKA esc visible=\(agenda.rig.panel.isVisible)")
            XCTAssertFalse(agenda.rig.panel.isVisible, "Esc hides the panel")
        }
        do {
            let agenda = try agendaRig()
            defer { close(agenda.rig) }
            let rig = agenda.rig
            let monitor = CornerHoverMonitor(settings: AppSettings(defaults: rig.defaults), panelController: rig.controller, uiState: rig.uiState,
                                             store: rig.store, noteStore: rig.notes, canvasStore: CanvasStore(container: rig.store.container),
                                             noteDraft: rig.draft)
            defer { monitor.stop() }
            let outcome = monitor.revealProgrammatically(openComposer: true, section: .tasks)
            spin(0.8)
            print("CAL_FKA hotkey outcome=\(outcome) section=\(rig.uiState.selectedSection) composer=\(rig.uiState.isComposerPresented) "
                  + "visible=\(rig.panel.isVisible) key=\(rig.panel.isKeyWindow) fr=\(kvName(rig.panel.firstResponder as? NSView))")
            // As on the trunk (fka run 45820518839: `outcome=shown section=tasks
            // composer=false key=true fr=AtticTokenTextView`): Tasks comes
            // forward with the keyboard in its add bar.
            XCTAssertEqual(outcome, .shown)
            XCTAssertEqual(rig.uiState.selectedSection, .tasks, "the hotkey brings Tasks forward")
            XCTAssertTrue(rig.panel.isKeyWindow, "the panel is key")
            XCTAssertEqual(responderName(rig.panel), "AtticTokenTextView", "the keyboard is in Tasks' add bar, as on the trunk")
            assertNoHiddenPage(rig, board: agenda.board, editor: agenda.editor, "hotkey")
        }
    }

    /// Fix B under Full Keyboard Access, by name: no stop of the panel's
    /// loop lies in a hidden page. Calendar shown (Draw, Notes and the
    /// Tasks tab hosts built and hidden), then Tasks shown after Calendar
    /// held the keyboard (Calendar hidden, never a stop).
    func testFKATabLoopNeverStopsOnAHiddenPage() throws {
        try requireFullKeyboardAccess()
        let agenda = try agendaRig()
        defer { close(agenda.rig) }
        let panel = agenda.rig.panel
        var seen: [String: Int] = [:]
        for step in 1...(agenda.path.count + 12) {
            queue("\t", code: 48, agenda.rig)
            traceTab(agenda.rig, "loop-calendar", step, seen: &seen, task: agenda.task)
            let hidden = hiddenPage(of: panel.firstResponder, in: panel)
            XCTAssertNil(hidden, "Calendar shown, Tab \(step): the stop \(responderName(panel)) lies in the hidden page \(hidden ?? "")")
        }
        show(.tasks, agenda.rig, settle: 1.0)
        panel.makeFirstResponder(nil)
        seen = [:]
        for step in 1...24 {
            queue("\t", code: 48, agenda.rig)
            traceTab(agenda.rig, "loop-tasks", step, seen: &seen, task: nil)
            let hidden = hiddenPage(of: panel.firstResponder, in: panel)
            XCTAssertNil(hidden, "Tasks shown, Tab \(step): the stop \(responderName(panel)) lies in the hidden page \(hidden ?? "")")
        }
        print("CAL_FKA loop calendar_tabs=\(agenda.path.count + 12) tasks_tabs=24")
    }
}
