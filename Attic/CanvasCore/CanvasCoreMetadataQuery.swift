import Foundation
import SwiftData

enum CanvasCoreMetadataQuery {
    // Candidate projection, blocked by P4MetadataQueryBudget on the installed
    // macOS 27 toolchain: observed SQL still includes payload columns. Do not
    // wire this to accepted picker/accessibility paths until that gate passes.
    struct Stroke: Equatable {
        let physicalID: PersistentIdentifier
        let id: UUID
        let canvasID: UUID
        let version: Int64
        let generation: Int64
        let tombstoned: Bool
        let bounds: CanvasCoreBounds?
        let rank: Int64?
    }
    @MainActor static func strokes(canvasID: UUID, in context: ModelContext) throws -> [Stroke] {
        var descriptor = FetchDescriptor<CanvasStrokeItem>(predicate: #Predicate { $0.canvasID == canvasID })
        descriptor.includePendingChanges = false
        descriptor.propertiesToFetch = [\CanvasStrokeItem.id, \CanvasStrokeItem.canvasID,
            \CanvasStrokeItem.mutationVersion, \CanvasStrokeItem.boardGeneration, \CanvasStrokeItem.tombstoned,
            \CanvasStrokeItem.boundsMinX, \CanvasStrokeItem.boundsMinY, \CanvasStrokeItem.boundsMaxX,
            \CanvasStrokeItem.boundsMaxY, \CanvasStrokeItem.rankOverride]
        return try context.fetch(descriptor).map { row in
            let bounds: CanvasCoreBounds?
            if let x = row.boundsMinX, let y = row.boundsMinY, let mx = row.boundsMaxX, let my = row.boundsMaxY {
                bounds = .init(minX: x, minY: y, maxX: mx, maxY: my)
            } else { bounds = nil }
            return .init(physicalID: row.persistentModelID, id: row.id, canvasID: row.canvasID,
                version: row.mutationVersion, generation: row.boardGeneration, tombstoned: row.tombstoned,
                bounds: bounds, rank: row.rankOverride)
        }
    }
}
