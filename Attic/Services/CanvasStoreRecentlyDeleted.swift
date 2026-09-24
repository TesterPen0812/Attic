import Foundation
import SwiftData

enum CanvasRecentlyDeletedError: LocalizedError {
    case notRecentlyDeleted(UUID)
    case replicasDisagree(UUID)
    case incompleteRestore(UUID)

    var errorDescription: String? {
        switch self {
        case let .notRecentlyDeleted(id):
            "The canvas \(id.uuidString) is not in Recently Deleted."
        case let .replicasDisagree(id):
            "Copies of the canvas \(id.uuidString) disagree about its deletion. Refresh and try again."
        case .incompleteRestore:
            "Part of this deleted canvas is no longer there, so it can’t be restored safely."
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
            // Every physical board replica must be this same delete; a copy
            // already purged (its content gone) or deleted differently makes
            // the restore incomplete, so nothing is written.
            guard boards.allSatisfy({
                $0.tombstoned && $0.purgedAt == nil && $0.deletedAt == deletedAt
                    && $0.recentlyDeletedAt == winner.recentlyDeletedAt
                    && $0.deletedContentCount == winner.deletedContentCount
            }) else {
                throw CanvasRecentlyDeletedError.replicasDisagree(id)
            }
            // Read before the loop below clears it on every replica.
            let recordedContent = winner.deletedContentCount
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
                replica.deletedContentCount = nil
            }
            let restored = try restoreContent(canvasID: id, deletedAt: deletedAt, at: timestamp)
            if let recordedContent, Int64(restored) != recordedContent {
                throw CanvasRecentlyDeletedError.incompleteRestore(id)
            }
        } catch {
            discardPendingChanges(after: error)
            return false
        }
        return save().succeeded
    }

    /// Returns how many objects it brought back.
    private func restoreContent(canvasID: UUID, deletedAt: Date, at timestamp: Date) throws -> Int {
        var restored = 0
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
            restored += 1
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
            restored += 1
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
            restored += 1
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
        return restored
    }

    /// Removes for good the canvases whose 30 days started before `cutoff`:
    /// their stroke, image and object rows are deleted, and the board rows
    /// stay as nameless tombstones marked `purgedAt`. Destructive only when
    /// everything agrees: every board replica is identical, and every content
    /// row of the canvas is deleted with its replicas agreeing. A live or
    /// divergent row anywhere defers the whole canvas.
    ///
    /// A canvas deleted before Recently Deleted existed has no start date; the
    /// first run stamps it with "now", so it is removed 30 days after the app
    /// first saw it. Returns the purged canvas ids.
    @discardableResult
    func purgeDeletedCanvases(before cutoff: Date) -> Set<UUID> {
        var purged = Set<UUID>()
        var stamped = false
        do {
            let boards = try context.fetchCanvasReplicas(FetchDescriptor<CanvasBoardItem>(
                predicate: #Predicate { $0.tombstoned && $0.purgedAt == nil }
            ))
            let timestamp = now()
            for id in Set(boards.map(\.id)) {
                let replicas = try storedBoardReplicas(matching: id)
                guard let first = replicas.first else { continue }
                if replicas.allSatisfy({ $0.tombstoned && $0.purgedAt == nil && $0.recentlyDeletedAt == nil }) {
                    for replica in replicas { replica.recentlyDeletedAt = timestamp }
                    stamped = true
                    continue
                }
                guard let started = first.recentlyDeletedAt, started < cutoff,
                      replicas.allSatisfy({ Self.boardDeletionSnapshot($0) == Self.boardDeletionSnapshot(first) }),
                      try contentIsSafeToPurge(canvasID: id) else { continue }
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
        guard !purged.isEmpty || stamped else { return [] }
        return save().succeeded ? purged : []
    }

    /// Every content row of the canvas is deleted, and the replicas of each
    /// object agree on its deletion and version.
    private func contentIsSafeToPurge(canvasID: UUID) throws -> Bool {
        func agree<Row>(_ rows: [Row], id: (Row) -> UUID, tombstoned: (Row) -> Bool,
                        version: (Row) -> Int64, deletedAt: (Row) -> Date?) -> Bool {
            guard rows.allSatisfy(tombstoned) else { return false }
            return Dictionary(grouping: rows, by: id).values.allSatisfy { group in
                let first = group[0]
                return group.allSatisfy { version($0) == version(first) && deletedAt($0) == deletedAt(first) }
            }
        }
        let strokes = try context.fetchCanvasReplicas(FetchDescriptor<CanvasStrokeItem>(
            predicate: #Predicate { $0.canvasID == canvasID }
        ))
        guard agree(strokes, id: \.id, tombstoned: \.tombstoned, version: \.mutationVersion, deletedAt: \.deletedAt) else {
            return false
        }
        let images = try context.fetchCanvasReplicas(FetchDescriptor<CanvasImageItem>(
            predicate: #Predicate { $0.canvasID == canvasID }
        ))
        guard agree(images, id: \.id, tombstoned: \.tombstoned, version: \.mutationVersion, deletedAt: \.deletedAt) else {
            return false
        }
        #if os(macOS)
        let objects = try storedSemanticReplicas(canvasID: canvasID)
        guard agree(objects, id: \.id, tombstoned: \.tombstoned, version: \.mutationVersion, deletedAt: \.deletedAt) else {
            return false
        }
        #endif
        return true
    }

    private struct BoardDeletionSnapshot: Equatable {
        let name: String
        let sortIndex: Int64
        let formatVersion: Int
        let clearGeneration: Int64
        let mutationVersion: Int64
        let tombstoned: Bool
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
        let tagsRaw: String
        let purgedAt: Date?
        let recentlyDeletedAt: Date?
        let deletedContentCount: Int64?
    }

    private static func boardDeletionSnapshot(_ board: CanvasBoardItem) -> BoardDeletionSnapshot {
        BoardDeletionSnapshot(
            name: board.name, sortIndex: board.sortIndex, formatVersion: board.formatVersion,
            clearGeneration: board.clearGeneration, mutationVersion: board.mutationVersion,
            tombstoned: board.tombstoned, createdAt: board.createdAt, updatedAt: board.updatedAt,
            deletedAt: board.deletedAt, tagsRaw: board.tagsRaw, purgedAt: board.purgedAt,
            recentlyDeletedAt: board.recentlyDeletedAt, deletedContentCount: board.deletedContentCount
        )
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
