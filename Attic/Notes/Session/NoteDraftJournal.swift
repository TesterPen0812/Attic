import Foundation
import CryptoKit

/// What survives a failed save or a crash for one note's draft: its
/// document, the revision it was based on, the selection and the images it
/// staged (critique finding 1).
struct NoteDraftJournalEntry: Codable, Equatable, Sendable {
    struct StagedFile: Codable, Equatable, Sendable {
        let id: UUID
        let filename: String
        let contentTypeIdentifier: String
        let byteCount: Int64
        let digest: String
    }

    struct PendingImport: Codable, Equatable, Sendable {
        struct Item: Codable, Equatable, Sendable {
            let filename: String
            let contentTypeIdentifier: String
            let byteCount: Int64
            let stagedID: UUID?
            let pixelWidth: Double?
            let pixelHeight: Double?
            let failure: String?
        }
        let anchor: Int
        /// Nonzero for a captured paste replacement. nil in older journals.
        var replacementLength: Int? = nil
        /// True for a drop/paste boundary; false for Insert at the caret.
        var isBoundary: Bool? = nil
        let acceptedText: String
        let items: [Item]
        let remainingNames: [String]
    }

    var noteID: UUID
    var isPersisted: Bool
    var baseRevisionID: UUID?
    var content: Data
    var selectionLocation: Int
    var selectionLength: Int
    var scrollOffset: Double? = nil
    var staged: [StagedFile]
    var savedAt: Date
    /// The draft's full tag set (optional, so older recovery files still
    /// read). Kept even when unchanged, so a draft whose note disappears
    /// still has its tags.
    var tags: [String]? = nil
    /// Whether `tags` is a change the person made, to be written over the
    /// stored tags. nil in files written before this field: those stored
    /// `tags` only for a change.
    var tagsChanged: Bool? = nil
    /// A batch still loading when this checkpoint was written. Its copied
    /// bytes are also in `staged`, digest-checked by the journal reader.
    var pendingImport: PendingImport? = nil

    /// The tags to write over the stored ones, if any.
    var changedTags: [String]? {
        guard let tags else { return nil }
        return (tagsChanged ?? true) ? tags : nil
    }
}

/// Names the exact checkpoint a session wrote or adopted: the SHA-256 of
/// its file bytes. A claim authorizes replacement or explicit cancellation;
/// retirement additionally requires a verified durable byte handoff.
struct NoteRecoveryClaim: Equatable, Sendable {
    fileprivate let digest: String
}

/// The note as the store holds it after a successful save. A checkpoint
/// that adds nothing to it (same document and tags, every staged byte
/// already saved) may be retired without a claim.
struct NoteRecoverySavedState: Sendable {
    let document: NoteDocument
    let tags: [String]
    /// Verified stored payloads, keyed by the original UUID. Equality is a
    /// byte-handoff proof; presence of a row or document reference is not.
    var attachments: [UUID: StagedNoteAttachment] = [:]
}

enum NoteDraftRecoveryEntry: Sendable {
    case valid(NoteDraftJournalEntry, [StagedNoteAttachment], NoteRecoveryClaim)
    case damaged(String)
}

struct NoteDamagedRecoveryConfirmation: Equatable, Sendable {
    let noteID: UUID?
    let checkpointFilename: String
    fileprivate let checkpointDigest: String?
    fileprivate let stagedDigests: [String: String]
    let unreadableItems: [String]
    var canDiscard: Bool { unreadableItems.isEmpty }
}

struct NoteDamagedRecoveryDetails: Sendable {
    let title: String
    let explanation: String
    let confirmation: NoteDamagedRecoveryConfirmation
}

private enum NoteDraftJournalError: LocalizedError {
    case incompleteStaging
    case conflictingStaging
    case unknownOwnership
    case asynchronousIORequired

    var errorDescription: String? {
        switch self {
        case .incompleteStaging: "The recovery copy has missing or damaged image bytes."
        case .conflictingStaging: "An earlier recovery copy owns different bytes at this image ID."
        case .asynchronousIORequired: "Recovery persistence is still being prepared. Try again after it finishes."
        case .unknownOwnership: "Another recovery copy of this note is being kept, with its files, until it can be checked."
        }
    }
}

/// The single decision made before every journal mutation or collection.
/// A damaged state retains *all* staged files because its ownership set is
/// unknowable, even if the JSON envelope happens to decode.
private enum NoteRecoveryOwnership {
    case absent
    case valid(NoteDraftJournalEntry, [StagedNoteAttachment], NoteRecoveryClaim)
    case pending(NoteDraftJournalEntry, [StagedNoteAttachment], NoteRecoveryClaim)
    case damaged(String)
    case retired

    var retainedIDs: Set<UUID>? {
        switch self {
        case .absent, .retired: []
        case let .valid(entry, _, _), let .pending(entry, _, _): Set(entry.staged.map(\.id))
        case .damaged: nil
        }
    }

    /// Whether a caller may replace or retire this state. Unknown state is
    /// never released; known work needs the caller's claim, or proof that
    /// the saved note already holds all of it.
    func mayRelease(claim: NoteRecoveryClaim?, saved: () -> NoteRecoverySavedState?, discarding: Bool = false) -> Bool {
        switch self {
        case .absent, .retired: return true
        case .damaged: return false
        case let .pending(entry, _, current):
            if discarding { return claim == current }
            guard claim == current, let saved = saved(),
                  Set(entry.pendingImport?.items.compactMap(\.stagedID) ?? []).isSubset(of: Set(saved.document.attachmentIDs)) else { return false }
            let owed = Set(saved.document.attachmentIDs).union(entry.pendingImport?.items.compactMap(\.stagedID) ?? [])
            return entry.staged.filter { owed.contains($0.id) }.allSatisfy { meta in
                guard let bytes = saved.attachments[meta.id] else { return false }
                return bytes.payloadIsVerified && bytes.id == meta.id && bytes.byteCount == meta.byteCount && bytes.digest == meta.digest
            }
        case let .valid(entry, _, current):
            if discarding && claim == current { return true }
            guard let saved = saved() else { return false }
            return (claim == current || (NoteContentCodec.decode(entry.content).document == saved.document
                && (entry.changedTags == nil || entry.changedTags == saved.tags)))
                && entry.staged.filter { claim != current || saved.document.attachmentIDs.contains($0.id) }.allSatisfy { meta in
                    guard let bytes = saved.attachments[meta.id] else { return false }
                    return bytes.payloadIsVerified && bytes.id == meta.id && bytes.byteCount == meta.byteCount && bytes.digest == meta.digest
                }
        }
    }
}

/// Where drafts are checkpointed when the store can't save them. Every
/// checkpoint change goes through these two operations; callers never touch
/// the journal's files.
@MainActor
protocol NoteDraftJournaling: AnyObject {
    var requiresAsyncIO: Bool { get }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment], replacing: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws
    func discardOwnedDurably(noteID: UUID, claim: NoteRecoveryClaim) async throws
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry]
    /// Fresh ownership evidence without retiring checkpoints or collecting
    /// staging that may belong to a different live journal facade.
    func readRetentionEntries() async throws -> [NoteDraftRecoveryEntry]
    func cancelPendingDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment], replacing: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim
    func damagedDetailsDurably(noteID: UUID) async throws -> NoteDamagedRecoveryDetails
    func listDamagedDurably() async throws -> [NoteDamagedRecoveryDetails]
    func archiveDamagedDurably(_ confirmation: NoteDamagedRecoveryConfirmation, to: URL?, resolving: Bool) async throws -> URL
    /// Writes a checkpoint over state the caller owns (`replacing` is its
    /// current claim) and returns the new claim. Refuses damaged state and
    /// another owner's checkpoint, keeping both and their bytes.
    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
               replacing claim: NoteRecoveryClaim?) throws -> NoteRecoveryClaim
    /// Retires a checkpoint only when `saved` proves every still-owed staged byte has
    /// a durable owner. A claim alone never proves that handoff.
    /// Damaged or foreign state throws and stays on disk with its bytes.
    func retire(noteID: UUID, claim: NoteRecoveryClaim?, saved: () -> NoteRecoverySavedState?) throws
    /// Every checkpoint, damaged ones included, for startup and retention.
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry]
    /// Explicit cancellation/transfer is distinct from saved redundancy.
    func discardOwned(noteID: UUID, claim: NoteRecoveryClaim) throws
    func damagedDetails(noteID: UUID) throws -> NoteDamagedRecoveryDetails
    func archiveDamaged(_ confirmation: NoteDamagedRecoveryConfirmation, to destination: URL?, resolving: Bool) throws -> URL
}

extension NoteDraftJournaling {
    func cancelPendingDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment], replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        try await writeDurably(entry, staged: staged, replacing: claim)
    }

    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment], replacing: NoteRecoveryClaim?) throws -> NoteRecoveryClaim { throw NoteDraftJournalError.asynchronousIORequired }
    func retire(noteID: UUID, claim: NoteRecoveryClaim?, saved: () -> NoteRecoverySavedState?) throws { throw NoteDraftJournalError.asynchronousIORequired }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: @MainActor () -> NoteRecoverySavedState?) async throws {
        try await retireDurably(noteID: noteID, claim: claim, saved: saved())
    }

    var requiresAsyncIO: Bool { false }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment], replacing: NoteRecoveryClaim? = nil) async throws -> NoteRecoveryClaim {
        try write(entry, staged: staged, replacing: replacing)
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        try retire(noteID: noteID, claim: claim, saved: { saved })
    }
    func discardOwnedDurably(noteID: UUID, claim: NoteRecoveryClaim) async throws { try discardOwned(noteID: noteID, claim: claim) }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] { try recoveryEntries() }
    func readRetentionEntries() async throws -> [NoteDraftRecoveryEntry] {
        guard !requiresAsyncIO else { throw NoteDraftJournalError.asynchronousIORequired }
        return try recoveryEntries()
    }
    func entriesDurably() async throws -> [(NoteDraftJournalEntry, [StagedNoteAttachment])] {
        try await readRecoveryEntries().compactMap { if case let .valid(entry, bytes, _) = $0 { return (entry, bytes) }; return nil }
    }
    func listDamagedDurably() async throws -> [NoteDamagedRecoveryDetails] { throw NoteDraftJournalError.asynchronousIORequired }
    func damagedDetailsDurably(noteID: UUID) async throws -> NoteDamagedRecoveryDetails { try damagedDetails(noteID: noteID) }
    func archiveDamagedDurably(_ confirmation: NoteDamagedRecoveryConfirmation, to destination: URL?, resolving: Bool) async throws -> URL {
        try archiveDamaged(confirmation, to: destination, resolving: resolving)
    }

    func damagedDetails(noteID: UUID) throws -> NoteDamagedRecoveryDetails { throw NoteDraftJournalError.unknownOwnership }
    func archiveDamaged(_ confirmation: NoteDamagedRecoveryConfirmation, to destination: URL?, resolving: Bool) throws -> URL {
        throw NoteDraftJournalError.unknownOwnership
    }

    func discardOwned(noteID: UUID, claim: NoteRecoveryClaim) throws {
        try retire(noteID: noteID, claim: claim, saved: { nil })
    }

    /// A first checkpoint for a note with none.
    @discardableResult
    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment]) throws -> NoteRecoveryClaim {
        try write(entry, staged: staged, replacing: nil)
    }

    /// Readable checkpoints only (tests and presentation).
    func entries() throws -> [(NoteDraftJournalEntry, [StagedNoteAttachment])] {
        try recoveryEntries().compactMap {
            if case let .valid(entry, staged, _) = $0 { return (entry, staged) }
            return nil
        }
    }
}

/// One file per note (`<id>.json`) plus staged attachment bytes
/// (`staged/<id>`), written atomically. All disk I/O and verification live
/// on this serialized actor; the main-actor facade exposes cached inventory.
private struct NoteLiveReferenceSnapshot: Sendable {
    let version: UInt64
    let ids: Set<UUID>
}

private actor NoteDraftJournalIO {
    let directory: URL
    private let fileManagerFactory: @Sendable () -> FileManager
    private lazy var fileManager = fileManagerFactory()
    private var liveReferences = Set<UUID>()
    private var liveReferenceVersion: UInt64 = 0
    private func installLiveReferences(_ snapshot: NoteLiveReferenceSnapshot) {
        guard snapshot.version >= liveReferenceVersion else { return }
        liveReferenceVersion = snapshot.version
        liveReferences = snapshot.ids
    }

    init(directory: URL, fileManagerFactory: @escaping @Sendable () -> FileManager) {
        self.directory = directory
        self.fileManagerFactory = fileManagerFactory
    }

    private var stagedDirectory: URL { directory.appendingPathComponent("staged", isDirectory: true) }

    private func url(for noteID: UUID) -> URL {
        directory.appendingPathComponent("\(noteID.uuidString).json")
    }

    private static func digest(_ data: Data) -> String {
        NotePayloadDigest.sha256(data)
    }

    private func ownership(of file: URL) -> NoteRecoveryOwnership {
        guard fileManager.fileExists(atPath: file.path) else { return .absent }
        do {
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entry = try decoder.decode(NoteDraftJournalEntry.self, from: data)
            guard file.deletingPathExtension().lastPathComponent == entry.noteID.uuidString,
                  case .editable = NoteContentCodec.decode(entry.content),
                  Set(entry.staged.map(\.id)).count == entry.staged.count else {
                return .damaged("Recovery copy \(file.lastPathComponent) has unknown document or file ownership.")
            }
            let marker = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["retired"] as? Bool == true
            if marker {
                guard entry.staged.isEmpty, entry.pendingImport == nil else {
                    return .damaged("Retired recovery marker \(file.lastPathComponent) still names files or a pending import.")
                }
                return .retired
            }
            var staged: [StagedNoteAttachment] = []
            for meta in entry.staged {
                let bytes = try Data(contentsOf: stagedDirectory.appendingPathComponent(meta.id.uuidString))
                guard Int64(bytes.count) == meta.byteCount, Self.digest(bytes) == meta.digest else {
                    return .damaged("Recovery copy for \(entry.noteID.uuidString) has a damaged file: \(meta.filename).")
                }
                staged.append(StagedNoteAttachment(id: meta.id, filename: meta.filename,
                    contentTypeIdentifier: meta.contentTypeIdentifier, byteCount: meta.byteCount,
                    digest: meta.digest, data: bytes))
            }
            let claim = NoteRecoveryClaim(digest: Self.digest(data))
            if let pending = entry.pendingImport {
                guard Set(pending.items.compactMap(\.stagedID)).isSubset(of: Set(entry.staged.map(\.id))) else {
                    return .damaged("Recovery copy for \(entry.noteID.uuidString) has unknown pending file ownership.")
                }
                return .pending(entry, staged, claim)
            }
            return .valid(entry, staged, claim)
        } catch {
            return .damaged("Recovery copy \(file.lastPathComponent) is incomplete or unreadable: \(error.localizedDescription)")
        }
    }

    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
               replacing claim: NoteRecoveryClaim?, cancellingPending: Bool = false,
               live: NoteLiveReferenceSnapshot) throws -> NoteRecoveryClaim {
        installLiveReferences(live)
        let previous = ownership(of: url(for: entry.noteID))
        guard previous.mayRelease(claim: claim, saved: { nil }, discarding: true) else {
            throw NoteDraftJournalError.unknownOwnership
        }
        guard case .editable = NoteContentCodec.decode(entry.content),
              Set(entry.staged.map(\.id)).count == entry.staged.count,
              Set(entry.pendingImport?.items.compactMap(\.stagedID) ?? []).isSubset(of: Set(entry.staged.map(\.id))) else {
            throw NoteDraftJournalError.unknownOwnership
        }
        guard Set(entry.staged.map(\.id)) == Set(staged.map(\.id)), entry.staged.count == staged.count else {
            throw NoteDraftJournalError.incompleteStaging
        }
        for item in staged {
            guard item.byteCount == Int64(item.data.count), item.digest == Self.digest(item.data),
                  entry.staged.contains(where: { $0.id == item.id && $0.byteCount == item.byteCount && $0.digest == item.digest }) else {
                throw NoteDraftJournalError.incompleteStaging
            }
        }
        try fileManager.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        for item in staged {
            let file = stagedDirectory.appendingPathComponent(item.id.uuidString)
            if fileManager.fileExists(atPath: file.path) {
                guard try Data(contentsOf: file) == item.data else {
                    throw NoteDraftJournalError.conflictingStaging
                }
            } else {
                try item.data.write(to: file, options: .atomic)
            }
        }
        var preservedEntry = entry
        switch previous {
        case let .valid(old, _, _), let .pending(old, _, _):
            // Previous staged data remains a checkpoint owner until explicit
            // cancellation or verified handoff. A replacement claim alone
            // cannot turn the collector into an implicit byte deletion.
            let named = Set(entry.staged.map(\.id))
            let cancelled = cancellingPending ? Set(old.pendingImport?.items.compactMap(\.stagedID) ?? []) : []
            preservedEntry.staged += old.staged.filter { !named.contains($0.id) && !cancelled.contains($0.id) }
        default: break
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(preservedEntry)
        try data.write(to: url(for: entry.noteID), options: .atomic)
        removeUnreferencedStagedFiles()
        return NoteRecoveryClaim(digest: Self.digest(data))
    }

    /// If the file cannot be unlinked, an empty retired marker replaces it,
    /// so it can never come back as unsaved work.
    func retire(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?, live: NoteLiveReferenceSnapshot) throws {
        installLiveReferences(live)
        let file = url(for: noteID)
        let state = ownership(of: file)
        if case .absent = state { return }
        guard state.mayRelease(claim: claim, saved: { saved }) else { throw NoteDraftJournalError.unknownOwnership }
        try unlinkReleasedCheckpoint(noteID: noteID)
    }

    func discardOwned(noteID: UUID, claim: NoteRecoveryClaim, live: NoteLiveReferenceSnapshot) throws {
        installLiveReferences(live)
        guard ownership(of: url(for: noteID)).mayRelease(claim: claim, saved: { nil }, discarding: true) else {
            throw NoteDraftJournalError.unknownOwnership
        }
        try unlinkReleasedCheckpoint(noteID: noteID)
    }

    private func unlinkReleasedCheckpoint(noteID: UUID) throws {
        let file = url(for: noteID)
        do {
            try fileManager.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already absent.
        } catch {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let blank = NoteDraftJournalEntry(noteID: noteID, isPersisted: true, baseRevisionID: nil,
                content: try NoteContentCodec.encode(.blank), selectionLocation: 0, selectionLength: 0,
                staged: [], savedAt: Date())
            guard var object = try JSONSerialization.jsonObject(with: encoder.encode(blank)) as? [String: Any] else {
                throw error
            }
            object["retired"] = true
            try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        }
        removeUnreferencedStagedFiles()
    }

    func listDamaged() throws -> [NoteDamagedRecoveryDetails] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                guard case .damaged = ownership(of: file) else { return nil }
                return try damagedDetails(file: file)
            }
    }

    func damagedDetails(noteID: UUID) throws -> NoteDamagedRecoveryDetails {
        try damagedDetails(file: url(for: noteID))
    }

    private func damagedDetails(file: URL) throws -> NoteDamagedRecoveryDetails {
        guard case .damaged = ownership(of: file) else { throw NoteDraftJournalError.unknownOwnership }
        let confirmation = damagedConfirmation(file: file)
        let explanation = confirmation.canDiscard
            ? "Save Recovery Copy preserves whatever is readable and the exact damaged data. Discard Damaged Recovery… requires confirmation and moves it to quarantine; nothing is silently deleted."
            : "Save Recovery Copy preserves readable data. Discard is unavailable until these items can be read: " + confirmation.unreadableItems.joined(separator: ", ") + ". Restore access and try again; the originals remain protected."
        return NoteDamagedRecoveryDetails(title: "Recovery data is damaged",
            explanation: explanation, confirmation: confirmation)
    }

    private func damagedConfirmation(file: URL) -> NoteDamagedRecoveryConfirmation {
        let checkpoint = try? Data(contentsOf: file)
        var unreadable = checkpoint == nil ? [file.lastPathComponent] : []
        var staged: [String: String] = [:]
        if fileManager.fileExists(atPath: stagedDirectory.path) {
            do {
                for stagedFile in try fileManager.contentsOfDirectory(at: stagedDirectory, includingPropertiesForKeys: nil) {
                    // Unknown ownership includes arbitrary names and unreadable entries.
                    if let bytes = try? Data(contentsOf: stagedFile) {
                        staged[stagedFile.lastPathComponent] = Self.digest(bytes)
                    } else { unreadable.append("staged/" + stagedFile.lastPathComponent) }
                }
            } catch { unreadable.append("staged/") }
        }
        return .init(noteID: UUID(uuidString: file.deletingPathExtension().lastPathComponent),
            checkpointFilename: file.lastPathComponent, checkpointDigest: checkpoint.map(Self.digest),
            stagedDigests: staged, unreadableItems: unreadable.sorted())
    }

    func archiveDamaged(_ confirmation: NoteDamagedRecoveryConfirmation, to destination: URL?, resolving: Bool, live: NoteLiveReferenceSnapshot) throws -> URL {
        installLiveReferences(live)
        guard URL(fileURLWithPath: confirmation.checkpointFilename).lastPathComponent == confirmation.checkpointFilename,
              confirmation.checkpointFilename.hasSuffix(".json") else { throw NoteDraftJournalError.unknownOwnership }
        let checkpoint = directory.appendingPathComponent(confirmation.checkpointFilename)
        guard case .damaged = ownership(of: checkpoint),
              damagedConfirmation(file: checkpoint) == confirmation else {
            throw NoteDraftJournalError.unknownOwnership
        }
        guard !resolving || confirmation.canDiscard else { throw NoteDraftJournalError.incompleteStaging }
        let parent = destination ?? directory.appendingPathComponent("quarantine", isDirectory: true)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let archive = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: false)
        let stagedArchive = archive.appendingPathComponent("staged", isDirectory: true)
        try fileManager.createDirectory(at: stagedArchive, withIntermediateDirectories: false)
        let archivedCheckpoint = archive.appendingPathComponent(checkpoint.lastPathComponent)
        if let digest = confirmation.checkpointDigest {
            try fileManager.copyItem(at: checkpoint, to: archivedCheckpoint)
            guard Self.digest(try Data(contentsOf: archivedCheckpoint)) == digest else {
                throw NoteDraftJournalError.incompleteStaging
            }
        }
        if !confirmation.unreadableItems.isEmpty {
            try Data(confirmation.unreadableItems.joined(separator: "\n").utf8)
                .write(to: archive.appendingPathComponent("unreadable-items.txt"), options: .atomic)
        }
        for (name, digest) in confirmation.stagedDigests {
            let copy = stagedArchive.appendingPathComponent(name)
            try fileManager.copyItem(at: stagedDirectory.appendingPathComponent(name), to: copy)
            guard Self.digest(try Data(contentsOf: copy)) == digest else { throw NoteDraftJournalError.incompleteStaging }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let entry = try? decoder.decode(NoteDraftJournalEntry.self, from: Data(contentsOf: archivedCheckpoint)),
           let document = NoteContentCodec.decode(entry.content).document {
            try entry.content.write(to: archive.appendingPathComponent("readable-note.json"), options: .atomic)
            let names = Dictionary(entry.staged.map { ($0.id, $0.filename) }, uniquingKeysWith: { first, _ in first })
            try Data(NoteMarkdownExport.markdown(document) { names[$0] }.utf8)
                .write(to: archive.appendingPathComponent("readable-note.md"), options: .atomic)
        }
        let manifest = try JSONEncoder().encode(confirmation.stagedDigests)
        try manifest.write(to: archive.appendingPathComponent("ownership.json"), options: .atomic)
        let archiveFiles = [archive.appendingPathComponent("ownership.json")]
            + (confirmation.checkpointDigest == nil ? [] : [archivedCheckpoint])
            + (confirmation.unreadableItems.isEmpty ? [] : [archive.appendingPathComponent("unreadable-items.txt")])
            + confirmation.stagedDigests.keys.map({ stagedArchive.appendingPathComponent($0) })
        for file in archiveFiles {
            let handle = try FileHandle(forWritingTo: file)
            try handle.synchronize(); try handle.close()
        }
        // Recheck the complete inventory after preservation. No active path is
        // released on copy/verification failure or a stale confirmation.
        guard damagedConfirmation(file: checkpoint) == confirmation else {
            throw NoteDraftJournalError.unknownOwnership
        }
        if resolving {
            try fileManager.moveItem(at: checkpoint, to: archive.appendingPathComponent("resolved-checkpoint.raw"))
            // Quarantine is independent: active staged collection never enters
            // it. Its byte-for-byte copies own all unknown bytes indefinitely.
            removeUnreferencedStagedFiles()
        }
        return archive
    }

    func recoveryEntries(collectRetired: Bool = true, live: NoteLiveReferenceSnapshot) throws -> [NoteDraftRecoveryEntry] {
        installLiveReferences(live)
        let results = try readEntries(collectRetired: collectRetired)
        removeUnreferencedStagedFiles()
        return results
    }

    func retentionEntries() throws -> [NoteDraftRecoveryEntry] {
        try readEntries(collectRetired: false)
    }

    private func readEntries(collectRetired: Bool) throws -> [NoteDraftRecoveryEntry] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let results: [NoteDraftRecoveryEntry] = files.compactMap { file in
            switch ownership(of: file) {
            case let .valid(entry, staged, claim), let .pending(entry, staged, claim):
                return .valid(entry, staged, claim)
            case let .damaged(message): return .damaged(message)
            case .retired:
                if collectRetired { try? fileManager.removeItem(at: file) }
                return nil
            case .absent: return nil
            }
        }.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case let (.valid(left, _, _), .valid(right, _, _)): left.savedAt < right.savedAt
            case (.valid, .damaged): true
            case (.damaged, .valid): false
            case let (.damaged(left), .damaged(right)): left < right
            }
        }
        return results
    }

    /// A crash after a staged payload write but before the journal rename, or
    /// cancellation followed by a new checkpoint, can leave orphan files.
    /// Never collect when any journal file is unreadable: its bytes may still
    /// be the only recovery copy.
    private func removeUnreferencedStagedFiles() {
        guard let journals = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }),
              let files = try? fileManager.contentsOfDirectory(at: stagedDirectory, includingPropertiesForKeys: nil)
        else { return }
        var retained = liveReferences
        for file in journals {
            guard let owned = ownership(of: file).retainedIDs else { return }
            retained.formUnion(owned)
        }
        for file in files {
            guard let id = UUID(uuidString: file.lastPathComponent), !retained.contains(id) else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}


/// Synchronous controller boundaries can inspect cached ownership, but never
/// perform disk work. They queue a durable operation and keep the session
/// until its asynchronous completion; in-memory test journals remain usable.
@MainActor
final class NoteDraftJournal: NoteDraftJournaling {
    let directory: URL
    private let io: NoteDraftJournalIO
    private var cached: [NoteDraftRecoveryEntry]?
    private var liveReferenceVersion: UInt64 = 0
    private var cachedVersion: UInt64 = 0

    private func liveSnapshot() throws -> NoteLiveReferenceSnapshot {
        let ids = try liveReferencedIDs()
        liveReferenceVersion &+= 1
        return .init(version: liveReferenceVersion, ids: ids)
    }

    private func publish(_ entries: [NoteDraftRecoveryEntry], for snapshot: NoteLiveReferenceSnapshot) {
        guard snapshot.version >= cachedVersion else { return }
        cachedVersion = snapshot.version
        cached = entries
    }
    var liveReferencedIDs: () throws -> Set<UUID> = { [] }
    var requiresAsyncIO: Bool { true }

    /// The factory runs on the I/O actor and normally creates its exclusive
    /// FileManager. Shared injected managers must synchronize their own state.
    init(directory: URL, fileManagerFactory: @escaping @Sendable () -> FileManager = { FileManager() }) {
        self.directory = directory
        io = NoteDraftJournalIO(directory: directory, fileManagerFactory: fileManagerFactory)
    }

    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment], replacing: NoteRecoveryClaim?) throws -> NoteRecoveryClaim {
        throw NoteDraftJournalError.asynchronousIORequired
    }
    func retire(noteID: UUID, claim: NoteRecoveryClaim?, saved: () -> NoteRecoverySavedState?) throws {
        throw NoteDraftJournalError.asynchronousIORequired
    }
    func discardOwned(noteID: UUID, claim: NoteRecoveryClaim) throws { throw NoteDraftJournalError.asynchronousIORequired }
    func damagedDetails(noteID: UUID) throws -> NoteDamagedRecoveryDetails { throw NoteDraftJournalError.asynchronousIORequired }
    func archiveDamaged(_ confirmation: NoteDamagedRecoveryConfirmation, to destination: URL?, resolving: Bool) throws -> URL {
        throw NoteDraftJournalError.asynchronousIORequired
    }
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] {
        guard let cached else { throw NoteDraftJournalError.asynchronousIORequired }
        return cached
    }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] {
        let snapshot = try liveSnapshot()
        let entries = try await io.recoveryEntries(live: snapshot)
        publish(entries, for: snapshot)
        return entries
    }
    func readRetentionEntries() async throws -> [NoteDraftRecoveryEntry] {
        try await io.retentionEntries()
    }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment], replacing: NoteRecoveryClaim? = nil) async throws -> NoteRecoveryClaim {
        let snapshot = try liveSnapshot()
        let claim = try await io.write(entry, staged: staged, replacing: replacing, live: snapshot)
        publish(try await io.recoveryEntries(live: snapshot), for: snapshot)
        return claim
    }
    func cancelPendingDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment], replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        let snapshot = try liveSnapshot()
        let updated = try await io.write(entry, staged: staged, replacing: claim, cancellingPending: true, live: snapshot)
        publish(try await io.recoveryEntries(live: snapshot), for: snapshot)
        return updated
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        let snapshot = try liveSnapshot()
        try await io.retire(noteID: noteID, claim: claim, saved: saved, live: snapshot)
        publish(try await io.recoveryEntries(collectRetired: false, live: snapshot), for: snapshot)
    }
    func discardOwnedDurably(noteID: UUID, claim: NoteRecoveryClaim) async throws {
        let snapshot = try liveSnapshot()
        try await io.discardOwned(noteID: noteID, claim: claim, live: snapshot)
        publish(try await io.recoveryEntries(live: snapshot), for: snapshot)
    }
    func listDamagedDurably() async throws -> [NoteDamagedRecoveryDetails] { try await io.listDamaged() }
    func damagedDetailsDurably(noteID: UUID) async throws -> NoteDamagedRecoveryDetails { try await io.damagedDetails(noteID: noteID) }
    func archiveDamagedDurably(_ confirmation: NoteDamagedRecoveryConfirmation, to destination: URL?, resolving: Bool) async throws -> URL {
        let snapshot = try liveSnapshot()
        let archive = try await io.archiveDamaged(confirmation, to: destination, resolving: resolving, live: snapshot)
        publish(try await io.recoveryEntries(live: snapshot), for: snapshot)
        return archive
    }
}
