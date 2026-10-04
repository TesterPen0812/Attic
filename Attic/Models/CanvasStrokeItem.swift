import Foundation
import SwiftData

@Model
final class CanvasStrokeItem {
    /// Logical stroke identity. This deliberately has no SwiftData unique
    /// constraint because CloudKit cannot enforce one.
    var id: UUID = UUID()
    var canvasID: UUID = CanvasBoardItem.logicalBoardID
    var payloadVersion: Int = 1
    var payload: Data = Data()
    // Provisional v2 contract. Existing JSON is canonical and never replaced
    // by a cache. Spike A's remaining presentation evidence may change these
    // optional fields before the slice 3 migration/schema freeze.
    @Attribute(.externalStorage) var binaryPayload: Data? = nil
    // Retain the experimental binaryPayload column for additive compatibility.
    // New writes use a separate immutable payload row, never this column.
    var binaryRowID: UUID? = nil
    var binaryDigest: String? = nil
    var boundsMinX: Double? = nil
    var boundsMinY: Double? = nil
    var boundsMaxX: Double? = nil
    var boundsMaxY: Double? = nil
    var offsetX: Double = 0
    var offsetY: Double = 0
    var rankOverride: Int64? = nil
    var boardGeneration: Int64 = 0
    var mutationVersion: Int64 = 1
    var tombstoned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        canvasID: UUID = CanvasBoardItem.logicalBoardID,
        payloadVersion: Int = 1,
        payload: Data = Data(),
        boardGeneration: Int64 = 0,
        mutationVersion: Int64 = 1,
        tombstoned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.canvasID = canvasID
        self.payloadVersion = payloadVersion
        self.payload = payload
        self.boardGeneration = boardGeneration
        self.mutationVersion = mutationVersion
        self.tombstoned = tombstoned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}
