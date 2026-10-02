import Foundation
import SwiftData

/// Membership queries carry expected absence too. Tokenizing only known IDs
/// cannot detect a new sibling or association arriving during preparation.
enum WorkspaceScope: Codable, Hashable, Sendable {
    case all(WorkspaceOwner.Entity)
    case children(UUID), attachments(UUID), versions(UUID), proposals(UUID)
    case taskAssociations(UUID), noteAssociations(UUID), preservations(UUID)
    var entity: WorkspaceOwner.Entity {
        switch self {
        case let .all(entity): entity
        case .children: .task
        case .attachments: .attachment
        case .versions: .version
        case .proposals: .proposal
        case .taskAssociations, .noteAssociations: .association
        case .preservations: .preservation
        }
    }
}

/// Index one complete physical inventory once. Large family commands must
/// not issue one table scan for every task's empty association scope.
struct WorkspaceScopeIndex {
    private var inventory: [WorkspaceOwner: WorkspaceModelToken]
    private var membership: [WorkspaceScope: Set<WorkspaceOwner>] = [:]
    init(_ inventory: [WorkspaceOwner: WorkspaceModelToken]) throws {
        self.inventory = inventory
        for (owner, token) in inventory {
            for scope in try Self.scopes(of: token) { membership[scope, default: []].insert(owner) }
        }
    }
    /// Only a confirmed, declared write set changes this complete snapshot.
    /// Validation still reads the affected scopes from the fresh commit context.
    func replacing(_ updates: [WorkspaceOwner: WorkspaceModelToken]) throws -> Self {
        var next = self
        for (owner, token) in updates {
            if let previous = inventory[owner] {
                for scope in try Self.scopes(of: previous) { next.membership[scope]?.remove(owner) }
            }
            next.inventory[owner] = token
            for scope in try Self.scopes(of: token) { next.membership[scope, default: []].insert(owner) }
        }
        return next
    }
    private static func scopes(of token: WorkspaceModelToken) throws -> Set<WorkspaceScope> {
        var scopes = Set<WorkspaceScope>()
        for replica in token.replicas {
            func id(_ key: String) throws -> UUID? {
                guard let data = replica.fields[key] else { throw WorkspaceFoundationError.unknown }
                return try JSONDecoder().decode(UUID?.self, from: data)
            }
            switch token.owner.entity {
            case .task: if let value = try id("parentID") { scopes.insert(.children(value)) }
            case .attachment: if let value = try id("noteID") { scopes.insert(.attachments(value)) }
            case .version: if let value = try id("noteID") { scopes.insert(.versions(value)) }
            case .proposal: if let value = try id("noteID") { scopes.insert(.proposals(value)) }
            case .association:
                if let value = try id("taskID") { scopes.insert(.taskAssociations(value)) }
                if let value = try id("noteID") { scopes.insert(.noteAssociations(value)) }
            case .preservation: if let value = try id("rootID") { scopes.insert(.preservations(value)) }
            default: break
            }
        }
        return scopes
    }
    func token(_ scope: WorkspaceScope) -> WorkspaceScopeToken {
        if case let .all(entity) = scope {
            return WorkspaceScopeToken(scope: scope, members: inventory.values.filter { $0.owner.entity == entity && !$0.replicas.isEmpty }.sorted { $0.owner.id.uuidString < $1.owner.id.uuidString })
        }
        return WorkspaceScopeToken(scope: scope, members: (membership[scope] ?? []).sorted { $0.id.uuidString < $1.id.uuidString }.map { inventory[$0]! })
    }
}
struct WorkspaceScopeToken: Codable, Equatable, Sendable {
    let scope: WorkspaceScope
    let members: [WorkspaceModelToken]

    /// Fetch related rows for the requested families in batches. A large
    /// touched set (such as list-order migration) must not issue thousands
    /// of otherwise-empty membership queries or scan unrelated blob owners.
    @MainActor static func read(scopes: Set<WorkspaceScope>, in context: ModelContext) throws -> [WorkspaceScope: Self] {
        if scopes.count == 1, let scope = scopes.first { return [scope: try read(scope, in: context)] }
        var membership = Dictionary(uniqueKeysWithValues: scopes.map { ($0, Set<WorkspaceOwner>()) })
        var result: [WorkspaceScope: Self] = [:]
        var children: [UUID?] = [], attachments: [UUID] = [], versions: [UUID] = [], proposals: [UUID] = []
        var taskAssociations: [UUID] = [], noteAssociations: [UUID] = [], preservations: [UUID] = []
        for scope in scopes {
            switch scope {
            case .all: result[scope] = try read(scope, in: context)
            case let .children(id): children.append(id)
            case let .attachments(id): attachments.append(id)
            case let .versions(id): versions.append(id)
            case let .proposals(id): proposals.append(id)
            case let .taskAssociations(id): taskAssociations.append(id)
            case let .noteAssociations(id): noteAssociations.append(id)
            case let .preservations(id): preservations.append(id)
            }
        }
        func add(_ row: any PersistentModel, to scope: WorkspaceScope) throws {
            guard scopes.contains(scope) else { return }
            guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.unknown }
            membership[scope, default: []].insert(owner)
        }
        if !children.isEmpty {
            for row in try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { children.contains($0.parentID) })) {
                if let parent = row.parentID { try add(row, to: .children(parent)) }
            }
        }
        if !attachments.isEmpty {
            for row in try context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { attachments.contains($0.noteID) })) { try add(row, to: .attachments(row.noteID)) }
        }
        if !versions.isEmpty {
            for row in try context.fetch(FetchDescriptor<NoteVersion>(predicate: #Predicate { versions.contains($0.noteID) })) { try add(row, to: .versions(row.noteID)) }
        }
        if !proposals.isEmpty {
            for row in try context.fetch(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { proposals.contains($0.noteID) })) { try add(row, to: .proposals(row.noteID)) }
        }
        if !taskAssociations.isEmpty || !noteAssociations.isEmpty {
            for row in try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { taskAssociations.contains($0.taskID) || noteAssociations.contains($0.noteID) })) {
                try add(row, to: .taskAssociations(row.taskID)); try add(row, to: .noteAssociations(row.noteID))
            }
        }
        if !preservations.isEmpty {
            for row in try context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { preservations.contains($0.rootID) })) { try add(row, to: .preservations(row.rootID)) }
        }
        let tokens = try WorkspaceModelToken.read(owners: membership.values.reduce(into: Set<WorkspaceOwner>()) { $0.formUnion($1) }, in: context)
        for (scope, owners) in membership where result[scope] == nil {
            result[scope] = Self(scope: scope, members: owners.sorted { $0.id.uuidString < $1.id.uuidString }.map { tokens[$0]! })
        }
        return result
    }

    @MainActor static func read(_ scope: WorkspaceScope, in context: ModelContext) throws -> Self {
        var owners = Set<WorkspaceOwner>()
        func collect<M: PersistentModel>(_ rows: [M]) throws {
            for row in rows {
                guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.unknown }
                owners.insert(owner)
            }
        }
        switch scope {
        case let .all(entity):
            return Self(scope: scope, members: try WorkspaceLegacyBridge.inventory(in: context, includeCanvas: true, entities: [entity]).values.sorted { $0.owner.id.uuidString < $1.owner.id.uuidString })
        case let .children(id): try collect(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.parentID == id })))
        case let .attachments(id): try collect(context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.noteID == id })))
        case let .versions(id): try collect(context.fetch(FetchDescriptor<NoteVersion>(predicate: #Predicate { $0.noteID == id })))
        case let .proposals(id): try collect(context.fetch(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { $0.noteID == id })))
        case let .taskAssociations(id): try collect(context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.taskID == id })))
        case let .noteAssociations(id): try collect(context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == id })))
        case let .preservations(id): try collect(context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.rootID == id })))
        }
        return Self(scope: scope, members: try owners.sorted { $0.id.uuidString < $1.id.uuidString }
            .map { try WorkspaceModelToken.read($0, in: context) })
    }
    static func scopes(for tokens: [WorkspaceModelToken]) -> Set<WorkspaceScope> {
        var scopes = Set<WorkspaceScope>()
        for token in tokens {
            switch token.owner.entity {
            case .task:
                scopes.formUnion([.children(token.owner.id), .taskAssociations(token.owner.id), .preservations(token.owner.id)])
            case .note:
                scopes.formUnion([.attachments(token.owner.id), .versions(token.owner.id),
                                  .proposals(token.owner.id), .noteAssociations(token.owner.id)])
            default: break
            }
        }
        return scopes
    }
    static func fromBaseline(_ scope: WorkspaceScope, _ baseline: [WorkspaceOwner: WorkspaceModelToken]) throws -> Self {
        let entity: WorkspaceOwner.Entity
        let field: String
        let id: UUID
        switch scope {
        case let .all(value):
            return Self(scope: scope, members: baseline.values.filter { $0.owner.entity == value && !$0.replicas.isEmpty }.sorted { $0.owner.id.uuidString < $1.owner.id.uuidString })
        case let .children(value): entity = .task; field = "parentID"; id = value
        case let .attachments(value): entity = .attachment; field = "noteID"; id = value
        case let .versions(value): entity = .version; field = "noteID"; id = value
        case let .proposals(value): entity = .proposal; field = "noteID"; id = value
        case let .taskAssociations(value): entity = .association; field = "taskID"; id = value
        case let .noteAssociations(value): entity = .association; field = "noteID"; id = value
        case let .preservations(value): entity = .preservation; field = "rootID"; id = value
        }
        let encoded = try WorkspaceModelFields.encode(id)
        return Self(scope: scope, members: baseline.values.filter {
            $0.owner.entity == entity && $0.replicas.contains { $0.fields[field] == encoded }
        }.sorted { $0.owner.id.uuidString < $1.owner.id.uuidString })
    }
}
