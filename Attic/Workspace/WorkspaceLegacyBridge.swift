import Foundation
import ObjectiveC
import SwiftData

/// Adapts the existing store staging contexts to the single fresh-context
/// writer. Presented objects are never inserted into the commit context.
@MainActor
enum WorkspaceLegacyBridge {
    private final class WeakCoordinator {
        weak var value: WorkspaceOperationCoordinator?
        init(_ value: WorkspaceOperationCoordinator) { self.value = value }
    }
    private final class ContextState {
        let coordinator: WorkspaceOperationCoordinator
        var baseline: [WorkspaceOwner: WorkspaceModelToken]
        var scopes: [WorkspaceScope: WorkspaceScopeToken] = [:]
        var captureFailed = false
        let includeCanvas: Bool
        var plainTaskWrites: Set<UUID>?
        var plainNoteWrites: Set<UUID>?
        var saveObserver: NSObjectProtocol?
        init(_ coordinator: WorkspaceOperationCoordinator, _ baseline: [WorkspaceOwner: WorkspaceModelToken], includeCanvas: Bool,
             scopes: [WorkspaceScope: WorkspaceScopeToken] = [:]) {
            self.coordinator = coordinator; self.baseline = baseline; self.includeCanvas = includeCanvas; self.scopes = scopes
        }
        deinit { if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) } }
    }
    private final class ContextReference: @unchecked Sendable {
        weak var value: ModelContext?
        init(_ value: ModelContext) { self.value = value }
    }
    private static var coordinators: [ObjectIdentifier: WeakCoordinator] = [:]
    private static var contextKey: UInt8 = 0
    private static var journalDirectories: [ObjectIdentifier: URL] = [:]
    static func configureJournalDirectory(_ directory: URL, for container: ModelContainer) {
        journalDirectories[ObjectIdentifier(container)] = directory
    }
    static func register(_ coordinator: WorkspaceOperationCoordinator) {
        coordinators[ObjectIdentifier(coordinator.container)] = WeakCoordinator(coordinator)
    }
    static func coordinator(for container: ModelContainer) throws -> WorkspaceOperationCoordinator {
        if let existing = coordinators[ObjectIdentifier(container)]?.value { return existing }
        let directory: URL
        if let configured = journalDirectories[ObjectIdentifier(container)] {
            directory = configured
        } else if let disk = container.configurations.first(where: { !$0.isStoredInMemoryOnly }) {
            directory = disk.url.deletingLastPathComponent().appendingPathComponent("NoteDrafts", isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AtticWorkspaceBridge-\(UUID().uuidString)", isDirectory: true)
        }
        return try WorkspaceOperationCoordinator(container: container, journal: NoteDraftJournal(directory: directory))
    }
    static func context(for container: ModelContainer, includeCanvas: Bool = false) -> ModelContext {
        let context = ModelContext(container); context.autosaveEnabled = false
        // A failed baseline is represented by no registration. persist then
        // refuses; it never manufactures an empty read set from the failure.
        try? registerContext(context, includeCanvas: includeCanvas)
        return context
    }
    static func registerContext(_ context: ModelContext, includeCanvas: Bool = false,
                                baseline: [WorkspaceOwner: WorkspaceModelToken]? = nil) throws {
        context.autosaveEnabled = false
        let coordinator = try coordinator(for: context.container)
        let baseline = baseline ?? [:]
        let state = ContextState(coordinator, baseline, includeCanvas: includeCanvas)
        let reference = ContextReference(context)
        // Isolated fixtures can save this staging context directly. Capture
        // a fresh empty guard cache after success; never refresh guards while
        // a command still has pending edits. This is a read, not a new writer.
        state.saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let saved = reference.value else { return }
                do { try registerContext(saved, includeCanvas: includeCanvas) }
                catch { objc_setAssociatedObject(saved, &contextKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
            }
        }
        objc_setAssociatedObject(context, &contextKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    /// Called only after persist confirms the declared mutation. External
    /// refreshes use context(for:) with fresh, lazily captured owner guards.
    static func presentationFollowingCommit(_ source: ModelContext, freshContext: ModelContext? = nil) throws -> ModelContext {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else { throw WorkspaceFoundationError.unknown }
        let fresh = freshContext ?? state.coordinator.freshContext()
        try registerContext(fresh, includeCanvas: state.includeCanvas, baseline: state.baseline)
        // Presentation can retain unchanged models from the consumed context.
        // Its preparation guards are finished; only the new context needs the
        // confirmed owner fingerprints. Do not retain migration-sized scopes.
        state.baseline.removeAll(); state.scopes.removeAll()
        return fresh
    }
    static func capturedToken(_ owner: WorkspaceOwner, in source: ModelContext) throws -> WorkspaceModelToken {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else { throw WorkspaceFoundationError.unknown }
        if let token = state.baseline[owner] { return token }
        let token = try WorkspaceModelToken.read(owner, in: source)
        state.baseline[owner] = token
        return token
    }
    static func captureBeforeMutation(_ row: any PersistentModel, in source: ModelContext) {
        captureBeforeMutations([row], in: source)
    }
    static func captureBeforeMutations(_ rows: [any PersistentModel], in source: ModelContext) {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else { return }
        let inserted = Set(source.insertedModelsArray.map { ObjectIdentifier($0) })
        var owners = Set(rows.filter { !inserted.contains(ObjectIdentifier($0)) }.compactMap { WorkspaceOperationCoordinator.owner($0) })
        // An attachment/history edit also touches its note's membership. Capture
        // that dependency before changing the first participant, not later when
        // note recency is stamped after the attachment was already changed.
        let insertedOwners = Set(source.insertedModelsArray.compactMap { WorkspaceOperationCoordinator.owner($0) })
        for row in rows {
            let noteID: UUID?
            switch row {
            case let attachment as NoteAttachment: noteID = attachment.noteID
            case let version as NoteVersion: noteID = version.noteID
            case let proposal as NotePendingEdit: noteID = proposal.noteID
            default: noteID = nil
            }
            if let noteID {
                let owner = WorkspaceOwner(entity: .note, id: noteID)
                if !insertedOwners.contains(owner) { owners.insert(owner) }
            }
        }
        do {
            let missing = owners.filter { state.baseline[$0] == nil }
            state.baseline.merge(try WorkspaceModelToken.read(owners: Set(missing), in: source)) { saved, _ in saved }
            let needed = WorkspaceScopeToken.scopes(for: owners.map { state.baseline[$0]! }).filter { state.scopes[$0] == nil }
            state.scopes.merge(try WorkspaceScopeToken.read(scopes: Set(needed), in: source)) { captured, _ in captured }
        } catch { state.captureFailed = true }
    }
    static func delete(_ row: any PersistentModel, in context: ModelContext) {
        captureBeforeMutation(row, in: context)
        context.delete(row)
    }
    static func confirmedPlainTaskWrites(in source: ModelContext) throws -> Set<UUID>? {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else { throw WorkspaceFoundationError.unknown }
        return state.plainTaskWrites
    }
    static func confirmedPlainNoteWrites(in source: ModelContext) throws -> Set<UUID>? {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else { throw WorkspaceFoundationError.unknown }
        return state.plainNoteWrites
    }
    static func persist(_ source: ModelContext, using writer: @escaping (ModelContext) throws -> Void,
                        sourceName: String, history: Bool = true) throws {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else {
            throw WorkspaceFoundationError.unknown
        }
        guard !state.captureFailed else { throw WorkspaceFoundationError.unknown }
        let changes = source.insertedModelsArray + source.changedModelsArray + source.deletedModelsArray
        guard let admission = state.coordinator.ownership.tryAcquire(try state.coordinator.admissionIDs(changes, before: Array(state.baseline.values)), kind: .admission) else {
            throw WorkspaceFoundationError.pendingPublication
        }
        defer { admission.release() }
        let writes = Set(try changes.map { row -> WorkspaceOwner in
            guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.conflict }
            return owner
        })
        if writes.isEmpty { return }
        let after = try WorkspaceModelToken.read(owners: writes, in: source)
        var before: [WorkspaceOwner: WorkspaceModelToken] = [:]
        for owner in writes {
            // Inserts have expected absence; changed/deleted owners must have
            // a guard captured before their first staged mutation.
            if let captured = state.baseline[owner] { before[owner] = captured }
            else if changes.filter({ WorkspaceOperationCoordinator.owner($0) == owner }).allSatisfy({ row in
                source.insertedModelsArray.contains { $0 === row }
            }) { before[owner] = WorkspaceModelToken(owner: owner, replicas: []) }
            else { throw WorkspaceFoundationError.unknown }
        }
        // Include metadata consumed at associated endpoints and parent heads.
        // Membership scopes below come from the original staging baseline.
        for token in Array(before.values) + Array(after.values) {
            for replica in token.replicas {
                for field in ["parentID", "taskID"] {
                    if let bytes = replica.fields[field], let id = try JSONDecoder().decode(UUID?.self, from: bytes) {
                        let owner = WorkspaceOwner(entity: .task, id: id)
                        // A parent created in this same batch still has
                        // expected absence; never replace it with staged rows.
                        if before[owner] == nil { before[owner] = try capturedToken(owner, in: source) }
                    }
                }
            }
        }
        let reads = before.values.sorted { ($0.owner.entity.rawValue, $0.owner.id.uuidString) < ($1.owner.entity.rawValue, $1.owner.id.uuidString) }
        let plain = try state.coordinator.mayUsePlainSave(
            before: writes.map { before[$0]! }, after: writes.map { after[$0]! }, in: source)
        let requiredScopes = WorkspaceScopeToken.scopes(for: reads)
        let missingScopes = requiredScopes.filter { state.scopes[$0] == nil }
        let freshScopes = try WorkspaceScopeToken.read(scopes: Set(missingScopes), in: state.coordinator.freshContext())
        let scopes = requiredScopes.map { state.scopes[$0] ?? freshScopes[$0]! }
        var staged: [StagedNoteAttachment] = []
        for row in changes.compactMap({ $0 as? NoteAttachment }) {
            let old = before[.init(entity: .attachment, id: row.id)]?.replicas.first { $0.physicalID == row.persistentModelID }
            guard let next = after[.init(entity: .attachment, id: row.id)]?.replicas.first(where: { $0.physicalID == row.persistentModelID }),
                  old?.fields["payload"] != next.fields["payload"] else { continue }
            // New bytes are already supplied by ingestion. Only this class
            // needs payload materialization and a durable envelope.
            guard let payload = row.payload else { throw WorkspaceFoundationError.protectedOwner }
            staged.append(try state.coordinator.journal.verifiedAttachmentSynchronously(id: row.id,
                filename: row.originalFilename, contentType: row.contentTypeIdentifier,
                byteCount: row.byteCount, digest: row.contentDigest, bytes: payload))
        }
        var documents: [UUID: Data] = [:]
        if !plain {
            for owner in writes where owner.entity == .note {
                let id = owner.id
                let rows = try source.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
                let contents = rows.compactMap(\.content)
                if contents.count == rows.count, Set(contents).count == 1 { documents[id] = contents.first }
            }
        }
        var preDraft: NoteDraftJournalEntry?
        if !plain, documents.count == 1, let (id, document) = documents.first {
            let newNote = before[.init(entity: .note, id: id)]?.replicas.isEmpty == true
            let pre = state.coordinator.freshContext()
            let beforeContent = try pre.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first?.content
            preDraft = NoteDraftJournalEntry(noteID: id, isPersisted: !newNote, baseRevisionID: nil,
                content: !history || newNote ? document : (beforeContent ?? document), selectionLocation: 0, selectionLength: 0,
                staged: staged.map { .init(id: $0.id, filename: $0.filename, contentTypeIdentifier: $0.contentTypeIdentifier,
                    byteCount: $0.byteCount, digest: $0.digest) }, savedAt: Date())
        }
        try state.coordinator.commitCompatibility(tokens: reads, scopes: scopes, writes: writes, intent: sourceName,
            plain: plain, writer: writer, staged: staged, afterDocuments: documents, preDraft: preDraft, stage: { target in
                for owner in writes {
                    guard let old = before[owner], let new = after[owner] else { throw WorkspaceFoundationError.unknown }
                    let oldByID = Dictionary(uniqueKeysWithValues: old.replicas.map { ($0.physicalID, $0.fields) })
                    let newIDs = Set(new.replicas.map(\.physicalID))
                    for replica in old.replicas where !newIDs.contains(replica.physicalID) {
                        target.delete(target.model(for: replica.physicalID))
                    }
                    for replica in new.replicas {
                        if let previous = oldByID[replica.physicalID] {
                            let patch = replica.fields.filter { previous[$0.key] != $0.value }
                            try WorkspaceModelFields.copy(Set(patch.keys), from: source.model(for: replica.physicalID),
                                to: target.model(for: replica.physicalID))
                        } else {
                            let row = try makeRow(owner.entity)
                            try WorkspaceModelFields.copy(Set(replica.fields.keys), from: source.model(for: replica.physicalID), to: row)
                            target.insert(row)
                        }
                    }
                }
            })
        // The source context remains presentation/staging only; stores replace
        // it with a fresh presentation after a confirmed commit.
        let committed = state.coordinator.freshContext()
        let confirmed = try WorkspaceModelToken.read(owners: writes, in: committed)
        let updates = confirmed
        state.baseline = updates
        state.scopes.removeAll()
        state.plainTaskWrites = plain && writes.allSatisfy({ $0.entity == .task }) ? Set(writes.map(\.id)) : nil
        state.plainNoteWrites = plain && writes.allSatisfy({ $0.entity == .note }) ? Set(writes.map(\.id)) : nil
    }
    static func persistSharedChanges(_ source: ModelContext, using writer: @escaping (ModelContext) throws -> Void) throws {
        if (source.insertedModelsArray + source.changedModelsArray + source.deletedModelsArray).contains(where: { $0 is ItemLink || $0 is TaskItem || $0 is NoteItem }) {
            try persist(source, using: writer, sourceName: "canvas shared-owner mutation")
        } else {
            try writer(source)
        }
    }

    static func inventory(in context: ModelContext, includeCanvas: Bool, entities: Set<WorkspaceOwner.Entity>? = nil) throws -> [WorkspaceOwner: WorkspaceModelToken] {
        let schema = Set(context.container.schema.entities.map(\.name))
        var families: [WorkspaceOwner: [WorkspaceModelToken.Replica]] = [:]
        func include<M: PersistentModel>(_ type: M.Type, name: String) throws {
            let entity: WorkspaceOwner.Entity
            switch name {
            case "TaskItem": entity = .task
            case "NoteItem": entity = .note
            case "NoteAttachment": entity = .attachment
            case "NoteVersion": entity = .version
            case "NotePendingEdit": entity = .proposal
            case "ItemLink": entity = .link
            case "TaskNoteAssociation": entity = .association
            case "TaskDeletionPreservation": entity = .preservation
            case "OperationReceipt": entity = .receipt
            case "CanvasBoardItem": entity = .board
            case "CanvasStrokeItem": entity = .stroke
            case "CanvasImageItem": entity = .image
            case "CanvasSemanticObjectItem": entity = .semantic
            default: throw WorkspaceFoundationError.unsupportedField(name)
            }
            if let entities, !entities.contains(entity) { return }
            if let entities, entities.contains(entity), !schema.contains(name) { throw WorkspaceFoundationError.unsupportedField(name) }
            guard schema.contains(name) else { return }
            for row in try context.fetch(FetchDescriptor<M>()) {
                guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.unknown }
                families[owner, default: []].append(.init(physicalID: row.persistentModelID, fields: try WorkspaceModelFields.fingerprint(row)))
            }
        }
        try include(TaskItem.self, name: "TaskItem"); try include(NoteItem.self, name: "NoteItem")
        try include(NoteAttachment.self, name: "NoteAttachment"); try include(NoteVersion.self, name: "NoteVersion")
        try include(NotePendingEdit.self, name: "NotePendingEdit"); try include(ItemLink.self, name: "ItemLink")
        try include(TaskNoteAssociation.self, name: "TaskNoteAssociation"); try include(TaskDeletionPreservation.self, name: "TaskDeletionPreservation")
        try include(OperationReceipt.self, name: "OperationReceipt")
        if includeCanvas {
            try include(CanvasBoardItem.self, name: "CanvasBoardItem")
            try include(CanvasStrokeItem.self, name: "CanvasStrokeItem"); try include(CanvasImageItem.self, name: "CanvasImageItem")
            try include(CanvasSemanticObjectItem.self, name: "CanvasSemanticObjectItem")
        }
        return Dictionary(uniqueKeysWithValues: families.map { owner, rows in
            (owner, WorkspaceModelToken(owner: owner, replicas: rows.sorted { String(describing: $0.physicalID) < String(describing: $1.physicalID) }))
        })
    }
    private static func makeRow(_ entity: WorkspaceOwner.Entity) throws -> any PersistentModel {
        switch entity {
        case .task: TaskItem(title: "")
        case .note: NoteItem()
        case .attachment: NoteAttachment(noteID: UUID(), originalFilename: "", byteCount: 0, sortIndex: 0, contentDigest: "")
        case .version: NoteVersion(noteID: UUID(), createdAt: Date(), reason: .replacedByDraft, content: nil, contentFormat: 0, title: "", body: "", attachmentIDs: [], sourceRevisionID: nil)
        case .proposal: NotePendingEdit(noteID: UUID(), baseRevisionToken: "", proposedContent: Data(), agentName: "", createdAt: Date())
        case .link: ItemLink(source: .init(.task, UUID()), target: .init(.note, UUID()), kind: .reference)
        case .association: TaskNoteAssociation(taskID: UUID(), noteID: UUID())
        case .preservation: TaskDeletionPreservation(rootID: UUID(), deletedAt: Date(), capturedAt: Date(), provenance: "", snapshot: Data())
        case .receipt: OperationReceipt(id: UUID(), envelopeDigest: "", affectedIDs: Data(), resultingTokens: Data())
        case .board: CanvasBoardItem()
        case .stroke: CanvasStrokeItem()
        case .image: CanvasImageItem()
        case .semantic: CanvasSemanticObjectItem()
        }
    }
}
