import Foundation
import SwiftData

/// One external binary row for a new stroke. Kept through soft-delete/Undo;
/// its stable UUID is guarded separately by the shared workspace ledger.
/// Provisional until Spike A's presentation evidence is complete.
@Model
final class CanvasInkPayloadItem {
    var id: UUID = UUID()
    var canvasID: UUID = UUID()
    var strokeID: UUID = UUID()
    @Attribute(.externalStorage) var bytes: Data = Data()
    var mutationVersion: Int64 = 1
    var tombstoned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil
    init(id: UUID = UUID(), canvasID: UUID = UUID(), strokeID: UUID = UUID()) {
        self.id = id; self.canvasID = canvasID; self.strokeID = strokeID
    }
}
