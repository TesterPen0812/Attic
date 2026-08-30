import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum AttachmentFileStoreError: LocalizedError, Equatable {
    case notAFile(URL)
    case inaccessible(URL, String)
    case tooManyAttachments
    case attachmentTooLarge(URL, Int64)
    case noteTooLarge
    case changedDuringRead(URL)
    case invalidDigest
    case invalidFilename(String)
    case coordinationFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case let .notAFile(url):
            "Only regular files can be attached: \(url.lastPathComponent)"
        case let .inaccessible(url, reason):
            "Unable to read \(url.lastPathComponent): \(reason)"
        case .tooManyAttachments:
            "A note can contain at most 20 attachments."
        case let .attachmentTooLarge(url, bytes):
            "\(url.lastPathComponent) is too large (\(bytes) bytes; limit is 15 MiB)."
        case .noteTooLarge:
            "Attachments for a note cannot exceed 100 MiB."
        case let .changedDuringRead(url):
            "The file changed while it was being attached: \(url.lastPathComponent)"
        case .invalidDigest:
            "The attachment digest is invalid."
        case let .invalidFilename(filename):
            "The attachment filename is invalid: \(filename)"
        case let .coordinationFailed(url, reason):
            "Unable to coordinate a read of \(url.lastPathComponent): \(reason)"
        }
    }
}

/// Owns the private materialization tree. All filesystem work is serialized so
/// a refresh, import, preview, and delete cannot race over the same bytes.
actor AttachmentFileStore {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = (rootURL ?? Self.defaultRootURL(fileManager: fileManager))
            .standardizedFileURL
    }

    func prepare() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: stagingRootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: thumbnailRootURL,
            withIntermediateDirectories: true
        )
    }

    func importFiles(
        _ urls: [URL],
        baseSortIndex: Int64,
        existingCount: Int,
        existingBytes: Int64,
        progress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> [ImportedAttachment] {
        try Task.checkCancellation()
        guard existingCount >= 0,
              existingCount <= AttachmentLimits.maxAttachmentsPerNote,
              urls.count <= AttachmentLimits.maxAttachmentsPerNote - existingCount else {
            throw AttachmentFileStoreError.tooManyAttachments
        }
        guard existingBytes >= 0,
              existingBytes <= AttachmentLimits.maxBytesPerNote else {
            throw AttachmentFileStoreError.noteTooLarge
        }

        try prepare()
        let batchRoot = stagingRootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: batchRoot, withIntermediateDirectories: true)
        var finalDirectories: [URL] = []

        do {
            var imported: [ImportedAttachment] = []
            var totalBytes = existingBytes

            for (offset, sourceURL) in urls.enumerated() {
                try Task.checkCancellation()
                let result = try importOne(
                    sourceURL,
                    stagingURL: batchRoot.appendingPathComponent("\(offset).stage"),
                    finalDirectories: &finalDirectories,
                    sortIndex: baseSortIndex + Int64(offset),
                    totalBytes: &totalBytes
                )
                imported.append(result)
                await progress?(offset + 1, urls.count)
            }

            try? fileManager.removeItem(at: batchRoot)
            return imported
        } catch {
            for directory in finalDirectories {
                try? fileManager.removeItem(at: directory)
                let idDirectory = directory.deletingLastPathComponent()
                if fileManager.fileExists(atPath: idDirectory.path),
                   (try? fileManager.contentsOfDirectory(atPath: idDirectory.path))?.isEmpty == true {
                    try? fileManager.removeItem(at: idDirectory)
                }
            }
            try? fileManager.removeItem(at: batchRoot)
            throw error
        }
    }

    func materializedURL(for reference: AttachmentFileReference) throws -> URL {
        let directory = try validatedDirectory(for: reference)
        let filename = Self.sanitizedFilename(reference.filename)
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\") else {
            throw AttachmentFileStoreError.invalidFilename(reference.filename)
        }

        let url = directory.appendingPathComponent(filename, isDirectory: false)
            .standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/") else {
            throw AttachmentFileStoreError.invalidFilename(reference.filename)
        }
        return url
    }

    func ensureMaterialized(_ reference: AttachmentFileReference) throws -> URL? {
        if let existingURL = try verifiedMaterializedURL(for: reference) {
            return existingURL
        }
        guard let payload = reference.payload else { return nil }
        if let byteCount = reference.byteCount, Int64(payload.count) != byteCount {
            throw AttachmentFileStoreError.changedDuringRead(
                URL(fileURLWithPath: reference.filename)
            )
        }
        guard SHA256.hash(data: payload).hexString == reference.digest else {
            throw AttachmentFileStoreError.invalidDigest
        }
        let url = try materializedURL(for: reference)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        try payload.write(to: url, options: .atomic)
        return url
    }

    func removeMaterializations(_ references: [AttachmentFileReference]) throws {
        for reference in references {
            let directory = try validatedDirectory(for: reference)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            let idDirectory = directory.deletingLastPathComponent()
            if fileManager.fileExists(atPath: idDirectory.path),
               (try? fileManager.contentsOfDirectory(atPath: idDirectory.path))?.isEmpty == true {
                try? fileManager.removeItem(at: idDirectory)
            }
        }
    }

    /// Inventories the app-owned materialization tree without touching model
    /// payloads. A refresh therefore scales with filesystem metadata rather
    /// than eagerly loading and hashing every attachment on the main actor.
    func reconcileMetadata(
        _ references: [AttachmentFileReference]
    ) throws -> AttachmentReconciliationReport {
        try prepare()
        var expected = Set<String>()
        var needsMaterialization: [AttachmentFileReference] = []
        var failures: [AttachmentReconciliationFailure] = []

        for reference in references {
            do {
                _ = try materializedURL(for: reference)
                expected.insert("\(reference.id.uuidString)/\(reference.digest.lowercased())")
                if try existingMaterializedURL(for: reference) == nil {
                    needsMaterialization.append(reference)
                }
            } catch {
                failures.append(.init(
                    attachmentID: reference.id,
                    message: error.localizedDescription
                ))
            }
        }

        try cleanOrphans(expected: expected)
        return AttachmentReconciliationReport(
            needsMaterialization: needsMaterialization,
            failures: failures
        )
    }

    /// Repairs each requested replica independently so one malformed payload
    /// cannot prevent unrelated attachments or cleanup from completing.
    func repairMaterializations(
        _ references: [AttachmentFileReference]
    ) -> [AttachmentReconciliationFailure] {
        var failures: [AttachmentReconciliationFailure] = []
        for reference in references {
            do {
                _ = try ensureMaterialized(reference)
            } catch {
                failures.append(.init(
                    attachmentID: reference.id,
                    message: error.localizedDescription
                ))
            }
        }
        return failures
    }

    /// Compatibility entry point used by focused storage tests and callers
    /// that already have payloads. New refresh paths should call the two-phase
    /// metadata and repair APIs directly.
    func reconcile(_ references: [AttachmentFileReference]) throws {
        let report = try reconcileMetadata(references)
        let neededKeys = Set(report.needsMaterialization.map {
            "\($0.id.uuidString)/\($0.digest.lowercased())"
        })
        let repairs = references.filter {
            neededKeys.contains("\($0.id.uuidString)/\($0.digest.lowercased())")
        }
        _ = repairMaterializations(repairs)
    }

    func existingMaterializedURL(
        for reference: AttachmentFileReference
    ) throws -> URL? {
        let url = try materializedURL(for: reference)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { return nil }
        if let byteCount = reference.byteCount,
           Int64(values.fileSize ?? -1) != byteCount {
            return nil
        }
        return url
    }

    /// Performs the expensive content check only when a file is about to be
    /// used. Routine reconciliation intentionally stops at metadata inventory.
    func verifiedMaterializedURL(
        for reference: AttachmentFileReference
    ) throws -> URL? {
        guard let url = try existingMaterializedURL(for: reference) else {
            return nil
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard SHA256.hash(data: data).hexString == reference.digest else {
            return nil
        }
        return url
    }

    private func cleanOrphans(expected: Set<String>) throws {
        let now = Date()
        for child in try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            if child.lastPathComponent == stagingRootName || child.lastPathComponent == thumbnailRootName {
                continue
            }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                try? fileManager.removeItem(at: child)
                continue
            }
            for digestDirectory in try fileManager.contentsOfDirectory(at: child, includingPropertiesForKeys: nil) {
                let key = "\(child.lastPathComponent)/\(digestDirectory.lastPathComponent.lowercased())"
                guard !expected.contains(key) else { continue }
                try? fileManager.removeItem(at: digestDirectory)
            }
            if (try? fileManager.contentsOfDirectory(atPath: child.path))?.isEmpty == true {
                try? fileManager.removeItem(at: child)
            }
        }

        for staging in (try? fileManager.contentsOfDirectory(
            at: stagingRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? [] {
            let modified = (try? staging.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > 24 * 60 * 60 {
                try? fileManager.removeItem(at: staging)
            }
        }

        // Thumbnail files are disposable. Keeping the cache root versioned
        // makes cleanup deterministic even when a future thumbnail provider
        // starts writing there.
        for item in (try? fileManager.contentsOfDirectory(at: thumbnailRootURL, includingPropertiesForKeys: nil)) ?? [] {
            if item.lastPathComponent != "v1" {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    private func importOne(
        _ sourceURL: URL,
        stagingURL: URL,
        finalDirectories: inout [URL],
        sortIndex: Int64,
        totalBytes: inout Int64
    ) throws -> ImportedAttachment {
        let sourceURL = sourceURL.standardizedFileURL

        // Finder/file-provider URLs can be inaccessible until their temporary
        // security scope is active. Start the scope before even reading file
        // attributes, and balance only a successful start.
        let startedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        } catch {
            throw AttachmentFileStoreError.inaccessible(sourceURL, error.localizedDescription)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AttachmentFileStoreError.notAFile(sourceURL)
        }
        let expectedByteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard expectedByteCount >= 0,
              expectedByteCount <= AttachmentLimits.maxBytesPerAttachment else {
            throw AttachmentFileStoreError.attachmentTooLarge(sourceURL, expectedByteCount)
        }
        guard totalBytes <= AttachmentLimits.maxBytesPerNote - expectedByteCount else {
            throw AttachmentFileStoreError.noteTooLarge
        }

        var coordinationError: NSError?
        var readError: Error?
        var byteCount: Int64 = 0
        var digest = SHA256()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                fileManager.createFile(atPath: stagingURL.path, contents: nil)
                let input = try FileHandle(forReadingFrom: coordinatedURL)
                let output = try FileHandle(forWritingTo: stagingURL)
                defer {
                    try? input.close()
                    try? output.close()
                }
                while true {
                    try Task.checkCancellation()
                    let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    byteCount += Int64(chunk.count)
                    guard byteCount <= AttachmentLimits.maxBytesPerAttachment else {
                        throw AttachmentFileStoreError.attachmentTooLarge(sourceURL, byteCount)
                    }
                    digest.update(data: chunk)
                    try output.write(contentsOf: chunk)
                }
            } catch {
                readError = error
            }
        }
        if let coordinationError {
            throw AttachmentFileStoreError.coordinationFailed(sourceURL, coordinationError.localizedDescription)
        }
        if let readError { throw readError }
        guard byteCount == expectedByteCount else {
            throw AttachmentFileStoreError.changedDuringRead(sourceURL)
        }
        let digestString = digest.finalize().hexString
        let filename = Self.sanitizedFilename(sourceURL.lastPathComponent)
        let contentType = (UTType(filenameExtension: sourceURL.pathExtension) ?? .data).identifier
        let attachmentID = UUID()
        let reference = AttachmentFileReference(
            id: attachmentID,
            digest: digestString,
            filename: filename,
            payload: nil
        )
        let finalDirectory = try validatedDirectory(for: reference)
        // Register the directory before any filesystem operation that can
        // partially succeed. If directory creation or the move fails, the
        // batch rollback can still remove the empty directory it created.
        finalDirectories.append(finalDirectory)
        try fileManager.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        let finalURL = finalDirectory.appendingPathComponent(filename)
        try fileManager.moveItem(at: stagingURL, to: finalURL)
        totalBytes += byteCount

        let payload = try Data(contentsOf: finalURL, options: .mappedIfSafe)
        return ImportedAttachment(
            id: attachmentID,
            filename: filename,
            contentTypeIdentifier: contentType,
            byteCount: byteCount,
            sortIndex: sortIndex,
            digest: digestString,
            createdAt: Date(),
            payload: payload
        )
    }

    private func validatedDirectory(for reference: AttachmentFileReference) throws -> URL {
        guard UUID(uuidString: reference.id.uuidString) != nil,
              reference.digest.count == 64,
              reference.digest.allSatisfy({ $0.isHexDigit }) else {
            throw AttachmentFileStoreError.invalidDigest
        }
        let directory = rootURL
            .appendingPathComponent(reference.id.uuidString, isDirectory: true)
            .appendingPathComponent(reference.digest.lowercased(), isDirectory: true)
            .standardizedFileURL
        guard directory.path.hasPrefix(rootURL.path + "/") else {
            throw AttachmentFileStoreError.invalidDigest
        }
        return directory
    }

    private var stagingRootName: String { ".staging" }
    private var thumbnailRootName: String { "Thumbnails" }
    private var stagingRootURL: URL { rootURL.appendingPathComponent(stagingRootName, isDirectory: true) }
    private var thumbnailRootURL: URL { rootURL.appendingPathComponent(thumbnailRootName, isDirectory: true) }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("Attic", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    static func sanitizedFilename(_ filename: String) -> String {
        let source = filename.isEmpty ? "attachment" : filename
        let cleaned = source.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" {
                return "_"
            }
            return Character(scalar)
        }
        let value = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = value.isEmpty || value == "." || value == ".." ? "attachment" : value
        guard fallback.utf8.count > AttachmentLimits.maxFilenameUTF8Bytes else { return fallback }

        let ns = fallback as NSString
        let ext = ns.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let available = max(1, AttachmentLimits.maxFilenameUTF8Bytes - suffix.utf8.count)
        var base = ns.deletingPathExtension
        while base.utf8.count > available, !base.isEmpty {
            base.removeLast()
        }
        return (base.isEmpty ? "attachment" : base) + suffix
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
