import Foundation
import SwiftData

/// Membership queries carry expected absence too. Tokenizing only known IDs
/// cannot detect a new sibling or association arriving during preparation.
enum WorkspaceScope: Codable, Hashable, Sendable {
    case children(UUID), attachments(UUID), versions(UUID), proposals(UUID)
    case taskAssociations(UUID), noteAssociations(UUID), preservations(UUID)
}
struct WorkspaceScopeToken: Codable, Equatable, Sendable {
    let scope: WorkspaceScope
    let members: [WorkspaceModelToken]

    @MainActor static func read(_ scope: WorkspaceScope, in context: ModelContext) throws -> Self {
        var owners = Set<WorkspaceOwner>()
        func collect<M: PersistentModel>(_ rows: [M]) throws {
            for row in rows {
                guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.unknown }
                owners.insert(owner)
            }
        }
        switch scope {
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
