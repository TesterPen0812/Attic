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
        let target = CanvasImportTarget(
            canvasID: selectedCanvasID,
            boardGeneration: boardGeneration
        )
        switch importImages(
            [CanvasPreparedImageImport(
                requestID: id,
                prepared: prepared,
                center: center
            )],
            target: target
        ) {
        case let .imported(images):
            return images.first
        case .rejected:
            return nil
        }
    }

    /// Atomically places the successfully prepared members of one import
    /// batch on the immutable page/generation captured when the drop began.
    /// This method never consults `selectedCanvasID` to choose a destination.
    @discardableResult
    func importImages(
        _ imports: [CanvasPreparedImageImport],
        target: CanvasImportTarget
    ) -> CanvasStoreImageImportOutcome {
        guard !imports.isEmpty else { return .imported([]) }
        guard Set(imports.map(\.requestID)).count == imports.count,
              imports.allSatisfy({ item in
                  !item.prepared.encodedData.isEmpty
                      && item.prepared.encodedData.count
                        <= CanvasImageImportPolicy.standard.maximumEncodedBytes
                      && item.prepared.pixelWidth > 0
                      && item.prepared.pixelHeight > 0
                      && item.center.isFinite
              }) else {
            let message = CanvasReplicaMutationError.invalidImage.localizedDescription
            lastErrorMessage = message
            return .rejected(.persistenceFailed(message))
        }

        let timestamp = now()
        do {
            let boardReplicas = try storedBoardReplicas(matching: target.canvasID)
            var boardToMaterialize: CanvasBoard?
            if boardReplicas.isEmpty {
                guard let board = canvases.first(where: { $0.id == target.canvasID }) else {
                    let failure = CanvasImageImportFailure.targetUnavailable
                    lastErrorMessage = failure.message
                    return .rejected(failure)
                }
                guard board.clearGeneration == target.boardGeneration else {
                    let failure = CanvasImageImportFailure.targetGenerationChanged
                    lastErrorMessage = failure.message
                    return .rejected(failure)
                }
                boardToMaterialize = board
            } else {
                let boardWinner = Self.winningBoardReplica(in: boardReplicas)
                guard !boardWinner.tombstoned else {
                    let failure = CanvasImageImportFailure.targetUnavailable
                    lastErrorMessage = failure.message
                    return .rejected(failure)
                }
                guard boardWinner.clearGeneration == target.boardGeneration else {
                    let failure = CanvasImageImportFailure.targetGenerationChanged
                    lastErrorMessage = failure.message
                    return .rejected(failure)
                }
            }

            let requestIDs = Set(imports.map(\.requestID))
            let targetRows = try context.fetch(FetchDescriptor<CanvasImageItem>())
                .filter { $0.canvasID == target.canvasID }
            let groupedRows = Dictionary(grouping: targetRows, by: \.id)
            let highestUnaffectedZ = try groupedRows.compactMap { id, replicas -> Int64? in
                guard !requestIDs.contains(id) else { return nil }
                let winner = try Self.winningImageReplica(in: replicas)
                guard !winner.tombstoned,
                      winner.boardGeneration == target.boardGeneration else {
                    return nil
                }
                return winner.zIndex
            }.max() ?? -1
            guard highestUnaffectedZ <= Int64.max - Int64(imports.count) else {
                let message = CanvasReplicaMutationError.sortIndexExhausted.localizedDescription
                lastErrorMessage = message
                return .rejected(.persistenceFailed(message))
            }

            if let board = boardToMaterialize {
                context.insert(CanvasBoardItem(
                    id: board.id,
                    name: board.name,
                    sortIndex: board.sortIndex,
                    formatVersion: CanvasStrokeCodec.currentVersion,
                    clearGeneration: target.boardGeneration,
                    mutationVersion: max(board.mutationVersion, 1),
                    tombstoned: false,
                    createdAt: board.createdAt == .distantPast ? timestamp : board.createdAt,
                    updatedAt: timestamp
                ))
            }

            var snapshots: [CanvasPlacedImage] = []
            snapshots.reserveCapacity(imports.count)
            for (offset, item) in imports.enumerated() {
                let size = CanvasImagePlacement.defaultSize(
                    pixelWidth: item.prepared.pixelWidth,
                    pixelHeight: item.prepared.pixelHeight
                )
                let transform = CanvasImageTransform(
                    center: item.center,
                    width: Double(size.width),
                    height: Double(size.height),
                    zIndex: highestUnaffectedZ + Int64(offset) + 1
                )
                let replicas = groupedRows[item.requestID] ?? []
                let createdAt: Date
                let mutationVersion: Int64
                if replicas.isEmpty {
                    createdAt = timestamp
                    mutationVersion = 1
                    context.insert(CanvasImageItem(
                        id: item.requestID,
                        canvasID: target.canvasID,
                        encodedData: item.prepared.encodedData,
                        contentType: item.prepared.contentType,
                        pixelWidth: item.prepared.pixelWidth,
                        pixelHeight: item.prepared.pixelHeight,
                        centerX: transform.center.x,
                        centerY: transform.center.y,
                        width: transform.width,
                        height: transform.height,
                        zIndex: transform.zIndex,
                        boardGeneration: target.boardGeneration,
                        mutationVersion: mutationVersion,
                        tombstoned: false,
                        createdAt: createdAt,
                        updatedAt: timestamp
                    ))
                } else {
                    let winner = try Self.winningImageReplica(in: replicas)
                    createdAt = winner.createdAt
                    mutationVersion = try Self.nextMutationVersion(
                        after: replicas.map(\.mutationVersion).max() ?? 0,
                        objectID: item.requestID
                    )
                    // A repeated batch ID is an idempotent logical identity.
                    // Update every physical replica rather than creating a
                    // hidden duplicate after an uncertain completion.
                    for replica in replicas {
                        replica.canvasID = target.canvasID
                        replica.encodedData = item.prepared.encodedData
                        replica.contentType = item.prepared.contentType
                        replica.pixelWidth = Int64(item.prepared.pixelWidth)
                        replica.pixelHeight = Int64(item.prepared.pixelHeight)
                        replica.centerX = transform.center.x
                        replica.centerY = transform.center.y
                        replica.width = transform.width
                        replica.height = transform.height
                        replica.zIndex = transform.zIndex
                        replica.boardGeneration = target.boardGeneration
                        replica.mutationVersion = mutationVersion
                        replica.tombstoned = false
                        replica.createdAt = createdAt
                        replica.updatedAt = timestamp
                        replica.deletedAt = nil
                    }
                }
                snapshots.append(CanvasPlacedImage(
                    id: item.requestID,
                    canvasID: target.canvasID,
                    encodedData: item.prepared.encodedData,
                    contentType: item.prepared.contentType,
                    pixelWidth: item.prepared.pixelWidth,
                    pixelHeight: item.prepared.pixelHeight,
                    transform: transform,
                    boardGeneration: target.boardGeneration,
                    mutationVersion: mutationVersion,
                    createdAt: createdAt,
                    updatedAt: timestamp
                ))
            }

            guard save() else {
                return .rejected(.persistenceFailed(
                    lastErrorMessage ?? "The image batch could not be saved."
                ))
            }
            if selectedCanvasID == target.canvasID,
               boardGeneration == target.boardGeneration {
                let reloadedByID = Dictionary(
                    uniqueKeysWithValues: images.map { ($0.id, $0) }
                )
                let reloadedSnapshots = imports.compactMap {
                    reloadedByID[$0.requestID]
                }
                if reloadedSnapshots.count == imports.count {
                    return .imported(reloadedSnapshots)
                }
            }
            return .imported(snapshots)
        } catch {
            discardPendingChanges(after: error)
            return .rejected(.persistenceFailed(error.localizedDescription))
        }
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
