import Foundation
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class WorkspaceCommitTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!
    private var coordinator: WorkspaceOperationCoordinator!
    private var taskID: UUID!
    private var noteID: UUID!
    private var original: NoteDocument!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticWorkspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        coordinator = try WorkspaceOperationCoordinator(container: container,
            journal: NoteDraftJournal(directory: root.appendingPathComponent("NoteDrafts")))
        taskID = UUID(); noteID = UUID()
        original = NoteDocument(blocks: [.text("Parent"), .text("Make this a child"), .text("Keep this")])
        let context = coordinator.freshContext()
        context.insert(TaskItem(id: taskID, title: "Parent"))
        let note = NoteItem(id: noteID)
        NoteStore.stageDocumentContent(try PreparedNoteDocument(original), format: 1, on: [note],
            timestamp: Date(timeIntervalSince1970: 123), revision: 0, revisionID: UUID())
        note.taskID = taskID
        context.insert(note)
        try context.save()
    }
    override func tearDown() async throws {
        coordinator = nil; container = nil
        try FileManager.default.removeItem(at: root)
    }
    private var baseOwners: Set<WorkspaceOwner> {
        [WorkspaceOwner(entity: .task, id: taskID), WorkspaceOwner(entity: .note, id: noteID)]
    }
    private func conversion(failAfter: Int? = nil,
                            publication: WorkspaceOperationCoordinator.Publication = .init()) async throws -> (WorkspaceOperationCoordinator.Outcome, UUID) {
        let context = coordinator.freshContext()
        let id = noteID!
        let note = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first)
        let versionID = UUID(), childID = UUID(), associationID = UUID(), attachmentID = UUID()
        let payload = Data("original imported bytes".utf8)
        let staged = StagedNoteAttachment(id: attachmentID, filename: "fixture.txt",
            contentTypeIdentifier: "public.plain-text", byteCount: Int64(payload.count),
            digest: NotePayloadDigest.sha256(payload), data: payload)
        var candidate = original!
        candidate.blocks.remove(at: 1)
        candidate.blocks.append(.file(attachmentID: attachmentID, filename: "fixture.txt",
            contentTypeIdentifier: "public.plain-text", byteCount: Int64(payload.count)))
        candidate.refreshRequiredCapabilities()
        let projection = try PreparedNoteDocument(candidate)
        let owners = baseOwners.union([
            WorkspaceOwner(entity: .task, id: childID), .init(entity: .version, id: versionID),
            .init(entity: .association, id: associationID), .init(entity: .attachment, id: attachmentID)
        ])
        let envelope = coordinator.newEnvelope(intent: "Make Subtask", reads: try coordinator.capture(owners),
            writes: owners, afterDocuments: [id: projection.content], staged: [staged])
        let versionIDs = [note.persistentModelID: versionID]
        let result = await coordinator.execute(envelope, stage: { commit in
            _ = try TaskStore.stageCreation(in: commit,
                drafts: [TaskDraft(title: "Make this a child", parentID: self.taskID)],
                ids: [childID], timestamp: Date(timeIntervalSince1970: 124))
            if failAfter == 1 { throw WorkspaceFoundationError.preparationFailed }
            try NoteStore.stageDocument(in: commit, noteID: id, document: candidate, prepared: projection,
                revisionID: UUID(), versionIDs: versionIDs, staged: [staged], timestamp: Date(timeIntervalSince1970: 124))
            if failAfter == 2 { throw WorkspaceFoundationError.preparationFailed }
            let association = TaskNoteAssociation(id: associationID, taskID: self.taskID, noteID: id)
            commit.insert(association)
            let rootID = self.taskID!
            for row in try commit.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == rootID })) {
                row.associationGeneration += 1; association.taskGeneration = row.associationGeneration
            }
            for row in try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })) {
                row.associationGeneration += 1; association.noteGeneration = row.associationGeneration
            }
            if failAfter == 3 { throw WorkspaceFoundationError.preparationFailed }
        }, publication: publication)
        return (result, envelope.id)
    }

    func testC1ConversionRefusalsAndSaveFailureLeaveEveryPhysicalFamilyUnchanged() async throws {
        let before = try coordinator.capture(baseOwners)
        for point in [1, 2, 3, 4] {
            if point == 4 { coordinator.save = { _ in throw WorkspaceFoundationError.preparationFailed } }
            let (outcome, _) = try await conversion(failAfter: point)
            XCTAssertEqual(outcome, .notCommitted)
            XCTAssertEqual(try coordinator.capture(baseOwners), before)
            let context = coordinator.freshContext()
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteVersion>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskNoteAssociation>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteAttachment>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceipt>()), 0)
        }
    }
    func testC1RealConversionCommitsTextChildVersionAttachmentAssociationAndReceiptTogether() async throws {
        let (outcome, id) = try await conversion()
        XCTAssertEqual(outcome, .committed)
        let context = coordinator.freshContext()
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.first { $0.parentID == taskID }?.title, "Make this a child")
        let note = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first)
        let document = try XCTUnwrap(note.content.flatMap { NoteContentCodec.decode($0).document })
        XCTAssertFalse(document.blocks.contains { $0.text == "Make this a child" })
        XCTAssertEqual(document.blocks[1].text, "Keep this")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteVersion>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskNoteAssociation>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteAttachment>()).first?.payload, Data("original imported bytes".utf8))
        let receipts = try context.fetch(FetchDescriptor<OperationReceipt>())
        XCTAssertEqual(receipts.map(\.id), [id]); XCTAssertTrue(receipts[0].publicationComplete)
    }
    func testC2WarmPresentationCannotOverwriteAFreshGatedRename() async throws {
        let tokens = try coordinator.capture(baseOwners)
        let warm = try coordinator.freshContext().fetch(FetchDescriptor<TaskItem>()).first!
        let rename = coordinator.plainSave(tokens: tokens, writes: [.init(entity: .task, id: taskID)], stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: "Fresh", timestamp: Date())
        })
        XCTAssertEqual(rename, .committed)
        let stale = coordinator.newEnvelope(intent: "stale rename", reads: tokens,
            writes: [.init(entity: .task, id: taskID)])
        let outcome = await coordinator.execute(stale, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: warm.title + " stale", timestamp: Date())
        })
        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(try coordinator.freshContext().fetch(FetchDescriptor<TaskItem>()).first?.title, "Fresh")
    }
    func testC3PublicationFailureKeepsOneCommittedResultAndRetriesOnlyRemainingPublication() async throws {
        var effects = [0, 0, 0, 0, 0]
        var refuse = true
        let publication = WorkspaceOperationCoordinator.Publication(steps: (0..<5).map { index in
            { _ in
                if index == 2 && refuse { throw WorkspaceFoundationError.preparationFailed }
                effects[index] += 1
            }
        })
        let (outcome, id) = try await conversion(publication: publication)
        XCTAssertEqual(outcome, .publicationPending)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<TaskItem>()), 2)
        XCTAssertEqual(effects, [1, 1, 0, 0, 0])
        refuse = false
        let retried = await coordinator.retryPublication(id)
        XCTAssertEqual(retried, .committed); XCTAssertEqual(effects, [1, 1, 1, 1, 1])
        let refused = await coordinator.retryPublication(id)
        XCTAssertEqual(refused, .conflict)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<TaskItem>()), 2)
    }
    func testC5PlainSaveReconcilesBeforeAfterAndUnreadableOutcomesWithoutReceipts() throws {
        let owners: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID)]
        coordinator.save = { _ in throw WorkspaceFoundationError.preparationFailed }
        var tokens = try coordinator.capture(owners)
        XCTAssertEqual(coordinator.plainSave(tokens: tokens, writes: owners, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: "Before", timestamp: Date())
        }), .notCommitted)
        coordinator.save = { context in try context.save(); throw WorkspaceFoundationError.unknown }
        XCTAssertEqual(coordinator.plainSave(tokens: tokens, writes: owners, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: "After", timestamp: Date())
        }), .committed)
        tokens = try coordinator.capture(owners)
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        XCTAssertEqual(coordinator.plainSave(tokens: tokens, writes: owners, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: "Unknown", timestamp: Date())
        }), .unknown)
        coordinator.beforeReconciliationRead = nil
        XCTAssertEqual(coordinator.reconcilePlain(), .committed)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("NoteDrafts/operations").path))
    }
}
