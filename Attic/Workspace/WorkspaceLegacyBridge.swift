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
        var scopeIndex: WorkspaceScopeIndex
        let includeCanvas: Bool
        var plainTaskWrites: Set<UUID>?
        var saveObserver: NSObjectProtocol?
        init(_ coordinator: WorkspaceOperationCoordinator, _ baseline: [WorkspaceOwner: WorkspaceModelToken], includeCanvas: Bool,
             scopeIndex: WorkspaceScopeIndex) {
            self.coordinator = coordinator; self.baseline = baseline; self.includeCanvas = includeCanvas; self.scopeIndex = scopeIndex
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
                                baseline: [WorkspaceOwner: WorkspaceModelToken]? = nil,
                                scopeIndex: WorkspaceScopeIndex? = nil) throws {
        context.autosaveEnabled = false
        let coordinator = try coordinator(for: context.container)
        let baseline = try baseline ?? inventory(in: context, includeCanvas: includeCanvas)
        let index = try scopeIndex ?? WorkspaceScopeIndex(baseline)
        let state = ContextState(coordinator, baseline, includeCanvas: includeCanvas, scopeIndex: index)
        let reference = ContextReference(context)
        // Isolated fixtures can save this staging context directly. Capture
        // its actual saved baseline after success; never refresh guards while
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
    /// refreshes use context(for:) and perform a complete new inventory.
    static func presentationFollowingCommit(_ source: ModelContext) throws -> ModelContext {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else { throw WorkspaceFoundationError.unknown }
        let fresh = state.coordinator.freshContext()
        try registerContext(fresh, includeCanvas: state.includeCanvas, baseline: state.baseline, scopeIndex: state.scopeIndex)
        return fresh
    }
    static func capturedToken(_ owner: WorkspaceOwner, in source: ModelContext) throws -> WorkspaceModelToken {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else { throw WorkspaceFoundationError.unknown }
        return state.baseline[owner] ?? WorkspaceModelToken(owner: owner, replicas: [])
    }
    static func confirmedPlainTaskWrites(in source: ModelContext) throws -> Set<UUID>? {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else { throw WorkspaceFoundationError.unknown }
        return state.plainTaskWrites
    }
    static func persist(_ source: ModelContext, using writer: @escaping (ModelContext) throws -> Void,
                        sourceName: String, history: Bool = true) throws {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else {
            throw WorkspaceFoundationError.unknown
        }
        let changes = source.insertedModelsArray + source.changedModelsArray + source.deletedModelsArray
        guard let admission = state.coordinator.ownership.tryAcquire(try state.coordinator.admissionIDs(changes), kind: .admission) else {
            throw WorkspaceFoundationError.pendingPublication
        }
        defer { admission.release() }
        let writes = Set(try changes.map { row -> WorkspaceOwner in
            guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.conflict }
            return owner
        })
        if writes.isEmpty { return }
        let bulkAfter = writes.count > 8 ? try inventory(in: source, includeCanvas: true, entities: Set(writes.map(\.entity))) : nil
        var after: [WorkspaceOwner: WorkspaceModelToken] = [:]
        var before: [WorkspaceOwner: WorkspaceModelToken] = [:]
        for owner in writes {
            before[owner] = state.baseline[owner] ?? WorkspaceModelToken(owner: owner, replicas: [])
            after[owner] = try bulkAfter.map { $0[owner] ?? WorkspaceModelToken(owner: owner, replicas: []) } ?? WorkspaceModelToken.read(owner, in: source)
        }
        // Include metadata consumed at associated endpoints and parent heads.
        // Membership scopes below come from the original staging baseline.
        for token in Array(before.values) + Array(after.values) {
            for replica in token.replicas {
                for field in ["parentID", "taskID"] {
                    if let bytes = replica.fields[field], let id = try JSONDecoder().decode(UUID?.self, from: bytes) {
                        let owner = WorkspaceOwner(entity: .task, id: id)
                        before[owner] = state.baseline[owner] ?? WorkspaceModelToken(owner: owner, replicas: [])
                    }
                }
            }
        }
        let reads = before.values.sorted { ($0.owner.entity.rawValue, $0.owner.id.uuidString) < ($1.owner.entity.rawValue, $1.owner.id.uuidString) }
        let plain = try !history && state.coordinator.mayUsePlainSave(
            before: writes.map { before[$0]! }, after: writes.map { after[$0]! }, in: source)
        let scopes = WorkspaceScopeToken.scopes(for: reads).map { state.scopeIndex.token($0) }
        var staged: [StagedNoteAttachment] = []
        for owner in writes where owner.entity == .attachment {
            guard let next = after[owner], let previous = before[owner], !next.replicas.isEmpty else { continue }
            let oldPayloads = Set(previous.replicas.compactMap { $0.fields["payload"] })
            let changed = next.replicas.filter { !oldPayloads.contains($0.fields["payload"] ?? Data()) }
            guard !changed.isEmpty else { continue }
            let values = changed[0].fields
            guard changed.allSatisfy({ $0.fields == values }), let payloadData = values["payload"] else {
                throw WorkspaceFoundationError.unknown
            }
            guard let payload = try JSONDecoder().decode(Data?.self, from: payloadData) else {
                throw WorkspaceFoundationError.protectedOwner
            }
            func field<T: Decodable>(_ key: String, _ type: T.Type) throws -> T {
                guard let data = values[key] else { throw WorkspaceFoundationError.unknown }
                return try JSONDecoder().decode(type, from: data)
            }
            let value = try state.coordinator.journal.verifiedAttachmentSynchronously(id: owner.id, filename: field("originalFilename", String.self),
                contentType: field("contentTypeIdentifier", String.self),
                byteCount: field("byteCount", Int64.self), digest: field("contentDigest", String.self), bytes: payload)
            staged.append(value)
        }
        var documents: [UUID: Data] = [:]
        for (owner, next) in after where owner.entity == .note {
            let contents = try next.replicas.compactMap { replica -> Data? in
                guard let field = replica.fields["content"] else { throw WorkspaceFoundationError.unknown }
                return try JSONDecoder().decode(Data?.self, from: field)
            }
            if Set(contents).count == 1 { documents[owner.id] = contents.first }
        }
        var preDraft: NoteDraftJournalEntry?
        if !plain, documents.count == 1, let (id, document) = documents.first {
            let newNote = before[.init(entity: .note, id: id)]?.replicas.isEmpty == true
            // For first persistence/import autosave the current candidate is
            // the user's pre-save draft. Model commands preserve stored before
            // content here; open mixed commands supply their session pre-copy
            // through the asynchronous coordinator API instead.
            let beforeContent = try before[.init(entity: .note, id: id)]?.replicas.first?.fields["content"].flatMap {
                try JSONDecoder().decode(Data?.self, from: $0)
            }
            let content = !history || newNote ? document : (beforeContent ?? document)
            preDraft = NoteDraftJournalEntry(noteID: id, isPersisted: !newNote, baseRevisionID: nil,
                content: content, selectionLocation: 0, selectionLength: 0,
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
                            try WorkspaceModelFields.apply(patch, to: target.model(for: replica.physicalID))
                        } else {
                            let row = try makeRow(owner.entity)
                            try WorkspaceModelFields.apply(replica.fields, to: row)
                            target.insert(row)
                        }
                    }
                }
            })
        // The source context remains presentation/staging only; stores replace
        // it with a fresh presentation after a confirmed commit.
        let committed = state.coordinator.freshContext()
        let confirmed = try writes.count > 8
            ? inventory(in: committed, includeCanvas: true, entities: Set(writes.map(\.entity)))
            : Dictionary(uniqueKeysWithValues: writes.map { ($0, try WorkspaceModelToken.read($0, in: committed)) })
        let updates = Dictionary(uniqueKeysWithValues: writes.map { ($0, confirmed[$0] ?? WorkspaceModelToken(owner: $0, replicas: [])) })
        state.scopeIndex = try state.scopeIndex.replacing(updates)
        state.baseline.merge(updates) { _, saved in saved }
        state.plainTaskWrites = plain && writes.allSatisfy({ $0.entity == .task }) ? Set(writes.map(\.id)) : nil
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
                families[owner, default: []].append(.init(physicalID: row.persistentModelID, fields: try WorkspaceModelFields.read(row)))
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
