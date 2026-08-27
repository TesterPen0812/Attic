import Foundation
import SwiftData

@Model
final class CanvasBoardItem {
    /// Canvas is one logical board. CloudKit may still contain multiple
    /// physical rows with this app-level identifier, so no unique constraint
    /// is applied and CanvasStore mutates every replica.
    static let logicalBoardID = UUID(
        uuidString: "8A9475C5-85B2-4D51-9CF6-A8D7EE6A4E01"
    )!

    var id: UUID = CanvasBoardItem.logicalBoardID
    var formatVersion: Int = 1
    var clearGeneration: Int64 = 0
    var updatedAt: Date = Date()

    init(
        id: UUID = CanvasBoardItem.logicalBoardID,
        formatVersion: Int = 1,
        clearGeneration: Int64 = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.formatVersion = formatVersion
        self.clearGeneration = clearGeneration
        self.updatedAt = updatedAt
    }
}
