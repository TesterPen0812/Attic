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
    /// card's path captures its Undo ownership with the same note fetches in
    /// a library ten times larger, with ten times the unrelated tasks and
    /// notes. Counted at the capture's fetch boundary (review R-3): the
    /// capture succeeds with no writing and returns no note rows at either
    /// size; an owned note is found and is the only row returned.
    func testGuardCreateReadsNoMoreRecordsInALargerLibrary() throws {
        var fetchesBySize: [Int: Int] = [:]
        for size in [100, 1_000] {
            let store = try makeStore(open: size, notes: size / 2)
            let library = AtticLibrary(tasks: store)
            var services = TasksPageServices()
            services.acknowledgementDelay = .seconds(25)
            let model = TasksPageModel(library: library, services: services)
            _ = model.rows(for: .now)
            let draft = TaskDraft(title: "Plain new task")
            let (fetches, rows) = (library.ownershipFetches, library.ownershipNoteRows)
            var created: TaskItem?
            _ = model.createAcknowledged(draft, save: { library.createTask(draft, writing: "", in: .tasks, id: $0) },
                                         settled: { created = $0 })
            model.settlePendingCompletionAcknowledgements()
            let id = try XCTUnwrap(created?.id, "the create saved")
            let fetched = library.ownershipFetches - fetches, returned = library.ownershipNoteRows - rows
            print("GUARD_CREATE tasks=\(size) notes=\(size / 2) ownership_fetches=\(fetched) ownership_note_rows=\(returned)")
            XCTAssertEqual(library.lastCapturedWriting, [], "tasks=\(size): the capture succeeded and found no writing")
            XCTAssertGreaterThan(fetched, 0, "tasks=\(size): the capture read the notes")
            XCTAssertEqual(returned, 0, "tasks=\(size): a plain create's capture returned note rows")
            fetchesBySize[size] = fetched

            // Positive control: a note owned by the task is found, and is the
            // one row the capture returns.
            let noteID = try attachNote(to: id, in: store)
            let (controlFetches, controlRows) = (library.ownershipFetches, library.ownershipNoteRows)
            XCTAssertEqual(library.itemOwnership([id], deleted: false).writing, [noteID], "tasks=\(size): the owned note is captured")
            XCTAssertEqual(library.ownershipNoteRows - controlRows, 1, "tasks=\(size): only the owned note is returned")
            XCTAssertEqual(library.ownershipFetches - controlFetches, fetched, "tasks=\(size): the control reads as the create did")
        }
        XCTAssertEqual(fetchesBySize[100], fetchesBySize[1_000], "TA-03: a plain create's Undo ownership fetches grew with the library")
    }

    /// Review R-2: the read by owner id fetches live writing only. An owner
    /// with many deleted replicas and one live note returns the live note,
    /// in one fetch of one row.
    func testOwnerIDReadFetchesOnlyLiveWriting() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let owner = TaskItem(title: "A")
        context.insert(owner)
        for index in 0..<20 {
            let deleted = NoteItem(title: "Deleted \(index)")
            deleted.taskID = owner.id
            deleted.deletedAt = Date()
            context.insert(deleted)
        }
        let live = NoteItem(title: "Live")
        live.taskID = owner.id
        context.insert(live)
        try context.save()
        let library = AtticLibrary(tasks: TaskStore(container: container))
        let (fetches, rows) = (library.ownershipFetches, library.ownershipNoteRows)
        XCTAssertEqual(library.liveWriting(ownedBy: [owner.id], in: ModelContext(container)), [live.id])
        print("GUARD_LIVE_ONLY deleted=20 ownership_fetches=\(library.ownershipFetches - fetches) ownership_note_rows=\(library.ownershipNoteRows - rows)")
        XCTAssertEqual(library.ownershipFetches - fetches, 1, "one fetch by owner id")
        XCTAssertEqual(library.ownershipNoteRows - rows, 1, "R-2: the read fetched deleted writing")
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

    /// Review R-1: a failed read by owner id never records less than the
    /// whole-table read did. One failure leaves the one-fetch-per-task read;
    /// two (the bulk read and that read) fall back to the whole table, which
    /// returns the same writing.
    func testFailedOwnerIDReadFallsBackToTheWholeTable() throws {
        let store = try makeStore(open: 3, notes: 2)
        let library = AtticLibrary(tasks: store)
        let id = try XCTUnwrap(store.tasks.first?.id)
        let noteID = try attachNote(to: id, in: store)
        let reference = try XCTUnwrap(library.wholeTableLiveWriting(ownedBy: [id]))
        XCTAssertEqual(reference, [noteID])
        for failures in [1, 2] {
            library.ownerFetchFailures = failures
            let rows = library.ownershipNoteRows
            XCTAssertEqual(library.itemOwnership([id], deleted: false).writing, reference, "failures=\(failures): the writing is still recorded")
            XCTAssertEqual(library.ownerFetchFailures, 0, "failures=\(failures): every failing fetch ran")
            XCTAssertEqual(library.ownershipNoteRows - rows, failures == 1 ? 1 : 3, "failures=\(failures): the read that answered")
        }
        XCTAssertEqual(library.itemOwnership([id], deleted: false).writing, reference, "the next read records the writing")
    }

    /// Review R-1, red first: both reads by owner id fail while the plain
    /// create records its Undo step; the whole table is still readable. A
    /// note attached afterwards is still protected: Undo of the add, with no
    /// older step, refuses for good and changes nothing.
    func testFailedOwnerIDCaptureStillProtectsALaterNote() throws {
        let store = try makeStore(open: 3, notes: 5)
        let library = AtticLibrary(tasks: store)
        library.ownerFetchFailures = 2
        let id = try XCTUnwrap(library.createTasks([TaskDraft(title: "New task")])?.first?.id)
        XCTAssertEqual(library.ownerFetchFailures, 0, "both reads by owner id ran and failed during the capture")
        XCTAssertNotNil(library.wholeTableLiveWriting(ownedBy: [id]), "the whole table stayed readable")
        let noteID = try attachNote(to: id, in: store)
        let receipts = try receiptIDs(store)
        XCTAssertEqual(library.undo.steps(in: .tasks, redo: false).map(\.name), ["Add Task"], "the add recorded its step, and it is the only one")
        let outcome = library.undo(in: .tasks)
        XCTAssertFalse(outcome.isApplied, "Undo of the add must not take a note it did not make")
        XCTAssertEqual(outcome.failure?.canRetry, false, "the step can never apply")
        let context = ModelContext(store.container)
        let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        let notes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(try XCTUnwrap(tasks.first).deletedAt, "the task stays live")
        XCTAssertEqual(notes.count, 1)
        XCTAssertNil(try XCTUnwrap(notes.first).deletedAt, "the note stays live")
        XCTAssertTrue(library.undo.steps(in: .tasks, redo: false).isEmpty, "the obsolete step is dropped")
        XCTAssertTrue(library.undo.steps(in: .tasks, redo: true).isEmpty, "no Redo step")
        XCTAssertEqual(try receiptIDs(store), receipts, "no deletion receipt")
    }

    /// TA-03, behaviour kept: Undo of an add stops for good when a note was
    /// attached to the new task after it was made, and changes nothing;
    /// without the note, Undo moves the task to Recently Deleted with one
    /// receipt, and Redo brings it back (review R-4: exact outcomes).
    func testUndoOfAnAddStopsWhenANoteWasAttachedLater() throws {
        for attach in [false, true] {
            let store = try makeStore(open: 3, notes: 5)
            let library = AtticLibrary(tasks: store)
            let id = try XCTUnwrap(library.createTasks([TaskDraft(title: "New task")])?.first?.id)
            let noteID = try attach ? attachNote(to: id, in: store) : nil
            let receipts = try receiptIDs(store)
            XCTAssertEqual(library.undo.steps(in: .tasks, redo: false).map(\.name), ["Add Task"], "attach=\(attach): the add's step is the only one")
            let outcome = library.undo(in: .tasks)
            let context = ModelContext(store.container)
            let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
            XCTAssertEqual(tasks.count, 1, "attach=\(attach): one physical task, never erased")
            let task = try XCTUnwrap(tasks.first)
            if let noteID {
                XCTAssertFalse(outcome.isApplied, "Undo of the add must not take a note it did not make")
                XCTAssertEqual(outcome.failure?.canRetry, false, "the step can never apply: not a retryable refusal")
                XCTAssertNil(task.deletedAt, "the task stays live")
                let notes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
                XCTAssertEqual(notes.count, 1)
                XCTAssertNil(try XCTUnwrap(notes.first).deletedAt, "the note stays live")
                XCTAssertTrue(library.undo.steps(in: .tasks, redo: false).isEmpty, "the obsolete step is dropped")
                XCTAssertTrue(library.undo.steps(in: .tasks, redo: true).isEmpty, "no Redo step")
                XCTAssertEqual(try receiptIDs(store), receipts, "no deletion receipt")
            } else {
                XCTAssertEqual(outcome, .applied, "Undo takes the new task back")
                XCTAssertNotNil(task.deletedAt, "the task is in Recently Deleted")
                XCTAssertNotNil(task.deletionGroupID, "under one deletion group")
                XCTAssertTrue(library.undo.steps(in: .tasks, redo: false).isEmpty)
                XCTAssertEqual(library.undo.steps(in: .tasks, redo: true).map(\.name), ["Add Task"], "the add's Redo step")
                let added = try receiptIDs(store).subtracting(receipts)
                XCTAssertEqual(added.count, 1, "one deletion receipt")
                let receipt = try XCTUnwrap(try ModelContext(store.container).fetch(FetchDescriptor<OperationReceipt>()).first { added.contains($0.id) })
                let affected = try JSONDecoder().decode([WorkspaceOwner].self, from: receipt.affectedIDs)
                XCTAssertTrue(affected.contains(WorkspaceOwner(entity: .task, id: id)), "the receipt names the task")
                XCTAssertEqual(library.redo(in: .tasks), .applied, "Redo brings the task back")
                let restored = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
                XCTAssertEqual(restored.count, 1)
                XCTAssertNil(try XCTUnwrap(restored.first).deletedAt, "the task is live again")
                XCTAssertNotNil(store.task(withID: id), "and listed")
            }
        }
    }

    // MARK: - Rig

    /// A live note owned by `task`, saved.
    private func attachNote(to task: UUID, in store: TaskStore) throws -> UUID {
        let context = ModelContext(store.container)
        let note = NoteItem(title: "Written later")
        note.taskID = task
        context.insert(note)
        try context.save()
        return note.id
    }

    private func receiptIDs(_ store: TaskStore) throws -> Set<UUID> {
        Set(try ModelContext(store.container).fetch(FetchDescriptor<OperationReceipt>()).map(\.id))
    }

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
