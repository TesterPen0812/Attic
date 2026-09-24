import Foundation

/// The three kinds of top-level item a person (or an agent) works with. Raw
/// values are stable storage and wire names: they are persisted in links and
/// used by the MCP tools.
enum AtticItemKind: String, Codable, CaseIterable, Sendable {
    case task
    case note
    case canvas
}

/// A reference to one logical item by application identity. It never refers
/// to a physical replica: every operation on it applies to all replicas.
struct AtticItemRef: Hashable, Codable, Sendable {
    let kind: AtticItemKind
    let id: UUID

    init(_ kind: AtticItemKind, _ id: UUID) {
        self.kind = kind
        self.id = id
    }
}

/// Recently Deleted keeps an item restorable for this long; the daily
/// cleanup removes it for good afterwards.
enum RecentlyDeletedPolicy {
    static let retentionDays = 30

    /// Items deleted strictly before this instant are due for removal.
    static func purgeCutoff(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -retentionDays, to: now)
            ?? now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
    }

    static func expiry(deletedAt: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: retentionDays, to: deletedAt)
            ?? deletedAt.addingTimeInterval(Double(retentionDays) * 24 * 60 * 60)
    }
}

/// One entry of Recently Deleted: the item a single delete hid, with what it
/// took along (a task's subtasks, a note's attachments).
struct DeletedItemSummary: Equatable, Sendable {
    let ref: AtticItemRef
    let title: String
    let deletedAt: Date
    /// Rows or objects that come back with it (subtasks, attachments).
    let includedCount: Int
    /// When its 30 days started; nil when it is never removed automatically
    /// (a canvas deleted before Recently Deleted existed).
    let retentionStart: Date?

    init(ref: AtticItemRef, title: String, deletedAt: Date, includedCount: Int, retentionStart: Date?) {
        self.ref = ref
        self.title = title
        self.deletedAt = deletedAt
        self.includedCount = includedCount
        self.retentionStart = retentionStart
    }

    func expiresAt(calendar: Calendar) -> Date? {
        retentionStart.map { RecentlyDeletedPolicy.expiry(deletedAt: $0, calendar: calendar) }
    }
}

/// One attachment removed on its own (a task file or a note attachment),
/// restorable from Recently Deleted for 30 days.
struct DeletedAttachmentSummary: Equatable, Sendable {
    let attachmentID: UUID
    /// The task or note it belongs to.
    let owner: AtticItemRef
    let filename: String
    let deletedAt: Date
}
