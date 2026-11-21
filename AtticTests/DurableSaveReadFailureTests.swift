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
        XCTAssertGreaterThan(reconciliationReads, 0, "The reconciliation read ran and failed")
        XCTAssertEqual(durable, 1, "The insert is durable once")
        XCTAssertNotNil(created, "A durable insert is reported as created")
        XCTAssertTrue(next, "The next edit works")
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

    /// Control for the purge observation: the same rig with its one preservation row. Purge succeeds and reaches it.
    func testC8OnePreservationRowPurgeControl() async throws {
        let run = try await twoPreservationRows("purge", copyingDependencyOwners: true, addingSecondRow: false)
        XCTAssertFalse(run.refused, "purge: one preservation row is purged")
        XCTAssertEqual(run.records, 1)
        XCTAssertEqual(run.purged, 1, "purge: the record is marked purged")
        XCTAssertEqual(run.taskRows, 0, "purge: the task's rows are gone")
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

    private func twoPreservationRows(_ command: String, copyingDependencyOwners: Bool, addingSecondRow: Bool = true) async throws
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
        if addingSecondRow { seed.insert(copy); try seed.save() }
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
        print("C8_TWO_ROWS \(command) second_row=\(addingSecondRow) copied_dependency_owners=\(copyingDependencyOwners) result=\(result) "
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
            XCTAssertTrue(first.contains("changed since"), "\(arm): the first write is refused as stale, with a retryable reason")
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
            let deleted = rig.library.delete(AtticItemRef(.note, noteID))
            let reloadsFailed = failures - rig.notes.reloadFailures
            rig.notes.reloadFailures = 0
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
            let undone = rig.notes.undoAgentCreatedNote(agentNoteID, revision: revision, metadata: metadata)
            let reloadsFailed = failures - rig.notes.reloadFailures
            rig.notes.reloadFailures = 0
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
    override func tearDown() {
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
            let presented = rig.notes.note(withID: noteID).map { "\($0.revisionToken == token):\($0.body)" } ?? "nil"
            let request = actions.beginRequest(title: "Rename a note")
            var outcome = "nil"
            do {
                let call = try await actions.call(name: "update_note", arguments: [
                    "id": noteID.uuidString, "title": "Renamed by agent", "base_revision": token], watching: false, requestID: request)
                if case let .performed(result) = call { outcome = "performed \(result.text)" } else { outcome = "\(call)" }
            } catch { outcome = "threw \(error)" }
            let afterAction = try noteRows(rig.container, noteID).map { blocks($0.content) }
            let steps = actions.changeSet(for: request)?.count ?? 0
            let undone = await actions.undo(changeSet: request)
            let afterUndo = try noteRows(rig.container, noteID).map { blocks($0.content) }
            print("R5_H2 build=\(R5Seams.build) arm=\(arm) spent=\(spent.map { "\($0)" } ?? "n/a") presented=\(presented) "
                + "outcome=\(outcome.prefix(160)) after_action=\(afterAction) steps=\(steps) undone=\(undone.undone) "
                + "failures=\(undone.failures) after_undo=\(afterUndo)")
            XCTAssertEqual(afterAction.count, 2, "\(arm): both physical rows remain")
            XCTAssertTrue(afterAction.allSatisfy { $0?.last == "Newer body" }, "\(arm): the newer body survives the title-only edit")
            XCTAssertTrue(afterUndo.allSatisfy { $0?.last == "Newer body" }, "\(arm): Undo never writes back the older body")
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
            let undone = rig.library.undo(in: .note(noteID))
            let stored = try noteRows(rig.container, noteID).map { AtticTag.decode($0.tagsRaw) }
            print("R5_H4 build=\(R5Seams.build) arm=\(arm) spent=\(spent.map { "\($0)" } ?? "n/a") presented=\(presented) "
                + "undone=\(undone) stored=\(stored) error=\(rig.notes.lastErrorMessage ?? "nil")")
            XCTAssertFalse(stored.isEmpty)
            XCTAssertTrue(stored.allSatisfy { $0.contains("keep") }, "\(arm): the tag added elsewhere survives Undo")
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
            default: rig.notes.refresh(); installed = true
            }
            let cachedAfter = rig.notes.cachedVerifiedAttachmentBytes(item.id) != nil
            let after = await rig.notes.verifiedAttachmentBytes(item.id, allowMaterialized: false)
            print("R5_H5 build=\(R5Seams.build) arm=\(arm) first=\(first != nil) cached_before=\(cachedBefore) "
                + "spent=\(spent.map { "\($0)" } ?? "n/a") installed=\(installed) cached_after=\(cachedAfter) after=\(after != nil)")
            XCTAssertNotNil(first, "\(arm): the payload verified before the outside write")
            XCTAssertTrue(installed, "\(arm): a fresh context is installed")
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
    static let proofArms = ["spent-prepare", "local-save", "refresh"]

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

    /// PR 40's staging entry: replaces a spent context, keeping attachment proofs.
    static func prepareNotes(_ notes: NoteStore) -> Bool { notes.prepareNoteEdit() }
}
