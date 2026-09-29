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

enum NoteDraftRecoveryEntry {
    case valid(NoteDraftJournalEntry, [StagedNoteAttachment])
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
        case .unknownOwnership: "The existing recovery copy is unreadable; its files are being kept."
        }
    }
}

/// The single decision made before every journal mutation or collection.
/// A damaged state retains *all* staged files because its ownership set is
/// unknowable, even if the JSON envelope happens to decode.
private enum NoteRecoveryOwnership {
    case absent
    case valid(NoteDraftJournalEntry, [StagedNoteAttachment])
    case pending(NoteDraftJournalEntry, [StagedNoteAttachment])
    case damaged(String)
    case retired

    var retainedIDs: Set<UUID>? {
        switch self {
        case .absent, .retired: []
        case let .valid(entry, _), let .pending(entry, _): Set(entry.staged.map(\.id))
        case .damaged: nil
        }
    }
}

/// Where drafts are checkpointed when the store can't save them.
@MainActor
protocol NoteDraftJournaling: AnyObject {
    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment]) throws
    func remove(noteID: UUID) throws
    func retireIfSaved(noteID: UUID, document: NoteDocument?, tags: [String]) throws
    func cancelPending(noteID: UUID) throws
    func retireIfTransferred(noteID: UUID, document: NoteDocument, tags: [String], copiedDigests: Set<String>) throws
    func entries() throws -> [(NoteDraftJournalEntry, [StagedNoteAttachment])]
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry]
}

extension NoteDraftJournaling {
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] {
        try entries().map { .valid($0.0, $0.1) }
    }

    /// Mock journals retain the same proof rule before forwarding to remove.
    func retireIfSaved(noteID: UUID, document: NoteDocument?, tags: [String]) throws {
        let entries = try recoveryEntries()
        guard entries.allSatisfy({ if case .valid = $0 { return true }; return false }) else {
            throw NoteDraftJournalError.unknownOwnership
        }
        guard let candidate = entries.compactMap({ item -> NoteDraftJournalEntry? in
            if case let .valid(entry, _) = item, entry.noteID == noteID { return entry }
            return nil
        }).first else {
            // A wrapper may be unable to prove removal even when its
            // enumeration found no row; preserve that failure signal.
            try remove(noteID: noteID)
            return
        }
        guard let document, candidate.pendingImport == nil,
              NoteContentCodec.decode(candidate.content).document == document,
              candidate.changedTags == nil || candidate.changedTags == tags,
              Set(candidate.staged.map(\.id)).isSubset(of: Set(document.attachmentIDs)) else {
            throw NoteDraftJournalError.unknownOwnership
        }
        try remove(noteID: noteID)
    }

    func cancelPending(noteID: UUID) throws { try remove(noteID: noteID) }

    func retireIfTransferred(noteID: UUID, document: NoteDocument, tags: [String],
                             copiedDigests: Set<String>) throws {
        let entries = try recoveryEntries()
        guard entries.allSatisfy({ if case .valid = $0 { return true }; return false }) else {
            throw NoteDraftJournalError.unknownOwnership
        }
        guard let candidate = entries.compactMap({ item -> NoteDraftJournalEntry? in
            if case let .valid(entry, _) = item, entry.noteID == noteID { return entry }
            return nil
        }).first else { return }
        guard candidate.pendingImport == nil,
              NoteContentCodec.decode(candidate.content).document == document,
              candidate.changedTags == nil || candidate.changedTags == tags,
              Set(candidate.staged.map(\.digest)).isSubset(of: copiedDigests) else {
            throw NoteDraftJournalError.unknownOwnership
        }
        try remove(noteID: noteID)
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
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard Int64(bytes.count) == meta.byteCount, digest == meta.digest else {
                    return .damaged("Recovery copy for \(entry.noteID.uuidString) has a damaged file: \(meta.filename).")
                }
                staged.append(StagedNoteAttachment(id: meta.id, filename: meta.filename,
                    contentTypeIdentifier: meta.contentTypeIdentifier, byteCount: meta.byteCount,
                    digest: meta.digest, data: bytes))
            }
            if let pending = entry.pendingImport {
                guard Set(pending.items.compactMap(\.stagedID)).isSubset(of: Set(entry.staged.map(\.id))) else {
                    return .damaged("Recovery copy for \(entry.noteID.uuidString) has unknown pending file ownership.")
                }
                return .pending(entry, staged)
            }
            return .valid(entry, staged)
        } catch {
            return .damaged("Recovery copy \(file.lastPathComponent) is incomplete or unreadable: \(error.localizedDescription)")
        }
    }

    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment]) throws {
        guard case .damaged = ownership(of: url(for: entry.noteID)) else {
            return try writeKnown(entry, staged: staged)
        }
        throw NoteDraftJournalError.unknownOwnership
    }

    private func writeKnown(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment]) throws {
        guard case .editable = NoteContentCodec.decode(entry.content),
              Set(entry.staged.map(\.id)).count == entry.staged.count,
              Set(entry.pendingImport?.items.compactMap(\.stagedID) ?? []).isSubset(of: Set(entry.staged.map(\.id))) else {
            throw NoteDraftJournalError.unknownOwnership
        }
        guard Set(entry.staged.map(\.id)) == Set(staged.map(\.id)), entry.staged.count == staged.count else {
            throw NoteDraftJournalError.incompleteStaging
        }
        for item in staged {
            let digest = SHA256.hash(data: item.data).map { String(format: "%02x", $0) }.joined()
            guard item.byteCount == Int64(item.data.count), item.digest == digest,
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
        try encoder.encode(entry).write(to: url(for: entry.noteID), options: .atomic)
        removeUnreferencedStagedFiles()
    }

    func remove(noteID: UUID) throws {
        let file = url(for: noteID)
        let state = ownership(of: file)
        switch state {
        case .absent: return
        case .damaged, .pending: throw NoteDraftJournalError.unknownOwnership
        case .retired, .valid: break
        }
        do {
            try fileManager.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already absent.
        }
        removeUnreferencedStagedFiles()
    }

    func retireIfSaved(noteID: UUID, document: NoteDocument?, tags: [String]) throws {
        switch ownership(of: url(for: noteID)) {
        case .absent: return
        case .retired: try remove(noteID: noteID)
        case let .valid(entry, _):
            guard let document,
                  NoteContentCodec.decode(entry.content).document == document,
                  entry.changedTags == nil || entry.changedTags == tags,
                  Set(entry.staged.map(\.id)).isSubset(of: Set(document.attachmentIDs)) else {
                throw NoteDraftJournalError.unknownOwnership
            }
            try remove(noteID: noteID)
        case .pending, .damaged: throw NoteDraftJournalError.unknownOwnership
        }
    }

    func cancelPending(noteID: UUID) throws {
        let file = url(for: noteID)
        switch ownership(of: file) {
        case .absent: return
        case .pending:
            try fileManager.removeItem(at: file)
            removeUnreferencedStagedFiles()
        case .valid, .retired, .damaged: throw NoteDraftJournalError.unknownOwnership
        }
    }

    func retireIfTransferred(noteID: UUID, document: NoteDocument, tags: [String],
                             copiedDigests: Set<String>) throws {
        switch ownership(of: url(for: noteID)) {
        case .absent: return
        case let .valid(entry, _):
            guard NoteContentCodec.decode(entry.content).document == document,
                  entry.changedTags == nil || entry.changedTags == tags,
                  Set(entry.staged.map(\.digest)).isSubset(of: copiedDigests) else {
                throw NoteDraftJournalError.unknownOwnership
            }
            try remove(noteID: noteID)
        case .pending, .damaged, .retired: throw NoteDraftJournalError.unknownOwnership
        }
    }

    func entries() throws -> [(NoteDraftJournalEntry, [StagedNoteAttachment])] {
        try recoveryEntries().compactMap {
            if case let .valid(entry, staged) = $0 { return (entry, staged) }
            return nil
        }
    }

    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let results: [NoteDraftRecoveryEntry] = files.compactMap { file in
            switch ownership(of: file) {
            case let .valid(entry, staged), let .pending(entry, staged): return .valid(entry, staged)
            case let .damaged(message): return .damaged(message)
            case .retired:
                try? fileManager.removeItem(at: file)
                return nil
            case .absent: return nil
            }
        }.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case let (.valid(left, _), .valid(right, _)): left.savedAt < right.savedAt
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
