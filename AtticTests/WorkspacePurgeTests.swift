import Foundation
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class WorkspacePurgeTests: XCTestCase {
    private var root: URL!
    private var coordinator: WorkspaceOperationCoordinator!
    private var files: TaskImageFiles!
    private var taskID: UUID!
    private var noteID: UUID!
    private var ownership: WorkspacePurge.Inventory?
    private let deletion = Date(timeIntervalSince1970: 100)
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticPurge-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        coordinator = try WorkspaceOperationCoordinator(container: container, journal: NoteDraftJournal(directory: root.appendingPathComponent("Journal")))
        files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
        taskID = UUID(); noteID = UUID(); ownership = .init(generation: 0)
    }
    override func tearDown() async throws {
        coordinator = nil; files = nil; try FileManager.default.removeItem(at: root)
    }
    private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, file: file, line: line) }
    private func seed(note: Bool = false, deletedNote: Bool = false, reference: TaskImageReference? = nil) throws {
        let context = coordinator.freshContext()
        let task = TaskItem(id: taskID, title: "Current task")
        task.deletedAt = deletion; task.deletionRootID = taskID; task.deletionMembersRaw = taskID.uuidString
        if let reference { task.imageReferencesData = try JSONEncoder().encode([reference]) }
        context.insert(task)
        if note {
            let document = try NoteDocument(blocks: [.text("Old compatibility"), .text("body")]).taskSnapshot(title: "Old compatibility")
            let row = NoteItem(id: noteID); row.taskID = taskID
            NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [row], timestamp: deletion, revision: 0, revisionID: UUID())
            if deletedNote { row.deletedAt = deletion }
            context.insert(row)
        }
        try context.save()
    }
    private func purge() async -> WorkspacePurge.Result {
        await WorkspacePurge.purge(rootID: taskID, before: .distantFuture, coordinator: coordinator, files: files, inventory: { self.ownership })
    }
    private func note() throws -> NoteItem {
        let id = noteID!
        return try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first)
    }
    private func document() throws -> NoteDocument { try XCTUnwrap(try note().content.flatMap { NoteContentCodec.decode($0).document }) }
    private func tasks() throws -> Int { try coordinator.freshContext().fetchCount(FetchDescriptor<TaskItem>()) }
    private func records() throws -> [TaskDeletionPreservation] { try coordinator.freshContext().fetch(FetchDescriptor<TaskDeletionPreservation>()) }

    func testP3NewDeletionCapturesEveryReplicaAndDependenciesWithSoftDelete() async throws {
        let context = coordinator.freshContext(), task = TaskItem(id: taskID, title: "Before deletion")
        task.listOrderVersion = TaskItem.currentListOrderVersion
        context.insert(task)
        let note = NoteItem(id: noteID); note.taskID = taskID; context.insert(note)
        let association = TaskNoteAssociation(taskID: taskID, noteID: noteID); context.insert(association)
        let version = NoteVersion(noteID: noteID, createdAt: deletion, reason: .beforeRestore, content: nil, contentFormat: 0,
            title: "Historical", body: "body", attachmentIDs: [], sourceRevisionID: note.revisionID)
        context.insert(version); try context.save()
        let store = TaskStore(container: coordinator.container, now: { self.deletion }, taskImageFiles: files)
        XCTAssertTrue(store.delete(taskIDs: [taskID]))
        let record = try XCTUnwrap(records().first), bytes = record.snapshot
        let snapshot = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: bytes)
        expectEqual(record.provenance, "soft deletion"); expectEqual(record.deletedAt, deletion)
        expectEqual(snapshot.members.first?.replicas?.count, 1)
        expectEqual(Set(snapshot.dependencies?.map(\.owner) ?? []), [
            .init(entity: .note, id: noteID), .init(entity: .association, id: association.id), .init(entity: .version, id: version.id)])
        expectEqual(await purge().outcome, .committed)
        expectEqual(try XCTUnwrap(records().first).snapshot, bytes)
        expectEqual(try tasks(), 0)
    }
    func testP3FailedNewDeletionSaveKeepsTasksAndCreatesNoRecord() throws {
        let context = coordinator.freshContext(), task = TaskItem(id: taskID, title: "Kept")
        task.listOrderVersion = TaskItem.currentListOrderVersion; context.insert(task); try context.save()
        let store = TaskStore(container: coordinator.container, persist: { _ in throw WorkspaceFoundationError.preparationFailed }, taskImageFiles: files)
        XCTAssertFalse(store.delete(taskIDs: [taskID])); XCTAssertTrue(try records().isEmpty)
        XCTAssertNil(try coordinator.freshContext().fetch(FetchDescriptor<TaskItem>()).first?.deletedAt)
    }
    func testP3NewCaptureRecordsUnverifiedOriginalWithoutBlockingExclusiveMissingFile() async throws {
        let ref = TaskImageReference(id: UUID(), filename: "missing.txt", digest: NotePayloadDigest.sha256(Data()),
            contentTypeIdentifier: "public.plain-text", byteCount: 0)
        let context = coordinator.freshContext(), task = TaskItem(id: taskID, title: "Kept title")
        task.listOrderVersion = TaskItem.currentListOrderVersion; task.imageReferencesData = try JSONEncoder().encode([ref]); context.insert(task); try context.save()
        let store = TaskStore(container: coordinator.container, now: { self.deletion }, taskImageFiles: files)
        XCTAssertTrue(store.delete(taskIDs: [taskID]))
        let bytes = try XCTUnwrap(records().first).snapshot
        let snapshot = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: bytes)
        expectEqual(snapshot.originals, [.init(reference: ref, wasMissing: nil)])
        expectEqual(await purge().outcome, .committed); expectEqual(try XCTUnwrap(records().first).snapshot, bytes)
    }
    func testP3CoordinatedLinksRemoveAffectedCompleteFamiliesAndKeepUnrelatedLinks() async throws {
        try seed()
        let context = coordinator.freshContext(), links = LinkStore(container: coordinator.container)
        let target = NoteItem(id: UUID()); context.insert(target); try context.save()
        let affected = try XCTUnwrap(links.link(.init(.task, taskID), to: .init(.note, target.id), kind: .reference))
        let unrelated = ItemLink(source: .init(.note, target.id), target: .init(.note, UUID()), kind: .reference)
        context.insert(unrelated); try context.save()
        expectEqual(await purge().outcome, .committed)
        let survivors = try coordinator.freshContext().fetch(FetchDescriptor<ItemLink>())
        expectEqual(Set(survivors.map(\.id)), [unrelated.id]); XCTAssertFalse(survivors.contains { $0.id == affected.id })
    }
    func testP3DivergentAffectedLinkFamilyRetainsEveryTaskAndRecord() async throws {
        try seed()
        let context = coordinator.freshContext(), link = ItemLink(source: .init(.task, taskID), target: .init(.note, UUID()), kind: .reference)
        context.insert(link)
        let replica = ItemLink(id: link.id, source: .init(.task, taskID), target: .init(.note, UUID()), kind: .reference)
        context.insert(replica); try context.save()
        expectEqual(await purge().outcome, .conflict); expectEqual(try tasks(), 1); XCTAssertTrue(try records().isEmpty)
        expectEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<ItemLink>()), 2)
    }

    func testP4LegacyActiveMaterializationAndDeletedRestoreKeepFormatBodyAndPreservationTitle() async throws {
        try seed()
        let context = coordinator.freshContext(), activeID = UUID()
        let active = NoteItem(id: activeID, title: "Old active", body: "line 1\nline 2")
        active.taskID = taskID; context.insert(active)
        let deleted = NoteItem(id: noteID, title: "Old deleted", body: "deleted body")
        deleted.taskID = taskID; deleted.deletedAt = deletion; context.insert(deleted); try context.save()
        expectEqual(await purge().outcome, .committed)
        let rows = try coordinator.freshContext().fetch(FetchDescriptor<NoteItem>())
        let materialized = try XCTUnwrap(rows.first { $0.id == activeID })
        expectEqual(materialized.title, "Current task"); expectEqual(materialized.body, "line 1\nline 2")
        expectEqual(materialized.contentFormat, 0); XCTAssertNil(materialized.content); XCTAssertNil(materialized.taskID)
        expectEqual(try note().title, "Old deleted")
        let store = NoteStore(container: coordinator.container)
        XCTAssertTrue(store.restoreDeleted(noteID: noteID))
        expectEqual(try note().title, "Current task"); expectEqual(try note().body, "deleted body")
        expectEqual(try note().contentFormat, 0); XCTAssertNil(try note().content); XCTAssertNil(try note().taskID)
    }
    func testP4LegacyVersionRestoreDerivesPreservationTitleAndKeepsHistoricalBody() async throws {
        try seed(note: true); expectEqual(await purge().outcome, .committed)
        let context = coordinator.freshContext(), version = NoteVersion(noteID: noteID, createdAt: deletion, reason: .beforeRestore,
            content: nil, contentFormat: 0, title: "Historical title", body: "Historical body", attachmentIDs: [], sourceRevisionID: nil)
        context.insert(version); try context.save()
        let store = NoteStore(container: coordinator.container)
        if case let .failure(error) = store.restoreVersion(version.id, noteID: noteID) { XCTFail("\(error)") }
        expectEqual(try note().title, "Current task"); expectEqual(try note().body, "Historical body")
        expectEqual(try note().contentFormat, 0); XCTAssertNil(try note().content); XCTAssertNil(try note().taskID)
        expectEqual(try tasks(), 0)
    }
    func testP3PreservationReferencesKeepDeletedNoteAndVersionRowsIndependentOfTaskLifetime() async throws {
        let context = coordinator.freshContext(), task = TaskItem(id: taskID, title: "Task")
        task.listOrderVersion = TaskItem.currentListOrderVersion; context.insert(task)
        let row = NoteItem(id: noteID, title: "Legacy", body: "body"); row.taskID = taskID; context.insert(row)
        let version = NoteVersion(noteID: noteID, createdAt: deletion, reason: .beforeRestore,
            content: nil, contentFormat: 0, title: "Old", body: "old", attachmentIDs: [], sourceRevisionID: nil)
        context.insert(version); try context.save()
        let store = TaskStore(container: coordinator.container, now: { self.deletion }, taskImageFiles: files)
        XCTAssertTrue(store.delete(taskIDs: [taskID])); expectEqual(await purge().outcome, .committed)
        let notes = NoteStore(container: coordinator.container)
        XCTAssertTrue(notes.delete(try XCTUnwrap(notes.notes.first { $0.id == noteID })))
        expectEqual(notes.purgeDeleted(before: .distantFuture), [])
        notes.thinVersions(noteID: noteID)
        XCTAssertTrue(try coordinator.freshContext().fetch(FetchDescriptor<NoteVersion>()).contains { $0.id == version.id })
        expectEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<NoteItem>()), 1)
    }

    func testP4SharedWriterTombstoneBlocksTaskAndAssociationResurrectionAndOldTaskNoteContent() async throws {
        try seed(note: true)
        let before = try document()
        expectEqual(await purge().outcome, .committed)
        let record = try XCTUnwrap(records().first), taskOwner = WorkspaceOwner(entity: .task, id: taskID)
        expectEqual(coordinator.plainSave(tokens: try coordinator.capture([taskOwner]), writes: [taskOwner], stage: { context in
            context.insert(TaskItem(id: self.taskID, title: "Resurrected"))
        }), .notCommitted)
        let associationID = UUID(), owner = WorkspaceOwner(entity: .association, id: associationID)
        expectEqual(coordinator.plainSave(tokens: try coordinator.capture([owner]), writes: [owner], stage: { context in
            context.insert(TaskNoteAssociation(id: associationID, taskID: self.taskID, noteID: self.noteID))
        }), .notCommitted)
        let noteOwner = WorkspaceOwner(entity: .note, id: noteID), bytes = try NoteContentCodec.encode(before)
        expectEqual(coordinator.plainSave(tokens: try coordinator.capture([noteOwner]), writes: [noteOwner], stage: { context in
            let row = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first)
            row.content = bytes
        }), .notCommitted)
        expectEqual(try tasks(), 0); XCTAssertNil(try note().taskID)
        XCTAssertFalse(try document().requires.contains("taskNote")); expectEqual(try XCTUnwrap(records().first).snapshot, record.snapshot)
    }

    func testP3IntactLegacyFamilyCapturesImmutableMetadataInSameSaveAsPurge() async throws {
        try seed(); let result = await purge()
        expectEqual(result.outcome, .committed); expectEqual(result.removedIDs, [taskID!]); expectEqual(try tasks(), 0)
        let record = try XCTUnwrap(records().first)
        expectEqual(record.provenance, "legacy intact-row capture"); expectEqual(record.deletedAt, deletion)
        XCTAssertGreaterThan(record.capturedAt, deletion); XCTAssertNotNil(record.purgedAt)
        let snapshot = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot)
        expectEqual(snapshot.rootID, taskID); expectEqual(snapshot.title, "Current task"); expectEqual(snapshot.members.map(\.id), [taskID!])
    }
    func testP3MissingExclusiveOriginalDoesNotStrandLegacyFamilyOrInventADigest() async throws {
        let reference = TaskImageReference(id: UUID(), filename: "missing.txt", digest: NotePayloadDigest.sha256(Data("missing".utf8)), contentTypeIdentifier: "public.plain-text", byteCount: 7)
        try seed(reference: reference); expectEqual(await purge().outcome, .committed)
        let snapshot = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: XCTUnwrap(records().first).snapshot)
        expectEqual(snapshot.originals, [.init(reference: reference, wasMissing: true)])
    }
    func testP3SurvivingOriginalOwnerRetainsWholeTaskFamilyAndCaptureDoesNotPersist() async throws {
        let reference = TaskImageReference(id: UUID(), filename: "missing.txt", digest: NotePayloadDigest.sha256(Data()), contentTypeIdentifier: "public.plain-text", byteCount: 0)
        try seed(reference: reference); ownership = .init(generation: 1, bytes: [reference.id])
        expectEqual(await purge().outcome, .conflict); expectEqual(try tasks(), 1); XCTAssertTrue(try records().isEmpty)
    }
    func testP3MissingMemberAndDivergentPhysicalReplicaRefuseCompleteFamily() async throws {
        try seed()
        let context = coordinator.freshContext(), row = try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<TaskItem>()).first)
        let replica = TaskItem(id: taskID, title: "Replica"); try WorkspaceModelFields.apply(WorkspaceModelFields.read(row), to: replica)
        replica.title = "Divergent"; context.insert(replica); try context.save()
        expectEqual(await purge().outcome, .conflict); expectEqual(try tasks(), 2); XCTAssertTrue(try records().isEmpty)
        for task in try context.fetch(FetchDescriptor<TaskItem>()) { task.title = "Current task"; task.deletionMembersRaw += " \(UUID())" }
        try context.save(); expectEqual(await purge().outcome, .conflict); expectEqual(try tasks(), 2)
    }
    func testP2ProtectedSessionStatesDeferPurgeAndIdleRetryUsesNewestDraft() async throws {
        try seed(note: true)
        let protected: [WorkspacePurge.SessionSnapshot] = [
            .init(activity: .composing), .init(activity: .writingToolsSafe), .init(activity: .writingToolsRefused),
            .init(importing: true), .init(state: .conflict(.changed)), .init(proposal: true),
            .init(replay: true), .init(publication: true)
        ]
        for state in protected {
            ownership = .init(generation: 1, sessions: [noteID: state])
            expectEqual(await purge().outcome, .conflict); expectEqual(try tasks(), 1); XCTAssertNotNil(try note().taskID)
        }
        ownership = .init(generation: 2, drafts: [noteID: try NoteDocument(blocks: [.text("Draft compatibility"), .text("newest draft")]).taskSnapshot(title: "Draft compatibility")])
        expectEqual(await purge().outcome, .committed)
        expectEqual(try document().title, "Current task"); expectEqual(try document().blocks[1].text, "newest draft")
        XCTAssertFalse(try document().requires.contains("taskNote")); XCTAssertNil(try note().taskID)
    }
    func testP2FailedCaptureSaveLeavesEveryTaskNoteAssociationAndHistoryRowUnchanged() async throws {
        try seed(note: true)
        let owners: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID), .init(entity: .note, id: noteID)]
        let before = try coordinator.capture(owners)
        coordinator.save = { _ in throw WorkspaceFoundationError.preparationFailed }
        expectEqual(await purge().outcome, .notCommitted); expectEqual(try coordinator.capture(owners), before)
        expectEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<TaskNoteAssociation>()), 0)
        expectEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<NoteVersion>()), 0)
        XCTAssertTrue(try records().isEmpty)
    }
    func testP1UnknownInventoryRetainsRowsWhileAnUnrelatedSaveStillWorks() async throws {
        try seed(); ownership = nil
        expectEqual(await purge().outcome, .conflict); expectEqual(try tasks(), 1)
        let store = TaskStore(container: coordinator.container)
        XCTAssertNotNil(store.create(title: "Unrelated")); expectEqual(try tasks(), 2)
    }
    func testP1ChangedOwnershipGenerationDuringPreparationRefusesWholePurge() async throws {
        try seed(note: true)
        coordinator.afterPreparation = { self.ownership = .init(generation: 1) }
        expectEqual(await purge().outcome, .conflict); expectEqual(try tasks(), 1); XCTAssertNotNil(try note().taskID)
        XCTAssertTrue(try records().isEmpty)
    }
    func testP1SurvivingNoteOrAssociationRowOwnerRetainsWholeFamilyUntilTransfer() async throws {
        try seed(note: true)
        let context = coordinator.freshContext(), associationID = UUID()
        context.insert(TaskNoteAssociation(id: associationID, taskID: taskID, noteID: noteID)); try context.save()
        for owner in [WorkspaceOwner(entity: .note, id: noteID), .init(entity: .association, id: associationID)] {
            ownership = .init(generation: 1, rows: [owner])
            expectEqual(await purge().outcome, .conflict); expectEqual(try tasks(), 1)
            XCTAssertNotNil(try note().taskID); XCTAssertTrue(try records().isEmpty)
        }
        ownership = .init(generation: 2)
        expectEqual(await purge().outcome, .committed); expectEqual(try tasks(), 0)
    }
    func testP2ClosedOwnNoteProposalRetainsFamilyEvenWithoutAnOpenSession() async throws {
        try seed(note: true)
        let context = coordinator.freshContext(), proposal = NotePendingEdit(noteID: noteID,
            baseRevisionToken: "base", proposedContent: try XCTUnwrap(note().content), agentName: "External", createdAt: Date())
        context.insert(proposal); try context.save()
        expectEqual(await purge().outcome, .conflict); expectEqual(try tasks(), 1)
        XCTAssertNotNil(try note().taskID); XCTAssertTrue(try records().isEmpty)
        context.delete(proposal); try context.save()
        expectEqual(await purge().outcome, .committed); expectEqual(try tasks(), 0)
    }
    func testP4DeletedOwnNoteDetachesWithoutChangingBytesAndNormalizesOnlyOnRestore() async throws {
        try seed(note: true, deletedNote: true); let old = try note().content
        expectEqual(await purge().outcome, .committed); expectEqual(try note().content, old); XCTAssertNil(try note().taskID)
        let store = NoteStore(container: coordinator.container)
        XCTAssertTrue(store.restoreDeleted(noteID: noteID)); expectEqual(try tasks(), 0)
        expectEqual(try document().title, "Current task"); XCTAssertFalse(try document().requires.contains("taskNote")); XCTAssertNil(try note().taskID)
    }
    func testP4VersionRestoreAfterPurgeUsesPreservationAndCannotRestoreLiveAssociation() async throws {
        try seed(note: true); expectEqual(await purge().outcome, .committed)
        let version = try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<NoteVersion>()).first)
        XCTAssertTrue(try XCTUnwrap(version.content.flatMap { NoteContentCodec.decode($0).document }).requires.contains("taskNote"))
        let store = NoteStore(container: coordinator.container)
        if case let .failure(error) = store.restoreVersion(version.id, noteID: noteID) { XCTFail("\(error)") }
        expectEqual(try tasks(), 0); XCTAssertNil(try note().taskID); expectEqual(try document().title, "Current task")
        XCTAssertFalse(try document().requires.contains("taskNote"))
    }
    func testP4MaterializationUndoRedoRestoresOrdinaryContentWithoutResurrectingTaskSemantics() async throws {
        try seed(note: true)
        let result = await purge(); expectEqual(result.outcome, .committed)
        let route = UndoRoute(), workspace = route.workspace(for: .taskWorkspace(taskID))
        let patch = try XCTUnwrap(result.materialization.first)
        try patch.record(operationID: XCTUnwrap(result.operationID), in: workspace, coordinator: coordinator)
        expectEqual(await workspace.replay(redo: false), .applied)
        expectEqual(try document().title, "Old compatibility"); expectEqual(try document().blocks[1].text, "body")
        XCTAssertFalse(try document().requires.contains("taskNote")); XCTAssertNil(try note().taskID); expectEqual(try tasks(), 0)
        expectEqual(await workspace.replay(redo: true), .applied)
        expectEqual(try document().title, "Current task"); XCTAssertNil(try note().taskID); expectEqual(try tasks(), 0)
        XCTAssertFalse(try document().requires.contains("taskNote"))
    }
    func testP3OpaqueOwnNoteDetachesEveryReplicaWithoutRewritingItsBytes() async throws {
        try seed(note: true)
        let context = coordinator.freshContext(), id = noteID!
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first)
        let bytes = Data("{\"format\":99,\"requires\":[\"taskNote\",\"future\"],\"blocks\":[]}".utf8)
        row.content = bytes; row.contentFormat = 99
        let replica = NoteItem(id: id); try WorkspaceModelFields.apply(WorkspaceModelFields.read(row), to: replica)
        context.insert(replica); try context.save()
        expectEqual(await purge().outcome, .committed)
        let rows = try coordinator.freshContext().fetch(FetchDescriptor<NoteItem>())
        expectEqual(rows.count, 2); XCTAssertTrue(rows.allSatisfy { $0.taskID == nil && $0.content == bytes })
        expectEqual(try tasks(), 0)
    }
    func testP5NewProviderDuringAwaitedReadInvalidatesUnlinkAttempt() async throws {
        let input = root.appendingPathComponent("original.txt"), bytes = Data("retain original".utf8)
        try bytes.write(to: input)
        let imported = try await files.importAttachments([input], existing: [])
        let reference = try XCTUnwrap(imported.first)
        let store = await files.files, gate = ProviderGate()
        store.registerByteOwners(UUID()) { await gate.pauseOnce(); return [] }
        let collection = Task { await self.files.remove([reference]) }
        await gate.waitUntilPaused()
        store.registerByteOwners(UUID()) { [reference.id] }
        await gate.release(); await collection.value
        let url = try await files.verifiedURL(for: reference); XCTAssertNotNil(url)
        if let url { expectEqual(try Data(contentsOf: url), bytes) }
        await files.remove([reference])
        let retained = try await files.verifiedURL(for: reference); XCTAssertNotNil(retained)
    }
    func testP3LegacyCollectorDefersOwnNoteRatherThanLeavingActionablePurgedTaskID() throws {
        try seed(note: true); let store = TaskStore(container: coordinator.container)
        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty); expectEqual(try tasks(), 1); XCTAssertNotNil(try note().taskID)
    }
    func testP5LegacyImportWaitsForUnlinkThenRefusesMissingOriginal() async throws {
        let input = root.appendingPathComponent("legacy.txt"); try Data("original".utf8).write(to: input)
        let imported = try await files.importAttachments([input], existing: [])
        let reference = try XCTUnwrap(imported.first)
        let store = files.files, pause = ProviderGate()
        store.registerByteOwners(UUID()) { await pause.pauseOnce(); return [] }
        let collection = Task { await self.files.remove([reference]) }
        await pause.waitUntilPaused()
        XCTAssertNil(store.ownership.tryAcquire([reference.id], kind: .admission))
        let reuse = Task { try await self.files.importCopies(of: [reference], existing: []) }
        await pause.release(); await collection.value
        do { _ = try await reuse.value; XCTFail("a collected original cannot become a new root") }
        catch {
            guard let failure = error as? TaskDropError, case .attachmentUnavailable = failure else { return XCTFail("unexpected error: \(error)") }
        }
        let url = try await files.verifiedURL(for: reference); XCTAssertNil(url)
        let storeWithMissingOriginal = TaskStore(container: coordinator.container, taskImageFiles: files)
        XCTAssertNil(storeWithMissingOriginal.create(title: "Stale reference", attachments: [reference]))
    }
    func testP5PayloadAdmissionWaitsThenRebuildsAndOwnsCandidateAcrossActors() async throws {
        let input = root.appendingPathComponent("payload.txt"), bytes = Data("durable payload".utf8)
        try bytes.write(to: input)
        let imported = try await files.importAttachments([input], existing: [])
        let reference = try XCTUnwrap(imported.first)
        let first = files.files, second = AttachmentFileStore(rootURL: first.rootURL), pause = ProviderGate()
        XCTAssertTrue(first.ownership === second.ownership)
        first.registerByteOwners(UUID()) { await pause.pauseOnce(); return [] }
        let collection = Task { await self.files.remove([reference]) }
        await pause.waitUntilPaused()
        let candidate = AttachmentFileReference(id: reference.id, digest: reference.digest, filename: reference.filename,
            byteCount: reference.byteCount, payload: bytes)
        let reuse = Task { try await second.admit(candidate) }
        await pause.release(); await collection.value
        let admitted = try await reuse.value
        let (url, lease) = try XCTUnwrap(admitted)
        expectEqual(try Data(contentsOf: url), bytes)
        await files.remove([reference])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "candidate admission owns bytes until root publication")
        first.registerByteOwners(UUID()) { [reference.id] }
        lease.release(); await files.remove([reference])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testP5FamilyLeaseBlocksPlainWriterQueuesJournaledWriterAndAllowsDisjointSave() async throws {
        try seed()
        files.files.registerWriter(coordinator.ownership)
        let collection = try XCTUnwrap(files.files.acquireCollection([taskID!]))
        let owner = WorkspaceOwner(entity: .task, id: taskID)
        let tokens = try coordinator.capture([owner])
        let result = coordinator.plainSave(tokens: tokens, writes: [owner]) { context in
            try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first).title = "Refused"
        }
        expectEqual(result, .conflict)
        let envelope = try coordinator.newEnvelope(intent: "Queued rename", reads: tokens, writes: [owner])
        let mutation = Task { await self.coordinator.execute(envelope, stage: { context in
            try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first).title = "After lease"
        }) }
        await Task.yield()
        expectEqual(try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<TaskItem>()).first).title, "Current task")
        let store = TaskStore(container: coordinator.container, taskImageFiles: files)
        XCTAssertNotNil(store.create(title: "Disjoint"))
        collection.release()
        expectEqual(await mutation.value, .committed)
        let id = taskID!
        expectEqual(try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first).title, "After lease")
    }
    func testP5CancelledAdmissionReleasesNoOtherOwnersAndReleasedLeaseCannotAuthorizeUnlink() async throws {
        let gate = coordinator.ownership, id = UUID()
        let collection = try XCTUnwrap(gate.tryAcquire([id], kind: .collection))
        let waiting = Task { try await gate.admit([id]) }; waiting.cancel()
        do { _ = try await waiting.value; XCTFail("cancelled admission") } catch is CancellationError { }
        XCTAssertTrue(gate.validatesCollection(collection, ids: [id]))
        collection.release(); XCTAssertFalse(gate.validatesCollection(collection, ids: [id]))
        let admission = try await gate.admit([id]); XCTAssertNil(gate.tryAcquire([id], kind: .collection))
        admission.release(); XCTAssertNotNil(gate.tryAcquire([id], kind: .collection))
    }
    func testP5ExistingPayloadlessAttachmentSoftRemovalCrossesByteLeaseButNotFamilyLease() throws {
        let context = coordinator.freshContext(), attachmentID = UUID()
        context.insert(NoteItem(id: noteID, body: "Legacy body"))
        context.insert(NoteAttachment(id: attachmentID, noteID: noteID, originalFilename: "only.txt", byteCount: 4,
            sortIndex: 0, contentDigest: NotePayloadDigest.sha256(Data("only".utf8)), payload: nil))
        try context.save()
        let store = NoteStore(container: coordinator.container, attachmentFileStore: files.files)
        let byteLease = try XCTUnwrap(coordinator.ownership.tryAcquire([attachmentID], kind: .collection))
        let row = try XCTUnwrap(store.attachments(for: noteID).first)
        XCTAssertTrue(store.removeAttachment(row), store.lastErrorMessage ?? "soft removal refused")
        byteLease.release()
        let familyLease = try XCTUnwrap(coordinator.ownership.tryAcquire([noteID], kind: .collection))
        XCTAssertFalse(store.restoreAttachment(attachmentID), "the row phase freezes every affected family owner")
        familyLease.release()
        XCTAssertTrue(store.restoreAttachment(attachmentID), store.lastErrorMessage ?? "restore refused")
        let rows = try coordinator.freshContext().fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(rows.count, 1); XCTAssertNil(rows.first?.payload); XCTAssertNil(rows.first?.deletedAt)
        XCTAssertEqual(rows.first?.contentDigest, NotePayloadDigest.sha256(Data("only".utf8)))
    }
    func testP5LegacyVersionReferencesAndMalformedReferenceMetadataAreAdmittedConservatively() throws {
        let fileID = UUID()
        let version = NoteVersion(noteID: noteID, createdAt: Date(), reason: .leave, content: nil, contentFormat: 0,
            title: "Legacy", body: "body", attachmentIDs: [fileID], sourceRevisionID: nil)
        let known = try coordinator.admissionIDs([version])
        XCTAssertTrue(known.contains(fileID)); XCTAssertFalse(known.contains(coordinator.ownership.unknownID))
        let bytes = try XCTUnwrap(coordinator.ownership.tryAcquire([fileID], kind: .collection))
        XCTAssertNil(coordinator.ownership.tryAcquire(known, kind: .admission)); bytes.release()
        version.attachmentIDsRaw += " unreadable-owner"
        let unknown = try coordinator.admissionIDs([version])
        XCTAssertTrue(unknown.contains(fileID)); XCTAssertTrue(unknown.contains(coordinator.ownership.unknownID))
        let unrelated = try XCTUnwrap(coordinator.ownership.tryAcquire([UUID()], kind: .collection))
        XCTAssertNil(coordinator.ownership.tryAcquire(unknown, kind: .admission)); unrelated.release()
    }

    func testP5UnknownContentAdmissionOverlapsEveryCollectionAndCannotBecomeEmptyOwnership() throws {
        let context = coordinator.freshContext(), row = NoteItem(id: noteID, title: "Opaque")
        row.content = Data("unsupported bytes".utf8); row.contentFormat = 9
        context.insert(row); try context.save()
        let owner = WorkspaceOwner(entity: .note, id: noteID), tokens = try coordinator.capture([owner])
        let unrelatedFile = UUID()
        let collection = try XCTUnwrap(coordinator.ownership.tryAcquire([unrelatedFile], kind: .collection))
        let mutation: (ModelContext) throws -> Void = { context in
            let id = self.noteID!
            try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first).title = "Compatible rename"
        }
        expectEqual(coordinator.plainSave(tokens: tokens, writes: [owner], stage: mutation), .conflict)
        expectEqual(try coordinator.capture([owner]), tokens)
        collection.release()
        expectEqual(coordinator.plainSave(tokens: tokens, writes: [owner], stage: mutation), .committed)
        expectEqual(try note().content, Data("unsupported bytes".utf8))
        expectEqual(try note().contentFormat, 9)
    }

    func testP5NewWriterDomainDuringPreparationInvalidatesFamilyLeaseBeforeRowSave() async throws {
        try seed(note: true)
        coordinator.afterPreparation = { self.files.files.registerWriter(WorkspaceOwnershipGate()) }
        expectEqual(await purge().outcome, .conflict)
        expectEqual(try tasks(), 1); XCTAssertNotNil(try note().taskID); XCTAssertTrue(try records().isEmpty)
    }
    func testP5PendingTaskImportOwnsItsOnlyOriginalUntilBindingOrExplicitDiscard() async throws {
        let input = root.appendingPathComponent("pending.txt"); try Data("pending original".utf8).write(to: input)
        let refs = try await files.importAttachments([input], existing: [])
        let reference = try XCTUnwrap(refs.first)
        let removed = await files.removeUnreferenced(keeping: [], modifiedBefore: .distantFuture, limit: 10)
        expectEqual(removed, 0)
        let store = TaskStore(container: coordinator.container, taskImageFiles: files)
        XCTAssertNotNil(store.create(title: "Bound", attachments: refs))
        await files.remove(refs)
        let retained = try await files.verifiedURL(for: reference); XCTAssertNotNil(retained)
        let other = try await files.importAttachments([input], existing: [])
        await files.remove(other)
        let discarded = try await files.verifiedURL(for: XCTUnwrap(other.first)); XCTAssertNil(discarded)
    }
}

private actor ProviderGate {
    private var paused = false, released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var resume: CheckedContinuation<Void, Never>?
    func pauseOnce() async {
        if released { return }
        paused = true; waiting.forEach { $0.resume() }; waiting.removeAll()
        await withCheckedContinuation { resume = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { released = true; resume?.resume(); resume = nil }
}
