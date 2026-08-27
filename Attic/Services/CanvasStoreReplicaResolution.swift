import Combine
import CoreData
import Foundation
import SwiftData

extension CanvasStore {
    static func copyImagePayload(
        from source: CanvasImageItem,
        to destination: CanvasImageItem
    ) {
        destination.encodedData = source.encodedData
        destination.contentType = source.contentType
        destination.pixelWidth = source.pixelWidth
        destination.pixelHeight = source.pixelHeight
        destination.centerX = source.centerX
        destination.centerY = source.centerY
        destination.width = source.width
        destination.height = source.height
        destination.zIndex = source.zIndex
    }

    static func winningStrokeReplica(
        in replicas: [CanvasStrokeItem]
    ) throws -> CanvasStrokeItem {
        guard var winner = replicas.first else {
            throw CanvasReplicaMutationError.missingStroke(UUID())
        }
        for candidate in replicas.dropFirst() where prefersStroke(candidate, over: winner) {
            winner = candidate
        }
        return winner
    }

    static func winningImageReplica(
        in replicas: [CanvasImageItem]
    ) throws -> CanvasImageItem {
        guard var winner = replicas.first else {
            throw CanvasReplicaMutationError.missingImage(UUID())
        }
        for candidate in replicas.dropFirst() where prefersImage(candidate, over: winner) {
            winner = candidate
        }
        return winner
    }

    static func winningBoardReplica(
        in replicas: [CanvasBoardItem]
    ) -> CanvasBoardItem {
        var winner = replicas[0]
        for candidate in replicas.dropFirst() where prefersBoard(candidate, over: winner) {
            winner = candidate
        }
        return winner
    }

    static func prefersStroke(
        _ candidate: CanvasStrokeItem,
        over existing: CanvasStrokeItem
    ) -> Bool {
        if candidate.mutationVersion != existing.mutationVersion {
            return candidate.mutationVersion > existing.mutationVersion
        }
        if candidate.boardGeneration != existing.boardGeneration {
            return candidate.boardGeneration > existing.boardGeneration
        }
        if candidate.tombstoned != existing.tombstoned {
            return candidate.tombstoned
        }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        if candidate.payloadVersion != existing.payloadVersion {
            return candidate.payloadVersion > existing.payloadVersion
        }
        if candidate.payload != existing.payload {
            return existing.payload.lexicographicallyPrecedes(candidate.payload)
        }
        if candidate.createdAt != existing.createdAt {
            return candidate.createdAt > existing.createdAt
        }
        if candidate.deletedAt != existing.deletedAt {
            return (candidate.deletedAt ?? .distantPast)
                > (existing.deletedAt ?? .distantPast)
        }
        return String(reflecting: candidate.persistentModelID)
            > String(reflecting: existing.persistentModelID)
    }

    static func prefersImage(
        _ candidate: CanvasImageItem,
        over existing: CanvasImageItem
    ) -> Bool {
        if candidate.mutationVersion != existing.mutationVersion {
            return candidate.mutationVersion > existing.mutationVersion
        }
        if candidate.boardGeneration != existing.boardGeneration {
            return candidate.boardGeneration > existing.boardGeneration
        }
        if candidate.tombstoned != existing.tombstoned {
            return candidate.tombstoned
        }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        if candidate.encodedData != existing.encodedData {
            return existing.encodedData.lexicographicallyPrecedes(candidate.encodedData)
        }
        if candidate.zIndex != existing.zIndex {
            return candidate.zIndex > existing.zIndex
        }
        if candidate.createdAt != existing.createdAt {
            return candidate.createdAt > existing.createdAt
        }
        if candidate.deletedAt != existing.deletedAt {
            return (candidate.deletedAt ?? .distantPast)
                > (existing.deletedAt ?? .distantPast)
        }
        return String(reflecting: candidate.persistentModelID)
            > String(reflecting: existing.persistentModelID)
    }

    static func prefersBoard(
        _ candidate: CanvasBoardItem,
        over existing: CanvasBoardItem
    ) -> Bool {
        if candidate.mutationVersion != existing.mutationVersion {
            return candidate.mutationVersion > existing.mutationVersion
        }
        if candidate.clearGeneration != existing.clearGeneration {
            return candidate.clearGeneration > existing.clearGeneration
        }
        if candidate.tombstoned != existing.tombstoned {
            return candidate.tombstoned
        }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        if candidate.name != existing.name {
            return candidate.name > existing.name
        }
        if candidate.sortIndex != existing.sortIndex {
            return candidate.sortIndex > existing.sortIndex
        }
        if candidate.deletedAt != existing.deletedAt {
            return (candidate.deletedAt ?? .distantPast)
                > (existing.deletedAt ?? .distantPast)
        }
        return String(reflecting: candidate.persistentModelID)
            > String(reflecting: existing.persistentModelID)
    }

    static func preferredStrokeSnapshot(
        _ candidate: CanvasStroke,
        over existing: CanvasStroke
    ) -> Bool {
        if candidate.mutationVersion != existing.mutationVersion {
            return candidate.mutationVersion > existing.mutationVersion
        }
        if candidate.boardGeneration != existing.boardGeneration {
            return candidate.boardGeneration > existing.boardGeneration
        }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return candidate.id.uuidString > existing.id.uuidString
    }

    static func preferredImageSnapshot(
        _ candidate: CanvasPlacedImage,
        over existing: CanvasPlacedImage
    ) -> Bool {
        if candidate.mutationVersion != existing.mutationVersion {
            return candidate.mutationVersion > existing.mutationVersion
        }
        if candidate.boardGeneration != existing.boardGeneration {
            return candidate.boardGeneration > existing.boardGeneration
        }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return candidate.id.uuidString > existing.id.uuidString
    }

    static func nextMutationVersion(
        after version: Int64,
        objectID: UUID
    ) throws -> Int64 {
        guard version < Int64.max else {
            throw CanvasReplicaMutationError.mutationVersionExhausted(objectID)
        }
        return max(version, 0) + 1
    }

    static func normalizedCanvasName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        return trimmed
    }

    static func nextDefaultName(in canvases: [CanvasBoard]) -> String {
        let names = Set(canvases.map(\.name))
        if !names.contains("Canvas") { return "Canvas" }
        var index = 2
        while names.contains("Canvas \(index)") { index += 1 }
        return "Canvas \(index)"
    }

    static func canvasBoard(from item: CanvasBoardItem) -> CanvasBoard {
        CanvasBoard(
            id: item.id,
            name: normalizedCanvasName(item.name) ?? "Untitled Canvas",
            sortIndex: item.sortIndex,
            clearGeneration: item.clearGeneration,
            mutationVersion: item.mutationVersion,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
    }

    static func boardComesBefore(_ lhs: CanvasBoard, _ rhs: CanvasBoard) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func strokeComesBefore(_ lhs: CanvasStroke, _ rhs: CanvasStroke) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func imageComesBefore(
        _ lhs: CanvasPlacedImage,
        _ rhs: CanvasPlacedImage
    ) -> Bool {
        if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func replicaKeyComesBefore(
        _ lhs: CanvasReplicaKey,
        _ rhs: CanvasReplicaKey
    ) -> Bool {
        if lhs.canvasID != rhs.canvasID {
            return lhs.canvasID.uuidString < rhs.canvasID.uuidString
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

}
