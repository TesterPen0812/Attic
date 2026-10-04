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
        let page = try page()
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
            if boundary == "close" { lease = try page.acquire(surfaceID: UUID()) }
            let current = try XCTUnwrap(page.captureCallback(for: lease))
            var installed = false
            XCTAssertTrue(page.install(current) { installed = true })
            XCTAssertTrue(installed, "positive control \\(boundary)")
        }
    }

    func testLateWorkspaceImportAfterDraftEditDropsPayloadAndKeepsPendingSource() async throws {
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
        XCTAssertTrue(try XCTUnwrap(page.note).engine.objectIDs().isEmpty)
        XCTAssertEqual(page.note?.engine.plainText, "Body later edit")
        XCTAssertTrue(try XCTUnwrap(page.note).isImporting, "pending source remains owned for recovery/cancellation")
        let entries = try await coordinator.journal.readRecoveryEntries()
        XCTAssertFalse(entries.isEmpty)
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
        XCTAssertNotEqual(note.notice, nil, "stale callback cannot install its old notice result")
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
        XCTAssertEqual(try page.acquire(surfaceID: UUID()), page.activeLease)
        XCTAssertEqual(page.note?.engine.plainText, "Body checkpointed")
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
    init(base: NoteDraftJournal, barrier: WorkspaceCallbackBarrier) { self.base = base; self.barrier = barrier }
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
