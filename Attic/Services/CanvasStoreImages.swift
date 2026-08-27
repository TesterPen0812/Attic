import Combine
import CoreData
import Foundation
import SwiftData

extension CanvasStore {
    @discardableResult
    func addImage(
        _ prepared: CanvasPreparedImage,
        center: CanvasPoint,
        id: UUID = UUID()
    ) -> CanvasPlacedImage? {
        guard !prepared.encodedData.isEmpty,
              prepared.encodedData.count <= CanvasImageImportPolicy.standard.maximumEncodedBytes,
              prepared.pixelWidth > 0,
              prepared.pixelHeight > 0,
              center.isFinite else {
            lastErrorMessage = CanvasReplicaMutationError.invalidImage.localizedDescription
            return nil
        }

        let size = CanvasImagePlacement.defaultSize(
            pixelWidth: prepared.pixelWidth,
            pixelHeight: prepared.pixelHeight
        )
        let highestZ = images.map(\.zIndex).max() ?? -1
        guard highestZ < Int64.max else {
            lastErrorMessage = CanvasReplicaMutationError.sortIndexExhausted.localizedDescription
            return nil
        }
        let transform = CanvasImageTransform(
            center: center,
            width: Double(size.width),
            height: Double(size.height),
            zIndex: highestZ + 1
        )
        let timestamp = now()
        do {
            try ensureSelectedBoardReplicaExists(at: timestamp)
            let replicas = try storedImageReplicas(matching: [id])[id] ?? []
            if replicas.isEmpty {
                context.insert(CanvasImageItem(
                    id: id,
                    canvasID: selectedCanvasID,
                    encodedData: prepared.encodedData,
                    contentType: prepared.contentType,
                    pixelWidth: prepared.pixelWidth,
                    pixelHeight: prepared.pixelHeight,
                    centerX: transform.center.x,
                    centerY: transform.center.y,
                    width: transform.width,
                    height: transform.height,
                    zIndex: transform.zIndex,
                    boardGeneration: boardGeneration,
                    mutationVersion: 1,
                    tombstoned: false,
                    createdAt: timestamp,
                    updatedAt: timestamp
                ))
            } else {
                // Treat a caller-supplied ID as an idempotent logical
                // identity, just like strokes. Updating every physical row
                // prevents an old tombstone from winning over a retry and
                // avoids creating another CloudKit duplicate.
                let winner = try Self.winningImageReplica(in: replicas)
                let nextVersion = try Self.nextMutationVersion(
                    after: replicas.map(\.mutationVersion).max() ?? 0,
                    objectID: id
                )
                for replica in replicas {
                    replica.canvasID = selectedCanvasID
                    replica.encodedData = prepared.encodedData
                    replica.contentType = prepared.contentType
                    replica.pixelWidth = Int64(prepared.pixelWidth)
                    replica.pixelHeight = Int64(prepared.pixelHeight)
                    replica.centerX = transform.center.x
                    replica.centerY = transform.center.y
                    replica.width = transform.width
                    replica.height = transform.height
                    replica.zIndex = transform.zIndex
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
        return images.first { $0.id == id }
    }

    @discardableResult
    func updateImage(
        _ id: UUID,
        transform: CanvasImageTransform
    ) -> Bool {
        guard transform.isValid else {
            lastErrorMessage = CanvasReplicaMutationError.invalidImage.localizedDescription
            return false
        }
        do {
            let replicas = try storedImageReplicas(matching: [id])[id] ?? []
            guard !replicas.isEmpty else {
                throw CanvasReplicaMutationError.missingImage(id)
            }
            let winner = try Self.winningImageReplica(in: replicas)
            let nextVersion = try Self.nextMutationVersion(
                after: replicas.map(\.mutationVersion).max() ?? 0,
                objectID: id
            )
            let timestamp = now()
            for replica in replicas {
                Self.copyImagePayload(from: winner, to: replica)
                replica.canvasID = selectedCanvasID
                replica.centerX = transform.center.x
                replica.centerY = transform.center.y
                replica.width = transform.width
                replica.height = transform.height
                replica.zIndex = transform.zIndex
                replica.boardGeneration = boardGeneration
                replica.mutationVersion = nextVersion
                replica.tombstoned = false
                replica.createdAt = winner.createdAt
                replica.updatedAt = timestamp
                replica.deletedAt = nil
            }
        } catch {
            discardPendingChanges(after: error)
            return false
        }
        return save()
    }

    @discardableResult
    func setImageDeleted(_ deleted: Bool, imageIDs: Set<UUID>) -> Bool {
        guard !imageIDs.isEmpty else { return true }
        do {
            let grouped = try storedImageReplicas(matching: imageIDs)
            for id in imageIDs where grouped[id]?.isEmpty != false {
                throw CanvasReplicaMutationError.missingImage(id)
            }
            let timestamp = now()
            for id in imageIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                let replicas = grouped[id] ?? []
                let winner = try Self.winningImageReplica(in: replicas)
                let nextVersion = try Self.nextMutationVersion(
                    after: replicas.map(\.mutationVersion).max() ?? 0,
                    objectID: id
                )
                for replica in replicas {
                    Self.copyImagePayload(from: winner, to: replica)
                    replica.canvasID = selectedCanvasID
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
    func restoreImages(_ snapshots: [CanvasPlacedImage]) -> Bool {
        guard !snapshots.isEmpty else { return true }
        let uniqueSnapshots = Dictionary(
            snapshots.map { ($0.id, $0) },
            uniquingKeysWith: { existing, candidate in
                Self.preferredImageSnapshot(candidate, over: existing)
                    ? candidate
                    : existing
            }
        )
        let ids = Set(uniqueSnapshots.keys)

        do {
            let timestamp = now()
            try ensureSelectedBoardReplicaExists(at: timestamp)
            let grouped = try storedImageReplicas(matching: ids)
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let snapshot = uniqueSnapshots[id],
                      !snapshot.encodedData.isEmpty,
                      snapshot.encodedData.count
                        <= CanvasImageImportPolicy.standard.maximumEncodedBytes,
                      snapshot.pixelWidth > 0,
                      snapshot.pixelHeight > 0,
                      snapshot.transform.isValid else {
                    throw CanvasReplicaMutationError.invalidImage
                }
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
                    context.insert(CanvasImageItem(
                        id: id,
                        canvasID: selectedCanvasID,
                        encodedData: snapshot.encodedData,
                        contentType: snapshot.contentType,
                        pixelWidth: snapshot.pixelWidth,
                        pixelHeight: snapshot.pixelHeight,
                        centerX: snapshot.center.x,
                        centerY: snapshot.center.y,
                        width: snapshot.width,
                        height: snapshot.height,
                        zIndex: snapshot.zIndex,
                        boardGeneration: boardGeneration,
                        mutationVersion: nextVersion,
                        tombstoned: false,
                        createdAt: snapshot.createdAt,
                        updatedAt: timestamp
                    ))
                } else {
                    for replica in replicas {
                        replica.canvasID = selectedCanvasID
                        replica.encodedData = snapshot.encodedData
                        replica.contentType = snapshot.contentType
                        replica.pixelWidth = Int64(snapshot.pixelWidth)
                        replica.pixelHeight = Int64(snapshot.pixelHeight)
                        replica.centerX = snapshot.center.x
                        replica.centerY = snapshot.center.y
                        replica.width = snapshot.width
                        replica.height = snapshot.height
                        replica.zIndex = snapshot.zIndex
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
