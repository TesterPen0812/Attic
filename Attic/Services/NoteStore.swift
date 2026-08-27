import Combine
import CoreData
import Foundation
import SwiftData

#if os(macOS)
typealias NoteAttachmentFileStore = AttachmentFileStore
#else
typealias NoteAttachmentFileStore = Any
#endif

private struct NoteReplicaSnapshot: Equatable {
    let id: UUID
    let title: String
    let body: String
    let createdAt: Date
    let updatedAt: Date

    init(_ note: NoteItem) {
        id = note.id
        title = note.title
        body = note.body
        createdAt = note.createdAt
        updatedAt = note.updatedAt
    }
}

private enum NoteReplicaMutationError: LocalizedError {
    case missingReplica(UUID)

    var errorDescription: String? {
        switch self {
        case let .missingReplica(id):
            "The note replicas for \(id.uuidString) could not be loaded safely."
        }
    }
}

/// Local-first store for notes, sharing the same CloudKit-backed container as
/// tasks. It follows the same invariants as `TaskStore`: deduplicate physical
/// replicas only for presentation, apply mutations to every replica, replace
/// the long-lived `ModelContext` after a CloudKit import, and hold a bounded
/// `ProcessInfo` activity assertion around export/import windows so the
/// `LSUIElement` Mac app does not nap while Core Data is mirroring.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [NoteItem] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var cloudSyncStatus = CloudSyncStatus()
#if os(macOS)
    @Published private(set) var attachmentsByNoteID: [UUID: [NoteAttachment]] = [:]
    @Published private(set) var attachmentImportState: AttachmentImportState = .idle
#endif

    private let container: ModelContainer
#if os(macOS)
    private let attachmentFileStore: AttachmentFileStore
#endif
    private var context: ModelContext
    private let now: () -> Date
    private let persist: (ModelContext) throws -> Void
    private var remoteChangeObservation: AnyCancellable?
    private var cloudKitEventObservation: AnyCancellable?
    private var cloudImportRefreshTask: Task<Void, Never>?
    private var cloudSyncProtection = CloudSyncProtectionState()
#if os(macOS)
    private var exportActivityToken: NSObjectProtocol?
    private var importActivityToken: NSObjectProtocol?
    private var exportActivityTimeoutTask: Task<Void, Never>?
    private var importActivityTimeoutTask: Task<Void, Never>?
    private static let cloudSyncActivityTimeout: Duration = .seconds(120)
#endif

    init(
        container: ModelContainer,
        now: @escaping () -> Date = Date.init,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
        attachmentFileStore: NoteAttachmentFileStore? = nil
    ) {
        self.container = container
#if os(macOS)
        self.attachmentFileStore = attachmentFileStore ?? AttachmentFileStore()
#endif
        context = ModelContext(container)
        self.now = now
        self.persist = persist
        refresh()
        observeRemoteChanges()
        observeCloudKitEvents()
    }

    @discardableResult
    func create(title: String = "", body: String = "") -> NoteItem? {
        let normalizedTitle = Self.normalizedTitle(title)
        guard !normalizedTitle.isEmpty || Self.hasMeaningfulBody(body) else { return nil }

        let timestamp = now()
        let note = NoteItem(
            title: normalizedTitle,
            body: body,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        context.insert(note)
        notes.append(note)
        guard save() else { return nil }
        return note
    }

    @discardableResult
    func update(
        _ note: NoteItem,
        title: String? = nil,
        body: String? = nil
    ) -> Bool {
        guard let note = notes.first(where: { $0.id == note.id }) else { return false }
        let replicas: [NoteItem]
        do {
            replicas = try storedNotes(matching: note.id)
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        let destinationTitle = title.map(Self.normalizedTitle) ?? note.title
        let destinationBody = body ?? note.body
        guard !destinationTitle.isEmpty || Self.hasMeaningfulBody(destinationBody) else { return false }

        let titleChanged = destinationTitle != note.title
        let bodyChanged = destinationBody != note.body
        let visibleSnapshot = NoteReplicaSnapshot(note)
        let replicasNeedRepair = replicas.contains { NoteReplicaSnapshot($0) != visibleSnapshot }
        guard titleChanged || bodyChanged || replicasNeedRepair else { return true }

        let timestamp = now()
        for replica in replicas {
            replica.title = destinationTitle
            replica.body = destinationBody
            replica.createdAt = note.createdAt
            replica.updatedAt = timestamp
        }
        return save()
    }

    @discardableResult
    func delete(_ note: NoteItem) -> Bool {
        guard let note = notes.first(where: { $0.id == note.id }) else { return false }
        let replicas: [NoteItem]
        do {
            replicas = try storedNotes(matching: note.id)
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
#if os(macOS)
        let attachmentReplicas: [NoteAttachment]
        do {
            attachmentReplicas = try storedAttachments(forNoteID: note.id)
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        let references = attachmentReplicas.map { AttachmentFileReference($0) }
#endif
        replicas.forEach(context.delete)
#if os(macOS)
        attachmentReplicas.forEach(context.delete)
#endif
        notes.removeAll { $0.id == note.id }
#if os(macOS)
        attachmentsByNoteID[note.id] = nil
#endif
        guard save() else { return false }
#if os(macOS)
        removeMaterializationsAfterSuccessfulSave(references)
#endif
        return true
    }

#if os(macOS)
    func attachments(for noteID: UUID) -> [NoteAttachment] {
        attachmentsByNoteID[noteID] ?? []
    }

    /// Imports a batch into an existing note, or creates an attachment-only
    /// note when noteID is nil. The filesystem transaction completes before
    /// the single SwiftData save; every created byte is removed on failure.
    @discardableResult
    func importAttachments(
        from urls: [URL],
        noteID: UUID? = nil
    ) async -> UUID? {
        guard !urls.isEmpty else { return noteID }
        attachmentImportState = .importing(completed: 0, total: urls.count)

        do {
            let targetNoteID: UUID
            if let noteID {
                let noteReplicas = try storedNotes(matching: noteID)
                guard !noteReplicas.isEmpty else {
                    throw AttachmentFileStoreError.inaccessible(
                        URL(fileURLWithPath: noteID.uuidString),
                        "The note is no longer available."
                    )
                }
                targetNoteID = noteID
            } else {
                targetNoteID = UUID()
            }

            let existing = attachments(for: targetNoteID)
            let baseSortIndex = existing.map(\.sortIndex).max().map { $0 + 1 } ?? 0
            let existingBytes = existing.reduce(Int64.zero) { $0 + $1.byteCount }
            let imported = try await attachmentFileStore.importFiles(
                urls,
                baseSortIndex: baseSortIndex,
                existingCount: existing.count,
                existingBytes: existingBytes
            )
            attachmentImportState = .importing(completed: urls.count, total: urls.count)

            if noteID == nil {
                let timestamp = now()
                context.insert(NoteItem(
                    id: targetNoteID,
                    title: "",
                    body: "",
                    createdAt: timestamp,
                    updatedAt: timestamp
                ))
            }

            let references = imported.map { item in
                NoteAttachment(
                    id: item.id,
                    noteID: targetNoteID,
                    originalFilename: item.filename,
                    contentTypeIdentifier: item.contentTypeIdentifier,
                    byteCount: item.byteCount,
                    sortIndex: item.sortIndex,
                    contentDigest: item.digest,
                    createdAt: item.createdAt,
                    payload: item.payload
                )
            }
            references.forEach(context.insert)
            guard save() else {
                try? await attachmentFileStore.removeMaterializations(
                    imported.map {
                        AttachmentFileReference(
                            id: $0.id,
                            digest: $0.digest,
                            filename: $0.filename,
                            payload: nil
                        )
                    }
                )
                attachmentImportState = .failed(lastErrorMessage ?? "Unable to save attachments.")
                return nil
            }

            refresh()
            attachmentImportState = .idle
            return targetNoteID
        } catch {
            attachmentImportState = .failed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func removeAttachment(_ attachment: NoteAttachment) -> Bool {
        let replicas: [NoteAttachment]
        do {
            replicas = try storedAttachments(matching: attachment.id)
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        let references = replicas.map { AttachmentFileReference($0) }
        replicas.forEach(context.delete)
        attachmentsByNoteID[attachment.noteID]?.removeAll { $0.id == attachment.id }
        guard save() else { return false }
        removeMaterializationsAfterSuccessfulSave(references)
        return true
    }

    func materializedURL(for attachment: NoteAttachment) async -> URL? {
        do {
            return try await attachmentFileStore.ensureMaterialized(
                AttachmentFileReference(attachment)
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    func setAttachmentError(_ message: String) {
        lastErrorMessage = message
    }
#endif

    /// Newest first, with a deterministic tiebreak so a refreshed duplicate
    /// keeps its position instead of flickering between physical rows.
    func orderedNotes() -> [NoteItem] {
        notes.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    func refresh() {
        do {
            try reloadModels()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func handleCloudSyncEvent(_ update: CloudSyncEventUpdate) {
        cloudSyncProtection.apply(update)
        reconcileProtectedCloudSyncActivity(for: update.kind)
        cloudSyncStatus.apply(update)
        if !update.succeeded, let errorMessage = update.errorMessage {
            NSLog("CloudKit %@ failed: %@", String(describing: update.kind), errorMessage)
        }
        // A failed import may still have committed earlier batches. Refresh
        // after every completed import so partially applied changes are not
        // left hidden behind stale SwiftData model instances.
        guard update.kind == .importData, update.endedAt != nil else { return }

        cloudImportRefreshTask?.cancel()
        cloudImportRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refresh()
            self?.cloudSyncProtection.completeImportRefresh()
            self?.reconcileProtectedCloudSyncActivity(for: .importData)
            self?.cloudImportRefreshTask = nil
        }
    }

    // MARK: - Persistence

    @discardableResult
    private func save() -> Bool {
        do {
            try persist(context)
            lastErrorMessage = nil
            revision &+= 1
            cloudSyncProtection.noteLocalSave()
            reconcileProtectedCloudSyncActivity(for: .exportData)
            return true
        } catch {
            let saveError = error.localizedDescription
            context.rollback()
            do {
                try reloadModels()
                lastErrorMessage = saveError
            } catch {
                lastErrorMessage = "\(saveError) · Reload failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func reloadModels() throws {
        // A long-lived ModelContext can return cached model instances after
        // CloudKit updates the underlying store. Refresh through a new context
        // so remote values replace the old objects instead of being written
        // back to CloudKit by the next local save.
        let refreshedContext = ModelContext(container)
        let fetchedNotes = try refreshedContext.fetch(FetchDescriptor<NoteItem>())
#if os(macOS)
        let fetchedAttachments = try refreshedContext.fetch(FetchDescriptor<NoteAttachment>())
#endif
        context = refreshedContext
        notes = visibleUniqueNotes(from: fetchedNotes)
#if os(macOS)
        attachmentsByNoteID = visibleUniqueAttachments(from: fetchedAttachments)
#endif
        revision &+= 1
#if os(macOS)
        reconcileFileStorage(with: fetchedAttachments)
#endif
    }

    /// CloudKit can't enforce a unique UUID attribute. If a malformed import
    /// ever produces duplicates, expose one app-level record. Never delete
    /// duplicates during refresh: a cleanup save could destroy the valid peer
    /// copy across CloudKit.
    private func visibleUniqueNotes(from fetched: [NoteItem]) -> [NoteItem] {
        var newestByID: [UUID: NoteItem] = [:]

        for note in fetched {
            guard let existing = newestByID[note.id] else {
                newestByID[note.id] = note
                continue
            }

            if note.updatedAt > existing.updatedAt {
                newestByID[note.id] = note
            } else if note.updatedAt == existing.updatedAt,
                      Self.tieBreakKey(for: note) > Self.tieBreakKey(for: existing) {
                newestByID[note.id] = note
            }
        }

        return fetched.filter { note in
            newestByID[note.id] === note
        }
    }

    private func storedNotes(matching id: UUID) throws -> [NoteItem] {
        let stored = try context.fetch(FetchDescriptor<NoteItem>())
        let replicas = stored.filter { $0.id == id }
        guard !replicas.isEmpty else {
            throw NoteReplicaMutationError.missingReplica(id)
        }
        return replicas
    }

#if os(macOS)
    private func storedAttachments(matching id: UUID) throws -> [NoteAttachment] {
        let stored = try context.fetch(FetchDescriptor<NoteAttachment>())
        let replicas = stored.filter { $0.id == id }
        guard !replicas.isEmpty else {
            throw NoteReplicaMutationError.missingReplica(id)
        }
        return replicas
    }

    private func storedAttachments(forNoteID noteID: UUID) throws -> [NoteAttachment] {
        let stored = try context.fetch(FetchDescriptor<NoteAttachment>())
        return stored.filter { $0.noteID == noteID }
    }

    private func visibleUniqueAttachments(
        from fetched: [NoteAttachment]
    ) -> [UUID: [NoteAttachment]] {
        var newestByID: [UUID: NoteAttachment] = [:]
        for attachment in fetched {
            guard let existing = newestByID[attachment.id] else {
                newestByID[attachment.id] = attachment
                continue
            }
            if attachment.updatedAt > existing.updatedAt
                || (attachment.updatedAt == existing.updatedAt
                    && String(reflecting: attachment.persistentModelID)
                    > String(reflecting: existing.persistentModelID)) {
                newestByID[attachment.id] = attachment
            }
        }

        return Dictionary(grouping: newestByID.values) { $0.noteID }
            .mapValues { attachments in
                attachments.sorted {
                    if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
            }
    }

    private func reconcileFileStorage(with attachments: [NoteAttachment]) {
        let references = attachments.map { AttachmentFileReference($0) }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await attachmentFileStore.reconcile(references)
            } catch {
                NSLog("Attic attachment reconciliation failed: %@", error.localizedDescription)
            }
        }
    }

    private func removeMaterializationsAfterSuccessfulSave(
        _ references: [AttachmentFileReference]
    ) {
        guard !references.isEmpty else { return }
        Task { [attachmentFileStore] in
            try? await attachmentFileStore.removeMaterializations(references)
        }
    }
#endif

    private func observeRemoteChanges() {
        remoteChangeObservation = NotificationCenter.default.publisher(
            for: .NSPersistentStoreRemoteChange
        )
        .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refresh()
        }
    }

    private func observeCloudKitEvents() {
        cloudKitEventObservation = NotificationCenter.default.publisher(
            for: NSPersistentCloudKitContainer.eventChangedNotification
        )
        .compactMap { notification in
            notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] event in
            guard let self, let kind = Self.activityKind(for: event.type) else { return }
            handleCloudSyncEvent(CloudSyncEventUpdate(
                id: event.identifier,
                kind: kind,
                endedAt: event.endDate,
                succeeded: event.succeeded,
                errorMessage: Self.cloudSyncErrorMessage(event.error)
            ))
        }
    }

    private func reconcileProtectedCloudSyncActivity(for kind: CloudSyncActivityKind) {
        let shouldProtect: Bool
        switch kind {
        case .exportData:
            shouldProtect = cloudSyncProtection.protectsExport
        case .importData:
            shouldProtect = cloudSyncProtection.protectsImport
        case .setup:
            return
        }

        if shouldProtect {
            beginProtectedCloudSyncActivity(for: kind)
        } else {
            endProtectedCloudSyncActivity(for: kind)
        }
    }

    /// Keep the `LSUIElement` app out of App Nap only while Core Data is handing
    /// a local note save to CloudKit or applying an import, then release the
    /// assertion immediately. The timeout is a safety net for framework events
    /// that never complete.
    private func beginProtectedCloudSyncActivity(for kind: CloudSyncActivityKind) {
#if os(macOS)
        guard kind != .setup else { return }

        let processInfo = ProcessInfo.processInfo
        switch kind {
        case .exportData:
            if exportActivityToken == nil {
                exportActivityToken = processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Exporting Attic notes to iCloud"
                )
            }
            exportActivityTimeoutTask?.cancel()
            exportActivityTimeoutTask = activityTimeoutTask(for: .exportData)
        case .importData:
            if importActivityToken == nil {
                importActivityToken = processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Importing Attic notes from iCloud"
                )
            }
            importActivityTimeoutTask?.cancel()
            importActivityTimeoutTask = activityTimeoutTask(for: .importData)
        case .setup:
            break
        }
#endif
    }

    private func endProtectedCloudSyncActivity(for kind: CloudSyncActivityKind) {
#if os(macOS)
        switch kind {
        case .exportData:
            exportActivityTimeoutTask?.cancel()
            exportActivityTimeoutTask = nil
            if let exportActivityToken {
                ProcessInfo.processInfo.endActivity(exportActivityToken)
                self.exportActivityToken = nil
            }
        case .importData:
            importActivityTimeoutTask?.cancel()
            importActivityTimeoutTask = nil
            if let importActivityToken {
                ProcessInfo.processInfo.endActivity(importActivityToken)
                self.importActivityToken = nil
            }
        case .setup:
            break
        }
#endif
    }

#if os(macOS)
    private func activityTimeoutTask(
        for kind: CloudSyncActivityKind
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.cloudSyncActivityTimeout)
            guard !Task.isCancelled else { return }
            self?.endProtectedCloudSyncActivity(for: kind)
        }
    }
#endif

    private static func activityKind(
        for type: NSPersistentCloudKitContainer.EventType
    ) -> CloudSyncActivityKind? {
        switch type {
        case .setup: .setup
        case .import: .importData
        case .export: .exportData
        @unknown default: nil
        }
    }

    private static func cloudSyncErrorMessage(_ error: Error?) -> String? {
        guard let error else { return nil }
        let nsError = error as NSError
        var message = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            message += " · \(underlyingError.domain) \(underlyingError.code): "
                + underlyingError.localizedDescription
        }
        return message
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func hasMeaningfulBody(_ body: String) -> Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func tieBreakKey(for note: NoteItem) -> String {
        [
            note.title,
            note.body,
            String(note.createdAt.timeIntervalSinceReferenceDate.bitPattern),
            String(note.updatedAt.timeIntervalSinceReferenceDate.bitPattern),
            String(reflecting: note.persistentModelID)
        ].joined(separator: "\u{1F}")
    }
}
