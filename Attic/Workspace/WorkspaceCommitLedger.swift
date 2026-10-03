import Foundation
import ObjectiveC
import SwiftData

/// A proof of unchanged in-process state. Losing any part of the proof sends
/// validation to the exact disk-read path; this ledger is never durable truth.
@MainActor
final class WorkspaceCommitLedger {
    final class ContextStamp {
        let contextID = UUID()
        let ledgerID: UUID
        var syncedEntities: [WorkspaceOwner.Entity: UInt64] = [:]
        var syncedGeneration: UInt64
        init(ledgerID: UUID, syncedGeneration: UInt64) {
            self.ledgerID = ledgerID; self.syncedGeneration = syncedGeneration
        }
    }
    struct OwnerEntry {
        let generation: UInt64
        let writerContextID: UUID
    }
    private struct PhysicalEntry {
        let owner: WorkspaceOwner
        let scopes: Set<WorkspaceScope>
        let generation: UInt64
    }
    private final class WeakStamp {
        weak var value: ContextStamp?
        init(_ value: ContextStamp) { self.value = value }
    }
    private var contexts: [WeakStamp] = []
    private(set) var trimPasses = 0
    let identity = UUID()
    private(set) var generation: UInt64 = 0
    private(set) var floor: UInt64 = 0
    private var entityFloors: [WorkspaceOwner.Entity: UInt64] = [:]
    private var entityGenerations: [WorkspaceOwner.Entity: UInt64] = [:]
    private(set) var owners: [WorkspaceOwner: OwnerEntry] = [:]
    private(set) var scopes: [WorkspaceScope: UInt64] = [:]
    private(set) var foreign: [WorkspaceOwner.Entity: UInt64] = [:]
    private var scopeWriters: [WorkspaceScope: UUID] = [:]
    private var physical: [PersistentIdentifier: PhysicalEntry] = [:]
    var capacity = 8_192
    private static var contextKey: UInt8 = 0
    private var observer: NSObjectProtocol?
    private var savingContext: ModelContext?
    private var observedGatedSave = false
    private let container: ModelContainer
    var foreignContextDidSave: ((ModelContext, [PersistentIdentifier], [PersistentIdentifier]) -> Void)?
    var foreignEntitiesDidChange: ((Set<WorkspaceOwner.Entity>) -> Void)?

    init(container: ModelContainer) {
        self.container = container
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] notification in
            // Production writers are main-actor contexts. didSave is delivered
            // synchronously before the saving caller can begin another command.
            MainActor.assumeIsolated { self?.didSave(notification) }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func isSaving(_ context: ModelContext) -> Bool { savingContext === context }
    func register(_ context: ModelContext) {
        if let previous = stamp(context), previous.ledgerID != identity { return }
        let current = ContextStamp(ledgerID: identity, syncedGeneration: generation)
        objc_setAssociatedObject(context, &Self.contextKey, current, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        contexts.removeAll { $0.value == nil }
        contexts.append(WeakStamp(current))
    }
    func stamp(_ context: ModelContext) -> ContextStamp? {
        objc_getAssociatedObject(context, &Self.contextKey) as? ContextStamp
    }
    func canValidate(_ context: ModelContext, owners requestedOwners: Set<WorkspaceOwner>, scopes requestedScopes: Set<WorkspaceScope>) -> Bool {
        guard let stamp = stamp(context), stamp.ledgerID == identity else { return false }
        let entities = Set(requestedOwners.map(\.entity)).union(requestedScopes.map(\.entity))
        func baseline(_ entity: WorkspaceOwner.Entity) -> UInt64 { stamp.syncedEntities[entity] ?? stamp.syncedGeneration }
        guard entities.allSatisfy({ baseline($0) >= (entityFloors[$0] ?? 0) && (foreign[$0] ?? 0) <= baseline($0) }) else { return false }
        guard requestedOwners.allSatisfy({ owner in
            guard let entry = owners[owner] else { return true }
            return entry.generation <= baseline(owner.entity) || entry.writerContextID == stamp.contextID
        }) else { return false }
        return requestedScopes.allSatisfy { scope in
            (scopes[scope] ?? 0) <= baseline(scope.entity) || scopeWriters[scope] == stamp.contextID
        }
    }
    /// Capture mappings only from supplied rows, never by fetching a family.
    func observe(_ tokens: [WorkspaceModelToken]) throws {
        for token in tokens {
            for replica in token.replicas {
                guard physical[replica.physicalID] == nil else { continue }
                physical[replica.physicalID] = PhysicalEntry(owner: token.owner,
                    scopes: try Self.membership(token.owner, fields: replica.fields), generation: generation)
            }
        }
        trim()
    }
    func gatedSave(_ context: ModelContext, before: [WorkspaceModelToken], using save: (ModelContext) throws -> Void, didCommit: () -> Void = {}) throws {
        precondition(savingContext == nil, "Gated saves cannot nest")
        let rows = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
        let deletedIDs = Set(context.deletedModelsArray.map(\.persistentModelID))
        let mappings = rows.compactMap { row -> ((any PersistentModel), WorkspaceOwner, Set<WorkspaceScope>, PersistentIdentifier, Bool)? in
            guard let owner = WorkspaceOperationCoordinator.owner(row) else { return nil }
            let id = row.persistentModelID
            return (row, owner, Self.membership(row), id, deletedIDs.contains(id))
        }
        let changed = Set(mappings.map { $0.1 })
        var memberships = Set<WorkspaceScope>()
        for token in before { for replica in token.replicas { memberships.formUnion(try Self.membership(token.owner, fields: replica.fields)) } }
        for row in rows { memberships.formUnion(Self.membership(row)) }
        let writer = stamp(context)?.contextID ?? UUID()
        savingContext = context; observedGatedSave = false
        var returnedSuccessfully = false
        defer {
            // A save-then-throw seam still saved. Its synchronous notification
            // must be logged even though reconciliation determines the outcome.
            if returnedSuccessfully || observedGatedSave {
                generation &+= 1
                for owner in changed { owners[owner] = OwnerEntry(generation: generation, writerContextID: writer) }
                memberships.formUnion(changed.map { .all($0.entity) })
                for scope in memberships { scopes[scope] = generation; scopeWriters[scope] = writer }
                for (row, owner, membership, previousID, deleted) in mappings {
                    if deleted { physical.removeValue(forKey: previousID) }
                    else {
                        physical.removeValue(forKey: previousID)
                        physical[row.persistentModelID] = PhysicalEntry(owner: owner, scopes: membership, generation: generation)
                    }
                }
                for entity in Set(changed.map(\.entity)).union(memberships.map(\.entity)) {
                    if let current = stamp(context), (current.syncedEntities[entity] ?? current.syncedGeneration) >= (entityGenerations[entity] ?? 0) {
                        current.syncedEntities[entity] = generation
                    }
                    entityGenerations[entity] = generation
                }
                // Only a contiguous sequence of this context's own writes
                // advances its global baseline. Unseen writes by another
                // context still require exact owner/scope validation.
                if let current = stamp(context), current.syncedGeneration == generation - 1 {
                    current.syncedGeneration = generation
                }
                trim()
                didCommit()
            }
            savingContext = nil; observedGatedSave = false
        }
        try save(context); returnedSuccessfully = true
    }
    private func didSave(_ notification: Notification) {
        guard let context = notification.object as? ModelContext, context.container === container else { return }
        if context === savingContext { observedGatedSave = true; return }
        generation &+= 1
        let unknownWriter = UUID()
        var touched = Set<WorkspaceOwner.Entity>()
        let info = notification.userInfo ?? [:]
        func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier]? {
            info[key] as? [PersistentIdentifier] ?? info[key.rawValue] as? [PersistentIdentifier]
        }
        let inserted = ids(.insertedIdentifiers), updated = ids(.updatedIdentifiers), deleted = ids(.deletedIdentifiers)
        if inserted == nil || updated == nil || deleted == nil || (info[ModelContext.NotificationKey.invalidatedAllIdentifiers] as? Bool == true) || (info[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] as? Bool == true) {
            for entity in Self.entities.values { foreign[entity] = generation; touched.insert(entity) }
        } else {
            for id in inserted! {
                if let entity = Self.entities[id.entityName] { foreign[entity] = generation; touched.insert(entity) }
                else { for entity in Self.entities.values { foreign[entity] = generation; touched.insert(entity) } }
            }
            for id in updated! + deleted! {
                if let entry = physical[id] {
                    touched.insert(entry.owner.entity)
                    owners[entry.owner] = OwnerEntry(generation: generation, writerContextID: unknownWriter)
                    var affected = entry.scopes
                    if let row = Self.registeredModel(id, in: context) {
                        let membership = Self.membership(row)
                        affected.formUnion(membership)
                        if let owner = WorkspaceOperationCoordinator.owner(row) {
                            owners[owner] = OwnerEntry(generation: generation, writerContextID: unknownWriter)
                            physical[id] = PhysicalEntry(owner: owner, scopes: membership, generation: generation)
                        }
                    }
                    else if updated!.contains(id) { foreign[entry.owner.entity] = generation }
                    if deleted!.contains(id) { physical.removeValue(forKey: id) }
                    affected.insert(.all(entry.owner.entity))
                    for scope in affected { scopes[scope] = generation; scopeWriters[scope] = unknownWriter }
                } else if let entity = Self.entities[id.entityName] { foreign[entity] = generation; touched.insert(entity) }
                else { for entity in Self.entities.values { foreign[entity] = generation; touched.insert(entity) } }
            }
        }
        for entity in touched { entityGenerations[entity] = generation }
        trim()
        foreignEntitiesDidChange?(touched)
        foreignContextDidSave?(context, (inserted ?? []) + (updated ?? []), deleted ?? [])
    }
    private func trim() {
        guard owners.count > capacity || scopes.count > capacity || physical.count > capacity else { return }
        trimPasses += 1
        contexts.removeAll { $0.value == nil }
        var oldestLive: [WorkspaceOwner.Entity: UInt64] = [:]
        for entity in Self.entities.values {
            oldestLive[entity] = contexts.compactMap { $0.value.map { $0.syncedEntities[entity] ?? $0.syncedGeneration } }.min() ?? generation
        }
        // Sort once per bounded batch, leaving headroom for later writes.
        // This amortizes eviction instead of scanning O(n) per removed entry.
        let target = max(0, capacity / 2)
        func forget(_ entryGeneration: UInt64, entity: WorkspaceOwner.Entity) {
            if entryGeneration > (oldestLive[entity] ?? generation) {
                floor = max(floor, entryGeneration)
                entityFloors[entity] = max(entityFloors[entity] ?? 0, entryGeneration)
            }
        }
        if owners.count > capacity {
            for entry in owners.sorted(by: { $0.value.generation < $1.value.generation }).prefix(owners.count - target) {
                forget(entry.value.generation, entity: entry.key.entity); owners.removeValue(forKey: entry.key)
            }
        }
        if scopes.count > capacity {
            for entry in scopes.sorted(by: { $0.value < $1.value }).prefix(scopes.count - target) {
                forget(entry.value, entity: entry.key.entity); scopes.removeValue(forKey: entry.key); scopeWriters.removeValue(forKey: entry.key)
            }
        }
        if physical.count > capacity {
            // Lost mappings already cause entity-wide foreign invalidation.
            // Dropping a mapping alone cannot grant stale validation authority.
            for entry in physical.sorted(by: { $0.value.generation < $1.value.generation }).prefix(physical.count - target) {
                physical.removeValue(forKey: entry.key)
            }
        }
    }
    /// Launch migration may record thousands of rows before presentation is
    /// built. The floor carries that complete invalidation without retaining
    /// a whole-table physical/owner map for the subsequent session.
    func evictLaunchMigrationEntries() {
        floor = generation
        for entity in Self.entities.values { entityFloors[entity] = generation }
        owners = [:]; scopes = [:]; scopeWriters = [:]; physical = [:]
    }
    private static let entities: [String: WorkspaceOwner.Entity] = [
        "TaskItem": .task, "NoteItem": .note, "NoteAttachment": .attachment, "NoteVersion": .version,
        "NotePendingEdit": .proposal, "ItemLink": .link, "TaskNoteAssociation": .association,
        "TaskDeletionPreservation": .preservation, "OperationReceipt": .receipt, "CanvasBoardItem": .board,
        "CanvasStrokeItem": .stroke, "CanvasImageItem": .image, "CanvasSemanticObjectItem": .semantic
    ]
    static func entity(for id: PersistentIdentifier) -> WorkspaceOwner.Entity? { entities[id.entityName] }
    static func supportedEntities(in container: ModelContainer) -> Set<WorkspaceOwner.Entity> {
        Set(container.schema.entities.compactMap { entities[$0.name] })
    }
    static func registeredModel(_ id: PersistentIdentifier, in context: ModelContext) -> (any PersistentModel)? {
        switch id.entityName {
        case "TaskItem": return context.registeredModel(for: id) as TaskItem?
        case "NoteItem": return context.registeredModel(for: id) as NoteItem?
        case "NoteAttachment": return context.registeredModel(for: id) as NoteAttachment?
        case "NoteVersion": return context.registeredModel(for: id) as NoteVersion?
        case "NotePendingEdit": return context.registeredModel(for: id) as NotePendingEdit?
        case "ItemLink": return context.registeredModel(for: id) as ItemLink?
        case "TaskNoteAssociation": return context.registeredModel(for: id) as TaskNoteAssociation?
        case "TaskDeletionPreservation": return context.registeredModel(for: id) as TaskDeletionPreservation?
        case "OperationReceipt": return context.registeredModel(for: id) as OperationReceipt?
        case "CanvasBoardItem": return context.registeredModel(for: id) as CanvasBoardItem?
        case "CanvasStrokeItem": return context.registeredModel(for: id) as CanvasStrokeItem?
        case "CanvasImageItem": return context.registeredModel(for: id) as CanvasImageItem?
        case "CanvasSemanticObjectItem": return context.registeredModel(for: id) as CanvasSemanticObjectItem?
        default: return nil
        }
    }
    static func membership(_ owner: WorkspaceOwner, fields: [String: Data]) throws -> Set<WorkspaceScope> {
        func id(_ field: String) throws -> UUID? {
            guard let bytes = fields[field] else { throw WorkspaceFoundationError.unknown }
            return try JSONDecoder().decode(UUID?.self, from: bytes)
        }
        switch owner.entity {
        case .task: return try id("parentID").map { [.children($0)] } ?? []
        case .attachment: return try id("noteID").map { [.attachments($0)] } ?? []
        case .version: return try id("noteID").map { [.versions($0)] } ?? []
        case .proposal: return try id("noteID").map { [.proposals($0)] } ?? []
        case .association:
            var result = Set<WorkspaceScope>()
            if let value = try id("taskID") { result.insert(.taskAssociations(value)) }
            if let value = try id("noteID") { result.insert(.noteAssociations(value)) }
            return result
        case .preservation: return try id("rootID").map { [.preservations($0)] } ?? []
        default: return []
        }
    }
    static func membership(_ row: any PersistentModel) -> Set<WorkspaceScope> {
        switch row {
        case let row as TaskItem: row.parentID.map { [.children($0)] } ?? []
        case let row as NoteAttachment: [.attachments(row.noteID)]
        case let row as NoteVersion: [.versions(row.noteID)]
        case let row as NotePendingEdit: [.proposals(row.noteID)]
        case let row as TaskNoteAssociation: [.taskAssociations(row.taskID), .noteAssociations(row.noteID)]
        case let row as TaskDeletionPreservation: [.preservations(row.rootID)]
        default: []
        }
    }
}
