import Foundation

/// Sparse before/after values. Nil metadata is the never-saved lazy board.
struct DrawChange: Codable, Equatable {
    var canvasID: UUID
    var before: DrawCanvas?
    var after: DrawCanvas?
    var objectsBefore: [UUID: DrawObject]
    var objectsAfter: [UUID: DrawObject]
    var objectIDs: Set<UUID> { Set(objectsBefore.keys).union(objectsAfter.keys) }
    var reversed: Self {
        Self(canvasID: canvasID, before: after, after: before,
             objectsBefore: objectsAfter, objectsAfter: objectsBefore)
    }
}

/// An image Delete Permanently or the 30-day removal takes: its canvas and
/// the deletion time the list showed.
struct DrawImageTarget: Equatable, Sendable {
    var canvas: UUID
    var deletedAt: Date
}

/// What a repository purge removed, and how many targets stayed.
struct DrawRepositoryPurge: Equatable, Sendable {
    var removedCanvases: Set<UUID> = []
    var removedImages: Set<UUID> = []
    var kept = 0
}

enum DrawWriteOutcome {
    case committed
    case retry(String)
    case held(String)
}

@MainActor
protocol DrawRepository: AnyObject {
    func library() throws -> [DrawCanvas]
    /// Search filters canvas metadata before requesting matching thumbnail bodies.
    func searchMetadata() throws -> [DrawCanvas]
    func hydrateSearchThumbnails(_ canvases: [DrawCanvas]) throws -> [DrawCanvas]
    func load(_ id: UUID) throws -> DrawSnapshot?
    func textMatches(_ words: [String], in id: UUID) throws -> [UUID]
    func write(_ change: DrawChange) -> DrawWriteOutcome
    func reconcile(_ change: DrawChange) -> DrawWriteOutcome
    /// Exact physical before/after proof of the attempted save, serialized
    /// for a recovery checkpoint outside the model transaction.
    func recoveryProof(for id: UUID) -> Data?
    /// Check the entire physical family before a recovered agent Undo reloads
    /// presentation winners into a new DrawStore.
    func matchesAgentUndoPrestate(_ change: DrawChange) -> Bool
    /// Forgets a failed attempt that nothing will retry (a thumbnail).
    func discardAttempt(for id: UUID)
    /// Images deleted from live canvases, from metadata only.
    func deletedImageHeaders() throws -> [DrawDeletedImage]
    /// Removes deleted canvases (with everything in them) and deleted
    /// images for good, every physical replica, in one save.
    func purge(canvases: [UUID: Date], images: [UUID: DrawImageTarget]) -> DrawRepositoryPurge
}

extension DrawRepository {
    func searchMetadata() throws -> [DrawCanvas] { try library() }
    func hydrateSearchThumbnails(_ canvases: [DrawCanvas]) throws -> [DrawCanvas] { canvases }
    func recoveryProof(for id: UUID) -> Data? { nil }
    func matchesAgentUndoPrestate(_ change: DrawChange) -> Bool { true }
}

@MainActor
final class DrawMemoryRepository: DrawRepository {
    private var canvases: [UUID: DrawCanvas] = [:]
    private var objects: [UUID: [UUID: DrawObject]] = [:]

    func library() -> [DrawCanvas] { Array(canvases.values) }
    func load(_ id: UUID) -> DrawSnapshot? {
        guard let canvas = canvases[id] else { return nil }
        return DrawSnapshot(canvas: canvas, objects: Array(objects[id, default: [:]].values))
    }
    func write(_ change: DrawChange) -> DrawWriteOutcome {
        canvases[change.canvasID] = change.after
        for id in change.objectIDs { objects[change.canvasID, default: [:]][id] = change.objectsAfter[id] }
        return .committed
    }
    func textMatches(_ words: [String], in id: UUID) -> [UUID] {
        objects[id, default: [:]].values.filter { object in
            object.deletedAt == nil && words.contains { object.text.localizedStandardContains($0) }
        }.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }
    func reconcile(_ change: DrawChange) -> DrawWriteOutcome { .retry("Retry the edit.") }
    func recoveryProof(for id: UUID) -> Data? { nil }
    func discardAttempt(for id: UUID) {}
    func deletedImageHeaders() -> [DrawDeletedImage] {
        canvases.values.filter { $0.deletedAt == nil }.flatMap { canvas -> [DrawDeletedImage] in
            var metadata = canvas
            metadata.thumbnail = nil
            return objects[canvas.id, default: [:]].values.filter { $0.isImage && $0.deletedAt != nil }
                .map { DrawDeletedImage(canvas: metadata, object: $0.header) }
        }
    }
    func purge(canvases targets: [UUID: Date], images: [UUID: DrawImageTarget]) -> DrawRepositoryPurge {
        var result = DrawRepositoryPurge()
        for (id, deletedAt) in targets {
            guard let canvas = canvases[id], canvas.deletedAt == deletedAt else { result.kept += 1; continue }
            canvases[id] = nil
            objects[id] = nil
            result.removedCanvases.insert(id)
        }
        for (objectID, target) in images {
            guard canvases[target.canvas] != nil, let object = objects[target.canvas]?[objectID], object.isImage,
                  object.deletedAt == target.deletedAt else { result.kept += 1; continue }
            objects[target.canvas]?[objectID] = nil
            result.removedImages.insert(objectID)
        }
        return result
    }
}
