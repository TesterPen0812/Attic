import Foundation
import SwiftData

/// Make Task from Note (UX plan § 2.1, the ⋯ of an ordinary note; no
/// shortcut): a task from the note's title and tags, and the same document
/// becomes the task's own note: its identity, body, files and incoming
/// links are kept, and its checkboxes stay note checkboxes. One coordinator
/// commit (S1) writes the task, the note's task form (§ 2.12: block 0 the
/// title snapshot, `requires: taskNote`, the note's own tags empty) and the
/// association. Undo sends the task to Recently Deleted and returns the
/// note exactly as it was; Redo brings the same task back.
@MainActor
enum TaskNoteConversion {
    enum Outcome: Equatable {
        case made(taskID: UUID)
        case refused(String)
    }

    @MainActor private struct ResultGuard {
        let tokens: [WorkspaceModelToken]
        let scopes: [WorkspaceScopeToken]
        func validateCurrent(using coordinator: WorkspaceOperationCoordinator) throws -> Self {
            func semantic(_ token: WorkspaceModelToken) -> WorkspaceModelToken {
                .init(owner: token.owner, replicas: token.replicas.map { replica in
                    var fields = replica.fields
                    // Revision counters and update timestamps describe saves,
                    // not dependent writing; compare every semantic field.
                    if token.owner.entity == .task { fields.removeValue(forKey: "updatedAt") }
                    if token.owner.entity == .note {
                        for key in ["updatedAt", "revision", "revisionID"] { fields.removeValue(forKey: key) }
                    }
                    return .init(physicalID: replica.physicalID, fields: fields)
                })
            }
            let context = coordinator.freshContext()
            let current = try tokens.map { try WorkspaceModelToken.read($0.owner, in: context) }
            let currentScopes = try scopes.map { try WorkspaceScopeToken.read($0.scope, in: context) }
            let sameScopes = zip(currentScopes, scopes).allSatisfy { current, expected in
                current.scope == expected.scope && current.members.map(semantic) == expected.members.map(semantic)
            }
            guard current.map(semantic) == tokens.map(semantic), sameScopes else { throw WorkspaceFoundationError.conflict }
            return Self(tokens: current, scopes: currentScopes)
        }
        static func capture(noteID: UUID, taskID: UUID, using coordinator: WorkspaceOperationCoordinator) throws -> Self {
            let context = coordinator.freshContext()
            return try Self(tokens: coordinator.capture([.init(entity: .note, id: noteID), .init(entity: .task, id: taskID)]),
                scopes: [WorkspaceScope.children(taskID), .taskAssociations(taskID), .taskNotes(taskID), .noteAssociations(noteID), .attachments(noteID), .proposals(noteID)].map {
                    try WorkspaceScopeToken.read($0, in: context)
                })
        }
    }

    static func makeTask(fromNote noteID: UUID, notes: NotesPageController, tasks: TaskStore) async -> Outcome {
        guard let session = notes.active, session.noteID == noteID, !session.isReadOnly else {
            return .refused(String(localized: "This note can't become a task here"))
        }
        guard notes.settleForWorkspaceOperation(session) else { return .refused(String(localized: "Couldn't save the note first")) }
        guard let note = notes.store.note(withID: noteID), note.taskID == nil,
              let loaded = notes.store.loadDocument(noteID: noteID), let before = loaded.content.document,
              before.isWritableByThisBuild, !before.requires.contains("taskNote") else {
            return .refused(String(localized: "This note is already a task's note"))
        }
        let title = TaskDraftBuilder.collapsed(before.title)
        guard !title.isEmpty else { return .refused(String(localized: "Give the note a title first")) }
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else {
            return .refused(String(localized: "Couldn't make the task"))
        }
        let history = session.engine.history.workspace ?? notes.undoRoute.workspace(for: .note(noteID))
        guard session.engine.history.workspace != nil || session.engine.history.redoOps.isEmpty else {
            return .refused(String(localized: "Couldn't make the task"))
        }
        history.attach(session.engine.history)
        guard history.reserveInput() else { return .refused(String(localized: "Finish typing first")) }
        defer { history.releaseInput() }
        let stamp = session.callbackStamp
        let sessionValid = { [weak session, weak notes] in
            guard let session, let notes else { return false }
            return notes.active === session && session.accepts(stamp)
        }
        let tags = note.tags
        let taskID = UUID()
        guard let result = await associate(noteID: noteID, taskID: taskID, title: title, before: before, tags: tags,
                              creating: TaskDraft(title: title, tags: tags, status: .todo), coordinator: coordinator, sessionValid: sessionValid) else {
            return .refused(String(localized: "Couldn't make the task"))
        }
        guard notes.undoRoute.alias(.taskWorkspace(taskID), to: history.historyID) else { preconditionFailure("Conversion must retain one workspace history") }
        tasks.refresh()
        await notes.retireConvertedNote(noteID)
        var expected = result
        var step = UndoStep(name: String(localized: "Make Task from Note"),
                            items: { [AtticItemRef(.note, noteID), AtticItemRef(.task, taskID)] },
                            undoOutcome: { .failed }, redoOutcome: { .failed })
        step.replay = { [weak notes, weak tasks, weak coordinator, weak history] redo, commitCursor in
            guard let notes, let tasks, let coordinator, let history, history.reserveInput() else { return .failed }
            defer { history.releaseInput() }
            // An unsaved editor also depends on the result, even if its
            // store token is unchanged. Keep it rather than overwriting it.
            if let current = notes.workspaceSessionIfCached(noteID) {
                guard !current.isImporting, current.engine.textView?.hasMarkedText() != true,
                      current.engine.matchesContentIgnoringFolds(notes.store.loadDocument(noteID: noteID)?.content.document),
                      current.engine.tags == notes.store.note(withID: noteID)?.tags else { return .failed }
            }
            guard let validated = try? expected.validateCurrent(using: coordinator) else { return .failed }
            let next = redo
                ? await associate(noteID: noteID, taskID: taskID, title: title, before: before, tags: tags,
                                  creating: nil, coordinator: coordinator, expected: validated)
                : await dissociate(noteID: noteID, taskID: taskID, before: before, tags: tags,
                                   coordinator: coordinator, expected: validated)
            guard let next else { return .failed }
            expected = next
            try? commitCursor()
            tasks.refresh()
            await notes.retireConvertedNote(noteID)
            return .applied
        }
        notes.undoRoute.record(step, in: history.historyID)
        return .made(taskID: taskID)
    }

    /// The note becomes `taskID`'s own note; `creating` makes the task,
    /// otherwise the task returns from Recently Deleted (Redo).
    private static func associate(noteID: UUID, taskID: UUID, title: String, before: NoteDocument, tags: [String],
                                  creating draft: TaskDraft?, coordinator: WorkspaceOperationCoordinator,
                                  expected: ResultGuard? = nil, sessionValid: @escaping () -> Bool = { true }) async -> ResultGuard? {
        do {
            let document = try before.taskSnapshot(title: title)
            let prepared = try PreparedNoteDocument(document)
            let context = coordinator.freshContext()
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            guard !rows.isEmpty, rows.allSatisfy({ $0.taskID == nil && $0.deletedAt == nil }) else { return nil }
            let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) })
            let associationID = UUID()
            var writes: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID), .init(entity: .note, id: noteID),
                                               .init(entity: .association, id: associationID)]
            writes.formUnion(versions.values.map { .init(entity: .version, id: $0) })
            if draft == nil {
                writes.formUnion(try context.fetch(FetchDescriptor<TaskDeletionPreservation>())
                    .filter { $0.rootID == taskID && $0.retiredAt == nil }.map { .init(entity: .preservation, id: $0.id) })
            }
            let envelope = try coordinator.newEnvelope(intent: "Make Task from Note", reads: coordinator.capture(writes),
                                                       writes: writes, inverseGuards: expected?.tokens, scopes: expected?.scopes, afterDocuments: [noteID: prepared.content])
            let outcome = await coordinator.execute(envelope, sessionValid: sessionValid, stage: { commit in
                if let draft {
                    _ = try TaskStore.stageCreation(in: commit, drafts: [draft], ids: [taskID], timestamp: Date())
                } else {
                    try TaskStore.stageRestoreDeleted(in: commit, taskIDs: [taskID], timestamp: Date())
                }
                try NoteStore.stageDocument(in: commit, noteID: noteID, document: document, prepared: prepared,
                                            revisionID: UUID(), versionIDs: versions, tags: [], timestamp: Date())
                let task = try commit.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID }))
                let notes = try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
                guard !task.isEmpty else { throw WorkspaceFoundationError.conflict }
                for row in task { row.associationGeneration += 1 }
                for row in notes { row.taskID = taskID; row.associationGeneration += 1 }
                let association = TaskNoteAssociation(id: associationID, taskID: taskID, noteID: noteID)
                association.taskGeneration = task.map(\.associationGeneration).max() ?? 1
                association.noteGeneration = notes.map(\.associationGeneration).max() ?? 1
                commit.insert(association)
            })
            guard outcome == .committed || outcome == .publicationPending else { return nil }
            return try ResultGuard.capture(noteID: noteID, taskID: taskID, using: coordinator)
        } catch { return nil }
    }

    /// Undo: the task goes to Recently Deleted (with its preservation) and
    /// the note returns exactly as it was, ordinary, with its tags.
    private static func dissociate(noteID: UUID, taskID: UUID, before: NoteDocument, tags: [String],
                                   coordinator: WorkspaceOperationCoordinator, expected: ResultGuard) async -> ResultGuard? {
        do {
            let prepared = try PreparedNoteDocument(before)
            let context = coordinator.freshContext()
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            guard !rows.isEmpty, rows.allSatisfy({ $0.taskID == taskID && $0.deletedAt == nil }) else { return nil }
            let links = try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID && $0.detachedAt == nil }))
            let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) })
            let preservation = UUID()
            var writes: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID), .init(entity: .note, id: noteID),
                                               .init(entity: .preservation, id: preservation)]
            writes.formUnion(versions.values.map { .init(entity: .version, id: $0) })
            writes.formUnion(links.map { .init(entity: .association, id: $0.id) })
            let envelope = try coordinator.newEnvelope(intent: "Undo Make Task from Note", reads: coordinator.capture(writes),
                                                       writes: writes, inverseGuards: expected.tokens, scopes: expected.scopes, afterDocuments: [noteID: prepared.content])
            let outcome = await coordinator.execute(envelope, stage: { commit in
                try TaskStore.stageSoftDeletion(in: commit, taskID: taskID, preservationID: preservation, timestamp: Date())
                try NoteStore.stageDocument(in: commit, noteID: noteID, document: before, prepared: prepared,
                                            revisionID: UUID(), versionIDs: versions, tags: tags, timestamp: Date())
                for row in try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) {
                    row.taskID = nil; row.associationGeneration += 1
                }
                for link in try commit.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID && $0.detachedAt == nil })) {
                    link.detachedAt = Date(); link.noteGeneration += 1; link.taskGeneration += 1
                }
            })
            guard outcome == .committed || outcome == .publicationPending else { return nil }
            return try ResultGuard.capture(noteID: noteID, taskID: taskID, using: coordinator)
        } catch { return nil }
    }
}
