import CryptoKit
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
        let files: AttachmentFileStore
        let ids: [UUID]
        let writingID: UUID
    }

    /// The panel's wiring: library plus a registered Notes lifecycle controller, 30 tasks, task 3 with writing,
    /// six other notes. One physical row per id.
    /// Fails the next N writer calls (the save itself, before anything is durable).
    private final class WriterFailures { var remaining = 0 }

    private func makeRig(writerFailures: WriterFailures? = nil,
                         seed extra: ((ModelContext) throws -> Void)? = nil) async throws -> Rig {
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
        try extra?(seed)
        try seed.save()
        let files = TaskImageFiles(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("R12Rig-\(UUID())"))
        let tasks = TaskStore(container: container, now: { date }, persist: { context in
            if let failures = writerFailures, failures.remaining > 0 {
                failures.remaining -= 1
                throw WorkspaceFoundationError.unknown
            }
            try context.save()
        }, taskImageFiles: files)
        let attachmentFiles = makeTestAttachmentFileStore()
        let notes = NoteStore(container: container, now: { date }, attachmentFileStore: attachmentFiles)
        let library = AtticLibrary(tasks: tasks, notes: notes)
        let controller = NotesPageController(store: notes, journal: coordinator.journal)
        await notes.waitForAttachmentReconciliation()
        XCTAssertTrue(coordinator.lifecycleNotes === controller)
        return Rig(container: container, tasks: tasks, notes: notes, library: library, controller: controller,
                   files: attachmentFiles, ids: ids, writingID: writing.id)
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

    /// Condition 7, second half: the owner read fails on two journaled saves in a row, then on none. Neither failed
    /// read wedges the store: each delete is durable once, the commands after them work, and no row is doubled.
    func testC7TwoFailedOwnerReadsInARowThenTheNextSavesWork() async throws {
        let rig = try await makeRig()
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 2
        let first = rig.library.deleteTasks([rig.ids[5]])
        let second = rig.library.deleteTasks([rig.ids[6]])
        let seamUsed = WorkspaceLegacyBridge.postCommitOwnerReadFailures == 0
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 0
        let renamed = rig.tasks.rename(try XCTUnwrap(rig.tasks.task(withID: rig.ids[7])), to: "Saved after two failed reads")
        let third = rig.library.deleteTasks([rig.ids[9]])
        let context = ModelContext(rig.container)
        func deleted(_ id: UUID) throws -> String {
            let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
            return "\(rows.filter { $0.deletedAt != nil }.count)/\(rows.count)"
        }
        print("C7_TWICE seam_used=\(seamUsed) first=\(first) second=\(second) renamed=\(renamed) third=\(third) "
            + "deleted=\(try deleted(rig.ids[5])),\(try deleted(rig.ids[6])),\(try deleted(rig.ids[9])) "
            + "can_undo=\(rig.library.undo.canUndo(in: .tasks)) error=\(rig.tasks.lastErrorMessage ?? "nil") "
            + "duplicates=\(try duplicateRows(rig.container))")
        XCTAssertTrue(seamUsed)
        XCTAssertEqual(try deleted(rig.ids[5]), "1/1", "The first delete is durable once")
        XCTAssertEqual(try deleted(rig.ids[6]), "1/1", "The second delete is durable once")
        XCTAssertTrue(renamed, "The next plain save works")
        XCTAssertTrue(third.isApplied, "The next journaled save works")
        XCTAssertEqual(try deleted(rig.ids[9]), "1/1")
        XCTAssertEqual(try duplicateRows(rig.container), [])
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    // MARK: Condition 3: every TaskStore site that stages on the spent context

    /// One unresolved delete (three failed presentation reads after the durable save), then one command that stages on
    /// the store's context without a prepare step, then the next save. Every id keeps one physical row, and the
    /// delete's preservation record stays one row.
    private func afterUnresolvedDelete(_ label: String, setup: (Rig) async throws -> Void = { _ in },
                                       command: (Rig) async throws -> Bool) async throws {
        let rig = try await makeRig()
        try await setup(rig)
        let id = rig.ids[3]
        rig.tasks.listRefreshFailures = 3
        XCTAssertTrue(rig.library.deleteTasks([id]).isApplied, label)
        XCTAssertTrue(rig.tasks.hasUnresolvedTaskReload, label)
        let commandResult = try await command(rig)
        let afterCommand = try duplicateRows(rig.container)
        let next = rig.tasks.rename(try XCTUnwrap(rig.tasks.task(withID: rig.ids[20])), to: "The next save after \(label)")
        let afterNext = try duplicateRows(rig.container)
        let records = try ModelContext(rig.container).fetch(
            FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.rootID == id }))
        print("C3_REUSE \(label) command=\(commandResult) next=\(next) preservation_rows=\(records.count) "
            + "preservation_ids=\(Set(records.map(\.id)).count) dupes_after_command=\(afterCommand) dupes_after_next=\(afterNext) "
            + "error=\(rig.tasks.lastErrorMessage ?? "nil")")
        XCTAssertEqual(afterCommand, [], "\(label): one physical row per id after the command")
        XCTAssertEqual(afterNext, [], "\(label): one physical row per id after the next save")
        XCTAssertEqual(records.count, 1, "\(label): the delete's preservation record is one row")
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    func testC3RestoreDeletedOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("restoreDeleted") { $0.tasks.restoreDeleted(taskIDs: [$0.ids[3]]) }
    }

    func testC3PurgeDeletedOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("purgeDeleted") { rig in
            !rig.tasks.purgeDeleted(before: .distantFuture).isEmpty
        }
    }

    func testC3DuplicateOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("duplicate") { $0.tasks.duplicate(taskIDs: [$0.ids[7]]) != nil }
    }

    func testC3MoveOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("move") { $0.tasks.move(taskID: $0.ids[7], toIndex: 0) }
    }

    func testC3CompleteFamilyOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("completeFamily") { $0.tasks.completeFamily(taskID: $0.ids[7]) }
    }

    func testC3MoveSubtaskOnTheSpentContext() async throws {
        var subtask: UUID?
        try await afterUnresolvedDelete("moveSubtask", setup: { rig in
            _ = try XCTUnwrap(rig.tasks.create(title: "First subtask", parentID: rig.ids[8]))
            subtask = try XCTUnwrap(rig.tasks.create(title: "Second subtask", parentID: rig.ids[8])).id
        }) { rig in rig.tasks.moveSubtask(taskID: try XCTUnwrap(subtask), by: -1) }
    }

    func testC3MoveCompletedToDoneLogOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("moveCompletedToDoneLog", setup: { rig in
            XCTAssertTrue(rig.tasks.setStatus(.done, for: try XCTUnwrap(rig.tasks.task(withID: rig.ids[10]))))
        }) { $0.tasks.moveCompletedToDoneLog(before: .distantFuture) > 0 }
    }

    func testC3ReopenOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("reopen", setup: { rig in
            XCTAssertTrue(rig.tasks.setStatus(.done, for: try XCTUnwrap(rig.tasks.task(withID: rig.ids[11]))))
        }) { $0.tasks.reopen(taskIDs: [$0.ids[11]]) }
    }

    func testC3RestoreToNowOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("restoreToNow", setup: { rig in
            XCTAssertTrue(rig.tasks.setStatus(.done, for: try XCTUnwrap(rig.tasks.task(withID: rig.ids[12]))))
            XCTAssertGreaterThan(rig.tasks.moveCompletedToDoneLog(before: .distantFuture), 0)
        }) { $0.tasks.restoreToNow(taskIDs: [$0.ids[12]]) }
    }

    /// Attaches one small file to `taskID` and returns its reference.
    private func attachOne(_ rig: Rig, to taskID: UUID) async throws -> TaskImageReference {
        let source = ownedTemporaryDirectory(prefix: "R12Attach").appendingPathComponent("plan.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plan".utf8).write(to: source)
        let attached = await rig.tasks.attachFiles([source], to: taskID)
        XCTAssertTrue(attached)
        return try XCTUnwrap(rig.tasks.task(withID: taskID)?.attachments.first)
    }

    func testC3AttachFilesOnTheSpentContext() async throws {
        let source = ownedTemporaryDirectory(prefix: "R12Attach").appendingPathComponent("later.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("later".utf8).write(to: source)
        try await afterUnresolvedDelete("attachFiles") { rig in await rig.tasks.attachFiles([source], to: rig.ids[9]) }
    }

    func testC3RemoveAttachmentOnTheSpentContext() async throws {
        var reference: TaskImageReference?
        try await afterUnresolvedDelete("removeAttachment", setup: { rig in
            reference = try await self.attachOne(rig, to: rig.ids[9])
        }) { rig in rig.tasks.removeAttachment(try XCTUnwrap(reference).id, from: rig.ids[9]) }
    }

    func testC3RestoreAttachmentOnTheSpentContext() async throws {
        var reference: TaskImageReference?
        try await afterUnresolvedDelete("restoreAttachment", setup: { rig in
            reference = try await self.attachOne(rig, to: rig.ids[9])
            XCTAssertTrue(rig.tasks.removeAttachment(try XCTUnwrap(reference).id, from: rig.ids[9]))
        }) { rig in rig.tasks.restoreAttachment(try XCTUnwrap(reference).id) }
    }

    func testC3PurgeRemovedAttachmentsOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("purgeRemovedAttachments", setup: { rig in
            let reference = try await self.attachOne(rig, to: rig.ids[9])
            XCTAssertTrue(rig.tasks.removeAttachment(reference.id, from: rig.ids[9]))
        }) { $0.tasks.purgeRemovedAttachments(before: .distantFuture) > 0 }
    }

    // MARK: Condition 2 and the Notes side

    /// A new note written through the editor session, whose journaled save commits and whose post-commit owner read
    /// throws. The note is durable once. The session must end saved: not a false conflict, not unsaved work that a
    /// later save writes again. One physical row after the session's own retries.
    func testC2NewNoteWhoseOwnerReadFailsIsSavedOnceAndNotRetried() async throws {
        let rig = try await makeRig()
        XCTAssertTrue(rig.controller.newNote())
        let session = try XCTUnwrap(rig.controller.active)
        session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
                                   with: NSAttributedString(string: "Written once"), name: "Typing")
        let stateBeforeSave = "\(session.state)"
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 1
        let first = rig.controller.save(session)
        let seamUsed = WorkspaceLegacyBridge.postCommitOwnerReadFailures == 0
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 0
        let stateAfterFirst = "\(session.state)"
        let preserved = rig.controller.preserve(session)
        let noteID = session.noteID
        let rows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        print("C2_NOTE state_before=\(stateBeforeSave) persisted=\(session.isPersisted) seam_used=\(seamUsed) first=\(first) state_after_first=\(stateAfterFirst) preserved=\(preserved) "
            + "state=\(session.state) rows=\(rows.count) error=\(rig.notes.lastErrorMessage ?? "nil") "
            + "duplicates=\(try duplicateRows(rig.container))")
        XCTAssertTrue(seamUsed)
        XCTAssertEqual(rows.count, 1, "The note is durable once")
        XCTAssertTrue(first, "A durable note save is reported as saved")
        XCTAssertEqual(try duplicateRows(rig.container), [])
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    /// The Notes side of R-2: a journaled note save commits, and the store's presentation reload fails, so `save`
    /// returns true and keeps its staging context. The next note command stages on it. Every id keeps one row.
    func testC3NoteCommandAfterAFailedReloadWritesOneRowPerID() async throws {
        let rig = try await makeRig()
        let note = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 0" })
        rig.notes.reloadFailures = 1
        let deleted = rig.notes.delete(note)
        let reloadFailed = rig.notes.reloadFailures == 0
        rig.notes.reloadFailures = 0
        let other = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 1" })
        let renamed = rig.notes.update(other, title: "Note 1 after a failed reload")
        print("C3_NOTE reload_failed=\(reloadFailed) deleted=\(deleted) renamed=\(renamed) "
            + "error=\(rig.notes.lastErrorMessage ?? "nil") duplicates=\(try duplicateRows(rig.container))")
        XCTAssertTrue(reloadFailed)
        XCTAssertEqual(try duplicateRows(rig.container), [], "One physical row per id after the next note command")
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    // MARK: Condition 3 of the build: a durable import whose step after the commit throws

    /// A note whose one file placement has a stored row without its bytes: what Locate repairs.
    private struct MissingFile { let noteID: UUID; let attachmentID: UUID; let bytes: Data; let source: URL }

    private func seedMissingFile() throws -> (MissingFile, (ModelContext) throws -> Void) {
        let bytes = Data(repeating: 0x42, count: 4_096)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let noteID = UUID(), attachmentID = UUID()
        let source = try ownedTemporaryFile(named: "original.pdf", prefix: "DurableImport")
        try bytes.write(to: source)
        let file = MissingFile(noteID: noteID, attachmentID: attachmentID, bytes: bytes, source: source)
        return (file, { context in
            let note = NoteItem(id: noteID, title: "Attached", body: "Attached", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            note.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Attached"),
                .file(attachmentID: attachmentID, filename: "original.pdf", contentTypeIdentifier: "com.adobe.pdf",
                      byteCount: Int64(bytes.count))]))
            context.insert(note)
            context.insert(NoteAttachment(id: attachmentID, noteID: noteID, originalFilename: "original.pdf",
                contentTypeIdentifier: "com.adobe.pdf", byteCount: Int64(bytes.count), sortIndex: 0,
                contentDigest: digest, createdAt: Date(timeIntervalSince1970: 1_700_000_000), payload: nil))
        })
    }

    /// Runs one import entry with one seam armed ("none" is the control: an ordinary successful import), then reads
    /// what is durable, whether the file store holds its file (read directly, never through a repair), and what the
    /// store reports. Returns whether the file is on disk, for comparison with the control.
    @discardableResult
    private func durableImport(_ entry: String, seam: String, control: Bool? = nil,
                               run: (Rig, MissingFile) async throws -> Bool) async throws -> Bool {
        let (file, seed) = try seedMissingFile()
        let rig = try await makeRig(seed: seed)
        if seam == "owner" { WorkspaceLegacyBridge.postCommitOwnerReadFailures = 1 }
        if seam == "plain" { WorkspaceLegacyBridge.postCommitPlainFailures = 1 }
        let reported = try await run(rig, file)
        let seamUsed = seam == "owner" ? WorkspaceLegacyBridge.postCommitOwnerReadFailures == 0
            : seam == "plain" ? WorkspaceLegacyBridge.postCommitPlainFailures == 0 : true
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 0
        WorkspaceLegacyBridge.postCommitPlainFailures = 0
        await rig.notes.waitForAttachmentReconciliation()
        let id = file.attachmentID
        let rows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == id }))
        let durable = rows.filter { $0.payload == file.bytes }.count
        let digest = SHA256.hash(data: file.bytes).map { String(format: "%02x", $0) }.joined()
        let url = try? await rig.files.verifiedMaterializedURL(
            for: AttachmentFileReference(id: id, digest: digest, filename: "original.pdf", payload: nil))
        let onDisk = url.flatMap { try? Data(contentsOf: $0) } == file.bytes
        print("C3_IMPORT \(entry) seam=\(seam) seam_used=\(seamUsed) reported=\(reported) rows=\(rows.count) durable=\(durable) "
            + "file_on_disk=\(onDisk) control_file_on_disk=\(control.map(String.init) ?? "-") "
            + "failure=\(rig.notes.attachmentFailures[id] ?? "nil") error=\(rig.notes.lastErrorMessage ?? "nil")")
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
        if !seamUsed { print("C3_IMPORT \(entry) seam=\(seam) SEAM_UNUSED: this entry does not reach that save path") }
        guard seamUsed else { return onDisk }
        XCTAssertEqual(durable, 1, "\(entry), \(seam): the import is durable once")
        if let control { XCTAssertEqual(onDisk, control, "\(entry), \(seam): its file is on disk as after a normal import") }
        XCTAssertTrue(reported, "\(entry), \(seam): a durable import is reported as done")
        return onDisk
    }

    private func durableImportCases(_ entry: String, run: (Rig, MissingFile) async throws -> Bool) async throws {
        let control = try await durableImport(entry, seam: "none", run: run)
        for seam in ["owner", "plain"] { try await durableImport(entry, seam: seam, control: control, run: run) }
    }

    func testC3DurableLocateAttachmentKeepsItsFileAndIsReportedDone() async throws {
        try await durableImportCases("locateAttachment") { rig, file in
            let shown = try XCTUnwrap(rig.notes.attachments(for: file.noteID).first { $0.id == file.attachmentID })
            return await rig.notes.locateAttachment(shown, at: file.source)
        }
    }

    func testC3DurableLocatePlacementKeepsItsFileAndIsReportedDone() async throws {
        try await durableImportCases("locatePlacement") { rig, file in
            let load = try XCTUnwrap(rig.notes.loadDocument(noteID: file.noteID))
            let block = try XCTUnwrap(load.content.document?.blocks.first { $0.attachmentID == file.attachmentID })
            return await rig.notes.locatePlacement(block, noteID: file.noteID, at: file.source) { true }
        }
    }

    // MARK: Condition 4 of the build: a journaled Notes commit that inserts rows, its reload failing, then another command

    /// The insert-bearing Notes pair: the editor saves a new note (a `NoteItem` insert, `createDocumentNote`), with or
    /// without one imported file (a `NoteAttachment` insert), journaled through `NotesPageController.save`. Every reload
    /// after the commit fails (the store's own, and `refreshAfterDocumentSave`'s when a file was inserted), so the
    /// store's staging context keeps the inserts. Then a rename of another note stages on the store. One row per id.
    func testC4NotesInsertingCommitThenAnotherNoteCommandWritesOneRowPerID() async throws {
        for withFile in [false, true] {
            let rig = try await makeRig()
            XCTAssertTrue(rig.controller.newNote())
            let session = try XCTUnwrap(rig.controller.active)
            XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0),
                                                     with: NSAttributedString(string: "Inserted once"), name: "Typing"))
            var itemID: UUID?
            if withFile {
                let data = Data(repeating: 0x42, count: 2_048)
                let item = StagedNoteAttachment(id: UUID(), filename: "inserted.pdf", contentTypeIdentifier: "com.adobe.pdf",
                    byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    data: data)
                session.engine.beginImageImport()
                XCTAssertTrue(session.engine.insertImportedObjects([.init(staged: item, pixelSize: nil)]))
                itemID = item.id
            }
            let failures = withFile ? 2 : 1
            rig.notes.reloadFailures = failures
            let saved = rig.controller.save(session)
            let reloadsFailed = failures - rig.notes.reloadFailures
            rig.notes.reloadFailures = 0
            let noteID = session.noteID
            let other = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 1" })
            let renamed = rig.notes.update(other, title: "Note 1 after an inserting commit")
            let context = ModelContext(rig.container)
            let noteRows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })).count
            let fileRows = try itemID.map { id in
                try context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == id })).count } ?? 0
            let attachmentDupes = Dictionary(grouping: try context.fetch(FetchDescriptor<NoteAttachment>()), by: \.id)
                .filter { $0.value.count > 1 }.map { "attachment \($0.key) x\($0.value.count)" }
            let label = withFile ? "note+file" : "note"
            print("C4_NOTES_INSERT \(label) reloads_failed=\(reloadsFailed)/\(failures) saved=\(saved) state=\(session.state) "
                + "renamed=\(renamed) note_rows=\(noteRows) file_rows=\(fileRows) error=\(rig.notes.lastErrorMessage ?? "nil") "
                + "duplicates=\(try duplicateRows(rig.container) + attachmentDupes)")
            XCTAssertEqual(reloadsFailed, failures, "\(label): every reload after the inserting commit failed")
            XCTAssertEqual(noteRows, 1, "\(label): the inserted note is one row")
            if withFile { XCTAssertEqual(fileRows, 1, "\(label): the inserted file is one row") }
            XCTAssertEqual(try duplicateRows(rig.container) + attachmentDupes, [], "\(label): one physical row per id after the next command")
            await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
        }
    }

    // MARK: Condition 8: a store that already holds two preservation rows

    /// Generated data: a durable delete, then a second physical copy of its preservation record (same id), as R-2
    /// leaves it. Restore (Undo) and purge, each on its own store. A characterization: it records what each does and
    /// requires only that a refusal changes no row. No repair; repairing real data is the owner's decision.
    func testC8RestoreAndPurgeOnAStoreThatHoldsTwoPreservationRows() async throws {
        for command in ["undo", "purge"] {
            let rig = try await makeRig()
            let id = rig.ids[3]
            XCTAssertTrue(rig.library.deleteTasks([id]).isApplied)
            let seed = ModelContext(rig.container)
            let original = try XCTUnwrap(try seed.fetch(
                FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.rootID == id })).first)
            seed.insert(TaskDeletionPreservation(id: original.id, rootID: original.rootID, deletedAt: original.deletedAt,
                capturedAt: original.capturedAt, provenance: original.provenance, snapshot: original.snapshot))
            try seed.save()
            func facts() throws -> String {
                let context = ModelContext(rig.container)
                let records = try context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.rootID == id }))
                let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
                return "records=\(records.count) retired=\(records.filter { $0.retiredAt != nil }.count) "
                    + "purged=\(records.filter { $0.purgedAt != nil }.count) task_rows=\(rows.count) "
                    + "task_live=\(rows.filter { $0.deletedAt == nil }.count)"
            }
            let before = try facts()
            let result: String
            let refused: Bool
            if command == "undo" {
                let outcome = rig.library.undo(in: .tasks)
                result = "\(outcome)"; refused = !outcome.isApplied
            } else {
                let purged = rig.tasks.purgeDeleted(before: .distantFuture)
                result = "\(purged.count)"; refused = purged.isEmpty
            }
            let after = try facts()
            print("C8_TWO_ROWS \(command) result=\(result) before[\(before)] after[\(after)] "
                + "error=\(rig.tasks.lastErrorMessage ?? "nil") duplicates=\(try duplicateRows(rig.container))")
            if refused {
                XCTAssertEqual(after, before, "\(command): a refusal changes no row")
            }
            await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
        }
    }
}
