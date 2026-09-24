import Foundation
import SwiftData

enum CanvasRecentlyDeletedError: LocalizedError {
    case notRecentlyDeleted(UUID)
    case replicasDisagree(UUID)

    var errorDescription: String? {
        switch self {
        case let .notRecentlyDeleted(id):
            "The canvas \(id.uuidString) is not in Recently Deleted."
        case let .replicasDisagree(id):
            "Copies of the canvas \(id.uuidString) disagree about its deletion. Refresh and try again."
        }
    }
}

/// Recently Deleted for canvases reuses the existing tombstones: deleting a
/// canvas marks its board and the content it still showed with one shared
/// `deletedAt`. Restore reverses exactly that set; purge removes the content
/// rows and keeps a nameless board tombstone so no late replica can bring
/// the canvas back. `recentlyDeletedAt` starts the 30 days; canvases deleted
/// before this existed have none and are kept until removed by hand.
extension CanvasStore {
    func recentlyDeletedCanvases() -> [DeletedItemSummary] {
        do {
            let boards = try makeFreshContext().fetchCanvasReplicas(FetchDescriptor<CanvasBoardItem>(
                predicate: #Predicate { $0.tombstoned && $0.purgedAt == nil }
            ))
            return Dictionary(grouping: boards, by: \.id).compactMap { id, replicas -> DeletedItemSummary? in
                let winner = Self.winningBoardReplica(in: replicas)
                guard winner.tombstoned, let deletedAt = winner.deletedAt else { return nil }
                return DeletedItemSummary(
                    ref: AtticItemRef(.canvas, id),
                    title: Self.normalizedCanvasName(winner.name) ?? "Untitled Canvas",
                    deletedAt: deletedAt,
                    includedCount: 0,
                    retentionStart: winner.recentlyDeletedAt
                )
            }
            .sorted { lhs, rhs in
                lhs.deletedAt != rhs.deletedAt
                    ? lhs.deletedAt > rhs.deletedAt
                    : lhs.ref.id.uuidString < rhs.ref.id.uuidString
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return []
        }
    }

    /// Brings a canvas back with everything its delete hid, on every
    /// replica, in one save. Objects deleted earlier stay deleted. The
    /// current selection does not change.
    @discardableResult
    func restoreCanvas(_ id: UUID) -> Bool {
        do {
            let boards = try storedBoardReplicas(matching: id)
            guard !boards.isEmpty else { throw CanvasReplicaMutationError.missingCanvas(id) }
            let winner = Self.winningBoardReplica(in: boards)
            guard winner.tombstoned, winner.purgedAt == nil, let deletedAt = winner.deletedAt else {
                throw CanvasRecentlyDeletedError.notRecentlyDeleted(id)
            }
            let timestamp = now()
            let nextVersion = try Self.nextMutationVersion(
                after: boards.map(\.mutationVersion).max() ?? 0,
                objectID: id
            )
            for replica in boards {
                replica.name = winner.name
                replica.sortIndex = winner.sortIndex
                replica.formatVersion = winner.formatVersion
                replica.clearGeneration = winner.clearGeneration
                replica.tagsRaw = winner.tagsRaw
                replica.mutationVersion = nextVersion
                replica.tombstoned = false
                replica.createdAt = winner.createdAt
                replica.updatedAt = timestamp
                replica.deletedAt = nil
                replica.recentlyDeletedAt = nil
            }
            try restoreContent(canvasID: id, deletedAt: deletedAt, at: timestamp)
        } catch {
            discardPendingChanges(after: error)
            return false
        }
        return save().succeeded
    }

    private func restoreContent(canvasID: UUID, deletedAt: Date, at timestamp: Date) throws {
        let strokeGroups = Dictionary(
            grouping: try context.fetchCanvasReplicas(FetchDescriptor<CanvasStrokeItem>(
                predicate: #Predicate { $0.canvasID == canvasID }
            )),
            by: \.id
        )
        // Every replica of each id in the canvas, including a live one, takes
        // the result, so the copies agree afterwards.
        for (id, replicas) in strokeGroups {
            let winner = try Self.winningStrokeReplica(in: replicas)
            guard winner.tombstoned, winner.deletedAt == deletedAt else { continue }
            let version = try Self.nextMutationVersion(
                after: replicas.map(\.mutationVersion).max() ?? 0,
                objectID: id
            )
            for replica in replicas {
                replica.payloadVersion = winner.payloadVersion
                replica.payload = winner.payload
                replica.boardGeneration = winner.boardGeneration
                replica.mutationVersion = version
                replica.tombstoned = false
                replica.createdAt = winner.createdAt
                replica.updatedAt = timestamp
                replica.deletedAt = nil
            }
        }

        let imageGroups = Dictionary(
            grouping: try context.fetchCanvasReplicas(FetchDescriptor<CanvasImageItem>(
                predicate: #Predicate { $0.canvasID == canvasID }
            )),
            by: \.id
        )
        for (id, replicas) in imageGroups {
            let winner = try Self.winningImageReplica(in: replicas)
            guard winner.tombstoned, winner.deletedAt == deletedAt else { continue }
            let version = try Self.nextMutationVersion(
                after: replicas.map(\.mutationVersion).max() ?? 0,
                objectID: id
            )
            for replica in replicas {
                Self.copyImagePayload(from: winner, to: replica)
                replica.boardGeneration = winner.boardGeneration
                replica.mutationVersion = version
                replica.tombstoned = false
                replica.createdAt = winner.createdAt
                replica.updatedAt = timestamp
                replica.deletedAt = nil
            }
        }

        #if os(macOS)
        for rows in Dictionary(grouping: try storedSemanticReplicas(canvasID: canvasID), by: \.id).values {
            guard let winner = Self.winningSemanticReplica(rows),
                  winner.tombstoned, winner.deletedAt == deletedAt else { continue }
            let snapshot = CanvasSemanticObject(winner)
            let version = try Self.nextMutationVersion(
                after: rows.map(\.mutationVersion).max() ?? 0,
                objectID: winner.id
            )
            for row in rows {
                applySemanticSnapshot(snapshot, to: row)
                row.mutationVersion = version
                row.tombstoned = false
                row.updatedAt = timestamp
                row.deletedAt = nil
            }
        }
        #endif
    }

    /// Removes for good the canvases deleted before `cutoff`: their stroke,
    /// image and object rows are deleted, and the board rows stay as nameless
    /// tombstones marked `purgedAt`. A canvas whose board replicas disagree is
    /// kept. Returns the purged canvas ids.
    @discardableResult
    func purgeDeletedCanvases(before cutoff: Date) -> Set<UUID> {
        var purged = Set<UUID>()
        do {
            let boards = try context.fetchCanvasReplicas(FetchDescriptor<CanvasBoardItem>(
                predicate: #Predicate { $0.tombstoned && $0.purgedAt == nil }
            ))
            let timestamp = now()
            for (id, rows) in Dictionary(grouping: boards, by: \.id) {
                let replicas = try storedBoardReplicas(matching: id)
                // Only a delete made since Recently Deleted existed starts the
                // 30 days; every replica must agree on it.
                guard let first = replicas.first, let started = first.recentlyDeletedAt, started < cutoff,
                      replicas.allSatisfy({
                          $0.tombstoned && $0.purgedAt == nil
                              && $0.deletedAt == first.deletedAt && $0.recentlyDeletedAt == started
                      }),
                      replicas.count == rows.count else { continue }
                let canvasID = id
                try context.fetchCanvasReplicas(FetchDescriptor<CanvasStrokeItem>(
                    predicate: #Predicate { $0.canvasID == canvasID }
                )).forEach(context.delete)
                try context.fetchCanvasReplicas(FetchDescriptor<CanvasImageItem>(
                    predicate: #Predicate { $0.canvasID == canvasID }
                )).forEach(context.delete)
                #if os(macOS)
                try storedSemanticReplicas(canvasID: canvasID).forEach(context.delete)
                #endif
                for replica in replicas {
                    replica.name = ""
                    replica.tagsRaw = ""
                    replica.purgedAt = timestamp
                    replica.updatedAt = timestamp
                }
                purged.insert(id)
            }
        } catch {
            discardPendingChanges(after: error)
            return []
        }
        guard !purged.isEmpty else { return [] }
        return save().succeeded ? purged : []
    }

    /// Sets a live canvas's tags on every board replica.
    @discardableResult
    func setTags(_ tags: [String], forCanvas id: UUID) -> Bool {
        guard canvases.contains(where: { $0.id == id }) else {
            lastErrorMessage = CanvasReplicaMutationError.missingCanvas(id).localizedDescription
            return false
        }
        let encoded = AtticTag.encode(tags)
        do {
            let replicas = try storedBoardReplicas(matching: id)
            guard !replicas.isEmpty else { throw CanvasReplicaMutationError.missingCanvas(id) }
            guard replicas.contains(where: { $0.tagsRaw != encoded }) else { return true }
            let winner = Self.winningBoardReplica(in: replicas)
            let nextVersion = try Self.nextMutationVersion(
                after: replicas.map(\.mutationVersion).max() ?? 0,
                objectID: id
            )
            let timestamp = now()
            for replica in replicas {
                replica.name = winner.name
                replica.sortIndex = winner.sortIndex
                replica.clearGeneration = winner.clearGeneration
                replica.tombstoned = winner.tombstoned
                replica.deletedAt = winner.deletedAt
                replica.createdAt = winner.createdAt
                replica.tagsRaw = encoded
                replica.mutationVersion = nextVersion
                replica.updatedAt = timestamp
            }
        } catch {
            discardPendingChanges(after: error)
            return false
        }
        return save().succeeded
    }
}
