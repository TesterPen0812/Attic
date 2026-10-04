import Foundation
import CryptoKit
import SwiftData

/// A logical family, never a single representative. An empty physical array
/// records expected absence; a failed read throws and cannot produce absence.
struct WorkspaceOwner: Codable, Hashable, Sendable {
    enum Entity: String, Codable, Sendable {
        case task, note, attachment, version, proposal, link, association, preservation, receipt, board, stroke, inkPayload, image, semantic
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
        case .board: return try capture(owner, rows: context.fetch(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.id == id })))
        case .stroke: return try capture(owner, rows: context.fetch(FetchDescriptor<CanvasStrokeItem>(predicate: #Predicate { $0.id == id })))
        case .inkPayload: return try capture(owner, rows: context.fetch(FetchDescriptor<CanvasInkPayloadItem>(predicate: #Predicate { $0.id == id })))
        case .image: return try capture(owner, rows: context.fetch(FetchDescriptor<CanvasImageItem>(predicate: #Predicate { $0.id == id })))
        case .semantic: return try capture(owner, rows: context.fetch(FetchDescriptor<CanvasSemanticObjectItem>(predicate: #Predicate { $0.id == id })))
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

    /// Batch only declared owners. Unlike an inventory, unrelated rows are
    /// never fetched; every matching physical replica still enters its guard.
    @MainActor static func read(owners: Set<WorkspaceOwner>, in context: ModelContext) throws -> [WorkspaceOwner: Self] {
        if owners.count == 1, let owner = owners.first { return [owner: try read(owner, in: context)] }
        var result = Dictionary(uniqueKeysWithValues: owners.map { ($0, Self(owner: $0, replicas: [])) })
        func collect<M: PersistentModel>(_ rows: [M]) throws {
            var groups: [WorkspaceOwner: [M]] = [:]
            for row in rows {
                guard let owner = WorkspaceOperationCoordinator.owner(row), owners.contains(owner) else { throw WorkspaceFoundationError.unknown }
                groups[owner, default: []].append(row)
            }
            for (owner, rows) in groups { result[owner] = try capture(owner, rows: rows) }
        }
        for (entity, group) in Dictionary(grouping: owners, by: { $0.entity }) {
            let ids = group.map(\.id)
            switch entity {
            case .task: try collect(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) })))
            case .note: try collect(context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { ids.contains($0.id) })))
            case .attachment: try collect(context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { ids.contains($0.id) })))
            case .version: try collect(context.fetch(FetchDescriptor<NoteVersion>(predicate: #Predicate { ids.contains($0.id) })))
            case .proposal: try collect(context.fetch(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { ids.contains($0.id) })))
            case .link: try collect(context.fetch(FetchDescriptor<ItemLink>(predicate: #Predicate { ids.contains($0.id) })))
            case .association: try collect(context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { ids.contains($0.id) })))
            case .preservation: try collect(context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { ids.contains($0.id) })))
            case .receipt: try collect(context.fetch(FetchDescriptor<OperationReceipt>(predicate: #Predicate { ids.contains($0.id) })))
            case .board: try collect(context.fetch(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { ids.contains($0.id) })))
            case .stroke: try collect(context.fetch(FetchDescriptor<CanvasStrokeItem>(predicate: #Predicate { ids.contains($0.id) })))
            case .inkPayload: try collect(context.fetch(FetchDescriptor<CanvasInkPayloadItem>(predicate: #Predicate { ids.contains($0.id) })))
            case .image: try collect(context.fetch(FetchDescriptor<CanvasImageItem>(predicate: #Predicate { ids.contains($0.id) })))
            case .semantic: try collect(context.fetch(FetchDescriptor<CanvasSemanticObjectItem>(predicate: #Predicate { ids.contains($0.id) })))
            }
        }
        return result
    }

    @MainActor private static func capture<M: PersistentModel>(_ owner: WorkspaceOwner, rows: [M]) throws -> Self {
        let replicas = try rows.map { row in
            try autoreleasepool { Replica(physicalID: row.persistentModelID, fields: try WorkspaceModelFields.fingerprint(row)) }
        }.sorted { String(describing: $0.physicalID) < String(describing: $1.physicalID) }
        return Self(owner: owner, replicas: replicas)
    }

    /// Families were fetched immediately before staging in this unsuspended
    /// transaction. Inspect those instances plus insertions instead of issuing
    /// the same SQLite queries again for the staged and confirmed guards.
    @MainActor static func stagedModels(owners: Set<WorkspaceOwner>, before: [WorkspaceOwner: Self],
                                      in context: ModelContext) throws -> [any PersistentModel] {
        let removed = Set(context.deletedModelsArray.map(\.persistentModelID))
        var rows: [any PersistentModel] = []
        for owner in owners {
            for replica in before[owner]?.replicas ?? [] where !removed.contains(replica.physicalID) {
                let row = context.model(for: replica.physicalID)
                guard WorkspaceOperationCoordinator.owner(row) == owner else { throw WorkspaceFoundationError.conflict }
                rows.append(row)
            }
        }
        rows += context.insertedModelsArray.filter { row in
            WorkspaceOperationCoordinator.owner(row).map(owners.contains) == true
        }
        return rows
    }
    @MainActor static func capture(owners: Set<WorkspaceOwner>, models: [any PersistentModel]) throws -> [WorkspaceOwner: Self] {
        var families = Dictionary(uniqueKeysWithValues: owners.map { ($0, [Replica]()) })
        for row in models {
            guard let owner = WorkspaceOperationCoordinator.owner(row), owners.contains(owner) else { throw WorkspaceFoundationError.conflict }
            families[owner, default: []].append(try autoreleasepool {
                Replica(physicalID: row.persistentModelID, fields: try WorkspaceModelFields.fingerprint(row))
            })
        }
        var tokens: [WorkspaceOwner: Self] = [:]
        for (owner, replicas) in families {
            tokens[owner] = Self(owner: owner, replicas: replicas.sorted { String(describing: $0.physicalID) < String(describing: $1.physicalID) })
        }
        return tokens
    }
}

enum WorkspaceFoundationError: Error, Equatable {
    case unsupportedField(String), conflict, unknown, pendingPublication, writerAlreadyActive
    case invalidIdentity, damagedEnvelope, protectedOwner, preparationFailed
}

/// Full values are reserved for explicit snapshots and touched-row patches.
/// Guards use scalar attributes and compact fingerprints; typed key paths never
/// fault stored attachment/version/proposal bytes during fingerprint reads.
/// Unknown future attributes refuse the write rather than weakening its guard.
enum WorkspaceModelFields {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }

    static func digest(_ data: Data?) -> String {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "nil"
    }
    /// Primitive JSON scalars are byte-identical to the original encoder.
    /// Their compiled field types need no encoder/container allocation on
    /// each guard; complex values and dates keep the existing codec.
    static func scalarFingerprint<Value: Encodable>(_ value: Value) throws -> Data {
        if Value.self == UUID.self || Value.self == UUID?.self {
            return (value as? UUID).map { Data(("\"" + $0.uuidString + "\"").utf8) } ?? Data("null".utf8)
        }
        if Value.self == Bool.self || Value.self == Bool?.self {
            return (value as? Bool).map { Data(($0 ? "true" : "false").utf8) } ?? Data("null".utf8)
        }
        if Value.self == Int.self || Value.self == Int?.self {
            return (value as? Int).map { Data(String($0).utf8) } ?? Data("null".utf8)
        }
        if Value.self == Int64.self || Value.self == Int64?.self {
            return (value as? Int64).map { Data(String($0).utf8) } ?? Data("null".utf8)
        }
        return try encode(value)
    }

    // Immutable, bounded memoization avoids rehashing the same derived text
    // in source/commit/confirmed fingerprints. Equality checks the real value;
    // this is not a model/revision cache and cannot hide an external change.
    @MainActor private static var textFingerprints: [(bytes: Data, digest: Data)] = []
    @MainActor static func textFingerprint(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        guard bytes.count > 1_024 else { return Data(SHA256.hash(data: bytes)) }
        // Data equality compares exact bytes in bulk. String equality accepts
        // canonical Unicode equivalents; element-by-element UTF-8 comparison
        // makes debug autosaves linear in expensive iterator calls.
        if let cached = textFingerprints.first(where: { $0.bytes == bytes }) { return cached.digest }
        let digest = Data(SHA256.hash(data: bytes))
        textFingerprints.append((bytes, digest))
        while textFingerprints.count > 4 || textFingerprints.reduce(0, { $0 + $1.bytes.count }) > 2_097_152 {
            textFingerprints.removeFirst()
        }
        return digest
    }
    @MainActor static func fingerprint<M: PersistentModel>(_ model: M) throws -> [String: Data] {
        try capture(model, fingerprint: true)
    }

    @MainActor static func read<M: PersistentModel>(_ model: M) throws -> [String: Data] {
        let fields = try capture(model)
        guard fields.count == schemaFieldCount(M.self) else {
            throw WorkspaceFoundationError.unsupportedField(String(describing: M.self))
        }
        return fields
    }

    // These describe compiled model types, never rows or contexts. Building
    // their key paths/closures and SwiftData schema metadata for every guard
    // was visible in Time Profiler, particularly during list-order migration.
    @MainActor private static var fieldTables: [ObjectIdentifier: Any] = [:]
    @MainActor private static var schemaFieldCounts: [ObjectIdentifier: Int] = [:]
    @MainActor private static func schemaFieldCount<M: PersistentModel>(_ type: M.Type) -> Int {
        let id = ObjectIdentifier(type)
        if let count = schemaFieldCounts[id] { return count }
        let count = type.schemaMetadata.count; schemaFieldCounts[id] = count; return count
    }
    @MainActor private static func fieldTable<M: PersistentModel>(for model: M, make: () -> [WorkspaceField<M>]) -> [WorkspaceField<M>] {
        let id = ObjectIdentifier(M.self)
        if let fields = fieldTables[id] as? [WorkspaceField<M>] { return fields }
        let fields = make(); fieldTables[id] = fields; return fields
    }

    @MainActor private static func record<M: PersistentModel>(_ model: M, _ fields: [WorkspaceField<M>], applying patch: [String: Data]? = nil, fingerprint: Bool = false, keys: Set<String>? = nil, copying source: (any PersistentModel)? = nil) throws -> [String: Data] {
        guard fields.count == schemaFieldCount(M.self) else { throw WorkspaceFoundationError.unsupportedField(String(describing: M.self)) }
        if let source {
            guard let source = source as? M, let keys,
                  keys.isSubset(of: Set(fields.map(\.name))) else { throw WorkspaceFoundationError.conflict }
            for field in fields where keys.contains(field.name) { field.copy(source, model) }
            return [:]
        }
        if let patch {
            guard Set(patch.keys).isSubset(of: Set(fields.map(\.name))) else { throw WorkspaceFoundationError.conflict }
            // Blob setters compute digests. Their optional digest field follows
            // the blob, so an explicit legacy snapshot can retain its nil column.
            for field in fields { if let value = patch[field.name] { try field.write(model, value) } }
            return [:] // apply() does not need to serialize every untouched field.
        }
        var values: [String: Data] = [:]
        for field in fields where keys == nil || keys!.contains(field.name) { values[field.name] = try fingerprint ? field.fingerprint(model) : field.read(model) }
        return values
    }

    @MainActor static func patchValues(_ keys: Set<String>, from model: any PersistentModel) throws -> [String: Data] {
        try capture(model, keys: keys)
    }
    /// Transfer only changed fields without serializing document bytes/text.
    /// The complete fingerprints were validated before this typed patch runs.
    @MainActor static func copy(_ keys: Set<String>, from source: any PersistentModel, to target: any PersistentModel) throws {
        _ = try capture(target, keys: keys, copying: source)
    }
    @MainActor static func apply(_ values: [String: Data], to model: any PersistentModel) throws {
        _ = try capture(model, applying: values)
    }

    @MainActor private static func capture(_ model: any PersistentModel, applying values: [String: Data]? = nil, fingerprint: Bool = false, keys: Set<String>? = nil, copying source: (any PersistentModel)? = nil) throws -> [String: Data] {
        switch model {
        case let row as TaskItem:
            return try record(row, fieldTable(for: row) { [
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
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as NoteItem:
            return try record(row, fieldTable(for: row) { [
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
                WorkspaceField("content", \NoteItem.content, fingerprint: { note in
                    if let digest = note.contentFingerprint { return try WorkspaceModelFields.encode(digest) }
                    let digest: String
                    if let data = note.content, let context = note.modelContext,
                       let cached = try WorkspaceLegacyBridge.coordinator(for: context.container).admittedContentDigest(data) {
                        digest = cached
                    } else { digest = WorkspaceModelFields.digest(note.content) }
                    return try WorkspaceModelFields.encode(digest)
                }, copying: { source, target in target.copyStoredContent(from: source) }),
                WorkspaceField("contentFingerprint", \NoteItem.contentFingerprint),
                WorkspaceField("contentFormat", \NoteItem.contentFormat),
                WorkspaceField("plainText", \NoteItem.plainText),
                WorkspaceField("imageCount", \NoteItem.imageCount),
                WorkspaceField("fileCount", \NoteItem.fileCount),
                WorkspaceField("firstFileName", \NoteItem.firstFileName),
                WorkspaceField("taskID", \NoteItem.taskID),
                WorkspaceField("revision", \NoteItem.revision),
                WorkspaceField("revisionID", \NoteItem.revisionID)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as NoteAttachment:
            return try record(row, fieldTable(for: row) { [
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
                WorkspaceField("payload", \NoteAttachment.payload, digest: \NoteAttachment.payloadFingerprint),
                WorkspaceField("payloadFingerprint", \NoteAttachment.payloadFingerprint)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as NoteVersion:
            return try record(row, fieldTable(for: row) { [
                WorkspaceField("id", \NoteVersion.id),
                WorkspaceField("noteID", \NoteVersion.noteID),
                WorkspaceField("createdAt", \NoteVersion.createdAt),
                WorkspaceField("reasonRaw", \NoteVersion.reasonRaw),
                WorkspaceField("content", \NoteVersion.content, digest: \NoteVersion.contentFingerprint),
                WorkspaceField("contentFingerprint", \NoteVersion.contentFingerprint),
                WorkspaceField("contentFormat", \NoteVersion.contentFormat),
                WorkspaceField("title", \NoteVersion.title),
                WorkspaceField("body", \NoteVersion.body),
                WorkspaceField("attachmentIDsRaw", \NoteVersion.attachmentIDsRaw),
                WorkspaceField("sourceRevisionID", \NoteVersion.sourceRevisionID)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as NotePendingEdit:
            return try record(row, fieldTable(for: row) { [
                WorkspaceField("id", \NotePendingEdit.id),
                WorkspaceField("noteID", \NotePendingEdit.noteID),
                WorkspaceField("baseRevisionToken", \NotePendingEdit.baseRevisionToken),
                WorkspaceField("proposedContent", \NotePendingEdit.proposedContent, digest: \NotePendingEdit.proposalFingerprint),
                WorkspaceField("proposalFingerprint", \NotePendingEdit.proposalFingerprint),
                WorkspaceField("baseVersionID", \NotePendingEdit.baseVersionID),
                WorkspaceField("agentName", \NotePendingEdit.agentName),
                WorkspaceField("createdAt", \NotePendingEdit.createdAt),
                WorkspaceField("needsReview", \NotePendingEdit.needsReview)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as ItemLink:
            return try record(row, fieldTable(for: row) { [
                WorkspaceField("id", \ItemLink.id),
                WorkspaceField("sourceKindRaw", \ItemLink.sourceKindRaw),
                WorkspaceField("sourceID", \ItemLink.sourceID),
                WorkspaceField("targetKindRaw", \ItemLink.targetKindRaw),
                WorkspaceField("targetID", \ItemLink.targetID),
                WorkspaceField("kindRaw", \ItemLink.kindRaw),
                WorkspaceField("createdAt", \ItemLink.createdAt),
                WorkspaceField("updatedAt", \ItemLink.updatedAt),
                WorkspaceField("deletedAt", \ItemLink.deletedAt)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as OperationReceipt:
            return try record(row, fieldTable(for: row) { [
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
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as TaskNoteAssociation:
            return try record(row, fieldTable(for: row) { [
                WorkspaceField("id", \TaskNoteAssociation.id),
                WorkspaceField("taskID", \TaskNoteAssociation.taskID),
                WorkspaceField("noteID", \TaskNoteAssociation.noteID),
                WorkspaceField("taskGeneration", \TaskNoteAssociation.taskGeneration),
                WorkspaceField("noteGeneration", \TaskNoteAssociation.noteGeneration),
                WorkspaceField("detachedPreservationID", \TaskNoteAssociation.detachedPreservationID),
                WorkspaceField("detachedAt", \TaskNoteAssociation.detachedAt)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as TaskDeletionPreservation:
            return try record(row, fieldTable(for: row) { [
                WorkspaceField("id", \TaskDeletionPreservation.id),
                WorkspaceField("rootID", \TaskDeletionPreservation.rootID),
                WorkspaceField("deletedAt", \TaskDeletionPreservation.deletedAt),
                WorkspaceField("capturedAt", \TaskDeletionPreservation.capturedAt),
                WorkspaceField("provenance", \TaskDeletionPreservation.provenance),
                WorkspaceField("snapshot", \TaskDeletionPreservation.snapshot),
                WorkspaceField("purgedAt", \TaskDeletionPreservation.purgedAt)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as CanvasBoardItem:
            return try record(row, fieldTable(for: row) { [
                WorkspaceField("id", \CanvasBoardItem.id),
                WorkspaceField("name", \CanvasBoardItem.name),
                WorkspaceField("sortIndex", \CanvasBoardItem.sortIndex),
                WorkspaceField("formatVersion", \CanvasBoardItem.formatVersion),
                WorkspaceField("clearGeneration", \CanvasBoardItem.clearGeneration),
                WorkspaceField("mutationVersion", \CanvasBoardItem.mutationVersion),
                WorkspaceField("tombstoned", \CanvasBoardItem.tombstoned),
                WorkspaceField("createdAt", \CanvasBoardItem.createdAt),
                WorkspaceField("updatedAt", \CanvasBoardItem.updatedAt),
                WorkspaceField("deletedAt", \CanvasBoardItem.deletedAt),
                WorkspaceField("tagsRaw", \CanvasBoardItem.tagsRaw),
                WorkspaceField("purgedAt", \CanvasBoardItem.purgedAt),
                WorkspaceField("recentlyDeletedAt", \CanvasBoardItem.recentlyDeletedAt),
                WorkspaceField("deletedContentCount", \CanvasBoardItem.deletedContentCount)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as CanvasStrokeItem:
            return try record(row, fieldTable(for: row) { [
                WorkspaceField("id", \CanvasStrokeItem.id),
                WorkspaceField("canvasID", \CanvasStrokeItem.canvasID),
                WorkspaceField("payloadVersion", \CanvasStrokeItem.payloadVersion),
                WorkspaceField("payload", \CanvasStrokeItem.payload),
                WorkspaceField("binaryPayload", \CanvasStrokeItem.binaryPayload, contentDigest: true),
                WorkspaceField("binaryRowID", \CanvasStrokeItem.binaryRowID),
                WorkspaceField("binaryDigest", \CanvasStrokeItem.binaryDigest),
                WorkspaceField("boundsMinX", \CanvasStrokeItem.boundsMinX),
                WorkspaceField("boundsMinY", \CanvasStrokeItem.boundsMinY),
                WorkspaceField("boundsMaxX", \CanvasStrokeItem.boundsMaxX),
                WorkspaceField("boundsMaxY", \CanvasStrokeItem.boundsMaxY),
                WorkspaceField("offsetX", \CanvasStrokeItem.offsetX),
                WorkspaceField("offsetY", \CanvasStrokeItem.offsetY),
                WorkspaceField("rankOverride", \CanvasStrokeItem.rankOverride),
                WorkspaceField("boardGeneration", \CanvasStrokeItem.boardGeneration),
                WorkspaceField("mutationVersion", \CanvasStrokeItem.mutationVersion),
                WorkspaceField("tombstoned", \CanvasStrokeItem.tombstoned),
                WorkspaceField("createdAt", \CanvasStrokeItem.createdAt),
                WorkspaceField("updatedAt", \CanvasStrokeItem.updatedAt),
                WorkspaceField("deletedAt", \CanvasStrokeItem.deletedAt)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as CanvasInkPayloadItem:
            return try record(row, fieldTable(for: row) { [
                WorkspaceField("id", \CanvasInkPayloadItem.id),
                WorkspaceField("canvasID", \CanvasInkPayloadItem.canvasID),
                WorkspaceField("strokeID", \CanvasInkPayloadItem.strokeID),
                WorkspaceField("bytes", \CanvasInkPayloadItem.bytes, fingerprint: {
                    Data(SHA256.hash(data: $0.bytes))
                }),
                WorkspaceField("mutationVersion", \CanvasInkPayloadItem.mutationVersion),
                WorkspaceField("tombstoned", \CanvasInkPayloadItem.tombstoned),
                WorkspaceField("createdAt", \CanvasInkPayloadItem.createdAt),
                WorkspaceField("updatedAt", \CanvasInkPayloadItem.updatedAt),
                WorkspaceField("deletedAt", \CanvasInkPayloadItem.deletedAt)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as CanvasImageItem:
            return try record(row, fieldTable(for: row) { [
                WorkspaceField("id", \CanvasImageItem.id),
                WorkspaceField("canvasID", \CanvasImageItem.canvasID),
                // Canvas collectors explicitly consume image bytes; hash those
                // bytes rather than trusting metadata that can lag a raw edit.
                // Lazy note/task/link guards never fetch these image owners.
                WorkspaceField("encodedData", \CanvasImageItem.encodedData, fingerprint: { Data(SHA256.hash(data: $0.encodedData)) }),
                WorkspaceField("encodedByteCount", \CanvasImageItem.encodedByteCount),
                WorkspaceField("contentDigest", \CanvasImageItem.contentDigest),
                WorkspaceField("contentType", \CanvasImageItem.contentType),
                WorkspaceField("pixelWidth", \CanvasImageItem.pixelWidth),
                WorkspaceField("pixelHeight", \CanvasImageItem.pixelHeight),
                WorkspaceField("centerX", \CanvasImageItem.centerX),
                WorkspaceField("centerY", \CanvasImageItem.centerY),
                WorkspaceField("width", \CanvasImageItem.width),
                WorkspaceField("height", \CanvasImageItem.height),
                WorkspaceField("zIndex", \CanvasImageItem.zIndex),
                WorkspaceField("boardGeneration", \CanvasImageItem.boardGeneration),
                WorkspaceField("mutationVersion", \CanvasImageItem.mutationVersion),
                WorkspaceField("tombstoned", \CanvasImageItem.tombstoned),
                WorkspaceField("createdAt", \CanvasImageItem.createdAt),
                WorkspaceField("updatedAt", \CanvasImageItem.updatedAt),
                WorkspaceField("deletedAt", \CanvasImageItem.deletedAt)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        case let row as CanvasSemanticObjectItem:
            return try record(row, fieldTable(for: row) { [
                WorkspaceField("id", \CanvasSemanticObjectItem.id),
                WorkspaceField("canvasID", \CanvasSemanticObjectItem.canvasID),
                WorkspaceField("kind", \CanvasSemanticObjectItem.kind),
                WorkspaceField("payloadVersion", \CanvasSemanticObjectItem.payloadVersion),
                WorkspaceField("payload", \CanvasSemanticObjectItem.payload),
                WorkspaceField("centerX", \CanvasSemanticObjectItem.centerX),
                WorkspaceField("centerY", \CanvasSemanticObjectItem.centerY),
                WorkspaceField("width", \CanvasSemanticObjectItem.width),
                WorkspaceField("height", \CanvasSemanticObjectItem.height),
                WorkspaceField("rotation", \CanvasSemanticObjectItem.rotation),
                WorkspaceField("zIndex", \CanvasSemanticObjectItem.zIndex),
                WorkspaceField("boardGeneration", \CanvasSemanticObjectItem.boardGeneration),
                WorkspaceField("mutationVersion", \CanvasSemanticObjectItem.mutationVersion),
                WorkspaceField("tombstoned", \CanvasSemanticObjectItem.tombstoned),
                WorkspaceField("createdAt", \CanvasSemanticObjectItem.createdAt),
                WorkspaceField("updatedAt", \CanvasSemanticObjectItem.updatedAt),
                WorkspaceField("deletedAt", \CanvasSemanticObjectItem.deletedAt)
            ] }, applying: values, fingerprint: fingerprint, keys: keys, copying: source)
        default: throw WorkspaceFoundationError.unsupportedField(String(describing: type(of: model)))
        }
    }
}

@MainActor private struct WorkspaceField<M: PersistentModel> {
    let name: String
    let read: (M) throws -> Data
    let fingerprint: (M) throws -> Data
    let write: (M, Data) throws -> Void
    let copy: (M, M) -> Void
    init<Value: Codable & Equatable>(_ name: String, _ keyPath: ReferenceWritableKeyPath<M, Value>) {
        self.name = name
        copy = { source, target in target[keyPath: keyPath] = source[keyPath: keyPath] }
        read = { try WorkspaceModelFields.encode($0[keyPath: keyPath]) }
        // One immutable value per compiled field. Read the actual model first:
        // equality can reuse encoding across before/staged/confirmed guards,
        // but never hides a changed value or retains a row/context. Cold list-
        // order migration otherwise encodes hundreds of thousands of nil and
        // scalar values (Time Profiler), leaving temporary allocation pages.
        var lastValue: Value?, lastFingerprint: Data?
        fingerprint = { model in
            // These key paths are compiled persisted attributes. Read through
            // SwiftData's public accessor, as the synthesized getter does,
            // without registering observation dependencies for guard reads.
            let value = model.getValue(forKey: keyPath)
            if let lastValue, lastValue == value, let lastFingerprint {
                // String equality accepts canonical Unicode equivalents; a
                // persisted-field guard still needs their exact UTF-8 bytes.
                if let text = value as? String, let previous = lastValue as? String {
                    if text.utf8.elementsEqual(previous.utf8) { return lastFingerprint }
                } else if let date = value as? Date, let previous = lastValue as? Date {
                    if date.timeIntervalSinceReferenceDate.bitPattern == previous.timeIntervalSinceReferenceDate.bitPattern { return lastFingerprint }
                } else { return lastFingerprint }
            }
            let bytes: Data
            if ["body", "plainText", "title"].contains(name), let text = value as? String {
                bytes = WorkspaceModelFields.textFingerprint(text)
            } else {
                let encoded = try WorkspaceModelFields.scalarFingerprint(value)
                bytes = ["snapshot", "pointsData", "payloadData", "encodedData", "payload"].contains(name)
                    ? Data(SHA256.hash(data: encoded)) : encoded
            }
            // Large document/text/blob values have their own bounded digest
            // policy. This scalar memo must not keep their supplied bytes.
            if (value as? String).map({ $0.utf8.count > 1_024 }) == true ||
               (value as? Data).map({ $0.count > 1_024 }) == true || value is Double || value is Float {
                lastValue = nil; lastFingerprint = nil
            } else {
                lastValue = value; lastFingerprint = bytes
            }
            return bytes
        }
        write = { model, data in model[keyPath: keyPath] = try JSONDecoder().decode(Value.self, from: data) }
    }
    init<Value: Codable>(_ name: String, _ keyPath: ReferenceWritableKeyPath<M, Value>,
                         fingerprint: @escaping (M) throws -> Data,
                         copying: ((M, M) -> Void)? = nil) {
        self.name = name
        copy = copying ?? { source, target in target[keyPath: keyPath] = source[keyPath: keyPath] }
        read = { try WorkspaceModelFields.encode($0[keyPath: keyPath]) }
        self.fingerprint = fingerprint
        write = { model, data in model[keyPath: keyPath] = try JSONDecoder().decode(Value.self, from: data) }
    }
    init(_ name: String, _ keyPath: ReferenceWritableKeyPath<M, Data?>, contentDigest: Bool) {
        self.name = name
        copy = { source, target in target[keyPath: keyPath] = source[keyPath: keyPath] }
        read = { try WorkspaceModelFields.encode($0[keyPath: keyPath]) }
        fingerprint = { try WorkspaceModelFields.encode(WorkspaceModelFields.digest($0[keyPath: keyPath])) }
        write = { model, data in model[keyPath: keyPath] = try JSONDecoder().decode(Data?.self, from: data) }
    }
    init(_ name: String, _ keyPath: ReferenceWritableKeyPath<M, Data?>,
         digest: ReferenceWritableKeyPath<M, String?>) {
        self.name = name
        copy = { source, target in target[keyPath: keyPath] = source[keyPath: keyPath] }
        read = { model in
            return try WorkspaceModelFields.encode(model[keyPath: keyPath])
        }
        fingerprint = { try WorkspaceModelFields.encode($0[keyPath: digest] ?? "legacy-unfingerprinted") }
        write = { model, data in model[keyPath: keyPath] = try JSONDecoder().decode(Data?.self, from: data) }
    }

}

/// Counts actual external-payload getters, including callers outside the bridge.
/// Focused tests reset this only after ingestion/reconciliation is complete.
enum WorkspacePayloadAccess {
    @MainActor static var counts: [String: Int] = [:]
    static func note(_ kind: String, model: any PersistentModel) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            // Ingestion values are already in memory. Count persisted faults,
            // including every read made outside fingerprint construction.
            if let context = model.modelContext,
               context.insertedModelsArray.contains(where: { $0 === model }) { return }
            counts[kind, default: 0] += 1
        }
    }
}
