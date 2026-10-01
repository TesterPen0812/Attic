import Foundation
import SwiftData

/// The task tombstone is not reversible. This patch owns only normalized
/// ordinary-note content, including its pre-materialization compatibility head.
@MainActor
struct WorkspaceMaterializationPatch {
    let noteID: UUID
    let taskID: UUID
    let preservationID: UUID
    let before: NoteDocument
    let after: NoteDocument

    func record(operationID: UUID, in workspace: WorkspaceHistory,
                coordinator: WorkspaceOperationCoordinator) throws {
        let old = try before.ordinarySnapshot(title: before.title)
        let new = try after.ordinarySnapshot(title: after.title)
        let oldPrepared = try PreparedNoteDocument(old), newPrepared = try PreparedNoteDocument(new)
        guard workspace.materialize(noteID: noteID) else { throw WorkspaceFoundationError.conflict }
        workspace.recordOperation(id: operationID, name: "Task removed permanently", coordinator: coordinator,
            attachmentIDs: Set(old.attachmentIDs + new.attachmentIDs)) { redo, effect in
            let context = coordinator.freshContext(), id = noteID, root = taskID
            guard try context.fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == root })) == 0 else {
                throw WorkspaceFoundationError.conflict
            }
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
            let expected = redo ? oldPrepared.content : newPrepared.content
            guard !rows.isEmpty, rows.allSatisfy({ $0.taskID == nil && $0.deletedAt == nil && $0.content == expected }) else {
                throw WorkspaceFoundationError.conflict
            }
            let document = redo ? new : old, prepared = redo ? newPrepared : oldPrepared
            let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) })
            let attachments = try context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.noteID == id }))
            let records = try context.fetch(FetchDescriptor<TaskDeletionPreservation>()).filter { $0.id == preservationID }
            guard !records.isEmpty, records.allSatisfy({ $0.rootID == root && $0.purgedAt != nil }) else { throw WorkspaceFoundationError.protectedOwner }
            let associations = try context.fetch(FetchDescriptor<TaskNoteAssociation>()).filter { $0.noteID == id }
            guard !associations.isEmpty, associations.allSatisfy({ $0.detachedAt != nil && $0.detachedPreservationID == preservationID }) else { throw WorkspaceFoundationError.protectedOwner }
            let writes = Set<WorkspaceOwner>([.init(entity: .note, id: id)])
                .union(versions.values.map { .init(entity: .version, id: $0) })
                .union(attachments.map { .init(entity: .attachment, id: $0.id) })
            let guards = writes.union([.init(entity: .task, id: root), .init(entity: .preservation, id: preservationID)])
                .union(associations.map { .init(entity: .association, id: $0.id) })
            let envelope = try coordinator.newEnvelope(intent: "Replay materialization", reads: coordinator.capture(guards), writes: writes,
                afterDocuments: [id: prepared.content], historyEffect: WorkspaceModelFields.encode(effect), replayOf: operationID)
            return .init(envelope: envelope, stage: { commit in
                try NoteStore.stageDocument(in: commit, noteID: id, document: document, prepared: prepared,
                    revisionID: UUID(), versionIDs: versions, timestamp: Date())
            })
        }
    }
}
