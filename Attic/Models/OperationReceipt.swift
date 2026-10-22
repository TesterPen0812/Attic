import Foundation
import SwiftData

/// Same-save evidence of a workspace commit. Logical IDs are intentionally not
/// unique: every physical replica must agree before recovery can use a receipt.
@Model
final class OperationReceipt {
    var id: UUID = UUID()
    var envelopeDigest: String = ""
    var affectedIDs: Data = Data()
    var resultingTokens: Data = Data()
    var historyEffect: Data? = nil
    var replayOf: UUID? = nil
    var compensationOf: UUID? = nil
    var publicationComplete: Bool = false
    var handoffProof: Data? = nil
    var envelopeReleased: Bool = false
    var createdAt: Date = Date()

    init(id: UUID, envelopeDigest: String, affectedIDs: Data, resultingTokens: Data,
         historyEffect: Data? = nil, replayOf: UUID? = nil, compensationOf: UUID? = nil) {
        self.id = id
        self.envelopeDigest = envelopeDigest
        self.affectedIDs = affectedIDs
        self.resultingTokens = resultingTokens
        self.historyEffect = historyEffect
        self.replayOf = replayOf
        self.compensationOf = compensationOf
    }
}

@Model
final class TaskNoteAssociation {
    var id: UUID = UUID()
    var taskID: UUID = UUID()
    var noteID: UUID = UUID()
    var taskGeneration: Int64 = 0
    var noteGeneration: Int64 = 0
    var detachedPreservationID: UUID? = nil
    var detachedAt: Date? = nil
    init(id: UUID = UUID(), taskID: UUID, noteID: UUID) {
        self.id = id; self.taskID = taskID; self.noteID = noteID
    }
}

/// Immutable recovery metadata; payload bytes stay owned at their original IDs.
@Model
final class TaskDeletionPreservation {
    var id: UUID = UUID()
    var rootID: UUID = UUID()
    var deletedAt: Date = Date()
    var capturedAt: Date = Date()
    var provenance: String = "soft-deletion"
    var snapshot: Data = Data()
    var purgedAt: Date? = nil
    /// Snapshot/tombstone stays immutable; dependency ownership ends when the
    /// deletion is restored or the coordinated purge materializes its notes.
    var retiredAt: Date? = nil
    var dependencyOwnersData: Data? = nil
    init(id: UUID = UUID(), rootID: UUID, deletedAt: Date, capturedAt: Date,
         provenance: String, snapshot: Data) {
        self.id = id; self.rootID = rootID; self.deletedAt = deletedAt
        self.capturedAt = capturedAt; self.provenance = provenance; self.snapshot = snapshot
    }
}

/// UX plan § 13: the migration record of one task family's legacy files
/// (`id` is the top-level task's id). Replicas with the same id are one
/// logical record (S10). Metadata only: the files' bytes stay owned at their
/// attachment IDs, and the legacy lists and `TaskImages` bytes are never
/// touched by the migration.
@Model
final class TaskAttachmentMigrationRecord {
    var id: UUID = UUID()
    var noteID: UUID = UUID()
    var noteCreated: Bool = false
    /// "migrated" or "reversed". A reversed family stays legacy until a
    /// person moves its files again (reversal is never undone automatically).
    var stateRaw: String = "migrated"
    /// The source manifest (`TaskAttachmentMigration.Manifest`).
    var manifestData: Data = Data()
    /// The note before (`NoteState`), or "absent".
    var beforeData: Data = Data()
    /// The note after: revision, placement IDs, attachment IDs.
    var afterData: Data = Data()
    var build: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    init(id: UUID, noteID: UUID) { self.id = id; self.noteID = noteID }
}
