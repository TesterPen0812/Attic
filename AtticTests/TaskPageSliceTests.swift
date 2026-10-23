import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Phase 3 task page slice: production entry, lazy note creation, files on a
/// row, Back, the lifecycle and All notes (mockups p3-20/21/22). Headless:
/// off-screen windows that never take the keyboard.
@MainActor
final class TaskPageSliceTests: XCTestCase {
    private var container: ModelContainer!
    private var tasks: TaskStore!
    private var library: AtticLibrary!
    private var notes: NotesPageController!
    private var coordinator: WorkspaceOperationCoordinator!
    private var windows: [NSWindow] = []
    private var presenters: [TaskNotePresenter] = []
    private let panel = NSSize(width: 320, height: 520)

    override func setUp() async throws {
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
    }

    override func tearDown() async throws {
        for presenter in presenters where presenter.lease != nil { _ = await presenter.close() }
        presenters.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
        notes = nil; library = nil; tasks = nil; coordinator = nil; container = nil
    }

    // MARK: Fixtures

    private func seed(_ scenario: TaskNotePreviewSeed.Scenario) throws -> UUID {
        let id = try TaskNotePreviewSeed.seed(scenario, in: container)
        tasks = TaskStore(container: container)
        library = AtticLibrary(tasks: tasks)
        notes = NotesPageController(store: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()),
                                    journal: coordinator.journal, defaults: nil,
                                    saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        notes.attachUndoRoute(library.undo)
        return id
    }

    private func open(_ taskID: UUID) throws -> TaskNotePresenter {
        let presenter = try TaskNotePresenter(taskID: taskID, tasks: tasks, library: library, notes: notes,
                                              design: .default, columnInset: 28, defaults: nil)
        presenters.append(presenter)
        let host = presenter.host
        host.setContentInsets(top: 76, bottom: 60)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.scrollView.frame = NSRect(origin: .zero, size: panel)
        window.contentView = host.scrollView
        windows.append(window)
        host.restack()
        settle(host.textView)
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

    private func ownNotes(_ taskID: UUID) throws -> [NoteItem] {
        try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).filter { $0.taskID == taskID }
    }

    private func associations(_ taskID: UUID) throws -> [TaskNoteAssociation] {
        try ModelContext(container).fetch(FetchDescriptor<TaskNoteAssociation>()).filter { $0.taskID == taskID }
    }

    /// The last block with content (the editor keeps an empty paragraph
    /// after an object line).
    private static func lastContent(_ document: NoteDocument) -> NoteBlock? {
        document.blocks.last { $0.kind != .text || !$0.text.isEmpty }
    }

    private func temporaryFile(_ name: String, contents: String = "hello") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaskPageSlice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    // MARK: § 2.1 lazy creation

    /// Writing in a task with no note creates exactly one own note and its
    /// association, together, through the gated save; the writing is kept
    /// in the task-note form (block 0 is the title snapshot).
    func testWritingInATaskWithNoNoteCreatesItsNoteAndAssociationTogether() async throws {
        let id = try seed(.nonote)
        let presenter = try open(id)
        XCTAssertTrue(try ownNotes(id).isEmpty, "opening creates nothing")
        XCTAssertFalse(presenter.host.engine.isReadOnly, "the writing takes text before a note exists")
        presenter.host.textView.window?.makeFirstResponder(presenter.host.textView)
        type("First words", into: presenter.host.textView)
        XCTAssertTrue(try ownNotes(id).isEmpty, "nothing is stored before the save")
        let session = try XCTUnwrap(presenter.session)
        XCTAssertTrue(notes.save(session))
        let rows = try ownNotes(id)
        XCTAssertEqual(rows.count, 1, "exactly one own note")
        let note = try XCTUnwrap(rows.first)
        XCTAssertEqual(note.id, session.noteID)
        let links = try associations(id)
        XCTAssertEqual(links.map(\.noteID), [note.id], "the association commits with the note")
        XCTAssertNil(links.first?.detachedAt)
        let document = try XCTUnwrap(NoteContentCodec.decode(try XCTUnwrap(note.content)).document)
        XCTAssertTrue(document.requires.contains("taskNote"))
        XCTAssertEqual(document.blocks.first?.text, "A task with no note yet", "block 0 is the task's title")
        XCTAssertEqual(document.blocks.dropFirst().map(\.text).joined(), "First words")
        // A second save writes the same note, never another one.
        type(" more", into: presenter.host.textView)
        XCTAssertTrue(notes.save(session))
        XCTAssertEqual(try ownNotes(id).count, 1)
        XCTAssertEqual(try associations(id).count, 1)
        // Reopening resolves the same note.
        let closed = await presenter.close()
        XCTAssertTrue(closed)
        let reopened = try open(id)
        XCTAssertEqual(reopened.session?.noteID, note.id)
        XCTAssertTrue(reopened.session?.isPersisted == true)
    }

    /// Opening, expanding and closing without writing leaves no note, no
    /// association and no cached draft.
    func testClosingAnUntouchedTaskPageLeavesNothingBehind() async throws {
        let id = try seed(.nonote)
        let presenter = try open(id)
        let draft = try XCTUnwrap(presenter.session)
        XCTAssertFalse(draft.isPersisted)
        XCTAssertEqual(draft.pendingTaskID, id)
        presenter.model.toggleExpanded(); presenter.model.toggleExpanded()
        let closed = await presenter.close()
        XCTAssertTrue(closed)
        XCTAssertTrue(try ownNotes(id).isEmpty)
        XCTAssertTrue(try associations(id).isEmpty)
        XCTAssertNil(notes.workspaceSessionIfCached(draft.noteID), "the untouched draft is discarded")
    }

    /// A second own note is refused: the store keeps one note per task.
    func testTheStoreRefusesASecondOwnNoteForOneTask() throws {
        let id = try seed(.boundary)
        let document = try NoteDocument(blocks: [.text("x"), .text("Second")]).taskSnapshot(title: "x")
        let result = notes.store.createDocumentNote(id: UUID(), document: document, taskOwner: id)
        guard case .failure = result else { return XCTFail("a second own note must be refused") }
        XCTAssertEqual(try ownNotes(id).count, 1)
        XCTAssertEqual(try associations(id).count, 1)
    }

    // MARK: Files on a row (`p3-22` row 4)

    func testFilesDroppedOnARowCreateTheTaskNoteWithTheFileAtItsEnd() async throws {
        let id = try seed(.nonote)
        let url = try temporaryFile("brief.txt")
        let added = await TaskNoteFiles.importFiles([url], to: id, tasks: tasks, controller: notes)
        XCTAssertTrue(added)
        let rows = try ownNotes(id)
        XCTAssertEqual(rows.count, 1, "the drop is the note's first content")
        let document = try XCTUnwrap(NoteContentCodec.decode(try XCTUnwrap(rows.first?.content)).document)
        XCTAssertEqual(document.objectIDs.count, 1, "the file is in the note")
        XCTAssertEqual(Self.lastContent(document)?.kind, .file, "at its end")
        XCTAssertEqual(try associations(id).count, 1)
        XCTAssertTrue(tasks.task(withID: id)?.attachments.isEmpty ?? true, "not a task attachment")
    }

    func testP3F11FailedHeadlessDropKeepsAnOwnerThatCanCloseAfterStorageRecovers() async throws {
        let id = try seed(.nonote)
        let gate = PersistenceGate()
        gate.shouldFail = true
        let controller = NotesPageController(store: NoteStore(container: container, persist: gate.save,
            attachmentFileStore: makeTestAttachmentFileStore()), journal: nil, defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        let url = try temporaryFile("recover.txt")
        let first = await TaskNoteFiles.importFiles([url], to: id, tasks: tasks, controller: controller)
        XCTAssertFalse(first)
        gate.shouldFail = false
        let second = await TaskNoteFiles.importFiles([url], to: id, tasks: tasks, controller: controller)
        XCTAssertTrue(second, "the retained owner retries its failed close before the next drop")
        let presenter = try TaskNotePresenter(taskID: id, tasks: tasks, library: library, notes: controller,
                                              design: .default, columnInset: 28, defaults: nil)
        XCTAssertNotNil(presenter.lease)
        let closed = await presenter.close()
        XCTAssertTrue(closed)
    }

    func testP3F11FailedDropCanHandItsLeaseAndDraftToAVisiblePage() async throws {
        let id = try seed(.nonote)
        let gate = PersistenceGate()
        gate.shouldFail = true
        let controller = NotesPageController(store: NoteStore(container: container, persist: gate.save,
            attachmentFileStore: makeTestAttachmentFileStore()), journal: nil, defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        let first = await TaskNoteFiles.importFiles([try temporaryFile("kept.txt")], to: id, tasks: tasks, controller: controller)
        XCTAssertFalse(first)
        gate.shouldFail = false
        let presenter = try TaskNotePresenter(taskID: id, tasks: tasks, library: library, notes: controller,
                                              design: .default, columnInset: 28, defaults: nil)
        XCTAssertEqual(presenter.host.engine.objectIDs().count, 1, "the failed drop's draft moves with the lease")
        let closed = await presenter.close()
        XCTAssertTrue(closed)
    }

    func testFilesDroppedOnARowAppendToAnExistingTaskNote() async throws {
        let id = try seed(.boundary)
        let before = try XCTUnwrap(try ownNotes(id).first?.id)
        let url = try temporaryFile("notes.txt")
        let added = await TaskNoteFiles.importFiles([url], to: id, tasks: tasks, controller: notes)
        XCTAssertTrue(added)
        let rows = try ownNotes(id)
        XCTAssertEqual(rows.map(\.id), [before])
        let document = try XCTUnwrap(NoteContentCodec.decode(try XCTUnwrap(rows.first?.content)).document)
        XCTAssertEqual(Self.lastContent(document)?.kind, .file, "at its end")
        XCTAssertTrue(document.blocks.contains { $0.text == "Sam owns the pricing page; I take the checklist." }, "the writing stays")
    }

    // MARK: Lifecycle (`p3-22`: nothing cascades)

    func testDeleteTaskDeletesTheWholeItemAndRestoreReturnsItsWriting() async throws {
        let id = try seed(.boundary)
        await notes.startAndWait() // Deletion must await the existing recovery inventory.
        let presenter = try open(id)
        let model = presenter.model
        let noteID = try XCTUnwrap(presenter.session?.noteID)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertTrue(model.deleteTask())
        XCTAssertNil(tasks.task(withID: id), "the task went to Recently Deleted")
        model.refresh()
        XCTAssertFalse(model.head.exists, "the head reads Task deleted · Restore")
        XCTAssertEqual(model.rows.count, 2, "the subtasks stay, as they were")
        XCTAssertEqual(model.head.subtasks.total, 2)
        let kept = try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).filter { $0.id == noteID }
        XCTAssertFalse(kept.isEmpty)
        // Owner decision 2026-10-23: task and writing have one lifecycle.
        XCTAssertTrue(kept.allSatisfy { $0.deletedAt != nil }, "the writing goes with the task")
        XCTAssertTrue(presenter.host.engine.isReadOnly, "deleted writing cannot keep accepting edits")
        XCTAssertTrue(model.restoreTask())
        XCTAssertNotNil(tasks.task(withID: id))
        XCTAssertFalse(presenter.host.engine.isReadOnly, "Restore returns the writing")
        XCTAssertTrue(model.head.exists)
        XCTAssertEqual(model.rows.count, 2)
    }

    func testATaskWhoseNoteIsInRecentlyDeletedOffersRestoreNote() async throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        let deleted = await notes.deleteNoteDurably(noteID: noteID)
        XCTAssertTrue(deleted)
        let presenter = try open(id)
        // § 2.7.2: the writing reads "Write a new note": a never-saved draft
        // owned by the task, beside the quiet Restore Note line.
        let draft = try XCTUnwrap(presenter.session)
        XCTAssertFalse(draft.isPersisted, "nothing is stored by opening")
        XCTAssertEqual(draft.pendingTaskID, id)
        XCTAssertNotEqual(draft.noteID, noteID, "a new note, never the deleted one")
        XCTAssertEqual(presenter.deletedNoteID, noteID)
        XCTAssertTrue(presenter.model.deletedNote)
        XCTAssertNotNil(tasks.task(withID: id), "deleting the note never deletes the task")
        XCTAssertTrue(notes.restoreDeletedNote(noteID: noteID, reopen: false))
        let closed = await presenter.close()
        XCTAssertTrue(closed)
        let reopened = try open(id)
        XCTAssertEqual(reopened.session?.noteID, noteID, "Restore Note brings the same note back")
        XCTAssertNil(reopened.deletedNoteID)
    }

    /// Restore Note reopens the page on a new presenter; its own native
    /// views are the ones on screen (the old host never stays mounted).
    func testRestoreNoteReopensThePageWithItsOwnEditorOnScreen() async throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        let deleted = await notes.deleteNoteDurably(noteID: noteID)
        XCTAssertTrue(deleted)
        let hosting = NSHostingController(rootView: AnyView(
            TaskNotePageContainer(taskID: id, tasks: tasks, controller: notes, noteStore: notes.store,
                                  layout: PanelPageLayout(cornerSize: 52, panelSize: panel), onClose: {})))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(panel)
        windows.append(window)
        func mounted(where condition: (TaskNotePresenter) -> Bool) async throws -> TaskNotePresenter {
            for _ in 0..<200 {
                hosting.view.layoutSubtreeIfNeeded()
                if let current = notes.taskNotePresenter, condition(current), current.host.scrollView.window === window {
                    return current
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw TaskNotePresenter.OpenError.unavailable
        }
        let first = try await mounted { $0.deletedNoteID == noteID }
        presenters.append(first)
        XCTAssertEqual(first.session?.isPersisted, false, "an untouched \"Write a new note\" draft")
        first.menus.restoreNote()
        let reopened = try await mounted { $0 !== first && $0.session?.noteID == noteID }
        presenters.append(reopened)
        XCTAssertNil(first.host.scrollView.window, "the old page's editor left the window")
        XCTAssertFalse(reopened.host.engine.isReadOnly)
        // Clicks on the reopened page reach its head and block.
        hosting.view.layoutSubtreeIfNeeded()
        let frameView = try XCTUnwrap(window.contentView?.superview)
        for (name, region) in [("head", reopened.host.headView), ("block", reopened.host.blockView)] {
            let inWindow = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil)
            let hit = frameView.hitTest(inWindow)
            XCTAssertTrue(hit.map { $0 === region || $0.isDescendant(of: region) } ?? false,
                          "a click in the reopened \(name) \(inWindow) lands on \(String(describing: hit).prefix(80))")
        }
    }

    /// A click on the head or the Subtasks block reaches them, never the
    /// writing under them, in the page as the panel hosts it (SwiftUI over
    /// the composed scroll). On screen a click on a row or Restore Note put
    /// the caret at the end of the writing instead.
    func testClicksOnTheHeadAndTheBlockReachThemNotTheWriting() async throws {
        let id = try seed(.boundary)
        let hosting = NSHostingController(rootView: AnyView(
            TaskNotePageContainer(taskID: id, tasks: tasks, controller: notes, noteStore: notes.store,
                                  layout: PanelPageLayout(cornerSize: 52, panelSize: panel), onClose: {})))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(panel)
        windows.append(window)
        var mounted: TaskNotePresenter?
        for _ in 0..<200 {
            hosting.view.layoutSubtreeIfNeeded()
            if let current = notes.taskNotePresenter, current.host.scrollView.window === window { mounted = current; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let presenter = try XCTUnwrap(mounted)
        presenters.append(presenter)
        let host = presenter.host
        host.scrollToTop()
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let frameView = try XCTUnwrap(window.contentView?.superview)
        for (name, region) in [("head", host.headView), ("block", host.blockView)] {
            let inWindow = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil)
            let hit = frameView.hitTest(inWindow)
            XCTAssertTrue(hit.map { $0 === region || $0.isDescendant(of: region) } ?? false,
                          "a click in the \(name) lands on \(String(describing: hit).prefix(80))")
        }
    }

    /// The page's marquee (box selection over blank document space) must
    /// leave presses on the head and the Subtasks block to them: on screen
    /// it took a click on a subtask's box or Restore Note as a click below
    /// the writing and started a new line there.
    func testTheMarqueeLeavesPressesOnTheHeadAndTheBlockToThem() throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let host = presenter.host
        host.scrollToTop()
        settle(host.textView)
        let controller = try XCTUnwrap(host.textView.marquee?.controller)
        let before = host.engine.textStorage.string
        for (name, region) in [("head", host.headView), ("block", host.blockView)] {
            let inWindow = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: region.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            XCTAssertNotNil(controller.handle(event(.leftMouseDown)), "a press on the \(name) is the \(name)'s, not a marquee")
            _ = controller.handle(event(.leftMouseUp))
        }
        settle(host.textView)
        XCTAssertEqual(host.engine.textStorage.string, before, "no new line was started below the writing")
    }

    // MARK: The owner preview's store ("Attic Task Page")

    /// The preview's fresh store opens on the heavy, boundary and no-note
    /// task pages; the heavy note gets its two screenshots and two PDFs.
    func testTheOwnerPreviewSeedsTaskPagesAndTheHeavyFiles() async throws {
        try TaskNotePreviewSeed.seedOwnerPreview(in: container)
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let tasks = TaskStore(container: container)
        let heavy = try XCTUnwrap(TaskNotePreviewSeed.seeded[.heavy])
        XCTAssertEqual(tasks.subtasks(of: heavy).count, 10)
        XCTAssertNotNil(TaskNotePreviewSeed.seeded[.boundary])
        let nonote = try XCTUnwrap(TaskNotePreviewSeed.seeded[.nonote])
        XCTAssertTrue(store.notes.filter { $0.taskID == nonote }.isEmpty, "the no-note task has none")
        await TaskNotePreviewSeed.attachHeavyFiles(to: store)
        let note = try XCTUnwrap(store.notes.first { $0.taskID == heavy })
        let document = try XCTUnwrap(store.loadDocument(noteID: note.id)?.content.document)
        XCTAssertEqual(document.blocks.filter { $0.kind == .image }.count, 2)
        XCTAssertEqual(document.blocks.filter { $0.kind == .file }.map(\.filename), ["hosting-quote.pdf", "redirect-map.pdf"])
        XCTAssertEqual(store.attachments(for: note.id).count, 4)
    }

    // MARK: All notes (`p3-22` row 3)

    func testAllNotesShowsATaskNoteWithItsCircleAndTaskNote() throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        notes.taskStateLookup = { [tasks] taskID in tasks!.listedTask(withID: taskID).map { TaskRowPresentation.state($0.status) } }
        let model = NotesLibraryModel(search: { _ in [] }, store: notes.store, controller: notes)
        let row = model.preparedRow(AtticNoteRowModel(id: noteID, title: "", time: "", preview: "", spoken: ""), store: notes.store)
        XCTAssertEqual(row.taskState, .inProgress)
        XCTAssertTrue(row.preview.hasPrefix("Task note · "), row.preview)
        XCTAssertTrue(row.spoken.hasPrefix("Task note, "), row.spoken)
        XCTAssertEqual(row.title, "Finalize launch checklist")
    }

    // MARK: Route: over the origin, Back returns

    func testATaskPageOpensOverTasksKeepsTheListBuiltAndBackReturns() async throws {
        let id = try seed(.boundary)
        let draft = NoteDraftController(noteStore: notes.store)
        notes = draft.pages
        notes.attachUndoRoute(library.undo)
        let uiState = PanelUIState()
        uiState.loadPageContent()
        uiState.openTaskNote(id, from: .tasks, row: id, backTitle: "Back to Now")
        XCTAssertEqual(uiState.taskNoteOrigin, .tasks)
        XCTAssertEqual(uiState.taskNoteBackTitle, "Back to Now")
        let covered = CoverProbe()
        let host = TaskNoteRouteHost(page: .tasks, noteStore: notes.store, taskStore: tasks, noteDraft: draft, uiState: uiState,
                                     layout: PanelPageLayout(cornerSize: 52, panelSize: panel), isReady: true) { isCovered in
            CoverProbeView(probe: covered, covered: isCovered)
        }
        // The Notes page does not take a route opened from Tasks.
        let notesHost = TaskNoteRouteHost(page: .notes, noteStore: notes.store, taskStore: tasks, noteDraft: draft, uiState: uiState,
                                          layout: PanelPageLayout(cornerSize: 52, panelSize: panel), isReady: true) { _ in
            Color.clear
        }
        let hosting = NSHostingController(rootView: AnyView(ZStack { host; notesHost.opacity(0) }))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        windows.append(window)
        var presenter: TaskNotePresenter?
        for _ in 0..<200 {
            hosting.view.layoutSubtreeIfNeeded()
            if let current = notes.taskNotePresenter, current.taskID == id, current.host.scrollView.window === window {
                presenter = current
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let page = try XCTUnwrap(presenter, "the task page mounts over Tasks")
        presenters.append(page)
        XCTAssertEqual(covered.values.last, true, "the list stays built, covered")
        XCTAssertFalse(covered.values.contains(false) && covered.mounts > 1, "the list was never rebuilt")
        // Back: durable close, then the route ends and the list shows again.
        let closed = await page.close()
        XCTAssertTrue(closed)
        TaskNoteRouteHost<EmptyView>.closeRoute(id, uiState: uiState)
        XCTAssertNil(uiState.openTaskNoteID)
        for _ in 0..<100 where covered.values.last != false {
            hosting.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(covered.values.last, false, "Back uncovers the same list")
        XCTAssertEqual(covered.mounts, 1, "Back returns to the list as it was: the same view, never rebuilt")
        XCTAssertEqual(uiState.taskNoteReturnRow, id, "the anchor row takes the keyboard again")
    }

    /// ⌘Return, a click on the title and VoiceOver's Open task note open the
    /// task's page through the host's service; the files list keeps its
    /// own control (the files count) and menu item.
    func testRowOpenCommandOpensTheTaskPage() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        var opened: [UUID] = []
        hosted.model.services.openTaskNote = { opened.append($0) }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first)
        let actions = hosted.page.actions(for: row.id, in: .now)
        XCTAssertEqual(actions.names.openPage, "Open task note")
        actions.openPage()
        hosted.spin(0.2)
        XCTAssertEqual(opened, [row.id])
        XCTAssertFalse(hosted.model.expandedFiles.contains(row.id), "⌘Return no longer opens the files list")
        XCTAssertEqual(hosted.model.selection, [row.id], "the row is the anchor Back returns to")
    }

    /// Without the service (Phase 1 hosts), ⌘Return still opens the files.
    func testRowOpenCommandWithoutTaskPagesStillShowsFiles() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first)
        XCTAssertNotEqual(hosted.page.actions(for: row.id, in: .now).names.openPage, "Open task note")
    }
}

@MainActor
private final class CoverProbe {
    var values: [Bool] = []
    var mounts = 0
}

private struct CoverProbeView: View {
    let probe: CoverProbe
    let covered: Bool
    var body: some View {
        Color.clear
            .onAppear { probe.mounts += 1; probe.values.append(covered) }
            .onChange(of: covered) { _, value in probe.values.append(value) }
    }
}
