import Foundation
import CryptoKit

/// What survives a failed save or a crash for one note's draft: its
/// document, the revision it was based on, the selection and the images it
/// staged (critique finding 1).
struct NoteDraftJournalEntry: Codable, Equatable {
    struct StagedFile: Codable, Equatable {
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
/// its file bytes. Only the holder of the current claim may replace or
/// retire a checkpoint that holds work the store does not.
struct NoteRecoveryClaim: Equatable, Sendable {
    fileprivate let digest: String
}

/// The note as the store holds it after a successful save. A checkpoint
/// that adds nothing to it (same document and tags, every staged byte
/// already saved) may be retired without a claim.
struct NoteRecoverySavedState {
    let document: NoteDocument
    let tags: [String]
}

enum NoteDraftRecoveryEntry {
    case valid(NoteDraftJournalEntry, [StagedNoteAttachment], NoteRecoveryClaim)
    case damaged(String)
}

private enum NoteDraftJournalError: LocalizedError {
    case incompleteStaging
    case conflictingStaging
    case unknownOwnership

    var errorDescription: String? {
        switch self {
        case .incompleteStaging: "The recovery copy has missing or damaged image bytes."
        case .conflictingStaging: "An earlier recovery copy owns different bytes at this image ID."
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
    func mayRelease(claim: NoteRecoveryClaim?, saved: () -> NoteRecoverySavedState?) -> Bool {
        switch self {
        case .absent, .retired: return true
        case .damaged: return false
        case let .pending(_, _, current): return claim == current
        case let .valid(entry, _, current):
            if claim == current { return true }
            guard let saved = saved() else { return false }
            return NoteContentCodec.decode(entry.content).document == saved.document
                && (entry.changedTags == nil || entry.changedTags == saved.tags)
                && Set(entry.staged.map(\.id)).isSubset(of: Set(saved.document.attachmentIDs))
        }
    }
}

/// Where drafts are checkpointed when the store can't save them. Every
/// checkpoint change goes through these two operations; callers never touch
/// the journal's files.
@MainActor
protocol NoteDraftJournaling: AnyObject {
    /// Writes a checkpoint over state the caller owns (`replacing` is its
    /// current claim) and returns the new claim. Refuses damaged state and
    /// another owner's checkpoint, keeping both and their bytes.
    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
               replacing claim: NoteRecoveryClaim?) throws -> NoteRecoveryClaim
    /// Retires a checkpoint the caller owns, or one `saved` proves redundant
    /// (read only when a checkpoint without a matching claim exists).
    /// Damaged or foreign state throws and stays on disk with its bytes.
    func retire(noteID: UUID, claim: NoteRecoveryClaim?, saved: () -> NoteRecoverySavedState?) throws
    /// Every checkpoint, damaged ones included, for startup and retention.
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry]
}

extension NoteDraftJournaling {
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
/// (`staged/<id>`), written atomically. Synchronous on purpose: navigation
/// must know whether the checkpoint landed before it replaces a session,
/// and it only runs when the store could not save.
@MainActor
final class NoteDraftJournal: NoteDraftJournaling {
    let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    private var stagedDirectory: URL { directory.appendingPathComponent("staged", isDirectory: true) }

    private func url(for noteID: UUID) -> URL {
        directory.appendingPathComponent("\(noteID.uuidString).json")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
               replacing claim: NoteRecoveryClaim?) throws -> NoteRecoveryClaim {
        guard ownership(of: url(for: entry.noteID)).mayRelease(claim: claim, saved: { nil }) else {
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        try data.write(to: url(for: entry.noteID), options: .atomic)
        removeUnreferencedStagedFiles()
        return NoteRecoveryClaim(digest: Self.digest(data))
    }

    /// If the file cannot be unlinked, an empty retired marker replaces it,
    /// so it can never come back as unsaved work.
    func retire(noteID: UUID, claim: NoteRecoveryClaim?, saved: () -> NoteRecoverySavedState?) throws {
        let file = url(for: noteID)
        let state = ownership(of: file)
        if case .absent = state { return }
        guard state.mayRelease(claim: claim, saved: saved) else { throw NoteDraftJournalError.unknownOwnership }
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

    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let results: [NoteDraftRecoveryEntry] = files.compactMap { file in
            switch ownership(of: file) {
            case let .valid(entry, staged, claim), let .pending(entry, staged, claim):
                return .valid(entry, staged, claim)
            case let .damaged(message): return .damaged(message)
            case .retired:
                try? fileManager.removeItem(at: file)
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
        removeUnreferencedStagedFiles()
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
        var retained = Set<UUID>()
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
