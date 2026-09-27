import Foundation
import SwiftData

/// A saved version of a note (spec § Notes → Version history): taken on a
/// 2-minute pause, when the note is left, and before any agent edit,
/// restore, migration or Writing Tools rewrite. Append-only; duplicates of
/// one `id` (CloudKit) are identical by construction and deduplicated for
/// presentation. Phase 2 slice 1 stores them; the history browser comes in
/// slice 7.
@Model
final class NoteVersion {
    var id: UUID = UUID()
    var noteID: UUID = UUID()
    var createdAt: Date = Date()
    /// `NoteVersionReason.rawValue`; unknown values from newer builds are kept.
    var reasonRaw: String = ""
    /// The note's content at that time (format ≥ 1), byte for byte.
    @Attribute(.externalStorage) var content: Data? = nil
    var contentFormat: Int = 0
    /// A legacy note's title and body (format 0), or the derived ones.
    var title: String = ""
    var body: String = ""
    /// The attachment rows this version shows (sorted, space-separated), so
    /// retention can keep them while the version exists.
    var attachmentIDsRaw: String = ""
    /// The note revision this version captured.
    var sourceRevisionID: UUID? = nil

    init(
        id: UUID = UUID(),
        noteID: UUID,
        createdAt: Date,
        reason: NoteVersionReason,
        content: Data?,
        contentFormat: Int,
        title: String,
        body: String,
        attachmentIDs: [UUID],
        sourceRevisionID: UUID?
    ) {
        self.id = id
        self.noteID = noteID
        self.createdAt = createdAt
        self.reasonRaw = reason.rawValue
        self.content = content
        self.contentFormat = contentFormat
        self.title = title
        self.body = body
        self.attachmentIDsRaw = NoteVersion.encodeIDs(attachmentIDs)
        self.sourceRevisionID = sourceRevisionID
    }

    var reason: NoteVersionReason? { NoteVersionReason(rawValue: reasonRaw) }

    var attachmentIDs: Set<UUID> {
        Set(attachmentIDsRaw.split(separator: " ").compactMap { UUID(uuidString: String($0)) })
    }

    static func encodeIDs(_ ids: [UUID]) -> String {
        Set(ids).map(\.uuidString).sorted().joined(separator: " ")
    }
}

enum NoteVersionReason: String, CaseIterable, Sendable {
    case pause
    case leave
    case beforeAgentEdit
    case beforeRestore
    case beforeMigration
    case beforeWritingTools
    /// The stored note had moved on from the revision an editor draft was
    /// based on (a recovered draft, a divergent replica): the stored text is
    /// kept here before the draft replaces it.
    case replacedByDraft
}

/// An agent's whole-note edit that could not apply because the note was open
/// (spec § Agent access). Kept across quit with the revision it was based on.
/// It applies by itself when the note is left if the note is still at that
/// revision; otherwise it waits for review (`needsReview`, UI in slice 5).
@Model
final class NotePendingEdit {
    var id: UUID = UUID()
    var noteID: UUID = UUID()
    var baseRevisionToken: String = ""
    @Attribute(.externalStorage) var proposedContent: Data? = nil
    var agentName: String = ""
    var createdAt: Date = Date()
    var needsReview: Bool = false

    init(id: UUID = UUID(), noteID: UUID, baseRevisionToken: String, proposedContent: Data,
         agentName: String, createdAt: Date) {
        self.id = id
        self.noteID = noteID
        self.baseRevisionToken = baseRevisionToken
        self.proposedContent = proposedContent
        self.agentName = agentName
        self.createdAt = createdAt
    }
}
