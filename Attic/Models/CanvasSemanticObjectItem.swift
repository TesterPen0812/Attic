import Foundation
import SwiftData

/// Additive storage: legacy image bytes and ink rows are never converted.
@Model
final class CanvasSemanticObjectItem {
    var id: UUID = UUID()
    var canvasID: UUID = CanvasBoardItem.logicalBoardID
    var kind: String = "text"
    var payloadVersion: Int = 1
    var payload: Data = Data()
    var centerX: Double = 0
    var centerY: Double = 0
    var width: Double = 160
    var height: Double = 48
    var rotation: Double = 0
    var zIndex: Int64 = 0
    var boardGeneration: Int64 = 0
    var mutationVersion: Int64 = 1
    var tombstoned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil

    init(id: UUID = UUID(), canvasID: UUID = CanvasBoardItem.logicalBoardID) {
        self.id = id
        self.canvasID = canvasID
    }
}
