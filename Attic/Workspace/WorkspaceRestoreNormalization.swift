import Foundation
import SwiftData

/// Restoring body content never restores a historical live association. The
/// compatibility head comes from today's task or its immutable preservation.
@MainActor
enum WorkspaceRestoreNormalization {
    /// Format-0 columns have no document capability marker. Detached identity
    /// still derives its title from preservation without migrating the body.
    static func detachedTitle(noteID: UUID, in context: ModelContext) throws -> String? {
        guard context.container.schema.entities.contains(where: { $0.name == "TaskNoteAssociation" }) else { return nil }
        let associations = try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID }))
        let detached = associations.filter { $0.detachedPreservationID != nil }
        guard !detached.isEmpty else { return nil }
        let ids = Set(detached.compactMap(\.detachedPreservationID)), taskIDs = Set(detached.map(\.taskID))
        guard ids.count == 1, taskIDs.count == 1, associations.allSatisfy({ $0.detachedAt != nil && $0.detachedPreservationID == ids.first }),
              let id = ids.first, let taskID = taskIDs.first else { throw WorkspaceFoundationError.conflict }
        let records = try context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.id == id }))
        guard let record = records.first, records.allSatisfy({ $0.snapshot == record.snapshot && $0.rootID == record.rootID && $0.purgedAt != nil }) else { throw WorkspaceFoundationError.unknown }
        guard try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).isEmpty else { throw WorkspaceFoundationError.conflict }
        return try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot).title(for: taskID)
    }

    static func document(_ document: NoteDocument, noteID: UUID, in context: ModelContext) throws -> NoteDocument {
        let schema = Set(context.container.schema.entities.map(\.name))
        let notes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        let associations = schema.contains("TaskNoteAssociation")
            ? try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID })) : []
        let currentTaskNote = notes.contains { row in
            row.content.flatMap { NoteContentCodec.decode($0).document }?.requires.contains("taskNote") == true
        }
        // A pre-schema taskID alone never activates taskNote semantics.
        guard document.requires.contains("taskNote") || currentTaskNote || !associations.isEmpty else { return document }
        let taskIDs = Set(notes.compactMap(\.taskID))
        guard taskIDs.count <= 1, taskIDs.isEmpty || notes.allSatisfy({ $0.taskID == taskIDs.first }) else { throw WorkspaceFoundationError.conflict }
        if let taskID = taskIDs.first {
            guard schema.contains("TaskItem") else { throw WorkspaceFoundationError.unknown }
            let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID }))
            guard let task = tasks.first, tasks.allSatisfy({ $0.title == task.title && $0.deletedAt == task.deletedAt }) else { throw WorkspaceFoundationError.conflict }
            return try document.taskSnapshot(title: task.title)
        }
        if !associations.isEmpty {
            let ids = Set(associations.compactMap(\.detachedPreservationID))
            guard ids.count == 1, associations.allSatisfy({ $0.detachedAt != nil && $0.detachedPreservationID == ids.first }),
                  schema.contains("TaskDeletionPreservation"), let id = ids.first else { throw WorkspaceFoundationError.unknown }
            let records = try context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.id == id }))
            guard let record = records.first, records.allSatisfy({ $0.snapshot == record.snapshot && $0.rootID == record.rootID && $0.purgedAt != nil }) else { throw WorkspaceFoundationError.unknown }
            let preservation = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot)
            let taskIDs = Set(associations.map(\.taskID))
            guard taskIDs.count == 1, let taskID = taskIDs.first else { throw WorkspaceFoundationError.conflict }
            return try document.ordinarySnapshot(title: preservation.title(for: taskID))
        }
        return document.requires.contains("taskNote") ? try document.ordinarySnapshot(title: document.title) : document
    }
}
