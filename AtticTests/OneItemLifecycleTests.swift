import Foundation
import SwiftData
import XCTest
@testable import Attic

/// Owner decision 2026-10-23: one deletion/restore for the whole item.
@MainActor
final class OneItemLifecycleTests: XCTestCase {
    private var container: ModelContainer!
    private var coordinator: WorkspaceOperationCoordinator!
    private var tasks: TaskStore!
    private var notes: NoteStore!
    private var library: AtticLibrary!
    private var files: TaskImageFiles!
    private let root = UUID(), child = UUID(), note = UUID(), alternate = UUID(), earlier = UUID()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        files = TaskImageFiles(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("AtticItemTests-\(UUID())"))
        let context = ModelContext(container)
        let document = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Parent"), .text("Writing")], requires: ["taskNote"]))
        for _ in 0..<2 {
            let task = TaskItem(id: root, title: "Parent", status: .done, createdAt: date, completedAt: date, manualOrder: 42)
            task.doneLoggedAt = date
            context.insert(task)
            context.insert(TaskItem(id: child, title: "Child", createdAt: date, parentID: root))
            let old = TaskItem(id: earlier, title: "Earlier", createdAt: date, parentID: root)
            old.deletedAt = date; old.deletionRootID = earlier; old.deletionMembersRaw = earlier.uuidString
            context.insert(old)
            for id in [note, alternate] {
                let row = NoteItem(id: id, title: "Parent", body: "Writing", createdAt: date)
                row.taskID = root
                row.content = document
                context.insert(row)
            }
        }
        try context.save()
        let fixedDate = date
        tasks = TaskStore(container: container, now: { fixedDate }, taskImageFiles: files)
        notes = NoteStore(container: container, now: { fixedDate }, attachmentFileStore: makeTestAttachmentFileStore())
        library = AtticLibrary(tasks: tasks, notes: notes)
        await notes.waitForAttachmentReconciliation()
    }

    override func tearDown() async throws {
        await coordinator.lifecycleNotes?.waitForRecoveryWork()
        await notes.waitForAttachmentReconciliation()
        library = nil; tasks = nil; notes = nil; coordinator = nil; container = nil; files = nil
    }

    private func rows() throws -> ([TaskItem], [NoteItem]) {
        let context = ModelContext(container)
        return try (context.fetch(FetchDescriptor<TaskItem>()), context.fetch(FetchDescriptor<NoteItem>()))
    }
    private func group(_ model: any PersistentModel) throws -> UUID? {
        guard let field = try WorkspaceModelFields.read(model)["deletionGroupID"] else { return nil }
        return try JSONDecoder().decode(UUID?.self, from: field)
    }

    func testTaskDeleteFansOutS10AndRestoreReturnsExactPlacement() throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let (t, n) = try rows()
        XCTAssertTrue(n.allSatisfy { $0.deletedAt == date }, "writing and unresolved alternates go together")
        let id = try XCTUnwrap(group(t.first { $0.id == root }!))
        for row in t where row.id != earlier { XCTAssertEqual(try group(row), id) }
        for row in n { XCTAssertEqual(try group(row), id) }
        for row in t where row.id == earlier { XCTAssertNil(try group(row)) }
        XCTAssertEqual(library.recentlyDeleted().count, 2, "one item row plus the earlier child deletion")
        XCTAssertTrue(library.restore(AtticItemRef(.note, alternate)))
        let (restored, writing) = try rows()
        XCTAssertTrue(writing.allSatisfy { $0.deletedAt == nil })
        for row in restored where row.id == root {
            XCTAssertNil(row.deletedAt); XCTAssertEqual(row.status, .done)
            XCTAssertEqual(row.doneLoggedAt, date); XCTAssertEqual(row.manualOrder, 42)
        }
        XCTAssertTrue(restored.filter { $0.id == earlier }.allSatisfy { $0.deletedAt == date })
    }

    func testNoteAliasDeleteTakesTaskAndUndoRestoresAll() throws {
        XCTAssertTrue(library.delete(AtticItemRef(.note, note)))
        XCTAssertTrue(try rows().0.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(library.undo.undo(in: .note(note)))
        XCTAssertTrue(try rows().0.filter { $0.id != earlier }.allSatisfy { $0.deletedAt == nil })
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt == nil })
    }

    func testFailedSaveRollsBackWholeItemAndHistory() throws {
        enum Failure: Error { case save }
        let fixedDate = date
        tasks = TaskStore(container: container, now: { fixedDate }, persist: { _ in throw Failure.save }, taskImageFiles: files)
        library = AtticLibrary(tasks: tasks, notes: notes)
        XCTAssertFalse(library.deleteListedTasks([root]).isApplied)
        XCTAssertTrue(try rows().0.filter { $0.id != earlier }.allSatisfy { $0.deletedAt == nil })
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt == nil })
        XCTAssertFalse(library.undo.canUndo(in: .tasks))
    }

    func testPurgeRemovesGroupTogetherAndNeverEarlierDelete() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let proofContext = ModelContext(container)
        XCTAssertEqual(try TaskStore.guardedDeletedFamily(in: proofContext, rootID: root, before: .distantFuture)?.count, 4)
        for copies in Dictionary(grouping: try proofContext.fetch(FetchDescriptor<TaskItem>()), by: \.id).values {
            let first = try WorkspaceModelFields.read(copies[0])
            for copy in copies.dropFirst() { XCTAssertEqual(try WorkspaceModelFields.read(copy), first, "physical task replicas must start equal") }
        }
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: tasks.taskImageFiles, inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(Set(try rows().0.map(\.id)), [earlier])
        XCTAssertTrue(try rows().1.isEmpty)
    }

    func testDivergentWritingReplicaKeepsEntirePurgeGroup() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first)
        row.body = "diverged"; try context.save()
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: tasks.taskImageFiles, inventory: { .init(generation: 0) })
        XCTAssertNotEqual(result.outcome, .committed)
        XCTAssertEqual(try rows().0.count, 6); XCTAssertEqual(try rows().1.count, 4)
    }
    func testLegacyPurgeConvertsWritingToCheckboxesWithoutTaskMetadata() async throws {
        let context = WorkspaceLegacyBridge.context(for: container)
        try TaskStore.stageSoftDeletion(in: context, taskID: root, preservationID: UUID(), timestamp: date)
        try context.save() // Fixture of a pre-2026-10-23 independent deletion.
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: tasks.taskImageFiles, inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .committed)
        for row in try rows().1 {
            XCTAssertNil(row.taskID)
            let doc = try XCTUnwrap(row.content.flatMap { NoteContentCodec.decode($0).document })
            XCTAssertFalse(doc.requires.contains("taskNote"))
            XCTAssertEqual(doc.blocks.map(\.text), ["Parent", "Child", "Writing"])
            XCTAssertEqual(doc.blocks[1].kind, .checklist)
        }
    }

    func testRestorePreservesEarlierDeletedPhysicalReplica() throws {
        let context = ModelContext(container), oldGroup = UUID()
        let old = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == root })
        old.deletedAt = date.addingTimeInterval(-10); old.deletionGroupID = oldGroup
        old.deletionRootID = root; old.deletionMembersRaw = root.uuidString
        old.updatedAt = date.addingTimeInterval(-10)
        try context.save(); tasks.refresh()
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        XCTAssertTrue(library.restore(AtticItemRef(.task, root)))
        let copies = try rows().0.filter { $0.id == root }
        XCTAssertEqual(copies.filter { $0.deletedAt == nil }.count, 1)
        XCTAssertEqual(copies.first { $0.deletionGroupID == oldGroup }?.deletedAt, date.addingTimeInterval(-10))
    }

    func testUndoRefreshesBothEndpointListsAndRedoRefusesNewWriting() throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        XCTAssertTrue(notes.notes.isEmpty)
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(Set(notes.notes.map(\.id)), [note, alternate])
        let context = ModelContext(container), extra = NoteItem(title: "New writing")
        extra.taskID = root; context.insert(extra); try context.save(); notes.refresh()
        XCTAssertFalse(library.undo.redo(in: .tasks), "Redo must not delete later writing")
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt == nil })
    }

    func testPurgeRefusesSurvivingWorkspaceProposal() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container)
        let outside = NoteItem(title: "Other"); context.insert(outside)
        let proposal = NotePendingEdit(noteID: outside.id, baseRevisionToken: "initial",
            proposedContent: try XCTUnwrap(outside.content), agentName: "Agent", createdAt: date)
        proposal.workspaceTaskID = root; context.insert(proposal); try context.save()
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        XCTAssertNotEqual(result.outcome, .committed)
        XCTAssertEqual(try rows().0.count, 6)
    }

    func testPurgeRefusesOutsideAssociationReplica() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container), id = UUID()
        context.insert(TaskNoteAssociation(id: id, taskID: root, noteID: note))
        context.insert(TaskNoteAssociation(id: id, taskID: UUID(), noteID: UUID()))
        try context.save()
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        XCTAssertNotEqual(result.outcome, .committed)
        XCTAssertEqual(try rows().0.count, 6)
    }

    func testCorruptPreservationKeepsWholeGroup() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<TaskDeletionPreservation>()).first)
        record.snapshot = Data("broken preservation".utf8); try context.save()
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        XCTAssertNotEqual(result.outcome, .committed)
        XCTAssertEqual(try rows().0.count, 6); XCTAssertEqual(try rows().1.count, 4)
    }

    func testFailedPurgeSaveKeepsAllRows() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        enum Failure: Error { case save }
        coordinator.save = { _ in throw Failure.save }
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .notCommitted)
        XCTAssertEqual(try rows().0.count, 6); XCTAssertEqual(try rows().1.count, 4)
    }

    func testOlderDeletedWritingWithoutAssociationRestoresAfterGroupPurge() async throws {
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<NoteItem>()) where row.id == note {
            row.deletedAt = date.addingTimeInterval(-10); row.deletedAttachmentIDsRaw = ""
            row.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Stale title"), .text("Old writing")], requires: ["taskNote"]))
        }
        try context.save(); notes.refresh()
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertTrue(notes.restoreDeleted(noteID: note))
        for row in try rows().1 {
            let doc = try XCTUnwrap(row.content.flatMap { NoteContentCodec.decode($0).document })
            XCTAssertEqual(doc.blocks.map(\.text), ["Parent", "Child", "Old writing"])
            XCTAssertFalse(doc.requires.contains("taskNote")); XCTAssertNil(row.taskID)
        }
    }

    func testLiveWritingOfLegacyDeletedTaskCanBeDeletedIndependently() throws {
        let context = WorkspaceLegacyBridge.context(for: container)
        try TaskStore.stageSoftDeletion(in: context, taskID: root, preservationID: UUID(), timestamp: date)
        try context.save(); tasks.refresh(); notes.refresh()
        XCTAssertTrue(library.delete(AtticItemRef(.note, note)))
        XCTAssertTrue(try rows().1.filter { $0.id == note }.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(try rows().1.filter { $0.id == alternate }.allSatisfy { $0.deletedAt == nil })
    }

    func testAgentPairedDeleteRequiresCombinedTokenAndStaleCallIsOneProposal() async throws {
        let controller = NotesPageController(store: notes, journal: coordinator.journal)
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: library)
        tools.notesController = { controller }
        XCTAssertThrowsError(try tools.call(name: "delete_task", arguments: ["id": root.uuidString]))
        let readSet = try AgentWorkspaceReadSet.capture(taskID: root, noteID: nil, in: ModelContext(container))
        let token = try WorkspaceModelFields.encode(readSet).base64EncodedString()
        let context = ModelContext(container)
        for task in try context.fetch(FetchDescriptor<TaskItem>()) where task.id == root { task.title = "Changed" }
        try context.save(); tasks.refresh()
        let response = try await tools.callAsync(name: "delete_task", arguments: ["id": root.uuidString, "base_workspace_token": token])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "pending")
        XCTAssertTrue(try rows().0.filter { $0.id != earlier }.allSatisfy { $0.deletedAt == nil })
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt == nil })
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NotePendingEdit>()), 1)
        await controller.waitForRecoveryWork()
    }

    func testRemovedFilesStayRemovedOnRestoreAndPurgeWithTheirItem() async throws {
        let context = ModelContext(container), shown = UUID(), removed = UUID(), bytes = Data("file bytes".utf8)
        for id in [shown, removed] {
            let file = NoteAttachment(id: id, noteID: note, originalFilename: "file.txt", byteCount: Int64(bytes.count),
                sortIndex: id == shown ? 0 : 1, contentDigest: NotePayloadDigest.sha256(bytes), createdAt: date, payload: bytes)
            if id == removed { file.deletedAt = date.addingTimeInterval(-10) }
            context.insert(file)
        }
        try context.save(); notes.refresh()
        let scope = try XCTUnwrap(library.deletionScope(for: root))
        XCTAssertTrue(scope.hasWriting); XCTAssertEqual(scope.subtaskCount, 1); XCTAssertEqual(scope.fileCount, 2)
        XCTAssertEqual(scope.confirmationMessage, "Its writing, 1 subtask and 2 files go to Recently Deleted for 30 days.")
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        XCTAssertTrue(library.restore(AtticItemRef(.task, root)))
        let restored = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertNil(restored.first { $0.id == shown }?.deletedAt)
        XCTAssertEqual(restored.first { $0.id == removed }?.deletedAt, date.addingTimeInterval(-10))
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 0)
    }

    func testChangedButReadablePreservationKeepsWholeGroup() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<TaskDeletionPreservation>()).first)
        let old = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot)
        let changed = old.members.map { member in
            var fields = member.fields
            if member.id == root { fields["title"] = try? WorkspaceModelFields.encode("Wrong title") }
            return WorkspacePurge.Preservation.Member(id: member.id, fields: fields, replicas: member.replicas)
        }
        record.snapshot = try WorkspaceModelFields.encode(WorkspacePurge.Preservation(rootID: old.rootID, title: old.title,
            members: changed, originals: old.originals, dependencies: old.dependencies))
        try context.save()
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        XCTAssertNotEqual(result.outcome, .committed)
        XCTAssertEqual(try rows().0.count, 6); XCTAssertEqual(try rows().1.count, 4)
    }

    func testUnreadableOwnProposalKeepsWholeGroup() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container)
        context.insert(NotePendingEdit(noteID: note, baseRevisionToken: "old", proposedContent: Data("unreadable".utf8), agentName: "Agent", createdAt: date))
        try context.save()
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        XCTAssertNotEqual(result.outcome, .committed)
        XCTAssertEqual(try rows().0.count, 6)
    }

    func testSharedLegacyBytesSurviveGroupPurgeWithAReason() async throws {
        let input = ownedTemporaryDirectory(prefix: "AtticSharedBytes").appendingPathComponent("shared.txt")
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("shared original".utf8); try data.write(to: input)
        let refs = try await files.importAttachments([input], existing: [])
        let reference = try XCTUnwrap(refs.first), context = ModelContext(container)
        let encodedReferences = try JSONEncoder().encode(refs)
        for row in try context.fetch(FetchDescriptor<TaskItem>()) where row.id == root { row.imageReferencesData = encodedReferences }
        let other = TaskItem(title: "Other owner"); other.imageReferencesData = encodedReferences; context.insert(other)
        try context.save(); tasks.refresh()
        // This fixture bound imports with a raw model save; finish the
        // import admission that TaskStore.save normally releases on commit.
        files.files.finishCandidates(Set(refs.map(\.id)))
        XCTAssertEqual(Set(try rows().0.filter { $0.id == root }.compactMap(\.imageReferencesData)).count, 1,
            "The positive purge fixture must have byte-identical physical attachment metadata")
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .committed, result.retentionReason ?? "The coordinated commit refused.")
        XCTAssertNotNil(result.retainedByteReasons[reference.id])
        let url = try await files.verifiedURL(for: reference)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), data)
        XCTAssertTrue(try rows().0.contains { $0.id == other.id })
    }

    func testOldDeleteUndoCannotRestoreLaterGroup() throws {
        for alias in [AtticItemRef(.task, root), AtticItemRef(.note, note)] {
            let old = library.itemOwnership([root, child], deleted: false)
            XCTAssertTrue(alias.kind == .task ? library.deleteListedTasks([root], in: .taskWorkspace(root)).isApplied : library.delete(alias, in: .taskWorkspace(root)))
            let deleted = library.itemOwnership([root, child], deleted: true)
            old.groups = deleted.groups; old.writing = deleted.writing
            XCTAssertTrue(library.restore(alias))
            let context = ModelContext(container), extra = NoteItem(title: "Later writing")
            extra.taskID = root; context.insert(extra); try context.save(); notes.refresh()
            XCTAssertTrue(alias.kind == .task ? library.deleteListedTasks([root], in: .taskWorkspace(root)).isApplied : library.delete(alias, in: .taskWorkspace(root)))
            XCTAssertEqual(library.restoreOutcome(alias, owning: old), .obsolete)
            XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt != nil })
            XCTAssertTrue(library.restore(alias))
        }
    }

    func testRestoreRefusesLostWritingOrRootMembership() throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container)
        let changed = try context.fetch(FetchDescriptor<NoteItem>()).filter { $0.id == note }
        let group = try XCTUnwrap(changed.first?.deletionGroupID)
        for row in changed { row.deletionGroupID = nil }
        try context.save()
        XCTAssertFalse(library.restore(AtticItemRef(.task, root)))
        XCTAssertTrue(try rows().0.allSatisfy { $0.deletedAt != nil })
        for row in changed { row.deletionGroupID = group }
        for row in try context.fetch(FetchDescriptor<TaskItem>()) where row.deletionGroupID == group { row.deletionRootID = nil }
        try context.save()
        XCTAssertFalse(library.restore(AtticItemRef(.task, root)))
        XCTAssertTrue(try rows().0.allSatisfy { $0.deletedAt != nil })
    }

    func testGroupedLegacyWritingMaterializesAfterOldTaskPurge() async throws {
        let context = WorkspaceLegacyBridge.context(for: container)
        try TaskStore.stageSoftDeletion(in: context, taskID: root, preservationID: UUID(), timestamp: date)
        try context.save(); tasks.refresh(); notes.refresh()
        XCTAssertTrue(library.delete(AtticItemRef(.note, note)))
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertTrue(library.restore(AtticItemRef(.note, note)))
        for row in try rows().1 where row.id == note {
            let document = try XCTUnwrap(row.content.flatMap { NoteContentCodec.decode($0).document })
            XCTAssertFalse(document.requires.contains("taskNote"))
            XCTAssertEqual(document.blocks.map(\.text), ["Parent", "Child", "Writing"])
            XCTAssertNil(row.taskID)
        }
    }

    func testAssociationOnlyAliasRedoRefusesLaterFamilyAndReassociation() throws {
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<NoteItem>()) where row.id == note { row.taskID = nil }
        let association = TaskNoteAssociation(taskID: root, noteID: note)
        context.insert(association); try context.save(); notes.refresh()
        XCTAssertTrue(library.delete(AtticItemRef(.note, note)))
        XCTAssertTrue(library.undo.undo(in: .note(note)))
        let later = TaskItem(title: "Later child", parentID: root)
        context.insert(later); try context.save(); tasks.refresh()
        XCTAssertFalse(library.undo.redo(in: .note(note)))
        XCTAssertNil(try rows().0.first { $0.id == later.id }?.deletedAt)
        _ = library.restore(AtticItemRef(.note, note))
        let owned = library.itemOwnership([root, child], deleted: false)
        let other = TaskItem(title: "Other task"); context.insert(other)
        for row in try context.fetch(FetchDescriptor<TaskNoteAssociation>()) where row.id == association.id { row.taskID = other.id }
        try context.save(); tasks.refresh()
        XCTAssertEqual(library.deleteOutcome(AtticItemRef(.note, note), owning: owned), .obsolete)
        XCTAssertNil(try rows().0.first { $0.id == other.id }?.deletedAt)
    }

    func testBulkRestoreUndoCannotDeleteNewWriting() throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [.init(.task, root)], attachments: []).restored, 1)
        let context = ModelContext(container), extra = NoteItem(title: "Later writing")
        extra.taskID = root; context.insert(extra); try context.save(); notes.refresh()
        XCTAssertFalse(library.undo.undo(in: .library))
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt == nil })
    }

    func testAgentRestoreAliasesRequireWholeItemToken() throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: library)
        XCTAssertThrowsError(try tools.call(name: "restore_item", arguments: ["kind": "note", "id": note.uuidString]))
        XCTAssertThrowsError(try tools.call(name: "restore_items", arguments: ["items": [["kind": "task", "id": root.uuidString]]]))
        XCTAssertTrue(try rows().0.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt != nil })
    }

    func testNativeNotesDeleteUndoCannotReachLaterWholeItemGroup() async throws {
        let ordinary = try XCTUnwrap(notes.create(title: "Ordinary"))
        let id = ordinary.id, controller = NotesPageController(store: notes, journal: coordinator.journal)
        await controller.startAndWait()
        XCTAssertTrue(controller.deleteNote(noteID: id))
        XCTAssertTrue(library.restore(.init(.note, id)))
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<NoteItem>()) where row.id == id { row.taskID = root }
        try context.save(); notes.refresh()
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        XCTAssertFalse(controller.undoLibrary())
        XCTAssertTrue(try rows().0.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt != nil })
        await controller.waitForRecoveryWork()
    }

    func testNativeDuplicateUndoRefusesReassociatedTask() async throws {
        let source = try XCTUnwrap(notes.create(title: "Source")), controller = NotesPageController(store: notes, journal: coordinator.journal)
        await controller.startAndWait()
        let before = Set(notes.notes.map(\.id))
        let copied = await controller.duplicateNote(noteID: source.id); XCTAssertTrue(copied)
        let id = try XCTUnwrap(Set(notes.notes.map(\.id)).subtracting(before).first), context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<NoteItem>()) where row.id == id { row.taskID = root }
        try context.save(); notes.refresh()
        XCTAssertFalse(controller.undoLibrary())
        XCTAssertTrue(try rows().0.filter { $0.id != earlier }.allSatisfy { $0.deletedAt == nil })
        await controller.waitForRecoveryWork()
    }

    func testIdenticalPreservationReplicasRestoreTogether() throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<TaskDeletionPreservation>()).first)
        let copy = TaskDeletionPreservation(id: record.id, rootID: record.rootID, deletedAt: record.deletedAt,
            capturedAt: record.capturedAt, provenance: record.provenance, snapshot: record.snapshot)
        copy.dependencyOwnersData = record.dependencyOwnersData; context.insert(copy); try context.save()
        XCTAssertTrue(library.restore(.init(.task, root)))
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt == nil })
    }

    func testUnreadableMigrationOwnershipRefusesBeforeGroupPurge() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container)
        let migration = TaskAttachmentMigrationRecord(id: UUID(), noteID: UUID())
        migration.manifestData = Data("broken".utf8); context.insert(migration)
        try context.save()
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        XCTAssertNotEqual(result.outcome, .committed)
        XCTAssertEqual(try rows().0.count, 6); XCTAssertEqual(try rows().1.count, 4)
    }

    func testAgentAssociationOnlyAliasUsesWholeItemToken() async throws {
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<NoteItem>()) where row.id == note { row.taskID = nil }
        context.insert(TaskNoteAssociation(taskID: root, noteID: note)); try context.save(); notes.refresh()
        let controller = NotesPageController(store: notes, journal: coordinator.journal)
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: library); tools.notesController = { controller }
        XCTAssertThrowsError(try tools.call(name: "delete_note", arguments: ["id": note.uuidString, "base_revision": try XCTUnwrap(notes.note(withID: note)).revisionToken]))
        let readSet = try AgentWorkspaceReadSet.capture(taskID: root, noteID: nil, in: ModelContext(container))
        let token = try WorkspaceModelFields.encode(readSet).base64EncodedString()
        do {
            _ = try await tools.callAsync(name: "delete_note", arguments: ["id": note.uuidString, "base_workspace_token": token])
        } catch { XCTFail("Association-only alias must accept its combined token: \(error)") }
        XCTAssertTrue(try rows().0.allSatisfy { $0.deletedAt != nil })
        await controller.waitForRecoveryWork()
    }

    func testRestoreRequiresCapturedWritingOwnership() throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container)
        let changed = try context.fetch(FetchDescriptor<NoteItem>()).filter { $0.id == note }
        for row in changed { row.taskID = nil }
        try context.save()
        XCTAssertFalse(library.restore(.init(.task, root)))
        XCTAssertTrue(try rows().0.allSatisfy { $0.deletedAt != nil })
    }

    func testRestoreRefusesExtraGroupWritingMember() throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container)
        let group = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == root }?.deletionGroupID)
        let extra = NoteItem(title: "Unknown group member")
        extra.taskID = root; extra.deletionGroupID = group; extra.deletedAt = date
        extra.deletedAttachmentIDsRaw = ""; context.insert(extra); try context.save()
        XCTAssertFalse(library.restore(.init(.task, root)))
        XCTAssertTrue(try rows().0.allSatisfy { $0.deletedAt != nil })
    }

    func testRestoreLeavesPreviouslyDeletedWritingReplicaEvenAtSameTimestamp() throws {
        let context = ModelContext(container), oldGroup = UUID()
        let old = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first { $0.id == note })
        old.deletedAt = date; old.deletionGroupID = oldGroup; old.deletedAttachmentIDsRaw = ""
        try context.save(); notes.refresh()
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        XCTAssertTrue(library.restore(.init(.task, root)))
        let copies = try rows().1.filter { $0.id == note }
        XCTAssertEqual(copies.filter { $0.deletedAt == nil }.count, 1)
        XCTAssertEqual(copies.first { $0.deletionGroupID == oldGroup }?.deletedAt, date)
    }

    func testOrdinaryWritingRestoreKeepsPreviouslyDeletedPhysicalReplica() throws {
        let context = ModelContext(container), id = UUID()
        let old = NoteItem(id: id, title: "Ordinary", createdAt: date.addingTimeInterval(-10))
        old.updatedAt = date.addingTimeInterval(-1)
        old.deletedAt = date; old.deletedAttachmentIDsRaw = ""
        context.insert(old); context.insert(NoteItem(id: id, title: "Ordinary", createdAt: date))
        try context.save(); notes.refresh()
        XCTAssertTrue(library.delete(.init(.note, id)))
        XCTAssertTrue(library.restore(.init(.note, id)))
        let copies = try rows().1.filter { $0.id == id }
        XCTAssertEqual(copies.filter { $0.deletedAt == nil }.count, 1)
        XCTAssertEqual(copies.filter { $0.deletedAt == date && $0.deletionGroupID == nil }.count, 1)
    }

    func testPurgeRechecksAbsenceWhenFirstOutsideProposalArrivesDuringPreparation() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        var inserted = false
        let taskID = root, instant = date, fixtureContainer = container!
        let content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Outside")]))
        coordinator.afterPreparation = {
            let context = ModelContext(fixtureContainer)
            let proposal = NotePendingEdit(noteID: UUID(), baseRevisionToken: "outside",
                proposedContent: content, agentName: "Agent", createdAt: instant)
            proposal.workspaceTaskID = taskID; context.insert(proposal)
            do { try context.save(); inserted = true } catch { XCTFail("Could not inject external proposal: \(error)") }
        }
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        coordinator.afterPreparation = nil
        XCTAssertTrue(inserted)
        XCTAssertNotEqual(result.outcome, .committed)
        XCTAssertEqual(try rows().0.count, 6); XCTAssertEqual(try rows().1.count, 4)
    }

}
