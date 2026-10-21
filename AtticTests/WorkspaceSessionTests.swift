import AppKit
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class WorkspaceSessionTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!
    private var coordinator: WorkspaceOperationCoordinator!
    private var notes: NotesPageController!
    private var taskID: UUID!
    private var noteID: UUID!

    override func setUp() async throws {
        root = ownedTemporaryDirectory(prefix: "WorkspaceSessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        coordinator = try WorkspaceOperationCoordinator(container: container, journal: NoteDraftJournal(directory: root))
        taskID = UUID(); noteID = UUID()
        let context = coordinator.freshContext()
        context.insert(TaskItem(id: taskID, title: "Head"))
        let note = NoteItem(id: noteID)
        note.taskID = taskID
        NoteStore.stageDocumentContent(try PreparedNoteDocument(.init(blocks: [.text("Body")])),
            format: 1, on: [note], timestamp: Date(), revision: 0, revisionID: UUID())
        context.insert(note)
        context.insert(TaskNoteAssociation(taskID: taskID, noteID: noteID))
        try context.save()
        notes = NotesPageController(store: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()),
            journal: coordinator.journal, defaults: nil, saveDelay: .seconds(600), durabilityDelay: .seconds(600))
    }
    override func tearDown() async throws {
        notes = nil; coordinator = nil; container = nil
    }
    private func page() throws -> WorkspacePageSession {
        try coordinator.sessions.session(for: .task(taskID), notes: notes)
    }
    private func type(_ text: String, in page: WorkspacePageSession) throws {
        let engine = try XCTUnwrap(page.note?.engine)
        engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
            with: NSAttributedString(string: text), name: "Typing")
    }

    func testTaskAndNoteAliasesHaveOneEngineAndCursorRegardlessOfOpenOrder() throws {
        let noteFirst = try coordinator.sessions.session(for: .note(noteID), notes: notes)
        let task = try page()
        XCTAssertTrue(task === noteFirst)
        XCTAssertTrue(task.note === notes.workspaceSession(noteID: noteID))
        try type(" draft", in: task)
        XCTAssertEqual(task.history.route.totalStepCount, 1)
        XCTAssertTrue(task.note?.engine.history.workspace === task.history)
        XCTAssertEqual(task.note?.engine.plainText, "Body draft")
        XCTAssertTrue(notes.undoRoute.workspace(for: .note(noteID)) === task.history)
    }

    func testDifferentMemoryAndDiskStoresNeverShareSessionsOrRegistry() throws {
        let other = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let otherCoordinator = try WorkspaceOperationCoordinator(container: other,
            journal: NoteDraftJournal(directory: root.appendingPathComponent("Other")))
        XCTAssertNotEqual(WorkspacePersistenceDomain(container), WorkspacePersistenceDomain(other))
        XCTAssertFalse(coordinator.sessions === otherCoordinator.sessions)
        XCTAssertThrowsError(try otherCoordinator.sessions.session(for: .note(noteID), notes: notes))
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let diskA = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: a)
        let diskB = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: b)
        XCTAssertNotEqual(WorkspacePersistenceDomain(diskA), WorkspacePersistenceDomain(diskB))
        let first = try page()
        for separate in [other, diskA, diskB] {
            let gate = try WorkspaceLegacyBridge.coordinator(for: separate)
            let context = gate.freshContext()
            context.insert(TaskItem(id: taskID, title: "Different store"))
            let note = NoteItem(id: noteID); note.taskID = taskID
            context.insert(note); try context.save()
            let controller = NotesPageController(store: NoteStore(container: separate, attachmentFileStore: makeTestAttachmentFileStore()),
                journal: gate.journal, defaults: nil, saveDelay: .seconds(600), durabilityDelay: .seconds(600))
            let second = try gate.sessions.session(for: .task(taskID), notes: controller)
            XCTAssertFalse(first === second)
            XCTAssertFalse(first.note?.engine === second.note?.engine)
            XCTAssertFalse(first.history === second.history)
        }
    }

    func testAliasDivergenceRefusesWithoutSplittingAuthority() throws {
        let existing = try page()
        let context = coordinator.freshContext()
        context.insert(TaskNoteAssociation(taskID: UUID(), noteID: noteID)); try context.save()
        XCTAssertThrowsError(try coordinator.sessions.session(for: .note(noteID), notes: notes))
        XCTAssertThrowsError(try page())
        XCTAssertEqual(existing.note?.engine.plainText, "Body")
    }

    func testTaskWithoutNoteDoesNotCreateOneAndCanBindLater() throws {
        let context = coordinator.freshContext(), id = UUID()
        context.insert(TaskItem(id: id, title: "No note")); try context.save()
        let session = try coordinator.sessions.session(for: .task(id), notes: notes)
        XCTAssertNil(session.note)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<NoteItem>()), 1)
        let lazyID = UUID(), note = NoteItem(id: lazyID)
        note.taskID = id; context.insert(note); try context.save()
        notes.store.refresh()
        let aliased = try coordinator.sessions.session(for: .note(lazyID), notes: notes)
        XCTAssertTrue(aliased === session)
        XCTAssertEqual(session.note?.noteID, lazyID)
    }

    func testSingleLeaseHandoffKeepsDraftHistoryAndRejectsTheFormerSurface() throws {
        let page = try page(), panel = UUID(), window = UUID()
        let lease = try page.acquire(surfaceID: panel)
        try type(" unsaved", in: page)
        let engine = page.note?.engine, cursor = page.history.route.totalStepCount
        let old = try XCTUnwrap(page.captureCallback(for: lease))
        XCTAssertThrowsError(try page.acquire(surfaceID: window))
        let moved = try page.handoff(from: lease, to: window)
        XCTAssertEqual(page.activeLease, moved)
        XCTAssertTrue(page.note?.engine === engine)
        XCTAssertEqual(page.note?.engine.plainText, "Body unsaved")
        XCTAssertEqual(page.history.route.totalStepCount, cursor)
        XCTAssertFalse(page.install(old) { XCTFail("old surface installed") })
        XCTAssertThrowsError(try page.handoff(from: lease, to: panel))
        XCTAssertEqual(try page.acquire(surfaceID: window), moved)
    }

    func testLateImportCheckpointAndPublicationResultsDropAfterEditRebindRefreshAndClose() async throws {
        var page = try page()
        var lease = try page.acquire(surfaceID: UUID())
        for boundary in ["edit", "rebind", "refresh", "close"] {
            let stamps = try (0..<3).map { _ in try XCTUnwrap(page.captureCallback(for: lease)) }
            switch boundary {
            case "edit": try type(" newer", in: page)
            case "rebind": lease = try page.handoff(from: lease, to: UUID())
            case "refresh": page.externalRefresh(origin: "agent")
            default:
                let closed = await page.close(lease)
                XCTAssertTrue(closed)
            }
            for stamp in stamps {
                XCTAssertFalse(page.install(stamp) { XCTFail("stale \\(boundary) result installed") })
                for step in page.publication(for: stamp, install: { XCTFail("stale publication installed") }).steps { try step(UUID()) }
            }
            if boundary == "close" { page = try self.page(); lease = try page.acquire(surfaceID: UUID()) }
            let current = try XCTUnwrap(page.captureCallback(for: lease))
            var installed = false
            XCTAssertTrue(page.install(current) { installed = true })
            XCTAssertTrue(installed, "positive control \\(boundary)")
        }
    }

    func testWorkspaceImportKeepsNewerDraftAndSavesInsertedImage() async throws {
        let barrier = WorkspaceCallbackBarrier()
        let data = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        let source = root.appendingPathComponent("source.png")
        try data.write(to: source)
        notes = NotesPageController(store: notes.store, journal: coordinator.journal, defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600), imageLoader: { _ in
                await barrier.pause()
                return (StagedNoteAttachment(id: UUID(), filename: "source.png", contentTypeIdentifier: "public.png",
                    byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data), CGSize(width: 1, height: 1))
            })
        let opened = await notes.openDurably(noteID: noteID)
        XCTAssertTrue(opened)
        let page = try page()
        _ = try page.acquire(surfaceID: UUID())
        notes.importFiles([source])
        await barrier.waitUntilStarted()
        try type(" later edit", in: page)
        await barrier.release(); await notes.waitForImportWork()
        XCTAssertEqual(try XCTUnwrap(page.note).engine.objectIDs().count, 1)
        XCTAssertTrue(try XCTUnwrap(page.note).engine.plainText.contains("later edit"))
        XCTAssertFalse(try XCTUnwrap(page.note).isImporting)
        await notes.runDueSave(try XCTUnwrap(page.note))
        XCTAssertEqual(notes.store.loadDocument(noteID: noteID)?.content.document, page.note?.engine.document())
        XCTAssertEqual(page.note?.state, .clean)
    }

    func testWorkspaceImportHandoffAndCloseCancelBatchAndKeepSource() async throws {
        for closing in [false, true] {
            let barrier = WorkspaceCallbackBarrier()
            let source = root.appendingPathComponent("handoff-\(closing).png")
            let data = Data([1, 2, 3])
            try data.write(to: source)
            let controller = NotesPageController(store: notes.store, journal: coordinator.journal, defaults: nil,
                saveDelay: .seconds(600), durabilityDelay: .seconds(600), imageLoader: { _ in
                    await barrier.pause()
                    return (StagedNoteAttachment(id: UUID(), filename: "source.png", contentTypeIdentifier: "public.png",
                        byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data), nil)
                })
            // Give the second iteration a distinct workspace/controller.
            let task = UUID(), id = UUID(), context = coordinator.freshContext()
            context.insert(TaskItem(id: task, title: "Import"))
            let row = NoteItem(id: id); row.taskID = task
            NoteStore.stageDocumentContent(try PreparedNoteDocument(.init(blocks: [.text("Import body")])),
                format: 1, on: [row], timestamp: Date(), revision: 0, revisionID: UUID())
            context.insert(row); try context.save(); controller.store.refresh()
            let opened = await controller.openDurably(noteID: id)
            XCTAssertTrue(opened)
            let page = try coordinator.sessions.session(for: .task(task), notes: controller)
            let lease = try page.acquire(surfaceID: UUID())
            controller.importFiles([source])
            await barrier.waitUntilStarted()
            if closing {
                let closed = await page.close(lease)
                XCTAssertTrue(closed)
            } else {
                _ = try page.handoff(from: lease, to: UUID())
            }
            await barrier.release()
            await controller.waitForImportWork(); await controller.waitForRecoveryWork()
            XCTAssertFalse(try XCTUnwrap(page.note).isImporting)
            XCTAssertTrue(try XCTUnwrap(page.note).engine.objectIDs().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            let entries = try await coordinator.journal.readRecoveryEntries()
            for entry in entries {
                if case let .valid(draft, _, _) = entry, draft.noteID == id {
                    XCTAssertNil(draft.pendingImport, "cancellation cannot leave recoverable pending metadata")
                }
            }
        }
    }

    func testWorkspaceImportBindingMismatchCancelsInsteadOfSticking() async throws {
        let barrier = WorkspaceCallbackBarrier(), data = Data([1, 2, 3])
        let source = root.appendingPathComponent("stale.png")
        try data.write(to: source)
        notes = NotesPageController(store: notes.store, journal: coordinator.journal, defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600), imageLoader: { _ in
                await barrier.pause()
                return (StagedNoteAttachment(id: UUID(), filename: "stale.png", contentTypeIdentifier: "public.png",
                    byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data), nil)
            })
        let opened = await notes.openDurably(noteID: noteID)
        XCTAssertTrue(opened)
        let page = try page(); _ = try page.acquire(surfaceID: UUID())
        notes.importFiles([source]); await barrier.waitUntilStarted()
        try XCTUnwrap(page.note).invalidateCallbacks()
        await barrier.release(); await notes.waitForImportWork(); await notes.waitForRecoveryWork()
        XCTAssertFalse(try XCTUnwrap(page.note).isImporting)
        XCTAssertTrue(try XCTUnwrap(page.note).engine.objectIDs().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testOrdinaryNotesCheckpointCompletionAfterEditClearsNoticeAndReportsFailure() async throws {
        for failing in [false, true] {
            let id = UUID(), context = coordinator.freshContext()
            // Separate notes keep the two recovery outcomes independent.
            let fixture = NoteItem(id: id)
            NoteStore.stageDocumentContent(try PreparedNoteDocument(.init(blocks: [.text("Body")])),
                format: 1, on: [fixture], timestamp: Date(), revision: 0, revisionID: UUID())
            context.insert(fixture); try context.save()
            let barrier = WorkspaceCallbackBarrier()
            let journal = WorkspaceBarrierJournal(base: coordinator.journal, barrier: barrier, failWrite: failing)
            let controller = NotesPageController(store: NoteStore(container: container,
                persist: { _ in throw WorkspaceFoundationError.unknown }, attachmentFileStore: makeTestAttachmentFileStore()),
                journal: journal, defaults: nil, saveDelay: .seconds(600), durabilityDelay: .seconds(600))
            let opened = await controller.openDurably(noteID: id)
            XCTAssertTrue(opened)
            let note = try XCTUnwrap(controller.active)
            note.engine.performEdit(NSRange(location: note.engine.textStorage.length, length: 0),
                with: NSAttributedString(string: " first"), name: "Typing")
            _ = controller.preserve(note)
            await barrier.waitUntilStarted()
            XCTAssertEqual(note.notice, "Saving recovery data…")
            note.engine.performEdit(NSRange(location: note.engine.textStorage.length, length: 0),
                with: NSAttributedString(string: " newer"), name: "Typing")
            await barrier.release(); await controller.waitForRecoveryWork()
            XCTAssertNil(note.notice)
            XCTAssertEqual(note.engine.plainText, "Body first newer")
            XCTAssertFalse(controller.workspaceIsDurable(note))
            if failing {
                if case let .onlyInMemory(reason) = note.state { XCTAssertTrue(reason.contains("Recovery could not be saved")) }
                else { XCTFail("checkpoint failure must be reported despite the newer draft") }
            } else {
                if case .notSaved = note.state {} else { XCTFail("successful recovery reports store failure") }
                let entries = try await coordinator.journal.readRecoveryEntries()
                XCTAssertFalse(entries.isEmpty)
            }
        }
    }

    func testNotesOpenRefusesLeasedWorkspaceAndExternalRefreshKeepsOneSession() throws {
        let page = try page(), note = try XCTUnwrap(page.note), engine = note.engine
        let lease = try page.acquire(surfaceID: UUID())
        XCTAssertFalse(notes.open(noteID: noteID))
        XCTAssertNil(notes.active)
        let context = coordinator.freshContext()
        let id = noteID!
        let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
        NoteStore.stageDocumentContent(try PreparedNoteDocument(.init(blocks: [.text("Changed externally")])),
            format: 1, on: rows, timestamp: Date(), revision: 1, revisionID: UUID())
        try context.save(); notes.store.refresh()
        XCTAssertFalse(notes.open(noteID: noteID))
        XCTAssertTrue(page.note === note); XCTAssertTrue(page.note?.engine === engine)
        page.externalRefresh(origin: "agent")
        XCTAssertTrue(page.note === note)
        XCTAssertTrue(notes.workspaceSession(noteID: noteID) === note)
        XCTAssertEqual(note.engine.plainText, "Changed externally")
        XCTAssertEqual(page.activeLease, lease)
        XCTAssertFalse(notes.openFailedDraft(sessionID: note.id))
    }

    func testWorkspaceReusesActiveNoteAfterCacheAdmissionEvictsItsEntry() async throws {
        let opened = await notes.openDurably(noteID: noteID)
        XCTAssertTrue(opened)
        notes.present()
        let context = coordinator.freshContext()
        var ids: [(UUID, UUID)] = []
        for index in 0..<8 {
            let task = UUID(), id = UUID()
            let fixture = NoteItem(id: id); fixture.taskID = task
            context.insert(TaskItem(id: task, title: "Cached \(index)"))
            NoteStore.stageDocumentContent(try PreparedNoteDocument(.init(blocks: [.text("Cached \(index)")])),
                format: 1, on: [fixture], timestamp: Date(), revision: 0, revisionID: UUID())
            context.insert(fixture); ids.append((task, id))
        }
        try context.save(); notes.store.refresh()
        // Seven bound notes protect their cache slots. Together with the
        // visible note they fill the eight-slot cache before the incoming open.
        for (task, _) in ids.prefix(7) {
            _ = try coordinator.sessions.session(for: .task(task), notes: notes)
        }
        let incoming = try XCTUnwrap(ids.last)
        let shown = await notes.openDurably(noteID: incoming.1)
        XCTAssertTrue(shown)
        let active = try XCTUnwrap(notes.active), engine = active.engine
        let page = try coordinator.sessions.session(for: .task(incoming.0), notes: notes)
        XCTAssertTrue(page.note === active)
        XCTAssertTrue(page.note?.engine === engine)
        _ = try page.acquire(surfaceID: UUID())
        XCTAssertFalse(notes.open(noteID: incoming.1))
    }

    func testSuspendWorkspaceDoesNotDetachTheActiveNotesEditor() async throws {
        let barrier = WorkspaceCallbackBarrier(), data = Data([1, 2, 3])
        let source = root.appendingPathComponent("active.png")
        try data.write(to: source)
        notes = NotesPageController(store: notes.store, journal: coordinator.journal, defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600), imageLoader: { _ in
                await barrier.pause()
                return (StagedNoteAttachment(id: UUID(), filename: "active.png", contentTypeIdentifier: "public.png",
                    byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data), nil)
            })
        let opened = await notes.openDurably(noteID: noteID)
        XCTAssertTrue(opened)
        let note = try XCTUnwrap(notes.active)
        let (scroll, view) = note.engine.makeView()
        _ = scroll
        notes.importFiles([source]); await barrier.waitUntilStarted()
        notes.suspendWorkspace(note)
        XCTAssertTrue(note.engine.textView === view)
        XCTAssertTrue(note.isImporting, "suspending a workspace must not cancel the active Notes page's batch")
        await barrier.release(); await notes.waitForImportWork(); await notes.waitForRecoveryWork()
        XCTAssertEqual(note.engine.objectIDs().count, 1)
        XCTAssertFalse(note.isImporting)
        note.engine.detachView()
    }

    func testCleanCloseReleasesRegistryPageAndKeepsTheCachedEditorWarm() async throws {
        var page: WorkspacePageSession? = try self.page()
        weak var weakPage = page
        weak var weakNote = page?.note
        weak var weakEngine = page?.note?.engine
        let lease = try XCTUnwrap(page).acquire(surfaceID: UUID())
        let closed = await page!.close(lease)
        XCTAssertTrue(closed)
        XCTAssertFalse(try XCTUnwrap(page?.note).usesWorkspaceBinding)
        XCTAssertThrowsError(try page!.acquire(surfaceID: UUID()))
        page = nil
        XCTAssertNil(weakPage)
        XCTAssertNotNil(weakNote); XCTAssertNotNil(weakEngine)
        let reopened = try self.page()
        XCTAssertTrue(reopened.note === weakNote)
        XCTAssertTrue(reopened.note?.engine === weakEngine)
        XCTAssertEqual(reopened.note?.engine.plainText, "Body")
    }

    func testAliasResolutionFetchesOnlyMatchingReplicasInPopulatedStore() throws {
        let context = coordinator.freshContext()
        for _ in 0..<40 {
            let task = TaskItem(title: "Unrelated"), note = NoteItem()
            note.taskID = task.id
            context.insert(task); context.insert(note)
            context.insert(TaskNoteAssociation(taskID: task.id, noteID: note.id))
        }
        // Agreeing duplicates must all participate in the scoped fetch.
        let duplicate = NoteItem(id: noteID); duplicate.taskID = taskID
        context.insert(duplicate)
        context.insert(TaskNoteAssociation(taskID: taskID, noteID: noteID))
        try context.save(); notes.store.refresh()
        var fetched: [(Int, Int)] = []
        coordinator.sessions.didFetchResolutionRows = { fetched.append(($0, $1)) }
        _ = try page()
        _ = try coordinator.sessions.session(for: .note(noteID), notes: notes)
        XCTAssertEqual(fetched.map { $0.0 }, [4, 6])
        XCTAssertEqual(fetched.map { $0.1 }, [4, 6])
        duplicate.taskID = UUID(); try context.save()
        XCTAssertThrowsError(try page(), "divergent replicas still refuse after predicate narrowing")
    }

    func testOrphanRegistryRebindDropsOldPages() async throws {
        await notes.store.waitForAttachmentReconciliation()
        let registry = coordinator.sessions
        weak var oldPage: WorkspacePageSession?
        do { let page = try self.page(); oldPage = page }
        XCTAssertNotNil(oldPage)
        notes = nil
        coordinator = nil
        let replacement = try WorkspaceOperationCoordinator(container: container, journal: NoteDraftJournal(directory: root))
        registry.rebind(to: replacement)
        XCTAssertTrue(replacement.sessions === registry)
        XCTAssertNil(oldPage)
        let otherNotes = NotesPageController(store: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()),
            journal: replacement.journal, defaults: nil)
        let fresh = try replacement.sessions.session(for: .task(taskID), notes: otherNotes)
        XCTAssertEqual(fresh.note?.engine.plainText, "Body")
    }

    func testPreparedSaveDropsAfterLeaseHandoffWithoutOverwritingDurableBody() async throws {
        let barrier = WorkspaceCallbackBarrier()
        notes = NotesPageController(store: notes.store, journal: coordinator.journal, defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600),
            prepareDocument: { document in await barrier.pause(); return try? PreparedNoteDocument(document) })
        let page = try page(), lease = try page.acquire(surfaceID: UUID())
        try type(" prepared", in: page)
        let note = try XCTUnwrap(page.note)
        let controller = notes!
        let work = Task { await controller.runDueSave(note) }
        await barrier.waitUntilStarted()
        _ = try page.handoff(from: lease, to: UUID())
        await barrier.release(); await work.value
        XCTAssertEqual(notes.store.loadDocument(noteID: noteID)?.content.document?.title, "Body")
        XCTAssertEqual(page.note?.engine.plainText, "Body prepared")
    }

    func testStaleCheckpointKeepsItsClaimButCannotMarkANewerDraftDurable() async throws {
        let barrier = WorkspaceCallbackBarrier()
        let journal = WorkspaceBarrierJournal(base: coordinator.journal, barrier: barrier)
        let failedStore = NoteStore(container: container, persist: { _ in throw WorkspaceFoundationError.unknown },
            attachmentFileStore: makeTestAttachmentFileStore())
        notes = NotesPageController(store: failedStore, journal: journal, defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        let page = try page(), lease = try page.acquire(surfaceID: UUID())
        try type(" first", in: page)
        let note = try XCTUnwrap(page.note)
        _ = notes.preserve(note)
        await barrier.waitUntilStarted()
        _ = try page.handoff(from: lease, to: UUID())
        await barrier.release(); await notes.waitForRecoveryWork()
        XCTAssertTrue(coordinator.retainedRecoveryBytes.isEmpty)
        let entries = try await coordinator.journal.readRecoveryEntries()
        XCTAssertEqual(entries.count, 1, "stale completion retains durable recovery ownership")
        XCTAssertEqual(page.note?.engine.plainText, "Body first")
        XCTAssertNil(note.notice, "completed recovery must clear its saving notice")
        XCTAssertFalse(notes.workspaceIsDurable(note), "old binding must not verify the current draft")
        if case .notSaved = note.state {} else { XCTFail("checkpoint success reports the failed store save") }
    }

    func testCloseSavesTheDraftBeforeRevokingLeaseAndHiddenIdleDoesNotPoll() async throws {
        let page = try page(), lease = try page.acquire(surfaceID: UUID())
        try type(" durable", in: page)
        let closed = await page.close(lease)
        XCTAssertTrue(closed); XCTAssertNil(page.activeLease)
        let loaded = try XCTUnwrap(notes.store.loadDocument(noteID: noteID)?.content.document)
        XCTAssertEqual(loaded.title, "Body durable")
        var saves = 0, reads = 0
        coordinator.save = { context in saves += 1; try context.save() }
        coordinator.beforeReconciliationRead = { reads += 1 }
        coordinator.validationCounters = .init()
        for _ in 0..<100 {
            _ = page.activitySnapshot
            await Task.yield()
        }
        XCTAssertEqual(saves, 0); XCTAssertEqual(reads, 0)
        XCTAssertEqual(coordinator.validationCounters, .init())
        let tasks = TaskStore(container: container)
        coordinator.validationCounters = .init()
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: taskID)), title: "head edit"))
        XCTAssertEqual(coordinator.validationCounters, .init(fastValidations: 1, slowValidations: 0, freshContexts: 0))
    }

    func testWarmCloseReusesTheEditorButRevokesThePageLeaseAndCallbacks() async throws {
        let old = try page(), lease = try old.acquire(surfaceID: UUID())
        let note = try XCTUnwrap(old.note), engine = note.engine
        try type(" warm", in: old)
        let stamp = try XCTUnwrap(old.captureCallback(for: lease))
        let closed = await old.close(lease)
        XCTAssertTrue(closed)
        XCTAssertNil(engine.textView)
        XCTAssertNil(note.workspacePage)
        XCTAssertFalse(note.usesWorkspaceBinding)
        XCTAssertThrowsError(try old.acquire(surfaceID: UUID()))

        let reopened = try page(), next = try reopened.acquire(surfaceID: UUID())
        XCTAssertFalse(reopened === old)
        XCTAssertTrue(reopened.note === note)
        XCTAssertTrue(reopened.note?.engine === engine)
        XCTAssertTrue(reopened.history === old.history)
        XCTAssertNotEqual(next, lease)
        XCTAssertFalse(old.install(stamp) { XCTFail("closed callback installed") })
        XCTAssertFalse(reopened.install(stamp) { XCTFail("old lease installed") })
        XCTAssertEqual(engine.plainText, "Body warm")
        XCTAssertTrue(reopened.history.undo())
        XCTAssertEqual(engine.plainText, "Body")
        let reclosed = await reopened.close(next)
        XCTAssertTrue(reclosed)
        XCTAssertEqual(notes.store.loadDocument(noteID: noteID)?.content.document?.title, "Body")
    }

    func testClosedWorkspaceUsesTheSameEightSlotLRUAsPlainNotes() async throws {
        let old = try page(), lease = try old.acquire(surfaceID: UUID())
        let original = try XCTUnwrap(old.note)
        let closed = await old.close(lease)
        XCTAssertTrue(closed)
        let context = coordinator.freshContext()
        var ids: [UUID] = []
        for index in 0..<9 {
            let note = NoteItem()
            NoteStore.stageDocumentContent(try PreparedNoteDocument(.init(blocks: [.text("Plain \(index)")])),
                format: 1, on: [note], timestamp: Date(), revision: 0, revisionID: UUID())
            context.insert(note); ids.append(note.id)
        }
        try context.save(); notes.store.refresh()
        for id in ids { XCTAssertTrue(notes.open(noteID: id)) }
        let reopened = try page()
        XCTAssertFalse(reopened.note === original, "a closed clean task note yields its slot just like a plain note")
        let next = try reopened.acquire(surfaceID: UUID())
        let warm = try XCTUnwrap(reopened.note)
        let reclosed = await reopened.close(next)
        XCTAssertTrue(reclosed)
        XCTAssertTrue(try page().note === warm, "the newly used session stays warm")
    }

    func testWarmReopenRefreshesACleanClosedNoteAfterAnExternalWrite() async throws {
        let old = try page(), lease = try old.acquire(surfaceID: UUID())
        let original = try XCTUnwrap(old.note)
        try type(" before external edit", in: old)
        let closed = await old.close(lease)
        XCTAssertTrue(closed)
        let context = coordinator.freshContext(), id = noteID!
        let replicas = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
        NoteStore.stageDocumentContent(try PreparedNoteDocument(.init(blocks: [.text("External body")])),
            format: 1, on: replicas, timestamp: Date(), revision: 1, revisionID: UUID())
        try context.save()
        let reopened = try page()
        XCTAssertFalse(reopened.note === original)
        XCTAssertEqual(reopened.note?.engine.plainText, "External body")
        let next = try reopened.acquire(surfaceID: UUID())
        XCTAssertFalse(reopened.history.undo(), "reopening cannot replay the retired editor across an external edit")
        try type(" after", in: reopened)
        XCTAssertTrue(reopened.history.undo())
        XCTAssertEqual(reopened.note?.engine.plainText, "External body")
        XCTAssertFalse(reopened.history.undo())
        let reclosed = await reopened.close(next)
        XCTAssertTrue(reclosed)
        XCTAssertEqual(notes.store.loadDocument(noteID: id)?.content.document?.title, "External body")
    }

    func testClosePreservesEditsMadeWhileCheckpointIsSuspendedAndRefusesHandoff() async throws {
        let barrier = WorkspaceCallbackBarrier()
        let journal = WorkspaceBarrierJournal(base: coordinator.journal, barrier: barrier)
        notes = NotesPageController(store: NoteStore(container: container, persist: { _ in throw WorkspaceFoundationError.unknown },
            attachmentFileStore: makeTestAttachmentFileStore()), journal: journal, defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        let page = try page(), lease = try page.acquire(surfaceID: UUID())
        try type(" first", in: page)
        let controller = notes!
        let work = Task { await page.close(lease) }
        await barrier.waitUntilStarted()
        XCTAssertThrowsError(try page.handoff(from: lease, to: UUID()))
        try type(" latest", in: page)
        await barrier.release()
        let closed = await work.value
        XCTAssertTrue(closed); XCTAssertNil(page.activeLease)
        let entries = try await coordinator.journal.readRecoveryEntries()
        guard case let .valid(entry, _, _) = try XCTUnwrap(entries.first) else { return XCTFail("checkpoint") }
        XCTAssertEqual(NoteContentCodec.decode(entry.content).document?.title, "Body first latest")
        XCTAssertTrue(controller.workspaceIsDurable(try XCTUnwrap(page.note)))
    }

    func testCloseCheckpointsWhenSaveFailsAndRetainsRecoveryAfterReopen() async throws {
        let failedStore = NoteStore(container: container, persist: { _ in throw WorkspaceFoundationError.unknown },
            attachmentFileStore: makeTestAttachmentFileStore())
        notes = NotesPageController(store: failedStore, journal: coordinator.journal, defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        let page = try page(), lease = try page.acquire(surfaceID: UUID())
        try type(" checkpointed", in: page)
        let closed = await page.close(lease)
        XCTAssertTrue(closed); XCTAssertNil(page.activeLease)
        let entries = try await coordinator.journal.readRecoveryEntries()
        XCTAssertEqual(entries.count, 1)
        guard case let .valid(entry, _, _) = entries[0] else { return XCTFail("missing claimed recovery") }
        XCTAssertEqual(NoteContentCodec.decode(entry.content).document?.title, "Body checkpointed")
        XCTAssertNil(coordinator.ownership.tryAcquire([noteID], kind: .collection))
        let reopened = try self.page()
        XCTAssertFalse(reopened === page)
        _ = try reopened.acquire(surfaceID: UUID())
        XCTAssertTrue(reopened.note === page.note, "protected recovery draft keeps one cached session")
        XCTAssertEqual(reopened.note?.engine.plainText, "Body checkpointed")
    }

    func testClosedCheckpointDraftSurvivesWarmCachePressure() async throws {
        notes = NotesPageController(store: NoteStore(container: container,
            persist: { _ in throw WorkspaceFoundationError.unknown },
            attachmentFileStore: makeTestAttachmentFileStore()), journal: coordinator.journal,
            defaults: nil, saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        let old = try page(), lease = try old.acquire(surfaceID: UUID())
        try type(" protected", in: old)
        let closed = await old.close(lease)
        XCTAssertTrue(closed)
        let original = try XCTUnwrap(old.note)
        let context = coordinator.freshContext()
        var ids: [UUID] = []
        for index in 0..<10 {
            let note = NoteItem()
            NoteStore.stageDocumentContent(try PreparedNoteDocument(.init(blocks: [.text("Pressure \(index)")])),
                format: 1, on: [note], timestamp: Date(), revision: 0, revisionID: UUID())
            context.insert(note); ids.append(note.id)
        }
        try context.save(); notes.store.refresh()
        for id in ids { XCTAssertTrue(notes.open(noteID: id)) }
        let reopened = try page(), next = try reopened.acquire(surfaceID: UUID())
        XCTAssertTrue(reopened.note === original)
        XCTAssertEqual(original.engine.plainText, "Body protected")
        let entries = try await coordinator.journal.readRecoveryEntries()
        XCTAssertEqual(entries.count, 1)
        let reclosed = await reopened.close(next)
        XCTAssertTrue(reclosed)
    }

    func testExternalRefreshReplacesCleanEngineAndPreservesDirtyDraftBehindABarrier() throws {
        let page = try page(), lease = try page.acquire(surfaceID: UUID())
        let stale = try XCTUnwrap(page.captureCallback(for: lease))
        let old = page.note?.engine
        let context = coordinator.freshContext()
        let rows = try context.fetch(FetchDescriptor<NoteItem>())
        NoteStore.stageDocumentContent(try PreparedNoteDocument(.init(blocks: [.text("External")])),
            format: 1, on: rows, timestamp: Date(), revision: 1, revisionID: UUID())
        try context.save()
        page.externalRefresh(origin: "agent")
        XCTAssertFalse(page.install(stale) { XCTFail("stale external result") })
        XCTAssertFalse(page.note?.engine === old)
        XCTAssertTrue(page.note === notes.workspaceSession(noteID: noteID))
        XCTAssertTrue(page.note?.engine.history.workspace === page.history)
        XCTAssertEqual(page.note?.engine.plainText, "External")
        XCTAssertFalse(page.history.undo(), "external barrier has no inverse")
        try type(" local draft", in: page)
        let second = coordinator.freshContext()
        NoteStore.stageDocumentContent(try PreparedNoteDocument(.init(blocks: [.text("Second external")])),
            format: 1, on: try second.fetch(FetchDescriptor<NoteItem>()), timestamp: Date(), revision: 2, revisionID: UUID())
        try second.save()
        page.externalRefresh(origin: "agent")
        XCTAssertEqual(page.note?.engine.plainText, "External local draft")
        XCTAssertEqual(page.note?.state, .conflict(.changed))
    }

    func testCloseRefusesWhenSaveAndCheckpointBothFailAndKeepsLeaseAndDraft() async throws {
        // No recovery journal is a deterministic checkpoint failure.
        let failed = NotesPageController(store: NoteStore(container: container, persist: { _ in throw WorkspaceFoundationError.unknown },
            attachmentFileStore: makeTestAttachmentFileStore()), journal: nil, defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        let page = try coordinator.sessions.session(for: .task(taskID), notes: failed)
        let lease = try page.acquire(surfaceID: UUID())
        try type(" only in memory", in: page)
        let closed = await page.close(lease)
        XCTAssertFalse(closed); XCTAssertEqual(page.activeLease, lease)
        XCTAssertEqual(page.note?.engine.plainText, "Body only in memory")
        XCTAssertFalse(try XCTUnwrap(failed.store.note(withID: noteID)?.modelContext).hasChanges)
    }

    func testDeferredPurgeProjectionRetainsProtectedDraftAndCheckpointBytes() async throws {
        let page = try page(), lease = try page.acquire(surfaceID: UUID())
        let note = try XCTUnwrap(page.note)
        let data = Data("retained".utf8)
        let bytes = StagedNoteAttachment(id: UUID(), filename: "kept.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data)
        note.engine.beginImageImport()
        XCTAssertTrue(note.engine.insertImportedObjects([NoteImportedObject(staged: bytes, pixelSize: nil)], acceptedText: ""))
        note.engine.writingToolsWillBegin()
        XCTAssertFalse(page.activitySnapshot.canCommit)
        let preserved = await notes.preserveDurably(note)
        XCTAssertTrue(preserved)
        let inventory = try await coordinator.journal.readRecoveryEntries()
        XCTAssertFalse(inventory.isEmpty)
        XCTAssertTrue(coordinator.retainedRecoveryBytes.contains(bytes.id))
        XCTAssertNil(coordinator.ownership.tryAcquire([bytes.id], kind: .collection))
        let closed = await page.close(lease)
        XCTAssertFalse(closed)
        XCTAssertEqual(page.activeLease, lease)
    }
    func testFieldCommitAndCancelRetireOnlyTheirUndoTargetAndRecordOnce() throws {
        let page = try page(), manager = UndoManager()
        manager.groupsByEvent = false
        let foreign = WorkspaceFieldUndo.Target()
        var foreignUndos = 0, fieldUndos = 0
        let field = WorkspaceFieldUndo(manager: manager)
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: foreign) { _ in foreignUndos += 1 }
        manager.registerUndo(withTarget: field.target) { _ in fieldUndos += 1 }
        manager.endUndoGrouping()
        var commits = 0
        let commit = {
            commits += 1
            return UndoStep(name: "Rename", undo: { true }, redo: { true })
        }
        XCTAssertTrue(field.commit(to: page.history, save: commit))
        XCTAssertFalse(field.commit(to: page.history, save: commit))
        XCTAssertEqual(commits, 1); XCTAssertEqual(page.history.route.totalStepCount, 1)
        manager.undo()
        XCTAssertEqual(foreignUndos, 1); XCTAssertEqual(fieldUndos, 0)
        let cancelled = WorkspaceFieldUndo(manager: manager)
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: foreign) { _ in foreignUndos += 1 }
        manager.registerUndo(withTarget: cancelled.target) { _ in fieldUndos += 1 }
        manager.endUndoGrouping()
        cancelled.cancel(); manager.undo()
        XCTAssertEqual(foreignUndos, 2); XCTAssertEqual(fieldUndos, 0)
        XCTAssertEqual(page.history.route.totalStepCount, 1)
    }

    func testRefusedFieldCommitKeepsNativeUndoAndWorkspaceCursor() throws {
        let page = try page(), manager = UndoManager()
        manager.groupsByEvent = false
        let field = WorkspaceFieldUndo(manager: manager)
        var fieldUndos = 0
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: field.target) { _ in fieldUndos += 1 }
        manager.endUndoGrouping()
        XCTAssertFalse(field.commit(to: page.history, save: { nil }))
        XCTAssertEqual(page.history.route.totalStepCount, 0)
        manager.undo(); XCTAssertEqual(fieldUndos, 1)
    }
}

private actor WorkspaceCallbackBarrier {
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
private final class WorkspaceBarrierJournal: NoteDraftJournaling {
    let base: NoteDraftJournal
    let barrier: WorkspaceCallbackBarrier
    var workspaceJournal: NoteDraftJournal? { base }
    var requiresAsyncIO: Bool { true }
    let failWrite: Bool
    init(base: NoteDraftJournal, barrier: WorkspaceCallbackBarrier, failWrite: Bool = false) { self.base = base; self.barrier = barrier; self.failWrite = failWrite }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
                      replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        await barrier.pause()
        if failWrite { throw WorkspaceFoundationError.unknown }
        return try await base.writeDurably(entry, staged: staged, replacing: claim)
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        try await base.retireDurably(noteID: noteID, claim: claim, saved: saved)
    }
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { try base.recoveryEntries() }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] { try await base.readRecoveryEntries() }
}
