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
            $0.sourceID == id && $0.sourceKindRaw == kindRaw
        }), anchoredAt: \.source, item: item, otherEnd: \.target, includingUnavailable: includingUnavailableEndpoints)
    }

    /// Backlinks: links that point at `item` ("Linked from").
    func backlinks(to item: AtticItemRef, includingUnavailableEndpoints: Bool = false) -> [ItemLinkRecord] {
        let id = item.id
        let kindRaw = item.kind.rawValue
        return records(FetchDescriptor<ItemLink>(predicate: #Predicate {
            $0.targetID == id && $0.targetKindRaw == kindRaw
        }), anchoredAt: \.target, item: item, otherEnd: \.source, includingUnavailable: includingUnavailableEndpoints)
    }

    /// Hard-deletes every link that touches one of `items` (items purged for
    /// good). An item is its kind and its id: a note that happens to share a
    /// purged task's UUID keeps its links. All replicas of a link id go
    /// together, and a link whose replicas disagree about its ends or kind is
    /// kept. Returns how many link ids were removed.
    @discardableResult
    func purgeLinks(touching items: Set<AtticItemRef>) -> Int {
        guard !items.isEmpty else { return 0 }
        let context = ModelContext(container)
        do {
            let removed = try stagePurge(touching: items, in: context)
            guard removed > 0 else { return 0 }
            return save(context) ? removed : 0
        } catch {
            lastErrorMessage = error.localizedDescription
            return 0
        }
    }

    /// The same removal as `purgeLinks(touching:)`, staged in `context`
    /// without saving: an item store passes its own context, so the item
    /// rows and their links are removed by one save, or neither is. A failed
    /// save therefore leaves both for the next cleanup, and no link outlives
    /// the item it points at. Returns how many link ids it staged.
    func stagePurge(touching items: Set<AtticItemRef>, in context: ModelContext) throws -> Int {
        guard !items.isEmpty else { return 0 }
        let ids = Array(Set(items.map(\.id)))
        let candidates = try context.fetch(FetchDescriptor<ItemLink>(predicate: #Predicate {
            ids.contains($0.sourceID) || ids.contains($0.targetID)
        }))
        let linkIDs = Array(Set(candidates.filter { row in
            (row.source.map(items.contains) ?? false) || (row.target.map(items.contains) ?? false)
        }.map(\.id)))
        guard !linkIDs.isEmpty else { return 0 }
        let replicas = try context.fetch(FetchDescriptor<ItemLink>(predicate: #Predicate {
            linkIDs.contains($0.id)
        }))
        var removed = 0
        for group in Dictionary(grouping: replicas, by: \.id).values {
            let ends = Self.ends(of: group[0])
            guard group.allSatisfy({ Self.ends(of: $0) == ends }) else { continue }
            group.forEach(context.delete)
            removed += 1
        }
        return removed
    }

    /// Records that another store's save committed a staged purge.
    func stagedPurgeWasSaved() {
        revision &+= 1
    }

    /// Hard-deletes links removed softly before `cutoff`, when every replica
    /// of the link is identical (same ends, kind and removal).
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
                let snapshot = Self.snapshot(of: replicas[0])
                guard replicas.allSatisfy({ ($0.deletedAt ?? .distantFuture) < cutoff && Self.snapshot(of: $0) == snapshot }) else {
                    continue
                }
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

    private struct LinkEnds: Equatable {
        let sourceKind: String
        let sourceID: UUID
        let targetKind: String
        let targetID: UUID
        let kind: String
    }

    private static func ends(of link: ItemLink) -> LinkEnds {
        LinkEnds(sourceKind: link.sourceKindRaw, sourceID: link.sourceID,
                 targetKind: link.targetKindRaw, targetID: link.targetID, kind: link.kindRaw)
    }

    private struct LinkSnapshot: Equatable {
        let ends: LinkEnds
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    private static func snapshot(of link: ItemLink) -> LinkSnapshot {
        LinkSnapshot(ends: ends(of: link), createdAt: link.createdAt, updatedAt: link.updatedAt, deletedAt: link.deletedAt)
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

    /// The links whose presented replica touches `item` at `anchor`.
    /// `candidates` finds link ids with any replica there, removed or not;
    /// every replica of those ids is then read and the newest one decides
    /// (`winningReplica`) before the removal and endpoint filters, so an
    /// older live copy never outlives a newer removal, and a copy that was
    /// retargeted elsewhere answers for itself.
    private func records(
        _ candidates: FetchDescriptor<ItemLink>,
        anchoredAt anchor: KeyPath<ItemLinkRecord, AtticItemRef>,
        item: AtticItemRef,
        otherEnd: KeyPath<ItemLinkRecord, AtticItemRef>,
        includingUnavailable: Bool
    ) -> [ItemLinkRecord] {
        do {
            let context = ModelContext(container)
            let ids = Array(Set(try context.fetch(candidates).map(\.id)))
            guard !ids.isEmpty else { return [] }
            let rows = try context.fetch(FetchDescriptor<ItemLink>(predicate: #Predicate { ids.contains($0.id) }))
            return Dictionary(grouping: rows, by: \.id).values
                .compactMap { replicas -> ItemLinkRecord? in
                    let row = Self.winningReplica(in: replicas)
                    guard row.deletedAt == nil, let source = row.source, let target = row.target,
                          let kind = row.kind else { return nil }
                    let record = ItemLinkRecord(id: row.id, source: source, target: target, kind: kind,
                                                createdAt: row.createdAt)
                    return record[keyPath: anchor] == item ? record : nil
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

    /// The replica presentation shows: newest `updatedAt`, then the larger
    /// persistent identifier, deterministically.
    private static func winningReplica(in replicas: [ItemLink]) -> ItemLink {
        var winner = replicas[0]
        for row in replicas.dropFirst() {
            if row.updatedAt > winner.updatedAt
                || (row.updatedAt == winner.updatedAt
                    && String(reflecting: row.persistentModelID) > String(reflecting: winner.persistentModelID)) {
                winner = row
            }
        }
        return winner
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
