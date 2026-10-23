import Foundation
import SwiftData

/// Restoring body content never restores a historical live association. The
/// compatibility head comes from today's task or its immutable preservation.
@MainActor
enum WorkspaceRestoreNormalization {
    /// Circle-removed redirects describe retired identities, not a recipe
    /// to replay their children whenever historical writing is restored.
    private static func circleRemoved(_ document: NoteDocument, noteID: UUID, in context: ModelContext) throws -> NoteDocument? {
        guard document.requires.contains("taskNote") else { return nil }
        let notes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        guard let note = notes.first, notes.allSatisfy({ $0.taskID == nil && $0.title == note.title }) else { return nil }
        let links = try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID }))
        let redirected = links.filter { $0.detachedPreservationID != nil }
        guard !redirected.isEmpty else { return nil }
        var circle = false
        for link in redirected {
            guard link.detachedAt != nil, let id = link.detachedPreservationID else { throw WorkspaceFoundationError.conflict }
            let records = try context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.id == id }))
            guard let record = records.first else { throw WorkspaceFoundationError.unknown }
            let fields = try WorkspaceModelFields.read(record)
            guard try records.allSatisfy({ try WorkspaceModelFields.read($0) == fields }),
                  try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot).members.contains(where: { $0.id == link.taskID }) else { throw WorkspaceFoundationError.conflict }
            circle = circle || record.provenance == "circle removed"
        }
        guard circle else { return nil }
        guard links.allSatisfy({ $0.detachedAt != nil }) else { throw WorkspaceFoundationError.conflict }
        return try document.ordinarySnapshot(title: note.title)
    }

    static func materialization(_ document: NoteDocument, noteID: UUID, in context: ModelContext) throws -> WorkspaceTaskNoteMaterializer.Value? {
        guard document.requires.contains("taskNote") else { return nil }
        if let ordinary = try circleRemoved(document, noteID: noteID, in: context) {
            let notes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            guard let first = notes.first, notes.allSatisfy({ $0.tags == first.tags }) else { throw WorkspaceFoundationError.conflict }
            return .init(document: ordinary, tags: first.tags)
        }
        let links = try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID }))
            .filter { $0.detachedPreservationID != nil }
        guard !links.isEmpty else { return nil }
        let ids = Set(links.compactMap(\.detachedPreservationID)), tasks = Set(links.map(\.taskID))
        guard ids.count == 1, tasks.count == 1, let id = ids.first, let taskID = tasks.first,
              links.allSatisfy({ $0.detachedAt != nil }) else { throw WorkspaceFoundationError.conflict }
        let records = try context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.id == id }))
        guard let record = records.first, records.allSatisfy({ $0.snapshot == record.snapshot && $0.purgedAt != nil }) else { throw WorkspaceFoundationError.conflict }
        let snapshot = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot)
        return try WorkspaceTaskNoteMaterializer.materialize(document, taskID: taskID, preservation: snapshot)
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
        if let ordinary = try circleRemoved(document, noteID: noteID, in: context) { return ordinary }
        // Detached ordinary content belongs to the person, including saved
        // ordinary versions. Historical links cannot materialize it again.
        guard document.requires.contains("taskNote") else { return document }
        // A note restored as a separate note (§ 2.7.2: the task had a newer
        // one) keeps its detached links without a preservation: it is
        // ordinary already, and nothing about the task is re-applied.
        let purged = associations.filter { $0.detachedPreservationID != nil }
        guard associations.allSatisfy({ $0.detachedAt != nil }) || !purged.isEmpty else { throw WorkspaceFoundationError.conflict }
        if !purged.isEmpty {
            let associations = purged
            let ids = Set(associations.compactMap(\.detachedPreservationID))
            guard ids.count == 1, associations.allSatisfy({ $0.detachedAt != nil && $0.detachedPreservationID == ids.first }),
                  schema.contains("TaskDeletionPreservation"), let id = ids.first else { throw WorkspaceFoundationError.unknown }
            let records = try context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.id == id }))
            guard let record = records.first, records.allSatisfy({ $0.snapshot == record.snapshot && $0.rootID == record.rootID && $0.purgedAt != nil }) else { throw WorkspaceFoundationError.unknown }
            let preservation = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot)
            let taskIDs = Set(associations.map(\.taskID))
            guard taskIDs.count == 1, let taskID = taskIDs.first else { throw WorkspaceFoundationError.conflict }
            return try WorkspaceTaskNoteMaterializer.materialize(document, taskID: taskID, preservation: preservation).document
        }
        return document.requires.contains("taskNote") ? try document.ordinarySnapshot(title: document.title) : document
    }
}

/// One materializer for purge, separate-note restore and historical versions.
/// Its head and checkboxes come from the deletion preservation, never from
/// a later reconstruction of the task after it has been removed.
@MainActor
enum WorkspaceTaskNoteMaterializer {
    struct Value { let document: NoteDocument; let tags: [String] }

    static func materialize(_ document: NoteDocument, taskID: UUID,
                            preservation: WorkspacePurge.Preservation, childOrder: [UUID]? = nil) throws -> Value {
        guard let head = preservation.members.first(where: { $0.id == taskID }) else { throw WorkspaceFoundationError.conflict }
        func value<T: Decodable>(_ name: String, in member: WorkspacePurge.Preservation.Member, as: T.Type) throws -> T {
            guard let data = member.fields[name] else { throw WorkspaceFoundationError.unknown }
            return try JSONDecoder().decode(T.self, from: data)
        }
        let title = try value("title", in: head, as: String.self)
        let tags = AtticTag.decode(try value("tagsRaw", in: head, as: String.self))
        var children = try preservation.members.filter { try value("parentID", in: $0, as: UUID?.self) == taskID }
            .sorted { left, right in
                let leftDone = try value("statusRaw", in: left, as: String.self) == TaskStatus.done.rawValue
                let rightDone = try value("statusRaw", in: right, as: String.self) == TaskStatus.done.rawValue
                if leftDone != rightDone { return !leftDone }
                let l = try value("manualOrder", in: left, as: Int64?.self) ?? 0
                let r = try value("manualOrder", in: right, as: Int64?.self) ?? 0
                if l != r { return l > r }
                let leftCreated = try value("createdAt", in: left, as: Date.self)
                let rightCreated = try value("createdAt", in: right, as: Date.self)
                return leftCreated == rightCreated ? left.id.uuidString < right.id.uuidString : leftCreated < rightCreated
            }
        if let childOrder {
            guard childOrder.count == Set(childOrder).count, Set(childOrder) == Set(children.map(\.id)) else { throw WorkspaceFoundationError.conflict }
            let positions = Dictionary(uniqueKeysWithValues: childOrder.enumerated().map { ($1, $0) })
            children.sort { positions[$0.id]! < positions[$1.id]! }
        }
        // Owner decision 2026-10-23: Remove from Tasks drops task-only
        // metadata; only the subtasks become writing, in page order.
        var ordinary = try document.ordinarySnapshot(title: title)
        if document.requires.contains("taskNote") {
            let boxes = try children.map { child in
                NoteBlock.checklist(try value("title", in: child, as: String.self),
                    checked: try value("statusRaw", in: child, as: String.self) == TaskStatus.done.rawValue)
            }
            ordinary.blocks.insert(contentsOf: boxes, at: min(1, ordinary.blocks.count))
        }
        return Value(document: ordinary, tags: tags)
    }

    static func preservation(taskID: UUID, in context: ModelContext) throws -> WorkspacePurge.Preservation {
        let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID || $0.parentID == taskID }))
        if tasks.isEmpty || tasks.filter({ $0.id == taskID }).allSatisfy({ $0.deletedAt != nil }) {
            let records = try context.fetch(FetchDescriptor<TaskDeletionPreservation>()).sorted { $0.capturedAt > $1.capturedAt }
            for record in records {
                let snapshot = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot)
                if snapshot.members.contains(where: { $0.id == taskID }) { return snapshot }
            }
        }
        var members: [WorkspacePurge.Preservation.Member] = []
        for (id, rows) in Dictionary(grouping: tasks, by: \.id) {
            let fields = try WorkspaceModelFields.read(rows[0])
            guard try rows.allSatisfy({ try WorkspaceModelFields.read($0) == fields }) else { throw WorkspaceFoundationError.conflict }
            members.append(.init(id: id, fields: fields))
        }
        guard let title = tasks.first(where: { $0.id == taskID })?.title else { throw WorkspaceFoundationError.conflict }
        return .init(rootID: taskID, title: title, members: members, originals: [])
    }
}
