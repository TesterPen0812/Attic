import Combine
import CoreData
import Foundation
import SwiftData

extension CanvasStore {
    @discardableResult
    func addStroke(
        color: CanvasInkColor,
        width: Double,
        points: [CanvasPoint],
        id: UUID = UUID()
    ) -> CanvasStroke? {
        let payload: Data
        do {
            payload = try CanvasStrokeCodec.encode(
                color: color,
                width: width,
                points: points
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }

        let timestamp = now()
        do {
            try ensureSelectedBoardReplicaExists(at: timestamp)
            let replicas = try storedStrokeReplicas(matching: [id])[id] ?? []
            if replicas.isEmpty {
                context.insert(CanvasStrokeItem(
                    id: id,
                    canvasID: selectedCanvasID,
                    payloadVersion: CanvasStrokeCodec.currentVersion,
                    payload: payload,
                    boardGeneration: boardGeneration,
                    mutationVersion: 1,
                    tombstoned: false,
                    createdAt: timestamp,
                    updatedAt: timestamp
                ))
            } else {
                let winner = try Self.winningStrokeReplica(in: replicas)
                let nextVersion = try Self.nextMutationVersion(
                    after: replicas.map(\.mutationVersion).max() ?? 0,
                    objectID: id
                )
                for replica in replicas {
                    replica.canvasID = selectedCanvasID
                    replica.payloadVersion = CanvasStrokeCodec.currentVersion
                    replica.payload = payload
                    replica.boardGeneration = boardGeneration
                    replica.mutationVersion = nextVersion
                    replica.tombstoned = false
                    replica.createdAt = winner.createdAt
                    replica.updatedAt = timestamp
                    replica.deletedAt = nil
                }
            }
        } catch {
            discardPendingChanges(after: error)
            return nil
        }

        guard save() else { return nil }
        return strokes.first { $0.id == id }
    }

    @discardableResult
    func setDeleted(
        _ deleted: Bool,
        strokeIDs: Set<UUID>
    ) -> Bool {
        guard !strokeIDs.isEmpty else { return true }

        let grouped: [UUID: [CanvasStrokeItem]]
        do {
            grouped = try storedStrokeReplicas(matching: strokeIDs)
            for id in strokeIDs where grouped[id]?.isEmpty != false {
                throw CanvasReplicaMutationError.missingStroke(id)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }

        let timestamp = now()
        do {
            for id in strokeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                let replicas = grouped[id] ?? []
                let winner = try Self.winningStrokeReplica(in: replicas)
                let nextVersion = try Self.nextMutationVersion(
                    after: replicas.map(\.mutationVersion).max() ?? 0,
                    objectID: id
                )
                for replica in replicas {
                    replica.canvasID = selectedCanvasID
                    replica.payloadVersion = winner.payloadVersion
                    replica.payload = winner.payload
                    replica.boardGeneration = deleted
                        ? winner.boardGeneration
                        : boardGeneration
                    replica.mutationVersion = nextVersion
                    replica.tombstoned = deleted
                    replica.createdAt = winner.createdAt
                    replica.updatedAt = timestamp
                    replica.deletedAt = deleted ? timestamp : nil
                }
            }
        } catch {
            discardPendingChanges(after: error)
            return false
        }

        return save()
    }

    @discardableResult
    func restore(_ snapshots: [CanvasStroke]) -> Bool {
        guard !snapshots.isEmpty else { return true }
        let uniqueSnapshots = Dictionary(
            snapshots.map { ($0.id, $0) },
            uniquingKeysWith: { existing, candidate in
                Self.preferredStrokeSnapshot(candidate, over: existing)
                    ? candidate
                    : existing
            }
        )
        let ids = Set(uniqueSnapshots.keys)

        do {
            let timestamp = now()
            try ensureSelectedBoardReplicaExists(at: timestamp)
            let grouped = try storedStrokeReplicas(matching: ids)
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let snapshot = uniqueSnapshots[id] else { continue }
                let payload = try CanvasStrokeCodec.encode(
                    color: snapshot.color,
                    width: snapshot.width,
                    points: snapshot.points
                )
                let replicas = grouped[id] ?? []
                let baseline = max(
                    replicas.map(\.mutationVersion).max() ?? 0,
                    snapshot.mutationVersion
                )
                let nextVersion = try Self.nextMutationVersion(
                    after: baseline,
                    objectID: id
                )
                if replicas.isEmpty {
                    context.insert(CanvasStrokeItem(
                        id: id,
                        canvasID: selectedCanvasID,
                        payloadVersion: CanvasStrokeCodec.currentVersion,
                        payload: payload,
                        boardGeneration: boardGeneration,
                        mutationVersion: nextVersion,
                        tombstoned: false,
                        createdAt: snapshot.createdAt,
                        updatedAt: timestamp
                    ))
                } else {
                    for replica in replicas {
                        replica.canvasID = selectedCanvasID
                        replica.payloadVersion = CanvasStrokeCodec.currentVersion
                        replica.payload = payload
                        replica.boardGeneration = boardGeneration
                        replica.mutationVersion = nextVersion
                        replica.tombstoned = false
                        replica.createdAt = snapshot.createdAt
                        replica.updatedAt = timestamp
                        replica.deletedAt = nil
                    }
                }
            }
        } catch {
            discardPendingChanges(after: error)
            return false
        }
        return save()
    }

}
