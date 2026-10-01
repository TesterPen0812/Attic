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
        init(_ coordinator: WorkspaceOperationCoordinator, _ baseline: [WorkspaceOwner: WorkspaceModelToken]) {
            self.coordinator = coordinator; self.baseline = baseline
        }
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
    static func context(for container: ModelContainer) -> ModelContext {
        let context = ModelContext(container); context.autosaveEnabled = false
        // A failed baseline is represented by no registration. persist then
        // refuses; it never manufactures an empty read set from the failure.
        try? registerContext(context)
        return context
    }
    static func registerContext(_ context: ModelContext) throws {
        context.autosaveEnabled = false
        let coordinator = try coordinator(for: context.container)
        let baseline = try inventory(in: context)
        objc_setAssociatedObject(context, &contextKey, ContextState(coordinator, baseline), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func persist(_ source: ModelContext, using writer: @escaping (ModelContext) throws -> Void,
                        sourceName: String, history: Bool = true) throws {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else {
            throw WorkspaceFoundationError.unknown
        }
        let changes = source.insertedModelsArray + source.changedModelsArray + source.deletedModelsArray
        let writes = Set(try changes.map { row -> WorkspaceOwner in
            guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.conflict }
            return owner
        })
        if writes.isEmpty { return }
        var after: [WorkspaceOwner: WorkspaceModelToken] = [:]
        var before: [WorkspaceOwner: WorkspaceModelToken] = [:]
        for owner in writes {
            before[owner] = state.baseline[owner] ?? WorkspaceModelToken(owner: owner, replicas: [])
            after[owner] = try WorkspaceModelToken.read(owner, in: source)
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
        let plain = !history && writes.count == 1 && writes.allSatisfy { owner in
            guard let old = before[owner], let new = after[owner], !old.replicas.isEmpty,
                  old.replicas.map(\.physicalID) == new.replicas.map(\.physicalID) else { return false }
            let allowed: Set<String>
            switch owner.entity {
            case .task:
                allowed = ["title", "statusRaw", "completedAt", "completedFromRaw", "completedFromOrder", "manualOrder", "updatedAt"]
                // An association makes a task command a workspace operation.
                let idData = try? WorkspaceModelFields.encode(owner.id)
                if state.baseline.contains(where: { $0.key.entity == .note && $0.value.replicas.contains { $0.fields["taskID"] == idData } }) { return false }
            case .note:
                allowed = ["content", "contentFormat", "title", "body", "plainText", "imageCount", "fileCount", "firstFileName", "revision", "revisionID", "updatedAt", "tagsRaw"]
            default: return false
            }
            return zip(old.replicas, new.replicas).allSatisfy { old, new in
                Set(new.fields.keys.filter { new.fields[$0] != old.fields[$0] }).isSubset(of: allowed)
            }
        }
        let scopes = try WorkspaceScopeToken.scopes(for: reads).map { try WorkspaceScopeToken.fromBaseline($0, state.baseline) }
        try state.coordinator.commitCompatibility(tokens: reads, scopes: scopes, writes: writes, intent: sourceName,
            plain: plain, writer: writer, stage: { target in
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
        state.baseline = try inventory(in: state.coordinator.freshContext())
    }
    static func persistSharedChanges(_ source: ModelContext, using writer: @escaping (ModelContext) throws -> Void) throws {
        if (source.insertedModelsArray + source.changedModelsArray + source.deletedModelsArray).contains(where: { $0 is ItemLink || $0 is TaskItem || $0 is NoteItem }) {
            try persist(source, using: writer, sourceName: "canvas shared-owner mutation")
        } else {
            try writer(source)
            try registerContext(source)
        }
    }

    private static func inventory(in context: ModelContext) throws -> [WorkspaceOwner: WorkspaceModelToken] {
        let schema = Set(context.container.schema.entities.map(\.name))
        var owners = Set<WorkspaceOwner>()
        func include<M: PersistentModel>(_ type: M.Type, name: String) throws {
            guard schema.contains(name) else { return }
            for row in try context.fetch(FetchDescriptor<M>()) {
                guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.unknown }
                owners.insert(owner)
            }
        }
        try include(TaskItem.self, name: "TaskItem"); try include(NoteItem.self, name: "NoteItem")
        try include(NoteAttachment.self, name: "NoteAttachment"); try include(NoteVersion.self, name: "NoteVersion")
        try include(NotePendingEdit.self, name: "NotePendingEdit"); try include(ItemLink.self, name: "ItemLink")
        try include(TaskNoteAssociation.self, name: "TaskNoteAssociation"); try include(TaskDeletionPreservation.self, name: "TaskDeletionPreservation")
        try include(OperationReceipt.self, name: "OperationReceipt"); try include(CanvasBoardItem.self, name: "CanvasBoardItem")
        try include(CanvasStrokeItem.self, name: "CanvasStrokeItem"); try include(CanvasImageItem.self, name: "CanvasImageItem")
        try include(CanvasSemanticObjectItem.self, name: "CanvasSemanticObjectItem")
        return try Dictionary(uniqueKeysWithValues: owners.map { ($0, try WorkspaceModelToken.read($0, in: context)) })
    }
    private static func makeRow(_ entity: WorkspaceOwner.Entity) throws -> any PersistentModel {
        switch entity {
        case .task: TaskItem(backingData: TaskItem.createBackingData())
        case .note: NoteItem(backingData: NoteItem.createBackingData())
        case .attachment: NoteAttachment(backingData: NoteAttachment.createBackingData())
        case .version: NoteVersion(backingData: NoteVersion.createBackingData())
        case .proposal: NotePendingEdit(backingData: NotePendingEdit.createBackingData())
        case .link: ItemLink(backingData: ItemLink.createBackingData())
        case .association: TaskNoteAssociation(backingData: TaskNoteAssociation.createBackingData())
        case .preservation: TaskDeletionPreservation(backingData: TaskDeletionPreservation.createBackingData())
        case .receipt: OperationReceipt(backingData: OperationReceipt.createBackingData())
        case .board: CanvasBoardItem(backingData: CanvasBoardItem.createBackingData())
        case .stroke: CanvasStrokeItem(backingData: CanvasStrokeItem.createBackingData())
        case .image: CanvasImageItem(backingData: CanvasImageItem.createBackingData())
        case .semantic: CanvasSemanticObjectItem(backingData: CanvasSemanticObjectItem.createBackingData())
        }
    }
}
