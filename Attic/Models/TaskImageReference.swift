import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A task attachment: an image or a general file. The type name and its
/// Codable keys predate general files and stay unchanged, so stored tasks and
/// drag payloads from earlier builds still decode.
struct TaskImageReference: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let digest: String
    let contentTypeIdentifier: String
    let byteCount: Int64

    var contentType: UTType { UTType(contentTypeIdentifier) ?? .data }
    var isImage: Bool { contentType.conforms(to: .image) }

    var fileReference: AttachmentFileReference {
        AttachmentFileReference(id: id, digest: digest, filename: filename, byteCount: byteCount, payload: nil)
    }
}

/// An attachment a task already holds, with the top-level task that owns it
/// (a legacy subtask attachment belongs to the subtask's parent).
struct TaskAttachmentSource: Equatable, Sendable {
    let reference: TaskImageReference
    let ownerID: UUID
}

/// Private local attachment files are separate from the Notes cache so its
/// reconciliation cannot delete task attachments. File work stays off the UI
/// actor. The directory name predates general files and stays for existing data.
actor TaskImageFiles {
    static let shared = TaskImageFiles()
    let files: AttachmentFileStore
    private var thumbnailCache: [String: Data] = [:]

    init(rootURL: URL? = nil) {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attic/TaskImages", isDirectory: true)
        files = AttachmentFileStore(rootURL: root)
    }

    /// Copies images and general files into private storage. Anything typed
    /// as an image must decode as one; other files are kept as regular files.
    /// Nothing is read back into memory: images are validated one at a time
    /// from their private copy, which ImageIO reads incrementally.
    func importAttachments(_ urls: [URL], existing: [TaskImageReference]) async throws -> [TaskImageReference] {
        let imported = try await files.importFiles(urls, baseSortIndex: Int64(existing.count),
            existingCount: existing.count, existingBytes: existing.reduce(0) { $0 + $1.byteCount },
            includePayload: false)
        let references = imported.map {
            TaskImageReference(id: $0.id, filename: $0.filename, digest: $0.digest,
                               contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount)
        }
        for reference in references where reference.isImage {
            guard let url = try? await files.materializedURL(for: reference.fileReference),
                  Self.decodesAsImage(url) else {
                await remove(references)
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return references
    }

    /// New private copies of attachments Attic already holds (a card dropped
    /// on another task). Each copy gets its own identity and directory, so
    /// removing either attachment never deletes the other's bytes. Sources
    /// are read only from their digest-verified private file; a copy whose
    /// bytes don't match its source's digest is removed and nothing attaches.
    /// The recorded type carries over.
    func importCopies(of sources: [TaskImageReference], existing: [TaskImageReference]) async throws -> [TaskImageReference] {
        var urls: [URL] = []
        for source in sources {
            guard let url = try? await verifiedURL(for: source) else { throw TaskDropError.attachmentUnavailable }
            urls.append(url)
        }
        let copies = try await importAttachments(urls, existing: existing)
        guard copies.map({ $0.digest.lowercased() }) == sources.map({ $0.digest.lowercased() }) else {
            await remove(copies)
            throw TaskDropError.attachmentUnavailable
        }
        return zip(copies, sources).map { copy, source in
            TaskImageReference(id: copy.id, filename: copy.filename, digest: copy.digest,
                               contentTypeIdentifier: source.contentTypeIdentifier, byteCount: copy.byteCount)
        }
    }

    /// Launch-time cleanup of private copies no task references, such as a
    /// composer's pending items when Attic quit before the task was added.
    /// See `AttachmentFileStore.removeUnreferencedMaterializations`.
    func removeUnreferenced(keeping referencedIDs: Set<UUID>, modifiedBefore cutoff: Date, limit: Int) async -> Int {
        let removed = await files.removeUnreferencedMaterializations(
            keeping: referencedIDs, modifiedBefore: cutoff, limit: limit
        )
        if removed > 0 { thumbnailCache.removeAll() }
        return removed
    }

    /// The same check as before (a readable image source with at least one
    /// image), without caching decoded pixels.
    nonisolated static func decodesAsImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    /// The verified private copy, for Quick Look and dragging out (receivers
    /// get their own copy). Never handed to another app to open in place.
    func verifiedURL(for reference: TaskImageReference) async throws -> URL? {
        try await files.verifiedMaterializedURL(for: reference.fileReference)
    }

    /// A disposable read-only copy for opening in another app. The private
    /// copy is the attachment's only bytes and is digest-checked on every use,
    /// so an editor saving over it would make the attachment unusable. Edits
    /// to this copy never reach Attic, and read-only makes that visible in
    /// the editor instead of silently discarding changes.
    func openableCopy(for reference: TaskImageReference) async throws -> URL? {
        // A missing, changed or invalid private copy reads as unavailable;
        // only a failure to make the copy throws.
        guard let source = try? await files.verifiedMaterializedURL(for: reference.fileReference) else { return nil }
        let copy = try Self.disposableDirectory()
            .appendingPathComponent(AttachmentFileStore.sanitizedFilename(reference.filename))
        try FileManager.default.copyItem(at: source, to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: copy.path)
        return copy
    }

    func remove(_ references: [TaskImageReference]) async {
        try? await files.removeMaterializations(references.map(\.fileReference))
    }

    func thumbnail(_ reference: TaskImageReference, pixels: Int = 96) async throws -> Data? {
        let key = "\(reference.digest)-\(pixels)"
        if let cached = thumbnailCache[key] { return cached }
        guard reference.isImage else { return nil }
        guard let url = try await files.verifiedMaterializedURL(for: reference.fileReference) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(512, pixels),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        if thumbnailCache.count >= 64, let first = thumbnailCache.keys.first { thumbnailCache.removeValue(forKey: first) }
        thumbnailCache[key] = data as Data
        return data as Data
    }

    /// A fresh directory under the temporary exports root. Only these
    /// disposable exports are pruned (after a day), never durable attachments.
    private static func disposableDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticTaskExports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in old where ((try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture) < Date().addingTimeInterval(-86400) {
            try? FileManager.default.removeItem(at: url)
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func export(title: String, references: [TaskImageReference]) async throws -> URL {
        let sanitized = String(AttachmentFileStore.sanitizedFilename(title).prefix(70))
        let name = ["", ".", ".."].contains(sanitized) ? "Task" : sanitized
        let directory = try Self.disposableDirectory()
            .appendingPathComponent(name.isEmpty ? "Task" : name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try title.write(to: directory.appendingPathComponent("Task.txt"), atomically: true, encoding: .utf8)
        for (index, reference) in references.enumerated() {
            guard let source = try await files.verifiedMaterializedURL(for: reference.fileReference) else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("\(index + 1)-\(AttachmentFileStore.sanitizedFilename(reference.filename))"))
        }
        return directory
    }
}
