import Foundation
import SwiftData

@Model
final class CanvasImageItem {
    // CloudKit cannot enforce SwiftData uniqueness. CanvasStore presents one
    // deterministic winner and applies every mutation to all physical replicas.
    var id: UUID = UUID()
    var canvasID: UUID = CanvasBoardItem.logicalBoardID
    @Attribute(.externalStorage) var encodedData: Data = Data()
    var contentType: String = "public.png"
    var pixelWidth: Int64 = 0
    var pixelHeight: Int64 = 0
    var centerX: Double = 0
    var centerY: Double = 0
    var width: Double = CanvasImagePlacement.minimumDimension
    var height: Double = CanvasImagePlacement.minimumDimension
    var zIndex: Int64 = 0
    var boardGeneration: Int64 = 0
    var mutationVersion: Int64 = 1
    var tombstoned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        canvasID: UUID = CanvasBoardItem.logicalBoardID,
        encodedData: Data = Data(),
        contentType: String = "public.png",
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        centerX: Double = 0,
        centerY: Double = 0,
        width: Double = CanvasImagePlacement.minimumDimension,
        height: Double = CanvasImagePlacement.minimumDimension,
        zIndex: Int64 = 0,
        boardGeneration: Int64 = 0,
        mutationVersion: Int64 = 1,
        tombstoned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.canvasID = canvasID
        self.encodedData = encodedData
        self.contentType = contentType
        self.pixelWidth = Int64(pixelWidth)
        self.pixelHeight = Int64(pixelHeight)
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.zIndex = zIndex
        self.boardGeneration = boardGeneration
        self.mutationVersion = mutationVersion
        self.tombstoned = tombstoned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}
