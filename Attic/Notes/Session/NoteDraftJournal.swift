import Foundation

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

    var noteID: UUID
    var isPersisted: Bool
    var baseRevisionID: UUID?
    var content: Data
    var selectionLocation: Int
    var selectionLength: Int
    var staged: [StagedFile]
    var savedAt: Date
}

/// Where drafts are checkpointed when the store can't save them.
@MainActor
protocol NoteDraftJournaling: AnyObject {
    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment]) throws
    func remove(noteID: UUID) throws
    func entries() throws -> [(NoteDraftJournalEntry, [StagedNoteAttachment])]
}

/// One file per note (`<id>.json`) plus staged image bytes
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
        try fileManager.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        for item in staged {
            let file = stagedDirectory.appendingPathComponent(item.id.uuidString)
            if !fileManager.fileExists(atPath: file.path) {
                try item.data.write(to: file, options: .atomic)
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: url(for: entry.noteID), options: .atomic)
    }

    func remove(noteID: UUID) throws {
        let file = url(for: noteID)
        let staged = (try? read(file))?.staged ?? []
        do {
            try fileManager.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already absent.
        }
        for item in staged {
            try? fileManager.removeItem(at: stagedDirectory.appendingPathComponent(item.id.uuidString))
        }
    }

    private func read(_ file: URL) throws -> NoteDraftJournalEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NoteDraftJournalEntry.self, from: Data(contentsOf: file))
    }

    func entries() throws -> [(NoteDraftJournalEntry, [StagedNoteAttachment])] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try files.map { file in
            let entry = try read(file)
            let staged = entry.staged.compactMap { meta -> StagedNoteAttachment? in
                guard let data = try? Data(contentsOf: stagedDirectory.appendingPathComponent(meta.id.uuidString)) else { return nil }
                return StagedNoteAttachment(id: meta.id, filename: meta.filename, contentTypeIdentifier: meta.contentTypeIdentifier,
                                            byteCount: meta.byteCount, digest: meta.digest, data: data)
            }
            return (entry, staged)
        }.sorted { $0.0.savedAt < $1.0.savedAt }
    }
}
