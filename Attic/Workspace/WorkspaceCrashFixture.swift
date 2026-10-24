import Darwin
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
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
        let inputs = ["exclusive.txt", "shared.txt"].map { root.appendingPathComponent($0) }
        for input in inputs { try bytes.write(to: input) }
        let references = try await files.importAttachments(inputs, existing: [])
        try JSONEncoder().encode(references).write(to: root.appendingPathComponent("purge-files.json"))
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let context = ModelContext(container), date = Date(timeIntervalSince1970: 1_700_000_000)
        let document = try PreparedNoteDocument(original)
        // Replica equality includes the encoded metadata bytes, not only
        // decoded references; JSON object-key order is unspecified.
        let exclusiveData = try JSONEncoder().encode([references[0]])
        let sharedData = try JSONEncoder().encode([references[1]])
        for _ in 0..<2 {
            let parent = TaskItem(id: taskID, title: "Parent", createdAt: date, manualOrder: 42)
            parent.listOrderVersion = TaskItem.currentListOrderVersion
            parent.imageReferencesData = exclusiveData
            context.insert(parent)
            let child = TaskItem(id: childID, title: "Child", createdAt: date, parentID: taskID)
            child.listOrderVersion = TaskItem.currentListOrderVersion
            child.imageReferencesData = sharedData
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
        let outside = TaskItem(id: alternateID, title: "Shared original owner", createdAt: date)
        outside.listOrderVersion = TaskItem.currentListOrderVersion
        outside.imageReferencesData = try JSONEncoder().encode([references[1]])
        context.insert(outside)
        context.insert(NoteVersion(id: versionID, noteID: noteID, createdAt: date, reason: .pause,
            content: document.content, contentFormat: 1, title: document.title, body: document.body,
            attachmentIDs: original.attachmentIDs, sourceRevisionID: versionID))
        context.insert(NotePendingEdit(noteID: noteID, baseRevisionToken: "fixture", proposedContent: document.content,
            agentName: "Crash fixture", createdAt: date, baseVersionID: versionID))
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

    static let earlierCircleChildID = UUID(uuidString: "D92AC3EB-5A34-48CE-9882-7F0712F47450")!

    static func seedReviewedCircle(_ root: URL, adding: Bool, moving: Bool = false) async throws {
        try await seedCircle(root, adding: adding)
        var references: [TaskImageReference] = []
        if !adding {
            let files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
            var inputs: [URL] = []
            for name in moving ? ["earlier.txt", "move.txt"] : ["earlier.txt"] {
                let input = root.appendingPathComponent(name); try bytes.write(to: input); inputs.append(input)
            }
            references = try await files.importAttachments(inputs, existing: [])
            try JSONEncoder().encode(references).write(to: root.appendingPathComponent("review-files.json"))
        }
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let context = ModelContext(container), date = Date(timeIntervalSince1970: 1_699_999_990)
        let document = try PreparedNoteDocument(adding ? original.ordinarySnapshot(title: "Parent") : original)
        context.insert(NoteVersion(id: versionID, noteID: noteID, createdAt: date, reason: .pause,
            content: document.content, contentFormat: 1, title: document.title, body: document.body,
            attachmentIDs: original.attachmentIDs, sourceRevisionID: versionID))
        context.insert(ItemLink(source: .init(.note, alternateID), target: .init(adding ? .note : .task, adding ? noteID : taskID),
            kind: .reference, createdAt: date))
        if !adding {
            let encoded = try JSONEncoder().encode([references[0]])
            for _ in 0..<2 {
                let child = TaskItem(id: earlierCircleChildID, title: "Earlier deleted child", createdAt: date, parentID: taskID)
                child.listOrderVersion = TaskItem.currentListOrderVersion
                child.deletedAt = date; child.deletionRootID = earlierCircleChildID
                child.deletionMembersRaw = earlierCircleChildID.uuidString; child.imageReferencesData = encoded
                context.insert(child)
            }
            if moving {
                let encoded = try JSONEncoder().encode([references[1]])
                for parent in try context.fetch(FetchDescriptor<TaskItem>()) where parent.id == taskID { parent.imageReferencesData = encoded }
                // Keep two physical replicas in this expanded fixture, just
                // like its original shown/removed note-owned files. Move
                // revives these removed payload rows and places their card.
                for _ in 0..<2 {
                    let reference = references[1]
                    let file = NoteAttachment(id: reference.id, noteID: noteID, originalFilename: reference.filename,
                        contentTypeIdentifier: reference.contentTypeIdentifier, byteCount: reference.byteCount, sortIndex: 2, contentDigest: reference.digest, createdAt: date, payload: bytes)
                    file.deletedAt = date; context.insert(file)
                }
            }
        }
        try context.save()
    }

    /// Exercise the same history/reservation producer as the app, with an
    /// engine-only session and fixture-owned journal/store/files.
    static func changeCircle(_ root: URL, adding: Bool, reviewAction: String? = nil, retainedWindow: Bool = false) async throws -> Bool {
        // Only the reviewed operation receives the kill/save-then-throw;
        // bootstrap its prior committed history in this child first.
        let point = ProcessInfo.processInfo.environment["ATTIC_CRASH_POINT"]
        let saveThenThrow = ProcessInfo.processInfo.environment["ATTIC_SAVE_THEN_THROW"]
        func arm() {
            if let point { setenv("ATTIC_CRASH_POINT", point, 1) } else { unsetenv("ATTIC_CRASH_POINT") }
            if let saveThenThrow { setenv("ATTIC_SAVE_THEN_THROW", saveThenThrow, 1) } else { unsetenv("ATTIC_SAVE_THEN_THROW") }
        }
        if reviewAction != nil { unsetenv("ATTIC_CRASH_POINT"); unsetenv("ATTIC_SAVE_THEN_THROW") }
        defer { arm() }
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let coordinator = try WorkspaceOperationCoordinator(container: container, journal: journal(root))
        let tasks = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles")))
        let library = AtticLibrary(tasks: tasks)
        let notes = NotesPageController(store: NoteStore(container: container,
            attachmentFileStore: NoteAttachmentFileStore(rootURL: root.appendingPathComponent("NoteFiles"))),
            journal: coordinator.journal, defaults: nil, saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        notes.attachUndoRoute(library.undo)
        func armReviewedOperation() throws {
            let rows = try coordinator.freshContext().fetch(FetchDescriptor<NoteItem>())
            guard let content = rows.first?.content, rows.allSatisfy({ $0.content == content }) else { throw WorkspaceFoundationError.conflict }
            try content.write(to: root.appendingPathComponent("review-before-content.json"), options: .atomic)
            coordinator.save = { commit in
                let writing = (commit.changedModelsArray + commit.insertedModelsArray).compactMap { $0 as? NoteItem }
                if let content = writing.first?.content {
                    guard writing.allSatisfy({ $0.content == content }) else { throw WorkspaceFoundationError.conflict }
                    try content.write(to: root.appendingPathComponent("review-after-content.json"), options: .atomic)
                }
                try commit.save()
            }
            arm()
        }
        if reviewAction != nil { await notes.recoverAtLaunchAndWait() }
        if reviewAction == "move-review-remove" {
            if retainedWindow {
                let page = try coordinator.sessions.session(for: .task(taskID), notes: notes)
                let lease = try page.acquire(surfaceID: UUID())
                try page.retainAcrossItemChanges(lease: lease)
                guard await page.close(lease) else { return false }
                try armReviewedOperation()
                WorkspaceCrashHook.reach("C2-window-migration-released")
                // Migration's existing crash matrix owns its durable steps;
                // this fixture arms just the window release/remount boundaries.
                unsetenv("ATTIC_CRASH_POINT"); unsetenv("ATTIC_SAVE_THEN_THROW")
            }
            let moved = await tasks.fileMigration.moveIntoNote(taskID, tasks: tasks, notes: notes)
            switch moved {
            case .migrated, .reconciled, .unchanged: break
            default: return false
            }
            await notes.waitForRecoveryWork()
            try armReviewedOperation(); WorkspaceCrashHook.reach("B-move-before-remove")
        }
        // Add is invoked from the ordinary note's active controller session;
        // activating this engine-only session presents no native surface.
        if adding, !notes.open(noteID: noteID) { throw WorkspaceFoundationError.unknown }
        let retainedPage: WorkspacePageSession?
        let retainedLease: WorkspacePageSession.Lease?
        if retainedWindow {
            let page = try coordinator.sessions.session(for: adding ? .note(noteID) : .task(taskID), notes: notes)
            let lease = try page.acquire(surfaceID: UUID())
            try page.retainAcrossItemChanges(lease: lease)
            retainedPage = page; retainedLease = lease
            if reviewAction == "move-review-remove" { WorkspaceCrashHook.reach("C2-window-migration-rebound") }
        } else { retainedPage = nil; retainedLease = nil }
        guard let session = retainedPage?.note ?? notes.workspaceSession(noteID: noteID) else { throw WorkspaceFoundationError.unknown }
        var changedTaskID = taskID
        if adding {
            guard case let .made(id) = await TaskNoteConversion.makeTask(fromNote: noteID, notes: notes, tasks: tasks, workspaceSession: session) else { return false }
            changedTaskID = id
        } else {
            guard case .removed = await TaskNoteConversion.removeTask(taskID, notes: notes, tasks: tasks, workspaceSession: session) else { return false }
        }
        if let retainedPage {
            guard retainedPage.activeLease == retainedLease, retainedPage.note === session,
                  session.usesWorkspaceBinding, session.engine.isBodyOnly == adding,
                  session.engine.history.workspace === retainedPage.history,
                  retainedPage.key.workspace == (adding ? .task(changedTaskID) : .note(noteID)) else { return false }
            let resolved = try coordinator.sessions.session(for: adding ? .task(changedTaskID) : .note(noteID), notes: notes)
            guard resolved === retainedPage else { return false }
        }
        let history = notes.undoRoute.workspace(for: .taskWorkspace(changedTaskID))
        if reviewAction == "undo-review-add" || reviewAction == "undo-review-remove" {
            try armReviewedOperation()
            return await history.replay(redo: false) == .applied
        }
        if reviewAction == "purge-review-circle" {
            await notes.retireConvertedNote(noteID)
            await notes.waitForRecoveryWork()
            await notes.store.waitForAttachmentReconciliation()
            history.clear()
            try armReviewedOperation()
            let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
            return report.removedTaskIDs.contains(taskID)
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
    static func restoreItem(_ root: URL) async throws -> Bool {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let coordinator = try WorkspaceOperationCoordinator(container: container, journal: journal(root))
        try await coordinator.reconcileStartup()
        let store = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles")))
        let result = store.restoreDeleted(taskID: taskID)
        return withExtendedLifetime(coordinator) { result }
    }
    static func purgeItem(_ root: URL) async throws -> WorkspaceOperationCoordinator.Outcome {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let coordinator = try WorkspaceOperationCoordinator(container: container, journal: journal(root))
        try await coordinator.reconcileStartup()
        let result = await WorkspacePurge.purge(rootID: taskID, before: .distantFuture, coordinator: coordinator,
            files: TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles")), inventory: { .init(generation: 0) },
            publication: .init(steps: [{ _ in }]))
        if result.outcome == .committed {
            try JSONEncoder().encode(result.retainedByteReasons).write(to: root.appendingPathComponent("retained-reasons.json"))
        }
        return result.outcome
    }

}
#endif
