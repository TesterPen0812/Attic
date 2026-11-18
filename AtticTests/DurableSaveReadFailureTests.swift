import SwiftData
import XCTest
@testable import Attic

/// Board ids delete-postcommit-owner-read (R-1) and undo-unresolved-staging (R-2), from Astra's review of pull
/// request 29. One rule for both: once the save is durable, the action is recorded as done; a failed read afterwards
/// is a presentation failure, retried or reported, and never changes the record or leaves a staging context to be
/// reused. Red tests first; the fix is its own pull request.
@MainActor
final class DurableSaveReadFailureTests: XCTestCase {
    override func tearDown() {
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 0
        WorkspaceLegacyBridge.postCommitPlainFailures = 0
        WorkspaceLegacyBridge.postSaveCaptureFailures = 0
        super.tearDown()
    }

    private struct Rig {
        let container: ModelContainer
        let tasks: TaskStore
        let notes: NoteStore
        let library: AtticLibrary
        let controller: NotesPageController
        let ids: [UUID]
        let writingID: UUID
    }

    /// The panel's wiring: library plus a registered Notes lifecycle controller, 30 tasks, task 3 with writing,
    /// six other notes. One physical row per id.
    /// Fails the next N writer calls (the save itself, before anything is durable).
    private final class WriterFailures { var remaining = 0 }

    private func makeRig(writerFailures: WriterFailures? = nil) async throws -> Rig {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let seed = ModelContext(container)
        var ids: [UUID] = []
        for index in 0..<30 {
            let task = TaskItem(title: "Open task \(index)", createdAt: date)
            task.tags = ["tag\(index % 7)"]
            seed.insert(task); ids.append(task.id)
        }
        let writing = NoteItem(title: "Open task 3", body: "Writing", createdAt: date)
        writing.taskID = ids[3]
        writing.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Open task 3"), .text("Writing")], requires: ["taskNote"]))
        seed.insert(writing)
        for index in 0..<6 { seed.insert(NoteItem(title: "Note \(index)", body: "Body", createdAt: date)) }
        try seed.save()
        let files = TaskImageFiles(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("R12Rig-\(UUID())"))
        let tasks = TaskStore(container: container, now: { date }, persist: { context in
            if let failures = writerFailures, failures.remaining > 0 {
                failures.remaining -= 1
                throw WorkspaceFoundationError.unknown
            }
            try context.save()
        }, taskImageFiles: files)
        let notes = NoteStore(container: container, now: { date }, attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: tasks, notes: notes)
        let controller = NotesPageController(store: notes, journal: coordinator.journal)
        await notes.waitForAttachmentReconciliation()
        XCTAssertTrue(coordinator.lifecycleNotes === controller)
        return Rig(container: container, tasks: tasks, notes: notes, library: library, controller: controller,
                   ids: ids, writingID: writing.id)
    }

    /// Physical rows per id, read from a fresh context: every id with more than one row, by model.
    private func duplicateRows(_ container: ModelContainer) throws -> [String] {
        let context = ModelContext(container)
        func dupes<T: PersistentModel>(_ name: String, _ rows: [T], _ id: (T) -> UUID) -> [String] {
            Dictionary(grouping: rows, by: id).filter { $0.value.count > 1 }.map { "\(name) \($0.key) x\($0.value.count)" }
        }
        return (dupes("task", try context.fetch(FetchDescriptor<TaskItem>()), \.id)
            + dupes("note", try context.fetch(FetchDescriptor<NoteItem>()), \.id)
            + dupes("preservation", try context.fetch(FetchDescriptor<TaskDeletionPreservation>()), \.id)
            + dupes("receipt", try context.fetch(FetchDescriptor<OperationReceipt>()), \.id)).sorted()
    }

    private func durable(_ container: ModelContainer, task id: UUID, note writingID: UUID)
        throws -> (taskRows: Int, taskDeleted: Int, noteDeleted: Int, preservations: Int, retired: Int, receipts: Int) {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        let notes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == writingID }))
        let records = try context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.rootID == id }))
        return (rows.count, rows.filter { $0.deletedAt != nil }.count, notes.filter { $0.deletedAt != nil }.count,
                records.count, records.filter { $0.retiredAt != nil }.count,
                try context.fetchCount(FetchDescriptor<OperationReceipt>()))
    }

    /// R-1 (delete-postcommit-owner-read). The journaled writer commits the delete and its receipt; the read of the
    /// written owners that follows throws. The delete is durable, so it is recorded as done: the command reports it
    /// applied, keeps one Undo step, the task and its writing leave the presentation, and Undo restores both.
    func testR1DurableDeleteWhosePostCommitOwnerReadFailsIsRecordedAsDone() async throws {
        let rig = try await makeRig()
        let id = rig.ids[3]
        let before = try durable(rig.container, task: id, note: rig.writingID)
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 1
        let outcome = rig.library.deleteTasks([id])
        let seamUsed = WorkspaceLegacyBridge.postCommitOwnerReadFailures == 0
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 0
        let after = try durable(rig.container, task: id, note: rig.writingID)
        let canUndo = rig.library.undo.canUndo(in: .tasks)
        let taskPresented = rig.tasks.task(withID: id) != nil
        let writingPresentedLive = rig.notes.notes.contains { $0.id == rig.writingID }
        print("R1_FACTS seam_used=\(seamUsed) outcome=\(outcome) can_undo=\(canUndo) task_presented=\(taskPresented) "
            + "writing_presented_live=\(writingPresentedLive) task_deleted=\(after.taskDeleted)/\(after.taskRows) "
            + "note_deleted=\(after.noteDeleted) receipts=\(before.receipts)->\(after.receipts) "
            + "preservations=\(after.preservations) duplicates=\(try duplicateRows(rig.container))")

        XCTAssertTrue(seamUsed, "The injected failure reached the post-commit owner read")
        // The facts the record must follow: the delete and its receipt are durable.
        XCTAssertEqual(after.taskDeleted, after.taskRows, "The delete is durable")
        XCTAssertEqual(after.noteDeleted, 1, "The writing's delete is durable")
        XCTAssertEqual(after.receipts, before.receipts + 1, "The delete's receipt is durable")
        // Recorded as done.
        XCTAssertTrue(outcome.isApplied, "A durable delete is reported as applied")
        XCTAssertTrue(canUndo, "A durable delete keeps its Undo step")
        XCTAssertFalse(taskPresented, "The task leaves Tasks")
        XCTAssertFalse(writingPresentedLive, "Its writing leaves the Notes library (lifecycle notice)")
        // And it can be undone once.
        XCTAssertTrue(rig.library.undo(in: .tasks).isApplied, "Undo restores the durable delete")
        XCTAssertNotNil(rig.tasks.task(withID: id))
        XCTAssertTrue(rig.notes.notes.contains { $0.id == rig.writingID })
        XCTAssertEqual(try duplicateRows(rig.container), [])
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    /// R-2 (undo-unresolved-staging). Three presentation reads fail after a durable delete, so the task store keeps
    /// its staging context. Undo runs at once, then the next save through the same store. Every id must still have
    /// one physical row: the delete's preservation record is kept once (by its original id, retired by the restore),
    /// and nothing staged before is written again.
    func testR2ImmediateUndoAfterUnresolvedDeleteThenNextSaveWritesOneRowPerID() async throws {
        let rig = try await makeRig()
        let id = rig.ids[3]
        let before = try durable(rig.container, task: id, note: rig.writingID)
        rig.tasks.listRefreshFailures = 3
        XCTAssertTrue(rig.library.deleteTasks([id]).isApplied, "The durable save cannot be refused by a presentation read")
        XCTAssertTrue(rig.tasks.hasUnresolvedTaskReload, "Three failed reads leave the presentation unresolved")
        let afterDelete = try durable(rig.container, task: id, note: rig.writingID)
        let preservationIDs = Set(try ModelContext(rig.container).fetch(
            FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.rootID == id })).map(\.id))

        let undone = rig.library.undo(in: .tasks)
        let afterUndo = try durable(rig.container, task: id, note: rig.writingID)
        let dupesAfterUndo = try duplicateRows(rig.container)

        let other = try XCTUnwrap(rig.tasks.task(withID: rig.ids[7]))
        let nextSaved = rig.tasks.rename(other, to: "The next save")
        let afterNext = try durable(rig.container, task: id, note: rig.writingID)
        let dupesAfterNext = try duplicateRows(rig.container)
        let preservationIDsAfter = Set(try ModelContext(rig.container).fetch(
            FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.rootID == id })).map(\.id))
        print("R2_FACTS undo=\(undone) next_save=\(nextSaved) "
            + "preservations=\(afterDelete.preservations)->\(afterUndo.preservations)->\(afterNext.preservations) "
            + "retired=\(afterUndo.retired)->\(afterNext.retired) receipts=\(before.receipts)->\(afterDelete.receipts)->"
            + "\(afterUndo.receipts)->\(afterNext.receipts) task_deleted=\(afterUndo.taskDeleted)->\(afterNext.taskDeleted) "
            + "dupes_after_undo=\(dupesAfterUndo) dupes_after_next=\(dupesAfterNext) "
            + "new_preservation_ids=\(preservationIDsAfter.subtracting(preservationIDs).count)")

        XCTAssertEqual(afterDelete.preservations, 1, "The delete writes one preservation record")
        XCTAssertTrue(undone.isApplied, "Undo restores the durable delete")
        XCTAssertTrue(nextSaved, "The next save succeeds")
        XCTAssertEqual(dupesAfterUndo, [], "One physical row per id after Undo")
        XCTAssertEqual(dupesAfterNext, [], "One physical row per id after the next save")
        XCTAssertEqual(afterNext.preservations, 1, "Still one preservation record for the deletion")
        XCTAssertEqual(preservationIDsAfter, preservationIDs, "The record keeps its original id; none is added")
        XCTAssertEqual(afterNext.retired, 1, "Retired by the restore")
        XCTAssertEqual(afterNext.taskDeleted, 0, "The task stays restored")
        XCTAssertEqual(afterUndo.receipts, afterDelete.receipts + 1, "Undo writes exactly one inverse receipt")
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    private func durableTitles(_ container: ModelContainer, _ title: String) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.title == title }))
    }

    /// Condition 1, plain branch of `persist`: the in-place save commits, then the bridge's update of its scope guards
    /// and baseline throws. The rename is durable, so it is reported as done and presented, and the next save works.
    func testC1PlainEditWhoseBaselineUpdateFailsIsRecordedAsDone() async throws {
        let rig = try await makeRig()
        let task = try XCTUnwrap(rig.tasks.task(withID: rig.ids[7]))
        WorkspaceLegacyBridge.postCommitPlainFailures = 1
        let renamed = rig.tasks.rename(task, to: "Renamed after a plain commit")
        let seamUsed = WorkspaceLegacyBridge.postCommitPlainFailures == 0
        WorkspaceLegacyBridge.postCommitPlainFailures = 0
        let durable = try durableTitles(rig.container, "Renamed after a plain commit")
        let presented = rig.tasks.task(withID: rig.ids[7])?.title
        let next = rig.tasks.rename(try XCTUnwrap(rig.tasks.task(withID: rig.ids[8])), to: "The next plain save")
        print("C1_PLAIN seam_used=\(seamUsed) renamed=\(renamed) durable=\(durable) presented=\(presented ?? "nil") "
            + "next=\(next) next_durable=\(try durableTitles(rig.container, "The next plain save")) "
            + "duplicates=\(try duplicateRows(rig.container))")
        XCTAssertTrue(seamUsed)
        XCTAssertEqual(durable, 1, "The rename is durable")
        XCTAssertTrue(renamed, "A durable rename is reported as done")
        XCTAssertEqual(presented, "Renamed after a plain commit")
        XCTAssertTrue(next, "The next save works")
        XCTAssertEqual(try durableTitles(rig.container, "The next plain save"), 1)
        XCTAssertEqual(try duplicateRows(rig.container), [])
    }

    /// Condition 1, `commitInPlace`: `gatedSave` commits an insert, then capturing the inserted row's permanent
    /// identifiers throws. The new task is durable once, reported as created, presented, and the next save writes it
    /// no second time.
    func testC1PlainInsertWhoseCaptureFailsIsWrittenOnceAndReported() async throws {
        let rig = try await makeRig()
        WorkspaceLegacyBridge.postSaveCaptureFailures = 1
        let created = rig.tasks.create(title: "Created before a failed capture")
        let seamUsed = WorkspaceLegacyBridge.postSaveCaptureFailures == 0
        WorkspaceLegacyBridge.postSaveCaptureFailures = 0
        let durable = try durableTitles(rig.container, "Created before a failed capture")
        let presented = rig.tasks.tasks.filter { $0.title == "Created before a failed capture" }.count
        let next = rig.tasks.rename(try XCTUnwrap(rig.tasks.task(withID: rig.ids[8])), to: "The next plain save")
        let durableAfterNext = try durableTitles(rig.container, "Created before a failed capture")
        print("C1_CAPTURE seam_used=\(seamUsed) created=\(created != nil) durable=\(durable) presented=\(presented) "
            + "next=\(next) durable_after_next=\(durableAfterNext) error=\(rig.tasks.lastErrorMessage ?? "nil") "
            + "duplicates=\(try duplicateRows(rig.container))")
        XCTAssertTrue(seamUsed)
        XCTAssertEqual(durable, 1, "The insert is durable once")
        XCTAssertNotNil(created, "A durable insert is reported as created")
        XCTAssertEqual(presented, 1)
        XCTAssertTrue(next, "The next save works")
        XCTAssertEqual(durableAfterNext, 1, "The next save does not write the insert again")
        XCTAssertEqual(try duplicateRows(rig.container), [])
    }

    /// Condition 6: an Undo whose save fails before anything is durable is refused, and keeps its history step, so
    /// the owner can press Undo again.
    func testC6RefusedUndoKeepsItsHistoryStep() async throws {
        let failures = WriterFailures()
        let rig = try await makeRig(writerFailures: failures)
        let id = rig.ids[5]
        XCTAssertTrue(rig.library.deleteTasks([id]).isApplied)
        failures.remaining = 1
        let refused = rig.library.undo(in: .tasks)
        let failureUsed = failures.remaining == 0
        failures.remaining = 0
        let canUndo = rig.library.undo.canUndo(in: .tasks)
        let presentedAfterRefusal = rig.tasks.task(withID: id) != nil
        let again = rig.library.undo(in: .tasks)
        print("C6_UNDO failure_used=\(failureUsed) refused=\(refused) can_undo_after=\(canUndo) "
            + "presented_after_refusal=\(presentedAfterRefusal) again=\(again) presented=\(rig.tasks.task(withID: id) != nil) "
            + "duplicates=\(try duplicateRows(rig.container))")
        XCTAssertTrue(failureUsed)
        XCTAssertFalse(refused.isApplied, "The failed save refuses the Undo")
        XCTAssertTrue(canUndo, "A refused Undo keeps its step")
        XCTAssertFalse(presentedAfterRefusal, "Nothing was restored")
        XCTAssertTrue(again.isApplied, "Undo again restores")
        XCTAssertNotNil(rig.tasks.task(withID: id))
        XCTAssertEqual(try duplicateRows(rig.container), [])
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    /// Condition 7: after a failed post-commit owner read the store is not wedged. The next plain save and the next
    /// journaled save both work, each recorded once.
    func testC7AfterAFailedOwnerReadTheNextSavesWork() async throws {
        let rig = try await makeRig()
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 1
        let first = rig.library.deleteTasks([rig.ids[5]])
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 0
        let renamed = rig.tasks.rename(try XCTUnwrap(rig.tasks.task(withID: rig.ids[7])), to: "Saved after a failed read")
        let renameDurable = try durableTitles(rig.container, "Saved after a failed read")
        let second = rig.library.deleteTasks([rig.ids[9]])
        let secondID = rig.ids[9]
        let secondDurable = try ModelContext(rig.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == secondID }))
            .allSatisfy { $0.deletedAt != nil }
        print("C7_NEXT first=\(first) renamed=\(renamed) rename_durable=\(renameDurable) second=\(second) "
            + "second_durable=\(secondDurable) can_undo=\(rig.library.undo.canUndo(in: .tasks)) "
            + "error=\(rig.tasks.lastErrorMessage ?? "nil") duplicates=\(try duplicateRows(rig.container))")
        XCTAssertTrue(renamed, "The next plain save works")
        XCTAssertEqual(renameDurable, 1)
        XCTAssertTrue(second.isApplied, "The next journaled save works")
        XCTAssertTrue(secondDurable)
        XCTAssertNil(rig.tasks.task(withID: rig.ids[9]))
        XCTAssertTrue(rig.library.undo(in: .tasks).isApplied, "The second delete has its Undo step")
        XCTAssertNotNil(rig.tasks.task(withID: rig.ids[9]))
        XCTAssertEqual(try duplicateRows(rig.container), [])
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }
}
