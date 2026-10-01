import Foundation
import SwiftData

#if ATTIC_OPERATION_CRASH_TESTS
/// Disk fixtures shared by the embedded child and hosted assertions. No default
/// store or app runtime is used, and every identifier belongs to this fixture.
@MainActor
enum WorkspaceCrashFixture {
    static let taskID = UUID(uuidString: "D92AC3EB-5A34-48CE-9882-7F0712F47431")!
    static let noteID = UUID(uuidString: "D92AC3EB-5A34-48CE-9882-7F0712F47432")!
    static let childID = UUID(uuidString: "D92AC3EB-5A34-48CE-9882-7F0712F47433")!
    static let versionID = UUID(uuidString: "D92AC3EB-5A34-48CE-9882-7F0712F47434")!
    static let fileID = UUID(uuidString: "D92AC3EB-5A34-48CE-9882-7F0712F47435")!
    static let associationID = UUID(uuidString: "D92AC3EB-5A34-48CE-9882-7F0712F47436")!
    static let filePlacementID = UUID(uuidString: "D92AC3EB-5A34-48CE-9882-7F0712F47437")!
    static let bytes = Data("crash fixture original attachment".utf8)
    static var staged: StagedNoteAttachment {
        .init(id: fileID, filename: "fixture.txt", contentTypeIdentifier: "public.plain-text",
              byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
    }
    static var original: NoteDocument {
        var doc = NoteDocument(blocks: [.text("Parent"), .text("Make child"),
            .file(id: filePlacementID, attachmentID: fileID, filename: "fixture.txt", contentTypeIdentifier: "public.plain-text", byteCount: Int64(bytes.count))])
        doc.requires.append("taskNote"); doc.refreshRequiredCapabilities(); return doc
    }
    static var candidate: NoteDocument {
        var doc = original; doc.blocks.remove(at: 1); return doc
    }
    static func purgeFiles(_ root: URL) throws -> [TaskImageReference] {
        try JSONDecoder().decode([TaskImageReference].self, from: Data(contentsOf: root.appendingPathComponent("purge-files.json")))
    }
    static func seedPurge(_ root: URL) async throws {
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
        var inputs: [URL] = []
        for index in 0..<2 {
            let input = root.appendingPathComponent("original-\(index).txt")
            try bytes.write(to: input); inputs.append(input)
        }
        let references = try await files.importAttachments(inputs, existing: [])
        try JSONEncoder().encode(references).write(to: root.appendingPathComponent("purge-files.json"))
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let context = ModelContext(container); context.autosaveEnabled = false
        let deletion = Date(timeIntervalSince1970: 100), members = [taskID.uuidString, childID.uuidString].sorted().joined(separator: " ")
        for (index, id) in [taskID, childID].enumerated() {
            let row = TaskItem(id: id, title: index == 0 ? "Parent" : "Child", parentID: index == 0 ? nil : taskID)
            row.deletedAt = deletion; row.deletionRootID = taskID; row.deletionMembersRaw = members
            row.imageReferencesData = try JSONEncoder().encode([references[index]])
            context.insert(row)
        }
        let note = NoteItem(id: noteID); note.taskID = taskID
        let document = try NoteDocument(blocks: [.text("Old title"), .text("Retain body")]).taskSnapshot(title: "Old title")
        NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [note], timestamp: deletion, revision: 0, revisionID: UUID())
        context.insert(note); try context.save()
    }
    static func purge(_ root: URL) async throws -> WorkspaceOperationCoordinator.Outcome {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let coordinator = try WorkspaceOperationCoordinator(container: container, journal: journal(root))
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
        let result = await WorkspacePurge.purge(rootID: taskID, before: .distantFuture,
            coordinator: coordinator, files: files, inventory: { .init(generation: 0) })
        guard result.outcome == .committed else { return result.outcome }
        WorkspaceCrashHook.reach("K8-before-unlink")
        await files.remove(try purgeFiles(root))
        return result.outcome
    }
    static func journal(_ root: URL) -> NoteDraftJournal {
        NoteDraftJournal(directory: root.appendingPathComponent("NoteDrafts"))
    }
    static func seed(_ root: URL) async throws {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let context = ModelContext(container); context.autosaveEnabled = false
        context.insert(TaskItem(id: taskID, title: "Parent"))
        let note = NoteItem(id: noteID); note.taskID = taskID
        // The imported file is deliberately only in the checkpoint until the
        // conversion save. A pre-save death must never lose its original.
        let stored = try NoteDocument(blocks: [.text("Parent"), .text("Make child")]).taskSnapshot(title: "Parent")
        NoteStore.stageDocumentContent(try PreparedNoteDocument(stored), format: 1, on: [note], timestamp: Date(), revision: 0, revisionID: UUID())
        context.insert(note); try context.save()
        let draft = NoteDraftJournalEntry(noteID: noteID, isPersisted: true, baseRevisionID: note.revisionID,
            content: try PreparedNoteDocument(original).content, selectionLocation: 7, selectionLength: 10,
            staged: [.init(id: fileID, filename: staged.filename, contentTypeIdentifier: staged.contentTypeIdentifier,
                byteCount: staged.byteCount, digest: staged.digest)], savedAt: Date())
        _ = try await journal(root).writeDurably(draft, staged: [staged])
    }
    static func convert(_ root: URL) async throws -> WorkspaceOperationCoordinator.Outcome {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let journal = journal(root)
        let coordinator = try WorkspaceOperationCoordinator(container: container, journal: journal)
        let entries = try await journal.inventoryCheckpoints()
        guard case let .valid(pre, _, claim) = entries.first else { throw WorkspaceFoundationError.unknown }
        let context = coordinator.freshContext()
        let note = try context.fetch(FetchDescriptor<NoteItem>()).first!
        let physical = note.persistentModelID
        let owners: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID), .init(entity: .note, id: noteID),
            .init(entity: .task, id: childID), .init(entity: .version, id: versionID),
            .init(entity: .attachment, id: fileID), .init(entity: .association, id: associationID)]
        let prepared = try PreparedNoteDocument(candidate)
        let envelope = try coordinator.newEnvelope(intent: "Make Subtask", reads: coordinator.capture(owners), writes: owners,
            preDraft: pre, afterDocuments: [noteID: prepared.content], checkpointClaim: claim, staged: [staged])
        return await coordinator.execute(envelope, stage: { commit in
            _ = try TaskStore.stageCreation(in: commit, drafts: [TaskDraft(title: "Make child", parentID: taskID)], ids: [childID], timestamp: Date())
            WorkspaceCrashHook.reach("K3-task")
            try NoteStore.stageDocument(in: commit, noteID: noteID, document: candidate, prepared: prepared,
                revisionID: UUID(), versionIDs: [physical: versionID], staged: [staged], timestamp: Date())
            let task = try commit.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first!
            let note = try commit.fetch(FetchDescriptor<NoteItem>()).first!
            task.associationGeneration += 1; note.associationGeneration += 1
            let association = TaskNoteAssociation(id: associationID, taskID: taskID, noteID: noteID)
            association.taskGeneration = task.associationGeneration; association.noteGeneration = note.associationGeneration
            commit.insert(association)
            WorkspaceCrashHook.reach("K3-association")
        }, publication: .init(steps: (0..<5).map { _ in { _ in } }))
    }
}
#endif
