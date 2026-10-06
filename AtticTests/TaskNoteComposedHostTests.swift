import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Phase 3 slice 0b round 2a: the composed task-note host and the § 9.1
/// feasibility gate, headless (offscreen windows, never key; no app launch).
@MainActor
final class TaskNoteComposedHostTests: XCTestCase {
    private var container: ModelContainer!
    private var tasks: TaskStore!
    private var library: AtticLibrary!
    private var notes: NotesPageController!
    private var coordinator: WorkspaceOperationCoordinator!
    private var windows: [NSWindow] = []
    private var presenters: [TaskNotePresenter] = []
    private var openingWindow: NSWindow?

    /// The panel's size and the Notes page's insets (header 76, bottom row).
    private let panel = NSSize(width: 320, height: 520)
    private let topInset: CGFloat = 76
    private let bottomInset: CGFloat = 60
    private let columnInset: CGFloat = 28

    override func setUp() async throws {
        TaskNoteLayoutCounter.enabledForTesting = true
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
    }

    override func tearDown() async throws {
        TaskNoteLayoutCounter.enabledForTesting = false
        for presenter in presenters { _ = await presenter.close() }
        presenters.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
        notes = nil; library = nil; tasks = nil; coordinator = nil; container = nil
    }

    // MARK: Fixtures

    private func mountTaskPage(_ taskID: UUID, in hosting: NSHostingController<AnyView>) async throws -> TaskNotePresenter {
        hosting.rootView = AnyView(TaskNotePageContainer(taskID: taskID, tasks: tasks, controller: notes,
            noteStore: notes.store, layout: PanelPageLayout(cornerSize: 52, panelSize: panel), onClose: {}).id(UUID()))
        hosting.view.layoutSubtreeIfNeeded()
        hosting.view.displayIfNeeded()
        for _ in 0..<30 {
            if let presenter = notes.taskNotePresenter, presenter.host.scrollView.window === hosting.view.window {
                presenters.append(presenter)
                await Task.yield()
                return presenter
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TaskNotePresenter.OpenError.unavailable
    }

    private func sectionHosting() -> NSHostingController<AnyView> {
        let hosting = NSHostingController(rootView: AnyView(Color.clear))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        windows.append(window)
        return hosting
    }

    func testTaskPageDraftCaretAndFoldSurviveTasksThenNotesWithANewContainer() async throws {
        let id = try seed(.boundary), hosting = sectionHosting()
        let uiState = PanelUIState()
        uiState.loadPageContent(); uiState.selectSection(.notes); uiState.openTaskNoteID = id
        let original = try await mountTaskPage(id, in: hosting)
        original.restoreViewStateOnMount()
        type("Reopen draft ", into: original.host.textView)
        original.host.textView.setSelectedRange(NSRange(location: 7, length: 3))
        original.model.setFolded(true)
        original.model.newSubtaskText = "Uncommitted subtask"
        let session = try XCTUnwrap(original.session), lease = original.lease
        let body = original.host.engine.textStorage.string
        for _ in 0..<3 {
            XCTAssertTrue(notes.prepareToLeave(.pageSwitch))
            uiState.selectSection(.tasks)
            hosting.rootView = AnyView(Text("Tasks"))
            hosting.view.layoutSubtreeIfNeeded()
            await Task.yield()
            XCTAssertTrue(notes.taskNotePresenter === original)
            uiState.selectSection(.notes); notes.present()
            let reopened = try await mountTaskPage(try XCTUnwrap(uiState.openTaskNoteID), in: hosting)
            reopened.restoreViewStateOnMount()
            XCTAssertTrue(reopened === original, "a new container resumes the navigation owner's single lease")
            XCTAssertEqual(reopened.lease, lease)
            XCTAssertEqual(reopened.host.engine.textStorage.string, body)
            XCTAssertEqual(reopened.host.textView.selectedRange(), NSRange(location: 7, length: 3))
            XCTAssertTrue(reopened.model.isFolded)
            XCTAssertEqual(reopened.model.newSubtaskText, "Uncommitted subtask")
            XCTAssertTrue(session.usesWorkspaceBinding)
            XCTAssertFalse(hosting.view.window?.isVisible == true)
        }
        let closed = await original.close()
        XCTAssertTrue(closed)
        XCTAssertNil(notes.taskNotePresenter)
        let reopened = try notes.openTaskNote(taskID: id, tasks: tasks, library: library,
            design: .default, columnInset: columnInset, defaults: nil)
        presenters.append(reopened)
        XCTAssertNotEqual(reopened.lease, lease, "Back still revokes the old lease")
    }

    func testTasksThenNotesWhileCheckpointIsPendingKeepsLatestDraftAndCheckpointOwner() async throws {
        let id = try seed(.boundary), barrier = TaskNoteCheckpointBarrier()
        notes = NotesPageController(store: NoteStore(container: container,
            persist: { _ in throw WorkspaceFoundationError.unknown }, attachmentFileStore: makeTestAttachmentFileStore()),
            journal: TaskNoteCheckpointJournal(base: coordinator.journal, barrier: barrier), defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        notes.attachUndoRoute(library.undo)
        let hosting = sectionHosting(), original = try await mountTaskPage(id, in: hosting)
        let session = try XCTUnwrap(original.session), stamp = session.callbackStamp
        type(" pending", into: original.host.textView)
        original.host.textView.setSelectedRange(NSRange(location: 4, length: 0))
        original.model.setFolded(true)
        XCTAssertTrue(notes.prepareToLeave(.pageSwitch), "retained section navigation may queue its checkpoint")
        await barrier.waitUntilStarted()
        hosting.rootView = AnyView(Text("Tasks")); hosting.view.layoutSubtreeIfNeeded()
        await Task.yield()
        notes.present()
        let reopened = try await mountTaskPage(id, in: hosting)
        reopened.restoreViewStateOnMount()
        XCTAssertTrue(reopened === original)
        XCTAssertEqual(reopened.host.textView.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertTrue(reopened.model.isFolded)
        XCTAssertEqual(session.callbackStamp.binding, stamp.binding, "remount does not invalidate the queued checkpoint")
        type(" latest", into: reopened.host.textView)
        let expected = reopened.host.engine.textStorage.string
        await barrier.release()
        let durable = await notes.preserveAllDurably()
        XCTAssertTrue(durable)
        XCTAssertEqual(session.engine.textStorage.string, expected, "the older checkpoint cannot replace current writing")
        let entries = try await coordinator.journal.readRecoveryEntries()
        guard case let .valid(entry, _, _) = try XCTUnwrap(entries.first) else { return XCTFail("missing checkpoint") }
        XCTAssertEqual(NoteContentCodec.decode(entry.content).document?.blocks.dropFirst().map(\.text).joined(separator: "\n"), expected)
        XCTAssertTrue(notes.workspaceIsDurable(session))
    }

    func testNotesPageHostChangesTheRequestedRouteAndKeepsARefusedSurface() async throws {
        let a = try seed(.boundary), b = try XCTUnwrap(tasks.create(title: "Task B")).id
        let draft = NoteDraftController(noteStore: notes.store)
        notes = draft.pages
        notes.attachUndoRoute(library.undo)
        let uiState = PanelUIState()
        uiState.loadPageContent(); uiState.selectSection(.notes); uiState.openTaskNoteID = a
        let hosting = sectionHosting()
        hosting.rootView = AnyView(NotesPageHost(noteStore: notes.store, taskStore: tasks, noteDraft: draft,
            uiState: uiState, layout: PanelPageLayout(cornerSize: 52, panelSize: panel), hasRestoredSession: true))
        func mounted(_ id: UUID) async throws -> TaskNotePresenter {
            for _ in 0..<100 {
                hosting.view.layoutSubtreeIfNeeded()
                if let current = notes.taskNotePresenter, current.taskID == id,
                   current.host.scrollView.window === hosting.view.window {
                    presenters.append(current)
                    return current
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw TaskNotePresenter.OpenError.unavailable
        }
        let first = try await mounted(a)
        uiState.openTaskNoteID = b
        let second = try await mounted(b)
        XCTAssertNil(first.lease)
        uiState.openTaskNoteID = a
        let returned = try await mounted(a)
        XCTAssertNil(second.lease)
        returned.model.beginEditingTitle()
        returned.model.titleEdit.text = "Conflicting draft"
        XCTAssertTrue(library.updateTask(a, title: "Newer title").isApplied)
        uiState.openTaskNoteID = b
        for _ in 0..<100 {
            if uiState.openTaskNoteID == a { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(uiState.openTaskNoteID, a, "a refused navigation restores the requested route")
        XCTAssertTrue(notes.taskNotePresenter === returned)
        XCTAssertNotNil(returned.host.scrollView.window, "the recoverable field remains on its surface")
        XCTAssertEqual(returned.model.titleEdit.text, "Conflicting draft")
        returned.model.cancelTitle()
        uiState.openTaskNoteID = nil
        for _ in 0..<100 {
            if notes.taskNotePresenter == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(notes.taskNotePresenter)
        XCTAssertNil(returned.lease)
    }

    func testOrdinaryNoteNavigationChecksTheActiveCompositionWhileATaskNoteIsBound() async throws {
        let id = try seed(.boundary)
        XCTAssertTrue(notes.newNote())
        let active = try XCTUnwrap(notes.active)
        let (_, view) = active.engine.makeView()
        let presenter = try await mountTaskPage(id, in: sectionHosting())
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        for reason: NotesPageController.LeaveReason in [.openNote, .newNote, .library, .exitToOldPage] {
            XCTAssertFalse(notes.prepareToLeave(reason), "navigation must check the ordinary session being replaced")
        }
        view.unmarkText()
        XCTAssertNotNil(presenter.lease)
    }

    func testOrdinaryNavigationRecordsActiveLeaveVersionWithoutTouchingBoundComposition() async throws {
        let id = try seed(.boundary)
        XCTAssertTrue(notes.newNote())
        let active = try XCTUnwrap(notes.active)
        let (_, view) = active.engine.makeView()
        type("Ordinary note", into: view)
        let durable = await notes.preserveAllDurably()
        XCTAssertTrue(durable)
        let presenter = try await mountTaskPage(id, in: sectionHosting())
        presenter.host.textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(notes.prepareToLeave(.library), "the bound task is not leaving for an ordinary Notes navigation")
        XCTAssertTrue(notes.store.versions(noteID: active.noteID).contains { $0.title == "Ordinary note" })
        XCTAssertTrue(presenter.host.textView.hasMarkedText())
        presenter.host.textView.unmarkText()
    }

    func testRouteChangesFromAToBToAAndToNoTaskReleaseEachOldLease() async throws {
        let a = try seed(.boundary)
        let b = try XCTUnwrap(tasks.create(title: "Task B")).id
        let hosting = sectionHosting()
        let first = try await mountTaskPage(a, in: hosting)
        let changed = await notes.prepareTaskNoteRoute(b)
        XCTAssertTrue(changed)
        let second = try await mountTaskPage(b, in: hosting)
        XCTAssertNil(first.lease)
        XCTAssertFalse(try XCTUnwrap(first.session).usesWorkspaceBinding)
        XCTAssertEqual(second.taskID, b)
        let back = await notes.prepareTaskNoteRoute(a)
        XCTAssertTrue(back)
        let reopened = try await mountTaskPage(a, in: hosting)
        XCTAssertNil(second.lease)
        XCTAssertNotEqual(first.lease, reopened.lease)
        XCTAssertEqual(reopened.taskID, a)
        let left = await notes.prepareTaskNoteRoute(nil)
        XCTAssertTrue(left)
        XCTAssertNil(reopened.lease)
        XCTAssertNil(notes.taskNotePresenter)
    }

    func testRouteChangeWhileCheckpointPendingWaitsAndCommitsFieldsBeforeRelease() async throws {
        let a = try seed(.boundary), barrier = TaskNoteCheckpointBarrier()
        let b = try XCTUnwrap(tasks.create(title: "Task B")).id
        notes = NotesPageController(store: NoteStore(container: container,
            persist: { _ in throw WorkspaceFoundationError.unknown }, attachmentFileStore: makeTestAttachmentFileStore()),
            journal: TaskNoteCheckpointJournal(base: coordinator.journal, barrier: barrier), defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        notes.attachUndoRoute(library.undo)
        let hosting = sectionHosting(), first = try await mountTaskPage(a, in: hosting)
        type(" pending", into: first.host.textView)
        let expected = first.host.engine.textStorage.string
        let route = Task { @MainActor in await notes.prepareTaskNoteRoute(b) }
        await barrier.waitUntilStarted()
        XCTAssertNotNil(first.lease, "A stays mounted and owns its draft while durability is pending")
        XCTAssertTrue(notes.taskNotePresenter === first)
        // Another native field can begin while the close awaits IO.
        first.model.newSubtaskText = "Entered during checkpoint"
        let repeatedClose = Task { @MainActor in await first.close() }
        await barrier.release()
        let result = await route.value, repeated = await repeatedClose.value
        XCTAssertTrue(result)
        XCTAssertTrue(repeated, "overlapping route/Back requests share one close")
        XCTAssertNil(first.lease)
        XCTAssertTrue(tasks.subtasks(of: a).contains { $0.title == "Entered during checkpoint" })
        let second = try await mountTaskPage(b, in: hosting)
        XCTAssertEqual(second.taskID, b)
        let entries = try await coordinator.journal.readRecoveryEntries()
        guard case let .valid(entry, _, _) = try XCTUnwrap(entries.first) else { return XCTFail("missing checkpoint") }
        XCTAssertEqual(NoteContentCodec.decode(entry.content).document?.blocks.dropFirst().map(\.text).joined(separator: "\n"), expected)
    }

    func testRouteReversalToAWhileItsCloseIsPendingReacquiresAAfterDurability() async throws {
        let a = try seed(.boundary), barrier = TaskNoteCheckpointBarrier()
        let b = try XCTUnwrap(tasks.create(title: "Task B")).id
        notes = NotesPageController(store: NoteStore(container: container,
            persist: { _ in throw WorkspaceFoundationError.unknown }, attachmentFileStore: makeTestAttachmentFileStore()),
            journal: TaskNoteCheckpointJournal(base: coordinator.journal, barrier: barrier), defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        notes.attachUndoRoute(library.undo)
        let hosting = sectionHosting(), first = try await mountTaskPage(a, in: hosting)
        type(" pending", into: first.host.textView)
        let body = first.host.engine.textStorage.string, oldLease = first.lease
        let outgoing = Task { @MainActor in await notes.prepareTaskNoteRoute(b) }
        await barrier.waitUntilStarted()
        var reversed = false
        let incoming = Task { @MainActor in
            let result = await notes.prepareTaskNoteRoute(a)
            reversed = true
            return result
        }
        await Task.yield()
        XCTAssertFalse(reversed, "the newest A route must await A's already-started close")
        await barrier.release()
        let left = await outgoing.value, returned = await incoming.value
        XCTAssertTrue(left); XCTAssertTrue(returned)
        let reopened = try await mountTaskPage(a, in: hosting)
        XCTAssertNil(first.lease)
        XCTAssertNotEqual(reopened.lease, oldLease)
        XCTAssertEqual(reopened.host.engine.textStorage.string, body)
    }

    func testRouteChangeRefusesCompositionAndCanRetry() async throws {
        let a = try seed(.boundary), b = try XCTUnwrap(tasks.create(title: "Task B")).id
        let hosting = sectionHosting(), first = try await mountTaskPage(a, in: hosting)
        first.host.textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        let refused = await notes.prepareTaskNoteRoute(b)
        XCTAssertFalse(refused)
        XCTAssertNotNil(first.lease)
        XCTAssertTrue(notes.taskNotePresenter === first)
        first.host.textView.unmarkText()
        let retried = await notes.prepareTaskNoteRoute(b)
        XCTAssertTrue(retried)
        let second = try await mountTaskPage(b, in: hosting)
        XCTAssertEqual(second.taskID, b)
    }

    func testCloseCommitsFieldsAndReviewerSequenceReopensWithoutStaleDraftWarmOrCold() async throws {
        for cold in [false, true] {
            let id = try seed(.boundary), presenter = try open(id), model = presenter.model
            let row = try XCTUnwrap(model.rows.first)
            model.beginEditingTitle()
            model.titleEdit.text = "Draft X"
            model.beginRename(row.id)
            model.renameText = "Renamed on navigation"
            model.newSubtaskText = "Added on navigation"
            let closed = await presenter.close()
            XCTAssertTrue(closed)
            XCTAssertEqual(tasks.task(withID: id)?.title, "Draft X")
            XCTAssertEqual(tasks.task(withID: row.id)?.title, "Renamed on navigation")
            XCTAssertTrue(tasks.subtasks(of: id).contains { $0.title == "Added on navigation" })
            XCTAssertFalse(model.isEditingTitle)
            XCTAssertNil(model.renamingID)
            XCTAssertTrue(model.newSubtaskText.isEmpty)
            XCTAssertNil(model.undoTitleDraft())
            XCTAssertNil(model.undoRenameDraft())
            XCTAssertTrue(library.updateTask(id, title: "Y").isApplied)
            if cold { presenter.session?.taskNotePresentation = nil }
            let reopened = try open(id)
            XCTAssertEqual(reopened.model.head.title, "Y")
            XCTAssertFalse(reopened.model.isEditingTitle)
            XCTAssertTrue(reopened.model.commitTitle())
            XCTAssertEqual(tasks.task(withID: id)?.title, "Y", "Return after reopen never revives Draft X")
        }
    }

    func testConflictingTitleAndRenameKeepNewerValueDraftAndUndoAndRefuseClose() async throws {
        let id = try seed(.boundary), presenter = try open(id), model = presenter.model
        model.beginEditingTitle()
        model.titleEdited(NSRange(location: 0, length: 0), replacement: "Draft ")
        model.titleEdit.text = "Draft " + model.head.title
        XCTAssertTrue(library.updateTask(id, title: "Newer title").isApplied)
        XCTAssertFalse(model.commitTitle())
        let closed = await presenter.close()
        XCTAssertFalse(closed)
        XCTAssertNotNil(presenter.lease)
        XCTAssertTrue(model.isEditingTitle)
        XCTAssertEqual(tasks.task(withID: id)?.title, "Newer title")
        XCTAssertNotNil(model.failure)
        XCTAssertNotNil(model.undoTitleDraft(), "conflict retains the field's original Undo")
        model.cancelTitle()
        XCTAssertNil(model.failure, "cancelling the conflicting title retires its notice")
        let row = try XCTUnwrap(model.rows.first)
        model.beginRename(row.id)
        model.renameEdited(NSRange(location: 0, length: 0), replacement: "Draft ")
        model.renameText = "Draft " + row.title
        XCTAssertTrue(library.updateTask(row.id, title: "Newer subtask").isApplied)
        XCTAssertFalse(model.commitRename())
        let renameClosed = await presenter.close()
        XCTAssertFalse(renameClosed)
        XCTAssertEqual(tasks.task(withID: row.id)?.title, "Newer subtask")
        XCTAssertEqual(model.renameText, "Draft " + row.title)
        XCTAssertNotNil(model.undoRenameDraft())
        model.cancelRename()
        XCTAssertNil(model.failure, "cancelling the conflicting rename retires its notice")
        let resolved = await presenter.close()
        XCTAssertTrue(resolved, "explicit cancellation lets navigation keep the newer values")
        let reopened = try open(id)
        XCTAssertNil(reopened.model.failure, "warm reopen has no obsolete conflict notice")
        XCTAssertEqual(reopened.model.head.title, "Newer title")
    }

    func testUnchangedFieldDraftDoesNotRestoreItsBaseOverExternalChanges() throws {
        let id = try seed(.boundary), model = try open(id).model
        model.beginEditingTitle()
        XCTAssertTrue(library.updateTask(id, title: "Newer title").isApplied)
        XCTAssertTrue(model.commitTitle())
        XCTAssertEqual(tasks.task(withID: id)?.title, "Newer title")
        let row = try XCTUnwrap(model.rows.first)
        model.beginRename(row.id)
        XCTAssertTrue(library.updateTask(row.id, title: "Newer subtask").isApplied)
        XCTAssertTrue(model.commitRename())
        XCTAssertEqual(tasks.task(withID: row.id)?.title, "Newer subtask")
    }

    func testPlainNotesViewAfterComposedUseDoesNotRetainItsDetachedLayoutManager() async throws {
        let id = try seed(.boundary), presenter = try open(id)
        let engine = presenter.host.engine
        let closed = await presenter.close()
        XCTAssertTrue(closed)
        let (_, plain) = engine.makeView()
        let manager = try XCTUnwrap(plain.textLayoutManager)
        engine.detachView()
        XCTAssertNil(manager.textContentManager)
        XCTAssertFalse(engine.keepsComposedViewportWarm)
    }

    func testJustUncheckedBoundarySubtaskMovesUpAfterNoOpPurgeAndUndoes() throws {
        let id = try seed(.boundary), presenter = try open(id), model = presenter.model
        let freeze = try XCTUnwrap(model.rows.first { $0.title == "Freeze strings" })
        let write = try XCTUnwrap(model.rows.first { $0.title == "Write release notes" })
        model.setFocusInside(true)
        XCTAssertTrue(tasks.purgeDeleted(before: .distantPast).isEmpty)
        XCTAssertTrue(model.toggle(freeze.id))
        XCTAssertEqual(model.rows.map(\.id), [write.id, freeze.id], "unchecking holds the row in place")
        XCTAssertTrue(model.move(freeze.id, by: -1))
        model.refresh()
        XCTAssertEqual(model.rows.map(\.id), [freeze.id, write.id])
        XCTAssertNil(model.failure)
        model.undoWorkspace(); model.refresh()
        XCTAssertEqual(model.rows.map(\.id), [write.id, freeze.id])
        model.undoWorkspace(); model.refresh()
        XCTAssertEqual(model.rows.first { $0.id == freeze.id }?.isDone, true)
    }

    func testJustUncheckedSubtaskMovesUpRelativeToItsHeldNeighbourRatherThanItsCanonicalIndex() throws {
        let id = try seed(.heavy), presenter = try open(id, unfolded: true), model = presenter.model
        let export = try XCTUnwrap(model.rows.first { $0.title == "Export the blog posts" })
        let announce = try XCTUnwrap(model.rows.first { $0.title == "Announce the launch" })
        model.setFocusInside(true)
        XCTAssertTrue(model.toggle(export.id))
        XCTAssertEqual(model.rows.filter { !$0.isDone }.last?.id, export.id)
        XCTAssertEqual(tasks.subtasks(of: id).filter { $0.status != .done }.first?.id, export.id)
        XCTAssertTrue(model.move(export.id, by: -1))
        XCTAssertEqual(model.rows.filter { !$0.isDone }.suffix(2).map(\.id), [export.id, announce.id])
        model.undoWorkspace(); model.refresh()
        XCTAssertEqual(model.rows.filter { !$0.isDone }.first?.id, export.id)
        XCTAssertEqual(model.rows.first { $0.id == export.id }?.isDone, false, "Undo reverses the move, not the tick")
    }

    private func seed(_ scenario: TaskNotePreviewSeed.Scenario) throws -> UUID {
        let id = try TaskNotePreviewSeed.seed(scenario, in: container)
        tasks = TaskStore(container: container)
        library = AtticLibrary(tasks: tasks)
        notes = NotesPageController(store: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()),
                                    journal: coordinator.journal, defaults: nil,
                                    saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        // As the app wires it: the Notes page records into the library's route.
        notes.attachUndoRoute(library.undo)
        return id
    }

    private func open(_ taskID: UUID, unfolded: Bool? = nil) throws -> TaskNotePresenter {
        let start = DispatchTime.now().uptimeNanoseconds
        let presenter = try TaskNotePresenter(taskID: taskID, tasks: tasks, library: library, notes: notes,
                                              design: .default, columnInset: columnInset, defaults: nil)
        let initialized = DispatchTime.now().uptimeNanoseconds
        presenters.append(presenter)
        if let unfolded { presenter.model.setFolded(!unfolded) }
        let host = presenter.host
        if openingWindow != nil {
            // The measured page includes its normal native editor controls.
            let controls = NoteFormatControls(engine: host.engine, textView: host.textView, scrollView: host.scrollView,
                                              design: .default, noteID: host.engine.noteID, isNewDraft: false)
            let objects = NoteObjectControls(engine: host.engine, textView: host.textView)
            host.onInvalidate = { controls.invalidate(); objects.invalidate() }
        }
        host.setContentInsets(top: topInset, bottom: bottomInset)
        let window = openingWindow ?? NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.titled],
                                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.scrollView.frame = NSRect(origin: .zero, size: panel)
        window.contentView = host.scrollView
        if openingWindow == nil { windows.append(window) }
        let mounted = DispatchTime.now().uptimeNanoseconds
        host.restack()
        host.scrollToTop()
        let restacked = DispatchTime.now().uptimeNanoseconds
        settle(host.textView)
        if ProcessInfo.processInfo.environment["ATTIC_TASK_NOTE_OPEN_PROFILE"] == "1" {
            let displayed = DispatchTime.now().uptimeNanoseconds
            print("TASKNOTE-PROFILE init \(Double(initialized - start) / 1_000_000) mount \(Double(mounted - initialized) / 1_000_000) restack \(Double(restacked - mounted) / 1_000_000) display \(Double(displayed - restacked) / 1_000_000)")
        }
        return presenter
    }

    private func settle(_ textView: NSTextView) {
        textView.window?.contentView?.layoutSubtreeIfNeeded()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        textView.window?.displayIfNeeded()
        RunLoop.main.run(until: Date())
    }

    private func type(_ text: String, into textView: NSTextView) {
        for character in text {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            settle(textView)
        }
    }

    private func caretIsVisible(_ host: TaskNoteComposedHost, file: StaticString = #filePath, line: UInt = #line) {
        let caret = host.mapper.textRect(for: host.textView.selectedRange())
        XCTAssertNotNil(caret, file: file, line: line)
        guard let caret else { return }
        let visible = host.mapper.unobscuredRect()
        XCTAssertTrue(visible.contains(NSPoint(x: max(visible.minX + 1, caret.minX), y: caret.midY)),
                      "caret \(caret) inside the unobscured \(visible)", file: file, line: line)
    }

    // MARK: § 2.12 body-only projection

    func testTheTaskNoteShowsOnlyTheBodyAndSavesBlockZeroFromTheLiveTitle() throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let engine = presenter.host.engine
        XCTAssertTrue(engine.isBodyOnly)
        XCTAssertEqual(engine.textStorage.string,
                       "Everything that has to be true before 1.0 goes out.\nSam owns the pricing page; I take the checklist.")
        // The first line is body text, never the title's look.
        let font = engine.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, engine.style.bodyFont.pointSize)
        XCTAssertTrue(engine.validate(.paragraph(.body), selection: NSRange(location: 0, length: 0)).enabled,
                      "the first line is formattable body")
        // A rename writes nothing to the note; the next body save carries
        // the live title in block 0.
        XCTAssertTrue(presenter.model.library.updateTask(id, title: "Ship 1.0").isApplied)
        presenter.model.refresh()
        let document = engine.document()
        XCTAssertEqual(document.blocks.first?.text, "Ship 1.0")
        XCTAssertTrue(document.requires.contains("taskNote"))
        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertEqual(document.blocks[1].text, "Everything that has to be true before 1.0 goes out.")
    }

    // MARK: § 9.1 architecture

    func testOneScrollStacksTheHeadTheBlockAndTheTextViewThatNeverScrollsOnItsOwn() throws {
        let id = try seed(.heavy)
        let presenter = try open(id, unfolded: true)
        let host = presenter.host
        XCTAssertTrue(host.textView.superview === host.documentView)
        XCTAssertTrue(host.textView.enclosingScrollView === host.scrollView)
        XCTAssertTrue(host.scrollView.documentView === host.documentView)
        XCTAssertTrue(host.documentView.isFlipped)
        var nested = 0
        func walk(_ view: NSView) { for sub in view.subviews { if sub is NSScrollView { nested += 1 }; walk(sub) } }
        walk(host.documentView)
        XCTAssertEqual(nested, 0, "no nested scroll view")
        XCTAssertEqual(host.headFrame.minY, 0)
        XCTAssertEqual(host.blockFrame.minY, host.headFrame.maxY + TaskNoteMetrics.headToBlock, accuracy: 0.5)
        XCTAssertEqual(host.textView.frame.minY, host.blockFrame.maxY + TaskNoteMetrics.blockToWriting, accuracy: 0.5)
        XCTAssertEqual(host.headFrame.minX, columnInset)
        XCTAssertEqual(host.documentView.frame.height, host.textView.frame.maxY, accuracy: 1)
        // Ten rows (28 pt each), the 28 pt header and Add subtask.
        XCTAssertGreaterThanOrEqual(host.blockFrame.height, CGFloat(10 + 2) * 28)
        // Folded, the block is one line.
        presenter.model.setFolded(true)
        host.restack()
        XCTAssertEqual(host.blockFrame.height, TaskNoteMetrics.blockHeader, accuracy: 1)
    }

    func testTheEditorIsNeverRecreatedAcrossFoldHeadChangesRestackAndALookChange() throws {
        let id = try seed(.heavy)
        let presenter = try open(id)
        let textView = presenter.host.textView
        let engine = presenter.host.engine
        presenter.model.toggleFold(); presenter.host.restack()
        presenter.model.toggleFold(); presenter.host.restack()
        XCTAssertTrue(library.updateTask(id, title: "A much longer title that wraps onto three lines in the narrow panel column").isApplied)
        presenter.model.refresh(); presenter.host.restack()
        var dark = AtticDesignContext.default
        dark.mode = .dark
        presenter.update(design: dark)
        XCTAssertTrue(presenter.model.toggle(tasks.subtasks(of: id)[4].id))
        presenter.host.restack()
        XCTAssertTrue(presenter.host.textView === textView)
        XCTAssertTrue(engine.textView === textView)
        XCTAssertTrue(presenter.session?.engine === engine)
        XCTAssertTrue(presenter.model.library.updateTask(id, title: String(repeating: "A wrapping title ", count: 8)).isApplied)
        presenter.model.refresh()
        presenter.host.restack()
        let readingHeight = presenter.host.headFrame.height
        presenter.model.beginEditingTitle()
        presenter.host.restack()
        XCTAssertLessThan(presenter.host.headFrame.height, readingHeight, "cached head sizing follows the one-line title editor")
        presenter.model.cancelTitle()
        presenter.host.restack()
        XCTAssertEqual(presenter.host.headFrame.height, readingHeight)
        XCTAssertTrue(presenter.host.textView === textView)
    }

    func testExternalRefreshRetiresTheDetachedEditorAndKeepsTypingDurable() async throws {
        let id = try seed(.boundary), presenter = try open(id)
        let session = try XCTUnwrap(presenter.session)
        let mounted = NSHostingView(rootView: TaskNotePage(presenter: presenter, controller: notes,
            noteStore: notes.store, layout: PanelPageLayout(cornerSize: 52, panelSize: panel), onBack: {}))
        let window = try XCTUnwrap(presenter.host.scrollView.window)
        window.contentView = mounted
        mounted.frame = NSRect(origin: .zero, size: panel)
        mounted.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(NoteFormatControls.active?.engine === session.engine)
        let oldView = presenter.host.textView
        let oldEngine = session.engine
        let page = try coordinator.sessions.session(for: .task(id), notes: notes)
        let context = coordinator.freshContext(), noteID = session.noteID
        let replicas = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        let document = try NoteDocument(blocks: [.text("Head"), .text("Imported body")]).taskSnapshot(title: "Head")
        NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: replicas,
                                      timestamp: Date(), revision: 1, revisionID: UUID())
        try context.save()
        page.externalRefresh(origin: "test import")
        mounted.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(NoteFormatControls.active?.engine === session.engine, "formatting follows the imported editor too")
        let host = presenter.host
        XCTAssertFalse(session.engine === oldEngine)
        XCTAssertTrue(host.engine === session.engine, "a mounted host must follow the session's imported engine")
        XCTAssertTrue(host.textView.engine === session.engine)
        XCTAssertTrue(host.mapper.textView === host.textView)
        XCTAssertFalse(oldView.isEditable)
        XCTAssertNil(oldView.superview)
        XCTAssertTrue(host.engine.isBodyOnly)
        XCTAssertEqual(host.engine.textStorage.string, "Imported body")
        host.textView.setSelectedRange(NSRange(location: host.engine.textStorage.length, length: 0))
        type(" saved", into: host.textView)
        let closed = await presenter.close()
        XCTAssertTrue(closed)
        let saved = try XCTUnwrap(notes.store.loadDocument(noteID: noteID)?.content.document)
        XCTAssertEqual(saved.blocks[1].text, "Imported body saved")
        XCTAssertFalse(host.scrollView.window?.isKeyWindow == true)
        XCTAssertFalse(host.scrollView.window?.isVisible == true)
    }

    func testWarmPresentationRetiresTheClosedEditorAndRefreshesTheHeadUnderANewLease() async throws {
        let id = try seed(.heavy), original = try open(id)
        let session = try XCTUnwrap(original.session)
        let oldView = original.host.textView
        let oldViewport = oldView.textLayoutManager
        let oldGeneration = session.engine.viewGeneration
        let oldLease = original.lease
        let oldTitle = original.model.head.title
        let closed = await original.close()
        XCTAssertTrue(closed)
        XCTAssertNil(original.lease)
        XCTAssertNil(session.engine.textView)
        XCTAssertNil(oldView.engine)
        XCTAssertNil(oldView.delegate)
        XCTAssertFalse(oldView.isEditable)
        XCTAssertTrue(oldView.isSuspended)
        let closedBody = session.engine.textStorage.string
        oldView.insertText("late", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(session.engine.textStorage.string, closedBody, "the retained closed editor refuses native input")
        XCTAssertNil(oldView.coordinateMapper)
        XCTAssertTrue(session.taskNotePresentation?.host === original.host)
        XCTAssertNil(original.model.onGeometryChange)
        XCTAssertNil(original.model.onFocusWriting)

        XCTAssertTrue(library.updateTask(id, title: "Changed while closed").isApplied)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(original.model.head.title, oldTitle, "closed native regions do not observe task changes")
        let reopened = try open(id)
        XCTAssertTrue(reopened.session === session)
        XCTAssertTrue(reopened.host === original.host)
        XCTAssertTrue(reopened.model === original.model)
        XCTAssertNil(session.taskNotePresentation, "only the new lease owns the resumed presentation")
        XCTAssertNotEqual(reopened.lease, oldLease)
        XCTAssertEqual(reopened.model.head.title, "Changed while closed")
        XCTAssertEqual(reopened.host.engine.document().blocks.first?.text, "Changed while closed")
        XCTAssertTrue(reopened.host.textView === oldView)
        XCTAssertTrue(reopened.host.textView.textLayoutManager === oldViewport, "unchanged closed sessions keep their viewport warm")
        XCTAssertNotEqual(session.engine.viewGeneration, oldGeneration, "queued native work cannot enter a later lease")
        XCTAssertTrue(reopened.host.textView.isEditable)
        XCTAssertFalse(reopened.host.textView.isSuspended)
        XCTAssertTrue(session.engine.textView === reopened.host.textView)
        XCTAssertTrue(reopened.host.mapper.textView === reopened.host.textView)
        let freshView = reopened.host.textView
        let alreadyClosed = await original.close()
        XCTAssertTrue(alreadyClosed)
        XCTAssertTrue(freshView.isEditable, "closing the retired presenter cannot revoke the new lease")
        XCTAssertFalse(reopened.host.scrollView.window?.isKeyWindow == true)
        XCTAssertFalse(reopened.host.scrollView.window?.isVisible == true)
    }

    func testChangedClosedDraftGetsAFreshViewportAndSavesItsNewBody() async throws {
        let id = try seed(.boundary), original = try open(id)
        let session = try XCTUnwrap(original.session)
        let oldViewport = original.host.textView.textLayoutManager
        let closed = await original.close()
        XCTAssertTrue(closed)
        session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
                                   with: NSAttributedString(string: " changed"), name: "Typing")
        let reopened = try open(id)
        XCTAssertTrue(reopened.session === session)
        XCTAssertFalse(reopened.host.textView.textLayoutManager === oldViewport,
                       "a closed viewport did not observe the new draft")
        XCTAssertTrue(reopened.host.textView.string.hasSuffix(" changed"))
        let reclosed = await reopened.close()
        XCTAssertTrue(reclosed)
        let saved = try XCTUnwrap(notes.store.loadDocument(noteID: session.noteID)?.content.document)
        XCTAssertTrue(saved.blocks.last?.text.hasSuffix(" changed") == true)
    }

    func testAnInterveningLegacyViewCannotResumeTheOldTaskViewport() async throws {
        let id = try seed(.boundary), original = try open(id)
        let session = try XCTUnwrap(original.session), oldView = original.host.textView
        let closed = await original.close()
        XCTAssertTrue(closed)
        XCTAssertTrue(notes.open(noteID: session.noteID))
        let (_, legacyView) = session.engine.makeView()
        session.engine.detachView()
        let reopened = try open(id)
        XCTAssertFalse(reopened.host.textView === oldView)
        XCTAssertFalse(reopened.host.textView === legacyView)
        XCTAssertEqual(session.engine.contentStorage.textLayoutManagers.count, 1, "one live renderer after an intervening surface")
        XCTAssertNil(oldView.engine)
        XCTAssertNil(legacyView.engine)
    }

    func testWarmLongViewportResumptionStaysProportionalToTheViewport() async throws {
        let id = try seed(.long), original = try open(id)
        let counter = try XCTUnwrap(original.host.layoutCounter)
        let initial = counter.fragmentsCreated
        let closed = await original.close()
        XCTAssertTrue(closed)
        let reopened = try open(id)
        XCTAssertTrue(reopened.host.layoutCounter === counter)
        XCTAssertLessThanOrEqual(counter.fragmentsCreated - initial, 20, "reopen must not lay out the 5,000-line document")
        XCTAssertLessThanOrEqual(counter.census().laidOut, 20)
    }

    // MARK: § 9.1 item 1: the caret stays visible

    func testTheCaretStaysVisibleTypingAtTheEndOfTheLongNote() throws {
        let id = try seed(.long)
        let presenter = try open(id)
        let host = presenter.host
        let end = host.engine.textStorage.length
        host.textView.setSelectedRange(NSRange(location: end, length: 0))
        host.textView.scrollRangeToVisible(host.textView.selectedRange())
        settle(host.textView)
        caretIsVisible(host)
        type(" and a few more words at the very end of it", into: host.textView)
        caretIsVisible(host)
        host.textView.insertNewline(nil); settle(host.textView)
        type("A new last line", into: host.textView)
        caretIsVisible(host)
    }

    func testTheCaretStaysVisibleAfterAFoldAboveItAndAfterTheTitleWraps() throws {
        let id = try seed(.fifty)
        let presenter = try open(id, unfolded: true)
        let host = presenter.host
        // In the writing, past the regions (50 rows above it).
        let line = (host.engine.textStorage.string as NSString).range(of: "Line 30 ").location
        host.textView.setSelectedRange(NSRange(location: line, length: 0))
        host.textView.scrollRangeToVisible(host.textView.selectedRange())
        settle(host.textView)
        caretIsVisible(host)
        let clip = host.scrollView.contentView
        let before = host.mapper.textRect(for: host.textView.selectedRange()).map { clip.convert($0, from: host.textView).minY - clip.bounds.minY }
        presenter.model.setFolded(true)
        host.restack(); settle(host.textView)
        caretIsVisible(host)
        // The viewport kept its anchor: the caret did not jump on screen.
        let after = host.mapper.textRect(for: host.textView.selectedRange()).map { clip.convert($0, from: host.textView).minY - clip.bounds.minY }
        if let before, let after {
            XCTAssertEqual(before, after, accuracy: 1, "the writing stays put on screen while the block folds above it")
        }
        presenter.model.setFolded(false); host.restack(); settle(host.textView)
        host.textView.scrollRangeToVisible(host.textView.selectedRange()); settle(host.textView)
        XCTAssertTrue(library.updateTask(id, title: String(repeating: "A title that wraps across lines ", count: 4)).isApplied)
        presenter.model.refresh(); host.restack(); settle(host.textView)
        type("x", into: host.textView)
        caretIsVisible(host)
    }

    // MARK: § 9.1 item 2: layout stays proportional to the viewport

    private struct LayoutSample { let open: Int; let keystroke: [Int]; let scroll: [Int]; let paragraphs: Int }

    private func layoutSample(_ scenario: TaskNotePreviewSeed.Scenario, unfolded: Bool? = nil) throws -> LayoutSample {
        let id = try seed(scenario)
        let presenter = try open(id, unfolded: unfolded)
        let host = presenter.host
        let counter = try XCTUnwrap(host.layoutCounter)
        let open = counter.census().laidOut
        // Keystrokes in the middle of the note.
        let middle = (host.engine.textStorage.string as NSString).range(of: "Line 2501 ").location
        host.textView.setSelectedRange(NSRange(location: middle, length: 0))
        host.textView.scrollRangeToVisible(host.textView.selectedRange())
        settle(host.textView)
        var keystroke: [Int] = []
        for character in "typing here" {
            let before = counter.fragmentsCreated
            host.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            settle(host.textView)
            keystroke.append(counter.fragmentsCreated - before)
        }
        // Scroll steps of 40 pt down the shared clip: the fragments that
        // became laid out at each step.
        var scroll: [Int] = []
        let clip = host.scrollView.contentView
        var laidOut = counter.census().laidOut
        for _ in 0..<20 {
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 40))
            host.scrollView.reflectScrolledClipView(clip)
            settle(host.textView)
            let now = counter.census().laidOut
            scroll.append(now - laidOut)
            laidOut = now
        }
        return LayoutSample(open: open, keystroke: keystroke, scroll: scroll, paragraphs: counter.census().paragraphs)
    }

    func testLayoutPerKeystrokeAndPerScrollStepIsProportionalToTheViewport() throws {
        let host = try layoutSample(.long)
        let visibleLines = Int(ceil((panel.height - topInset - bottomInset) / 21)) // body line pitch ≈ 21
        let report = "TASKNOTE-LAYOUT long: open laid out \(host.open) of \(host.paragraphs) paragraphs; per keystroke created \(host.keystroke); per 40 pt scroll step newly laid out \(host.scroll); viewport ≈ \(visibleLines) lines"
        print(report); XCTContext.runActivity(named: report) { _ in }
        // Never the document: a whole-document layout would touch thousands.
        XCTAssertLessThan(host.open, host.paragraphs / 10, "open lays out the viewport, not the document")
        XCTAssertLessThanOrEqual(host.keystroke.max() ?? 0, visibleLines, "a keystroke lays out within the viewport")
        XCTAssertLessThanOrEqual(host.scroll.max() ?? 0, visibleLines, "a scroll step lays out within the viewport")
    }

    func testFiftyUnfoldedSubtasksKeepLayoutProportionalToTheViewport() throws {
        let fifty = try layoutSample(.fifty, unfolded: true)
        let visibleLines = Int(ceil((panel.height - topInset - bottomInset) / 21))
        let report = "TASKNOTE-LAYOUT fifty: open laid out \(fifty.open) of \(fifty.paragraphs); per keystroke \(fifty.keystroke); per scroll step \(fifty.scroll)"
        print(report); XCTContext.runActivity(named: report) { _ in }
        XCTAssertLessThan(fifty.open, fifty.paragraphs / 10)
        XCTAssertLessThanOrEqual(fifty.keystroke.max() ?? 0, visibleLines)
        XCTAssertLessThanOrEqual(fifty.scroll.max() ?? 0, visibleLines)
    }

    // MARK: § 2.3.1 held order and both insertion rules

    func testCanonicalInsertionPutsANewOpenSubtaskAtTheEndOfTheOpenGroup() throws {
        let id = try seed(.heavy)
        let presenter = try open(id, unfolded: true)
        let model = presenter.model
        model.newSubtaskText = "Write the launch post"
        XCTAssertTrue(model.commitNewSubtask())
        let canonical = tasks.subtasks(of: id)
        let open = canonical.filter { $0.status != .done }
        XCTAssertEqual(open.last?.title, "Write the launch post")
        XCTAssertEqual(canonical.firstIndex { $0.status == .done }, open.count, "completed rows follow the open group")
        // Not in use: the block shows canonical order at once.
        XCTAssertEqual(model.rows.map(\.id), canonical.map(\.id))
    }

    func testHeldOrderKeepsTicksInPlaceAndPutsNewRowsAtTheEndUntilTheHoldReleases() throws {
        let id = try seed(.heavy)
        let presenter = try open(id, unfolded: true)
        let model = presenter.model
        model.setFocusInside(true)
        let held = model.rows.map(\.id)
        // Ticking never moves the next target away.
        XCTAssertTrue(model.toggle(held[4]))
        XCTAssertTrue(model.toggle(held[5]))
        model.refresh()
        XCTAssertEqual(model.rows.map(\.id), held)
        XCTAssertTrue(model.rows[4].isDone)
        // Held insertion: the end of the held list, below the completed rows.
        model.newSubtaskText = "Fresh row"
        XCTAssertTrue(model.commitNewSubtask())
        model.refresh()
        XCTAssertEqual(Array(model.rows.map(\.id).prefix(held.count)), held)
        XCTAssertEqual(model.rows.last?.title, "Fresh row")
        // Focus and pointer leave: canonical order, the new row in its group.
        model.setFocusInside(false)
        let canonical = tasks.subtasks(of: id).map(\.id)
        XCTAssertEqual(model.rows.map(\.id), canonical)
        XCTAssertNotEqual(model.rows.last?.title, "Fresh row")
    }

    func testFoldingReleasesTheHoldAndIsPresentationStateOnly() throws {
        let id = try seed(.heavy)
        let presenter = try open(id, unfolded: true)
        let model = presenter.model
        let revision = tasks.revision
        let steps = model.history.route.totalStepCount
        model.setPointerInside(true)
        XCTAssertTrue(model.toggle(model.rows[4].id))
        let ticked = model.rows[4].id
        model.setFolded(true)
        XCTAssertNil(model.heldOrder)
        model.setFolded(false)
        XCTAssertNotEqual(model.rows[4].id, ticked, "after the hold, the ticked row settles into the completed group")
        XCTAssertEqual(model.history.route.totalStepCount, steps + 1, "only the tick is history; folding is not")
        XCTAssertEqual(tasks.revision, revision + 1, "folding saves nothing")
    }

    func testReorderStaysWithinItsStateGroup() throws {
        let id = try seed(.heavy)
        let presenter = try open(id, unfolded: true)
        let model = presenter.model
        let canonical = tasks.subtasks(of: id)
        let lastOpen = try XCTUnwrap(canonical.last { $0.status != .done })
        let lastIndex = try XCTUnwrap(canonical.firstIndex { $0.id == lastOpen.id })
        XCTAssertFalse(model.move(lastOpen.id, by: 1), "the open group's last row cannot cross into the completed group")
        XCTAssertTrue(model.move(lastOpen.id, by: -1))
        XCTAssertEqual(tasks.subtasks(of: id)[lastIndex - 1].id, lastOpen.id)
        let firstDone = try XCTUnwrap(tasks.subtasks(of: id).first { $0.status == .done })
        XCTAssertFalse(model.move(firstDone.id, by: -1), "the completed group's first row cannot cross into the open group")
    }

    // MARK: § 7 focus routing and field-local Undo

    func testEmptyReturnInAddSubtaskPutsTheCaretAtTheTopOfTheWriting() throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let host = presenter.host
        host.textView.setSelectedRange(NSRange(location: 20, length: 0))
        presenter.model.newSubtaskText = ""
        XCTAssertTrue(presenter.model.commitNewSubtask())
        XCTAssertTrue(host.textView.window?.firstResponder === host.textView)
        XCTAssertEqual(host.textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testControlShiftTabFromTheWritingGoesToTheLastRowElseAddSubtask() throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let model = presenter.model
        model.focusBlockFromWriting()
        XCTAssertEqual(model.focusRequest, .add)
        model.focusedRowID = model.rows[1].id
        model.noteRowFocused(model.rows[1].id)
        model.focusBlockFromWriting()
        XCTAssertEqual(model.focusRequest, .list)
        XCTAssertEqual(model.focusedRowID, model.rows[1].id)
        // A folded block unfolds on the way in.
        model.setFolded(true)
        model.focusBlockFromWriting()
        XCTAssertFalse(model.isFolded)
    }

    func testARenameIsOneStepInTheWorkspaceHistoryAndRetiresTheFieldUndo() throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let model = presenter.model
        let route = model.history.route
        let before = route.totalStepCount
        let manager = UndoManager()
        manager.groupsByEvent = false
        let row = try XCTUnwrap(model.rows.first { $0.title == "Write release notes" })
        model.beginRename(row.id, undoManager: manager)
        // Typing in the field: draft steps of its own, never the workspace's.
        let start = (model.renameText as NSString).length
        model.renameEdited(NSRange(location: 6, length: 0), replacement: "the ")
        model.renameText = "Write the release notes"
        XCTAssertNotNil(model.undoRenameDraft(), "⌘Z in the field steps the draft")
        XCTAssertEqual(model.renameText, "Write release notes")
        XCTAssertNotNil(model.redoRenameDraft())
        XCTAssertEqual(model.renameText, "Write the release notes")
        XCTAssertEqual((model.renameText as NSString).length, start + 4)
        XCTAssertTrue(model.commitRename())
        XCTAssertNil(model.undoRenameDraft(), "the field's draft Undo retires with the commit")
        XCTAssertEqual(route.totalStepCount, before + 1)
        XCTAssertEqual(tasks.task(withID: row.id)?.title, "Write the release notes")
        XCTAssertTrue(route.canUndo(in: model.historyID))
        // ⌘Z in the page walks the same history.
        XCTAssertTrue(route.undo(in: model.historyID))
        XCTAssertEqual(tasks.task(withID: row.id)?.title, "Write release notes")
    }

    func testTheHeadTitleUnderstandsShorthandAndCommitsToTheBlock() throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let model = presenter.model
        model.beginEditingTitle()
        let text = model.titleEdit.text
        model.titleEdit.edited(NSRange(location: (text as NSString).length, length: 0), replacement: " #ship ")
        model.titleEdit.text = text + " #ship "
        model.titleEdit.markShown(parser: model.parser, caret: (model.titleEdit.text as NSString).length)
        XCTAssertTrue(model.commitTitle())
        XCTAssertEqual(tasks.task(withID: id)?.title, "Finalize launch checklist")
        XCTAssertTrue(tasks.task(withID: id)?.tags.contains("ship") == true)
        XCTAssertEqual(model.focusRequest, .list)
    }

    // MARK: § 2.1 nothing is created

    func testATaskWithNoNoteOpensFoldsTicksAndAddsWithoutCreatingOne() throws {
        let id = try seed(.nonote)
        let presenter = try open(id)
        XCTAssertNil(presenter.session)
        let model = presenter.model
        model.toggleFold(); model.toggleFold()
        XCTAssertTrue(model.toggle(model.rows[0].id))
        model.newSubtaskText = "Another"
        XCTAssertTrue(model.commitNewSubtask())
        let context = ModelContext(container)
        let notesForTask = try context.fetch(FetchDescriptor<NoteItem>()).filter { $0.taskID == id }
        XCTAssertTrue(notesForTask.isEmpty)
        XCTAssertTrue(presenter.host.engine.isBodyOnly)
    }

    // MARK: § 9 0b performance rows (headless; paired with the plain Phase 2 note)

    /// The plain Phase 2 page's editor over the same body (a 320 × 520
    /// window, the same insets).
    private func plainEditor(_ body: [NoteBlock]) -> (NoteEditorEngine, NoteEditorTextView, NSScrollView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Read the long note")] + body))
        let (scrollView, textView) = engine.makeView()
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        textView.textContainerInset = NSSize(width: columnInset, height: 0)
        scrollView.frame = NSRect(origin: .zero, size: panel)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        return (engine, textView, scrollView)
    }

    private func ms(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// OD-9's same-job bound: reference median + max(reference range, the
    /// measurement's step) + 0.2 ms.
    private func bound(_ reference: [Double]) -> Double {
        let sorted = reference.sorted()
        let steps = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.filter { $0 > 0 }
        return median(reference) + max((sorted.last ?? 0) - (sorted.first ?? 0), steps.min() ?? 0) + 0.2
    }

    private func keystrokes(_ textView: NSTextView, at marker: String, autosave: (() -> Void)? = nil) -> [Double] {
        let location = (textView.string as NSString).range(of: marker).location
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        settle(textView)
        return "the quick brown fox jumps over".map { character in
            autosave?()
            return ms {
                textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
                textView.displayIfNeeded()
            }
        }
    }

    private func report(_ name: String, candidate: [Double], reference: [Double]) {
        let line = String(format: "TASKNOTE-PERF %@ composed median %.3f ms (max %.3f) · plain median %.3f ms (max %.3f) · bound %.3f ms",
                          name, median(candidate), candidate.max() ?? 0, median(reference), reference.max() ?? 0, bound(reference))
        print(line); XCTContext.runActivity(named: line) { _ in }
    }

    func testKeystrokeInTheLongProseNoteDoesNotRegressAgainstThePlainNote() throws {
        let id = try seed(.long)
        let composed = try open(id).host
        let (_, plainView, _) = plainEditor(TaskNotePreviewSeed.longProse())
        // Interleaved rounds: plain, composed, plain, composed (drift cancels).
        var candidate: [Double] = [], reference: [Double] = []
        for round in 0..<4 {
            reference += keystrokes(plainView, at: "Line \(2_501 + round) ")
            candidate += keystrokes(composed.textView, at: "Line \(2_501 + round) ")
        }
        report("keystroke long prose", candidate: candidate, reference: reference)
        XCTAssertLessThanOrEqual(median(candidate), bound(reference))
    }

    func testKeystrokeWithFiftySubtasksUnfoldedDoesNotRegressAgainstThePlainNote() throws {
        let id = try seed(.fifty)
        let composed = try open(id, unfolded: true).host
        let (_, plainView, _) = plainEditor(TaskNotePreviewSeed.longProse())
        var candidate: [Double] = [], reference: [Double] = []
        for round in 0..<4 {
            reference += keystrokes(plainView, at: "Line \(round + 1) ")
            candidate += keystrokes(composed.textView, at: "Line \(round + 1) ")
        }
        report("keystroke 50 subtasks", candidate: candidate, reference: reference)
        XCTAssertLessThanOrEqual(median(candidate), bound(reference))
    }

    func testKeystrokeRightAfterAnAutosaveDoesNotRegressAgainstThePlainNote() throws {
        let id = try seed(.long)
        let presenter = try open(id)
        let session = try XCTUnwrap(presenter.session)
        let composed = presenter.host
        // The plain note: a Phase 2 session of the same length in the same
        // controller (its saves go through the same store path).
        let plainID = UUID()
        let context = ModelContext(container)
        let plainNote = NoteItem(id: plainID)
        NoteStore.stageDocumentContent(try PreparedNoteDocument(NoteDocument(blocks: [.text("Plain")] + TaskNotePreviewSeed.longProse())),
                                       format: 1, on: [plainNote], timestamp: Date(), revision: 0, revisionID: UUID())
        context.insert(plainNote); try context.save()
        notes.store.refresh()
        XCTAssertTrue(notes.open(noteID: plainID))
        let plain = try XCTUnwrap(notes.active)
        let (scroll, plainView) = plain.engine.makeView()
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        scroll.frame = NSRect(origin: .zero, size: panel)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        windows.append(window)
        var saves: [Double] = []
        var candidate: [Double] = [], reference: [Double] = []
        for round in 0..<3 {
            reference += keystrokes(plainView, at: "Line \(3_001 + round) ") { saves.append(self.ms { _ = self.notes.save(plain) }) }
            candidate += keystrokes(composed.textView, at: "Line \(3_001 + round) ") { saves.append(self.ms { _ = self.notes.save(session) }) }
        }
        report("keystroke after autosave", candidate: candidate, reference: reference)
        print(String(format: "TASKNOTE-PERF autosave median %.3f ms", median(saves)))
        XCTAssertLessThanOrEqual(median(candidate), bound(reference))
        // The saves really wrote: block 0 is the live title, the body intact.
        let stored = notes.store.loadDocument(noteID: session.noteID)?.content.document
        XCTAssertEqual(stored?.blocks.first?.text, "Read the long note")
        XCTAssertTrue(stored?.requires.contains("taskNote") == true)
    }

    /// A plain Phase 2 note with the same body, saved in the store, opened
    /// through the Notes controller with its own scroll view.
    private func plainNote(_ body: [NoteBlock]) throws -> UUID {
        let id = UUID()
        let context = ModelContext(container)
        let note = NoteItem(id: id)
        NoteStore.stageDocumentContent(try PreparedNoteDocument(NoteDocument(blocks: [.text("Plain")] + body)),
                                       format: 1, on: [note], timestamp: Date(), revision: 0, revisionID: UUID())
        context.insert(note); try context.save()
        notes.store.refresh()
        return id
    }

    private func openPlain(_ id: UUID) throws -> Double {
        var view: NoteEditorTextView?
        var retire: (() -> Void)?
        let elapsed = try {
            let start = DispatchTime.now().uptimeNanoseconds
            XCTAssertTrue(notes.open(noteID: id))
            let session = try XCTUnwrap(notes.active)
            let (scroll, textView) = session.engine.makeView()
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
            textView.textContainerInset = NSSize(width: columnInset, height: 0)
            // Match NoteEditorRepresentable's production native setup. A
            // bare NSTextView omits Notes' title/menu/tag accessories while
            // the composed side draws its SwiftUI head and subtask regions.
            let chrome = NotesPageChrome()
            let accessories = NoteTitleAccessories(engine: session.engine, textView: textView, scrollView: scroll,
                                                   chrome: chrome, design: .default, headerBottom: topInset,
                                                   isUntouched: { false }, tagEditor: { AnyView(EmptyView()) })
            let controls = NoteFormatControls(engine: session.engine, textView: textView, scrollView: scroll,
                                              design: .default, noteID: id, isNewDraft: false)
            let objects = NoteObjectControls(engine: session.engine, textView: textView)
            retire = { controls.invalidate(); objects.invalidate(); accessories.invalidate() }
            scroll.frame = NSRect(origin: .zero, size: panel)
            let window = openingWindow ?? NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            if openingWindow == nil { windows.append(window) }
            settle(textView)
            view = textView
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }()
        retire?()
        if let openingWindow { openingWindow.contentView = NSView() }
        else { view?.window?.close() }
        view?.engine?.detachView()
        return elapsed
    }

    private func openComposed(_ id: UUID) throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        let presenter = try open(id)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let closed = expectation(description: "closed")
        Task { @MainActor in let ok = await presenter.close(); XCTAssertTrue(ok); closed.fulfill() }
        wait(for: [closed], timeout: 10)
        presenters.removeAll { $0 === presenter }
        if let openingWindow { openingWindow.contentView = NSView() }
        else { presenter.host.scrollView.window?.close() }
        return elapsed
    }

    /// § 9: opening a task's note, cold and warm, from the seeded entry
    /// (here: the presenter, its session load, the composed host and the
    /// first display). Paired with the plain note of the same body opened
    /// through Notes, including each page's production native controls and
    /// title accessories. Both share the same bounded warm session cache.
    private func measureOpen(_ scenario: TaskNotePreviewSeed.Scenario, body: [NoteBlock]) throws -> (cold: (Double, Double), warm: ([Double], [Double])) {
        // Page navigation uses an existing panel, never a new macOS window.
        // Both sides mount, lay out and display in the same unordered host.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        openingWindow = window
        defer { openingWindow = nil }
        let id = try seed(scenario)
        let plain = try plainNote(body)
        let other = try plainNote([.text("Elsewhere")])
        let plainCold = try openPlain(plain)
        let composedCold = try openComposed(id)
        var plainWarm: [Double] = [], composedWarm: [Double] = []
        // Twelve samples per side, matching the paired Done evidence budget.
        // Keep every sample, including scheduling/display outliers.
        for pair in 0..<12 {
            XCTAssertTrue(notes.open(noteID: other))
            if pair.isMultiple(of: 2) {
                plainWarm.append(try openPlain(plain))
                composedWarm.append(try openComposed(id))
            } else {
                composedWarm.append(try openComposed(id))
                plainWarm.append(try openPlain(plain))
            }
        }
        let line = String(format: "TASKNOTE-PERF open %@ cold composed %.2f ms / plain %.2f ms · warm composed median %.2f ms (max %.2f) / plain median %.2f ms (max %.2f)",
                          scenario.rawValue, composedCold, plainCold, median(composedWarm), composedWarm.max() ?? 0,
                          median(plainWarm), plainWarm.max() ?? 0)
        print(line); XCTContext.runActivity(named: line) { _ in }
        return ((composedCold, plainCold), (composedWarm, plainWarm))
    }

    func testOpeningTheTaskNoteColdAndWarm() throws {
        let heavy = try measureOpen(.heavy, body: [.text("Research"), .text("Static hosting wins on cost: about €9 a month against €40 for the current server. The redirect map covers all 212 old posts; Sam has the export.")])
        XCTAssertGreaterThan(heavy.cold.0, 0)
        XCTAssertLessThanOrEqual(median(heavy.warm.0), bound(heavy.warm.1), "warm task notes share plain Notes' cache performance")
        let long = try measureOpen(.long, body: TaskNotePreviewSeed.longProse())
        XCTAssertGreaterThan(long.cold.0, 0)
        XCTAssertLessThan(median(long.warm.0), 50, "a warm long task note must not reload its document")
        XCTAssertLessThanOrEqual(median(long.warm.0), bound(long.warm.1), "warm long-note reopen must meet the paired OD-9 bound")
        print("TASKNOTE-PERF warm long raw composed \(long.warm.0) / plain \(long.warm.1)")
    }

    /// § 9: scrolling the composed view shows no regression against the
    /// plain note of the same length (40 pt steps, layout and display).
    func testScrollingTheComposedViewDoesNotRegressAgainstThePlainNote() throws {
        let id = try seed(.fifty)
        let presenter = try open(id, unfolded: true)
        let composed = presenter.host
        let (_, plainView, plainScroll) = plainEditor(TaskNotePreviewSeed.longProse())
        settle(plainView)
        func steps(_ scroll: NSScrollView, _ textView: NSTextView) -> [Double] {
            let clip = scroll.contentView
            return (0..<40).map { _ in
                ms {
                    clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 40))
                    scroll.reflectScrolledClipView(clip)
                    textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
                    textView.window?.displayIfNeeded()
                }
            }
        }
        var candidate: [Double] = [], reference: [Double] = []
        for _ in 0..<3 {
            reference += steps(plainScroll, plainView)
            candidate += steps(composed.scrollView, composed.textView)
        }
        report("scroll step", candidate: candidate, reference: reference)
        XCTAssertLessThanOrEqual(median(candidate), bound(reference))
        // Folding 50 rows above the writing: the final height once, the
        // anchor kept, then layout and display (reported; a plain note has
        // no fold).
        let fold = (0..<6).map { index in
            ms {
                presenter.model.setFolded(index.isMultiple(of: 2))
                composed.restack()
                composed.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
                composed.textView.window?.displayIfNeeded()
            }
        }
        var parts: [[Double]] = [[], [], [], []]
        for index in 0..<6 {
            parts[0].append(ms { presenter.model.setFolded(index.isMultiple(of: 2)) })
            parts[1].append(ms { composed.restack() })
            parts[2].append(ms { composed.textView.textLayoutManager?.textViewportLayoutController.layoutViewport() })
            parts[3].append(ms { composed.textView.window?.displayIfNeeded() })
        }
        print(String(format: "TASKNOTE-PERF fold parts: model %.2f · restack %.2f · viewport %.2f · display %.2f ms (medians)",
                     median(parts[0]), median(parts[1]), median(parts[2]), median(parts[3])))
        let line = String(format: "TASKNOTE-PERF fold/unfold 50 rows median %.2f ms (max %.2f)", median(fold), fold.max() ?? 0)
        print(line); XCTContext.runActivity(named: line) { _ in }
    }

    // MARK: Round 2a fixes

    func testARefusedRenameKeepsItsFieldTextAndDraftUndo() throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let model = presenter.model
        let row = try XCTUnwrap(model.rows.first)
        model.beginRename(row.id)
        model.renameEdited(NSRange(location: 0, length: 0), replacement: "X")
        model.renameText = "X" + row.title
        // Another command is still preparing: the commit is refused.
        XCTAssertTrue(model.history.reserveInput())
        XCTAssertFalse(model.commitRename())
        model.history.releaseInput()
        XCTAssertEqual(model.renamingID, row.id, "the field stays open")
        XCTAssertEqual(model.renameText, "X" + row.title, "with its text")
        XCTAssertNotNil(model.undoRenameDraft(), "and its draft Undo")
        // Folding cancels it and retires the draft.
        model.setFolded(true)
        XCTAssertNil(model.renamingID)
        XCTAssertNil(model.undoRenameDraft())
    }

    func testTheTitleDraftHasItsOwnUndoBeforeTheWorkspace() throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let model = presenter.model
        model.beginEditingTitle()
        let text = model.titleEdit.text
        model.titleEdited(NSRange(location: (text as NSString).length, length: 0), replacement: "!")
        model.titleEdit.text = text + "!"
        XCTAssertEqual(model.undoTitleDraft()?.text, text)
        XCTAssertEqual(model.redoTitleDraft()?.text, text + "!")
        model.cancelTitle()
        XCTAssertNil(model.undoTitleDraft(), "cancel retires the title's draft Undo")
    }

    func testANewTodoSubtaskGoesAfterLaterRowsInTheOpenDisplayGroup() throws {
        let id = try seed(.boundary)
        _ = try open(id)
        let later = try XCTUnwrap(library.createTasks([TaskDraft(title: "Later row", status: .backlog, parentID: id)]))
        XCTAssertEqual(later.count, 1)
        XCTAssertNotNil(library.createTasks([TaskDraft(title: "Todo row", status: .todo, parentID: id)]))
        let open = tasks.subtasks(of: id).filter { $0.status != .done }.map(\.title)
        XCTAssertEqual(Array(open.suffix(2)), ["Later row", "Todo row"])
        // A batch keeps its drafts' order at the end.
        XCTAssertNotNil(library.createTasks([TaskDraft(title: "A", parentID: id), TaskDraft(title: "B", parentID: id)]))
        XCTAssertEqual(Array(tasks.subtasks(of: id).filter { $0.status != .done }.map(\.title).suffix(2)), ["A", "B"])
    }

    func testReorderingCompletedSubtasksSaves() throws {
        let id = try seed(.boundary)
        let presenter = try open(id, unfolded: true)
        let model = presenter.model
        model.newSubtaskText = "CU order row"
        XCTAssertTrue(model.commitNewSubtask())
        let write = try XCTUnwrap(tasks.subtasks(of: id).first { $0.title == "Write release notes" })
        XCTAssertTrue(model.toggle(write.id))
        let done = tasks.subtasks(of: id).filter { $0.status == .done }
        XCTAssertEqual(done.count, 2)
        XCTAssertTrue(model.move(done[0].id, by: 1), "\(String(describing: model.failure))")
        XCTAssertNil(model.failure)
        XCTAssertEqual(tasks.subtasks(of: id).filter { $0.status == .done }.map(\.id), [done[1].id, done[0].id])
        XCTAssertTrue(model.move(done[0].id, by: -1))
        XCTAssertNil(model.failure)
    }

    func testListEntrySelectsTheLastRowElseTheFirst() throws {
        let id = try seed(.heavy)
        let presenter = try open(id, unfolded: true)
        let model = presenter.model
        XCTAssertEqual(model.listEntryRowID, model.rows.first?.id, "a fresh Tab into the list selects the first row")
        model.noteRowFocused(model.rows[3].id)
        model.focusedRowID = nil
        XCTAssertEqual(model.listEntryRowID, model.rows[3].id)
        model.requestFocus(.list)
        XCTAssertEqual(model.focusedRowID, model.rows[3].id)
    }

    func testHeldRowsSettleAtOnceWithReduceMotion() throws {
        let id = try seed(.heavy)
        var design = AtticDesignContext.default
        design.reduceMotion = true
        let presenter = try TaskNotePresenter(taskID: id, tasks: tasks, library: library, notes: notes,
                                              design: design, columnInset: columnInset, defaults: nil)
        presenters.append(presenter)
        XCTAssertTrue(presenter.model.reduceMotion)
    }

    func testDarkWritingUsesTheNotesInkEvenWhenNotesNeverShowed() throws {
        let id = try seed(.boundary)
        var dark = AtticDesignContext.default
        dark.mode = .dark
        let presenter = try TaskNotePresenter(taskID: id, tasks: tasks, library: library, notes: notes,
                                              design: dark, columnInset: columnInset, defaults: nil)
        presenters.append(presenter)
        let engine = presenter.host.engine
        let ink = engine.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(ink, NoteTextStyle(design: dark).bodyColor)
        XCTAssertNotEqual(ink, NoteTextStyle(design: .default).bodyColor)
        // A later change of look reaches the open editor.
        presenter.update(design: .default)
        XCTAssertEqual(engine.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       NoteTextStyle(design: .default).bodyColor)
    }

    func testTabFromAddSubtaskLeavesTheKeyboardInTheWriting() throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let host = presenter.host
        let window = try XCTUnwrap(host.textView.window)
        // The block's hosting view had the keyboard (the Add field).
        window.makeFirstResponder(host.blockView)
        presenter.model.focusWriting(atTop: true)
        // SwiftUI handing the keyboard back to its hosting view this turn
        // must not win.
        window.makeFirstResponder(host.blockView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(window.firstResponder === host.textView)
        XCTAssertEqual(host.textView.selectedRange(), NSRange(location: 0, length: 0))
        host.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(host.engine.textStorage.string.hasPrefix("x"), "typing after the Tab reaches the writing")
    }

    func testFindUsesTheComposedFinderAndTheSharedScroll() throws {
        let id = try seed(.long)
        let presenter = try open(id)
        let host = presenter.host
        XCTAssertTrue(host.textView.composedFinder === host.textFinder)
        XCTAssertTrue(host.textFinder.findBarContainer === host.scrollView)
        XCTAssertTrue(host.textFinder.client === host.textView)
        let item = NSMenuItem(title: "Find…", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "f")
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        XCTAssertTrue(host.textView.validateUserInterfaceItem(item))
        host.textView.performTextFinderAction(item)
        XCTAssertTrue(host.scrollView.isFindBarVisible, "⌘F shows the bar over the shared scroll")
        // Scroll-to-match goes through the mapper.
        let match = (host.engine.textStorage.string as NSString).range(of: "Line 4000 ")
        host.textView.scrollRangeToVisible(match)
        settle(host.textView)
        let rect = try XCTUnwrap(host.mapper.textRect(for: match))
        XCTAssertTrue(host.mapper.unobscuredRect().intersects(rect))
    }

    func testTheBlockClipsRowsLeavingOnAFold() throws {
        let id = try seed(.heavy)
        let presenter = try open(id, unfolded: true)
        let block = presenter.host.blockView
        XCTAssertEqual(block.layer?.masksToBounds, true)
        presenter.model.setFolded(true)
        presenter.host.restack()
        XCTAssertEqual(block.frame.height, TaskNoteMetrics.blockHeader, accuracy: 1)
    }

    func testFoldAndUnfoldCommitNativeGeometryBeforeTheNextSwiftUIFrame() throws {
        let id = try seed(.fifty), presenter = try open(id, unfolded: true)
        presenter.model.setFolded(true)
        XCTAssertEqual(presenter.host.blockView.frame.height, TaskNoteMetrics.blockHeader, accuracy: 1)
        presenter.model.setFolded(false)
        XCTAssertEqual(presenter.host.blockView.frame.height, presenter.model.blockHeight, accuracy: 1)
    }
}

private actor TaskNoteCheckpointBarrier {
    private var started = false
    private var pending: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        guard !started else { return }
        started = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
        await withCheckedContinuation { pending = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { pending?.resume(); pending = nil }
}

@MainActor
private final class TaskNoteCheckpointJournal: NoteDraftJournaling {
    let base: NoteDraftJournal
    let barrier: TaskNoteCheckpointBarrier
    var workspaceJournal: NoteDraftJournal? { base }
    var requiresAsyncIO: Bool { true }
    init(base: NoteDraftJournal, barrier: TaskNoteCheckpointBarrier) { self.base = base; self.barrier = barrier }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
                      replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        await barrier.pause()
        return try await base.writeDurably(entry, staged: staged, replacing: claim)
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        try await base.retireDurably(noteID: noteID, claim: claim, saved: saved)
    }
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { try base.recoveryEntries() }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] { try await base.readRecoveryEntries() }
}
