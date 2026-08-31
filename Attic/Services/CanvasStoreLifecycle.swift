import Combine
import CoreData
import Foundation
import SwiftData

extension CanvasStore {
    @discardableResult
    func clearBoard() -> Bool {
        do {
            guard boardGeneration < Int64.max else {
                throw CanvasReplicaMutationError.generationExhausted
            }
            let replicas = try storedBoardReplicas(matching: selectedCanvasID)
            let nextGeneration = boardGeneration + 1
            let timestamp = now()
            if replicas.isEmpty {
                let board = selectedCanvas
                context.insert(CanvasBoardItem(
                    id: selectedCanvasID,
                    name: board.name,
                    sortIndex: board.sortIndex,
                    formatVersion: CanvasStrokeCodec.currentVersion,
                    clearGeneration: nextGeneration,
                    mutationVersion: try Self.nextMutationVersion(
                        after: board.mutationVersion,
                        objectID: selectedCanvasID
                    ),
                    tombstoned: false,
                    createdAt: board.createdAt == .distantPast ? timestamp : board.createdAt,
                    updatedAt: timestamp
                ))
            } else {
                let winner = Self.winningBoardReplica(in: replicas)
                let nextVersion = try Self.nextMutationVersion(
                    after: replicas.map(\.mutationVersion).max() ?? 0,
                    objectID: selectedCanvasID
                )
                for replica in replicas {
                    replica.name = winner.name
                    replica.sortIndex = winner.sortIndex
                    replica.formatVersion = CanvasStrokeCodec.currentVersion
                    replica.clearGeneration = nextGeneration
                    replica.mutationVersion = nextVersion
                    replica.tombstoned = false
                    replica.createdAt = winner.createdAt
                    replica.updatedAt = timestamp
                    replica.deletedAt = nil
                }
            }
        } catch {
            discardPendingChanges(after: error)
            return false
        }
        return save()
    }

    func refresh() {
        do {
            let warning = try reloadCanvas()
            lastErrorMessage = warning
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func handleCloudSyncEvent(_ update: CloudSyncEventUpdate) {
        guard CanvasCloudInfrastructurePolicy.isEnabled else { return }
        cloudSyncProtection.apply(update)
        reconcileProtectedCloudSyncActivity(for: update.kind)
        cloudSyncStatus.apply(update)
        if !update.succeeded, let errorMessage = update.errorMessage {
            NSLog("CloudKit %@ failed: %@", String(describing: update.kind), errorMessage)
        }

        // A completed import can leave a long-lived SwiftData context stale.
        // Replace it before fetching so imported values cannot be overwritten by
        // the next local Canvas mutation.
        guard update.kind == .importData, update.endedAt != nil else { return }

        cloudImportRefreshTask?.cancel()
        cloudImportRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refresh()
            self?.cloudSyncProtection.completeImportRefresh()
            self?.reconcileProtectedCloudSyncActivity(for: .importData)
            self?.cloudImportRefreshTask = nil
        }
    }

}
