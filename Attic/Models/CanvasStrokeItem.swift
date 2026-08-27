import Foundation
import SwiftData

@Model
final class CanvasStrokeItem {
    /// Logical stroke identity. This deliberately has no SwiftData unique
    /// constraint because CloudKit cannot enforce one.
    var id: UUID = UUID()
    var payloadVersion: Int = 1
    var payload: Data = Data()
    var boardGeneration: Int64 = 0
    var mutationVersion: Int64 = 1
    var isDeleted: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        payloadVersion: Int = 1,
        payload: Data = Data(),
        boardGeneration: Int64 = 0,
        mutationVersion: Int64 = 1,
        isDeleted: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.payloadVersion = payloadVersion
        self.payload = payload
        self.boardGeneration = boardGeneration
        self.mutationVersion = mutationVersion
        self.isDeleted = isDeleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}
