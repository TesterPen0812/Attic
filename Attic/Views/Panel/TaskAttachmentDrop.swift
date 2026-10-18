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

    /// Marks a gallery card drag; visible only to this process.
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
    /// Owned directories of stagings merged into this one (the add bar's
    /// batches, imported as one): `discard` removes them too.
    private var mergedDirectories: [URL] = []

    init(urls: [URL] = []) {
        self.urls = urls
    }

    /// Several stagings imported as one (O17-06): their files in order,
    /// and every directory they own, which `discard` removes.
    init(merging parts: [TaskAttachmentStaging]) {
        urls = parts.flatMap(\.urls)
        mergedDirectories = parts.flatMap { [$0.ownedDirectory].compactMap { $0 } + $0.mergedDirectories }
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
        for directory in [ownedDirectory].compactMap({ $0 }) + mergedDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
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
    /// A dropped item never delivered its content (V-13): the import
    /// gives up rather than stay busy.
    case stalled

    var errorDescription: String? {
        switch self {
        case .unsupported: "Only files and images can be attached."
        case .attachmentUnavailable: "The attachment is no longer available."
        case .alreadyAttached: "That attachment already belongs to this task."
        case .stalled: "A dropped item never arrived."
        }
    }
}

/// One item provider load that always ends (V-13). A provider can accept a
/// load and never call back: a file promise whose drag was refused, an
/// app that quit. The load resumes exactly once: with the provider's
/// result; with `TaskDropError.stalled` once its progress has not moved
/// for `stallLimit`; or with `CancellationError` when the awaiting task is
/// cancelled. A result that arrives after that is dropped (`isWanted`).
final class TaskProviderLoad<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var ended = false
    private var progress: Progress?

    /// Whether the result is still awaited (a late callback does no work).
    var isWanted: Bool { lock.withLock { !ended } }

    /// Ends the load with `result`; false when it had already ended.
    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        let waiting: CheckedContinuation<Value, Error>? = lock.withLock {
            guard !ended else { return nil }
            ended = true
            defer { continuation = nil }
            return continuation
        }
        guard let waiting else { return false }
        waiting.resume(with: result)
        return true
    }

    /// Runs `start` (which begins the provider's load, calls `finish`, and
    /// returns the load's progress) and awaits its one result.
    static func run(isolation: isolated (any Actor)? = #isolation, _ start: (TaskProviderLoad<Value>) -> Progress?) async throws -> Value {
        let load = TaskProviderLoad<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                let early: Bool = load.lock.withLock {
                    if load.ended { return true }
                    load.continuation = continuation
                    return false
                }
                if early {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let progress = start(load)
                load.lock.withLock { load.progress = progress }
                load.watch(seen: progress?.completedUnitCount ?? 0)
            }
        } onCancel: {
            load.lock.withLock { load.progress }?.cancel()
            load.finish(.failure(CancellationError()))
        }
    }

    /// Gives up once the progress has stood still for a whole limit
    /// (`TaskProviderLoadLimit.seconds`).
    private func watch(seen: Int64) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + TaskProviderLoadLimit.seconds) { [self] in
            guard isWanted else { return }
            let progress = lock.withLock { self.progress }
            let now = progress?.completedUnitCount ?? 0
            if now > seen {
                watch(seen: now)
                return
            }
            progress?.cancel()
            finish(.failure(TaskDropError.stalled))
        }
    }
}

/// How long a dropped item's load may go without finishing or reporting
/// progress, in seconds (tests shorten it).
enum TaskProviderLoadLimit {
    nonisolated(unsafe) static var seconds: TimeInterval = 60
}

/// The file row being dragged in this process (A1: a row of a task's files
/// list). Drop validation is synchronous and cannot load the row's marker,
/// so a row records which attachment it is, and the task that owns it, when
/// its drag begins; every row drag replaces the record. It is consulted only
/// while a drag carries the own-process marker, and a drop checks the marker
/// against it, and the store against both, before anything is copied.
@MainActor
enum TaskAttachmentCardDrag {
    private(set) static var current: TaskAttachmentSource?

    static func begin(_ reference: TaskImageReference, store: TaskStore) {
        current = store.attachmentSource(for: reference.id)
    }

    /// A file may be copied to any task except the owner it came from. An
    /// unresolvable file is refused everywhere.
    static func canCopy(toOwner ownerID: UUID?) -> Bool {
        guard let current else { return false }
        return current.ownerID != ownerID
    }

    /// The dragged file, confirmed by its marker: one provider whose marker
    /// names the attachment `expected` recorded when the drag began. macOS
    /// can reconstruct an empty SwiftUI provider for a file-promise drag;
    /// in that case its own-process marker remains on the native pasteboard.
    static func sources(from providers: [NSItemProvider],
                        expected: TaskAttachmentSource?,
                        nativePasteboard: NSPasteboard = NSPasteboard(name: .drag)) async throws -> [TaskAttachmentSource] {
        guard let expected, providers.count == 1, let provider = providers.first else {
            throw TaskDropError.attachmentUnavailable
        }
        let data: Data
        if provider.registeredTypeIdentifiers.isEmpty {
            // Read synchronously on the main actor while the native drag is
            // alive. Never substitute a recorded source without its marker.
            guard let nativeData = nativePasteboard.data(forType:
                NSPasteboard.PasteboardType(TaskDropContent.attachmentCardType.identifier)) else {
                throw TaskDropError.attachmentUnavailable
            }
            data = nativeData
        } else {
            data = try await TaskProviderLoad<Data>.run { load in
                provider.loadDataRepresentation(forTypeIdentifier: TaskDropContent.attachmentCardType.identifier) { data, error in
                    if let data { load.finish(.success(data)) }
                    else { load.finish(.failure(error ?? TaskDropError.attachmentUnavailable)) }
                }
            }
        }
        guard let marker = String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:)),
              marker == expected.reference.id else {
            throw TaskDropError.attachmentUnavailable
        }
        return [expected]
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
        try await TaskProviderLoad<URL>.run { load in
            provider.loadObject(ofClass: URL.self) { url, error in
                guard let url, url.isFileURL else {
                    load.finish(.failure(error ?? TaskDropError.unsupported))
                    return
                }
                // Finder may hand over a file reference URL (/.file/id=…);
                // the importer needs the real path and filename.
                load.finish(.success((url as NSURL).filePathURL ?? url))
            }
        }
    }

    private static func copyFile(of provider: NSItemProvider, type: UTType, into directory: URL) async throws -> URL {
        let suggestedName = provider.suggestedName
        return try await TaskProviderLoad<URL>.run { load in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                // Given up already (stalled or cancelled): copy nothing.
                guard load.isWanted else { return }
                guard let url else {
                    load.finish(.failure(error ?? CocoaError(.fileReadUnknown)))
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
                    if !load.finish(.success(destination)) { try? FileManager.default.removeItem(at: destination) }
                } catch {
                    load.finish(.failure(error))
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
