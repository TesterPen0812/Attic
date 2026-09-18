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
        UTType(exportedAs: NoteInlineCardsLayout.dragType.rawValue)
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

/// The gallery card being dragged in this process. Drop validation is
/// synchronous and cannot load the card's marker, so a card records which
/// attachment it is, and the task that owns it, when its drag begins; every
/// card drag replaces the record. It is consulted only while a drag carries
/// the own-process card marker, and a drop checks the marker against it, and
/// the store against both, before anything is copied.
@MainActor
enum TaskAttachmentCardDrag {
    private(set) static var current: TaskAttachmentSource?

    static func begin(_ reference: TaskImageReference, store: TaskStore) {
        current = store.attachmentSource(for: reference.id)
    }

    /// A card may be copied anywhere except into the owner it came from
    /// (`nil` is the main composer's new task). An unresolvable card is
    /// refused everywhere.
    static func canCopy(toOwner ownerID: UUID?) -> Bool {
        guard let current else { return false }
        return current.ownerID != ownerID
    }

    /// The dragged card, confirmed by its marker: one provider whose marker
    /// names the attachment `expected` recorded when the drag began.
    static func sources(from providers: [NSItemProvider],
                        expected: TaskAttachmentSource?) async throws -> [TaskAttachmentSource] {
        guard let expected, providers.count == 1, let provider = providers.first else {
            throw TaskDropError.attachmentUnavailable
        }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: TaskDropContent.attachmentCardType.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? TaskDropError.attachmentUnavailable) }
            }
        }
        guard let marker = String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:)),
              marker == expected.reference.id else {
            throw TaskDropError.attachmentUnavailable
        }
        return [expected]
    }
}

/// Dropping onto a task: the store reserves the owner, then stages and
/// imports files, or copies a card from another task; success reveals the
/// new cards, failure leaves the store's calm message and changes nothing
/// else.
@MainActor
enum TaskFileDrop {
    static func message(for title: String) -> String {
        "Drop to attach to “\(title)”"
    }

    static func canAccept(_ taskID: UUID, store: TaskStore) -> Bool {
        canAccept(.files, onto: taskID, store: store)
    }

    static func canAccept(_ content: TaskDropContent, onto taskID: UUID, store: TaskStore) -> Bool {
        guard let ownerID = store.attachmentOwnerID(for: taskID),
              !store.importingAttachmentTaskIDs.contains(ownerID) else { return false }
        switch content {
        case .files: return true
        case .attachmentCard: return TaskAttachmentCardDrag.canCopy(toOwner: ownerID)
        case .task, .unsupported: return false
        }
    }

    static func attach(_ content: TaskDropContent, _ providers: [NSItemProvider], to taskID: UUID,
                       store: TaskStore, subtaskPanels: SubtaskPanelController) {
        guard let ownerID = store.attachmentOwnerID(for: taskID) else { return }
        // The panel state at drop time decides whether revealing the result
        // later is still expected (see revealImportedAttachments).
        let atDrop = subtaskPanels.revealContext
        let card = TaskAttachmentCardDrag.current
        Task { @MainActor in
            let ids: [UUID]?
            switch content {
            case .files:
                ids = await store.attachStagedFiles(to: ownerID) { try await TaskDroppedFiles.stage(providers) }
            case .attachmentCard:
                ids = await store.attachCopies(to: ownerID) {
                    try await TaskAttachmentCardDrag.sources(from: providers, expected: card)
                }
            case .task, .unsupported:
                return
            }
            guard let ids else { return }
            subtaskPanels.revealImportedAttachments(ids, for: ownerID, since: atDrop)
            let title = store.tasks.first { $0.id == ownerID }?.title ?? "task"
            AccessibilityNotification.Announcement(
                ids.count == 1 ? "Attached 1 file to \(title)" : "Attached \(ids.count) files to \(title)"
            ).post()
        }
    }
}

/// A family panel's file-drop state. The panel surface and each child row
/// inside it are separate drop destinations; all of them report here, so the
/// whole panel reads as one target wherever the pointer is.
@MainActor
final class TaskFileDropTarget: ObservableObject {
    @Published private(set) var isTargeted = false
    private var sources: Set<AnyHashable> = []
    /// Set by the panel for the family it currently shows.
    var perform: (TaskDropContent, [NSItemProvider]) -> Void = { _, _ in }
    var canAccept: (TaskDropContent) -> Bool = { _ in false }

    func setTargeted(_ targeted: Bool, source: AnyHashable) {
        if targeted { sources.insert(source) } else { sources.remove(source) }
        let now = !sources.isEmpty
        if now != isTargeted { isTargeted = now }
    }

    /// Forgets every source. A drop ends the drag for the whole panel, even
    /// if a destination it crossed never received its exit.
    func end() {
        sources.removeAll()
        if isTargeted { isTargeted = false }
    }
}

private struct TaskFileDropTargetKey: EnvironmentKey {
    static let defaultValue: TaskFileDropTarget? = nil
}

extension EnvironmentValues {
    /// Set by a family panel: rows inside it hand file drops to the panel.
    var taskFileDropTarget: TaskFileDropTarget? {
        get { self[TaskFileDropTargetKey.self] }
        set { self[TaskFileDropTargetKey.self] = newValue }
    }
}

/// Drop destination for attachments only (a panel surface or the main
/// composer): files, or a card the destination may copy. Task drags are
/// refused even when they also carry files.
struct TaskFileDropDelegate: DropDelegate {
    let canAccept: (TaskDropContent) -> Bool
    let setTargeted: (Bool) -> Void
    let perform: (TaskDropContent, [NSItemProvider]) -> Void

    private func accepted(_ info: DropInfo) -> TaskDropContent? {
        let content = TaskDropContent.classify(info)
        switch content {
        case .files, .attachmentCard: return canAccept(content) ? content : nil
        case .task, .unsupported: return nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        accepted(info) != nil
    }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { setTargeted(true) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) {
        setTargeted(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        setTargeted(false)
        guard let content = accepted(info) else { return false }
        let providers = TaskDropContent.providers(for: content, in: info)
        guard !providers.isEmpty else { return false }
        perform(content, providers)
        return true
    }
}

/// A task row's single drop destination, so routing is decided in one place:
/// task drags keep the existing reorder/status drop; files and cards from
/// other tasks attach to the row's owner. Inside a family panel the row
/// forwards them to the panel's target instead of highlighting itself.
struct TaskRowDropDelegate: DropDelegate {
    let taskID: UUID
    let panelTarget: TaskFileDropTarget?
    let canAcceptAttachment: (TaskDropContent) -> Bool
    let setTaskTargeted: (Bool) -> Void
    let setFileTargeted: (Bool) -> Void
    let performTaskDrop: (UUID) -> Void
    let beginTaskDrop: () -> Void
    let attach: (TaskDropContent, [NSItemProvider]) -> Void

    private var source: AnyHashable { "row-\(taskID.uuidString)" }

    private func acceptsAttachment(_ content: TaskDropContent) -> Bool {
        panelTarget?.canAccept(content) ?? canAcceptAttachment(content)
    }

    func validateDrop(info: DropInfo) -> Bool {
        accepts(TaskDropContent.classify(info))
    }

    func accepts(_ content: TaskDropContent) -> Bool {
        switch content {
        case .task: return true
        case .files, .attachmentCard: return acceptsAttachment(content)
        case .unsupported: return false
        }
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        switch TaskDropContent.classify(info) {
        case .task: setTaskTargeted(true)
        case .files, .attachmentCard:
            if let panelTarget { panelTarget.setTargeted(true, source: source) } else { setFileTargeted(true) }
        case .unsupported: break
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: TaskDropContent.classify(info) == .task ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        clearTargets()
    }

    func performDrop(info: DropInfo) -> Bool {
        perform(
            TaskDropContent.classify(info),
            taskProvider: { info.itemProviders(for: [TaskDragPayload.internalTaskType]).first },
            attachmentProviders: { TaskDropContent.providers(for: $0, in: info) }
        )
    }

    /// The body of `performDrop` without `DropInfo`, which tests cannot build.
    func perform(
        _ content: TaskDropContent,
        taskProvider: () -> NSItemProvider?,
        attachmentProviders: (TaskDropContent) -> [NSItemProvider]
    ) -> Bool {
        clearTargets()
        // Any drop ends the drag for the whole panel, a reorder included: a
        // destination it crossed may never have received its exit.
        panelTarget?.end()
        guard accepts(content) else { return false }
        switch content {
        case .task:
            guard let provider = taskProvider() else { return false }
            // The shell's drag-release watcher must see the drag consumed
            // now, not after the payload loads.
            beginTaskDrop()
            let perform = performTaskDrop
            _ = provider.loadTransferable(type: TaskDragPayload.self) { result in
                guard let taskID = try? result.get().taskID else { return }
                Task { @MainActor in perform(taskID) }
            }
            return true
        case .files, .attachmentCard:
            let providers = attachmentProviders(content)
            guard !providers.isEmpty else { return false }
            if let panelTarget { panelTarget.perform(content, providers) } else { attach(content, providers) }
            return true
        case .unsupported:
            return false
        }
    }

    private func clearTargets() {
        setTaskTargeted(false)
        setFileTargeted(false)
        panelTarget?.setTargeted(false, source: source)
    }
}

/// Restrained drop feedback: a faint tint and edge over content that stays
/// visible, with one small label naming where the files will go.
struct TaskDropOverlay<S: Shape>: View {
    let message: String
    let shape: S
    var labelAlignment: Alignment = .center
    var compact = false

    var body: some View {
        ZStack(alignment: labelAlignment) {
            shape.fill(Color.accentColor.opacity(0.07))
            shape.stroke(Color.accentColor.opacity(0.55), lineWidth: 1.25)
                .padding(0.75)
            Label {
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "paperclip")
            }
            .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.primary.opacity(0.9))
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .atticGlassControl(in: Capsule(), interactive: false)
            .padding(.horizontal, compact ? 6 : 14)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

}
