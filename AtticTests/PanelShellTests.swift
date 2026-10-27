import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The Phase 1 shell: pages and the header, the Undo toast, the error
/// notice, menus, the key-window treatment, releasing pages when hidden and
/// the agent's `show` tool.
@MainActor
final class PanelShellTests: XCTestCase {
    private final class NativeTrackingView: NSView {
        var onDown: ((NSEvent) -> Void)?
        override func mouseDown(with event: NSEvent) { onDown?(event) }
    }

    func testG06NativeTrackingConsumesReleaseAndFinalisesPanelPressExactlyOnce() throws {
        let panel = AtticPanel(contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 300),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let tracker = NativeTrackingView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        panel.contentView = tracker
        let requestedSize = panel.frame.size
        if TestPresentationPolicy.isInvisible {
            // Deliberately request a displayed origin: the host boundary,
            // rather than a fixture's hard-coded coordinates, must protect it.
            panel.setFrameOrigin(try XCTUnwrap(NSScreen.main).frame.origin)
        }
        panel.orderFront(nil)
        if TestPresentationPolicy.isInvisible {
            XCTAssertEqual(panel.frame.size, requestedSize)
            XCTAssertTrue(NSScreen.screens.allSatisfy { !panel.frame.intersects($0.frame) })
            panel.makeKeyAndOrderFront(nil)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.isKeyWindow)
            NSApp.activate()
            XCTAssertFalse(NSApp.isActive)
            panel.setFrameOrigin(try XCTUnwrap(NSScreen.main).frame.origin)
            XCTAssertTrue(NSScreen.screens.allSatisfy { !panel.frame.intersects($0.frame) },
                          "A visible window's frame update must also stay off every display")
            XCTAssertEqual(panel.frame.size, requestedSize)
            // Exercise native cell entry points as well as NSMenu: the
            // bundle canary rejects even transient menu tracking.
            let popup = NSPopUpButton(frame: CGRect(x: 10, y: 10, width: 100, height: 24), pullsDown: false)
            popup.addItem(withTitle: "Invisible menu probe")
            tracker.addSubview(popup)
            let cell = try XCTUnwrap(popup.cell as? NSPopUpButtonCell)
            cell.performClick(withFrame: popup.bounds, in: popup)
            cell.attachPopUp(withFrame: popup.bounds, in: popup)
            // Eager titled initialization can recenter internally before
            // returning, even when its requested content rect is off-screen.
            let titled = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            titled.isReleasedWhenClosed = false
            defer { titled.close() }
            XCTAssertTrue(NSScreen.screens.allSatisfy { !titled.frame.intersects($0.frame) })
            XCTAssertEqual(titled.contentView?.bounds.size, CGSize(width: 320, height: 500))
            XCTAssertGreaterThan(titled.windowNumber, 0, "eager initialization still creates the backing window")
            XCTAssertFalse(titled.isVisible, "eager initialization still returns a hidden window")
        }
        var presses = 0
        var releases = 0
        panel.onPressEnded = { releases += 1 }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 150, y: 150), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        let up = try event(.leftMouseUp)
        tracker.onDown = { _ in
            presses += 1
            XCTAssertTrue(panel.isPressing)
            XCTAssertEqual(releases, 0, "key appearance waits until tracking returns")
            NSApp.postEvent(up, atStart: true)
            let consumed = panel.nextEvent(matching: .leftMouseUp, until: Date().addingTimeInterval(1), inMode: .eventTracking, dequeue: true)
            XCTAssertEqual(consumed?.type, .leftMouseUp, "the same dequeue used by the block handle")
            XCTAssertTrue(panel.isPressing, "never finalise during mouseDown dispatch")
            XCTAssertEqual(releases, 0)
        }
        panel.sendEvent(try event(.leftMouseDown))
        XCTAssertEqual(presses, 1, "the native tracking callback must actually run")
        XCTAssertFalse(panel.isPressing, "native tracking already released the button")
        XCTAssertEqual(releases, 1, "the key appearance updates immediately")
        panel.sendEvent(up)
        panel.sendEvent(try event(.mouseMoved))
        XCTAssertEqual(releases, 1, "late events cannot finalise the same press twice")
    }

    // MARK: Pages and the header

    /// A20: every switch, the first and every later one, between every pair
    /// of pages, uses the feel's spring with the pages travelling sideways.
    /// Before, the shell crossfaded for 180 ms whatever the feel, and only
    /// the first visit to Notes looked sprung (the editor's own slide for
    /// the note its session started on).
    func testEveryPageSwitchUsesTheFeelsMotionEveryTime() throws {
        let saved = AtticMotionTuning.current
        defer { AtticMotionTuning.current = saved }
        for feel in [AtticAnimationLevel.lively, .subtle] {
            AtticMotionTuning.current = feel.feel.tuning
            let ui = PanelUIState()
            ui.loadPageContent()
            XCTAssertEqual(PanelPage(ui.selectedSection), .tasks)
            let route: [PanelPage] = [.notes, .tasks, .notes, .tasks, .canvas, .tasks, .canvas, .notes, .canvas, .notes, .tasks]
            var used: [PanelPageSwitch] = []
            for page in route {
                ui.switchPage(to: page.section, motion: .current(reduceMotion: false))
                used.append(try XCTUnwrap(ui.lastPageSwitch))
            }
            XCTAssertEqual(used.map(\.to), route)
            let spring = feel.feel.tuning.slide
            XCTAssertGreaterThan(spring.bounce, 0, "\(feel): never a plain fade")
            for (index, record) in used.enumerated() {
                XCTAssertEqual(record.motion, PanelPageMotion(spring: spring), "\(feel) switch \(index) to \(record.to)")
                XCTAssertEqual(record.motion.animation, .spring(duration: spring.response, bounce: spring.bounce))
                XCTAssertNotEqual(record.motion.animation, .spring(duration: 0.18, bounce: 0), "the old crossfade")
            }
            // First and repeated visits to Notes are the same switch.
            XCTAssertEqual(used[0], used[2])
            XCTAssertEqual(used[1], used[3])
            // Sideways in page order: in from its side of the page left, out
            // to its side of the new one.
            XCTAssertEqual(used[0].restingSide(of: .notes), 1, "Tasks → Notes: Notes comes in from the right")
            XCTAssertEqual(used[0].restingSide(of: .tasks), -1, "Tasks goes out to the left")
            XCTAssertEqual(used[1].restingSide(of: .notes), 1, "Notes → Tasks: Notes goes out to the right")
            XCTAssertEqual(used[1].restingSide(of: .tasks), -1, "Tasks comes in from the left")
            XCTAssertEqual(used[7].restingSide(of: .notes), -1, "Canvas → Notes: Notes comes in from the left")
            XCTAssertEqual(used[8].restingSide(of: .notes), -1, "Notes → Canvas: Notes goes out to the left")
            XCTAssertEqual(used[8].restingSide(of: .canvas), 1)
            // A kept page rests on its side of the current page.
            XCTAssertEqual(PanelPage.canvas.side(from: .tasks), 1)
            XCTAssertEqual(PanelPage.tasks.side(from: .canvas), -1)
            XCTAssertEqual(PanelPage.notes.side(from: .notes), 0)
        }
        // Reduce Motion and Animations: Reduced keep their instant switch.
        AtticMotionTuning.current = .lively
        let ui = PanelUIState()
        ui.loadPageContent()
        ui.switchPage(to: .notes, motion: .current(reduceMotion: true))
        XCTAssertEqual(ui.lastPageSwitch?.motion, .instant)
        XCTAssertNil(ui.lastPageSwitch?.motion.animation)
        XCTAssertEqual(ui.lastPageSwitch?.restingSide(of: .notes), 0, "no travel")
        XCTAssertNil(AtticMotionPreset.pageSwitch.animation(reduceMotion: true))
        // The cause: the Notes editor's springy slide no longer plays for the
        // note the page opens on, only for a new or another note.
        XCTAssertNil(NotesEditorPage.noteSlideAnimation(hasShownNote: false, reduceMotion: false))
        XCTAssertEqual(NotesEditorPage.noteSlideAnimation(hasShownNote: true, reduceMotion: false),
                       AtticMotionPreset.slide.animation(reduceMotion: false))
    }

    /// A20 and N-4: the "New tag" row's + sits in the dots' column, so its
    /// name starts where the tags' names do; the tick's column is at the end.
    func testTheNewTagRowsPlusSitsInTheDotColumn() {
        let m = AtticDropdownMetrics.self
        let name = String(localized: "New tag “#plan”")
        XCTAssertEqual(AtticTagPicker.rowsWidth(tags: [], create: "plan"),
                       ceil(m.rowPadding * 2 + m.dotSlot + m.columnGap + AtticTextStyle.dropdownRow.measuredWidth(name)
                            + m.columnGap + m.checkSlot))
    }

    func testSectionsMapToThreePagesAndTasksAlwaysOpensOnNow() {
        XCTAssertEqual(PanelPage(.tasks), .tasks)
        XCTAssertEqual(PanelPage(.backlog), .tasks, "Backlog is part of the Tasks page")
        XCTAssertEqual(PanelPage(.notes), .notes)
        XCTAssertEqual(PanelPage(.canvas), .canvas)
        XCTAssertEqual(PanelPage.tasks.section, .tasks)
        XCTAssertEqual(PanelPage.allCases.map(\.title), ["Tasks", "Notes", "Canvas"])
    }

    func testPageSwitchItemsCarryCommandDigitsAndStableIdentifiers() {
        let items = PanelPage.switchItems
        XCTAssertEqual(items.map { $0.keyEquivalent?.character }, ["1", "2", "3"])
        XCTAssertEqual(items.map(\.shortcut), ["⌘1", "⌘2", "⌘3"])
        XCTAssertEqual(items.map(\.accessibilityIdentifier), ["panel-section-tasks", "panel-section-notes", "panel-section-canvas"])
    }

    /// Phase 0's symmetrical top: the pin and the page button are equal
    /// 36 pt squares; the page button opens leftward to 96, the region the
    /// header's hit testing keeps for it.
    /// Chrome B (Notes v2, owner 2026-10-08): 32 pt squares, the page
    /// button opening to 84 (three 24 pt chips 2 apart in a 4 pt inset).
    /// Control size Medium (owner, 2026-10-20): 30 pt squares, opening to
    /// 78 (three 22 pt chips).
    func testHeaderIsTwoEqualSquaresAndThePageButtonOpensTo84() {
        // The owner's panel design (2026-10-27): a 27 pt pin, the page switch
        // 36 shut (its glyph and a chevron) and 75 open.
        XCTAssertEqual(PanelHeaderLayout.height, 27)
        XCTAssertEqual(PanelHeaderLayout.pinSize, CGSize(width: 27, height: 27))
        XCTAssertEqual(AtticPageButton<PanelPage>.width(open: false, count: PanelPage.allCases.count), 36)
        XCTAssertEqual(PanelHeaderLayout.pageSwitchWidth, 75)
    }

    func testPageLayoutUsesTheCornerAwareInsetsAndPlacesTheHeaderBand() {
        let size = CGSize(width: 320, height: 520)
        for corner in [10.0, 52, 80, 140] {
            let layout = PanelPageLayout(cornerSize: corner, panelSize: size)
            XCTAssertEqual(layout.contentInsets, PanelGeometry.contentInsets(cornerSize: corner, panelSize: size))
            XCTAssertEqual(layout.chromeInsets, PanelGeometry.chromeInsets(cornerSize: corner, panelSize: size))
            XCTAssertEqual(layout.headerBottom, layout.chromeInsets.top + 27)
        }
        // Chrome B: the controls sit 16 from every edge at the default
        // corner (the header 16–46 with Medium's 30 pt controls; it was
        // 16–48), and move inward with larger corners.
        XCTAssertEqual(PanelPageLayout(cornerSize: 52, panelSize: size).chromeInsets.top, 16)
        XCTAssertEqual(PanelPageLayout(cornerSize: 52, panelSize: size).headerBottom, 43)
        XCTAssertGreaterThan(PanelPageLayout(cornerSize: 140, panelSize: size).chromeInsets.top, 16)
    }

    // MARK: Key window

    /// Native Liquid Glass renders flat in a window that is not key; the
    /// panel draws its controls in the Craft style until it is key.
    func testControlsAreGlassOnlyWhileThePanelIsKey() {
        XCTAssertEqual(PanelKeyTreatment.controls(isPanelKey: true), .liquidGlass)
        XCTAssertEqual(PanelKeyTreatment.controls(isPanelKey: false), .craft)
        // Glass and Frosted keep real glass out of focus (Phase 0's weight).
        for surface in [PanelSurfaceStyle.glass, .frosted] {
            XCTAssertEqual(PanelKeyTreatment.controls(isPanelKey: false, surface: surface), .liquidGlass)
            XCTAssertEqual(AtticDesignContext(surface: .glass, reduceTransparency: true,
                                              controls: PanelKeyTreatment.controls(isPanelKey: false, surface: surface)).effectiveControls,
                           .craft, "Reduce Transparency still draws them")
        }
        XCTAssertEqual(PanelKeyTreatment.controls(isPanelKey: false, surface: .solid), .craft)
        let state = PanelUIState()
        XCTAssertFalse(state.isPanelKey)
        state.setPanelKey(true)
        XCTAssertTrue(state.isPanelKey)
    }

    func testPrimaryInputFocusRequestsAreDistinctEvents() {
        let state = PanelUIState()
        let first = state.primaryInputFocusRequest
        state.requestPrimaryInputFocus()
        state.requestPrimaryInputFocus()
        XCTAssertEqual(state.primaryInputFocusRequest, first &+ 2)
    }

    // MARK: Undo toast

    func testToastShowsRunsItsActionOnceAndDismisses() {
        let toasts = PanelToastCenter()
        var undone = 0
        toasts.show("Task deleted") { undone += 1 }
        XCTAssertEqual(toasts.current?.message, "Task deleted")
        XCTAssertEqual(toasts.current?.actionTitle, "Undo")
        XCTAssertTrue(toasts.hasPendingDismissalForTesting)
        toasts.performAction()
        toasts.performAction()
        XCTAssertEqual(undone, 1, "Undo runs once")
        XCTAssertNil(toasts.current)
        XCTAssertFalse(toasts.hasPendingDismissalForTesting)
    }

    func testToastLeavesByItselfAfterItsHoldAndANewOneReplacesIt() {
        let toasts = PanelToastCenter()
        XCTAssertEqual(toasts.holdDuration, 6, "spec: the Undo toast stays 6 s")
        toasts.holdDuration = 0.05
        var firstUndone = false
        toasts.show("Task deleted") { firstUndone = true }
        toasts.show("Note deleted") {}
        XCTAssertEqual(toasts.current?.message, "Note deleted")
        toasts.performAction()
        XCTAssertFalse(firstUndone, "a replaced toast's action is gone")

        toasts.show("Canvas deleted") {}
        let gone = expectation(description: "dismissed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertNil(toasts.current)
            gone.fulfill()
        }
        wait(for: [gone], timeout: 2)
    }

    func testHoveringKeepsTheToastUntilThePointerLeaves() {
        let toasts = PanelToastCenter()
        toasts.holdDuration = 0.05
        toasts.show("Task deleted") {}
        toasts.holdOpen(true)
        XCTAssertFalse(toasts.hasPendingDismissalForTesting)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertNotNil(toasts.current, "the pointer on the toast holds it open")
        toasts.holdOpen(false)
        XCTAssertTrue(toasts.hasPendingDismissalForTesting)
    }

    // MARK: Menus

    func testMenuBarMenuMatchesTheSpecWithShortcutsShown() {
        let commands = MenuBarCommands.commands(
            advertisedNewTaskShortcut: KeyboardShortcut("t", modifiers: [.command, .option]),
            showPanel: {}, newTask: {}, newNote: {}, search: {}, openSettings: {}, quit: {}
        )
        XCTAssertEqual(commands.map(\.title), ["Show Attic", "New task", "New note", "Search Done Tasks…", "Open", "Settings…", "Quit Attic"])
        XCTAssertEqual(commands[1].shortcut, KeyboardShortcut("t", modifiers: [.command, .option]))
        // Round 10: New note and Search show their keys; Open lists the
        // pages and Pin with theirs.
        XCTAssertEqual(commands[2].shortcut, KeyboardShortcut("n", modifiers: [.command, .shift]))
        XCTAssertEqual(commands[3].shortcut, KeyboardShortcut("f", modifiers: [.command, .shift]))
        XCTAssertEqual(commands[4].children.map(\.title), ["Tasks", "Notes", "Canvas", "Pin Panel"])
        XCTAssertEqual(commands[4].children.map(\.shortcut), [
            KeyboardShortcut("1", modifiers: .command), KeyboardShortcut("2", modifiers: .command),
            KeyboardShortcut("3", modifiers: .command), KeyboardShortcut("p", modifiers: [.command, .shift])
        ])
        XCTAssertEqual(commands[5].shortcut, KeyboardShortcut(",", modifiers: .command))
        XCTAssertEqual(commands[6].shortcut, KeyboardShortcut("q", modifiers: .command))
        XCTAssertEqual(commands.map(\.startsSection), [false, true, false, false, true, true, true])
    }

    func testMenuBarMenuDoesNotAdvertiseARefusedGlobalShortcut() {
        let commands = MenuBarCommands.commands(
            advertisedNewTaskShortcut: nil,
            showPanel: {}, newTask: {}, newNote: {}, search: {}, openSettings: {}, quit: {}
        )
        XCTAssertNil(commands[1].shortcut)
    }

    func testAppearanceChoiceMapsToTheWindowAppearance() {
        XCTAssertNil(AppearancePreference.system.designMode)
        XCTAssertEqual(AppearancePreference.light.designMode, .light)
        XCTAssertEqual(AppearancePreference.dark.designMode, .dark)
        XCTAssertEqual(AtticWindowAppearance.appearance(for: .dark)?.name, .darkAqua)
    }

    // MARK: Released when hidden

    func testPagesAreBuiltOnRevealAndReleasedOnlyWhenHiddenAndSaved() throws {
        let suite = "PanelShellTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let state = PanelUIState()
        let controller = AtticPanelController(
            store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: container)),
            noteDraft: NoteDraftController(noteStore: notes),
            settings: AppSettings(defaults: defaults), uiState: state
        )
        XCTAssertFalse(state.isPageContentLoaded, "nothing is built before the first reveal")
        let screen = try XCTUnwrap(NSScreen.main)
        controller.show(on: screen, corner: .topRight)
        XCTAssertTrue(state.isPageContentLoaded)

        controller.releasePagesIfSafe()
        XCTAssertTrue(state.isPageContentLoaded, "a visible panel keeps its pages")

        var hidden = false
        _ = controller.requestHide { hidden = $0 == .hidden }
        let deadline = Date().addingTimeInterval(3)
        while !hidden, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(hidden)

        controller.releasePagesIfSafe()
        XCTAssertTrue(state.isPageContentLoaded, "the Tasks list is not a heavy view: it stays built")
        state.selectSection(.canvas)

        state.setInteractionLock(.notesImport, isActive: true)
        controller.releasePagesIfSafe()
        XCTAssertTrue(state.isPageContentLoaded, "unfinished work keeps the pages")
        state.setInteractionLock(.notesImport, isActive: false)
        state.setInteractionLock(.quickEntryFocus, isActive: true)
        state.setInteractionLock(.taskComposer, isActive: true)
        controller.releasePagesIfSafe()
        XCTAssertFalse(state.isPageContentLoaded, "focus and the add bar's draft (kept by the shell) do not hold the pages")
        XCTAssertNil(controller.toasts.current)

        controller.show(on: screen, corner: .topRight)
        XCTAssertTrue(state.isPageContentLoaded, "a reveal builds them again")
        _ = controller.requestHide { _ in }
    }

    func testApproachingTheCornerBuildsTheHiddenPanelsPagesOnce() throws {
        let suite = "PanelShellTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let state = PanelUIState()
        let controller = AtticPanelController(
            store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: container)),
            noteDraft: NoteDraftController(noteStore: notes),
            settings: AppSettings(defaults: defaults), uiState: state
        )
        state.selectSection(.canvas)
        XCTAssertFalse(state.isPageContentLoaded)
        controller.preparePagesForReveal()
        XCTAssertTrue(state.isPageContentLoaded, "built while the pointer approaches")
        controller.preparePagesForReveal()
        XCTAssertTrue(state.isPageContentLoaded)
        controller.releasePagesIfSafe()
        XCTAssertFalse(state.isPageContentLoaded, "no reveal followed: a heavy page is released again")
    }

    func testOnlyHeavyPagesAreReleasedWhenHidden() {
        XCTAssertFalse(AtticPanelController.releasesWhenHidden(.tasks))
        XCTAssertFalse(AtticPanelController.releasesWhenHidden(.backlog))
        XCTAssertTrue(AtticPanelController.releasesWhenHidden(.notes))
        XCTAssertTrue(AtticPanelController.releasesWhenHidden(.canvas))
    }

    func testHidingDismissesTheToast() throws {
        let suite = "PanelShellTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let controller = AtticPanelController(
            store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: container)),
            noteDraft: NoteDraftController(noteStore: notes),
            settings: AppSettings(defaults: defaults), uiState: PanelUIState()
        )
        controller.show(on: try XCTUnwrap(NSScreen.main), corner: .topRight)
        controller.toasts.show("Task deleted") {}
        var hidden = false
        _ = controller.requestHide { hidden = $0 == .hidden }
        let deadline = Date().addingTimeInterval(3)
        while !hidden, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(hidden)
        XCTAssertNil(controller.toasts.current, "nothing waits on a timer while hidden")
    }

    // MARK: Agent `show`

    private final class FakePresenter: AgentPanelPresenting {
        var outcome: AgentShowOutcome = .shown("the Notes page")
        var targets: [AgentShowTarget] = []
        func presentForAgent(_ target: AgentShowTarget) -> AgentShowOutcome {
            targets.append(target)
            return outcome
        }
    }

    func testShowParsesExactlyOnePageOrItem() throws {
        XCTAssertEqual(try AgentShellTools.target(from: ["page": "notes"]), .page(.notes))
        let id = UUID()
        XCTAssertEqual(
            try AgentShellTools.target(from: ["item": ["kind": "task", "id": id.uuidString]]),
            .item(AtticItemRef(.task, id))
        )
        XCTAssertThrowsError(try AgentShellTools.target(from: [:]))
        XCTAssertThrowsError(try AgentShellTools.target(from: ["page": "backlog"]))
        XCTAssertThrowsError(try AgentShellTools.target(from: ["page": "notes", "item": ["kind": "note", "id": id.uuidString]]))
        XCTAssertThrowsError(try AgentShellTools.target(from: ["item": ["kind": "task", "id": "nope"]]))
    }

    func testShowReportsWhatItShowedAndNeverMovesWhileTheUserTypes() throws {
        let tools = AgentShellTools()
        let presenter = FakePresenter()
        tools.presenter = presenter
        XCTAssertEqual(try tools.call(name: "show", arguments: ["page": "notes"]), "Shown: the Notes page.")
        presenter.outcome = .userIsTyping
        XCTAssertTrue(try tools.call(name: "show", arguments: ["page": "canvas"]).hasPrefix("Not shown: the user is typing"))
        presenter.outcome = .notFound("task")
        XCTAssertThrowsError(try tools.call(name: "show", arguments: ["item": ["kind": "task", "id": UUID().uuidString]]))
        XCTAssertEqual(presenter.targets.count, 3)
    }

    func testMCPListsAndRoutesShowBesideTheTaskTools() throws {
        let store = try makeTestStore()
        let shell = AgentShellTools()
        let presenter = FakePresenter()
        shell.presenter = presenter
        let handler = MCPRequestHandler(tools: AgentTaskTools(store: store), shellTools: shell)

        func send(_ message: [String: Any]) throws -> [String: Any] {
            let body = try JSONSerialization.data(withJSONObject: message)
            let result = handler.handle(body: body, protocolVersion: "2025-06-18")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(result.body)) as? [String: Any])
        }

        let list = try send(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("show"))
        XCTAssertTrue(names.contains("list_tasks"), "the task tools are unchanged")

        let call = try send(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                             "params": ["name": "show", "arguments": ["page": "tasks"]]])
        let result = try XCTUnwrap(call["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(presenter.targets, [.page(.tasks)])
    }
}

// MARK: - UI review 14 (F2): header and page column

@MainActor
extension PanelShellTests {
    /// U-04: shut, the page button's glyph is the pin's: the strong glyph
    /// ink at regular weight (the pin is `emphasisedGlyph`), never the quiet
    /// outline icon that reads as disabled.
    func testU04TheShutPageGlyphMatchesThePin() {
        let shut = AtticPageButtonMetrics.glyphFace(isSelected: true, open: false, accent: false, solid: false)
        XCTAssertEqual(shut.ink, .glyph)
        XCTAssertEqual(shut.weight, .regular)
        XCTAssertEqual(AtticPageButtonMetrics.glyphFace(isSelected: true, open: false, accent: true, solid: false).ink, .glyph,
                       "a Light palette's accent marks the current page only among the others")
        XCTAssertEqual(AtticPageButtonMetrics.glyphFace(isSelected: true, open: true, accent: true, solid: false).ink, .accent)
        XCTAssertEqual(AtticPageButtonMetrics.glyphFace(isSelected: true, open: true, accent: true, solid: true).ink, .glyph)
        let other = AtticPageButtonMetrics.glyphFace(isSelected: false, open: true, accent: false, solid: false)
        XCTAssertEqual(other.ink, .icon)
        XCTAssertEqual(other.weight, AtticIconWeight.outline)
    }

    /// U-42: a panel wider than the reading width keeps a centred column of
    /// that width; at and under it nothing changes.
    func testU42AWidePanelKeepsAReadingColumn() {
        let narrow = PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 320, height: 520))
        XCTAssertEqual(narrow.readingColumn(), narrow)
        let wide = PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 1700, height: 520))
        let column = wide.readingColumn()
        let extra = (1700 - PanelPageLayout.readingWidth) / 2
        XCTAssertEqual(column.chromeInsets.leading, wide.chromeInsets.leading + extra, accuracy: 0.5)
        XCTAssertEqual(column.chromeInsets.trailing, wide.chromeInsets.trailing + extra, accuracy: 0.5)
        XCTAssertEqual(column.contentInsets.leading, wide.contentInsets.leading + extra, accuracy: 0.5)
        XCTAssertEqual(column.chromeInsets.top, wide.chromeInsets.top, "the header row keeps its place")
        XCTAssertEqual(column.panelSize, wide.panelSize)
    }
}
