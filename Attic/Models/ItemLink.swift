import Foundation
import SwiftData

/// What a link is for. Raw values are persisted and used on the wire.
enum ItemLinkKind: String, Codable, CaseIterable, Sendable {
    /// A task card (or item card) shown inside a note or task page.
    case card
    /// A canvas (or file-like item) attached to a task.
    case attachment
    /// A plain reference between two items.
    case reference
}

/// One directed link between any two tasks, notes or canvases.
///
/// Sync-ready like every model: defaults on every attribute, no uniqueness
/// constraint and the UUID as app-level identity. Duplicate replicas of one
/// link id are resolved for presentation only; changes apply to all of them.
/// Links survive when either end is soft-deleted, so restoring that item
/// relinks it; purging the item removes its links.
@Model
final class ItemLink {
    var id: UUID = UUID()
    var sourceKindRaw: String = AtticItemKind.task.rawValue
    var sourceID: UUID = UUID()
    var targetKindRaw: String = AtticItemKind.task.rawValue
    var targetID: UUID = UUID()
    var kindRaw: String = ItemLinkKind.reference.rawValue
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Soft deletion of the link itself (a card removed from a note).
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        source: AtticItemRef,
        target: AtticItemRef,
        kind: ItemLinkKind,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        sourceKindRaw = source.kind.rawValue
        sourceID = source.id
        targetKindRaw = target.kind.rawValue
        targetID = target.id
        kindRaw = kind.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }

    /// nil when a replica carries a kind this version does not know.
    var source: AtticItemRef? {
        AtticItemKind(rawValue: sourceKindRaw).map { AtticItemRef($0, sourceID) }
    }

    var target: AtticItemRef? {
        AtticItemKind(rawValue: targetKindRaw).map { AtticItemRef($0, targetID) }
    }

    var kind: ItemLinkKind? { ItemLinkKind(rawValue: kindRaw) }
}
