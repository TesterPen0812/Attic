import Foundation
import SwiftData

/// A logical family, never a single representative. An empty physical array
/// records expected absence; a failed read throws and cannot produce absence.
struct WorkspaceOwner: Codable, Hashable, Sendable {
    enum Entity: String, Codable, Sendable {
        case task, note, attachment, version, proposal, link, association, preservation, receipt
    }
    let entity: Entity
    let id: UUID
}

struct WorkspaceModelToken: Codable, Equatable, Sendable {
    struct Replica: Codable, Equatable, Sendable {
        let physicalID: PersistentIdentifier
        let fields: [String: Data]
    }
    let owner: WorkspaceOwner
    let replicas: [Replica]

    @MainActor static func read(_ owner: WorkspaceOwner, in context: ModelContext) throws -> Self {
        let id = owner.id
        switch owner.entity {
        case .task: return try capture(owner, rows: context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })))
        case .note: return try capture(owner, rows: context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })))
        case .attachment: return try capture(owner, rows: context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == id })))
        case .version: return try capture(owner, rows: context.fetch(FetchDescriptor<NoteVersion>(predicate: #Predicate { $0.id == id })))
        case .proposal: return try capture(owner, rows: context.fetch(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { $0.id == id })))
        case .link: return try capture(owner, rows: context.fetch(FetchDescriptor<ItemLink>(predicate: #Predicate { $0.id == id })))
        case .association: return try capture(owner, rows: context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.id == id })))
        case .preservation: return try capture(owner, rows: context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.id == id })))
        case .receipt: return try capture(owner, rows: context.fetch(FetchDescriptor<OperationReceipt>(predicate: #Predicate { $0.id == id })))
        }
    }

    @MainActor private static func capture<M: PersistentModel>(_ owner: WorkspaceOwner, rows: [M]) throws -> Self {
        let replicas = try rows.map { row in
            Replica(physicalID: row.persistentModelID, fields: try WorkspaceModelFields.read(row))
        }.sorted { String(describing: $0.physicalID) < String(describing: $1.physicalID) }
        return Self(owner: owner, replicas: replicas)
    }
}

enum WorkspaceFoundationError: Error, Equatable {
    case unsupportedField(String), conflict, unknown, pendingPublication, writerAlreadyActive
    case invalidIdentity, damagedEnvelope, protectedOwner, preparationFailed
}

/// All foundation entities use only scalar attributes. Read each declared field
/// through its typed key path; an unsupported future attribute is unknown, never
/// silently omitted from a guard. This includes external-storage payload bytes.
enum WorkspaceModelFields {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }

    @MainActor static func read<M: PersistentModel>(_ model: M) throws -> [String: Data] {
        let fields = try capture(model)
        guard fields.count == M.schemaMetadata.count else {
            throw WorkspaceFoundationError.unsupportedField(String(describing: M.self))
        }
        return fields
    }

    @MainActor private static func record<M>(_ model: M, _ fields: [WorkspaceField<M>]) throws -> [String: Data] {
        var values: [String: Data] = [:]
        for field in fields { values[field.name] = try field.read(model) }
        return values
    }

    @MainActor private static func capture(_ model: any PersistentModel) throws -> [String: Data] {
        switch model {
        case let row as TaskItem:
            return try record(row, [
                WorkspaceField("id", \TaskItem.id),
                WorkspaceField("associationGeneration", \TaskItem.associationGeneration),
                WorkspaceField("title", \TaskItem.title),
                WorkspaceField("statusRaw", \TaskItem.statusRaw),
                WorkspaceField("priorityRaw", \TaskItem.priorityRaw),
                WorkspaceField("createdAt", \TaskItem.createdAt),
                WorkspaceField("updatedAt", \TaskItem.updatedAt),
                WorkspaceField("completedAt", \TaskItem.completedAt),
                WorkspaceField("manualOrder", \TaskItem.manualOrder),
                WorkspaceField("parentID", \TaskItem.parentID),
                WorkspaceField("imageReferencesData", \TaskItem.imageReferencesData),
                WorkspaceField("deletedAt", \TaskItem.deletedAt),
                WorkspaceField("deletionRootID", \TaskItem.deletionRootID),
                WorkspaceField("deletionMembersRaw", \TaskItem.deletionMembersRaw),
                WorkspaceField("removedAttachmentsData", \TaskItem.removedAttachmentsData),
                WorkspaceField("doneLoggedAt", \TaskItem.doneLoggedAt),
                WorkspaceField("tagsRaw", \TaskItem.tagsRaw),
                WorkspaceField("dueDayRaw", \TaskItem.dueDayRaw),
                WorkspaceField("listOrderVersion", \TaskItem.listOrderVersion),
                WorkspaceField("completedFromRaw", \TaskItem.completedFromRaw),
                WorkspaceField("completedFromOrder", \TaskItem.completedFromOrder)
            ])
        case let row as NoteItem:
            return try record(row, [
                WorkspaceField("id", \NoteItem.id),
                WorkspaceField("associationGeneration", \NoteItem.associationGeneration),
                WorkspaceField("title", \NoteItem.title),
                WorkspaceField("body", \NoteItem.body),
                WorkspaceField("createdAt", \NoteItem.createdAt),
                WorkspaceField("updatedAt", \NoteItem.updatedAt),
                WorkspaceField("deletedAt", \NoteItem.deletedAt),
                WorkspaceField("deletedAttachmentIDsRaw", \NoteItem.deletedAttachmentIDsRaw),
                WorkspaceField("tagsRaw", \NoteItem.tagsRaw),
                WorkspaceField("pinnedAt", \NoteItem.pinnedAt),
                WorkspaceField("content", \NoteItem.content),
                WorkspaceField("contentFormat", \NoteItem.contentFormat),
                WorkspaceField("plainText", \NoteItem.plainText),
                WorkspaceField("imageCount", \NoteItem.imageCount),
                WorkspaceField("fileCount", \NoteItem.fileCount),
                WorkspaceField("firstFileName", \NoteItem.firstFileName),
                WorkspaceField("taskID", \NoteItem.taskID),
                WorkspaceField("revision", \NoteItem.revision),
                WorkspaceField("revisionID", \NoteItem.revisionID)
            ])
        case let row as NoteAttachment:
            return try record(row, [
                WorkspaceField("id", \NoteAttachment.id),
                WorkspaceField("noteID", \NoteAttachment.noteID),
                WorkspaceField("originalFilename", \NoteAttachment.originalFilename),
                WorkspaceField("contentTypeIdentifier", \NoteAttachment.contentTypeIdentifier),
                WorkspaceField("byteCount", \NoteAttachment.byteCount),
                WorkspaceField("sortIndex", \NoteAttachment.sortIndex),
                WorkspaceField("inlineOffset", \NoteAttachment.inlineOffset),
                WorkspaceField("displayWidth", \NoteAttachment.displayWidth),
                WorkspaceField("displayHeight", \NoteAttachment.displayHeight),
                WorkspaceField("contentDigest", \NoteAttachment.contentDigest),
                WorkspaceField("createdAt", \NoteAttachment.createdAt),
                WorkspaceField("updatedAt", \NoteAttachment.updatedAt),
                WorkspaceField("deletedAt", \NoteAttachment.deletedAt),
                WorkspaceField("payload", \NoteAttachment.payload)
            ])
        case let row as NoteVersion:
            return try record(row, [
                WorkspaceField("id", \NoteVersion.id),
                WorkspaceField("noteID", \NoteVersion.noteID),
                WorkspaceField("createdAt", \NoteVersion.createdAt),
                WorkspaceField("reasonRaw", \NoteVersion.reasonRaw),
                WorkspaceField("content", \NoteVersion.content),
                WorkspaceField("contentFormat", \NoteVersion.contentFormat),
                WorkspaceField("title", \NoteVersion.title),
                WorkspaceField("body", \NoteVersion.body),
                WorkspaceField("attachmentIDsRaw", \NoteVersion.attachmentIDsRaw),
                WorkspaceField("sourceRevisionID", \NoteVersion.sourceRevisionID)
            ])
        case let row as NotePendingEdit:
            return try record(row, [
                WorkspaceField("id", \NotePendingEdit.id),
                WorkspaceField("noteID", \NotePendingEdit.noteID),
                WorkspaceField("baseRevisionToken", \NotePendingEdit.baseRevisionToken),
                WorkspaceField("proposedContent", \NotePendingEdit.proposedContent),
                WorkspaceField("baseVersionID", \NotePendingEdit.baseVersionID),
                WorkspaceField("agentName", \NotePendingEdit.agentName),
                WorkspaceField("createdAt", \NotePendingEdit.createdAt),
                WorkspaceField("needsReview", \NotePendingEdit.needsReview)
            ])
        case let row as ItemLink:
            return try record(row, [
                WorkspaceField("id", \ItemLink.id),
                WorkspaceField("sourceKindRaw", \ItemLink.sourceKindRaw),
                WorkspaceField("sourceID", \ItemLink.sourceID),
                WorkspaceField("targetKindRaw", \ItemLink.targetKindRaw),
                WorkspaceField("targetID", \ItemLink.targetID),
                WorkspaceField("kindRaw", \ItemLink.kindRaw),
                WorkspaceField("createdAt", \ItemLink.createdAt),
                WorkspaceField("updatedAt", \ItemLink.updatedAt),
                WorkspaceField("deletedAt", \ItemLink.deletedAt)
            ])
        case let row as OperationReceipt:
            return try record(row, [
                WorkspaceField("id", \OperationReceipt.id),
                WorkspaceField("envelopeDigest", \OperationReceipt.envelopeDigest),
                WorkspaceField("affectedIDs", \OperationReceipt.affectedIDs),
                WorkspaceField("resultingTokens", \OperationReceipt.resultingTokens),
                WorkspaceField("historyEffect", \OperationReceipt.historyEffect),
                WorkspaceField("replayOf", \OperationReceipt.replayOf),
                WorkspaceField("compensationOf", \OperationReceipt.compensationOf),
                WorkspaceField("publicationComplete", \OperationReceipt.publicationComplete),
                WorkspaceField("handoffProof", \OperationReceipt.handoffProof),
                WorkspaceField("envelopeReleased", \OperationReceipt.envelopeReleased),
                WorkspaceField("createdAt", \OperationReceipt.createdAt)
            ])
        case let row as TaskNoteAssociation:
            return try record(row, [
                WorkspaceField("id", \TaskNoteAssociation.id),
                WorkspaceField("taskID", \TaskNoteAssociation.taskID),
                WorkspaceField("noteID", \TaskNoteAssociation.noteID),
                WorkspaceField("taskGeneration", \TaskNoteAssociation.taskGeneration),
                WorkspaceField("noteGeneration", \TaskNoteAssociation.noteGeneration),
                WorkspaceField("detachedPreservationID", \TaskNoteAssociation.detachedPreservationID),
                WorkspaceField("detachedAt", \TaskNoteAssociation.detachedAt)
            ])
        case let row as TaskDeletionPreservation:
            return try record(row, [
                WorkspaceField("id", \TaskDeletionPreservation.id),
                WorkspaceField("rootID", \TaskDeletionPreservation.rootID),
                WorkspaceField("deletedAt", \TaskDeletionPreservation.deletedAt),
                WorkspaceField("capturedAt", \TaskDeletionPreservation.capturedAt),
                WorkspaceField("provenance", \TaskDeletionPreservation.provenance),
                WorkspaceField("snapshot", \TaskDeletionPreservation.snapshot),
                WorkspaceField("purgedAt", \TaskDeletionPreservation.purgedAt)
            ])
        default: throw WorkspaceFoundationError.unsupportedField(String(describing: type(of: model)))
        }
    }
}

@MainActor private struct WorkspaceField<M> {
    let name: String
    let read: (M) throws -> Data
    init<Value: Encodable>(_ name: String, _ keyPath: KeyPath<M, Value>) {
        self.name = name
        read = { try WorkspaceModelFields.encode($0[keyPath: keyPath]) }
    }
}
