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

    struct PendingImport: Codable, Equatable {
        struct Item: Codable, Equatable {
            let filename: String
            let contentTypeIdentifier: String
            let byteCount: Int64
            let stagedID: UUID?
            let pixelWidth: Double?
            let pixelHeight: Double?
            let failure: String?
        }
        let anchor: Int
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

    var errorDescription: String? {
        switch self {
        case .incompleteStaging: "The recovery copy has missing or damaged image bytes."
        case .conflictingStaging: "An earlier recovery copy owns different bytes at this image ID."
        }
    }
}

/// Where drafts are checkpointed when the store can't save them.
@MainActor
protocol NoteDraftJournaling: AnyObject {
    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment]) throws
    func remove(noteID: UUID) throws
    func entries() throws -> [(NoteDraftJournalEntry, [StagedNoteAttachment])]
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry]
}

extension NoteDraftJournaling {
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] {
        try entries().map { .valid($0.0, $0.1) }
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

    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment]) throws {
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
        let staged = (try? read(file))?.staged ?? []
        do {
            try fileManager.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already absent.
        }
        if !staged.isEmpty { removeUnreferencedStagedFiles() }
    }

    private func read(_ file: URL) throws -> NoteDraftJournalEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NoteDraftJournalEntry.self, from: Data(contentsOf: file))
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
            do {
                let data = try Data(contentsOf: file)
                // Older builds used a retired marker after a committed save.
                // It is not a draft and must never be replayed as one.
                if let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   values["retired"] as? Bool == true {
                    try? fileManager.removeItem(at: file)
                    return nil
                }
                let entry = try read(file)
                var staged: [StagedNoteAttachment] = []
                for meta in entry.staged {
                    let data = try Data(contentsOf: stagedDirectory.appendingPathComponent(meta.id.uuidString))
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard Int64(data.count) == meta.byteCount, digest == meta.digest else {
                        return .damaged("Recovery copy for \(entry.noteID.uuidString) has a damaged image: \(meta.filename).")
                    }
                    staged.append(StagedNoteAttachment(id: meta.id, filename: meta.filename,
                                                       contentTypeIdentifier: meta.contentTypeIdentifier,
                                                       byteCount: meta.byteCount, digest: meta.digest, data: data))
                }
                return .valid(entry, staged)
            } catch {
                return .damaged("Recovery copy \(file.lastPathComponent) is incomplete or unreadable: \(error.localizedDescription)")
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
            guard let entry = try? read(file) else { return }
            retained.formUnion(entry.staged.map(\.id))
        }
        for file in files {
            guard let id = UUID(uuidString: file.lastPathComponent), !retained.contains(id) else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}
