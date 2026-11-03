import AppKit
import ObjectiveC
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
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, persist: gate.save, attachmentFileStore: makeTestAttachmentFileStore()))
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

    // Retaining Notes must retain its native editor without retaining input ownership.
    private func followupNotes() async throws -> (Panel, NoteSession, NoteEditorTextView) {
        let panel = try makePanel()
        await panel.noteDraft.pages.startAndWait()
        panel.uiState.selectSection(.notes)
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .notes, takesKeyboard: false), .shown)
        spin(until: { panel.noteDraft.pages.active?.engine.textView != nil })
        let session = try XCTUnwrap(panel.noteDraft.pages.active)
        let editor = try XCTUnwrap(session.engine.textView)
        return (panel, session, editor)
    }

    private func followupSwitch(_ panel: Panel, to section: PanelSection) {
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: section, takesKeyboard: false), .shown)
        spin(0.4)
    }

    func testFollowupKeptNotesSavesAnEditOnLeaving() async throws {
        let (panel, session, editor) = try await followupNotes()
        editor.insertText("Durable on leave", replacementRange: NSRange(location: 0, length: 0))
        followupSwitch(panel, to: .tasks)
        let fresh = ModelContext(panel.notes.container)
        let rows = try fresh.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(rows.first { $0.id == session.noteID }?.title, "Durable on leave")
        XCTAssertTrue(session.engine.textView === editor, "leaving must retain the built editor")
        followupSwitch(panel, to: .notes)
        XCTAssertTrue(session.engine.textView === editor, "returning must reuse the same native editor")
        XCTAssertFalse(editor.isSuspended)
    }

    func testFollowupKeptNotesReleasesInputAndAgentLocks() async throws {
        let (panel, session, editor) = try await followupNotes()
        editor.insertText("Releasable", replacementRange: NSRange(location: 0, length: 0))
        followupSwitch(panel, to: .tasks)
        XCTAssertTrue(panel.uiState.builtPages.contains(.notes), "the page stays built")
        XCTAssertTrue(session.engine.textView === editor)
        XCTAssertTrue(editor.isSuspended, "a retained hidden editor must reject late input")
        XCTAssertFalse(editor.isEditable)
        let text = editor.string
        editor.insertText("stray", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, text)
        if case .direct = panel.notes.agentWriteDisposition(session.noteID) {} else {
            XCTFail("a clean hidden note must release the visible-editor write lock")
        }
        XCTAssertFalse(panel.uiState.interactionLockReasons.contains(.notesEditorFocus))
        XCTAssertFalse(panel.uiState.interactionLockReasons.contains(.notesPopover))
    }

    func testFollowupKeptNotesRefreshesImportedContextBeforePresentation() async throws {
        let (panel, session, _) = try await followupNotes()
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0),
            with: NSAttributedString(string: "Before import"), name: "Type"))
        followupSwitch(panel, to: .tasks)
        XCTAssertTrue(panel.uiState.builtPages.contains(.notes))
        let oldContext = panel.notes.modelContext
        let other = trackAttachmentReconciliation(of: NoteStore(container: panel.notes.container,
            attachmentFileStore: makeTestAttachmentFileStore()))
        let revision = try XCTUnwrap(other.note(withID: session.noteID)?.revisionID)
        _ = try other.saveDocument(noteID: session.noteID,
            document: NoteDocument(blocks: [.text("Imported writing")]), baseRevisionID: revision).get()
        panel.notes.refresh()
        XCTAssertFalse(panel.notes.modelContext === oldContext, "imports replace the context")
        followupSwitch(panel, to: .notes)
        XCTAssertEqual(panel.noteDraft.pages.active?.engine.plainText, "Imported writing")
        XCTAssertFalse(panel.noteDraft.pages.active?.engine === session.engine, "stale engine is replaced before showing")
    }

    func testFollowupKeptNotesFailedSaveRollsBackAndRefusesLeaving() async throws {
        let (panel, session, editor) = try await followupNotes()
        editor.insertText("Original", replacementRange: NSRange(location: 0, length: 0))
        followupSwitch(panel, to: .tasks)
        XCTAssertTrue(panel.uiState.builtPages.contains(.notes), "failure path also retains Notes")
        followupSwitch(panel, to: .notes)
        XCTAssertTrue(session.engine.textView === editor, "failure path uses the retained editor too")
        let live = try XCTUnwrap(session.engine.textView)
        live.insertText(" unsaved", replacementRange: NSRange(location: live.string.utf16.count, length: 0))
        panel.gate.shouldFail = true
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .refused(.unsavedNote))
        XCTAssertEqual(panel.uiState.selectedSection, .notes)
        XCTAssertEqual(session.engine.plainText, "Original unsaved", "the draft remains available for retry")
        let fresh = ModelContext(panel.notes.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<NoteItem>()).first { $0.id == session.noteID }?.title, "Original")
        XCTAssertFalse(panel.notes.modelContext.hasChanges, "failed save rolls back staging")
        panel.gate.shouldFail = false
        followupSwitch(panel, to: .tasks)
        XCTAssertEqual(panel.notes.note(withID: session.noteID)?.title, "Original unsaved")
    }

    func testFollowupHiddenNotesCannotConsumeFindEscapeOrReclaimFocus() async throws {
        var chrome: NotesPageChrome?
        NotesEditorPage.lifetimeProbe = { value, _ in chrome = value }
        defer { NotesEditorPage.lifetimeProbe = nil }
        let (panel, session, editor) = try await followupNotes()
        session.engine.find.show()
        XCTAssertTrue(session.engine.find.isShown)
        let controls = try XCTUnwrap(chrome?.controls)
        followupSwitch(panel, to: .tasks)
        XCTAssertFalse(session.engine.find.isShown, "Find releases its input without refocusing on leave")
        let window = try XCTUnwrap(editor.window)
        window.makeFirstResponder(nil)
        let responder = window.firstResponder
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertFalse(controls.handleKey(escape), "hidden controls cannot take another page's Escape")
        editor.restoreInputFocus()
        XCTAssertTrue(window.firstResponder === responder, "late focus restoration cannot focus hidden Notes")
    }

    func testFollowupHiddenNotesLibraryReleasesItsNativeKeyboardMonitor() async throws {
        var keys: NotesLibraryKeys?
        NotesLibraryView.lifetimeProbe = { keys = $0 }
        defer { NotesLibraryView.lifetimeProbe = nil }
        let (panel, _, _) = try await followupNotes()
        XCTAssertTrue(panel.noteDraft.pages.showLibrary()); spin(0.3)
        let libraryKeys = try XCTUnwrap(keys)
        XCTAssertNotNil(libraryKeys.handler)
        followupSwitch(panel, to: .tasks)
        XCTAssertNil(libraryKeys.handler, "the hidden library cannot handle typing, Return, delete or Undo")
        followupSwitch(panel, to: .notes)
        XCTAssertNotNil(libraryKeys.handler, "the same built library resumes its keys")
        XCTAssertNotNil(libraryKeys.window)
    }

    func testFollowupHiddenNotesRefusesLateTableInput() async throws {
        let panel = try makePanel()
        let (id, _) = try panel.notes.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Table"), .table(.blank()), .text("After")])).get()
        await panel.noteDraft.pages.startAndWait()
        XCTAssertTrue(panel.noteDraft.pages.open(noteID: id))
        followupSwitch(panel, to: .notes)
        let session = try XCTUnwrap(panel.noteDraft.pages.active)
        let engine = session.engine
        let blockID = try XCTUnwrap(engine.document().blocks.first { $0.kind == .table }?.id)
        let attachment = try XCTUnwrap(engine.tableAttachment(id: blockID)?.0)
        engine.enterTable(attachment, at: .init(row: 1, column: 0), caret: .start)
        spin(0.2)
        let cell = attachment.tableView.editor
        followupSwitch(panel, to: .tasks)
        let before = engine.document()
        cell.insertText("late", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(engine.document(), before, "retaining the table cannot retain permission to edit it")
        XCTAssertFalse(engine.allowsTableCellEdit)
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

    func testNativePanelAndIslandStayActiveWithoutChangingKeyboardOwnership() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        let rig = try makePanel()
        XCTAssertEqual(rig.monitor.revealProgrammatically(section: .tasks), .shown)
        spin(0.3)
        let panel = rig.controller.panelForTesting
        let island = rig.controller.islandWindowsForTesting.island
        func appearance(_ window: NSWindow) throws -> Bool {
            let selector = NSSelectorFromString("_hasActiveAppearance")
            let method = try XCTUnwrap(class_getInstanceMethod(type(of: window), selector))
            typealias Read = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method_getImplementation(method), to: Read.self)(window, selector)
        }
        // The released keyboard state still changes. Native appearance must
        // stay active through it without acquiring or moving the keyboard.
        let key = panel.isKeyWindow, islandKey = island.isKeyWindow
        let responder = panel.firstResponder
        let active = NSRunningApplication.current.isActive
        for releasedLook in [false, true, false] {
            rig.uiState.setPanelKey(releasedLook)
            XCTAssertTrue(try appearance(panel), "glass stays active before and after release")
            XCTAssertTrue(try appearance(island), "the island agrees independently of keyboard state")
            XCTAssertEqual(panel.isKeyWindow, key)
            XCTAssertEqual(island.isKeyWindow, islandKey)
            XCTAssertTrue(panel.firstResponder === responder)
            XCTAssertEqual(NSRunningApplication.current.isActive, active)
        }
    }

    func testActivationDuringAndAfterAHideNeverSupersedesTheHide() throws {
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        for pinned in [false, true] {
            let rig = try makePanel()
            XCTAssertEqual(rig.monitor.revealProgrammatically(section: .tasks), .shown)
            spin(0.8)
            rig.uiState.isPanelPinned = pinned
            var result: PanelHideCompletion?
            let hides = rig.uiState.hideCount
            _ = rig.controller.requestHide { result = $0 }
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            spin(until: { result != nil })
            XCTAssertEqual(result, .hidden, "activation must not invalidate the accepted hide")
            XCTAssertFalse(rig.controller.isPanelVisible)
            XCTAssertEqual(rig.uiState.hideCount, hides + 1)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            spin(0.1)
            XCTAssertFalse(rig.controller.isPanelVisible, "late activation cannot restore hidden presentation")
            XCTAssertEqual(rig.uiState.hideCount, hides + 1)
        }
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
        panel.noteDraft.pages.start()
        XCTAssertTrue(panel.noteDraft.pages.newNote())
        XCTAssertTrue(try XCTUnwrap(panel.noteDraft.pages.active).engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Keep this draft"), name: "Type"))
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
        XCTAssertNotNil(panel.noteDraft.pages.active)
        XCTAssertEqual(panel.noteDraft.pages.active?.engine.plainText, "Keep this draft")

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
    /// controls) keep real glass before a click, as the shell does;
    /// Reduce Transparency remains opaque either way.
    func testOlderGlassControlsStayGlassWithoutThePanelsKeyboard() {
        XCTAssertEqual(AtticGlassControlTreatment.resolve(
            reduceTransparency: false, controls: PanelKeyTreatment.controls(isPanelKey: true)), .nativeGlass)
        XCTAssertEqual(AtticGlassControlTreatment.resolve(
            reduceTransparency: false, controls: PanelKeyTreatment.controls(isPanelKey: false)), .nativeGlass)
        XCTAssertEqual(AtticGlassControlTreatment.resolve(reduceTransparency: true, controls: .liquidGlass), .opaque)
        XCTAssertEqual(AtticGlassControlTreatment.resolve(reduceTransparency: true, controls: .craft), .opaque)
    }

    /// Swipe to close works pinned too (owner, 2026-10-02): the pull's request
    /// hides the panel, tells the hover monitor (which then needs the pointer
    /// to leave the hotspot before a reveal: `CornerHoverStateMachineTests`'
    /// `testInteractiveForceHide...`), and leaves the pin as it was.
    func testAPinnedPanelClosesOnAPullAndStaysPinned() throws {
        let panel = try makePanel()
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks), .shown)
        spin(until: { panel.controller.isVisibleForPerformanceProbe })
        panel.uiState.isPanelPinned = true
        var completions = 0
        let original = panel.controller.onInteractiveHideCompleted
        panel.controller.onInteractiveHideCompleted = { completions += 1; original?() }

        panel.controller.panelForTesting.onTrackpadDismissRequest?()
        spin(until: { !panel.controller.isVisibleForPerformanceProbe })

        XCTAssertFalse(panel.controller.isVisibleForPerformanceProbe, "a pinned panel closes on a fresh pull")
        XCTAssertEqual(completions, 1, "the hover monitor is told, so it does not re-show the panel at once")
        XCTAssertTrue(panel.uiState.isPanelPinned, "closing by swipe does not change the pin")
        spin(0.6)
        XCTAssertFalse(panel.controller.isVisibleForPerformanceProbe, "and it stays hidden")
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
