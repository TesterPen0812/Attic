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
    override func setUp() {
        super.setUp()
        WorkspaceLegacyBridge.foreignRowMutations = 0
    }

    override func tearDown() {
        XCTAssertEqual(WorkspaceLegacyBridge.foreignRowMutations, 0, "No row is staged through a context it does not belong to")
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 0
        WorkspaceLegacyBridge.postCommitPlainFailures = 0
        WorkspaceLegacyBridge.postSaveCaptureFailures = 0
        WorkspaceLegacyBridge.postReconcileReadFailures = 0
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
    private final class WriterFailures {
        var remaining = 0
        /// The failing writer saves first, then throws: the outcome is unknown to the coordinator, the rows durable.
        var afterSave = false
    }

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
                if failures.afterSave { try context.save() }
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

    /// Astra round 5 on 9952bb65, HOLD 1 (red test for narrowing, no fix). `commitInPlace` commits an insert; capturing
    /// its permanent identifiers throws (PR 40's seam), and the reconciliation read that follows throws too. The task
    /// is on disk once, so creation must return it, and the next edit must work.
    func testR5H1PlainInsertWhoseCaptureAndReconciliationReadFailIsReportedCreated() async throws {
        let rig = try await makeRig()
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: rig.container)
        var reconciliationReads = 0
        coordinator.beforeReconciliationRead = {
            reconciliationReads += 1
            throw WorkspaceFoundationError.unknown
        }
        WorkspaceLegacyBridge.postSaveCaptureFailures = 1
        let created = rig.tasks.create(title: "Created before two failed reads")
        let seamUsed = WorkspaceLegacyBridge.postSaveCaptureFailures == 0
        WorkspaceLegacyBridge.postSaveCaptureFailures = 0
        coordinator.beforeReconciliationRead = nil
        let durable = try durableTitles(rig.container, "Created before two failed reads")
        let next = rig.tasks.rename(try XCTUnwrap(rig.tasks.task(withID: rig.ids[8])), to: "The next plain save")
        let renamedCreated = created.map { rig.tasks.rename($0, to: "Created, then renamed") }
        print("R5_H1 seam_used=\(seamUsed) reconciliation_reads=\(reconciliationReads) created=\(created != nil) "
            + "durable=\(durable) next=\(next) renamed_created=\(renamedCreated.map { "\($0)" } ?? "nil") "
            + "durable_after=\(try durableTitles(rig.container, "Created before two failed reads"))+"
            + "\(try durableTitles(rig.container, "Created, then renamed")) error=\(rig.tasks.lastErrorMessage ?? "nil") "
            + "duplicates=\(try duplicateRows(rig.container))")
        XCTAssertTrue(seamUsed, "The capture after the save failed")
        XCTAssertEqual(reconciliationReads, 0, "No reconciliation is attempted once the save returned")
        XCTAssertEqual(durable, 1, "The insert is durable once")
        XCTAssertNotNil(created, "A durable insert is reported as created")
        XCTAssertTrue(next, "The next edit works")
        XCTAssertEqual(try duplicateRows(rig.container), [])
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    /// Fable's F1, second half (pr40-fable.md §3): the writer saves and then throws, so the outcome is unknown;
    /// reconciliation proves the plain commit, and then the read of the confirmed guards throws. The rename is durable,
    /// so it is reported done, and the next edit works.
    func testR5H1bPlainEditProvenByReconciliationWhoseGuardReadFailsIsDone() async throws {
        let failures = WriterFailures()
        let rig = try await makeRig(writerFailures: failures)
        failures.remaining = 1; failures.afterSave = true
        WorkspaceLegacyBridge.postReconcileReadFailures = 1
        let renamed = rig.tasks.rename(try XCTUnwrap(rig.tasks.task(withID: rig.ids[7])), to: "Renamed before an unknown outcome")
        let writerUsed = failures.remaining == 0
        let seamUsed = WorkspaceLegacyBridge.postReconcileReadFailures == 0
        failures.remaining = 0; failures.afterSave = false
        WorkspaceLegacyBridge.postReconcileReadFailures = 0
        let durable = try durableTitles(rig.container, "Renamed before an unknown outcome")
        let next = rig.tasks.rename(try XCTUnwrap(rig.tasks.task(withID: rig.ids[8])), to: "The next plain save")
        print("R5_H1B writer_used=\(writerUsed) seam_used=\(seamUsed) renamed=\(renamed) durable=\(durable) next=\(next) "
            + "next_durable=\(try durableTitles(rig.container, "The next plain save")) "
            + "error=\(rig.tasks.lastErrorMessage ?? "nil") duplicates=\(try duplicateRows(rig.container))")
        XCTAssertTrue(writerUsed, "The writer saved and threw")
        XCTAssertTrue(seamUsed, "Reconciliation proved the commit and the guard read failed")
        XCTAssertEqual(durable, 1, "The rename is durable")
        XCTAssertTrue(renamed, "A durable rename is reported as done")
        XCTAssertTrue(next, "The next edit works")
        XCTAssertEqual(try durableTitles(rig.container, "The next plain save"), 1)
        XCTAssertEqual(try duplicateRows(rig.container), [])
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
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
        let seamUsed = WorkspaceLegacyBridge.postCommitOwnerReadFailures == 0
        WorkspaceLegacyBridge.postCommitOwnerReadFailures = 0
        let firstID = rig.ids[5]
        let firstRows = try ModelContext(rig.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == firstID }))
        let firstDurable = firstRows.count == 1 && firstRows.allSatisfy { $0.deletedAt != nil }
        let renamed = rig.tasks.rename(try XCTUnwrap(rig.tasks.task(withID: rig.ids[7])), to: "Saved after a failed read")
        let renameDurable = try durableTitles(rig.container, "Saved after a failed read")
        let second = rig.library.deleteTasks([rig.ids[9]])
        let secondID = rig.ids[9]
        let secondDurable = try ModelContext(rig.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == secondID }))
            .allSatisfy { $0.deletedAt != nil }
        print("C7_NEXT seam_used=\(seamUsed) first=\(first) first_durable=\(firstDurable) renamed=\(renamed) rename_durable=\(renameDurable) second=\(second) "
            + "second_durable=\(secondDurable) can_undo=\(rig.library.undo.canUndo(in: .tasks)) "
            + "error=\(rig.tasks.lastErrorMessage ?? "nil") duplicates=\(try duplicateRows(rig.container))")
        XCTAssertTrue(seamUsed, "The first delete's owner read failed")
        XCTAssertTrue(first.isApplied, "The first delete is durable and reported done")
        XCTAssertTrue(firstDurable)
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
        // Astra round 5 (9952bb65), NOTE: both deletes are durable, so both are reported done.
        XCTAssertTrue(first.isApplied, "The first durable delete is reported done")
        XCTAssertTrue(second.isApplied, "The second durable delete is reported done")
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
        // Nothing replaced a spent context before the command (the delete's own entry found it usable).
        XCTAssertNil(rig.tasks.lastSpentContextUnsaved, "\(label): no spent context replaced before the command")
        let before = try taskFingerprint(rig.container)
        let commandResult = try await command(rig)
        // Read before the next save, which would replace a spent context itself.
        let replacedByCommand = rig.tasks.lastSpentContextUnsaved
        let changed = try taskFingerprint(rig.container) != before
        let afterCommand = try duplicateRows(rig.container)
        let next = rig.tasks.rename(try XCTUnwrap(rig.tasks.task(withID: rig.ids[20])), to: "The next save after \(label)")
        let afterNext = try duplicateRows(rig.container)
        let records = try ModelContext(rig.container).fetch(
            FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.rootID == id }))
        print("C3_REUSE \(label) command=\(commandResult) durable_change=\(changed) next=\(next) preservation_rows=\(records.count) "
            + "preservation_ids=\(Set(records.map(\.id)).count) dupes_after_command=\(afterCommand) dupes_after_next=\(afterNext) "
            + "error=\(rig.tasks.lastErrorMessage ?? "nil")")
        // Build condition 5: the command's staging entry replaced the spent context, and it held nothing unsaved.
        print("C5_SPENT \(label) replaced=\(replacedByCommand != nil) unsaved=\(replacedByCommand ?? [])")
        XCTAssertTrue(commandResult, "\(label): the command reports its work done")
        XCTAssertTrue(changed, "\(label): the command's own work is durable before the next save")
        XCTAssertEqual(replacedByCommand, [], "\(label): the command itself replaced the spent context, discarding nothing unsaved")
        XCTAssertEqual(afterCommand, [], "\(label): one physical row per id after the command")
        XCTAssertTrue(next, "\(label): the next save works")
        XCTAssertEqual(try durableTitles(rig.container, "The next save after \(label)"), 1, "\(label): the next save is durable")
        XCTAssertEqual(afterNext, [], "\(label): one physical row per id after the next save")
        XCTAssertEqual(records.count, 1, "\(label): the delete's preservation record is one row")
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    /// Every task row's durable fields, read from a fresh context: a command that writes nothing leaves it equal.
    private func taskFingerprint(_ container: ModelContainer) throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).map { task in
            [task.id.uuidString, task.title, task.statusRaw, "\(task.completedAt?.timeIntervalSince1970 ?? -1)",
             "\(task.manualOrder ?? -1)", task.parentID?.uuidString ?? "-", "\(task.deletedAt?.timeIntervalSince1970 ?? -1)",
             "\(task.doneLoggedAt?.timeIntervalSince1970 ?? -1)", "a\(task.attachments.count)",
             "r\(task.removedAttachments.count)"].joined(separator: " ")
        }.sorted()
    }

    func testC3RestoreDeletedOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("restoreDeleted") { $0.tasks.restoreDeleted(taskIDs: [$0.ids[3]]) }
    }

    /// A task store alone, seeded as the rig's tasks. In the rig (notes, library and Notes controller wired) the purge
    /// cannot commit at all, on the trunk too (board TASK-PURGE-UNKNOWN; pinned in testC3PurgeTargetIsPurgedWithoutAFault).
    private func makeBareTaskStore() throws -> (container: ModelContainer, tasks: TaskStore, ids: [UUID]) {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let seed = ModelContext(container)
        var ids: [UUID] = []
        for index in 0..<30 {
            let task = TaskItem(title: "Open task \(index)", createdAt: date)
            task.tags = ["tag\(index % 7)"]
            seed.insert(task); ids.append(task.id)
        }
        try seed.save()
        let files = TaskImageFiles(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("R12Bare-\(UUID())"))
        return (container, TaskStore(container: container, now: { date }, taskImageFiles: files), ids)
    }

    /// Purge on a spent context, on a task store alone: the delete commits and its list refresh fails, so the store's
    /// context stays spent (the purge's own replacement of it, below, shows it was). The purge must replace it (discarding nothing), purge the task durably,
    /// and leave the next save working with one physical row per id.
    func testC3PurgeDeletedOnTheSpentContext() async throws {
        let (container, tasks, ids) = try makeBareTaskStore()
        let id = ids[13]
        tasks.listRefreshFailures = 3
        let deleted = tasks.delete(taskIDs: [id])
        let refreshFailed = 3 - tasks.listRefreshFailures
        tasks.listRefreshFailures = 0
        let replacedBefore = tasks.lastSpentContextUnsaved
        let deletedRows = try ModelContext(container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        let refusalsBefore = WorkspaceLegacyBridge.spentContextRefusals
        let before = try taskFingerprint(container)
        let purged = tasks.purgeDeleted(before: .distantFuture)
        let replacedByPurge = tasks.lastSpentContextUnsaved
        let refusals = WorkspaceLegacyBridge.spentContextRefusals - refusalsBefore
        let left = try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        let changed = try taskFingerprint(container) != before
        let afterPurge = try duplicateRows(container)
        let next = tasks.rename(try XCTUnwrap(tasks.task(withID: ids[20])), to: "The next save after purgeDeleted")
        let afterNext = try duplicateRows(container)
        print("C3_PURGE_SPENT_BARE deleted=\(deleted) refresh_failed=\(refreshFailed) "
            + "deleted_rows=\(deletedRows.filter { $0.deletedAt != nil }.count)/\(deletedRows.count) replaced_before=\(replacedBefore.map { "\($0)" } ?? "nil") "
            + "purged=\(purged.contains(id)) replaced_by_purge=\(replacedByPurge.map { "\($0)" } ?? "nil") refusals=\(refusals) rows_left=\(left) "
            + "durable_change=\(changed) dupes_after_purge=\(afterPurge) next=\(next) dupes_after_next=\(afterNext) error=\(tasks.lastErrorMessage ?? "nil")")
        XCTAssertTrue(deleted)
        XCTAssertGreaterThan(refreshFailed, 0, "The delete's list refresh failed")
        XCTAssertTrue(!deletedRows.isEmpty && deletedRows.allSatisfy { $0.deletedAt != nil }, "The delete is durable")
        XCTAssertNil(replacedBefore, "Nothing replaced a spent context before the purge")
        XCTAssertEqual(replacedByPurge, [], "The purge itself replaced the spent context, discarding nothing unsaved")
        XCTAssertEqual(refusals, 0, "No save was refused on a spent context")
        XCTAssertTrue(purged.contains(id), "The purge reports the task purged")
        XCTAssertEqual(left, 0, "The purged task is gone from disk")
        XCTAssertTrue(changed)
        XCTAssertEqual(afterPurge, [], "One physical row per id after the purge")
        XCTAssertTrue(next, "The next save works")
        XCTAssertEqual(try durableTitles(container, "The next save after purgeDeleted"), 1, "The next save is durable")
        XCTAssertEqual(afterNext, [], "One physical row per id after the next save")
    }

    /// The purge's control. Arm "bare": a task store alone purges a task it deleted, leaving no row. Arm "rig": with
    /// notes, the library and the Notes controller wired, the same purge fails on the trunk too (board
    /// TASK-PURGE-UNKNOWN: probes on 2eb6663a, 6a6429b6 and f4c3a142 print WorkspaceFoundationError.unknown from the
    /// save). The rig arm pins today's outcome so that a fix fails it and the pin is updated with the fix.
    func testC3PurgeTargetIsPurgedWithoutAFault() async throws {
        let (bareContainer, bareTasks, bareIDs) = try makeBareTaskStore()
        let bareID = bareIDs[13]
        let bareDeleted = bareTasks.delete(taskIDs: [bareID])
        let barePurged = bareTasks.purgeDeleted(before: .distantFuture).contains(bareID)
        let bareLeft = try ModelContext(bareContainer).fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == bareID }))
        print("C3_PURGE_CONTROL bare deleted=\(bareDeleted) purged=\(barePurged) rows_left=\(bareLeft) error=\(bareTasks.lastErrorMessage ?? "nil")")
        XCTAssertTrue(bareDeleted)
        XCTAssertTrue(barePurged, "A task store alone purges a task it deleted")
        XCTAssertEqual(bareLeft, 0, "No row is left")

        let rig = try await makeRig()
        let id = rig.ids[13]
        let deleted = rig.tasks.delete(taskIDs: [id])
        let purged = rig.tasks.purgeDeleted(before: .distantFuture).contains(id)
        let left = try ModelContext(rig.container).fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        let error = rig.tasks.lastErrorMessage
        print("C3_PURGE_CONTROL rig deleted=\(deleted) purged=\(purged) rows_left=\(left) error=\(error ?? "nil")")
        let pin = "TASK-PURGE-UNKNOWN: today's outcome (the trunk's too). A fix changes it: update this pin with the fix"
        XCTAssertTrue(deleted)
        XCTAssertFalse(purged, pin)
        XCTAssertEqual(left, 1, pin)
        XCTAssertEqual(error, WorkspaceFoundationError.unknown.localizedDescription, pin)
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    func testC3DuplicateOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("duplicate") { $0.tasks.duplicate(taskIDs: [$0.ids[7]]) != nil }
    }

    func testC3MoveOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("move") { rig in
            // The group as presented, without the deleted task the failed reads left in it: its last task moves first.
            let group = rig.tasks.orderGroup(of: try XCTUnwrap(rig.tasks.task(withID: rig.ids[7]))).map(\.id).filter { $0 != rig.ids[3] }
            let mover = try XCTUnwrap(group.last)
            let moved = rig.tasks.move(taskID: mover, toIndex: 0)
            let first = rig.tasks.orderGroup(of: try XCTUnwrap(rig.tasks.task(withID: mover))).first?.id
            print("C3_MOVE group=\(group.count) moved=\(moved) mover_first=\(first == mover)")
            XCTAssertEqual(first, mover, "move: the task ends first")
            return moved
        }
    }

    func testC3CompleteFamilyOnTheSpentContext() async throws {
        try await afterUnresolvedDelete("completeFamily") { $0.tasks.completeFamily(taskID: $0.ids[7]) }
    }

    func testC3MoveSubtaskOnTheSpentContext() async throws {
        var subtask: UUID?
        try await afterUnresolvedDelete("moveSubtask", setup: { rig in
            _ = try XCTUnwrap(rig.tasks.create(title: "First subtask", parentID: rig.ids[8]))
            subtask = try XCTUnwrap(rig.tasks.create(title: "Second subtask", parentID: rig.ids[8])).id
        }) { rig in
            // Whichever subtask sorts last moves up one (equal times sort by UUID, so creation order is not the order).
            let siblings = rig.tasks.subtasks(of: rig.ids[8]).map(\.id)
            XCTAssertEqual(siblings.count, 2)
            XCTAssertTrue(siblings.contains(try XCTUnwrap(subtask)))
            let mover = try XCTUnwrap(siblings.last)
            let moved = rig.tasks.moveSubtask(taskID: mover, by: -1)
            let after = rig.tasks.subtasks(of: rig.ids[8]).map(\.id)
            print("C3_MOVE_SUBTASK moved=\(moved) mover_first=\(after.first == mover)")
            XCTAssertEqual(after.first, mover, "moveSubtask: the subtask ends first")
            return moved
        }
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
        // Arm "none" is the control: the same save and preserve with no fault. The faulted arm must write what it
        // writes: the same number of journaled writes (receipts) across save and preserve, and the same revision count.
        var control: (receipts: Int, revisions: [Int64])?
        for seam in ["none", "owner"] {
            let rig = try await makeRig()
            XCTAssertTrue(rig.controller.newNote())
            let session = try XCTUnwrap(rig.controller.active)
            session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
                                       with: NSAttributedString(string: "Written once"), name: "Typing")
            let stateBeforeSave = "\(session.state)"
            let receiptsBefore = try ModelContext(rig.container).fetchCount(FetchDescriptor<OperationReceipt>())
            if seam == "owner" { WorkspaceLegacyBridge.postCommitOwnerReadFailures = 1 }
            let first = rig.controller.save(session)
            let seamUsed = seam == "none" || WorkspaceLegacyBridge.postCommitOwnerReadFailures == 0
            WorkspaceLegacyBridge.postCommitOwnerReadFailures = 0
            let stateAfterFirst = "\(session.state)"
            let noteID = session.noteID
            func revisions() throws -> [String] {
                try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
                    .map { "\($0.revisionToken) \($0.revision)" }
            }
            let afterFirst = try revisions()
            let preserved = rig.controller.preserve(session)
            let afterPreserve = try revisions()
            let rows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            let receipts = try ModelContext(rig.container).fetchCount(FetchDescriptor<OperationReceipt>()) - receiptsBefore
            print("C2_NOTE \(seam) state_before=\(stateBeforeSave) persisted=\(session.isPersisted) seam_used=\(seamUsed) first=\(first) "
                + "state_after_first=\(stateAfterFirst) preserved=\(preserved) state=\(session.state) rows=\(rows.count) "
                + "receipts=\(receipts) revisions=\(rows.map(\.revision)) control=\(control.map { "\($0.receipts) \($0.revisions)" } ?? "-") "
                + "error=\(rig.notes.lastErrorMessage ?? "nil") duplicates=\(try duplicateRows(rig.container))")
            XCTAssertTrue(seamUsed, seam)
            XCTAssertEqual(rows.count, 1, "\(seam): the note is durable once")
            XCTAssertTrue(first, "\(seam): a durable note save is reported as saved")
            XCTAssertTrue(preserved, "\(seam): preserve succeeds")
            XCTAssertTrue(session.isPersisted, seam)
            XCTAssertFalse(NoteSessionPolicy.hasPendingWork(session.state), "\(seam): the session ends saved")
            XCTAssertEqual(afterPreserve, afterFirst, "\(seam): preserve writes the note no second time")
            XCTAssertEqual(try duplicateRows(rig.container), [], seam)
            if let control {
                XCTAssertEqual(receipts, control.receipts, "The faulted save writes as many times as the control")
                XCTAssertEqual(rows.map(\.revision), control.revisions, "The faulted save reaches the control's revision")
            } else {
                control = (receipts, rows.map(\.revision))
            }
            await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
        }
    }

    /// The Notes side of R-2: a journaled note save commits, and the store's presentation reload fails, so `save`
    /// returns true and keeps its staging context. The next note command stages on it. Every id keeps one row.
    func testC3NoteCommandAfterAFailedReloadWritesOneRowPerID() async throws {
        let rig = try await makeRig()
        let note = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 0" })
        // Every presentation read after the delete's commit fails: its own, the library's and the controller's.
        rig.notes.reloadFailures = 3
        let deleted = rig.notes.delete(note)
        let reloadsFailed = 3 - rig.notes.reloadFailures
        rig.notes.reloadFailures = 0
        let spentBeforeRename = WorkspaceLegacyBridge.isSpent(rig.notes.modelContext)
        let other = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 1" })
        let otherID = other.id
        let renamed = rig.notes.update(other, title: "Note 1 after a failed reload")
        let titles = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == otherID })).map(\.title)
        print("C3_NOTE reloads_failed=\(reloadsFailed) deleted=\(deleted) spent_before_rename=\(spentBeforeRename) renamed=\(renamed) "
            + "titles=\(titles) unsaved=\(rig.notes.lastSpentContextUnsaved ?? ["nil"]) "
            + "error=\(rig.notes.lastErrorMessage ?? "nil") duplicates=\(try duplicateRows(rig.container))")
        XCTAssertTrue(deleted, "The delete is durable and reported done")
        XCTAssertTrue(spentBeforeRename, "The rename meets the spent context")
        XCTAssertTrue(renamed)
        XCTAssertEqual(titles, ["Note 1 after a failed reload"], "The rename is durable")
        XCTAssertEqual(rig.notes.lastSpentContextUnsaved, [], "The rename replaced the spent context, discarding nothing unsaved")
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
    /// what is durable, whether the store reads the bytes back, and what the store reports. Whether a cached file is
    /// on disk is printed beside the control's, not required. Returns that observation.
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
        // Observed only: whether the file store holds a cached file (Locate repairs the row's payload).
        let url = try? await rig.files.verifiedMaterializedURL(
            for: AttachmentFileReference(id: id, digest: digest, filename: "original.pdf", payload: nil))
        let onDisk = url.flatMap { try? Data(contentsOf: $0) } == file.bytes
        // What the app reads back: the store's verified bytes for the attachment (the open path).
        let bytesReadable = await rig.notes.verifiedAttachmentBytes(id)?.data == file.bytes
        print("C3_IMPORT \(entry) seam=\(seam) seam_used=\(seamUsed) reported=\(reported) rows=\(rows.count) durable=\(durable) "
            + "file_on_disk=\(onDisk) bytes_readable=\(bytesReadable) control_file_on_disk=\(control.map(String.init) ?? "-") "
            + "failure=\(rig.notes.attachmentFailures[id] ?? "nil") error=\(rig.notes.lastErrorMessage ?? "nil")")
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
        XCTAssertTrue(seamUsed, "\(entry), \(seam): the fault fired on this entry's save")
        XCTAssertEqual(rows.count, 1, "\(entry), \(seam): one physical row")
        XCTAssertEqual(durable, 1, "\(entry), \(seam): the import is durable once")
        XCTAssertTrue(bytesReadable, "\(entry), \(seam): the located bytes can be read back")
        XCTAssertTrue(reported, "\(entry), \(seam): a durable import is reported as done")
        return onDisk
    }

    private func durableImportCases(_ entry: String, run: (Rig, MissingFile) async throws -> Bool) async throws {
        let control = try await durableImport(entry, seam: "none", run: run)
        // Locate saves through the journaled path only (run durb1: seam=plain seam_used=false on both entries), so the
        // plain after-commit fault has no save to fire on here; `C1_PLAIN` covers that path.
        try await durableImport(entry, seam: "owner", control: control, run: run)
    }

    func testC3DurableLocateAttachmentIsReadableAndReportedDone() async throws {
        try await durableImportCases("locateAttachment") { rig, file in
            let shown = try XCTUnwrap(rig.notes.attachments(for: file.noteID).first { $0.id == file.attachmentID })
            return await rig.notes.locateAttachment(shown, at: file.source)
        }
    }

    func testC3DurableLocatePlacementIsReadableAndReportedDone() async throws {
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
            XCTAssertTrue(saved, "\(label): the durable editor save is reported done")
            XCTAssertTrue(renamed, "\(label): the next command works")
            XCTAssertEqual(rig.notes.lastSpentContextUnsaved, [], "\(label): the spent context is replaced, discarding nothing unsaved")
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
    /// Astra round 5 (9952bb65), HOLD 6: the second row is a true copy, `dependencyOwnersData` included (deletion
    /// always encodes it, and restore requires the rows to agree on it). Undo must then restore and retire both
    /// physical records; a restore that retires only one of them fails here. Purge, when it succeeds, reaches both
    /// records; a purge refusal changes no row (as before this repair).
    func testC8RestoreAndPurgeOnAStoreThatHoldsTwoPreservationRows() async throws {
        for command in ["undo", "purge"] {
            let run = try await twoPreservationRows(command, copyingDependencyOwners: true)
            if command == "undo" {
                XCTAssertFalse(run.refused, "undo: two agreeing preservation rows are restored, not refused")
                XCTAssertEqual(run.records, 2, "undo: both physical records remain")
                XCTAssertEqual(run.retired, 2, "undo: both physical records are retired")
                XCTAssertEqual(run.purged, 0, "undo: neither record is marked purged")
                XCTAssertGreaterThan(run.taskRows, 0, "undo: the task's rows remain")
                XCTAssertEqual(run.taskLive, run.taskRows, "undo: every row of the task is live again")
            } else if run.refused {
                XCTAssertEqual(run.after, run.before, "purge: a refusal changes no row")
            } else {
                XCTAssertEqual(run.retired, 2, "purge: both physical records are retired")
                XCTAssertEqual(run.purged, 2, "purge: both physical records are marked purged")
                XCTAssertEqual(run.taskRows, 0, "purge: the task's rows are gone")
            }
        }
    }

    /// The fixture before HOLD 6, kept as its own case: the copy omits `dependencyOwnersData`, so the two rows
    /// disagree. Undo is refused and changes no row; purge is either refused unchanged or reaches both records.
    func testC8DivergentPreservationRowsAreRefusedUnchanged() async throws {
        for command in ["undo", "purge"] {
            let run = try await twoPreservationRows(command, copyingDependencyOwners: false)
            if command == "undo" { XCTAssertTrue(run.refused, "undo: divergent preservation rows are refused") }
            if run.refused {
                XCTAssertEqual(run.after, run.before, "\(command): a refusal changes no row")
            } else {
                XCTAssertEqual(run.retired, 2, "\(command): never one of the two records")
                XCTAssertEqual(run.purged, 2, "\(command): never one of the two records")
            }
        }
    }

    private func twoPreservationRows(_ command: String, copyingDependencyOwners: Bool) async throws
        -> (refused: Bool, before: String, after: String, records: Int, retired: Int, purged: Int, taskRows: Int, taskLive: Int) {
        let rig = try await makeRig()
        let id = rig.ids[3]
        XCTAssertTrue(rig.library.deleteTasks([id]).isApplied)
        let seed = ModelContext(rig.container)
        let original = try XCTUnwrap(try seed.fetch(
            FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.rootID == id })).first)
        let copy = TaskDeletionPreservation(id: original.id, rootID: original.rootID, deletedAt: original.deletedAt,
            capturedAt: original.capturedAt, provenance: original.provenance, snapshot: original.snapshot)
        if copyingDependencyOwners { copy.dependencyOwnersData = original.dependencyOwnersData }
        seed.insert(copy)
        try seed.save()
        func read() throws -> (records: [TaskDeletionPreservation], rows: [TaskItem]) {
            let context = ModelContext(rig.container)
            return (try context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.rootID == id })),
                    try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })))
        }
        func facts() throws -> String {
            let (records, rows) = try read()
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
        let (records, rows) = try read()
        print("C8_TWO_ROWS \(command) copied_dependency_owners=\(copyingDependencyOwners) result=\(result) "
            + "before[\(before)] after[\(after)] error=\(rig.tasks.lastErrorMessage ?? "nil") "
            + "duplicates=\(try duplicateRows(rig.container))")
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
        return (refused, before, after, records.count, records.filter { $0.retiredAt != nil }.count,
                records.filter { $0.purgedAt != nil }.count, rows.count, rows.filter { $0.deletedAt == nil }.count)
    }

    /// Generated data: one note id with two identical physical rows, as R-2 leaves a re-proposed insert. A
    /// characterization of what such a note does (lead, 21:18): it is listed once, a rename reaches every replica, it
    /// opens, and Delete Note reaches every replica. No repair.
    func testC8NoteWithTwoPhysicalRowsOpensEditsAndDeletes() async throws {
        let twinID = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let rig = try await makeRig(seed: { seed in
            for _ in 0..<2 {
                let twin = NoteItem(id: twinID, title: "Twin", body: "Body", createdAt: date)
                twin.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Twin"), .text("Body")]))
                seed.insert(twin)
            }
        })
        func rows() throws -> [NoteItem] {
            try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == twinID }))
        }
        let listed = rig.notes.notes.filter { $0.id == twinID }.count
        let note = try XCTUnwrap(rig.notes.notes.first { $0.id == twinID })
        let renamed = rig.notes.update(note, title: "Twin renamed")
        let titles = try rows().map(\.title).sorted()
        // As in the app: the note is opened, then deleted from the page (Delete Note), after recovery work, which
        // leaves the editor first.
        let opened = rig.controller.open(noteID: twinID)
        let session = rig.controller.active
        let deleted = await rig.controller.deleteNoteDurably(noteID: twinID)
        let notice = session?.noticeValue.map { "\($0.kind): \(session?.notice ?? "")" } ?? "nil"
        let afterDelete = try rows()
        print("C8_TWO_NOTE_ROWS rows=\(afterDelete.count) listed=\(listed) opened=\(opened) renamed=\(renamed) "
            + "titles=\(titles) deleted=\(deleted) deleted_rows=\(afterDelete.filter { $0.deletedAt != nil }.count) "
            + "error=\(rig.notes.lastErrorMessage ?? "nil") notice=\(notice)")
        XCTAssertEqual(afterDelete.count, 2, "Characterization only: both physical rows remain")
        XCTAssertEqual(listed, 1, "Listed once")
        XCTAssertTrue(opened, "Opens")
        XCTAssertTrue(renamed)
        XCTAssertEqual(titles, ["Twin renamed", "Twin renamed"], "A rename reaches every replica")
        XCTAssertTrue(deleted)
        XCTAssertEqual(afterDelete.filter { $0.deletedAt != nil }.count, 2, "A delete reaches every replica")
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    // MARK: Astra round 1 on this branch (gpt-6.2-astra, 19 Nov)

    /// A1 (finding 1), the bridge's own guard: declaring a read set on a spent context is refused at once
    /// (WorkspaceLegacyBridge.withDeclaredReadSet), so tokens never ride on a context the write will not commit from.
    /// The agent tools prepare before this point; `testA1AgentToolEditStartingOnASpentNoteContext` covers that path.
    func testA1AnAgentEditKeepsItsDeclaredReadSetWhenTheNoteContextIsSpent() async throws {
        let rig = try await makeRig()
        guard case let .success(created) = rig.notes.createDocumentNote(
            id: UUID(), document: NoteDocument(blocks: [.text("Agent target"), .text("Before")])) else { return XCTFail("create") }
        let noteID = created.noteID
        let owner = WorkspaceOwner(entity: .task, id: rig.ids[5])
        let token = try XCTUnwrap(WorkspaceModelToken.read(owners: [owner], in: ModelContext(rig.container))[owner])
        let base = try XCTUnwrap(rig.notes.note(withID: noteID)).revisionToken
        let other = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 0" })
        rig.notes.reloadFailures = 3
        XCTAssertTrue(rig.notes.delete(other))
        let reloadsFailed = 3 - rig.notes.reloadFailures
        rig.notes.reloadFailures = 0
        let spent = WorkspaceLegacyBridge.isSpent(rig.notes.modelContext)
        XCTAssertTrue(rig.tasks.rename(try XCTUnwrap(rig.tasks.task(withID: rig.ids[5])), to: "Changed after the agent read"))
        var outcome = "nil"
        do {
            let result = try WorkspaceLegacyBridge.withDeclaredReadSet(tokens: [token], scopes: [], in: rig.notes.modelContext) {
                rig.notes.agentWrite(noteID: noteID, baseRevisionToken: base,
                                     document: NoteDocument(blocks: [.text("Agent target"), .text("Agent edit")]),
                                     agentName: "Agent", disposition: .direct)
            }
            if case .success(.applied) = result { outcome = "applied" } else { outcome = "refused \(result)" }
        } catch { outcome = "threw \(error)" }
        let bodies = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })).map(\.body)
        print("A1_DECLARED reloads_failed=\(reloadsFailed) spent=\(spent) outcome=\(outcome) bodies=\(bodies)")
        XCTAssertTrue(spent, "The edit meets a spent note context")
        XCTAssertFalse(outcome == "applied", "An edit whose declared read changed after the read does not commit")
        XCTAssertFalse(bodies.contains { $0.contains("Agent edit") }, "The note keeps its body")
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    /// A1 through the agent tool (Astra rounds 2 and 3). The note store's context is spent (a journaled delete whose
    /// every reload failed) and its presentation is behind: the task's note changed in another context since its last
    /// read. The agent reads the workspace (current revision and tokens) and writes with update_note. The tool decides
    /// staleness from the presented revision, before the store replaces its context (the in-app agent's Undo snapshot
    /// is taken from that same presentation), so the first write must not apply and the body on disk stays as it was.
    /// That attempt replaces the spent context; the agent's retry with the same arguments then meets current state.
    /// Arm "current": nothing changes after the read, so the retry applies. Arm "association": the task gains an
    /// association after the read, so the retry waits for review and the body on disk stays as it was.
    func testA1AgentToolEditStartingOnASpentNoteContext() async throws {
        for arm in ["current", "association"] {
            let rig = try await makeRig()
            await rig.controller.waitForRecoveryWork()
            let taskID = rig.ids[3], noteID = rig.writingID
            let tools = AgentTaskTools(store: rig.tasks, noteStore: rig.notes, library: rig.library)
            tools.notesController = { rig.controller }
            let other = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 0" })
            rig.notes.reloadFailures = 3
            XCTAssertTrue(rig.notes.delete(other))
            let reloadsFailed = 3 - rig.notes.reloadFailures
            rig.notes.reloadFailures = 0
            let changed = ModelContext(rig.container)
            for row in try changed.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) {
                row.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Open task 3"), .text("Changed elsewhere")],
                                                                       requires: ["taskNote"]))
                row.body = "Changed elsewhere"; row.revision += 1; row.revisionID = UUID()
            }
            try changed.save()
            let spent = WorkspaceLegacyBridge.isSpent(rig.notes.modelContext)
            let workspace = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(
                tools.call(name: "get_task_workspace", arguments: ["id": taskID.uuidString]).utf8)) as? [String: Any])
            let revision = try XCTUnwrap(workspace["note_revision"] as? String)
            func durable() throws -> [NoteItem] {
                try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            }
            let durableRevision = try XCTUnwrap(try durable().first?.revisionToken)
            let presentedBehind = rig.notes.note(withID: noteID)?.revisionToken != durableRevision
            if arm == "association" {
                let context = ModelContext(rig.container)
                context.insert(TaskNoteAssociation(taskID: taskID, noteID: noteID))
                try context.save()
            }
            let arguments: [String: Any] = [
                "id": noteID.uuidString, "body": "Agent edit", "base_revision": revision,
                "base_note_token": try XCTUnwrap(workspace["note_token"] as? String),
                "base_association_token": try XCTUnwrap(workspace["association_token"] as? String)]
            var pendingEditID: String?
            func attempt() -> String {
                pendingEditID = nil
                do {
                    let reply = try tools.call(name: "update_note", arguments: arguments)
                    let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
                    pendingEditID = object?["pending_edit"] as? String
                    return (object?["status"] as? String) ?? reply
                } catch { return "threw \(error)" }
            }
            func proposals() throws -> [NotePendingEdit] {
                try ModelContext(rig.container).fetch(FetchDescriptor<NotePendingEdit>()).filter { $0.noteID == noteID }
            }
            let first = attempt()
            let proposalsAfterFirst = try proposals().count
            let bodiesAfterFirst = try durable().map(\.body)
            let spentAfterFirst = WorkspaceLegacyBridge.isSpent(rig.notes.modelContext)
            let retry = attempt()
            let bodies = try durable().map(\.body)
            let pending = try proposals()
            let proposedBodies = pending.map { durableDocument($0.proposedContent).map { Array($0.blocks.dropFirst().map(\.text)) } }
            print("A1_PROPOSALS \(arm) after_first=\(proposalsAfterFirst) after_retry=\(pending.count) "
                + "retry_edit_matches=\(pending.map(\.id.uuidString) == [pendingEditID].compactMap { $0 }) proposed_bodies=\(proposedBodies)")
            print("A1_TOOL \(arm) reloads_failed=\(reloadsFailed) spent=\(spent) presented_behind=\(presentedBehind) "
                + "agent_read_current=\(revision == durableRevision) first=\(first) bodies_after_first=\(bodiesAfterFirst) "
                + "spent_after_first=\(spentAfterFirst) retry=\(retry) bodies=\(bodies) pending=\(pending.map { "\($0.needsReview)" })")
            XCTAssertTrue(spent, "\(arm): the tool starts on a spent note context")
            XCTAssertTrue(presentedBehind, "\(arm): the store's presentation is behind")
            XCTAssertEqual(revision, durableRevision, "\(arm): the agent read the current revision")
            // r7 (pr40-wall-design.md): the tool's entry replaced the spent context, so the write is refused once.
            XCTAssertTrue(first.contains(R7Rows.refusal), "\(arm): the first write is refused at its entry, with a retryable reason")
            XCTAssertEqual(proposalsAfterFirst, 0, "\(arm): the refused write leaves no proposal")
            XCTAssertEqual(bodiesAfterFirst, ["Changed elsewhere"], "\(arm): the body on disk stays as it was")
            XCTAssertFalse(spentAfterFirst, "\(arm): the first attempt replaced the spent context")
            if arm == "current" {
                XCTAssertEqual(retry, "applied", "The retry meets current state and applies")
                XCTAssertTrue(!bodies.isEmpty && bodies.allSatisfy { $0.contains("Agent edit") }, "Its body reaches disk")
                XCTAssertTrue(pending.isEmpty, "An applied edit leaves no proposal")
            } else {
                XCTAssertEqual(retry, "pending", "An edit whose read changed waits for review")
                XCTAssertEqual(bodies, ["Changed elsewhere"], "The stored body stays as it was")
                let editID = try XCTUnwrap(pendingEditID, "The pending reply names its proposal")
                XCTAssertEqual(pending.map(\.id.uuidString), [editID], "Exactly one proposal, the one the reply names")
                XCTAssertTrue(pending.allSatisfy(\.needsReview))
                XCTAssertEqual(proposedBodies, [["Agent edit"]], "The proposal holds the agent's edit")
            }
            await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
        }
    }

    /// Astra round 3, finding 1: the in-app agent's Undo of a note edit. The agent records the note for Undo from the
    /// store's presentation before the tool runs. Arm "behind": the store's context is spent and its presentation
    /// behind (it shows "Before"; another context saved "Saved elsewhere"). An update_note with the current revision is
    /// refused as stale, records nothing for Undo, and the stored document stays "Saved elsewhere". Arm "fresh" is the
    /// control: the store has refreshed, so the same call applies, and its Undo restores "Saved elsewhere", never "Before".
    func testA12AgentUndoNeverRestoresAnOlderBodyThanItsEditReplaced() async throws {
        for arm in ["behind", "fresh"] {
            let rig = try await makeRig()
            await rig.controller.waitForRecoveryWork()
            guard case let .success(created) = rig.notes.createDocumentNote(
                id: UUID(), document: NoteDocument(blocks: [.text("Undo target"), .text("Before")])) else { return XCTFail("create") }
            let noteID = created.noteID
            let tools = AgentTaskTools(store: rig.tasks, noteStore: rig.notes, library: rig.library)
            tools.notesController = { rig.controller }
            let actions = AgentActions(tasks: tools)
            rig.notes.reloadFailures = 3
            XCTAssertTrue(rig.notes.delete(try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 0" })))
            rig.notes.reloadFailures = 0
            let spent = WorkspaceLegacyBridge.isSpent(rig.notes.modelContext)
            let changed = ModelContext(rig.container)
            for row in try changed.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) {
                row.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Undo target"), .text("Saved elsewhere")]))
                row.body = "Saved elsewhere"; row.revision += 1; row.revisionID = UUID()
            }
            try changed.save()
            if arm == "fresh" { rig.notes.refresh() }
            func stored() throws -> [[String]?] {
                try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
                    .map { durableDocument($0.content)?.blocks.map(\.text) }
            }
            let revision = try XCTUnwrap(try ModelContext(rig.container).fetch(
                FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })).first?.revisionToken)
            let presentedBehind = rig.notes.note(withID: noteID)?.revisionToken != revision
            let request = actions.beginRequest(title: "Edit a note")
            var outcome = "nil"
            do {
                let call = try await actions.call(name: "update_note", arguments: [
                    "id": noteID.uuidString, "body": "Agent edit", "base_revision": revision], watching: false, requestID: request)
                if case let .performed(result) = call { outcome = "performed \(result.text)" } else { outcome = "\(call)" }
            } catch { outcome = "threw \(error)" }
            let afterAction = try stored()
            let steps = actions.changeSet(for: request)?.count ?? 0
            let undone = await actions.undo(changeSet: request)
            let afterUndo = try stored()
            print("A12_AGENT_UNDO \(arm) spent=\(spent) presented_behind=\(presentedBehind) outcome=\(outcome) "
                + "after_action=\(afterAction) steps=\(steps) undone=\(undone.undone) failures=\(undone.failures) after_undo=\(afterUndo)")
            XCTAssertTrue(spent, arm)
            if arm == "behind" {
                XCTAssertTrue(presentedBehind)
                XCTAssertTrue(outcome.contains("changed since"), "The edit is refused as stale, with a retryable reason")
                XCTAssertEqual(afterAction, [["Undo target", "Saved elsewhere"]], "The refused edit writes nothing")
                XCTAssertEqual(steps, 0, "A refused edit records nothing for Undo")
                XCTAssertEqual(undone.undone, 0)
            } else {
                XCTAssertFalse(presentedBehind, "After the refresh the presentation is current")
                XCTAssertTrue(outcome.hasPrefix("performed") && outcome.contains("applied"), "The edit applies")
                XCTAssertEqual(afterAction, [["Undo target", "Agent edit"]], "The agent's edit is stored")
                XCTAssertEqual(undone.undone, 1, "Undo takes back exactly the edit")
                XCTAssertEqual(undone.failures, [])
            }
            XCTAssertEqual(afterUndo, [["Undo target", "Saved elsewhere"]], "Undo never writes back a document older than the one the edit replaced")
            await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
        }
    }

    /// A3 (finding 3). Two agent proposals on one base. Leaving the note applies the first; with one injected failure
    /// that apply's reload fails. The second is now stale and must be marked for review, durably, with no refused save.
    /// Arm 0 is the control. The apply starts on a usable context (refreshed after the proposals were written).
    /// A bare note store, as NoteDocumentStoreTests applies proposals: in the panel-wired rig the control arm applied
    /// nothing (run dura2red on f9364f73: `failures=0 … applied=0 … error=The save could not be confirmed…`).
    func testA3ApplyingTwoProposalsAfterAFailedReloadMarksTheSecondForReview() async throws {
        for failures in [0, 1] {
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            let notes = NoteStore(container: container, now: { Date(timeIntervalSince1970: 1_700_000_000) },
                                  attachmentFileStore: makeTestAttachmentFileStore())
            await notes.waitForAttachmentReconciliation()
            struct Bare { let notes: NoteStore; let container: ModelContainer }
            let rig = Bare(notes: notes, container: container)
            guard case let .success(created) = rig.notes.createDocumentNote(
                id: UUID(), document: NoteDocument(blocks: [.text("Two proposals"), .text("Base")])) else { return XCTFail("create") }
            let noteID = created.noteID
            let base = try XCTUnwrap(rig.notes.note(withID: noteID)).revisionToken
            var proposalIDs: [String: UUID] = [:]
            for line in ["First", "Second"] {
                guard case let .success(.pending(editID)) = rig.notes.agentWrite(noteID: noteID, baseRevisionToken: base,
                    document: NoteDocument(blocks: [.text("Two proposals"), .text(line)]), agentName: "Agent",
                    disposition: .proposal) else { return XCTFail("proposal \(line)") }
                proposalIDs[line] = editID
            }
            let spentAfterProposals = WorkspaceLegacyBridge.isSpent(rig.notes.modelContext)
            rig.notes.refresh()
            let spentBeforeApply = WorkspaceLegacyBridge.isSpent(rig.notes.modelContext)
            let refusalsBefore = WorkspaceLegacyBridge.spentContextRefusals
            rig.notes.reloadFailures = failures
            let applied = rig.notes.applyPendingEdits(noteID: noteID)
            let reloadsFailed = failures - rig.notes.reloadFailures
            rig.notes.reloadFailures = 0
            let refusals = WorkspaceLegacyBridge.spentContextRefusals - refusalsBefore
            let pending = try ModelContext(rig.container).fetch(FetchDescriptor<NotePendingEdit>()).filter { $0.noteID == noteID }
            let bodies = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })).map(\.body)
            print("A3_PROPOSALS failures=\(failures) spent_after_proposals=\(spentAfterProposals) spent_before_apply=\(spentBeforeApply) "
                + "reloads_failed=\(reloadsFailed) applied=\(applied) refusals=\(refusals) pending=\(pending.map { "\($0.needsReview)" }) "
                + "bodies=\(bodies) error=\(rig.notes.lastErrorMessage ?? "nil")")
            XCTAssertFalse(spentBeforeApply, "\(failures): the apply starts on a usable context")
            XCTAssertEqual(reloadsFailed, failures, "\(failures): the injected reload failure fired")
            XCTAssertEqual(applied, 1, "\(failures)")
            XCTAssertEqual(pending.count, 1, "\(failures): the second proposal remains")
            XCTAssertEqual(pending.map(\.needsReview), [true], "\(failures): the stale second proposal is marked for review durably")
            XCTAssertEqual(refusals, 0, "\(failures): no save was refused on a spent context")
            // Equal timestamps order the two proposals by UUID, so either may apply first: the other must remain, unchanged.
            let noteRows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            let liveBlocks = noteRows.filter { $0.deletedAt == nil }.map { durableDocument($0.content)?.blocks.map(\.text) }
            let appliedLine = ["First", "Second"].first { liveBlocks == [["Two proposals", $0]] }
            let otherLine = appliedLine.flatMap { applied in ["First", "Second"].first { $0 != applied } }
            let remainingBlocks = pending.map { durableDocument($0.proposedContent)?.blocks.map(\.text) }
            print("A3_SURVIVOR failures=\(failures) live_blocks=\(liveBlocks) applied_line=\(appliedLine ?? "nil") "
                + "remaining_is_other=\(otherLine.map { pending.map(\.id) == [proposalIDs[$0]] } ?? false) remaining_blocks=\(remainingBlocks) "
                + "replaced_spent=\(rig.notes.lastSpentContextUnsaved.map { "\($0)" } ?? "nil")")
            XCTAssertNotNil(appliedLine, "\(failures): one live note holds exactly one proposal's document")
            if let otherLine {
                XCTAssertEqual(pending.map(\.id), [try XCTUnwrap(proposalIDs[otherLine])], "\(failures): the other proposal remains, by its ID")
                XCTAssertEqual(remainingBlocks, [["Two proposals", otherLine]], "\(failures): its proposed document is unchanged and readable")
            }
            await rig.notes.waitForAttachmentReconciliation()
        }
    }

    /// A4 (finding 4). A saved note is open with a file just added (unsaved). Deleting it first saves the editor (an
    /// inserting, journaled commit); with two injected failures that save's reloads fail, leaving the context spent. The
    /// delete must still reach every physical row with no refused save, record one Undo step, and Undo must bring the
    /// file back readable. Arm 0 is the control. Recovery work is drained first, so the delete meets no recovery hold.
    func testA4DeletingANoteWhoseEditorSaveSpendsTheContextDeletesIt() async throws {
        for failures in [0, 2] {
            let rig = try await makeRig()
            XCTAssertTrue(rig.controller.newNote())
            let session = try XCTUnwrap(rig.controller.active)
            XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0),
                                                     with: NSAttributedString(string: "Saved first"), name: "Typing"))
            XCTAssertTrue(rig.controller.save(session))
            await rig.controller.waitForRecoveryWork()
            let noteID = session.noteID
            let data = Data(repeating: 0x43, count: 2_048)
            let item = StagedNoteAttachment(id: UUID(), filename: "added.pdf", contentTypeIdentifier: "com.adobe.pdf",
                byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), data: data)
            session.engine.beginImageImport()
            XCTAssertTrue(session.engine.insertImportedObjects([.init(staged: item, pixelSize: nil)]))
            await rig.controller.waitForRecoveryWork()
            let stateBeforeDelete = "\(session.state)"
            let itemIDBefore = item.id
            let fileRowsBefore = try ModelContext(rig.container).fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == itemIDBefore })).count
            let stepsBefore = rig.library.undo.steps(in: .note(noteID), redo: false).count
            let refusalsBefore = WorkspaceLegacyBridge.spentContextRefusals
            rig.notes.reloadFailures = failures
            var deleted = rig.library.delete(AtticItemRef(.note, noteID))
            let reloadsFailed = failures - rig.notes.reloadFailures
            rig.notes.reloadFailures = 0
            if failures > 0 {
                // r7: the editor's save spent the context and the delete's entry replaced it, so the delete is refused
                // once (the text and the file are saved); repeated, it applies.
                let firstError = rig.notes.lastErrorMessage
                let firstRows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
                XCTAssertFalse(deleted, "\(failures): the first delete is refused")
                XCTAssertEqual(firstError, R7Rows.refusal, "\(failures): refused at its entry")
                XCTAssertTrue(!firstRows.isEmpty && firstRows.allSatisfy { $0.deletedAt == nil }, "\(failures): the refused delete wrote nothing")
                XCTAssertEqual(rig.library.undo.steps(in: .note(noteID), redo: false).count, stepsBefore, "\(failures): and recorded no step")
                deleted = rig.library.delete(AtticItemRef(.note, noteID))
            }
            let refusals = WorkspaceLegacyBridge.spentContextRefusals - refusalsBefore
            let replaced = rig.notes.lastSpentContextUnsaved
            let itemID = item.id
            let rows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            let fileRows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == itemID })).count
            let canUndo = rig.library.undo.canUndo(in: .note(noteID))
            let newSteps = rig.library.undo.steps(in: .note(noteID), redo: false).count - stepsBefore
            let undone = rig.library.undo(in: .note(noteID))
            await rig.notes.waitForAttachmentReconciliation()
            let bytes = await rig.notes.verifiedAttachmentBytes(itemID)?.data == data
            let restored = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            // Read from the restored rows themselves, not from the store's presentation.
            let restoredHoldsFile = !restored.isEmpty
                && restored.allSatisfy { durableDocument($0.content)?.attachmentIDs.contains(itemID) == true }
            print("A4_UNDO failures=\(failures) file_rows_before=\(fileRowsBefore) new_steps=\(newSteps) "
                + "restored_live=\(restored.filter { $0.deletedAt == nil }.count)/\(restored.count) restored_holds_file=\(restoredHoldsFile)")
            print("A4_NOTE_DELETE failures=\(failures) state_before=\(stateBeforeDelete) reloads_failed=\(reloadsFailed) "
                + "deleted=\(deleted) refusals=\(refusals) replaced_spent=\(replaced.map { "\($0)" } ?? "nil") rows=\(rows.count) "
                + "deleted_rows=\(rows.filter { $0.deletedAt != nil }.count) file_rows=\(fileRows) can_undo=\(canUndo) "
                + "undone=\(undone) bytes_after_undo=\(bytes) error=\(rig.notes.lastErrorMessage ?? "nil")")
            XCTAssertEqual(reloadsFailed, failures, "\(failures): the injected reload failures fired")
            XCTAssertTrue(deleted, "\(failures): the delete is done")
            XCTAssertEqual(refusals, 0, "\(failures): no save was refused on a spent context")
            XCTAssertFalse(rows.isEmpty)
            XCTAssertTrue(rows.allSatisfy { $0.deletedAt != nil }, "\(failures): every physical row is deleted")
            XCTAssertEqual(fileRows, 1, "\(failures): the added file was saved once")
            XCTAssertTrue(canUndo, "\(failures): the delete is one Undo step")
            XCTAssertEqual(fileRowsBefore, 0, "\(failures): the file was unsaved when the delete began")
            XCTAssertEqual(newSteps, 1, "\(failures): the delete added one Undo step")
            XCTAssertTrue(undone.isApplied, "\(failures): Undo restores the note")
            XCTAssertTrue(!restored.isEmpty && restored.allSatisfy { $0.deletedAt == nil }, "\(failures): the note is live again")
            XCTAssertTrue(restoredHoldsFile, "\(failures): the restored note's document holds the file")
            XCTAssertTrue(bytes, "\(failures): the restored note's file reads back")
            await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
        }
    }

    /// A5 (finding 5). A store command re-entered while a save is under way (here an empty purge, from the save's own
    /// tag-inventory callback) must not discard the staged rows of the save that called it.
    func testA5ACommandReenteredDuringASaveKeepsTheStagedRows() async throws {
        let rig = try await makeRig()
        var reentered = 0
        let store: TaskStore = rig.tasks
        store.tagInventoryWillSave = { _ in
            guard reentered == 0 else { return }
            reentered += 1
            _ = store.purgeDeleted(before: .distantPast)
        }
        let created = rig.tasks.create(title: "Created while a purge re-enters")
        store.tagInventoryWillSave = { _ in }
        let id = created?.id
        let rows = try id.map { id in try ModelContext(rig.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).count } ?? 0
        print("A5_REENTRY reentered=\(reentered) created=\(created != nil) rows=\(rows)")
        XCTAssertEqual(reentered, 1, "The purge ran inside the save")
        XCTAssertNotNil(created)
        XCTAssertEqual(rows, 1, "The created task is durable")
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    /// Astra round 2: an empty command, or an agent write whose disposition already refuses, touches nothing, as it
    /// did before the staging entry existed. On a spent context whose reload would fail, each returns its own result
    /// and the injected read failure stays unused.
    func testA10EmptyCommandsAndRefusalsReturnBeforeAnyRead() async throws {
        let rig = try await makeRig()
        rig.tasks.listRefreshFailures = 3
        XCTAssertTrue(rig.library.deleteTasks([rig.ids[3]]).isApplied)
        let taskReadsFailed = 3 - rig.tasks.listRefreshFailures
        rig.tasks.listRefreshFailures = 1
        let restored = rig.tasks.restoreToNow(taskIDs: [])
        let reopened = rig.tasks.reopen(taskIDs: [])
        let taskFailureUnused = rig.tasks.listRefreshFailures == 1
        rig.tasks.listRefreshFailures = 0

        let target = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 1" })
        let base = target.revisionToken
        rig.notes.reloadFailures = 3
        XCTAssertTrue(rig.notes.delete(try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 0" })))
        let spent = WorkspaceLegacyBridge.isSpent(rig.notes.modelContext)
        rig.notes.reloadFailures = 1
        let refused = rig.notes.agentWrite(noteID: target.id, baseRevisionToken: base,
                                           document: NoteDocument(blocks: [.text("Note 1"), .text("Refused")]),
                                           agentName: "Agent", disposition: .refuse("Refused before any read"))
        let refusedDelete = rig.notes.agentDelete(noteID: target.id, baseRevisionToken: base, agentName: "Agent",
                                                  disposition: .refuse("Delete refused before any read"))
        let noteFailureUnused = rig.notes.reloadFailures == 1
        rig.notes.reloadFailures = 0
        var deleteReason = "\(refusedDelete)"
        if case let .failure(.saveFailed(message)) = refusedDelete { deleteReason = message }
        var reason = "\(refused)"
        if case let .failure(.saveFailed(message)) = refused { reason = message }
        print("A10_EMPTY task_reads_failed=\(taskReadsFailed) restore_to_now=\(restored) reopen=\(reopened) "
            + "task_failure_unused=\(taskFailureUnused) note_spent=\(spent) refused_reason=\(reason) delete_reason=\(deleteReason) note_failure_unused=\(noteFailureUnused)")
        XCTAssertEqual(taskReadsFailed, 3, "The delete's reads failed, leaving the task context spent")
        XCTAssertTrue(restored, "An empty Restore to Now succeeds")
        XCTAssertTrue(reopened, "An empty Reopen succeeds")
        XCTAssertTrue(taskFailureUnused, "Neither empty command read the store")
        XCTAssertTrue(spent)
        XCTAssertEqual(reason, "Refused before any read", "A refused agent write reports its own reason")
        XCTAssertEqual(deleteReason, "Delete refused before any read", "A refused agent delete reports its own reason")
        XCTAssertTrue(noteFailureUnused, "The refused agent write read nothing")
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    /// Astra round 2, the third deletion caller. An agent created a task's note; Undo removes it (it detaches from the
    /// task and goes to Recently Deleted). Preparing that deletion settles every open editor of the task's family: here
    /// a subtask's writing, open with a file just added, so its save is an inserting journaled commit. With two injected
    /// failures that save's reloads fail. Undo must still remove the note with no refused save, and the subtask's file
    /// must be saved once. Arm 0 is the control.
    func testA11UndoingAnAgentCreatedTaskNoteWhoseFamilyEditorSaveSpendsTheContext() async throws {
        for failures in [0, 2] {
            let rig = try await makeRig()
            let parentID = rig.ids[8]
            let child = try XCTUnwrap(rig.tasks.create(title: "Child with writing", parentID: parentID))
            let childNoteID = UUID()
            let seed = ModelContext(rig.container)
            let childNote = NoteItem(id: childNoteID, title: "Child with writing", body: "Child", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            childNote.taskID = child.id
            childNote.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Child with writing"), .text("Child")], requires: ["taskNote"]))
            seed.insert(childNote)
            try seed.save()
            rig.notes.refresh()
            let tools = AgentTaskTools(store: rig.tasks, noteStore: rig.notes, library: rig.library)
            tools.notesController = { rig.controller }
            _ = try tools.call(name: "create_note", arguments: ["title": "Agent note", "body": "Draft", "task_id": parentID.uuidString])
            let agentNote = try XCTUnwrap(rig.notes.notes.first { $0.taskID == parentID })
            let agentNoteID = agentNote.id
            let revision = agentNote.revisionToken
            let metadata = try XCTUnwrap(rig.notes.agentCreatedNoteMetadata(agentNoteID))
            let opened = rig.controller.open(noteID: childNoteID)
            let session = try XCTUnwrap(rig.controller.active)
            XCTAssertEqual(session.noteID, childNoteID)
            let data = Data(repeating: 0x44, count: 2_048)
            let item = StagedNoteAttachment(id: UUID(), filename: "child.pdf", contentTypeIdentifier: "com.adobe.pdf",
                byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), data: data)
            session.engine.beginImageImport()
            XCTAssertTrue(session.engine.insertImportedObjects([.init(staged: item, pixelSize: nil)]))
            await rig.controller.waitForRecoveryWork()
            let itemIDBefore = item.id
            let fileRowsBefore = try ModelContext(rig.container).fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == itemIDBefore })).count
            let liveLinksBefore = Set(try ModelContext(rig.container).fetch(FetchDescriptor<TaskNoteAssociation>(
                predicate: #Predicate { $0.noteID == agentNoteID })).filter { $0.detachedAt == nil }.map(\.id))
            let refusalsBefore = WorkspaceLegacyBridge.spentContextRefusals
            rig.notes.reloadFailures = failures
            var undone = rig.notes.undoAgentCreatedNote(agentNoteID, revision: revision, metadata: metadata)
            let reloadsFailed = failures - rig.notes.reloadFailures
            rig.notes.reloadFailures = 0
            if failures > 0 {
                // r7: the family editor's save spent the context and the deletion's entry replaced it, so Undo is
                // refused once (the subtask's file is saved); repeated, it applies.
                let firstError = rig.notes.lastErrorMessage
                let firstRows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == agentNoteID }))
                XCTAssertFalse(undone, "\(failures): the first Undo is refused")
                XCTAssertEqual(firstError, R7Rows.refusal, "\(failures): refused at its entry")
                XCTAssertTrue(!firstRows.isEmpty && firstRows.allSatisfy { $0.deletedAt == nil }, "\(failures): the refused Undo wrote nothing")
                undone = rig.notes.undoAgentCreatedNote(agentNoteID, revision: revision, metadata: metadata)
            }
            let refusals = WorkspaceLegacyBridge.spentContextRefusals - refusalsBefore
            let itemID = item.id
            let agentRows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == agentNoteID }))
            let fileRows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == itemID }))
            let parentRows = try ModelContext(rig.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == parentID }))
            let links = try ModelContext(rig.container).fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == agentNoteID }))
            await rig.notes.waitForAttachmentReconciliation()
            let childBytes = await rig.notes.verifiedAttachmentBytes(itemID)?.data == data
            print("A11_FACTS failures=\(failures) file_rows_before=\(fileRowsBefore) parent_live=\(parentRows.filter { $0.deletedAt == nil }.count)/\(parentRows.count) "
                + "live_links_before=\(liveLinksBefore.count) links=\(links.count) links_detached=\(links.filter { $0.detachedAt != nil }.count) child_bytes=\(childBytes) "
                + "replaced_spent=\(rig.notes.lastSpentContextUnsaved.map { "\($0)" } ?? "nil")")
            print("A11_UNDO_CREATED failures=\(failures) opened=\(opened) reloads_failed=\(reloadsFailed) undone=\(undone) "
                + "refusals=\(refusals) agent_rows=\(agentRows.count) agent_deleted=\(agentRows.filter { $0.deletedAt != nil }.count) "
                + "agent_detached=\(agentRows.filter { $0.taskID == nil }.count) child_file_rows=\(fileRows.count) "
                + "child_file_note=\(fileRows.allSatisfy { $0.noteID == childNoteID }) error=\(rig.notes.lastErrorMessage ?? "nil")")
            XCTAssertTrue(opened, "\(failures): the subtask's writing opens")
            XCTAssertEqual(reloadsFailed, failures, "\(failures): the injected reload failures fired")
            XCTAssertTrue(undone, "\(failures): Undo removes the agent's note")
            XCTAssertEqual(refusals, 0, "\(failures): no save was refused on a spent context")
            XCTAssertFalse(agentRows.isEmpty)
            XCTAssertTrue(agentRows.allSatisfy { $0.deletedAt != nil && $0.taskID == nil }, "\(failures): every row is deleted and detached")
            XCTAssertEqual(fileRows.count, 1, "\(failures): the subtask's file is saved once")
            XCTAssertTrue(fileRows.allSatisfy { $0.noteID == childNoteID }, "\(failures): it stays with the subtask's writing")
            XCTAssertEqual(fileRowsBefore, 0, "\(failures): the subtask's file was unsaved when Undo began")
            XCTAssertTrue(!parentRows.isEmpty && parentRows.allSatisfy { $0.deletedAt == nil }, "\(failures): the parent task stays")
            XCTAssertFalse(liveLinksBefore.isEmpty, "\(failures): the agent's note was linked to the parent before Undo")
            XCTAssertTrue(liveLinksBefore.isSubset(of: Set(links.map(\.id))), "\(failures): Undo keeps the association rows")
            XCTAssertTrue(links.allSatisfy { $0.detachedAt != nil }, "\(failures): every association of the note is detached")
            XCTAssertTrue(childBytes, "\(failures): the subtask's file reads back")
            await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
        }
    }

    /// A9 (finding 9). The spent-context diagnostic compares staged rows with durable rows as multisets: two staged
    /// copies with one durable copy is one row not durable.
    func testA9TheDiagnosticCountsIdenticalStagedReplicas() {
        let fields = ["title": Data("Same".utf8)]
        XCTAssertTrue(WorkspaceLegacyBridge.stagedRowsMissing(staged: [fields, fields], durable: [fields]),
                      "Two staged copies, one durable: one is missing")
        XCTAssertFalse(WorkspaceLegacyBridge.stagedRowsMissing(staged: [fields], durable: [fields]))
        XCTAssertFalse(WorkspaceLegacyBridge.stagedRowsMissing(staged: [fields, fields], durable: [fields, fields]))
    }
}

/// The document a stored row holds, decoded from its own bytes (not from a store's presentation).
private func durableDocument(_ data: Data?) -> NoteDocument? {
    guard let data, case let .editable(document) = NoteContentCodec.decode(data) else { return nil }
    return document
}

// R5-SHARED-BEGIN
/// Astra round 5 on 9952bb65, HOLDs 2–5: red tests for narrowing only (no fix in this pull request). This class uses
/// no PR 40 symbol: the same text runs on the trunk, where `R5Seams` has trunk bodies. "spent" leaves the note store's
/// context spent with its presentation behind (PR 40 only); "behind" leaves the presentation behind an outside write
/// with no spent context, as the trunk does.
@MainActor
final class DurableSaveR5NarrowingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        R5Seams.resetFamilyGuard()
    }

    override func tearDown() {
        R5Seams.assertFamilyGuard()
        R5Seams.reset()
        super.tearDown()
    }

    private struct Rig {
        let container: ModelContainer
        let tasks: TaskStore
        let notes: NoteStore
        let library: AtticLibrary
        let controller: NotesPageController
        let victim: NoteItem
    }

    /// Runs `mark` once, right after the next store save, when armed.
    private final class Between {
        var armed = false
        var marked = false
        var mark: (() throws -> Void)?
    }

    private final class Clock {
        var seconds: TimeInterval = 1_700_000_000
        func next() -> Date { seconds += 1; return Date(timeIntervalSince1970: seconds) }
    }

    private func makeRig() async throws -> Rig {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let seed = ModelContext(container)
        for index in 0..<3 { seed.insert(NoteItem(title: "Note \(index)", body: "Body", createdAt: date)) }
        try seed.save()
        let files = TaskImageFiles(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("R5Rig-\(UUID())"))
        let tasks = TaskStore(container: container, now: { date }, taskImageFiles: files)
        let notes = NoteStore(container: container, now: { date }, attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: tasks, notes: notes)
        let controller = NotesPageController(store: notes, journal: coordinator.journal)
        await notes.waitForAttachmentReconciliation()
        await controller.waitForRecoveryWork()
        let victim = try XCTUnwrap(notes.notes.first { $0.title == "Note 0" })
        return Rig(container: container, tasks: tasks, notes: notes, library: library, controller: controller, victim: victim)
    }

    private func finish(_ rig: Rig) async {
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    private func blocks(_ data: Data?) -> [String]? {
        guard let data, case let .editable(document) = NoteContentCodec.decode(data) else { return nil }
        return document.blocks.map(\.text)
    }

    private func noteRows(_ container: ModelContainer, _ id: UUID) throws -> [NoteItem] {
        try ModelContext(container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
    }

    /// HOLD 2. A title-only update_note while a newer physical replica (later `updatedAt`, the same revision token,
    /// another body) is on disk and the presentation is behind it. The newer body survives the edit and its Undo on
    /// every physical row.
    func testR5H2TitleOnlyAgentEditKeepsANewerSameRevisionBody() async throws {
        // The "behind" arm's body checks are a strict expected failure: they go red once the trunk change binds a
        // write to its base (pr40-fable.md §4). From r7 the "spent" arm's first edit is refused (the context was
        // replaced at its entry); repeated on the fresh rows it keeps the newer body.
        for arm in R5Seams.arms {
            let rig = try await makeRig()
            guard case let .success(created) = rig.notes.createDocumentNote(
                id: UUID(), document: NoteDocument(blocks: [.text("Target"), .text("Older body")])) else { return XCTFail("create") }
            let noteID = created.noteID
            let tools = AgentTaskTools(store: rig.tasks, noteStore: rig.notes, library: rig.library)
            tools.notesController = { rig.controller }
            let actions = AgentActions(tasks: tools)
            let spent = R5Seams.leaveNotesBehind(rig.notes, deleting: rig.victim, spend: arm == "spent")
            let outside = ModelContext(rig.container)
            let original = try XCTUnwrap(try outside.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })).first)
            let newer = NoteItem(id: noteID, title: original.title, body: "Newer body", createdAt: original.createdAt)
            newer.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Target"), .text("Newer body")]))
            newer.revision = original.revision; newer.revisionID = original.revisionID
            newer.tagsRaw = original.tagsRaw
            newer.updatedAt = original.updatedAt.addingTimeInterval(60)
            outside.insert(newer)
            try outside.save()
            let token = original.revisionToken
            // By physical row: which rows hold the newer body before the edit (r6 HOLD 4: a correct refusal that
            // leaves the older row untouched must pass, so the strict expected failure then reports the fix).
            let newerRows = Set(try noteRows(rig.container, noteID).filter { blocks($0.content)?.last == "Newer body" }
                .map(\.persistentModelID))
            let presented = rig.notes.note(withID: noteID).map { "\($0.revisionToken == token):\($0.body)" } ?? "nil"
            var callToken = token
            if arm == "spent" {
                let before = try R7Rows.snapshot(rig.container)
                var first = "nil"
                do {
                    let call = try await actions.call(name: "update_note", arguments: [
                        "id": noteID.uuidString, "title": "Renamed by agent", "base_revision": token], watching: false,
                        requestID: actions.beginRequest(title: "Rename a note (first try)"))
                    first = "\(call)"
                } catch { first = "threw \(error)" }
                print("R5_H2_FIRST arm=\(arm) first=\(first.prefix(120))")
                XCTAssertTrue(first.hasPrefix("threw"), "spent: the first edit is refused (its context was replaced at the entry)")
                XCTAssertEqual(try R7Rows.snapshot(rig.container), before, "spent: the refused edit wrote nothing")
                callToken = rig.notes.note(withID: noteID)?.revisionToken ?? token
            }
            let request = actions.beginRequest(title: "Rename a note")
            var outcome = "nil"
            do {
                let call = try await actions.call(name: "update_note", arguments: [
                    "id": noteID.uuidString, "title": "Renamed by agent", "base_revision": callToken], watching: false, requestID: request)
                if case let .performed(result) = call { outcome = "performed \(result.text)" } else { outcome = "\(call)" }
            } catch { outcome = "threw \(error)" }
            let actionRows = try noteRows(rig.container, noteID)
            let afterAction = actionRows.map { blocks($0.content) }
            let steps = actions.changeSet(for: request)?.count ?? 0
            let undone = await actions.undo(changeSet: request)
            let undoRows = try noteRows(rig.container, noteID)
            let afterUndo = undoRows.map { blocks($0.content) }
            let versions = try ModelContext(rig.container).fetch(FetchDescriptor<NoteVersion>(predicate: #Predicate { $0.noteID == noteID }))
            let newerVersions = versions.filter { blocks($0.content)?.last == "Newer body" }.count
            print("R5_H2_VERSIONS build=\(R5Seams.build) arm=\(arm) versions=\(versions.count) holding_newer_body=\(newerVersions) "
                + "bodies=\(versions.map { blocks($0.content)?.last ?? "nil" })")
            print("R5_H2 build=\(R5Seams.build) arm=\(arm) spent=\(spent.map { "\($0)" } ?? "n/a") presented=\(presented) "
                + "outcome=\(outcome.prefix(160)) after_action=\(afterAction) steps=\(steps) undone=\(undone.undone) "
                + "failures=\(undone.failures) after_undo=\(afterUndo)")
            // Identity first, outside any expected failure (r7 NOTE): the protected physical row is still there.
            XCTAssertEqual(newerRows.count, 1, "\(arm): one physical row holds the newer body before the edit")
            XCTAssertEqual(afterAction.count, 2, "\(arm): both physical rows remain")
            XCTAssertTrue(newerRows.isSubset(of: Set(actionRows.map(\.persistentModelID))), "\(arm): the newer row survives the edit")
            XCTAssertEqual(undoRows.count, 2, "\(arm): both physical rows remain after Undo")
            XCTAssertTrue(newerRows.isSubset(of: Set(undoRows.map(\.persistentModelID))), "\(arm): the newer row survives Undo")
            let bodies = {
                XCTAssertTrue(actionRows.filter { newerRows.contains($0.persistentModelID) }.allSatisfy { self.blocks($0.content)?.last == "Newer body" },
                              "\(arm): the row that held the newer body still holds it after the edit (none replaced by older content)")
                XCTAssertTrue(undoRows.filter { newerRows.contains($0.persistentModelID) }.allSatisfy { self.blocks($0.content)?.last == "Newer body" },
                              "\(arm): Undo writes nothing older back onto the row that held the newer body")
            }
            if arm == "behind" {
                XCTExpectFailure("NOTE-BASE-BINDING: a whole-document write is not compared with the base it came from") { bodies() }
            } else { bodies() }
            await finish(rig)
        }
    }

    /// HOLD 3. Two proposals: the first is stale (its base is an older revision), the second is current. Applying
    /// marks the first for review (pass 1's save); right after that save, another context marks the second for
    /// review, between the passes. Pass 2 must not apply it: its rows and the note's body stay as they were.
    func testR5H3ApplyingProposalsKeepsOneMarkedForReviewElsewhere() async throws {
        for arm in R5Seams.arms {
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            let clock = Clock()
            let between = Between()
            let notes = NoteStore(container: container, now: { clock.next() }, persist: { context in
                try context.save()
                if between.armed { between.armed = false; between.marked = (try? between.mark?()) != nil }
            }, attachmentFileStore: makeTestAttachmentFileStore())
            await notes.waitForAttachmentReconciliation()
            guard case let .success(created) = notes.createDocumentNote(
                id: UUID(), document: NoteDocument(blocks: [.text("Two proposals"), .text("Base")])) else { return XCTFail("create") }
            let noteID = created.noteID
            let r0 = try XCTUnwrap(notes.note(withID: noteID)).revisionToken
            guard case let .success(.pending(staleID)) = notes.agentWrite(noteID: noteID, baseRevisionToken: r0,
                document: NoteDocument(blocks: [.text("Two proposals"), .text("Stale")]), agentName: "Agent",
                disposition: .proposal) else { return XCTFail("stale proposal") }
            XCTAssertTrue(notes.update(try XCTUnwrap(notes.note(withID: noteID)), title: "Two proposals moved"))
            let current = try XCTUnwrap(notes.note(withID: noteID))
            let r1 = current.revisionToken
            let movedBlocks = blocks(current.content)
            guard case let .success(.pending(reviewID)) = notes.agentWrite(noteID: noteID, baseRevisionToken: r1,
                document: NoteDocument(blocks: [.text("Two proposals moved"), .text("Fresh")]), agentName: "Agent",
                disposition: .proposal) else { return XCTFail("current proposal") }
            notes.refresh()
            let listed = notes.pendingEdits(noteID: noteID)
            let listedReview = listed.map { "\($0.id == staleID ? "stale" : "current"):\($0.needsReview)" }
            between.mark = {
                let outside = ModelContext(container)
                for row in try outside.fetch(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { $0.id == reviewID })) {
                    row.needsReview = true
                }
                try outside.save()
            }
            between.armed = true
            if arm == "spent" { R5Seams.armPlainCommitSpend() }
            let applied = notes.applyPendingEdits(noteID: noteID)
            between.armed = false
            let spendFired = R5Seams.plainCommitSpendFired()
            R5Seams.reset()
            let pending = try ModelContext(container).fetch(FetchDescriptor<NotePendingEdit>()).filter { $0.noteID == noteID }
            let reviewRows = pending.filter { $0.id == reviewID }
            let stale = pending.filter { $0.id == staleID }
            let stored = try noteRows(container, noteID).map { blocks($0.content) }
            print("R5_H3 build=\(R5Seams.build) arm=\(arm) r0_ne_r1=\(r0 != r1) listed=\(listedReview) marked_between=\(between.marked) "
                + "spend_fired=\(spendFired.map { "\($0)" } ?? "n/a") applied=\(applied) "
                + "review_rows=\(reviewRows.map { "\($0.needsReview)" }) stale_rows=\(stale.map { "\($0.needsReview)" }) "
                + "stored=\(stored) error=\(notes.lastErrorMessage ?? "nil")")
            XCTAssertNotEqual(r0, r1, "\(arm): the first proposal's base is stale")
            XCTAssertTrue(between.marked, "\(arm): the second proposal was marked for review between the passes")
            XCTAssertEqual(applied, 0, "\(arm): nothing applies")
            XCTAssertEqual(reviewRows.map(\.needsReview), [true], "\(arm): the proposal marked for review elsewhere keeps its row")
            XCTAssertEqual(stored, [movedBlocks], "\(arm): the note's document is unchanged")
            await notes.waitForAttachmentReconciliation()
        }
    }

    /// HOLD 4. Add `mine` to a note; the presentation falls behind while another context adds `keep`; undo `mine`.
    /// Every physical row keeps `keep`.
    func testR5H4UndoingANoteTagKeepsATagAddedElsewhere() async throws {
        // The "behind" arm is a strict expected failure: it goes red once the trunk change moves the tag delta into
        // the store (pr40-fable.md §4). From r7 the "spent" arm's first Undo is refused (the context was replaced at
        // its entry); repeated, it moves the tags of the fresh rows.
        for arm in R5Seams.arms {
            let rig = try await makeRig()
            let note = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 1" })
            let noteID = note.id
            let ref = AtticItemRef(.note, noteID)
            XCTAssertTrue(rig.library.setTags(["mine"], on: ref))
            let spent = R5Seams.leaveNotesBehind(rig.notes, deleting: rig.victim, spend: arm == "spent")
            let outside = ModelContext(rig.container)
            for row in try outside.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) {
                row.tagsRaw = AtticTag.encode(["keep", "mine"])
            }
            try outside.save()
            let presented = rig.notes.note(withID: noteID)?.tags ?? []
            if arm == "spent" {
                let before = try R7Rows.snapshot(rig.container)
                let first = rig.library.undo(in: .note(noteID))
                print("R5_H4_FIRST arm=\(arm) first=\(first)")
                XCTAssertFalse(first.isApplied, "spent: the first Undo is refused (its context was replaced at the entry)")
                XCTAssertEqual(try R7Rows.snapshot(rig.container), before, "spent: the refused Undo wrote nothing")
            }
            let undone = rig.library.undo(in: .note(noteID))
            let stored = try noteRows(rig.container, noteID).map { AtticTag.decode($0.tagsRaw) }
            print("R5_H4 build=\(R5Seams.build) arm=\(arm) spent=\(spent.map { "\($0)" } ?? "n/a") presented=\(presented) "
                + "undone=\(undone) stored=\(stored) error=\(rig.notes.lastErrorMessage ?? "nil")")
            XCTAssertFalse(stored.isEmpty)
            let tags = {
                XCTAssertTrue(stored.allSatisfy { $0.contains("keep") }, "\(arm): the tag added elsewhere survives Undo")
                XCTAssertTrue(stored.allSatisfy { !$0.contains("mine") } || !undone.isApplied,
                              "\(arm): Undo either removed the tag it added or reported that it did not apply")
            }
            if arm == "behind" {
                XCTExpectFailure("NOTE-BASE-BINDING: note tag Undo writes a whole array computed from presentation") { tags() }
            } else { tags() }
            await finish(rig)
        }
    }

    /// HOLD 5. A verified attachment proof is cached; another context clears the stored payload (id, digest, size,
    /// type and owner unchanged); the store then installs a fresh context. Store-only verification returns nil.
    /// "spent-prepare" is PR 40's recovery swap; "local-save" is a journaled local save, whose reload also keeps
    /// proofs (on both commits); "refresh" is the store's outside-change refresh (the control). The recovery-copy half
    /// of the finding is not covered here.
    func testR5H5AFreshContextDropsAStaleAttachmentProof() async throws {
        for arm in R5Seams.proofArms {
            let rig = try await makeRig()
            let data = Data("file bytes".utf8)
            let item = StagedNoteAttachment(id: UUID(), filename: "plan.pdf", contentTypeIdentifier: "com.adobe.pdf",
                byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), data: data)
            let document = NoteDocument(blocks: [.text("Files"), .file(attachmentID: item.id, filename: item.filename,
                contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
            guard case .success = rig.notes.createDocumentNote(id: UUID(), document: document, staged: [item]) else { return XCTFail("create") }
            let first = await rig.notes.verifiedAttachmentBytes(item.id, allowMaterialized: false)
            let cachedBefore = rig.notes.cachedVerifiedAttachmentBytes(item.id) != nil
            let spent = arm == "spent-prepare" ? R5Seams.leaveNotesBehind(rig.notes, deleting: rig.victim, spend: true) : nil
            let outside = ModelContext(rig.container)
            let itemID = item.id
            for row in try outside.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == itemID })) { row.payload = nil }
            try outside.save()
            let installed: Bool
            switch arm {
            case "spent-prepare": installed = R5Seams.prepareNotes(rig.notes)
            // A journaled local save (an unrelated note's delete), which reloads keeping attachment proofs.
            case "local-save": installed = rig.notes.delete(rig.victim)
            // r6 HOLD 2: an unrelated pin whose plain-commit guard update fails; the save reloads at once.
            case "plain-guard":
                R5Seams.armPlainCommitSpend()
                let other = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 1" })
                installed = rig.notes.setPinned(true, noteID: other.id) && R5Seams.plainCommitSpendFired() == true
            default: rig.notes.refresh(); installed = true
            }
            let cachedAfter = rig.notes.cachedVerifiedAttachmentBytes(item.id) != nil
            let after = await rig.notes.verifiedAttachmentBytes(item.id, allowMaterialized: false)
            print("R5_H5 build=\(R5Seams.build) arm=\(arm) first=\(first != nil) cached_before=\(cachedBefore) "
                + "spent=\(spent.map { "\($0)" } ?? "n/a") installed=\(installed) cached_after=\(cachedAfter) after=\(after != nil)")
            XCTAssertNotNil(first, "\(arm): the payload verified before the outside write")
            XCTAssertTrue(installed, "\(arm): a fresh context is installed")
            XCTAssertTrue(try outside.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == itemID }))
                .allSatisfy { $0.payload == nil }, "\(arm): a fresh read finds no payload")
            XCTAssertNil(after, "\(arm): store-only verification no longer finds the cleared payload")
            await finish(rig)
        }
    }
}
// R5-SHARED-END

/// PR 40 bodies of the seams the R5 narrowing tests use. The trunk copy of this enum has trunk bodies.
@MainActor
enum R5Seams {
    static let build = "head"
    static let arms = ["spent", "behind"]
    static let proofArms = ["spent-prepare", "local-save", "refresh", "plain-guard"]

    /// Deletes `victim` (a journaled commit). With `spend`, its reloads fail, so the context stays spent and the
    /// presentation stays behind, as A12 does. Returns whether the bridge marks the context spent.
    static func leaveNotesBehind(_ notes: NoteStore, deleting victim: NoteItem, spend: Bool) -> Bool? {
        if spend { notes.reloadFailures = 3 }
        _ = notes.delete(victim)
        notes.reloadFailures = 0
        return WorkspaceLegacyBridge.isSpent(notes.modelContext)
    }

    /// The next plain commit's baseline update fails, which leaves its context spent.
    static func armPlainCommitSpend() { WorkspaceLegacyBridge.postCommitPlainFailures = 1 }
    static func plainCommitSpendFired() -> Bool? { WorkspaceLegacyBridge.postCommitPlainFailures == 0 }
    static func reset() { WorkspaceLegacyBridge.postCommitPlainFailures = 0 }
    /// PR 40's family guard (pr40-fable.md §3): no row is staged through a context it does not belong to.
    static func resetFamilyGuard() { WorkspaceLegacyBridge.foreignRowMutations = 0 }
    static func assertFamilyGuard() {
        XCTAssertEqual(WorkspaceLegacyBridge.foreignRowMutations, 0, "No row is staged through a context it does not belong to")
    }

    /// PR 40's staging entry on a spent context: whether it installed a fresh one. (From r7 the entry also ends the
    /// command it was called for, so its Bool is no longer that answer.)
    static func prepareNotes(_ notes: NoteStore) -> Bool {
        _ = notes.prepareNoteEdit()
        return !WorkspaceLegacyBridge.isSpent(notes.modelContext)
    }
}

/// Astra round 6 on ba6e5986 (pr40-astra-r6-ba6e5986.md): HOLD 1, the sweep's swap-only site and HOLD 3. Each red
/// leaves the note store's context spent (its reloads fail), so its presentation still shows the old disk, then
/// changes disk elsewhere; the command's staging entry then swaps the context under a read taken before it.
@MainActor
final class DurableSaveR6Tests: XCTestCase {
    override func setUp() {
        super.setUp()
        R5Seams.resetFamilyGuard()
    }

    override func tearDown() {
        R5Seams.assertFamilyGuard()
        R5Seams.reset()
        super.tearDown()
    }

    private struct Rig {
        let container: ModelContainer
        let tasks: TaskStore
        let notes: NoteStore
        let library: AtticLibrary?
        let controller: NotesPageController
        let victim: NoteItem
    }

    private func makeRig(library withLibrary: Bool, seed: (ModelContext) throws -> Void = { _ in }) async throws -> Rig {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let context = ModelContext(container)
        for index in 0..<3 { context.insert(NoteItem(title: "Note \(index)", body: "Body", createdAt: date)) }
        try seed(context)
        try context.save()
        let files = TaskImageFiles(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("R6Rig-\(UUID())"))
        let tasks = TaskStore(container: container, now: { date }, taskImageFiles: files)
        let notes = NoteStore(container: container, now: { date }, attachmentFileStore: makeTestAttachmentFileStore())
        let library = withLibrary ? AtticLibrary(tasks: tasks, notes: notes) : nil
        let controller = NotesPageController(store: notes, journal: coordinator.journal)
        await notes.waitForAttachmentReconciliation()
        await controller.waitForRecoveryWork()
        let victim = try XCTUnwrap(notes.notes.first { $0.title == "Note 0" })
        return Rig(container: container, tasks: tasks, notes: notes, library: library, controller: controller, victim: victim)
    }

    private func finish(_ rig: Rig) async {
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    private func noteRows(_ container: ModelContainer, _ id: UUID) throws -> [NoteItem] {
        try ModelContext(container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
    }

    private func taskRows(_ container: ModelContainer, _ id: UUID) throws -> [TaskItem] {
        try ModelContext(container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
    }

    /// HOLD 1. The presentation shows a task's note deleted on its own (pre-group); disk now holds the task and its
    /// note deleted together as one group. Restore Note on the task's page brings back the group; its Undo must take
    /// back exactly that, leaving the task deleted as it was before the Restore.
    func testR6H1RestoreNoteUndoFollowsTheGroupTheRestoreBroughtBack() async throws {
        let taskID = UUID(), noteID = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let rig = try await makeRig(library: true) { context in
            context.insert(TaskItem(id: taskID, title: "Owner", createdAt: date))
            let note = NoteItem(id: noteID, title: "Owned", body: "Writing", createdAt: date)
            note.taskID = taskID
            context.insert(note)
        }
        // r6 attempt 2 (the lead's recipe): the spending commit itself carries a pre-group independent deletion of
        // the note, staged on the store's own rows; its journaled commit leaves the spent context holding those
        // values for these rows. (No store command makes a group-less deletion today; old data has them.)
        let staged = try rig.notes.replicasIncludingDeleted(of: noteID)
        WorkspaceLegacyBridge.prepareMutations(staged, in: rig.notes.modelContext)
        for row in staged { row.deletedAt = date.addingTimeInterval(10) }
        let spent = R5Seams.leaveNotesBehind(rig.notes, deleting: rig.victim, spend: true)
        XCTAssertEqual(spent, true, "the store's context is spent")
        XCTAssertTrue(try noteRows(rig.container, noteID).allSatisfy { $0.deletedAt != nil && $0.deletionGroupID == nil },
                      "the spending commit wrote the pre-group deletion")
        // Elsewhere: the note comes back and the task is deleted with it, as one group.
        let outside = ModelContext(rig.container)
        for row in try outside.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) {
            row.deletedAt = nil
        }
        let group = UUID()
        try WorkspaceItemLifecycle.stageDeletion(rootID: taskID, tasks: try outside.fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })), group: group,
            timestamp: date.addingTimeInterval(20), in: outside)
        try outside.save()
        let stale = try rig.notes.replicasIncludingDeleted(of: noteID).map { $0.deletionGroupID == nil }
        let disk = try noteRows(rig.container, noteID).map { $0.deletionGroupID == nil }
        XCTAssertTrue(try noteRows(rig.container, noteID).allSatisfy { $0.deletionGroupID == group }, "disk holds the group")
        XCTAssertEqual(stale, [true], "before the command, the spent context still shows the pre-group deletion")
        XCTAssertEqual(disk, [false], "before the command, disk holds the group deletion")

        // r7: the context is replaced at the restore's entry, so the first Restore is refused and writes nothing.
        let diskBefore = try R7Rows.snapshot(rig.container)
        let refused = rig.controller.restoreTaskNote(noteID: noteID)
        XCTAssertNil(refused, "the first Restore is refused: its context was replaced at the entry")
        XCTAssertEqual(rig.notes.lastErrorMessage, R7Rows.refusal)
        XCTAssertEqual(try R7Rows.snapshot(rig.container), diskBefore, "the refused Restore wrote nothing")
        let restored = rig.controller.restoreTaskNote(noteID: noteID)
        let restoredTask = try taskRows(rig.container, taskID).map { $0.deletedAt == nil }
        let undone = rig.controller.undoRoute.undo(in: .taskWorkspace(taskID))
        let taskAfter = try taskRows(rig.container, taskID).map { $0.deletedAt != nil }
        let noteAfter = try noteRows(rig.container, noteID).map { $0.deletedAt != nil }
        print("R6_H1 before_independent=\(stale) disk_independent=\(disk) restored=\(restored.map { "\($0.separate)" } ?? "nil") "
            + "task_live_after_restore=\(restoredTask) undone=\(undone) task_deleted=\(taskAfter) note_deleted=\(noteAfter)")
        XCTAssertNotNil(restored, "Restore Note succeeds")
        XCTAssertEqual(restoredTask, [true], "the restore brought back the task with its note")
        XCTAssertTrue(undone, "Undo applies")
        XCTAssertEqual(taskAfter, [true], "Undo leaves the task deleted, as it was before Restore")
        XCTAssertTrue(!noteAfter.isEmpty && noteAfter.allSatisfy { $0 }, "Undo deletes the note again")
        await finish(rig)
    }

    /// Sweep, swap-only site: Delete Note's Undo without a command library. Its guard compares the note's current
    /// deletion groups with the ones the step owns. The presentation still shows the step's group; disk now holds a
    /// newer deletion of the note under another group. Undo must not restore a deletion the step does not own.
    func testR6SweepDeleteNoteUndoChecksTheGroupItWillRestore() async throws {
        let rig = try await makeRig(library: false)
        let note = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 1" })
        let noteID = note.id
        // The same recipe: the Delete Note commit is the spending commit (its reloads fail), so the spent context
        // holds the deletion's values for these rows.
        rig.notes.reloadFailures = 3
        XCTAssertTrue(rig.controller.deleteNote(noteID: noteID))
        rig.notes.reloadFailures = 0
        XCTAssertEqual(WorkspaceLegacyBridge.isSpent(rig.notes.modelContext), true, "the store's context is spent")
        let owned = Set(try noteRows(rig.container, noteID).compactMap(\.deletionGroupID))
        XCTAssertEqual(owned.count, 1, "the delete recorded one group")
        // Elsewhere: restored and deleted again, under a newer group.
        let newer = UUID()
        let outside = ModelContext(rig.container)
        for row in try outside.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) {
            row.deletedAt = Date(timeIntervalSince1970: 1_700_000_500)
            row.deletionGroupID = newer
        }
        try outside.save()
        let shown = Set(try rig.notes.replicasIncludingDeleted(of: noteID).compactMap(\.deletionGroupID))
        XCTAssertEqual(shown, owned, "before the command, the spent context still shows the step's own group")
        XCTAssertEqual(Set(try noteRows(rig.container, noteID).compactMap(\.deletionGroupID)), [newer],
                       "before the command, disk holds the newer group")
        let undone = rig.controller.undoRoute.undo(in: .notesLibrary)
        let after = try noteRows(rig.container, noteID)
        let disk = Set(try noteRows(rig.container, noteID).compactMap(\.deletionGroupID))
        print("R6_SWEEP before_is_owned=\(shown == owned) disk_is_owned=\(disk == owned) undone=\(undone) "
            + "deleted_after=\(after.map { $0.deletedAt != nil }) group_after=\(after.map { $0.deletionGroupID == newer })")
        XCTAssertTrue(!after.isEmpty && after.allSatisfy { $0.deletedAt != nil && $0.deletionGroupID == newer },
                      "Undo does not restore the newer deletion the step does not own")
        await finish(rig)
    }

    /// HOLD 3. The family guard is told which context a document staging writes through. A row carried from an
    /// older context is counted even when every row of the family came from that same older context.
    func testR6H3TheGuardCountsAFamilyCarriedFromAnOldContext() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let old = ModelContext(container)
        old.insert(NoteItem(title: "Carried", body: "Body"))
        try old.save()
        let carried = try XCTUnwrap(try old.fetch(FetchDescriptor<NoteItem>()).first)
        let installed = ModelContext(container)
        NoteStore.stageDocumentContent(try PreparedNoteDocument(NoteDocument(blocks: [.text("Carried"), .text("New")])),
            format: 1, on: [carried], timestamp: Date(), revision: carried.revision, revisionID: UUID(), in: installed)
        let counted = WorkspaceLegacyBridge.foreignRowMutations
        print("R6_H3 counted=\(counted)")
        old.rollback()
        R5Seams.resetFamilyGuard()
        XCTAssertEqual(counted, 1, "the row from the older context is counted against the installed context")
    }
}

/// Disk rows, read from a fresh context, for "the command wrote nothing" checks; and the r7 refusal text.
@MainActor
enum R7Rows {
    /// The fixed message a command refused at its entry leaves (pr40-wall-design.md: the rule).
    static let refusal = "The notes list was refreshed. Try again."

    /// Every note, attachment, version and proposal row on disk, each as its sorted fields (bytes compared).
    static func snapshot(_ container: ModelContainer) throws -> [String] {
        let context = ModelContext(container)
        func lines<M: PersistentModel>(_ type: M.Type) throws -> [String] {
            try context.fetch(FetchDescriptor<M>()).map { row in
                let fields = try WorkspaceModelFields.read(row)
                return "\(M.self)|" + fields.keys.sorted().map { "\($0)=\(fields[$0]!.base64EncodedString())" }.joined(separator: ";")
            }
        }
        return (try lines(NoteItem.self) + lines(NoteAttachment.self) + lines(NoteVersion.self)
            + lines(NotePendingEdit.self) + lines(TaskItem.self)).sorted()
    }
}

/// Astra round 7 on 4439310a (pr40-astra-r7.md) and the lead's rule (pr40-wall-design.md): a context replaced at a
/// command's entry ends that command. Each red leaves the note store's context spent (the reload after a durable
/// save failed) and changes disk from another context. Where the command's caller reads through a fetch, the spending
/// commit itself touches the row (the round 6 recipe), so the spent context still shows the earlier values.
@MainActor
final class DurableSaveR7Tests: XCTestCase {
    override func setUp() {
        super.setUp()
        R5Seams.resetFamilyGuard()
    }

    override func tearDown() {
        R5Seams.assertFamilyGuard()
        R5Seams.reset()
        super.tearDown()
    }

    private struct Rig {
        let container: ModelContainer
        let tasks: TaskStore
        let notes: NoteStore
        let library: AtticLibrary
        let controller: NotesPageController
        let victim: NoteItem
    }

    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRig(seed: (ModelContext) throws -> Void = { _ in }) async throws -> Rig {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        let context = ModelContext(container)
        for index in 0..<3 { context.insert(NoteItem(title: "Note \(index)", body: "Body", createdAt: date)) }
        try seed(context)
        try context.save()
        let files = TaskImageFiles(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("R7Rig-\(UUID())"))
        let tasks = TaskStore(container: container, now: { [date] in date }, taskImageFiles: files)
        let notes = NoteStore(container: container, now: { [date] in date }, attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: tasks, notes: notes)
        let controller = NotesPageController(store: notes, journal: coordinator.journal)
        await notes.waitForAttachmentReconciliation()
        await controller.waitForRecoveryWork()
        let victim = try XCTUnwrap(notes.notes.first { $0.title == "Note 0" })
        return Rig(container: container, tasks: tasks, notes: notes, library: library, controller: controller, victim: victim)
    }

    private func finish(_ rig: Rig) async {
        await rig.controller.waitForRecoveryWork(); await rig.notes.waitForAttachmentReconciliation()
    }

    /// The spending commit touches `rows` (fetched through the store's own context): `touch` changes them there,
    /// then an unrelated journaled delete commits them and its reloads fail, leaving the context spent and holding
    /// these rows' committed values.
    private func spend(_ rig: Rig, touching rows: [any PersistentModel] = [], _ touch: () -> Void = {}) -> Bool? {
        if !rows.isEmpty { WorkspaceLegacyBridge.prepareMutations(rows, in: rig.notes.modelContext) }
        touch()
        return R5Seams.leaveNotesBehind(rig.notes, deleting: rig.victim, spend: true)
    }

    private func document(_ data: Data?) -> NoteDocument? {
        guard let data, case let .editable(document) = NoteContentCodec.decode(data) else { return nil }
        return document
    }

    private func staged(_ name: String) -> StagedNoteAttachment {
        let data = Data("\(name) bytes".utf8)
        return StagedNoteAttachment(id: UUID(), filename: name, contentTypeIdentifier: "com.adobe.pdf",
            byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), data: data)
    }

    private func fileBlock(_ item: StagedNoteAttachment) -> NoteBlock {
        .file(attachmentID: item.id, filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
    }

    /// HOLD 1. Save as New Note checks the reviewed proposal's signature (through the store's context), then hands
    /// only its id to `createDocumentNote`. Another context replaced the proposal's contents under the same id. The
    /// save is refused, makes no note and leaves the replacement intact; repeated, the check sees the fresh rows.
    func testR7H1SaveAsNewNoteRefusesAProposalReplacedAcrossTheSwap() async throws {
        let rig = try await makeRig()
        guard case let .success(created) = rig.notes.createDocumentNote(
            id: UUID(), document: NoteDocument(blocks: [.text("Reviewed"), .text("Base")])) else { return XCTFail("create") }
        let noteID = created.noteID
        let token = try XCTUnwrap(rig.notes.note(withID: noteID)).revisionToken
        guard case let .success(.pending(proposalID)) = rig.notes.agentWrite(noteID: noteID, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Reviewed"), .text("Proposed")]), agentName: "Agent",
            disposition: .proposal) else { return XCTFail("proposal") }
        let held = try rig.notes.pendingEditRows(proposalID)
        let spent = spend(rig, touching: held) { held.forEach { $0.agentName = "Agent (seen)" } }
        XCTAssertEqual(spent, true, "the store's context is spent")
        let reviewed = try XCTUnwrap(rig.notes.pendingEditRows(proposalID).first.map(NoteProposalSignature.init))
        let outside = ModelContext(rig.container)
        for row in try outside.fetch(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { $0.id == proposalID })) {
            row.proposedContent = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Reviewed"), .text("Replacement")]))
        }
        try outside.save()
        let fresh = try outside.fetch(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { $0.id == proposalID }))
        // The controller's check (NotesPageController Save as New): the presented rows still match the review.
        let checked = try rig.notes.pendingEditRows(proposalID).first.map(NoteProposalSignature.init)
        XCTAssertEqual(checked, reviewed, "before the command, the spent context still shows the reviewed proposal")
        XCTAssertNotEqual(fresh.first.map(NoteProposalSignature.init), reviewed, "before the command, disk holds the replacement")
        let before = try R7Rows.snapshot(rig.container)
        let copyID = UUID()
        let result = rig.notes.createDocumentNote(id: copyID, document: NoteDocument(blocks: [.text("Reviewed"), .text("Proposed")]),
                                                  resolvingProposal: proposalID)
        let after = try R7Rows.snapshot(rig.container)
        let copies = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == copyID }))
        let remaining = try ModelContext(rig.container).fetch(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { $0.id == proposalID }))
        print("R7_H1 result=\(result) copies=\(copies.count) proposal_rows=\(remaining.count) "
            + "replacement_kept=\(remaining.allSatisfy { self.document($0.proposedContent)?.blocks.last?.text == "Replacement" }) "
            + "error=\(rig.notes.lastErrorMessage ?? "nil")")
        if case .success = result { XCTFail("Save as New Note is refused") }
        XCTAssertEqual(rig.notes.lastErrorMessage, R7Rows.refusal)
        XCTAssertTrue(copies.isEmpty, "no new note")
        XCTAssertEqual(after, before, "nothing written: the replacement proposal is intact")
        // Repeated: the controller's check now reads the fresh rows and no longer matches the review.
        XCTAssertNotEqual(try rig.notes.pendingEditRows(proposalID).first.map(NoteProposalSignature.init), reviewed,
                          "repeated, the check sees the replacement and stops before the store")
        await finish(rig)
    }

    /// HOLD 2. Undo of a Restore Attachment on note A finds the file in A's presented list; another context moved it
    /// to note B. The Undo is refused and B keeps its file; repeated, it no longer finds the file on A.
    func testR7H2AttachmentUndoRefusesAFileMovedToAnotherNote() async throws {
        let rig = try await makeRig()
        let item = staged("plan.pdf")
        guard case let .success(a) = rig.notes.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("A"), fileBlock(item)]), staged: [item]) else { return XCTFail("create A") }
        guard case let .success(b) = rig.notes.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("B"), .text("Body")])) else { return XCTFail("create B") }
        let aID = a.noteID, bID = b.noteID, itemID = item.id
        let attachment = try XCTUnwrap(rig.notes.attachments(for: aID).first { $0.id == itemID })
        XCTAssertTrue(rig.notes.removeAttachment(attachment), "the file goes to Recently Deleted")
        let summary = try XCTUnwrap(rig.library.recentlyDeletedAttachments().first { $0.attachmentID == itemID })
        XCTAssertTrue(rig.library.restoreAttachment(summary), "Restore Attachment, as one undoable step")
        let spent = spend(rig)
        XCTAssertEqual(spent, true, "the store's context is spent")
        // Elsewhere: the file moves to B (its rows, and the placement from A's document to B's).
        let outside = ModelContext(rig.container)
        for row in try outside.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == itemID })) { row.noteID = bID }
        for row in try outside.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == aID })) {
            row.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("A")]))
        }
        for row in try outside.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == bID })) {
            row.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("B"), .text("Body"), fileBlock(item)]))
        }
        try outside.save()
        XCTAssertTrue(rig.notes.attachments(for: aID).contains { $0.id == itemID }, "before the command, A's list still shows the file")
        let before = try R7Rows.snapshot(rig.container)
        let first = rig.library.undo(in: .library)
        let afterFirst = try R7Rows.snapshot(rig.container)
        let firstError = rig.notes.lastErrorMessage
        let second = rig.library.undo(in: .library)
        let rows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == itemID }))
        let bDocument = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == bID }))
            .map { self.document($0.content)?.attachmentIDs.contains(itemID) == true }
        print("R7_H2 first=\(first) second=\(second) rows_on_b=\(rows.map { $0.noteID == bID }) "
            + "live=\(rows.map { $0.deletedAt == nil }) b_placement=\(bDocument) error=\(firstError ?? "nil")")
        XCTAssertFalse(first.isApplied, "the first Undo is refused")
        XCTAssertEqual(firstError, R7Rows.refusal)
        XCTAssertEqual(afterFirst, before, "the refused Undo wrote nothing")
        XCTAssertFalse(second.isApplied, "repeated, A no longer shows the file: nothing to undo there")
        XCTAssertTrue(!rows.isEmpty && rows.allSatisfy { $0.noteID == bID && $0.deletedAt == nil }, "B keeps every attachment row")
        XCTAssertEqual(bDocument, [true], "B keeps the file's placement")
        await finish(rig)
    }

    /// HOLD 3. `update_note` and `update_note_table` decide from the presented note that it is not a task's note, so
    /// they ask for no workspace tokens. Another context made it task-owned without changing its revision. Each tool
    /// is refused and writes nothing; repeated, the agent layer reads the fresh note, supplies the task's workspace
    /// tokens (AgentActions+Convenience) and the write applies to the task-owned note.
    func testR7H3AgentToolsRefuseANoteThatBecameTaskOwned() async throws {
        for tool in ["update_note", "update_note_table"] {
            let taskID = UUID(), tableID = UUID()
            let rig = try await makeRig { context in context.insert(TaskItem(id: taskID, title: "Owner", createdAt: self.date)) }
            let table = NoteTable(texts: [["Pillar", "What"], ["One", "Two"]])
            guard case let .success(created) = rig.notes.createDocumentNote(id: UUID(),
                document: NoteDocument(blocks: [.text("Plain"), .text("Body"), .table(table, id: tableID)])) else { return XCTFail("create") }
            let noteID = created.noteID
            let token = try XCTUnwrap(rig.notes.note(withID: noteID)).revisionToken
            let held = try rig.notes.replicasIncludingDeleted(of: noteID)
            let spent = spend(rig, touching: held) { held.forEach { $0.pinnedAt = self.date } }
            XCTAssertEqual(spent, true, "\(tool): the store's context is spent")
            let outside = ModelContext(rig.container)
            for row in try outside.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) { row.taskID = taskID }
            try outside.save()
            XCTAssertNil(rig.notes.note(withID: noteID)?.taskID, "\(tool): before the command, the presented note has no task")
            XCTAssertEqual(try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
                .map(\.taskID), [taskID], "\(tool): before the command, disk holds the task owner")
            XCTAssertEqual(rig.notes.note(withID: noteID)?.revisionToken, token, "\(tool): the revision is unchanged")
            let tools = AgentTaskTools(store: rig.tasks, noteStore: rig.notes, library: rig.library)
            tools.notesController = { rig.controller }
            let actions = AgentActions(tasks: tools)
            var arguments: [String: Any] = ["id": noteID.uuidString, "base_revision": token]
            if tool == "update_note" { arguments["body"] = "Written by agent" } else {
                arguments["table_id"] = tableID.uuidString
                arguments["operations"] = [["op": "insert_row", "cells": ["Three", "Four"]]]
            }
            func attempt() async -> String {
                do {
                    let call = try await actions.call(name: tool, arguments: arguments, watching: false,
                                                      requestID: actions.beginRequest(title: tool))
                    if case .performed = call { return "performed" }
                    return "\(call)"
                } catch { return "threw \(error)" }
            }
            let before = try R7Rows.snapshot(rig.container)
            let first = await attempt()
            let afterFirst = try R7Rows.snapshot(rig.container)
            let firstError = rig.notes.lastErrorMessage
            let presentedOwner = rig.notes.note(withID: noteID)?.taskID
            let second = await attempt()
            let afterSecond = try R7Rows.snapshot(rig.container)
            print("R7_H3_OWNER tool=\(tool) presented_after_first=\(presentedOwner.map { "\($0 == taskID)" } ?? "nil") "
                + "disk=\(try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })).map { "\($0.taskID == taskID)" })")
            print("R7_H3 tool=\(tool) first=\(first.prefix(140)) second=\(second.prefix(140)) "
                + "first_wrote=\(afterFirst != before) second_wrote=\(afterSecond != before)")
            XCTAssertTrue(first.hasPrefix("threw"), "\(tool): the first call is refused")
            XCTAssertEqual(firstError, R7Rows.refusal, "\(tool): refused at the entry")
            XCTAssertEqual(afterFirst, before, "\(tool): the refused call wrote nothing (note, table and proposal rows)")
            XCTAssertEqual(presentedOwner, taskID, "\(tool): after the refusal the presented note shows its task")
            XCTAssertEqual(second, "performed", "\(tool): repeated, it applies with the task's workspace tokens")
            XCTAssertNotEqual(afterSecond, before, "\(tool): the repeated call wrote")
            let rows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            XCTAssertTrue(!rows.isEmpty && rows.allSatisfy { $0.taskID == taskID }, "\(tool): the note keeps its task owner")
            await finish(rig)
        }
    }

    /// HOLD 5, at the controller (the toast's closure is a private view method; this replays its lookup). The task
    /// page of A restores its deleted note; another context moved the note's writing to task B. The restore is
    /// refused and writes nothing, so no toast names a step under a history it was not recorded in.
    func testR7H5TaskPageRestoreRefusesWritingMovedToAnotherTask() async throws {
        let taskA = UUID(), taskB = UUID(), noteID = UUID()
        let rig = try await makeRig { context in
            context.insert(TaskItem(id: taskA, title: "A", createdAt: self.date))
            context.insert(TaskItem(id: taskB, title: "B", createdAt: self.date))
            let note = NoteItem(id: noteID, title: "Writing", body: "Body", createdAt: self.date)
            note.taskID = taskA
            context.insert(note)
        }
        let staged = try rig.notes.replicasIncludingDeleted(of: noteID)
        let spent = spend(rig, touching: staged) { staged.forEach { $0.deletedAt = self.date.addingTimeInterval(10) } }
        XCTAssertEqual(spent, true, "the store's context is spent")
        let outside = ModelContext(rig.container)
        for row in try outside.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) { row.taskID = taskB }
        try outside.save()
        XCTAssertEqual(try rig.notes.replicasIncludingDeleted(of: noteID).map(\.taskID), [taskA],
                       "before the command, the spent context still shows A's note")
        let before = try R7Rows.snapshot(rig.container)
        let restored = rig.controller.restoreTaskNote(noteID: noteID)
        let after = try R7Rows.snapshot(rig.container)
        let toastFinds = restored.map { rig.controller.undoRoute.undoStepID(in: .taskWorkspace(taskA)) == $0.stepID && $0.stepID != nil }
        print("R7_H5 restored=\(restored.map { "\($0.separate)" } ?? "nil") toast_finds_step_under_A=\(toastFinds.map { "\($0)" } ?? "n/a") "
            + "wrote=\(after != before) error=\(rig.notes.lastErrorMessage ?? "nil")")
        XCTAssertNil(restored, "the restore is refused: its context was replaced at the entry")
        XCTAssertEqual(rig.notes.lastErrorMessage, R7Rows.refusal)
        XCTAssertEqual(after, before, "the refused restore wrote nothing")
        await finish(rig)
    }

    /// HOLD 6. A grouped restore's post-save refresh fires the tag inventory callback; once, it tries to restore a
    /// note that is live (refused). The outer Restore Note still reports success and records one usable Undo step.
    func testR7H6ANestedRefusedRestoreKeepsTheOuterResult() async throws {
        let taskID = UUID(), noteID = UUID()
        let rig = try await makeRig { context in
            context.insert(TaskItem(id: taskID, title: "Owner", createdAt: self.date))
            let note = NoteItem(id: noteID, title: "Owned", body: "Writing", createdAt: self.date)
            note.taskID = taskID
            context.insert(note)
        }
        let outside = ModelContext(rig.container)
        try WorkspaceItemLifecycle.stageDeletion(rootID: taskID, tasks: try outside.fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })), group: UUID(),
            timestamp: date.addingTimeInterval(20), in: outside)
        try outside.save()
        let groupRows = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        XCTAssertEqual(groupRows.count, 1)
        XCTAssertTrue(groupRows.allSatisfy { $0.deletionGroupID != nil && $0.deletedAt != nil }, "the note is deleted with its task, as one group")
        let live = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 1" }).id
        let previous = rig.notes.tagInventoryRefreshed
        var nested: Bool?
        rig.notes.tagInventoryRefreshed = { [weak notes = rig.notes] in
            previous()
            if nested == nil, let notes { nested = notes.restoreDeleted(noteID: live) }
        }
        let restored = rig.controller.restoreTaskNote(noteID: noteID)
        rig.notes.tagInventoryRefreshed = previous
        let stepID = rig.controller.undoRoute.undoStepID(in: .taskWorkspace(taskID))
        print("R7_H6 nested=\(nested.map { "\($0)" } ?? "nil") restored=\(restored.map { "\($0.separate)" } ?? "nil") step=\(stepID != nil)")
        XCTAssertEqual(nested, false, "the nested restore of a live note is refused")
        XCTAssertNotNil(restored, "the outer Restore Note reports its durable success")
        XCTAssertNotNil(stepID, "one Undo step is recorded")
        XCTAssertEqual(restored?.stepID, stepID, "the toast names that step")
        XCTAssertTrue(rig.controller.undoRoute.undo(in: .taskWorkspace(taskID)), "the step is usable")
        XCTAssertTrue(try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            .allSatisfy { $0.deletedAt != nil }, "Undo sends the note back to Recently Deleted")
        await finish(rig)
    }

    private struct SweepFixture {
        let target: UUID, gone: UUID, kept: UUID, removed: UUID, proposal: UUID, proposed: UUID, plain: UUID, version: UUID
    }

    /// A note with a file, a removed file, a recorded version and a later edit; a text note with a pending proposal; a
    /// plain text note for the agent commands; and a deleted note.
    private func sweepFixture(_ rig: Rig) throws -> SweepFixture {
        let kept = staged("kept.pdf"), removed = staged("removed.pdf")
        guard case let .success(t) = rig.notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [
            .text("Target"), .text("Body"), fileBlock(kept), fileBlock(removed)]), staged: [kept, removed]) else { throw R7SweepError.setup("target") }
        let removedRow = try XCTUnwrap(rig.notes.attachments(for: t.noteID).first { $0.id == removed.id })
        guard rig.notes.removeAttachment(removedRow) else { throw R7SweepError.setup("remove") }
        guard rig.notes.recordVersion(noteID: t.noteID, reason: .pause) else { throw R7SweepError.setup("version") }
        let version = try XCTUnwrap(rig.notes.versions(noteID: t.noteID).first).id
        let current = try XCTUnwrap(rig.notes.note(withID: t.noteID))
        guard case .success = rig.notes.saveDocument(noteID: t.noteID, document: NoteDocument(blocks: [
            .text("Target"), .text("Edited"), fileBlock(kept)]), baseRevisionID: current.revisionID) else { throw R7SweepError.setup("edit") }
        guard case let .success(p) = rig.notes.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Reviewed"), .text("Base")])) else { throw R7SweepError.setup("proposed") }
        guard case let .success(plain) = rig.notes.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Plain"), .text("Body")])) else { throw R7SweepError.setup("plain") }
        let token = try XCTUnwrap(rig.notes.note(withID: p.noteID)).revisionToken
        let proposed = rig.notes.agentWrite(noteID: p.noteID, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Reviewed"), .text("Proposed")]), agentName: "Agent",
            disposition: .proposal)
        guard case let .success(.pending(proposal)) = proposed else { throw R7SweepError.setup("proposal \(proposed)") }
        guard case let .success(g) = rig.notes.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Gone"), .text("Body")])) else { throw R7SweepError.setup("gone") }
        guard rig.notes.delete(try XCTUnwrap(rig.notes.note(withID: g.noteID))) else { throw R7SweepError.setup("delete") }
        return SweepFixture(target: t.noteID, gone: g.noteID, kept: kept.id, removed: removed.id, proposal: proposal,
                            proposed: p.noteID, plain: plain.noteID, version: version)
    }

    private enum R7SweepError: Error { case setup(String) }

    /// The rule, over every `.decision` store command: with the store's context spent and a row changed on disk from
    /// another context, the command is refused with the fixed message and the rows on disk are byte-equal.
    func testR7SweepEveryDecisionCommandIsRefusedOnASpentContext() async throws {
        let far = Date(timeIntervalSince1970: 4_000_000_000)
        typealias Act = (Rig, SweepFixture) -> Bool
        let commands: [(String, Act)] = [
            ("setPinned", { r, f in r.notes.setPinned(true, noteID: f.target) }),
            ("setTags", { r, f in r.notes.note(withID: f.target).map { r.notes.setTags(["swept"], for: $0) } ?? false }),
            ("delete", { r, f in r.notes.note(withID: f.target).map { r.notes.delete($0) } ?? false }),
            ("deleteRestoredLegacyNote", { r, f in r.notes.deleteRestoredLegacyNote(noteID: f.target) }),
            ("restoreDeleted", { r, f in r.notes.restoreDeleted(noteID: f.gone) }),
            ("keepAsSeparateNote", { r, f in r.notes.keepAsSeparateNote(noteID: f.target) }),
            ("purgeDeleted", { r, _ in !r.notes.purgeDeleted(before: far).isEmpty }),
            ("removeAttachment", { r, f in r.notes.attachments(for: f.target).first { $0.id == f.kept }.map { r.notes.removeAttachment($0) } ?? false }),
            ("restoreAttachment", { r, f in r.notes.restoreAttachment(f.removed) }),
            ("purgeRemovedAttachments", { r, _ in r.notes.purgeRemovedAttachments(before: far) > 0 }),
            ("recordVersion", { r, f in r.notes.recordVersion(noteID: f.target, reason: .pause) }),
            ("thinVersions", { r, f in r.notes.thinVersions(noteID: f.target); return false }),
            ("restoreVersion", { r, f in if case .success = r.notes.restoreVersion(f.version, noteID: f.target) { return true }; return false }),
            ("agentWrite", { r, f in
                guard let token = r.notes.note(withID: f.plain)?.revisionToken else { return false }
                if case .success = r.notes.agentWrite(noteID: f.plain, baseRevisionToken: token,
                    document: NoteDocument(blocks: [.text("Plain"), .text("Agent")]), agentName: "Agent", disposition: .direct) { return true }
                return false }),
            ("applyPendingEdits", { r, f in r.notes.applyPendingEdits(noteID: f.proposed) > 0 }),
            ("agentDelete", { r, f in
                guard let token = r.notes.note(withID: f.plain)?.revisionToken else { return false }
                if case .success = r.notes.agentDelete(noteID: f.plain, baseRevisionToken: token, agentName: "Agent",
                                                       disposition: .direct) { return true }
                return false }),
            ("acknowledgeExternalEdit", { r, f in r.notes.acknowledgeExternalEdit(noteID: f.plain) }),
            ("replaceWithProposal", { r, f in
                guard let note = r.notes.note(withID: f.proposed), let row = try? r.notes.pendingEditRows(f.proposal).first,
                      let current = self.document(note.content) else { return false }
                if case .success = r.notes.replaceWithProposal(f.proposal, noteID: f.proposed, expectedRevision: note.revisionToken,
                    expectedSavedContent: note.content, expectedProposal: NoteProposalSignature(row), preserving: current) { return true }
                return false }),
            ("createDocumentNote(resolvingProposal:)", { r, f in
                if case .success = r.notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Reviewed"), .text("Proposed")]),
                                                              resolvingProposal: f.proposal) { return true }
                return false }),
            ("undoAgentCreatedNote", { r, f in
                guard let note = r.notes.note(withID: f.plain), let metadata = r.notes.agentCreatedNoteMetadata(f.plain) else { return false }
                return r.notes.undoAgentCreatedNote(f.plain, revision: note.revisionToken, metadata: metadata) }),
        ]
        var summary: [String] = []
        for (name, act) in commands {
            let rig = try await makeRig()
            let fixture = try sweepFixture(rig)
            XCTAssertEqual(spend(rig), true, "\(name): the store's context is spent")
            let outside = ModelContext(rig.container)
            for row in try outside.fetch(FetchDescriptor<NoteItem>()) where row.title == "Note 2" { row.title = "Note 2 (elsewhere)" }
            try outside.save()
            let before = try R7Rows.snapshot(rig.container)
            let applied = act(rig, fixture)
            let after = try R7Rows.snapshot(rig.container)
            let message = rig.notes.lastErrorMessage
            summary.append("\(name):applied=\(applied),wrote=\(after != before),refusal=\(message == R7Rows.refusal)")
            XCTAssertFalse(applied, "\(name) is refused")
            XCTAssertEqual(message, R7Rows.refusal, "\(name) is refused at its entry with the fixed message")
            XCTAssertEqual(after, before, "\(name): the rows on disk are byte-equal")
            await finish(rig)
            R5Seams.reset()
        }
        print("R7_SWEEP " + summary.joined(separator: " "))
    }

    /// HOLD 4. B's proof is cached; another context clears B's payload. A save then fails its first reload, and the
    /// store goes on: (plain-guard) an unrelated pin whose plain commit cannot update its guard, then reads; or
    /// (document) a document save on A with a file, whose save reload fails and whose document reload succeeds.
    /// Either way the save is durable and B's store-only verification finds nothing. (Every `saveDocument` restages
    /// the content, so a document save is journaled: Astra's "plain document save" is the two arms together.)
    func testR7H4AFailedReloadKeepsNoAttachmentProof() async throws {
        for arm in ["plain-guard", "document"] {
            let rig = try await makeRig()
            let fileB = staged("b.pdf"), fileA = staged("a.pdf")
            guard case let .success(b) = rig.notes.createDocumentNote(id: UUID(),
                document: NoteDocument(blocks: [.text("B"), fileBlock(fileB)]), staged: [fileB]) else { return XCTFail("create B") }
            guard case let .success(a) = rig.notes.createDocumentNote(id: UUID(),
                document: NoteDocument(blocks: [.text("A"), .text("Body")])) else { return XCTFail("create A") }
            let primed = await rig.notes.verifiedAttachmentBytes(fileB.id, allowMaterialized: false)
            XCTAssertNotNil(primed, "\(arm): B's proof is cached")
            let outside = ModelContext(rig.container)
            let bFile = fileB.id, aID = a.noteID
            for row in try outside.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == bFile })) { row.payload = nil }
            try outside.save()
            let durable: Bool
            var fired: Bool?
            rig.notes.reloadFailures = 1
            if arm == "plain-guard" {
                R5Seams.armPlainCommitSpend()
                let other = try XCTUnwrap(rig.notes.notes.first { $0.title == "Note 1" })
                durable = rig.notes.setPinned(true, noteID: other.id)
                fired = R5Seams.plainCommitSpendFired()
                XCTAssertEqual(fired, true, "\(arm): the plain commit's guard update failed")
            } else {
                let saved = rig.notes.saveDocument(noteID: aID, document: NoteDocument(blocks: [.text("A"), .text("Edited"), fileBlock(fileA)]),
                                                   baseRevisionID: a.revisionID, staged: [fileA])
                if case .success = saved { durable = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == aID }))
                    .allSatisfy { self.document($0.content)?.blocks.contains { $0.text == "Edited" } == true } } else { durable = false }
            }
            let reloadFailed = rig.notes.reloadFailures == 0
            rig.notes.reloadFailures = 0
            let after = await rig.notes.verifiedAttachmentBytes(fileB.id, allowMaterialized: false)
            print("R7_H4 arm=\(arm) durable=\(durable) plain_guard_fired=\(fired.map { "\($0)" } ?? "n/a") reload_failed=\(reloadFailed) "
                + "b_after=\(after != nil) b_distinct=\(b.noteID != aID)")
            XCTAssertTrue(durable, "\(arm): the save succeeds and is durable")
            XCTAssertTrue(reloadFailed, "\(arm): exactly one reload failed")
            XCTAssertNil(after, "\(arm): B's store-only verification finds no payload")
            await finish(rig)
            R5Seams.reset()
        }
    }
}
