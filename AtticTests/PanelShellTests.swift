import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The Phase 1 shell: pages and the header, the Undo toast, the error
/// notice, menus, the key-window treatment, releasing pages when hidden and
/// the agent's `show` tool.
@MainActor
final class PanelShellTests: XCTestCase {
    // MARK: Pages and the header

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

    func testPageSwitchWidthIsFixedAndMatchesTheDesignSystemGeometry() {
        let geometry = AtticPageSwitch<PanelPage>.Geometry(titles: PanelPage.allCases.map(\.title))
        XCTAssertEqual(PanelHeaderLayout.pageSwitchWidth, geometry.innerWidth + 2 * AtticControlSize.capsuleInset)
        for selected in 0..<3 {
            let total = (0..<3).map { geometry.width(of: $0, selected: selected) }.reduce(0, +) + 2 * geometry.spacing
            XCTAssertEqual(total, geometry.innerWidth, accuracy: 0.001, "the switch is the same width whichever page is selected")
        }
        // v9 (owner, 2026-09-26): the header's controls are 34 tall.
        XCTAssertEqual(PanelHeaderLayout.height, 34)
        XCTAssertEqual(PanelHeaderLayout.pinSize, CGSize(width: 38, height: 34))
    }

    func testPageLayoutUsesTheCornerAwareInsetsAndPlacesTheHeaderBand() {
        let size = CGSize(width: 320, height: 520)
        for corner in [10.0, 52, 80, 140] {
            let layout = PanelPageLayout(cornerSize: corner, panelSize: size)
            XCTAssertEqual(layout.contentInsets, PanelGeometry.contentInsets(cornerSize: corner, panelSize: size))
            XCTAssertEqual(layout.chromeInsets, PanelGeometry.chromeInsets(cornerSize: corner, panelSize: size))
            XCTAssertEqual(layout.headerBottom, layout.chromeInsets.top + 34)
        }
        // v9: the controls sit 12 from every edge at the default corner,
        // and move inward with larger corners.
        XCTAssertEqual(PanelPageLayout(cornerSize: 52, panelSize: size).chromeInsets.top, 12)
        XCTAssertGreaterThan(PanelPageLayout(cornerSize: 140, panelSize: size).chromeInsets.top, 12)
    }

    // MARK: Key window

    /// Native Liquid Glass renders flat in a window that is not key; the
    /// panel draws its controls in the Craft style until it is key.
    func testControlsAreGlassOnlyWhileThePanelIsKey() {
        XCTAssertEqual(PanelKeyTreatment.controls(isPanelKey: true), .liquidGlass)
        XCTAssertEqual(PanelKeyTreatment.controls(isPanelKey: false), .craft)
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
        XCTAssertEqual(commands.map(\.title), ["Show Attic", "New task", "New note", "Search", "Settings…", "Quit Attic"])
        XCTAssertEqual(commands[1].shortcut, KeyboardShortcut("t", modifiers: [.command, .option]))
        XCTAssertEqual(commands[4].shortcut, KeyboardShortcut(",", modifiers: .command))
        XCTAssertEqual(commands[5].shortcut, KeyboardShortcut("q", modifiers: .command))
        XCTAssertEqual(commands.map(\.startsSection), [false, true, false, false, true, true])
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
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
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
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
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
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
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
