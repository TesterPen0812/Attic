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
        let tags = note.tags
        let taskID = UUID()
        guard await associate(noteID: noteID, taskID: taskID, title: title, before: before, tags: tags,
                              creating: TaskDraft(title: title, tags: tags, status: .todo), coordinator: coordinator) else {
            return .refused(String(localized: "Couldn't make the task"))
        }
        tasks.refresh()
        notes.retireConvertedNote(noteID)
        // One step in the Notes library's history, replayed through the
        // gate (the toast and the library's ⌘Z use the route's replay).
        var step = UndoStep(name: String(localized: "Make Task from Note"),
                            items: { [AtticItemRef(.note, noteID), AtticItemRef(.task, taskID)] },
                            undoOutcome: { .failed }, redoOutcome: { .failed })
        step.replay = { redo, commitCursor in
            let done = redo
                ? await associate(noteID: noteID, taskID: taskID, title: title, before: before, tags: tags,
                                  creating: nil, coordinator: coordinator)
                : await dissociate(noteID: noteID, taskID: taskID, before: before, tags: tags, coordinator: coordinator)
            guard done else { return .failed }
            try? commitCursor()
            tasks.refresh()
            notes.retireConvertedNote(noteID)
            return .applied
        }
        notes.undoRoute.record(step, in: .notesLibrary)
        return .made(taskID: taskID)
    }

    /// The note becomes `taskID`'s own note; `creating` makes the task,
    /// otherwise the task returns from Recently Deleted (Redo).
    private static func associate(noteID: UUID, taskID: UUID, title: String, before: NoteDocument, tags: [String],
                                  creating draft: TaskDraft?, coordinator: WorkspaceOperationCoordinator) async -> Bool {
        do {
            let document = try before.taskSnapshot(title: title)
            let prepared = try PreparedNoteDocument(document)
            let context = coordinator.freshContext()
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            guard !rows.isEmpty, rows.allSatisfy({ $0.taskID == nil && $0.deletedAt == nil }) else { return false }
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
                                                       writes: writes, afterDocuments: [noteID: prepared.content])
            let outcome = await coordinator.execute(envelope, stage: { commit in
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
            return outcome == .committed || outcome == .publicationPending
        } catch { return false }
    }

    /// Undo: the task goes to Recently Deleted (with its preservation) and
    /// the note returns exactly as it was, ordinary, with its tags.
    private static func dissociate(noteID: UUID, taskID: UUID, before: NoteDocument, tags: [String],
                                   coordinator: WorkspaceOperationCoordinator) async -> Bool {
        do {
            let prepared = try PreparedNoteDocument(before)
            let context = coordinator.freshContext()
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            guard !rows.isEmpty, rows.allSatisfy({ $0.taskID == taskID && $0.deletedAt == nil }) else { return false }
            let links = try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID && $0.detachedAt == nil }))
            let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) })
            let preservation = UUID()
            var writes: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID), .init(entity: .note, id: noteID),
                                               .init(entity: .preservation, id: preservation)]
            writes.formUnion(versions.values.map { .init(entity: .version, id: $0) })
            writes.formUnion(links.map { .init(entity: .association, id: $0.id) })
            let envelope = try coordinator.newEnvelope(intent: "Undo Make Task from Note", reads: coordinator.capture(writes),
                                                       writes: writes, afterDocuments: [noteID: prepared.content])
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
            return outcome == .committed || outcome == .publicationPending
        } catch { return false }
    }
}
