import Combine
import Foundation
import SwiftData
import XCTest
@testable import Attic

/// A restore from Recently Deleted refreshes the stores once, as the Undo of a
/// delete does: a task's store, and a note's store when it restores a deletion
/// group, end the restore with the lifecycle's commit step
/// (`WorkspaceItemLifecycle.didCommit`), which refreshes the lifecycle's
/// library. The library adds its own refresh only where that step does not
/// run: a canvas, or a pre-group note restore, which reloads only its own
/// store. Counted as NoteStore sends (`objectWillChange`, one per published
/// property) and `revision` publishes, and as TaskStore whole reloads.
/// Every count is of synchronous sends while the command runs.
@MainActor
final class LibraryRestoreRefreshTests: XCTestCase {
    private var container: ModelContainer!
    private var coordinator: WorkspaceOperationCoordinator!
    private var tasks: TaskStore!
    private var notes: NoteStore!
    private var canvases: CanvasStore!
    private var library: AtticLibrary!
    private var controller: NotesPageController!
    private var bag = Set<AnyCancellable>()
    private var taskReloads = 0
    private let plain = UUID(), owner = UUID(), writing = UUID(), loose = UUID(), legacy = UUID()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private static let tag = "restorecount"

    override func setUp() async throws {
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        let context = ModelContext(container)
        context.insert(TaskItem(id: plain, title: "No writing", createdAt: date, manualOrder: 1))
        let tagged = TaskItem(id: owner, title: "With writing", createdAt: date, manualOrder: 2)
        tagged.tags = [Self.tag]
        context.insert(tagged)
        let document = try NoteContentCodec.encode(NoteDocument(blocks: [.text("With writing"), .text("Writing")], requires: ["taskNote"]))
        let owned = NoteItem(id: writing, title: "With writing", body: "Writing", createdAt: date)
        owned.taskID = owner
        owned.content = document
        context.insert(owned)
        context.insert(NoteItem(id: loose, title: "Loose note", body: "Body", createdAt: date))
        // Deleted before deletion groups existed: no group, so its restore is
        // the pre-group path, which has no commit step.
        let old = NoteItem(id: legacy, title: "Old note", body: "Old", createdAt: date)
        old.deletedAt = date
        context.insert(old)
        try context.save()
        let fixedDate = date
        tasks = TaskStore(container: container, now: { fixedDate })
        notes = NoteStore(container: container, now: { fixedDate }, attachmentFileStore: makeTestAttachmentFileStore())
        canvases = CanvasStore(container: container)
        library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        controller = NotesPageController(store: notes, journal: coordinator.journal)
        await notes.waitForAttachmentReconciliation()
        // TaskStore's whole reload (what `refresh()` runs) publishes `revision`
        // with no changed task IDs; an incremental task commit names its IDs.
        let store: TaskStore = tasks
        store.$revision.dropFirst().sink { [weak self] _ in
            if store.revisionChangedTaskIDs == nil { self?.taskReloads += 1 }
        }.store(in: &bag)
        XCTAssertTrue(coordinator.lifecycleLibrary === library)
        XCTAssertTrue(coordinator.lifecycleNotes === controller)
    }

    override func tearDown() async throws {
        bag.removeAll()
        await coordinator.lifecycleNotes?.waitForRecoveryWork()
        await notes.waitForAttachmentReconciliation()
        controller = nil; library = nil; canvases = nil; tasks = nil; notes = nil; coordinator = nil; container = nil
    }

    private struct Counts: Equatable, CustomStringConvertible {
        var sends = 0, revisions = 0, taskReloads = 0
        var description: String { "sends=\(sends) revisions=\(revisions) taskReloads=\(taskReloads)" }
    }

    private func counts(_ body: () -> Void) -> Counts {
        var counts = Counts()
        let reloadsBefore = taskReloads
        let sends = notes.objectWillChange.sink { _ in counts.sends += 1 }
        let revisions = notes.$revision.dropFirst().sink { _ in counts.revisions += 1 }
        body()
        sends.cancel(); revisions.cancel()
        counts.taskReloads = taskReloads - reloadsBefore
        return counts
    }

    func testTaskRestoreRefreshesAsTheUndoOfItsDeleteDoes() throws {
        let deleted = counts { XCTAssertTrue(library.deleteTasks([plain]).isApplied) }
        let undone = counts { XCTAssertTrue(library.undo.undo(in: .tasks)) }
        XCTAssertNotNil(tasks.task(withID: plain), "Undo brought the task back")
        XCTAssertTrue(library.deleteTasks([plain]).isApplied)
        let restored = counts { XCTAssertTrue(library.restore(AtticItemRef(.task, plain))) }
        print("restore-refresh-count delete=\(deleted) undo=\(undone) restore=\(restored)")
        XCTAssertEqual(deleted.revisions, 1, "a task delete refreshes NoteStore once, through its commit step")
        XCTAssertEqual(undone.revisions, 1, "Undo of the delete refreshes NoteStore once")
        XCTAssertEqual(deleted.sends, undone.sends, "a delete and its Undo send the same")
        XCTAssertEqual(restored.revisions, 1, "a task restore refreshes NoteStore once, through its commit step")
        XCTAssertEqual(restored, undone, "a restore from Recently Deleted refreshes as the Undo of a delete does")
        XCTAssertNotNil(tasks.task(withID: plain), "the restore brought the task back")
    }

    func testTaskRestoreShowsTheTaskItsWritingAndItsTag() throws {
        let shown = controller.store
        XCTAssertTrue(shown === notes, "the Notes controller presents from the library's note store")
        XCTAssertTrue(library.deleteTasks([owner]).isApplied)
        XCTAssertNil(shown.note(withID: writing), "the writing left Notes with its task")
        XCTAssertFalse(library.tags.names.contains(Self.tag), "the tag left the inventory with its only task")
        let restored = counts { XCTAssertTrue(library.restore(AtticItemRef(.task, owner))) }
        XCTAssertEqual(restored.revisions, 1, "a task restore refreshes NoteStore once")
        XCTAssertEqual(restored.taskReloads, 1, "a task restore reloads Tasks once, in its own save")
        XCTAssertNotNil(tasks.task(withID: owner), "the task is back in Tasks")
        XCTAssertNotNil(shown.note(withID: writing), "the writing is back in the Notes controller's own view")
        XCTAssertTrue(shown.notes.contains { $0.id == writing })
        XCTAssertTrue(library.tags.names.contains(Self.tag), "the tag is back in the inventory")
    }

    func testGroupedNoteRestoreReloadsTasksOnlyThroughItsCommitStep() throws {
        XCTAssertTrue(library.delete(AtticItemRef(.note, loose)))
        XCTAssertNil(notes.note(withID: loose))
        let restored = counts { XCTAssertTrue(library.restore(AtticItemRef(.note, loose))) }
        print("restore-refresh-count grouped-note=\(restored)")
        // The note's commit step reaches Tasks once; nothing else does.
        XCTAssertEqual(restored.taskReloads, 1, "a grouped note restore reloads Tasks once, through its commit step")
        XCTAssertNotNil(notes.note(withID: loose), "the note is back")
        XCTAssertNotNil(controller.store.note(withID: loose))
    }

    func testPreGroupNoteRestoreStillRefreshesTheOtherStores() throws {
        XCTAssertNil(notes.note(withID: legacy))
        let restored = counts { XCTAssertTrue(library.restore(AtticItemRef(.note, legacy))) }
        print("restore-refresh-count pre-group-note=\(restored)")
        // The pre-group path saves and reloads only the note store: the
        // library's refresh is the only one that reaches Tasks.
        XCTAssertEqual(restored.taskReloads, 1, "a pre-group note restore still reloads Tasks once")
        XCTAssertNotNil(notes.note(withID: legacy), "the note is back")
    }

    func testCanvasRestoreStillRefreshesTheOtherStores() throws {
        let board = try XCTUnwrap(canvases.createCanvas(name: "Board"))
        _ = try XCTUnwrap(canvases.createCanvas(name: "Spare"))
        XCTAssertTrue(library.delete(AtticItemRef(.canvas, board.id)))
        let restored = counts { XCTAssertTrue(library.restore(AtticItemRef(.canvas, board.id))) }
        print("restore-refresh-count canvas=\(restored)")
        // A canvas store has no commit step of its own: the library's refresh
        // is the only one that reaches Tasks and Notes.
        XCTAssertEqual(restored.revisions, 1, "a canvas restore still refreshes Notes once")
        XCTAssertEqual(restored.taskReloads, 1, "a canvas restore still reloads Tasks once")
        XCTAssertTrue(canvases.canvases.contains { $0.id == board.id })
    }
}
