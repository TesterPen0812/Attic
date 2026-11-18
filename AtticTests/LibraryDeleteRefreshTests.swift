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
        // The commit step refreshes twice (the library's stores, then the
        // Notes controller's whole-item publish); the library adds none.
        XCTAssertEqual(deleted, 2, "a task delete refreshes NoteStore only through its commit step")
        XCTAssertTrue(try rowDeleted(plain), "the task is in Recently Deleted")
        let undone = revisionPublishes { XCTAssertTrue(library.undo.undo(in: .tasks)) }
        XCTAssertEqual(undone, 2, "Undo of the delete refreshes as the delete does")
        XCTAssertNotNil(tasks.task(withID: plain), "Undo brought the task back")
    }

    func testDeletingATaskThatOwnsWritingStillUpdatesNotes() throws {
        XCTAssertNotNil(notes.note(withID: writing))
        let deleted = revisionPublishes { XCTAssertTrue(library.deleteTasks([owner]).isApplied) }
        XCTAssertEqual(deleted, 2)
        XCTAssertNil(notes.note(withID: writing), "the task's writing left Notes with it")
        XCTAssertTrue(try rowDeleted(writing))
        _ = revisionPublishes { XCTAssertTrue(library.undo.undo(in: .tasks)) }
        XCTAssertNotNil(notes.note(withID: writing), "Undo brought the writing back to Notes")
    }

    func testNoteDeletePublishesItsSaveAndItsCommitStepOnly() throws {
        let deleted = revisionPublishes { XCTAssertTrue(library.delete(AtticItemRef(.note, loose))) }
        // The note store's own save publishes twice (its reload, then the
        // saved-change record), and the commit step refreshes twice (the
        // library's stores, then the Notes controller); the library adds none.
        XCTAssertEqual(deleted, 4, "a note delete publishes for its own save and its commit step only")
        XCTAssertNil(notes.note(withID: loose))
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
        XCTAssertEqual(reachedOther, 2, "the commit step refreshes the lifecycle's stores")
        XCTAssertEqual(deleted, 1, "the deleting library still refreshes its own stores once")
        XCTAssertNil(tasks.task(withID: plain), "the deleting library's Tasks dropped the task")
        await otherNotes.waitForAttachmentReconciliation()
    }

    func testCanvasDeleteStillRefreshesTheOtherStores() throws {
        let board = try XCTUnwrap(canvases.createCanvas(name: "Board"))
        _ = try XCTUnwrap(canvases.createCanvas(name: "Spare"))
        var taskRefreshes = 0
        tasks.objectWillChange.sink { taskRefreshes += 1 }.store(in: &bag)
        let deleted = revisionPublishes { XCTAssertTrue(library.delete(AtticItemRef(.canvas, board.id))) }
        // A canvas store has no commit step of its own: the library's
        // refresh is the only one that reaches Tasks and Notes.
        XCTAssertEqual(deleted, 1, "a canvas delete still refreshes Notes once")
        XCTAssertGreaterThan(taskRefreshes, 0, "a canvas delete still refreshes Tasks")
        XCTAssertFalse(canvases.canvases.contains { $0.id == board.id })
    }

    private func rowDeleted(_ id: UUID) throws -> Bool {
        let context = ModelContext(container)
        let taskRows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        let noteRows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
        let rows: [Date?] = taskRows.map(\.deletedAt) + noteRows.map(\.deletedAt)
        return !rows.isEmpty && rows.allSatisfy { $0 != nil }
    }
}
