import Foundation
import SwiftData

enum CanvasRecentlyDeletedError: LocalizedError {
    case notRecentlyDeleted(UUID)
    case replicasDisagree(UUID)
    case metadataDisagrees(UUID)
    case incompleteRestore(UUID)

    var errorDescription: String? {
        switch self {
        case let .notRecentlyDeleted(id):
            "The canvas \(id.uuidString) is not in Recently Deleted."
        case let .replicasDisagree(id):
            "Copies of the canvas \(id.uuidString) disagree about its deletion. Refresh and try again."
        case let .metadataDisagrees(id):
            "Copies of the canvas \(id.uuidString) disagree about its name, tags or order. Refresh and try again."
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
            // the restore incomplete, so nothing is written. The copies must
            // also agree on everything the restore does not change (name,
            // tags, ordering, format, clear generation, creation): restoring
            // clears only the deletion, and two copies that disagree about
            // what the canvas is would come back side by side with one of
            // them shown, so they are refused until they agree.
            guard boards.allSatisfy({
                $0.tombstoned && $0.purgedAt == nil && $0.deletedAt == deletedAt
                    && $0.recentlyDeletedAt == winner.recentlyDeletedAt
                    && $0.deletedContentCount == winner.deletedContentCount
            }) else {
                throw CanvasRecentlyDeletedError.replicasDisagree(id)
            }
            let metadata = Self.boardMetadata(winner)
            guard boards.allSatisfy({ Self.boardMetadata($0) == metadata }) else {
                throw CanvasRecentlyDeletedError.metadataDisagrees(id)
            }
            // Every replica of each object this restore brings back must hold
            // the same content: restoring copies the winner over its peers,
            // which would erase a copy that differs. Checked before anything
            // is written.
            guard try restoredContentAgrees(canvasID: id, deletedAt: deletedAt) else {
                throw CanvasRecentlyDeletedError.replicasDisagree(id)
            }
            // Read before the loop below clears it on every replica.
            let recordedContent = winner.deletedContentCount
            let timestamp = now()
            let nextVersion = try Self.nextMutationVersion(
                after: boards.map(\.mutationVersion).max() ?? 0,
                objectID: id
            )
            // Only the deletion is cleared; the metadata already agrees.
            for replica in boards {
                replica.mutationVersion = nextVersion
                replica.tombstoned = false
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

    /// True when, for every stroke, image and object the delete at
    /// `deletedAt` hid, all replicas hold the same content (image bytes are
    /// read and compared, not their stored digest).
    private func restoredContentAgrees(canvasID: UUID, deletedAt: Date) throws -> Bool {
        func agree<Row>(_ groups: [[Row]], restored: (Row) -> Bool, content: (Row) -> [AnyHashable]) -> Bool {
            groups.allSatisfy { group in
                guard group.count > 1, group.contains(where: restored) else { return true }
                let first = content(group[0])
                return group.dropFirst().allSatisfy { content($0) == first }
            }
        }
        let strokes = Dictionary(grouping: try context.fetchCanvasReplicas(FetchDescriptor<CanvasStrokeItem>(
            predicate: #Predicate { $0.canvasID == canvasID }
        )), by: \.id).values
        let strokeWinners = try Set(strokes.map { try Self.winningStrokeReplica(in: $0) }.filter {
            $0.tombstoned && $0.deletedAt == deletedAt
        }.map(\.id))
        guard agree(Array(strokes), restored: { strokeWinners.contains($0.id) }, content: Self.strokeContent) else {
            return false
        }
        let images = Dictionary(grouping: try context.fetchCanvasReplicas(FetchDescriptor<CanvasImageItem>(
            predicate: #Predicate { $0.canvasID == canvasID }
        )), by: \.id).values
        let imageWinners = try Set(images.map { try Self.winningImageReplica(in: $0) }.filter {
            $0.tombstoned && $0.deletedAt == deletedAt
        }.map(\.id))
        guard agree(Array(images), restored: { imageWinners.contains($0.id) }, content: Self.imageContent) else {
            return false
        }
        #if os(macOS)
        let objects = Dictionary(grouping: try storedSemanticReplicas(canvasID: canvasID), by: \.id).values
        let objectWinners = Set(objects.compactMap { Self.winningSemanticReplica($0) }.filter {
            $0.tombstoned && $0.deletedAt == deletedAt
        }.map(\.id))
        guard agree(Array(objects), restored: { objectWinners.contains($0.id) }, content: Self.semanticContent) else {
            return false
        }
        #endif
        return true
    }

    /// What a stroke replica holds, apart from versioning and deletion.
    private static func strokeContent(_ row: CanvasStrokeItem) -> [AnyHashable] {
        [row.payloadVersion, row.payload, row.boardGeneration]
    }

    /// What an image replica holds. The bytes themselves are read, so a
    /// stored size or digest that no longer matches them can't hide a
    /// difference.
    private static func imageContent(_ row: CanvasImageItem) -> [AnyHashable] {
        [row.materialisedPayload, row.contentType, row.pixelWidth, row.pixelHeight, row.centerX, row.centerY,
         row.width, row.height, row.zIndex, row.boardGeneration]
    }

    private static func semanticContent(_ row: CanvasSemanticObjectItem) -> [AnyHashable] {
        [row.kind, row.payloadVersion, row.payload, row.centerX, row.centerY, row.width, row.height,
         row.rotation, row.zIndex, row.boardGeneration]
    }

    /// Content plus versioning and deletion: two replicas a purge may remove
    /// together are identical in all of it.
    private static func versioned(_ content: [AnyHashable], _ version: Int64, _ tombstoned: Bool,
                                  _ createdAt: Date, _ updatedAt: Date, _ deletedAt: Date?) -> [AnyHashable] {
        content + [version, tombstoned, createdAt, updatedAt, deletedAt]
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
    /// first saw it. Returns the purged canvas ids. `alongside` stages
    /// dependent removals (their links) in the same context, so they are
    /// saved with the purge or not at all; if it throws, nothing is purged.
    ///
    /// `confirmed` (emptying Recently Deleted by hand) limits the purge to
    /// the canvases the person was shown, each with the deletion time it had
    /// then, and removes a canvas deleted before Recently Deleted existed
    /// too instead of stamping it.
    @discardableResult
    func purgeDeletedCanvases(
        before cutoff: Date,
        confirmed: [UUID: Date]? = nil,
        alongside: ((ModelContext, Set<UUID>) throws -> Void)? = nil
    ) -> Set<UUID> {
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
                if let confirmed, confirmed[id] != Self.winningBoardReplica(in: replicas).deletedAt { continue }
                let unstamped = replicas.allSatisfy { $0.tombstoned && $0.purgedAt == nil && $0.recentlyDeletedAt == nil }
                if unstamped, confirmed == nil {
                    for replica in replicas { replica.recentlyDeletedAt = timestamp }
                    stamped = true
                    continue
                }
                guard let started = unstamped ? first.deletedAt : first.recentlyDeletedAt, started < cutoff,
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
            if !purged.isEmpty { try alongside?(context, purged) }
        } catch {
            discardPendingChanges(after: error)
            return []
        }
        guard !purged.isEmpty || stamped else { return [] }
        return save().succeeded ? purged : []
    }

    /// Every content row of the canvas is deleted, and the replicas of each
    /// object are identical: same deletion, same version and the same
    /// content, image bytes included. Two copies that agree on version and deletion time but hold
    /// different strokes, image bytes or object payloads are a conflict no
    /// one has seen yet, so the whole canvas waits.
    private func contentIsSafeToPurge(canvasID: UUID) throws -> Bool {
        func agree<Row>(_ rows: [Row], id: (Row) -> UUID, tombstoned: (Row) -> Bool,
                        snapshot: (Row) -> [AnyHashable]) -> Bool {
            guard rows.allSatisfy(tombstoned) else { return false }
            return Dictionary(grouping: rows, by: id).values.allSatisfy { group in
                // A lone replica has nothing to disagree with (and its image
                // bytes need not be read).
                guard group.count > 1 else { return true }
                let first = snapshot(group[0])
                return group.dropFirst().allSatisfy { snapshot($0) == first }
            }
        }
        let strokes = try context.fetchCanvasReplicas(FetchDescriptor<CanvasStrokeItem>(
            predicate: #Predicate { $0.canvasID == canvasID }
        ))
        guard agree(strokes, id: \.id, tombstoned: \.tombstoned, snapshot: {
            Self.versioned(Self.strokeContent($0), $0.mutationVersion, $0.tombstoned, $0.createdAt, $0.updatedAt,
                           $0.deletedAt)
        }) else {
            return false
        }
        let images = try context.fetchCanvasReplicas(FetchDescriptor<CanvasImageItem>(
            predicate: #Predicate { $0.canvasID == canvasID }
        ))
        // The bytes are read and compared: a stored size or digest can be
        // stale, and trusting it could purge two different images.
        guard agree(images, id: \.id, tombstoned: \.tombstoned, snapshot: {
            Self.versioned(Self.imageContent($0), $0.mutationVersion, $0.tombstoned, $0.createdAt, $0.updatedAt,
                           $0.deletedAt)
        }) else {
            return false
        }
        #if os(macOS)
        let objects = try storedSemanticReplicas(canvasID: canvasID)
        guard agree(objects, id: \.id, tombstoned: \.tombstoned, snapshot: {
            Self.versioned(Self.semanticContent($0), $0.mutationVersion, $0.tombstoned, $0.createdAt, $0.updatedAt,
                           $0.deletedAt)
        }) else {
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

    /// What a board is apart from its tags, versioning and deletion state:
    /// board operations that change neither must find every replica agreeing
    /// on it before they touch any of them.
    private struct BoardMetadata: Equatable {
        let name: String
        let sortIndex: Int64
        let formatVersion: Int
        let clearGeneration: Int64
        let createdAt: Date
        let tagsRaw: String
    }

    private static func boardMetadata(_ board: CanvasBoardItem, includingTags: Bool = true) -> BoardMetadata {
        BoardMetadata(name: board.name, sortIndex: board.sortIndex, formatVersion: board.formatVersion,
                      clearGeneration: board.clearGeneration, createdAt: board.createdAt,
                      tagsRaw: includingTags ? board.tagsRaw : "")
    }

    /// Sets a live canvas's tags on every board replica, changing nothing
    /// else. The replicas must agree on everything else about the board
    /// (name, ordering, format, clear generation, creation and deletion
    /// state); copies that disagree are refused rather than one being picked,
    /// since giving them one new version would decide which copy is shown.
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
            let metadata = Self.boardMetadata(winner, includingTags: false)
            guard replicas.allSatisfy({
                Self.boardMetadata($0, includingTags: false) == metadata
                    && $0.tombstoned == winner.tombstoned && $0.deletedAt == winner.deletedAt
                    && $0.purgedAt == winner.purgedAt
            }) else {
                throw CanvasRecentlyDeletedError.metadataDisagrees(id)
            }
            let nextVersion = try Self.nextMutationVersion(
                after: replicas.map(\.mutationVersion).max() ?? 0,
                objectID: id
            )
            let timestamp = now()
            for replica in replicas {
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
