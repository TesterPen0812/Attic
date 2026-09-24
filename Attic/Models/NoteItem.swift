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
    /// The attachment ids the note held when it was deleted (sorted,
    /// space-separated; empty for none), written to every replica, so the
    /// purge removes exactly that family and never a row that arrived later.
    /// nil while the note is live, and for a note deleted before this was
    /// recorded, which the purge keeps rather than guess.
    var deletedAttachmentIDsRaw: String? = nil
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

    /// The recorded attachment family, or nil when none was recorded or
    /// the record can't be read.
    var deletedAttachmentIDs: Set<UUID>? {
        guard let deletedAttachmentIDsRaw else { return nil }
        let tokens = deletedAttachmentIDsRaw.split(separator: " ")
        let ids = tokens.compactMap { UUID(uuidString: String($0)) }
        return ids.count == tokens.count ? Set(ids) : nil
    }

    var tags: [String] {
        get { AtticTag.decode(tagsRaw) }
        set { tagsRaw = AtticTag.encode(newValue) }
    }
}
