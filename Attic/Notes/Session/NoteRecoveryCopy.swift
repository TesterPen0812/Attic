import Foundation

/// Everything a recovery copy holds, gathered on the main actor and handed
/// to the file writer as plain values.
struct NoteRecoverySnapshot: Sendable, Equatable {
    var noteID: UUID
    var title: String
    /// The note in Attic's own stored format (`NoteContentCodec`): blocks,
    /// checklists, dates, image references, nothing flattened.
    var content: Data
    /// The same note as Markdown, for reading in any other app.
    var markdown: String
    var tags: [String]
    /// Why the note is only in memory or not saved, as the status said it.
    var reason: String
    var savedAt: Date
    /// Images the note shows whose bytes could be read.
    var attachments: [StagedNoteAttachment]
    /// Images the note shows whose bytes could not be read now.
    var unavailableAttachmentIDs: [UUID]
}

/// Save Recovery Copy…: a folder, not a single file, so nothing has to be
/// flattened to fit.
///
///     <name>/
///         README.txt        what this is and how to use it
///         note.json         the note in Attic's stored format (structure)
///         note.md           the note as Markdown (text, readable anywhere)
///         attachments/      the images the note shows, as the original files
///         manifest.json     ids, tags, image list, what could not be read
///
/// Why a folder: the note is structured (checklists, dates, images), and a
/// text file would lose that; a single archive would need a compressor and
/// hide the images from Finder. A folder keeps the note's real format next
/// to the images as ordinary files, opens in Finder and any editor, and can
/// be read back by decoding `note.json` and matching `manifest.json`'s image
/// ids to the files, which is exactly what a later import needs.
///
/// The folder is built in a scratch folder on the destination's own volume
/// and moved into place whole, so a failure leaves nothing half-written, and
/// an existing folder the person chose to replace is replaced only once the
/// new one is complete. There is no other place to build it: when the
/// destination's volume offers no scratch folder, the copy fails and
/// publishes nothing (a folder built elsewhere would be copied across
/// volumes at the end, and an interruption would leave it half there).
enum NoteRecoveryCopy {
    static let noteFile = "note.json"
    static let markdownFile = "note.md"
    static let manifestFile = "manifest.json"
    static let readmeFile = "README.txt"
    static let attachmentsFolder = "attachments"
    static let formatName = "com.taha.Attic.note-recovery-copy"

    struct Manifest: Codable, Equatable {
        struct Image: Codable, Equatable {
            var id: UUID
            var filename: String
            var contentType: String
            var byteCount: Int64
            var digest: String
            /// Path inside the folder.
            var file: String
        }
        var format: String
        var version: Int
        var noteID: UUID
        var title: String
        var savedAt: Date
        var reason: String
        var tags: [String]
        var noteFile: String
        var markdownFile: String
        var images: [Image]
        var unavailableImageIDs: [UUID]
    }

    /// "Groceries recovery copy" for the save panel's name field.
    static func suggestedName(title: String) -> String {
        let cleaned = safeName(title)
        let base = cleaned.isEmpty ? String(localized: "Untitled note") : String(cleaned.prefix(60))
        return String(localized: "\(base) recovery copy")
    }

    /// Why nothing was written: there was no scratch folder on the
    /// destination's volume to build the copy in.
    struct NoStagingError: LocalizedError {
        var errorDescription: String? {
            String(localized: "There is no safe place on that disk to build the copy, so nothing was saved. Choose another location.")
        }
    }

    /// Writes the folder at `destination`. Throws with nothing left behind
    /// (a replaced folder is untouched until the new one is complete).
    /// `onSameVolume` is the volume check, a parameter so a test can play a
    /// destination on another volume.
    static func write(_ snapshot: NoteRecoverySnapshot, to destination: URL,
                      fileManager: FileManager = .default,
                      onSameVolume: (URL, URL) -> Bool = NoteRecoveryCopy.onSameVolume) throws {
        // Built in a scratch folder on the destination's volume, then moved.
        let scratch = try scratchFolder(for: destination, fileManager: fileManager, onSameVolume: onSameVolume)
        defer { try? fileManager.removeItem(at: scratch) }
        let staging = scratch.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)

        var images: [Manifest.Image] = []
        if !snapshot.attachments.isEmpty {
            let folder = staging.appendingPathComponent(attachmentsFolder, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            var used = Set<String>()
            for attachment in snapshot.attachments {
                let name = uniqueName(attachment.filename, among: &used)
                try attachment.data.write(to: folder.appendingPathComponent(name), options: .atomic)
                images.append(Manifest.Image(id: attachment.id, filename: attachment.filename,
                                             contentType: attachment.contentTypeIdentifier,
                                             byteCount: attachment.byteCount, digest: attachment.digest,
                                             file: "\(attachmentsFolder)/\(name)"))
            }
        }
        let manifest = Manifest(format: formatName, version: 1, noteID: snapshot.noteID, title: snapshot.title,
                                savedAt: snapshot.savedAt, reason: snapshot.reason, tags: snapshot.tags,
                                noteFile: noteFile, markdownFile: markdownFile, images: images,
                                unavailableImageIDs: snapshot.unavailableAttachmentIDs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try snapshot.content.write(to: staging.appendingPathComponent(noteFile), options: .atomic)
        try Data(snapshot.markdown.utf8).write(to: staging.appendingPathComponent(markdownFile), options: .atomic)
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(manifestFile), options: .atomic)
        try Data(readme(for: manifest).utf8).write(to: staging.appendingPathComponent(readmeFile), options: .atomic)

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    /// What the README says. Plain text, so it reads without Attic.
    static func readme(for manifest: Manifest) -> String {
        let saved = manifest.savedAt.formatted(date: .abbreviated, time: .shortened)
        var text = """
        Attic recovery copy
        ===================

        This folder is a copy of a note that Attic could not save to its own
        library when it was made (\(saved)). It changes nothing in Attic.

        Reason Attic gave: \(manifest.reason)

        What is in it
        - note.md: the note's text as Markdown. Open it in any text editor.
        - note.json: the whole note in Attic's own format, with its structure
          (checklists, dates, image positions). This is the file to keep if
          you want the note restored exactly.
        - attachments/: the images the note shows, as ordinary files.
        - manifest.json: the note's id, tags, and which file is which image
          (each image's id, name, type, size and SHA-256 digest).

        """
        if !manifest.unavailableImageIDs.isEmpty {
            let ids = manifest.unavailableImageIDs.map(\.uuidString).joined(separator: ", ")
            text += """

            Not included
            \(manifest.unavailableImageIDs.count) image(s) could not be read when this copy was made, so their
            files are missing here: \(ids)

            """
        }
        text += """

        To bring it back: copy the text from note.md into a new Attic note,
        and add the images from attachments/. To restore it exactly, keep
        note.json and manifest.json together with attachments/.
        """
        return text
    }

    // MARK: Files

    /// A scratch folder on the destination's own volume, or a throw.
    /// First the system's replacement directory for that volume (the one a
    /// sandboxed app may use), then a hidden sibling of the destination.
    /// Never the general temporary folder: it can be another volume.
    private static func scratchFolder(for destination: URL, fileManager: FileManager,
                                      onSameVolume: (URL, URL) -> Bool) throws -> URL {
        let parent = destination.deletingLastPathComponent()
        if let url = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: parent, create: true) {
            if onSameVolume(url, parent) { return url }
            try? fileManager.removeItem(at: url)
        }
        let sibling = parent.appendingPathComponent(".AtticRecovery-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: sibling, withIntermediateDirectories: false)
        } catch {
            throw NoStagingError()
        }
        guard onSameVolume(sibling, parent) else {
            try? fileManager.removeItem(at: sibling)
            throw NoStagingError()
        }
        return sibling
    }

    /// Whether two existing locations are on the same volume.
    static func onSameVolume(_ first: URL, _ second: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let a = try? first.resourceValues(forKeys: keys).volumeIdentifier,
              let b = try? second.resourceValues(forKeys: keys).volumeIdentifier else { return false }
        return a.isEqual(b)
    }

    /// A file name that is safe in a folder and not already used there
    /// ("photo.png", then "photo 2.png").
    static func uniqueName(_ filename: String, among used: inout Set<String>) -> String {
        var name = safeName(filename)
        if name.isEmpty { name = "attachment" }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = name
        var counter = 2
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static func safeName(_ text: String) -> String {
        var cleaned = String(text.map { "/:\\\0".contains($0) || $0.isNewline ? "-" : $0 })
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned
    }
}
