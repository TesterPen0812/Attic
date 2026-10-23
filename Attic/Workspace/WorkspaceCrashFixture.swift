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
    /// § 13 migration: a family with a shown image, a shown PDF, a child's
    /// file and a removed file, its originals in the fixture's `TaskFiles`.
    static func migrationFiles(_ root: URL) throws -> [TaskImageReference] {
        try JSONDecoder().decode([TaskImageReference].self, from: Data(contentsOf: root.appendingPathComponent("migration-files.json")))
    }
    static func seedMigration(_ root: URL) async throws {
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
        var inputs: [URL] = []
        for name in ["shot.png", "Spec.pdf", "child.txt", "removed.txt"] {
            let input = root.appendingPathComponent(name)
            if name.hasSuffix(".png") { try AtticDemoData.demoImage().write(to: input) } else { try Data((name + " bytes").utf8).write(to: input) }
            inputs.append(input)
        }
        let references = try await files.importAttachments(inputs, existing: [])
        try JSONEncoder().encode(references).write(to: root.appendingPathComponent("migration-files.json"))
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let context = ModelContext(container); context.autosaveEnabled = false
        let parent = TaskItem(id: taskID, title: "Parent")
        parent.imageReferencesData = try JSONEncoder().encode([references[0], references[1]])
        parent.removedAttachmentsData = try JSONEncoder().encode([RemovedTaskAttachment(reference: references[3], removedAt: Date(timeIntervalSince1970: 1_700_000_000))])
        let child = TaskItem(id: childID, title: "Child", parentID: taskID)
        child.imageReferencesData = try JSONEncoder().encode([references[2]])
        context.insert(parent); context.insert(child)
        try context.save()
    }
    static func migrate(_ root: URL) async throws -> TaskAttachmentMigration.Outcome {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let coordinator = try WorkspaceOperationCoordinator(container: container, journal: journal(root))
        try await coordinator.reconcileStartup()
        return await TaskAttachmentMigration.migrate(rootID: taskID, coordinator: coordinator,
            files: TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles")))
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
    static let alternateID = UUID(uuidString: "D92AC3EB-5A34-48CE-9882-7F0712F47438")!
    static let removedFileID = UUID(uuidString: "D92AC3EB-5A34-48CE-9882-7F0712F47439")!
    static func seedItem(_ root: URL) async throws {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let context = ModelContext(container), date = Date(timeIntervalSince1970: 1_700_000_000)
        let document = try PreparedNoteDocument(original)
        for _ in 0..<2 {
            let parent = TaskItem(id: taskID, title: "Parent", createdAt: date, manualOrder: 42)
            parent.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(parent)
            let child = TaskItem(id: childID, title: "Child", createdAt: date, parentID: taskID)
            child.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(child)
            for id in [noteID, alternateID] {
                let row = NoteItem(id: id, createdAt: date); row.taskID = taskID
                NoteStore.stageDocumentContent(document, format: 1, on: [row], timestamp: date, revision: 0, revisionID: versionID)
                context.insert(row)
            }
            for id in [fileID, removedFileID] {
                let file = NoteAttachment(id: id, noteID: noteID, originalFilename: "fixture.txt", byteCount: Int64(bytes.count),
                    sortIndex: id == fileID ? 0 : 1, contentDigest: staged.digest, createdAt: date, payload: bytes)
                if id == removedFileID { file.deletedAt = date.addingTimeInterval(-10) }
                context.insert(file)
            }
        }
        try context.save()
    }
    static func seedCircle(_ root: URL, adding: Bool) async throws {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let context = ModelContext(container), date = Date(timeIntervalSince1970: 1_700_000_000)
        let document = try PreparedNoteDocument(adding ? original.ordinarySnapshot(title: "Parent") : original)
        for index in 0..<2 {
            if !adding {
                let parent = TaskItem(id: taskID, title: "Parent", priority: .high, createdAt: date, manualOrder: 42)
                parent.dueDayRaw = "2026-10-23"; parent.tags = ["kept"]
                parent.listOrderVersion = TaskItem.currentListOrderVersion; context.insert(parent)
                let child = TaskItem(id: childID, title: "Child", createdAt: date, parentID: taskID)
                child.listOrderVersion = TaskItem.currentListOrderVersion; context.insert(child)
            }
            let note = NoteItem(id: noteID, createdAt: date)
            note.taskID = adding ? nil : taskID
            note.pinnedAt = index == 0 ? date : nil
            NoteStore.stageDocumentContent(document, format: 1, on: [note], timestamp: date, revision: 0, revisionID: versionID)
            context.insert(note)
            for id in [fileID, removedFileID] {
                let file = NoteAttachment(id: id, noteID: noteID, originalFilename: "fixture.txt", byteCount: Int64(bytes.count),
                    sortIndex: id == fileID ? 0 : 1, contentDigest: staged.digest, createdAt: date, payload: bytes)
                if id == removedFileID { file.deletedAt = date.addingTimeInterval(-10) }
                context.insert(file)
            }
        }
        if !adding { context.insert(TaskNoteAssociation(id: associationID, taskID: taskID, noteID: noteID)) }
        try context.save()
    }

    /// Exercise the same history/reservation producer as the app, with an
    /// engine-only session and fixture-owned journal/store/files.
    static func changeCircle(_ root: URL, adding: Bool) async throws -> Bool {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let coordinator = try WorkspaceOperationCoordinator(container: container, journal: journal(root))
        let tasks = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles")))
        let library = AtticLibrary(tasks: tasks)
        let notes = NotesPageController(store: NoteStore(container: container,
            attachmentFileStore: NoteAttachmentFileStore(rootURL: root.appendingPathComponent("NoteFiles"))),
            journal: coordinator.journal, defaults: nil, saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        notes.attachUndoRoute(library.undo)
        // Add is invoked from the ordinary note's active controller session;
        // activating this engine-only session presents no native surface.
        if adding, !notes.open(noteID: noteID) { throw WorkspaceFoundationError.unknown }
        guard let session = notes.workspaceSession(noteID: noteID) else { throw WorkspaceFoundationError.unknown }
        if adding {
            guard case .made = await TaskNoteConversion.makeTask(fromNote: noteID, notes: notes, tasks: tasks, workspaceSession: session) else { return false }
        } else {
            guard case .removed = await TaskNoteConversion.removeTask(taskID, notes: notes, tasks: tasks, workspaceSession: session) else { return false }
        }
        return true
    }

    static func deleteItem(_ root: URL) throws -> Bool {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let coordinator = try WorkspaceOperationCoordinator(container: container, journal: journal(root))
        let store = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles")))
        let result = store.delete(taskIDs: [taskID])
        withExtendedLifetime(coordinator) { WorkspaceCrashHook.reach("A-delete-published") }
        return result
    }
    static func purgeItem(_ root: URL) async throws -> WorkspaceOperationCoordinator.Outcome {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let coordinator = try WorkspaceOperationCoordinator(container: container, journal: journal(root))
        try await coordinator.reconcileStartup()
        return await WorkspacePurge.purge(rootID: taskID, before: .distantFuture, coordinator: coordinator,
            files: TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles")), inventory: { .init(generation: 0) },
            publication: .init(steps: [{ _ in }])).outcome
    }

}
#endif
