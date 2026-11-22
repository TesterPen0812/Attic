import Combine
import Foundation
import SwiftData
import XCTest
@testable import Attic

/// A delete refreshes the stores once, through the lifecycle's commit step
/// (`WorkspaceItemLifecycle.didCommit`), and the library adds its own refresh
/// only where that step does not reach it: a canvas, or a library that isn't
/// the lifecycle's. Counted as NoteStore `revision` publishes: each refresh
/// publishes once, and so does each step of a note store's own save.
@MainActor
final class LibraryDeleteRefreshTests: XCTestCase {
    private var container: ModelContainer!
    private var coordinator: WorkspaceOperationCoordinator!
    private var tasks: TaskStore!
    private var notes: NoteStore!
    private var canvases: CanvasStore!
    private var library: AtticLibrary!
    private var controller: NotesPageController!
    private var otherLibrary: AtticLibrary?
    private var otherController: NotesPageController?
    private var bag = Set<AnyCancellable>()
    private let plain = UUID(), owner = UUID(), writing = UUID(), loose = UUID()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        let context = ModelContext(container)
        context.insert(TaskItem(id: plain, title: "No writing", createdAt: date, manualOrder: 1))
        context.insert(TaskItem(id: owner, title: "With writing", createdAt: date, manualOrder: 2))
        let document = try NoteContentCodec.encode(NoteDocument(blocks: [.text("With writing"), .text("Writing")], requires: ["taskNote"]))
        let owned = NoteItem(id: writing, title: "With writing", body: "Writing", createdAt: date)
        owned.taskID = owner
        owned.content = document
        context.insert(owned)
        context.insert(NoteItem(id: loose, title: "Loose note", body: "Body", createdAt: date))
        try context.save()
        let fixedDate = date
        tasks = TaskStore(container: container, now: { fixedDate })
        notes = NoteStore(container: container, now: { fixedDate }, attachmentFileStore: makeTestAttachmentFileStore())
        canvases = CanvasStore(container: container)
        library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        // The Notes page's controller, as the app makes it: the lifecycle's
        // whole-item publish goes through it.
        controller = NotesPageController(store: notes, journal: coordinator.journal)
        await notes.waitForAttachmentReconciliation()
    }

    override func tearDown() async throws {
        bag.removeAll()
        await coordinator.lifecycleNotes?.waitForRecoveryWork()
        await notes.waitForAttachmentReconciliation()
        otherController = nil; otherLibrary = nil
        controller = nil; library = nil; canvases = nil; tasks = nil; notes = nil; coordinator = nil; container = nil
    }

    /// `revision` publishes of `store` (NoteStore by default) while `body` runs.
    private func revisionPublishes(of store: NoteStore? = nil, _ body: () -> Void) -> Int {
        var count = 0
        let watch = (store ?? notes).$revision.dropFirst().sink { _ in count += 1 }
        body()
        watch.cancel()
        return count
    }

    func testTaskDeleteRefreshesNotesOnceThroughTheLifecycle() throws {
        XCTAssertTrue(coordinator.lifecycleLibrary === library)
        XCTAssertTrue(coordinator.lifecycleNotes === controller)
        let deleted = revisionPublishes { XCTAssertTrue(library.deleteTasks([plain]).isApplied) }
        // The commit step publishes once: the library's stores refresh
        // (`AtticLibrary.refreshItemStores`) reloads this NoteStore. The Notes
        // controller presents from that same store, so its whole-item publish
        // does not reload it again (`publishWholeItemLifecycle`
        // `notesReadInThisCommit:`); it would only if that reload had failed.
        // The library adds none.
        XCTAssertEqual(deleted, 1, "a task delete refreshes NoteStore only through its commit step")
        XCTAssertTrue(try rowDeleted(plain), "the task is in Recently Deleted")
        let undone = revisionPublishes { XCTAssertTrue(library.undo.undo(in: .tasks)) }
        // Undo commits through the same step: the one publish is again the
        // library's stores refresh.
        XCTAssertEqual(undone, 1, "Undo of the delete refreshes as the delete does")
        XCTAssertNotNil(tasks.task(withID: plain), "Undo brought the task back")
    }

    func testDeletingATaskThatOwnsWritingStillUpdatesNotes() throws {
        XCTAssertNotNil(notes.note(withID: writing))
        // What the Notes controller shows comes from its own store. That store
        // is the library's, so the library's stores refresh is what moves it;
        // the controller's whole-item publish no longer reloads it.
        let shown = controller.store
        XCTAssertTrue(shown === notes, "the Notes controller presents from the library's note store")
        XCTAssertTrue(shown.notes.contains { $0.id == writing })
        let deleted = revisionPublishes(of: shown) { XCTAssertTrue(library.deleteTasks([owner]).isApplied) }
        // One publish: the library's stores refresh, which carries the
        // writing's deletion.
        XCTAssertEqual(deleted, 1)
        XCTAssertNil(notes.note(withID: writing), "the task's writing left Notes with it")
        XCTAssertNil(shown.note(withID: writing), "the writing left the Notes controller's own view on delete")
        XCTAssertFalse(shown.notes.contains { $0.id == writing })
        XCTAssertTrue(try rowDeleted(writing))
        let undone = revisionPublishes(of: shown) { XCTAssertTrue(library.undo.undo(in: .tasks)) }
        // One publish again, the library's stores refresh, carrying the restore.
        XCTAssertEqual(undone, 1)
        XCTAssertNotNil(notes.note(withID: writing), "Undo brought the writing back to Notes")
        XCTAssertNotNil(shown.note(withID: writing), "Undo brought the writing back to the Notes controller's own view")
        XCTAssertTrue(shown.notes.contains { $0.id == writing })
    }

    // A restore from Recently Deleted (`AtticLibrary.restore`) reloads each
    // store once, as a delete does: the library adds its own refresh only
    // where the restore's commit step does not reach its stores, and never
    // reloads Tasks after a task store's save that already read them fresh.

    /// Whole Tasks reloads (what `TaskStore.refresh()` runs) of `store` (TaskStore by default) while `body` runs;
    /// an incremental task commit names its IDs and is not counted.
    private func taskReloads(of store: TaskStore? = nil, _ body: () -> Void) -> Int {
        let store: TaskStore = store ?? tasks
        var count = 0
        let watch = store.$revision.dropFirst().sink { _ in if store.revisionChangedTaskIDs == nil { count += 1 } }
        body()
        watch.cancel()
        return count
    }

    func testRecentlyDeletedTaskRestoreReloadsEachStoreOnce() throws {
        XCTAssertTrue(library.deleteTasks([plain]).isApplied)
        var notesPublished = 0
        let reloads = taskReloads {
            notesPublished = revisionPublishes { XCTAssertTrue(library.restore(AtticItemRef(.task, plain))) }
        }
        XCTAssertEqual(reloads, 1, "the task store's own save is the restore's one Tasks reload")
        XCTAssertEqual(notesPublished, 1, "the commit step is the restore's one Notes refresh")
        XCTAssertNotNil(tasks.task(withID: plain), "the task is back in Tasks")
    }

    func testRecentlyDeletedNoteRestoreAddsNoRefreshToItsCommitStep() throws {
        // The same note restore with and without the library's step around
        // it: Undo of a delete reaches the store directly.
        XCTAssertTrue(library.delete(AtticItemRef(.note, loose)))
        var direct = 0
        let directReloads = taskReloads { direct = revisionPublishes { XCTAssertTrue(library.undo.undo(in: .note(loose))) } }
        XCTAssertNotNil(notes.note(withID: loose))
        XCTAssertTrue(library.delete(AtticItemRef(.note, loose)))
        var restored = 0
        let restoredReloads = taskReloads {
            restored = revisionPublishes { XCTAssertTrue(library.restore(AtticItemRef(.note, loose))) }
        }
        XCTAssertEqual(restored, direct, "Recently Deleted's restore refreshes Notes as the store's own restore does")
        XCTAssertEqual(restoredReloads, directReloads, "and reloads Tasks as it does")
        XCTAssertEqual(restoredReloads, 1, "the commit step's refresh is the one Tasks reload")
        XCTAssertNotNil(notes.note(withID: loose))
    }

    func testTaskRestoreThroughALibraryThatIsNotTheLifecyclesReloadsItsTasksOnce() async throws {
        let fixedDate = date
        let otherTasks = TaskStore(container: container, now: { fixedDate })
        let otherNotes = NoteStore(container: container, now: { fixedDate }, attachmentFileStore: makeTestAttachmentFileStore())
        otherLibrary = AtticLibrary(tasks: otherTasks, notes: otherNotes, canvases: CanvasStore(container: container))
        otherController = NotesPageController(store: otherNotes, journal: coordinator.journal)
        XCTAssertTrue(coordinator.lifecycleLibrary === otherLibrary)
        await otherNotes.waitForAttachmentReconciliation()
        XCTAssertTrue(library.deleteTasks([plain]).isApplied)
        var notesPublished = 0, otherReloads = 0
        let reloads = taskReloads {
            otherReloads = taskReloads(of: otherTasks) {
                notesPublished = revisionPublishes { XCTAssertTrue(library.restore(AtticItemRef(.task, plain))) }
            }
        }
        XCTAssertEqual(reloads, 1, "the restoring library's Tasks reload once: its own save")
        XCTAssertEqual(notesPublished, 1, "its Notes, which the commit step misses, refresh once")
        XCTAssertEqual(otherReloads, 1, "the commit step reloads the lifecycle's Tasks once")
        XCTAssertNotNil(tasks.task(withID: plain))
        XCTAssertNotNil(otherTasks.task(withID: plain))
        await otherNotes.waitForAttachmentReconciliation()
    }

    func testNoteRestoreThroughALibraryThatIsNotTheLifecyclesRefreshesItsNotesOnce() async throws {
        let fixedDate = date
        let otherTasks = TaskStore(container: container, now: { fixedDate })
        let otherNotes = NoteStore(container: container, now: { fixedDate }, attachmentFileStore: makeTestAttachmentFileStore())
        otherLibrary = AtticLibrary(tasks: otherTasks, notes: otherNotes, canvases: CanvasStore(container: container))
        otherController = NotesPageController(store: otherNotes, journal: coordinator.journal)
        XCTAssertTrue(coordinator.lifecycleLibrary === otherLibrary)
        await otherNotes.waitForAttachmentReconciliation()
        XCTAssertTrue(library.delete(AtticItemRef(.note, loose)))
        var published = 0
        let reloads = taskReloads {
            published = revisionPublishes { XCTAssertTrue(library.restore(AtticItemRef(.note, loose))) }
        }
        // The note store's own save publishes twice and, as the commit step
        // misses it, its own refresh once; the library adds no Notes refresh.
        XCTAssertEqual(published, 3, "the restoring library's Notes refresh once after the save")
        XCTAssertEqual(reloads, 1, "its Tasks, which the commit step misses, reload once")
        XCTAssertNotNil(notes.note(withID: loose))
        XCTAssertNotNil(otherNotes.note(withID: loose))
        await otherNotes.waitForAttachmentReconciliation()
    }

    func testANoteRestoreWhoseOwnReadFailedIsReadAgainByTheLibrary() async throws {
        let fixedDate = date
        let otherNotes = NoteStore(container: container, now: { fixedDate }, attachmentFileStore: makeTestAttachmentFileStore())
        otherLibrary = AtticLibrary(tasks: TaskStore(container: container, now: { fixedDate }), notes: otherNotes,
            canvases: CanvasStore(container: container))
        otherController = NotesPageController(store: otherNotes, journal: coordinator.journal)
        XCTAssertTrue(coordinator.lifecycleLibrary === otherLibrary)
        await otherNotes.waitForAttachmentReconciliation()
        XCTAssertTrue(library.delete(AtticItemRef(.note, loose)))
        // The restore's save reload and the store's own refresh both fail; the
        // library's refresh is then the read that brings the note back.
        notes.reloadFailures = 2
        XCTAssertTrue(library.restore(AtticItemRef(.note, loose)))
        XCTAssertEqual(notes.reloadFailures, 0, "both failing reads were reached")
        XCTAssertNotNil(notes.note(withID: loose), "the library read Notes again after the failed read")
        XCTAssertNil(notes.lastErrorMessage, "and that read succeeded")
        await otherNotes.waitForAttachmentReconciliation()
    }

    func testRestoringAPreGroupNoteStillReloadsTasks() throws {
        // A note deleted before deletion groups has no commit step on
        // restore, so the library's own refresh is still its Tasks reload.
        let context = ModelContext(container)
        let id = loose
        for row in try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })) {
            row.deletedAt = date
            row.deletionGroupID = nil
        }
        try context.save()
        XCTAssertTrue(notes.refresh())
        XCTAssertNil(notes.note(withID: loose))
        let reloads = taskReloads { XCTAssertTrue(library.restore(AtticItemRef(.note, loose))) }
        XCTAssertEqual(reloads, 1, "a pre-group note restore still reloads Tasks once")
        XCTAssertNotNil(notes.note(withID: loose))
    }

    func testRecentlyDeletedCanvasRestoreStillRefreshesTheOtherStores() throws {
        let board = try XCTUnwrap(canvases.createCanvas(name: "Board"))
        _ = try XCTUnwrap(canvases.createCanvas(name: "Spare"))
        XCTAssertTrue(library.delete(AtticItemRef(.canvas, board.id)))
        var notesPublished = 0
        let reloads = taskReloads {
            notesPublished = revisionPublishes { XCTAssertTrue(library.restore(AtticItemRef(.canvas, board.id))) }
        }
        XCTAssertEqual(reloads, 1, "a canvas restore still reloads Tasks once")
        XCTAssertEqual(notesPublished, 1, "a canvas restore still refreshes Notes once")
        XCTAssertTrue(canvases.canvases.contains { $0.id == board.id })
    }

    func testNoteDeletePublishesItsSaveAndItsCommitStepOnly() throws {
        let deleted = revisionPublishes { XCTAssertTrue(library.delete(AtticItemRef(.note, loose))) }
        // The note store's own save publishes twice (its reload, then the
        // saved-change record), and the commit step once: the library's
        // stores refresh reloads NoteStore, and the Notes controller, which
        // presents from that store, does not reload it again. The library
        // adds none.
        XCTAssertEqual(deleted, 3, "a note delete publishes for its own save and its commit step only")
        XCTAssertNil(notes.note(withID: loose))
    }

    // A grouped note restore refreshes NoteStore once, through its commit step
    // (`WorkspaceItemLifecycle.didCommit`), as a note delete does: it publishes
    // for its own save (twice) and the commit step (once). The store's own
    // refresh is kept only for a store that commit step does not reach.

    func testUndoOfANoteDeleteRefreshesNotesOnceThroughItsCommitStep() throws {
        XCTAssertTrue(library.delete(AtticItemRef(.note, loose)))
        XCTAssertTrue(try deletedInAGroup(loose), "the restore below takes the grouped branch")
        let undone = revisionPublishes { XCTAssertTrue(library.undo.undo(in: .note(loose))) }
        XCTAssertEqual(undone, 3, "Undo of a note delete publishes for its own save and its commit step only")
        XCTAssertNotNil(notes.note(withID: loose), "Undo brought the note back")
        XCTAssertNotNil(controller.store.note(withID: loose), "the Notes controller shows it")
    }

    func testToastRestoreOfADeletedNoteRefreshesNotesOnceThroughItsCommitStep() throws {
        XCTAssertTrue(library.delete(AtticItemRef(.note, loose)))
        XCTAssertTrue(try deletedInAGroup(loose))
        let restored = revisionPublishes { XCTAssertTrue(controller.restoreDeletedNote(noteID: loose, reopen: false)) }
        XCTAssertEqual(restored, 3, "the toast's Undo publishes for its own save and its commit step only")
        XCTAssertNotNil(notes.note(withID: loose))
    }

    func testRestoreThroughAStoreOnlyTheNotesControllerReachesRefreshesItOnce() async throws {
        // A second Notes controller takes the lifecycle's Notes role; the
        // library is still this one, so the commit step reaches `otherNotes`
        // only through the controller's whole-item publish.
        let fixedDate = date
        let otherNotes = NoteStore(container: container, now: { fixedDate }, attachmentFileStore: makeTestAttachmentFileStore())
        otherController = NotesPageController(store: otherNotes, journal: coordinator.journal)
        XCTAssertTrue(coordinator.lifecycleLibrary === library)
        XCTAssertTrue(coordinator.lifecycleNotes === otherController)
        await otherNotes.waitForAttachmentReconciliation()
        XCTAssertTrue(otherNotes.delete(try XCTUnwrap(otherNotes.note(withID: loose))))
        XCTAssertTrue(try deletedInAGroup(loose))
        let restored = revisionPublishes(of: otherNotes) {
            XCTAssertNotNil(otherNotes.restoreDeletedNote(noteID: loose)?.group, "a grouped restore")
        }
        XCTAssertEqual(restored, 3, "the controller's publish is the restore's one refresh")
        XCTAssertNotNil(otherNotes.note(withID: loose))
        await otherNotes.waitForAttachmentReconciliation()
    }

    func testRestoreThroughAStoreTheCommitStepDoesNotReachStillRefreshesItself() async throws {
        // Another library and Notes controller take both lifecycle roles, so
        // the commit step never reads `notes`: its own refresh stays.
        let fixedDate = date
        let otherNotes = NoteStore(container: container, now: { fixedDate }, attachmentFileStore: makeTestAttachmentFileStore())
        otherLibrary = AtticLibrary(tasks: TaskStore(container: container, now: { fixedDate }), notes: otherNotes,
            canvases: CanvasStore(container: container))
        otherController = NotesPageController(store: otherNotes, journal: coordinator.journal)
        XCTAssertTrue(coordinator.lifecycleLibrary === otherLibrary)
        XCTAssertTrue(coordinator.lifecycleNotes === otherController)
        await otherNotes.waitForAttachmentReconciliation()
        XCTAssertTrue(notes.delete(try XCTUnwrap(notes.note(withID: loose))))
        XCTAssertTrue(try deletedInAGroup(loose))
        var reachedOther = 0
        let restored = revisionPublishes {
            reachedOther = revisionPublishes(of: otherNotes) {
                XCTAssertNotNil(notes.restoreDeletedNote(noteID: loose)?.group, "a grouped restore")
            }
        }
        XCTAssertEqual(restored, 3, "a store the commit step misses publishes for its save and its own refresh")
        XCTAssertEqual(reachedOther, 1, "the commit step refreshes the lifecycle's store once")
        XCTAssertNotNil(notes.note(withID: loose), "the restoring store lists the note again")
        XCTAssertNotNil(otherNotes.note(withID: loose))
        await otherNotes.waitForAttachmentReconciliation()
    }

    func testDeletingATaskOwnedNoteTakesTheTaskOutOfTasks() throws {
        XCTAssertNotNil(tasks.task(withID: owner))
        XCTAssertTrue(library.delete(AtticItemRef(.note, writing)))
        // The commit step's refresh is the only one now, and Tasks must still
        // drop the task the writing belonged to.
        XCTAssertNil(tasks.task(withID: owner), "the task left Tasks with its writing")
        XCTAssertNil(notes.note(withID: writing))
        XCTAssertTrue(try rowDeleted(owner))
        XCTAssertTrue(library.undo.undo(in: .note(writing)))
        XCTAssertNotNil(tasks.task(withID: owner), "Undo brought the task back to Tasks")
        XCTAssertNotNil(notes.note(withID: writing))
    }

    func testALibraryThatIsNotTheLifecyclesStillRefreshesItsOwnStores() async throws {
        // A second library and Notes controller on the same container take
        // the lifecycle's roles, so the commit step refreshes their stores,
        // not the first library's.
        let fixedDate = date
        let otherTasks = TaskStore(container: container, now: { fixedDate })
        let otherNotes = NoteStore(container: container, now: { fixedDate }, attachmentFileStore: makeTestAttachmentFileStore())
        otherLibrary = AtticLibrary(tasks: otherTasks, notes: otherNotes, canvases: CanvasStore(container: container))
        otherController = NotesPageController(store: otherNotes, journal: coordinator.journal)
        XCTAssertTrue(coordinator.lifecycleLibrary === otherLibrary)
        XCTAssertTrue(coordinator.lifecycleNotes === otherController)
        await otherNotes.waitForAttachmentReconciliation()
        var reachedOther = 0
        let deleted = revisionPublishes {
            reachedOther = revisionPublishes(of: otherNotes) { XCTAssertTrue(library.deleteTasks([plain]).isApplied) }
        }
        // Once: the lifecycle library's stores refresh reloads `otherNotes`;
        // `otherController` presents from that same store and does not
        // reload it again.
        XCTAssertEqual(reachedOther, 1, "the commit step refreshes the lifecycle's stores")
        XCTAssertEqual(deleted, 1, "the deleting library still refreshes its own stores once")
        XCTAssertNil(tasks.task(withID: plain), "the deleting library's Tasks dropped the task")
        await otherNotes.waitForAttachmentReconciliation()
    }

    // A delete through a library that isn't the lifecycle's: the commit step
    // reads the other library's stores, so this library refreshes its own,
    // but never reads Tasks again after a task store's save that already
    // read them fresh.

    /// A second library and Notes controller take both lifecycle roles, so the
    /// commit step reads their stores, not `library`'s.
    private func handLifecycleToAnotherLibrary() async throws -> (tasks: TaskStore, notes: NoteStore) {
        let fixedDate = date
        let otherTasks = TaskStore(container: container, now: { fixedDate })
        let otherNotes = NoteStore(container: container, now: { fixedDate }, attachmentFileStore: makeTestAttachmentFileStore())
        otherLibrary = AtticLibrary(tasks: otherTasks, notes: otherNotes, canvases: CanvasStore(container: container))
        otherController = NotesPageController(store: otherNotes, journal: coordinator.journal)
        XCTAssertTrue(coordinator.lifecycleLibrary === otherLibrary)
        XCTAssertTrue(coordinator.lifecycleNotes === otherController)
        await otherNotes.waitForAttachmentReconciliation()
        return (otherTasks, otherNotes)
    }

    func testTaskDeleteThroughALibraryThatIsNotTheLifecyclesReloadsItsTasksOnce() async throws {
        let other = try await handLifecycleToAnotherLibrary()
        var notesPublished = 0, otherReloads = 0
        let reloads = taskReloads {
            otherReloads = taskReloads(of: other.tasks) {
                notesPublished = revisionPublishes { XCTAssertTrue(library.delete(AtticItemRef(.task, plain))) }
            }
        }
        XCTAssertEqual(reloads, 1, "the deleting library's Tasks reload once: its own save")
        XCTAssertEqual(notesPublished, 1, "its Notes, which the commit step misses, refresh once")
        XCTAssertEqual(otherReloads, 1, "the commit step reloads the lifecycle's Tasks once")
        XCTAssertNil(tasks.task(withID: plain), "the deleting library's Tasks dropped the task")
        XCTAssertNil(other.tasks.task(withID: plain))
        XCTAssertTrue(try rowDeleted(plain))
        await other.notes.waitForAttachmentReconciliation()
    }

    func testANoteDeleteAfterATaskDeleteThroughThatLibraryStillReloadsTasks() async throws {
        // The task store's last save read fresh, but a note delete does not
        // save through it: deleting a task's writing takes the task out of
        // Tasks, which only the library's refresh shows here.
        let other = try await handLifecycleToAnotherLibrary()
        XCTAssertTrue(library.delete(AtticItemRef(.task, plain)))
        XCTAssertNotNil(tasks.task(withID: owner))
        let reloads = taskReloads { XCTAssertTrue(library.delete(AtticItemRef(.note, writing))) }
        XCTAssertEqual(reloads, 1, "a note delete still reloads the library's Tasks once")
        XCTAssertNil(tasks.task(withID: owner), "the task left Tasks with its writing")
        XCTAssertNil(notes.note(withID: writing))
        XCTAssertTrue(try rowDeleted(owner))
        XCTAssertTrue(library.undo.undo(in: .note(writing)))
        XCTAssertNotNil(tasks.task(withID: owner), "Undo brought the task back to Tasks")
        await other.notes.waitForAttachmentReconciliation()
    }

    func testATaskDeleteThroughThatLibraryStillTakesItsWritingOutOfNotes() async throws {
        let other = try await handLifecycleToAnotherLibrary()
        XCTAssertNotNil(notes.note(withID: writing))
        let published = revisionPublishes { XCTAssertTrue(library.delete(AtticItemRef(.task, owner))) }
        XCTAssertEqual(published, 1, "the deleting library's Notes refresh once")
        XCTAssertNil(notes.note(withID: writing), "the task's writing left Notes with it")
        XCTAssertNil(other.notes.note(withID: writing))
        XCTAssertTrue(try rowDeleted(writing))
        await other.notes.waitForAttachmentReconciliation()
    }

    func testACanvasDeleteAfterATaskDeleteThroughThatLibraryStillRefreshesTheOtherStores() async throws {
        let other = try await handLifecycleToAnotherLibrary()
        let board = try XCTUnwrap(canvases.createCanvas(name: "Board"))
        _ = try XCTUnwrap(canvases.createCanvas(name: "Spare"))
        XCTAssertTrue(library.delete(AtticItemRef(.task, plain)))
        var published = 0
        let reloads = taskReloads {
            published = revisionPublishes { XCTAssertTrue(library.delete(AtticItemRef(.canvas, board.id))) }
        }
        XCTAssertEqual(reloads, 1, "a canvas delete still reloads Tasks once")
        XCTAssertEqual(published, 1, "a canvas delete still refreshes Notes once")
        XCTAssertFalse(canvases.canvases.contains { $0.id == board.id })
        await other.notes.waitForAttachmentReconciliation()
    }

    func testATaskDeleteWhoseOwnReadFailedIsReadAgainByThatLibrary() async throws {
        let other = try await handLifecycleToAnotherLibrary()
        // The save's fresh read and its fallback refresh both fail; the
        // library's refresh is then the read that confirms the list.
        tasks.listRefreshFailures = 2
        XCTAssertTrue(library.delete(AtticItemRef(.task, plain)), "the delete is durable")
        XCTAssertEqual(tasks.listRefreshFailures, 0, "both failing reads were reached")
        XCTAssertFalse(tasks.hasUnresolvedTaskReload, "the library read Tasks again after the failed read")
        XCTAssertNil(tasks.errorNotice, "and that read succeeded")
        XCTAssertNil(tasks.task(withID: plain))
        XCTAssertTrue(try rowDeleted(plain))
        await other.notes.waitForAttachmentReconciliation()
    }

    func testANoteDeleteThroughThatLibraryReadsItsNotesAsBefore() async throws {
        // Pinned as it is: the store's save reads Notes fresh and the
        // library's refresh reads them again. NoteStore has no record that
        // its save read (a plain commit does not), so that double is left for
        // the board, not skipped here.
        let other = try await handLifecycleToAnotherLibrary()
        notes.resetFullNoteReloadCount()
        let published = revisionPublishes { XCTAssertTrue(library.delete(AtticItemRef(.note, loose))) }
        XCTAssertEqual(published, 3, "the save publishes twice and the library's refresh once")
        XCTAssertEqual(notes.fullNoteReloadCount, 2, "the save's read and the library's")
        XCTAssertNil(notes.note(withID: loose))
        XCTAssertNil(other.notes.note(withID: loose))
        await other.notes.waitForAttachmentReconciliation()
    }

    func testCanvasDeleteStillRefreshesTheOtherStores() throws {
        let board = try XCTUnwrap(canvases.createCanvas(name: "Board"))
        _ = try XCTUnwrap(canvases.createCanvas(name: "Spare"))
        // TaskStore's whole reload (what `refresh()` runs) publishes `revision`
        // with no changed task IDs; an incremental task commit names its IDs.
        var taskReloads = 0
        let store: TaskStore = tasks
        store.$revision.dropFirst().sink { _ in
            if store.revisionChangedTaskIDs == nil { taskReloads += 1 }
        }.store(in: &bag)
        let deleted = revisionPublishes { XCTAssertTrue(library.delete(AtticItemRef(.canvas, board.id))) }
        // A canvas store has no commit step of its own: the library's
        // refresh is the only one that reaches Tasks and Notes.
        XCTAssertEqual(deleted, 1, "a canvas delete still refreshes Notes once")
        XCTAssertEqual(taskReloads, 1, "a canvas delete still reloads Tasks once")
        XCTAssertFalse(canvases.canvases.contains { $0.id == board.id })
    }

    private func deletedInAGroup(_ id: UUID) throws -> Bool {
        let rows = try ModelContext(container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
        return !rows.isEmpty && rows.allSatisfy { $0.deletedAt != nil && $0.deletionGroupID != nil }
    }

    private func rowDeleted(_ id: UUID) throws -> Bool {
        let context = ModelContext(container)
        let taskRows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        let noteRows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
        let rows: [Date?] = taskRows.map(\.deletedAt) + noteRows.map(\.deletedAt)
        return !rows.isEmpty && rows.allSatisfy { $0 != nil }
    }
}
