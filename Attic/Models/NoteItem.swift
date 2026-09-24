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
    /// Soft deletion (Recently Deleted). Attachments stay keyed by `noteID`
    /// and are left untouched, so a restore brings them back with the note.
    var deletedAt: Date? = nil
    /// Normalised tags (see `AtticTag`), space-separated and sorted.
    var tagsRaw: String = ""

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

    var tags: [String] {
        get { AtticTag.decode(tagsRaw) }
        set { tagsRaw = AtticTag.encode(newValue) }
    }
}
