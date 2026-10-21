import Foundation
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Attic

@MainActor
final class Phase3StoreUpgradeTests: XCTestCase {
    func testFirstOpenCreatesNestedStoreDirectoryBeforeTakingWriterLease() throws {
        let root = ownedTemporaryDirectory(prefix: "P3FirstOpen")
        let directory = root.appendingPathComponent("New/Nested/Store", isDirectory: true)
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: directory)
        let context = ModelContext(container)
        let note = NoteItem(title: "Durable first note", body: "Kept")
        context.insert(note)
        try context.save()
        let reopened = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: directory)
        XCTAssertEqual(try ModelContext(reopened).fetch(FetchDescriptor<NoteItem>()).first?.title, "Durable first note")
        let storeURL = try XCTUnwrap(container.configurations.first?.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path + ".workspace-writer.lock"))
    }

    func testPhaseXDocumentPayloadsAndPhysicalReplicasSurviveWorkspaceUpgrade() throws {
        let root = ownedTemporaryDirectory(prefix: "Phase3StoreUpgrade")
        let url = root.appendingPathComponent("development.store")
        let id = UUID(), futureID = UUID(), attachmentID = UUID(), versionID = UUID(), proposalID = UUID()
        let document = NoteDocument(blocks: [.text("Modern note"), .text("Body with exact Unicode cafe\u{301}")])
        let bytes = try NoteContentCodec.encode(document)
        let future = Data("opaque future document bytes".utf8), payload = Data([0, 1, 2, 255])
        let revision = UUID()
        do {
            let old = try ModelContainer(for: Schema([
                PhaseXStoreFixture.NoteItem.self, PhaseXStoreFixture.NoteAttachment.self,
                PhaseXStoreFixture.NoteVersion.self, PhaseXStoreFixture.NotePendingEdit.self
            ]), configurations: ModelConfiguration("development", url: url, cloudKitDatabase: .none))
            let context = ModelContext(old)
            for title in ["Modern note", "Divergent replica"] {
                let note = PhaseXStoreFixture.NoteItem()
                note.id = id; note.title = title; note.body = "Body with exact Unicode cafe\u{301}"
                note.content = bytes; note.contentFormat = 1; note.revisionID = revision
                note.externalEditorName = "Agent"; note.externalEditedAt = Date(timeIntervalSince1970: 123)
                context.insert(note)
            }
            let opaque = PhaseXStoreFixture.NoteItem()
            opaque.id = futureID; opaque.content = future; opaque.contentFormat = 99
            context.insert(opaque)
            let attachment = PhaseXStoreFixture.NoteAttachment()
            attachment.id = attachmentID; attachment.noteID = id; attachment.payload = payload
            context.insert(attachment)
            let version = PhaseXStoreFixture.NoteVersion()
            version.id = versionID; version.noteID = id; version.content = bytes; version.contentFormat = 1
            context.insert(version)
            let proposal = PhaseXStoreFixture.NotePendingEdit()
            proposal.id = proposalID; proposal.noteID = id; proposal.proposedContent = bytes; proposal.isDeletion = true
            context.insert(proposal)
            try context.save()
        }
        let upgraded = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let current = ModelContext(upgraded)
        let replicas = try current.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
        XCTAssertEqual(replicas.count, 2)
        XCTAssertEqual(Set(replicas.map(\.title)), ["Modern note", "Divergent replica"])
        for row in replicas {
            XCTAssertEqual(row.content, bytes); XCTAssertEqual(row.revisionID, revision)
            XCTAssertEqual(row.externalEditorName, "Agent")
            XCTAssertEqual(row.externalEditedAt, Date(timeIntervalSince1970: 123))
            XCTAssertEqual(row.associationGeneration, 0); XCTAssertNil(row.contentFingerprint)
        }
        XCTAssertEqual(try current.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == futureID })).first?.content, future)
        XCTAssertEqual(try current.fetch(FetchDescriptor<NoteAttachment>()).first?.payload, payload)
        XCTAssertEqual(try current.fetch(FetchDescriptor<NoteVersion>()).first?.content, bytes)
        let proposal = try XCTUnwrap(current.fetch(FetchDescriptor<NotePendingEdit>()).first)
        XCTAssertEqual(proposal.proposedContent, bytes); XCTAssertTrue(proposal.isDeletion)
        XCTAssertEqual(try current.fetchCount(FetchDescriptor<OperationReceipt>()), 0)
    }
}

// Exact persisted declarations from main 281eb1e4, without convenience initializers.
// No uniqueness or relationship changes are hidden by a fixture translation.
private enum PhaseXStoreFixture {
@Model
final class NoteItem {
    init() {}
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
    /// Pinned to the top of All notes ("Pin to Top", Phase 2); nil when not
    /// pinned. Metadata, like tags: pinning never moves the note in the
    /// newest-first order or changes its revision, on every replica.
    var pinnedAt: Date? = nil

    /// Durable, unacknowledged outside-edit attribution. Local typing does not clear it.
    var externalEditorName: String? = nil
    var externalEditedAt: Date? = nil

    // MARK: Phase 2 note format (`attic.note/1`, see `NoteDocument`)
    //
    // All defaulted or optional, no uniqueness (CloudKit rules). A note with
    // Persisted format zero identifies historical rows for the one-time removal.
    // Keep that storage default so schema upgrades do not relabel old rows.
    // From format 1 on, `content` is the truth and `title`, `body` and
    // `plainText` are derived from it on every save, on every replica.

    /// The stored document. Kept byte for byte
    /// when this build can only read it (a newer format).
    @Attribute(.externalStorage) var content: Data? = nil
    /// 0 historical format (purged once), 1 `attic.note/1`, higher = a newer Attic.
    var contentFormat: Int = 0
    /// Derived search and agent text (title, then one line per block).
    var plainText: String = ""
    /// Revision-matched library facts, written with document bytes on every replica.
    var imageCount: Int = 0
    var fileCount: Int = 0
    var firstFileName: String? = nil
    /// This note is that task's page (phase 3); nil for ordinary notes.
    var taskID: UUID? = nil
    /// +1 per content save (ordering).
    var revision: Int64 = 0
    /// A new random value per content save: "unchanged since an agent read
    /// it" is exact even across divergent replicas. nil until the first
    /// save that records one.
    var revisionID: UUID? = nil

}

@Model
final class NoteAttachment {
    init() {}
    var id: UUID = UUID()
    var noteID: UUID = UUID()
    var originalFilename: String = ""
    var contentTypeIdentifier: String = UTType.data.identifier
    var byteCount: Int64 = 0
    var sortIndex: Int64 = 0
    /// Retired storage columns retained for additive schema compatibility; never read or written by the editor.
    var inlineOffset: Int? = nil
    var displayWidth: Double? = nil
    var displayHeight: Double? = nil
    var contentDigest: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Removed on its own and kept in Recently Deleted for 30 days (its bytes
    /// and file stay). nil while the attachment is shown.
    var deletedAt: Date? = nil
    @Attribute(.externalStorage) var payload: Data? = nil

}

@Model
final class NoteVersion {
    init() {}
    var id: UUID = UUID()
    var noteID: UUID = UUID()
    var createdAt: Date = Date()
    /// `NoteVersionReason.rawValue`; unknown values from newer builds are kept.
    var reasonRaw: String = ""
    /// The note's content at that time (format ≥ 1), byte for byte.
    @Attribute(.externalStorage) var content: Data? = nil
    var contentFormat: Int = 0
    /// Derived title and body retained for history presentation.
    var title: String = ""
    var body: String = ""
    /// The attachment rows this version shows (sorted, space-separated), so
    /// retention can keep them while the version exists.
    var attachmentIDsRaw: String = ""
    /// The note revision this version captured.
    var sourceRevisionID: UUID? = nil

}

@Model
final class NotePendingEdit {
    init() {}
    var id: UUID = UUID()
    var noteID: UUID = UUID()
    var baseRevisionToken: String = ""
    @Attribute(.externalStorage) var proposedContent: Data? = nil
    /// The version inserted in the same transaction as this proposal.
    var baseVersionID: UUID? = nil
    var agentName: String = ""
    var createdAt: Date = Date()
    var needsReview: Bool = false
    var isDeletion: Bool = false

}
}
