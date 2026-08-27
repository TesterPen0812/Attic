import Combine
import CoreData
import Foundation
import SwiftData

extension CanvasStore {
    @discardableResult
    func selectCanvas(_ id: UUID) -> Bool {
        guard canvases.contains(where: { $0.id == id }) else {
            lastErrorMessage = CanvasReplicaMutationError.missingCanvas(id).localizedDescription
            return false
        }
        guard selectedCanvasID != id else { return true }
        selectedCanvasID = id
        refresh()
        return selectedCanvasID == id
    }

    @discardableResult
    func createCanvas(name proposedName: String? = nil) -> CanvasBoard? {
        let fallback = Self.nextDefaultName(in: canvases)
        guard let name = Self.normalizedCanvasName(proposedName ?? fallback) else {
            lastErrorMessage = CanvasReplicaMutationError.invalidCanvasName.localizedDescription
            return nil
        }
        guard let highest = canvases.map(\.sortIndex).max(), highest < Int64.max else {
            lastErrorMessage = CanvasReplicaMutationError.sortIndexExhausted.localizedDescription
            return nil
        }

        let id = UUID()
        let timestamp = now()
        context.insert(CanvasBoardItem(
            id: id,
            name: name,
            sortIndex: highest + 1,
            formatVersion: CanvasStrokeCodec.currentVersion,
            clearGeneration: 0,
            mutationVersion: 1,
            tombstoned: false,
            createdAt: timestamp,
            updatedAt: timestamp
        ))
        selectedCanvasID = id
        guard save() else { return nil }
        return canvases.first { $0.id == id }
    }

    @discardableResult
    func renameCanvas(_ id: UUID, to proposedName: String) -> Bool {
        guard let name = Self.normalizedCanvasName(proposedName) else {
            lastErrorMessage = CanvasReplicaMutationError.invalidCanvasName.localizedDescription
            return false
        }

        do {
            let replicas = try storedBoardReplicas(matching: id)
            let timestamp = now()
            if replicas.isEmpty {
                guard let board = canvases.first(where: { $0.id == id }) else {
                    throw CanvasReplicaMutationError.missingCanvas(id)
                }
                context.insert(CanvasBoardItem(
                    id: id,
                    name: name,
                    sortIndex: board.sortIndex,
                    formatVersion: CanvasStrokeCodec.currentVersion,
                    clearGeneration: board.clearGeneration,
                    mutationVersion: try Self.nextMutationVersion(
                        after: board.mutationVersion,
                        objectID: id
                    ),
                    tombstoned: false,
                    createdAt: board.createdAt,
                    updatedAt: timestamp
                ))
            } else {
                let winner = Self.winningBoardReplica(in: replicas)
                let nextVersion = try Self.nextMutationVersion(
                    after: replicas.map(\.mutationVersion).max() ?? 0,
                    objectID: id
                )
                for replica in replicas {
                    replica.name = name
                    replica.sortIndex = winner.sortIndex
                    replica.formatVersion = CanvasStrokeCodec.currentVersion
                    replica.clearGeneration = winner.clearGeneration
                    replica.mutationVersion = nextVersion
                    replica.tombstoned = false
                    replica.createdAt = winner.createdAt
                    replica.updatedAt = timestamp
                    replica.deletedAt = nil
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        return save()
    }

    @discardableResult
    func deleteCanvas(_ id: UUID) -> Bool {
        guard canvases.count > 1 else {
            lastErrorMessage = CanvasReplicaMutationError.cannotDeleteLastCanvas.localizedDescription
            return false
        }
        guard canvases.contains(where: { $0.id == id }) else {
            lastErrorMessage = CanvasReplicaMutationError.missingCanvas(id).localizedDescription
            return false
        }

        do {
            let timestamp = now()
            let boardReplicas = try storedBoardReplicas(matching: id)
            if boardReplicas.isEmpty {
                let board = canvases.first { $0.id == id } ?? .defaultBoard
                context.insert(CanvasBoardItem(
                    id: id,
                    name: board.name,
                    sortIndex: board.sortIndex,
                    formatVersion: CanvasStrokeCodec.currentVersion,
                    clearGeneration: board.clearGeneration,
                    mutationVersion: try Self.nextMutationVersion(
                        after: board.mutationVersion,
                        objectID: id
                    ),
                    tombstoned: true,
                    createdAt: board.createdAt,
                    updatedAt: timestamp,
                    deletedAt: timestamp
                ))
            } else {
                let winner = Self.winningBoardReplica(in: boardReplicas)
                let nextVersion = try Self.nextMutationVersion(
                    after: boardReplicas.map(\.mutationVersion).max() ?? 0,
                    objectID: id
                )
                for replica in boardReplicas {
                    replica.name = winner.name
                    replica.sortIndex = winner.sortIndex
                    replica.formatVersion = winner.formatVersion
                    replica.clearGeneration = winner.clearGeneration
                    replica.mutationVersion = nextVersion
                    replica.tombstoned = true
                    replica.createdAt = winner.createdAt
                    replica.updatedAt = timestamp
                    replica.deletedAt = timestamp
                }
            }

            try tombstoneAllContent(canvasID: id, at: timestamp)
            if selectedCanvasID == id {
                selectedCanvasID = canvases.first { $0.id != id }?.id
                    ?? CanvasBoardItem.logicalBoardID
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        return save()
    }

}
