import Combine
import Foundation
import SwiftData
import XCTest
@testable import Attic

/// A delete refreshes the stores once, through the lifecycle's commit step
/// (`WorkspaceItemLifecycle.didCommit`), and the library adds its own refresh
/// only where that step does not run (a canvas). Counted as whole NoteStore
/// refreshes: each refresh publishes a new `revision` once.
@MainActor
final class LibraryDeleteRefreshTests: XCTestCase {
    private var container: ModelContainer!
    private var coordinator: WorkspaceOperationCoordinator!
    private var tasks: TaskStore!
    private var notes: NoteStore!
    private var canvases: CanvasStore!
    private var library: AtticLibrary!
    private var controller: NotesPageController!
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
        controller = nil; library = nil; canvases = nil; tasks = nil; notes = nil; coordinator = nil; container = nil
    }

    /// Whole NoteStore refreshes while `body` runs.
    private func noteRefreshes(_ body: () -> Void) -> Int {
        var count = 0
        let watch = notes.$revision.dropFirst().sink { _ in count += 1 }
        body()
        watch.cancel()
        return count
    }

    func testTaskDeleteRefreshesNotesOnceThroughTheLifecycle() throws {
        XCTAssertTrue(coordinator.lifecycleLibrary === library)
        XCTAssertTrue(coordinator.lifecycleNotes === controller)
        let deleted = noteRefreshes { XCTAssertTrue(library.deleteTasks([plain]).isApplied) }
        // The commit step refreshes twice (the library's stores, then the
        // Notes controller's whole-item publish); the library adds none.
        XCTAssertEqual(deleted, 2, "a task delete refreshes NoteStore only through its commit step")
        XCTAssertTrue(try rowDeleted(plain), "the task is in Recently Deleted")
        let undone = noteRefreshes { XCTAssertTrue(library.undo.undo(in: .tasks)) }
        XCTAssertEqual(undone, 2, "Undo of the delete refreshes as the delete does")
        XCTAssertNotNil(tasks.task(withID: plain), "Undo brought the task back")
    }

    func testDeletingATaskThatOwnsWritingStillUpdatesNotes() throws {
        XCTAssertNotNil(notes.note(withID: writing))
        let deleted = noteRefreshes { XCTAssertTrue(library.deleteTasks([owner]).isApplied) }
        XCTAssertEqual(deleted, 2)
        XCTAssertNil(notes.note(withID: writing), "the task's writing left Notes with it")
        XCTAssertTrue(try rowDeleted(writing))
        _ = noteRefreshes { XCTAssertTrue(library.undo.undo(in: .tasks)) }
        XCTAssertNotNil(notes.note(withID: writing), "Undo brought the writing back to Notes")
    }

    func testNoteDeleteRefreshesNotesOnceThroughTheLifecycle() throws {
        let deleted = noteRefreshes { XCTAssertTrue(library.delete(AtticItemRef(.note, loose))) }
        XCTAssertEqual(deleted, 2, "a note delete refreshes NoteStore only through its commit step")
        XCTAssertNil(notes.note(withID: loose))
    }

    func testCanvasDeleteStillRefreshesTheOtherStores() throws {
        let board = try XCTUnwrap(canvases.createCanvas(name: "Board"))
        _ = try XCTUnwrap(canvases.createCanvas(name: "Spare"))
        var taskRefreshes = 0
        tasks.objectWillChange.sink { taskRefreshes += 1 }.store(in: &bag)
        let deleted = noteRefreshes { XCTAssertTrue(library.delete(AtticItemRef(.canvas, board.id))) }
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
