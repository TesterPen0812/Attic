import Foundation
import SwiftData

@Model
final class NoteItem {
    // CloudKit can't enforce SwiftData uniqueness. UUID generation plus the
    // NoteStore refresh deduplication keep the app-level identity stable.
    var id: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}
