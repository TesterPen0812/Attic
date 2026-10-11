import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a drag over a task surface carries, decided from type conformance
/// alone so a destination can accept or refuse before anything loads.
enum TaskDropContent: Equatable {
    /// An Attic task row: reorder and status rules, never an attachment,
    /// even though a row with attachments also exports a folder.
    case task
    /// A card dragged out of an Attic gallery. Another task (or the main
    /// composer) receives its own private copy; the card's own owner refuses
    /// it, so releasing it back over its panel never duplicates it.
    case attachmentCard
    /// Files or images from Finder, another app, or a file promise.
    case files
    case unsupported

    /// Marks a gallery card drag (own process only). Declared in Info.plist.
    static let attachmentCardType = UTType(exportedAs: "com.taha.attic.task-attachment")

    /// File URLs, plus content that apps commonly provide or promise without
    /// a file URL (Photos, Mail, browsers).
    static let fileTypes: [UTType] = [.fileURL, .image, .pdf, .movie, .audio, .archive, .spreadsheet, .presentation]

    /// Never files, although they conform to `public.data`: text selections
    /// (including RTF, CSV, vCard and calendar text) and links.
    static let nonFileTypes: [UTType] = [.text, .url]

    /// Attic's own in-app drag markers. They conform to `public.data` but
    /// carry no file, so the general-file rule must not read them as one.
    static let internalMarkerTypes: [UTType] = [
        TaskDragPayload.internalTaskType,
        attachmentCardType,
        UTType(exportedAs: NoteEditorEngine.fragmentType.rawValue)
    ]

    /// What task drop destinations register: the listed file types, general
    /// data (Word, Pages, Mail messages, …; classified below) and cards.
    static let dropTypes: [UTType] = [attachmentCardType] + fileTypes + [.data]

    /// A task drag first, then a card; then files: a listed type, or any
    /// other data that is not text, a link or an Attic marker. Folders are
    /// not data, so a promised folder is never offered.
    static func classify(_ conforms: ([UTType]) -> Bool) -> TaskDropContent {
        if conforms([TaskDragPayload.internalTaskType]) { return .task }
        if conforms([attachmentCardType]) { return .attachmentCard }
        if conforms(fileTypes) { return .files }
        if conforms([.data]), !conforms(nonFileTypes), !conforms(internalMarkerTypes) { return .files }
        return .unsupported
    }

    static func classify(_ info: DropInfo) -> TaskDropContent {
        classify { info.hasItemsConforming(to: $0) }
    }

    /// The same rule for a single provider.
    static func classify(_ provider: NSItemProvider) -> TaskDropContent {
        classify { types in types.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) } }
    }

    /// The providers a destination hands on for `content`: exactly the ones
    /// the rule above accepted.
    static func providers(for content: TaskDropContent, in info: DropInfo) -> [NSItemProvider] {
        switch content {
        case .files: info.itemProviders(for: dropTypes).filter { classify($0) == .files }
        case .attachmentCard: info.itemProviders(for: [attachmentCardType])
        case .task, .unsupported: []
        }
    }
}

/// Files ready to import. `urls` may point at user originals (Finder), which
/// are only read. Content that exists only for the drop is written once into
/// `ownedDirectory`, the one thing `discard` removes.
struct TaskAttachmentStaging: Sendable {
    var urls: [URL] = []
    private(set) var ownedDirectory: URL?

    init(urls: [URL] = []) {
        self.urls = urls
    }

    static let ownedRootName = "AtticTaskDrops"
    static var ownedRootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(ownedRootName, isDirectory: true)
    }

    mutating func makeOwnedDirectory() throws -> URL {
        if let ownedDirectory { return ownedDirectory }
        let directory = Self.ownedRootURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ownedDirectory = directory
        return directory
    }

    func discard() {
        guard let ownedDirectory else { return }
        try? FileManager.default.removeItem(at: ownedDirectory)
    }

    /// Owned drop directories that a quit or crash left behind; an import
    /// discards its own. Only direct children of the owned root that were
    /// created and last modified before `cutoff` are removed, so a drop
    /// staging right now is never touched.
    @discardableResult
    static func removeAbandoned(modifiedBefore cutoff: Date, in root: URL = ownedRootURL) -> Int {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )) ?? []
        var removed = 0
        for child in children {
            // Never act through a link planted in the owned root.
            guard (try? FileManager.default.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType)
                    != .typeSymbolicLink,
                  let values = try? child.resourceValues(forKeys: keys),
                  let created = values.creationDate, let modified = values.contentModificationDate,
                  created < cutoff, modified < cutoff,
                  (try? FileManager.default.removeItem(at: child)) != nil else { continue }
            removed += 1
        }
        return removed
    }
}

enum TaskDropError: LocalizedError {
    case unsupported
    /// A dropped card no longer matches an attachment Attic holds.
    case attachmentUnavailable
    /// A card released over the task that already owns it.
    case alreadyAttached

    var errorDescription: String? {
        switch self {
        case .unsupported: "Only files and images can be attached."
        case .attachmentUnavailable: "The attachment is no longer available."
        case .alreadyAttached: "That attachment already belongs to this task."
        }
    }
}

/// Turns dropped item providers into importable files, one provider at a
/// time. A file URL is used as is. Promised or in-memory content is loaded by
/// the system into a temporary file that exists only during its callback, so
/// it is copied into the staging's owned directory under its own subfolder
/// (equal names never collide) with an extension matching its type.
enum TaskDroppedFiles {
    /// Throws only after discarding its own directory, as `stage` closures
    /// passed to the store and the composer must.
    static func stage(_ providers: [NSItemProvider]) async throws -> TaskAttachmentStaging {
        guard !providers.isEmpty else { throw TaskDropError.unsupported }
        // Refuse an oversized batch before loading anything.
        guard providers.count <= AttachmentLimits.maxAttachmentsPerNote else {
            throw AttachmentFileStoreError.tooManyAttachments
        }
        var staging = TaskAttachmentStaging()
        do {
            for (index, provider) in providers.enumerated() {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    staging.urls.append(try await fileURL(from: provider))
                } else if let type = fileContentType(of: provider) {
                    let destination = try staging.makeOwnedDirectory()
                        .appendingPathComponent("\(index)", isDirectory: true)
                    staging.urls.append(try await copyFile(of: provider, type: type, into: destination))
                } else {
                    throw TaskDropError.unsupported
                }
            }
        } catch {
            staging.discard()
            throw error
        }
        return staging
    }

    /// The provider's most faithful registered type that is file content: a
    /// listed type, otherwise (for a provider the drop rule accepts) its
    /// first declared data type, so a promised document keeps a real
    /// extension. Registered types are ordered by fidelity.
    static func fileContentType(of provider: NSItemProvider) -> UTType? {
        let registered = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let listed = TaskDropContent.fileTypes.filter { $0 != .fileURL }
        if let type = registered.first(where: { type in listed.contains { type.conforms(to: $0) } }) {
            return type
        }
        guard TaskDropContent.classify(provider) == .files else { return nil }
        let general = registered.filter { type in
            type.conforms(to: .data) && !TaskDropContent.internalMarkerTypes.contains(type)
        }
        return general.first { !$0.isDynamic } ?? general.first
    }

    /// A name that keeps the provider's suggestion and carries an extension
    /// matching `type`, because the importer derives the type from it.
    static func filename(suggested: String?, loaded: URL, type: UTType) -> String {
        var name = suggested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { name = loaded.lastPathComponent }
        let existing = UTType(filenameExtension: (name as NSString).pathExtension)
        if existing?.conforms(to: type) != true, let ext = type.preferredFilenameExtension {
            name += ".\(ext)"
        }
        return AttachmentFileStore.sanitizedFilename(name)
    }

    private static func fileURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url, url.isFileURL else {
                    continuation.resume(throwing: error ?? TaskDropError.unsupported)
                    return
                }
                // Finder may hand over a file reference URL (/.file/id=…);
                // the importer needs the real path and filename.
                continuation.resume(returning: (url as NSURL).filePathURL ?? url)
            }
        }
    }

    private static func copyFile(of provider: NSItemProvider, type: UTType, into directory: URL) async throws -> URL {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true else { throw AttachmentFileStoreError.notAFile(url) }
                    let size = Int64(values.fileSize ?? 0)
                    guard size <= AttachmentLimits.maxBytesPerAttachment else {
                        throw AttachmentFileStoreError.attachmentTooLarge(url, size)
                    }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent(
                        filename(suggested: suggestedName, loaded: url, type: type)
                    )
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// AppKit may terminate a drag without a destination exit (Escape, source
/// cancellation, or a completed drop). Every task surface shares this end.
extension View {
    func onTaskFileDropEnded(_ clear: @escaping () -> Void) -> some View {
        onDropSessionUpdated { session in
            switch session.phase {
            case .ended, .dataTransferCompleted: clear()
            default: break
            }
        }
    }
}
