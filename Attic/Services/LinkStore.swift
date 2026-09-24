import Foundation
import SwiftData

/// A link as presented: one per link id, whatever the replicas.
struct ItemLinkRecord: Equatable, Sendable {
    let id: UUID
    let source: AtticItemRef
    let target: AtticItemRef
    let kind: ItemLinkKind
    let createdAt: Date
}

/// Whether an endpoint of a link can be shown right now.
enum LinkEndpointState: Equatable {
    case live
    /// In Recently Deleted: the link is kept (the card's text keeps the id),
    /// so a restore relinks it without touching the link.
    case deleted
    /// Unknown to this store (not synced yet, or purged).
    case missing
}

enum LinkStoreError: LocalizedError {
    case unavailableEndpoint(AtticItemRef)
    case selfLink
    case missingLink(UUID)

    var errorDescription: String? {
        switch self {
        case let .unavailableEndpoint(ref):
            "No \(ref.kind.rawValue) exists with id \(ref.id.uuidString)."
        case .selfLink:
            "An item cannot link to itself."
        case let .missingLink(id):
            "No link exists with id \(id.uuidString)."
        }
    }
}

/// One link model between any task, note and canvas: a card in a note, a
/// canvas attached to a task, or a plain reference. Links are directed
/// (source → target) and duplicate-safe: several links between the same pair
/// are allowed (a note can hold two cards for one task; a canvas can be
/// attached to any number of tasks), duplicate replicas of one link id are
/// deduplicated for presentation only, and every change applies to all of
/// them. Soft-deleting an item keeps its links; purging it removes them.
@MainActor
final class LinkStore {
    private let container: ModelContainer
    private let now: () -> Date
    private let persist: (ModelContext) throws -> Void
    /// Answers whether an item exists and is live; supplied by the library,
    /// which knows every item store.
    var endpointState: (AtticItemRef) -> LinkEndpointState
    private(set) var lastErrorMessage: String?
    /// Bumped after every successful save.
    private(set) var revision: UInt64 = 0

    init(
        container: ModelContainer,
        now: @escaping () -> Date = Date.init,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
        endpointState: @escaping (AtticItemRef) -> LinkEndpointState = { _ in .live }
    ) {
        self.container = container
        self.now = now
        self.persist = persist
        self.endpointState = endpointState
    }

    /// Links `source` to `target`. Both must be live items. Returns the new
    /// link, or nil after recording why nothing changed.
    @discardableResult
    func link(_ source: AtticItemRef, to target: AtticItemRef, kind: ItemLinkKind) -> ItemLinkRecord? {
        guard source != target else { return fail(LinkStoreError.selfLink) }
        for endpoint in [source, target] where endpointState(endpoint) != .live {
            return fail(LinkStoreError.unavailableEndpoint(endpoint))
        }
        let context = ModelContext(container)
        let link = ItemLink(source: source, target: target, kind: kind, createdAt: now())
        context.insert(link)
        guard save(context) else { return nil }
        return ItemLinkRecord(id: link.id, source: source, target: target, kind: kind, createdAt: link.createdAt)
    }

    /// Removes a link softly (a card deleted from a note), on every replica.
    @discardableResult
    func unlink(_ linkID: UUID) -> Bool {
        setDeleted(true, linkID: linkID)
    }

    /// Brings back a softly removed link, on every replica.
    @discardableResult
    func restoreLink(_ linkID: UUID) -> Bool {
        setDeleted(false, linkID: linkID)
    }

    /// Links that start at `item`. By default only links whose other end can
    /// be shown; pass `includingUnavailableEndpoints` to see links to items in
    /// Recently Deleted too.
    func links(from item: AtticItemRef, includingUnavailableEndpoints: Bool = false) -> [ItemLinkRecord] {
        let id = item.id
        let kindRaw = item.kind.rawValue
        return records(FetchDescriptor<ItemLink>(predicate: #Predicate {
            $0.sourceID == id && $0.sourceKindRaw == kindRaw && $0.deletedAt == nil
        }), otherEnd: \.target, includingUnavailable: includingUnavailableEndpoints)
    }

    /// Backlinks: links that point at `item` ("Linked from").
    func backlinks(to item: AtticItemRef, includingUnavailableEndpoints: Bool = false) -> [ItemLinkRecord] {
        let id = item.id
        let kindRaw = item.kind.rawValue
        return records(FetchDescriptor<ItemLink>(predicate: #Predicate {
            $0.targetID == id && $0.targetKindRaw == kindRaw && $0.deletedAt == nil
        }), otherEnd: \.source, includingUnavailable: includingUnavailableEndpoints)
    }

    /// Hard-deletes every link that touches one of `itemIDs` (items purged
    /// for good), on every replica. Returns how many link ids were removed.
    @discardableResult
    func purgeLinks(touching itemIDs: Set<UUID>) -> Int {
        guard !itemIDs.isEmpty else { return 0 }
        let context = ModelContext(container)
        let ids = Array(itemIDs)
        do {
            let rows = try context.fetch(FetchDescriptor<ItemLink>(predicate: #Predicate {
                ids.contains($0.sourceID) || ids.contains($0.targetID)
            }))
            guard !rows.isEmpty else { return 0 }
            let removed = Set(rows.map(\.id))
            rows.forEach(context.delete)
            return save(context) ? removed.count : 0
        } catch {
            lastErrorMessage = error.localizedDescription
            return 0
        }
    }

    /// Hard-deletes links removed softly before `cutoff`, when every replica
    /// of the link agrees it is removed.
    @discardableResult
    func purgeRemovedLinks(before cutoff: Date) -> Int {
        let context = ModelContext(container)
        do {
            let removedRows = try context.fetch(FetchDescriptor<ItemLink>(predicate: #Predicate {
                $0.deletedAt != nil
            }))
            let candidateIDs = Array(Set(removedRows.filter { ($0.deletedAt ?? .distantFuture) < cutoff }.map(\.id)))
            guard !candidateIDs.isEmpty else { return 0 }
            let all = try context.fetch(FetchDescriptor<ItemLink>(predicate: #Predicate {
                candidateIDs.contains($0.id)
            }))
            var removed = 0
            for replicas in Dictionary(grouping: all, by: \.id).values {
                guard replicas.allSatisfy({ ($0.deletedAt ?? .distantFuture) < cutoff }) else { continue }
                replicas.forEach(context.delete)
                removed += 1
            }
            guard removed > 0 else { return 0 }
            return save(context) ? removed : 0
        } catch {
            lastErrorMessage = error.localizedDescription
            return 0
        }
    }

    // MARK: - Private

    private func setDeleted(_ deleted: Bool, linkID: UUID) -> Bool {
        let context = ModelContext(container)
        do {
            let replicas = try context.fetch(FetchDescriptor<ItemLink>(predicate: #Predicate { $0.id == linkID }))
            guard !replicas.isEmpty else { throw LinkStoreError.missingLink(linkID) }
            let timestamp = now()
            for replica in replicas {
                replica.deletedAt = deleted ? timestamp : nil
                replica.updatedAt = timestamp
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        return save(context)
    }

    private func records(
        _ descriptor: FetchDescriptor<ItemLink>,
        otherEnd: KeyPath<ItemLinkRecord, AtticItemRef>,
        includingUnavailable: Bool
    ) -> [ItemLinkRecord] {
        do {
            let rows = try ModelContext(container).fetch(descriptor)
            var newestByID: [UUID: ItemLink] = [:]
            for row in rows {
                if let existing = newestByID[row.id],
                   existing.updatedAt > row.updatedAt
                    || (existing.updatedAt == row.updatedAt
                        && String(reflecting: existing.persistentModelID) >= String(reflecting: row.persistentModelID)) {
                    continue
                }
                newestByID[row.id] = row
            }
            return newestByID.values
                .compactMap { row -> ItemLinkRecord? in
                    guard row.deletedAt == nil, let source = row.source, let target = row.target,
                          let kind = row.kind else { return nil }
                    return ItemLinkRecord(id: row.id, source: source, target: target, kind: kind, createdAt: row.createdAt)
                }
                .filter { includingUnavailable || endpointState($0[keyPath: otherEnd]) == .live }
                .sorted { lhs, rhs in
                    lhs.createdAt != rhs.createdAt
                        ? lhs.createdAt < rhs.createdAt
                        : lhs.id.uuidString < rhs.id.uuidString
                }
        } catch {
            lastErrorMessage = error.localizedDescription
            return []
        }
    }

    private func save(_ context: ModelContext) -> Bool {
        do {
            try persist(context)
            lastErrorMessage = nil
            revision &+= 1
            return true
        } catch {
            context.rollback()
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    private func fail<T>(_ error: Error) -> T? {
        lastErrorMessage = error.localizedDescription
        return nil
    }
}
