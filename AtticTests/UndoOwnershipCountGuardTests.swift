import SwiftData
import XCTest
@testable import Attic

/// Red-first count guard for create's Undo ownership read (18 Nov 2026,
/// `reports/perf-audit/tasks-actions.astra.md` TA-03): a plain create must
/// read the same number of records for its Undo step in a larger library.
/// It prints a `GUARD_` line with its count.
@MainActor
final class UndoOwnershipCountGuardTests: XCTestCase {
    /// Astra TA-03. A plain create (no writing, tags or files) through the
    /// card's path reads the same number of records for its Undo step in a
    /// library ten times larger, with ten times the unrelated tasks and notes.
    func testGuardCreateReadsNoMoreRecordsInALargerLibrary() throws {
        var bySize: [Int: Int] = [:]
        for size in [100, 1_000] {
            let store = try makeStore(open: size, notes: size / 2)
            let library = AtticLibrary(tasks: store)
            var services = TasksPageServices()
            services.acknowledgementDelay = .seconds(25)
            let model = TasksPageModel(library: library, services: services)
            _ = model.rows(for: .now)
            let draft = TaskDraft(title: "Plain new task")
            let before = library.ownershipRecordsRead
            var created: TaskItem?
            _ = model.createAcknowledged(draft, save: { library.createTask(draft, writing: "", in: .tasks, id: $0) },
                                         settled: { created = $0 })
            model.settlePendingCompletionAcknowledgements()
            XCTAssertNotNil(created, "the create saved")
            let read = library.ownershipRecordsRead - before
            print("GUARD_CREATE tasks=\(size) notes=\(size / 2) ownership_records_read=\(read)")
            bySize[size] = read
        }
        XCTAssertEqual(bySize[100], bySize[1_000], "TA-03: a plain create's Undo ownership read grew with the library")
    }

    /// TA-03's equivalence: on a store with duplicate replicas, deleted notes,
    /// notes owned by other tasks and notes owned by none, the read by owner
    /// id returns exactly what the old whole-table filter returned, for
    /// every member set.
    func testOwnerIDReadMatchesTheWholeTableFilter() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let a = TaskItem(title: "A"), b = TaskItem(title: "B"), c = TaskItem(title: "C")
        for task in [a, b, c] { context.insert(task) }
        func note(_ title: String, owner: UUID?, deleted: Bool = false, id: UUID = UUID()) -> UUID {
            let item = NoteItem(id: id, title: title)
            item.taskID = owner
            if deleted { item.deletedAt = Date() }
            context.insert(item)
            return id
        }
        _ = note("A's live", owner: a.id)
        _ = note("A's deleted", owner: a.id, deleted: true)
        _ = note("B's live", owner: b.id)
        _ = note("No owner", owner: nil)
        // One note, two replicas: live and deleted, both A's.
        let twin = note("Twin live", owner: a.id)
        _ = note("Twin deleted", owner: a.id, deleted: true, id: twin)
        // One note, two replicas that disagree on the owner: A's deleted, C's live.
        let split = note("Split, A deleted", owner: a.id, deleted: true)
        _ = note("Split, C live", owner: c.id, id: split)
        try context.save()
        let library = AtticLibrary(tasks: TaskStore(container: container))
        let unknown = UUID()
        let sets: [Set<UUID>] = [[], [a.id], [b.id], [c.id], [a.id, b.id], [a.id, c.id], [a.id, b.id, c.id], [unknown], [unknown, c.id]]
        for members in sets {
            let read = library.liveWriting(ownedBy: members, in: ModelContext(container))
            let reference = library.wholeTableLiveWriting(ownedBy: members)
            XCTAssertNotNil(read)
            XCTAssertEqual(read, reference, "members \(members.count): the read by owner id differs from the whole-table filter")
            XCTAssertEqual(library.itemOwnership(members, deleted: false).writing, reference)
        }
        XCTAssertEqual(library.wholeTableLiveWriting(ownedBy: [a.id])?.count, 2, "the seed holds what it claims: A's live note and the twin")
        XCTAssertEqual(library.wholeTableLiveWriting(ownedBy: [c.id]), [split])
    }

    /// TA-03: a failed read still records nil (Undo then skips the writing
    /// check, as before); the next read records the writing again.
    func testFailedOwnerIDReadRecordsNil() throws {
        let store = try makeStore(open: 3, notes: 2)
        let library = AtticLibrary(tasks: store)
        let id = try XCTUnwrap(store.tasks.first?.id)
        library.ownershipReadFailures = 1
        XCTAssertNil(library.itemOwnership([id], deleted: false).writing, "a failed read records nil")
        XCTAssertEqual(library.itemOwnership([id], deleted: false).writing, [], "the next read records the writing")
    }

    /// TA-03, behaviour kept: Undo of an add still stops as obsolete when a
    /// note was attached to the new task after it was made, and leaves the
    /// task and its note; without the note, Undo takes the task back.
    func testUndoOfAnAddStopsWhenANoteWasAttachedLater() throws {
        for attach in [false, true] {
            let store = try makeStore(open: 3, notes: 5)
            let library = AtticLibrary(tasks: store)
            let id = try XCTUnwrap(library.createTasks([TaskDraft(title: "New task")])?.first?.id)
            let noteID = UUID()
            if attach {
                let context = ModelContext(store.container)
                let note = NoteItem(id: noteID, title: "Written later")
                note.taskID = id
                context.insert(note)
                try context.save()
            }
            let outcome = library.undo(in: .tasks)
            let context = ModelContext(store.container)
            let task = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first
            if attach {
                XCTAssertFalse(outcome.isApplied, "Undo of the add must not take a note it did not make")
                XCTAssertNotNil(task, "the task stays")
                XCTAssertNil(task?.deletedAt, "the task stays live")
                let note = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })).first
                XCTAssertNil(note?.deletedAt, "the note stays live")
            } else {
                XCTAssertTrue(outcome.isApplied, "Undo takes the new task back")
                XCTAssertTrue(task == nil || task?.deletedAt != nil, "the task left the list")
            }
        }
    }

    // MARK: - Rig

    /// Open tasks on Now, tasks in Later, finished tasks in the Done log
    /// (finished before today) and unrelated notes.
    private func makeStore(open: Int, later: Int = 0, logged: Int = 0, notes: Int = 0, tagged: Bool = false) throws -> TaskStore {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        var order: Int64 = 10_000_000
        func insert(_ title: String, _ status: TaskStatus, completed: Date? = nil, tags: [String] = []) {
            order -= 1_024
            let item = TaskItem(title: title, status: status, createdAt: now, completedAt: completed, manualOrder: order)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if let completed { item.doneLoggedAt = completed }
            if !tags.isEmpty { item.tags = tags }
            context.insert(item)
        }
        for index in 0..<open { insert("Open task \(index)", .todo, tags: tagged ? ["open\(index % 5)"] : []) }
        for index in 0..<later { insert("Later task \(index)", .backlog) }
        for index in 0..<logged {
            insert("Finished task \(index)", .done, completed: now.addingTimeInterval(-86_400 - Double(index + 1) * 3_600),
                   tags: tagged ? ["done\(index % 7)"] : [])
        }
        for index in 0..<notes { context.insert(NoteItem(title: "Note \(index)", body: "Unrelated note \(index)")) }
        try context.save()
        return TaskStore(container: container)
    }
}
