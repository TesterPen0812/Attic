import Foundation
import SwiftData

@Model
final class CanvasBoardItem {
    /// The original single-canvas identity. Existing installations continue to
    /// resolve their ink and images into this default canvas.
    static let logicalBoardID = UUID(
        uuidString: "8A9475C5-85B2-4D51-9CF6-A8D7EE6A4E01"
    )!

    /// Used only when every physical board is tombstoned. Keeping this identity
    /// distinct prevents a deleted default canvas from being synthesized again.
    static let recoveryBoardID = UUID(
        uuidString: "B9C741E8-72F4-4E8E-A87C-64F77C2C1B01"
    )!

    /// App-level identity only. CloudKit can contain multiple physical rows for
    /// the same UUID, so CanvasStore deterministically resolves a winner and
    /// applies mutations to every replica rather than using a unique constraint.
    var id: UUID = CanvasBoardItem.logicalBoardID
    var name: String = "Canvas"
    var sortIndex: Int64 = 0
    var formatVersion: Int = 1
    var clearGeneration: Int64 = 0
    var mutationVersion: Int64 = 1
    var tombstoned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil

    init(
        id: UUID = CanvasBoardItem.logicalBoardID,
        name: String = "Canvas",
        sortIndex: Int64 = 0,
        formatVersion: Int = 1,
        clearGeneration: Int64 = 0,
        mutationVersion: Int64 = 1,
        tombstoned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.formatVersion = formatVersion
        self.clearGeneration = clearGeneration
        self.mutationVersion = mutationVersion
        self.tombstoned = tombstoned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}
