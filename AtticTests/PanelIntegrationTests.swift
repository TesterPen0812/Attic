import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The Phase 1 integration round: the agent's `show` over the real panel
/// (monitor, controller, stores), click-through on a stationary reveal, the
/// retried page release, the key-state rule for older glass controls and
/// the Haptics seam.
@MainActor
final class PanelIntegrationTests: XCTestCase {
    private struct Panel {
        let defaults: UserDefaults
        let suite: String
        let store: TaskStore
        let notes: NoteStore
        let canvasSession: CanvasSession
        let noteDraft: NoteDraftController
        let settings: AppSettings
        let uiState: PanelUIState
        let controller: AtticPanelController
        let monitor: CornerHoverMonitor
        let presenter: PanelAgentPresenter
        let gate: PersistenceGate
    }

    private var panels: [Panel] = []

    override func tearDown() async throws {
        for panel in panels {
            _ = panel.controller.requestHide { _ in }
            panel.defaults.removePersistentDomain(forName: panel.suite)
        }
        panels.removeAll()
        spin(0.4)
    }

    private func makePanel() throws -> Panel {
        let suite = "PanelIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let gate = PersistenceGate()
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, persist: gate.save, attachmentFileStore: makeTestAttachmentFileStore())
        let canvasStore = CanvasStore(container: container)
        let canvasSession = CanvasSession(store: canvasStore)
        let noteDraft = NoteDraftController(noteStore: notes)
        let settings = AppSettings(defaults: defaults)
        let uiState = PanelUIState()
        let controller = AtticPanelController(
            store: store, noteStore: notes, canvasSession: canvasSession,
            noteDraft: noteDraft, settings: settings, uiState: uiState
        )
        let monitor = CornerHoverMonitor(
            settings: settings, panelController: controller, uiState: uiState,
            store: store, noteStore: notes, canvasStore: canvasStore, noteDraft: noteDraft
        )
        let presenter = PanelAgentPresenter(
            uiState: uiState, store: store, noteStore: notes,
            canvasSession: canvasSession, noteDraft: noteDraft,
            reveal: { [weak monitor] section in
                monitor?.revealProgrammatically(section: section, takesKeyboard: false) ?? .refused(.noScreen)
            }
        )
        let panel = Panel(
            defaults: defaults, suite: suite, store: store, notes: notes, canvasSession: canvasSession,
            noteDraft: noteDraft, settings: settings, uiState: uiState, controller: controller,
            monitor: monitor, presenter: presenter, gate: gate
        )
        panels.append(panel)
        return panel
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func hide(_ panel: Panel) {
        var hidden = false
        _ = panel.controller.requestHide { hidden = $0 == .hidden }
        spin(until: { hidden })
        XCTAssertTrue(hidden)
    }

    // MARK: Agent `show` over the real panel

    /// A canvas text editor sets no interaction lock; `show` must still see
    /// it and move nothing: not the page, not the board.
    func testShowNeverInterruptsAnActiveCanvasTextEditor() throws {
        let panel = try makePanel()
        let first = try XCTUnwrap(panel.canvasSession.createCanvas(name: "First"))
        let second = try XCTUnwrap(panel.canvasSession.createCanvas(name: "Second"))
        XCTAssertTrue(panel.canvasSession.selectCanvas(first.id))
        panel.uiState.selectSection(.canvas)
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .canvas), .shown)
        panel.uiState.setPanelKey(true)

        // A real canvas editor holding the keyboard in a visible window.
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 200, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = CanvasSemanticTextEditor(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        editor.onCommit = { true }
        window.contentView?.addSubview(editor)
        window.orderFrontRegardless()
        XCTAssertTrue(window.makeFirstResponder(editor))
        defer {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
        }
        XCTAssertNotNil(CanvasSemanticTextEditor.focusedInVisibleWindow)
        XCTAssertTrue(panel.presenter.isUserTypingInPanel)

        let tools = AgentShellTools()
        tools.presenter = panel.presenter
        let reply = try tools.call(name: "show", arguments: ["item": ["kind": "canvas", "id": second.id.uuidString]])
        XCTAssertTrue(reply.hasPrefix("Not shown: the user is typing"), reply)
        XCTAssertEqual(panel.canvasSession.selectedCanvasID, first.id, "the board did not change under the editor")
        XCTAssertEqual(try tools.call(name: "show", arguments: ["page": "tasks"]).hasPrefix("Not shown"), true)
        XCTAssertEqual(panel.uiState.selectedSection, .canvas, "the page did not change under the editor")

        // Once the editor lets go, the same request shows the board.
        window.makeFirstResponder(nil)
        XCTAssertNil(CanvasSemanticTextEditor.focusedInVisibleWindow)
        XCTAssertEqual(try tools.call(name: "show", arguments: ["item": ["kind": "canvas", "id": second.id.uuidString]]),
                       "Shown: the canvas.")
        XCTAssertEqual(panel.canvasSession.selectedCanvasID, second.id)
    }

    /// A Notes draft that cannot be saved refuses the page change. `show`
    /// reports that as a failure, and nothing moved: the page, the board
    /// (selected only after its page shows) and the draft are untouched.
    func testShowReportsARefusedNotesCloseAndChangesNothing() throws {
        let panel = try makePanel()
        let first = try XCTUnwrap(panel.canvasSession.createCanvas(name: "First"))
        let second = try XCTUnwrap(panel.canvasSession.createCanvas(name: "Second"))
        XCTAssertTrue(panel.canvasSession.selectCanvas(first.id))
        panel.uiState.selectSection(.notes)
        XCTAssertTrue(panel.noteDraft.beginNew())
        panel.noteDraft.body = "Keep this draft"
        panel.gate.shouldFail = true

        let tools = AgentShellTools()
        tools.presenter = panel.presenter
        for arguments: [String: Any] in [["page": "tasks"], ["item": ["kind": "canvas", "id": second.id.uuidString]]] {
            XCTAssertThrowsError(try tools.call(name: "show", arguments: arguments)) { error in
                let message = (error as? AgentToolError)?.message ?? ""
                XCTAssertTrue(message.hasPrefix("Not shown: the note open in Attic could not be saved"), message)
            }
        }
        XCTAssertEqual(panel.uiState.selectedSection, .notes)
        XCTAssertEqual(panel.canvasSession.selectedCanvasID, first.id, "a refused reveal selects no board")
        XCTAssertFalse(panel.controller.isVisibleForPerformanceProbe, "nothing was revealed")
        XCTAssertTrue(panel.noteDraft.isActive)
        XCTAssertEqual(panel.noteDraft.body, "Keep this draft")

        // Saving works again: the same request shows the board.
        panel.gate.shouldFail = false
        XCTAssertEqual(try tools.call(name: "show", arguments: ["item": ["kind": "canvas", "id": second.id.uuidString]]),
                       "Shown: the canvas.")
        XCTAssertEqual(panel.uiState.selectedSection, .canvas)
        XCTAssertEqual(panel.canvasSession.selectedCanvasID, second.id)
        XCTAssertTrue(panel.controller.isVisibleForPerformanceProbe)
        XCTAssertFalse(panel.uiState.isPanelKey, "an agent's show never takes the keyboard")
    }

    func testShowOfATaskAsksTheTasksPageToSelectIt() throws {
        let panel = try makePanel()
        let task = try XCTUnwrap(panel.store.create(title: "Parked", status: .backlog))
        let tools = AgentShellTools()
        tools.presenter = panel.presenter
        XCTAssertEqual(try tools.call(name: "show", arguments: ["item": ["kind": "task", "id": task.id.uuidString]]),
                       "Shown: the task “Parked” on the Tasks page.")
        XCTAssertEqual(panel.uiState.selectedSection, .backlog)
        XCTAssertEqual(panel.uiState.shownItem, AtticItemRef(.task, task.id))
        XCTAssertThrowsError(try tools.call(name: "show", arguments: ["item": ["kind": "task", "id": UUID().uuidString]]))
    }

    // MARK: Click-through on a stationary reveal

    /// The pointer monitor starts before the panel is on screen; a pointer
    /// resting in the corner wedge sends no event. Ordering front resamples,
    /// so the wedge passes clicks through and blank surface keeps them.
    func testAStationaryRevealResamplesClickThrough() throws {
        let panel = try makePanel()
        let screen = try XCTUnwrap(NSScreen.main)
        // Where the panel docks: learned from one reveal, then hidden again.
        XCTAssertTrue(panel.controller.show(on: screen, corner: .topRight))
        let expected = panel.controller.visibleContentFrameForTesting
        hide(panel)
        // The docked corner's wedge: inside the window, outside the squircle.
        let wedge = CGPoint(x: expected.maxX - 2, y: expected.maxY - 2)
        let blank = CGPoint(x: expected.midX, y: expected.midY)
        panel.controller.pointerLocation = { wedge }
        XCTAssertTrue(panel.controller.show(on: screen, corner: .topRight))
        XCTAssertTrue(panel.controller.ignoresMouseEventsForTesting, "a click in the corner wedge reaches the app behind")
        spin(0.4)
        XCTAssertTrue(panel.controller.ignoresMouseEventsForTesting, "still after the reveal animation settles")

        hide(panel)
        panel.controller.pointerLocation = { blank }
        XCTAssertTrue(panel.controller.show(on: screen, corner: .topRight))
        XCTAssertFalse(panel.controller.ignoresMouseEventsForTesting, "a click on blank painted surface stays in Attic")
    }

    // MARK: Released when hidden, retried when work finishes

    func testASkippedReleaseIsRetriedWhenTheImportFinishes() throws {
        let panel = try makePanel()
        let delay = AtticPanelController.pageReleaseDelay
        AtticPanelController.pageReleaseDelay = 0.1
        defer { AtticPanelController.pageReleaseDelay = delay }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.uiState.selectSection(.canvas)
        panel.controller.show(on: screen, corner: .topRight)
        XCTAssertTrue(panel.uiState.isPageContentLoaded)

        // An import is in flight when the panel hides and at the deadline.
        panel.uiState.setInteractionLock(.notesImport, isActive: true)
        hide(panel)
        spin(0.4)
        XCTAssertTrue(panel.uiState.isPageContentLoaded, "the deadline skipped the release: an import is in flight")
        XCTAssertTrue(panel.controller.hasPendingPageReleaseRetryForTesting)

        // Its completion releases the pages, with no timer.
        panel.uiState.setInteractionLock(.notesImport, isActive: false)
        spin(until: { !panel.uiState.isPageContentLoaded })
        XCTAssertFalse(panel.uiState.isPageContentLoaded, "the release ran when the import finished")
        XCTAssertFalse(panel.controller.hasPendingPageReleaseRetryForTesting)
    }

    func testAReleaseWaitingOnAPlacementRetriesWhenItEndsAndARevealCancelsIt() throws {
        let panel = try makePanel()
        let delay = AtticPanelController.pageReleaseDelay
        AtticPanelController.pageReleaseDelay = 0.1
        defer { AtticPanelController.pageReleaseDelay = delay }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.uiState.selectSection(.canvas)
        panel.controller.show(on: screen, corner: .topRight)
        panel.canvasSession.prepareShapePlacement(.rectangle)
        hide(panel)
        spin(0.4)
        XCTAssertTrue(panel.uiState.isPageContentLoaded)
        XCTAssertTrue(panel.controller.hasPendingPageReleaseRetryForTesting)

        // A reveal cancels the waiting release: a visible panel keeps its pages.
        panel.controller.show(on: screen, corner: .topRight)
        XCTAssertFalse(panel.controller.hasPendingPageReleaseRetryForTesting)
        panel.canvasSession.cancelPendingPlacement()
        spin(0.2)
        XCTAssertTrue(panel.uiState.isPageContentLoaded)

        // Hidden again with the placement pending, then it ends.
        panel.canvasSession.prepareShapePlacement(.rectangle)
        hide(panel)
        spin(0.4)
        XCTAssertTrue(panel.uiState.isPageContentLoaded)
        panel.canvasSession.cancelPendingPlacement()
        spin(until: { !panel.uiState.isPageContentLoaded })
        XCTAssertFalse(panel.uiState.isPageContentLoaded)
    }

    // MARK: Pages kept built

    /// A page shown during this reveal stays built behind the current one,
    /// so switching back only shows it; Notes (rebuilt in Phase 2) is never
    /// kept. The hidden release frees the kept pages; Tasks stays built.
    func testShownPagesStayBuiltBehindTheCurrentOneUntilTheHiddenRelease() throws {
        let panel = try makePanel()
        let delay = AtticPanelController.pageReleaseDelay
        AtticPanelController.pageReleaseDelay = 0.1
        defer { AtticPanelController.pageReleaseDelay = delay }
        panel.controller.show(on: try XCTUnwrap(NSScreen.main), corner: .topRight)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks])
        panel.uiState.selectSection(.canvas)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks, .canvas])
        panel.uiState.selectSection(.notes)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks, .canvas, .notes])
        panel.uiState.selectSection(.tasks)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks, .canvas], "Notes is rebuilt each time it shows")
        panel.uiState.prepareBuiltPage(.notes)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks, .canvas])

        hide(panel)
        spin(until: { panel.uiState.builtPages == [.tasks] })
        XCTAssertEqual(panel.uiState.builtPages, [.tasks], "the hidden release frees the pages kept behind Tasks")
        XCTAssertTrue(panel.uiState.isPageContentLoaded, "Tasks stays built")
    }

    func testTheTasksPageIsBuiltOnceTheAppIsIdleAfterLaunch() throws {
        let panel = try makePanel()
        XCTAssertFalse(panel.uiState.isPageContentLoaded)
        panel.controller.buildTasksPageWhenIdle(after: 0)
        spin(until: { panel.uiState.isPageContentLoaded })
        XCTAssertTrue(panel.uiState.isPageContentLoaded)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks])
        XCTAssertFalse(panel.controller.isVisibleForPerformanceProbe, "built while hidden")

        let other = try makePanel()
        other.uiState.selectSection(.canvas)
        other.controller.buildTasksPageWhenIdle(after: 0)
        spin(0.2)
        XCTAssertFalse(other.uiState.isPageContentLoaded, "a heavy page is never built ahead")
    }

    // MARK: Key state, haptics

    /// The older glass controls (Notes, Canvas, subtask and attachment
    /// controls) follow the same rule as the shell: real glass only while
    /// the panel is key; Reduce Transparency is opaque either way.
    func testOlderGlassControlsFollowThePanelsKeyState() {
        XCTAssertEqual(AtticGlassControlTreatment.resolve(
            reduceTransparency: false, controls: PanelKeyTreatment.controls(isPanelKey: true)), .nativeGlass)
        XCTAssertEqual(AtticGlassControlTreatment.resolve(
            reduceTransparency: false, controls: PanelKeyTreatment.controls(isPanelKey: false)), .drawn)
        XCTAssertEqual(AtticGlassControlTreatment.resolve(reduceTransparency: true, controls: .liquidGlass), .opaque)
        XCTAssertEqual(AtticGlassControlTreatment.resolve(reduceTransparency: true, controls: .craft), .opaque)
    }

    func testThePanelFollowsTheHapticsSetting() throws {
        let suite = "PanelIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.panelHapticsEnabled)
        settings.hapticsEnabled = false
        XCTAssertFalse(settings.panelHapticsEnabled)
    }
}
