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

    // MARK: Phase 2 note format (`attic.note/1`, see `NoteDocument`)
    //
    // All defaulted or optional, no uniqueness (CloudKit rules). A note with
    // `contentFormat == 0` is legacy: `title` and `body` are its content.
    // From format 1 on, `content` is the truth and `title`, `body` and
    // `plainText` are derived from it on every save, on every replica.

    /// The stored document; nil while the note is legacy. Kept byte for byte
    /// when this build can only read it (a newer format).
    @Attribute(.externalStorage) var content: Data? = nil
    /// 0 legacy title/body, 1 `attic.note/1`, higher = written by a newer Attic.
    var contentFormat: Int = 0
    /// Derived search and agent text (title, then one line per block).
    var plainText: String = ""
    /// This note is that task's page (phase 3); nil for ordinary notes.
    var taskID: UUID? = nil
    /// +1 per content save (ordering).
    var revision: Int64 = 0
    /// A new random value per content save: "unchanged since an agent read
    /// it" is exact even across divergent replicas. nil until the first
    /// save that records one.
    var revisionID: UUID? = nil

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

    /// Stored in the new format (editable or not): the new editor owns it.
    var usesDocumentFormat: Bool { contentFormat >= 1 }

    /// The token agents read and must send back with a write.
    var revisionToken: String { revisionID?.uuidString ?? NoteItem.initialRevisionToken }

    static let initialRevisionToken = "initial"
}
