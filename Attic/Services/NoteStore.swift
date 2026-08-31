import Combine
import CoreData
import Foundation
import SwiftData

#if os(macOS)
typealias NoteAttachmentFileStore = AttachmentFileStore

protocol NoteAttachmentFileImporting: Sendable {
    func importFiles(
        _ urls: [URL],
        baseSortIndex: Int64,
        existingCount: Int,
        existingBytes: Int64,
        progress: (@Sendable (Int, Int) async -> Void)?
    ) async throws -> [ImportedAttachment]
}

extension AttachmentFileStore: NoteAttachmentFileImporting {}

typealias NoteAttachmentImporter = any NoteAttachmentFileImporting

struct NoteAttachmentImportActivity: Equatable {
    let requestID: UUID
    let editorSession: NoteEditorSession
    let origin: NoteAttachmentImportOrigin
    var state: AttachmentImportState
}
#else
typealias NoteAttachmentFileStore = Any
typealias NoteAttachmentImporter = Any
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
    @Published private(set) var attachmentImportActivity: NoteAttachmentImportActivity?

    var attachmentImportState: AttachmentImportState {
        attachmentImportActivity?.state ?? .idle
    }
#endif

    private let container: ModelContainer
#if os(macOS)
    private let attachmentFileStore: AttachmentFileStore
    private let attachmentImporter: any NoteAttachmentFileImporting
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
    private var attachmentImportInFlight = false
    private var invalidatedAttachmentImportIDs = Set<UUID>()
    private static let cloudSyncActivityTimeout: Duration = .seconds(120)
#endif

    init(
        container: ModelContainer,
        now: @escaping () -> Date = Date.init,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
        attachmentFileStore: NoteAttachmentFileStore? = nil,
        attachmentImporter: NoteAttachmentImporter? = nil
    ) {
        self.container = container
#if os(macOS)
        let resolvedAttachmentFileStore = attachmentFileStore ?? AttachmentFileStore()
        self.attachmentFileStore = resolvedAttachmentFileStore
        self.attachmentImporter = attachmentImporter ?? resolvedAttachmentFileStore
#endif
        context = ModelContext(container)
        self.now = now
        self.persist = persist
        refresh()
        observeRemoteChanges()
        observeCloudKitEvents()
    }

    @discardableResult
    func create(id: UUID = UUID(), title: String = "", body: String = "") -> NoteItem? {
        let normalizedTitle = Self.normalizedTitle(title)
        guard !normalizedTitle.isEmpty || Self.hasMeaningfulBody(body) else { return nil }

        let timestamp = now()
        let note = NoteItem(
            id: id,
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
        let attachmentImportIDToInvalidate = attachmentImportInFlight
            && attachmentImportActivity?.origin.noteID == note.id
            ? attachmentImportActivity?.requestID
            : nil
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
        if let attachmentImportIDToInvalidate {
            invalidatedAttachmentImportIDs.insert(attachmentImportIDToInvalidate)
        }
        removeMaterializationsAfterSuccessfulSave(references)
#endif
        return true
    }

#if os(macOS)
    func attachments(for noteID: UUID) -> [NoteAttachment] {
        attachmentsByNoteID[noteID] ?? []
    }

    func attachmentImportState(for editorSession: NoteEditorSession) -> AttachmentImportState {
        guard attachmentImportActivity?.editorSession == editorSession else { return .idle }
        return attachmentImportState
    }

    /// Imports a batch into the immutable origin captured by the draft before
    /// this async transaction starts. A blank origin owns a reserved logical
    /// note ID that a concurrent autosave may create while file work is in
    /// flight; either completion order converges on that one ID.
    @discardableResult
    func importAttachments(
        _ request: NoteAttachmentImportRequest
    ) async -> NoteAttachmentImportOutcome {
        guard !request.urls.isEmpty else {
            let message = "Choose at least one file to attach."
            lastErrorMessage = message
            return .failed(message)
        }
        guard !attachmentImportInFlight else {
            lastErrorMessage = "Finish or cancel the current attachment import before adding more files."
            return .busy
        }
        attachmentImportInFlight = true
        attachmentImportActivity = NoteAttachmentImportActivity(
            requestID: request.id,
            editorSession: request.editorSession,
            origin: request.origin,
            state: .importing(completed: 0, total: request.urls.count)
        )
        defer {
            attachmentImportInFlight = false
            invalidatedAttachmentImportIDs.remove(request.id)
        }
        var imported: [ImportedAttachment] = []

        do {
            let targetNoteID = request.origin.noteID
            let originWasPersistedAtStart: Bool
            switch request.origin {
            case .note:
                _ = try storedNotes(matching: targetNoteID)
                originWasPersistedAtStart = true
            case .blankDraft:
                originWasPersistedAtStart = try !storedNotesIfPresent(
                    matching: targetNoteID
                ).isEmpty
            }

            let existing = try visibleAttachments(forNoteID: targetNoteID)
            let baseSortIndex = existing.map(\.sortIndex).max().map { $0 + 1 } ?? 0
            let existingBytes = totalAttachmentBytes(existing)
            imported = try await attachmentImporter.importFiles(
                request.urls,
                baseSortIndex: baseSortIndex,
                existingCount: existing.count,
                existingBytes: existingBytes
            ) { [weak self] completed, total in
                await self?.updateAttachmentImportProgress(
                    requestID: request.id,
                    completed: completed,
                    total: total
                )
            }
            try Task.checkCancellation()

            guard !invalidatedAttachmentImportIDs.contains(request.id) else {
                throw NoteReplicaMutationError.missingReplica(targetNoteID)
            }
            switch request.origin {
            case .note:
                // The file copy can yield to CloudKit refresh notifications.
                // Recheck the logical note before committing attachments so a
                // note deleted remotely during the copy cannot gain orphaned
                // attachment rows. Re-read its attachments as well: a remote
                // insert during the copy must not let this batch exceed the
                // per-note limit or reuse stale sort indexes.
                _ = try storedNotes(matching: targetNoteID)
            case .blankDraft:
                let noteReplicas = try storedNotesIfPresent(matching: targetNoteID)
                if noteReplicas.isEmpty {
                    // If this reserved origin had already become durable and is
                    // now absent, deletion wins over the attachment completion.
                    guard !originWasPersistedAtStart else {
                        throw NoteReplicaMutationError.missingReplica(targetNoteID)
                    }
                    let timestamp = now()
                    context.insert(NoteItem(
                        id: targetNoteID,
                        title: "",
                        body: "",
                        createdAt: timestamp,
                        updatedAt: timestamp
                    ))
                }
            }

            try Task.checkCancellation()
            let currentAttachments = try visibleAttachments(forNoteID: targetNoteID)
            guard currentAttachments.count <= AttachmentLimits.maxAttachmentsPerNote,
                  imported.count <= AttachmentLimits.maxAttachmentsPerNote - currentAttachments.count else {
                throw AttachmentFileStoreError.tooManyAttachments
            }
            let importedBytes = totalAttachmentBytes(imported)
            let currentBytes = totalAttachmentBytes(currentAttachments)
            guard importedBytes <= AttachmentLimits.maxBytesPerNote - currentBytes else {
                throw AttachmentFileStoreError.noteTooLarge
            }
            let currentBaseSortIndex = currentAttachments.map(\.sortIndex).max().map { $0 + 1 } ?? 0
            let references = imported.enumerated().map { offset, item in
                NoteAttachment(
                    id: item.id,
                    noteID: targetNoteID,
                    originalFilename: item.filename,
                    contentTypeIdentifier: item.contentTypeIdentifier,
                    byteCount: item.byteCount,
                    sortIndex: currentBaseSortIndex + Int64(offset),
                    contentDigest: item.digest,
                    createdAt: item.createdAt,
                    payload: item.payload
                )
            }
            references.forEach(context.insert)
            guard save() else {
                try? await removeImportedMaterializations(imported)
                let message = lastErrorMessage ?? "Unable to save attachments."
                updateAttachmentImportState(.failed(message), requestID: request.id)
                return .failed(message)
            }

            refresh()
            clearAttachmentImportActivity(requestID: request.id)
            return .imported(noteID: targetNoteID)
        } catch is CancellationError {
            context.rollback()
            try? await removeImportedMaterializations(imported)
            clearAttachmentImportActivity(requestID: request.id)
            return .cancelled
        } catch NoteReplicaMutationError.missingReplica {
            context.rollback()
            try? await removeImportedMaterializations(imported)
            let message = "The note is no longer available."
            updateAttachmentImportState(.failed(message), requestID: request.id)
            lastErrorMessage = message
            return .originUnavailable
        } catch {
            context.rollback()
            try? await removeImportedMaterializations(imported)
            updateAttachmentImportState(
                .failed(error.localizedDescription),
                requestID: request.id
            )
            lastErrorMessage = error.localizedDescription
            return .failed(error.localizedDescription)
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
        for noteID in attachmentsByNoteID.keys {
            attachmentsByNoteID[noteID]?.removeAll { $0.id == attachment.id }
        }
        guard save() else { return false }
        removeMaterializationsAfterSuccessfulSave(references)
        return true
    }

    func materializedURL(for attachment: NoteAttachment) async -> URL? {
        let metadata = AttachmentFileReference(attachment, includePayload: false)
        do {
            let url: URL
            if let existing = try await attachmentFileStore.verifiedMaterializedURL(
                for: metadata
            ) {
                url = existing
            } else {
                let reference = AttachmentFileReference(attachment)
                guard let repaired = try await attachmentFileStore.ensureMaterialized(reference) else {
                    return nil
                }
                url = repaired
            }

            // A thumbnail or Quick Look request may outlive a row that was
            // removed while the filesystem actor was materializing its bytes.
            // Do not hand an orphaned file back to the UI; remove it after the
            // actor finishes so removal and materialization remain serialized.
            let stillVisible = attachmentsByNoteID.values.contains { attachments in
                attachments.contains {
                    $0.id == attachment.id
                        && $0.contentDigest == attachment.contentDigest
                }
            }
            guard stillVisible else {
                try? await attachmentFileStore.removeMaterializations([metadata])
                return nil
            }
            return url
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
        let replicas = try storedNotesIfPresent(matching: id)
        guard !replicas.isEmpty else {
            throw NoteReplicaMutationError.missingReplica(id)
        }
        return replicas
    }

    private func storedNotesIfPresent(matching id: UUID) throws -> [NoteItem] {
        let stored = try context.fetch(FetchDescriptor<NoteItem>())
        return stored.filter { $0.id == id }
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

    private func visibleAttachments(forNoteID noteID: UUID) throws -> [NoteAttachment] {
        let replicas = try storedAttachments(forNoteID: noteID)
        return visibleUniqueAttachments(from: replicas)[noteID] ?? []
    }

    private func totalAttachmentBytes(_ attachments: [NoteAttachment]) -> Int64 {
        totalAttachmentBytes(attachments.map(\.byteCount))
    }

    private func totalAttachmentBytes(_ attachments: [ImportedAttachment]) -> Int64 {
        totalAttachmentBytes(attachments.map(\.byteCount))
    }

    private func totalAttachmentBytes(_ byteCounts: [Int64]) -> Int64 {
        byteCounts.reduce(Int64.zero) { total, byteCount in
            let validByteCount = max(byteCount, 0)
            guard total < AttachmentLimits.maxBytesPerNote else {
                return AttachmentLimits.maxBytesPerNote
            }
            return min(
                AttachmentLimits.maxBytesPerNote,
                total > AttachmentLimits.maxBytesPerNote - validByteCount
                    ? AttachmentLimits.maxBytesPerNote
                    : total + validByteCount
            )
        }
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
        let metadata = attachments.map {
            AttachmentFileReference($0, includePayload: false)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await attachmentFileStore.reconcileMetadata(metadata)
                let neededKeys = Set(report.needsMaterialization.map {
                    "\($0.id.uuidString)/\($0.digest.lowercased())"
                })
                let repairs = attachments.compactMap { attachment -> AttachmentFileReference? in
                    let key = "\(attachment.id.uuidString)/\(attachment.contentDigest.lowercased())"
                    return neededKeys.contains(key) ? AttachmentFileReference(attachment) : nil
                }
                let repairFailures = await attachmentFileStore.repairMaterializations(repairs)
                for failure in report.failures + repairFailures {
                    NSLog(
                        "Attic attachment reconciliation skipped %@: %@",
                        failure.attachmentID.uuidString,
                        failure.message
                    )
                }
            } catch {
                NSLog("Attic attachment reconciliation failed: %@", error.localizedDescription)
            }
        }
    }

    private func updateAttachmentImportProgress(
        requestID: UUID,
        completed: Int,
        total: Int
    ) {
        updateAttachmentImportState(
            .importing(completed: completed, total: total),
            requestID: requestID
        )
    }

    private func updateAttachmentImportState(
        _ state: AttachmentImportState,
        requestID: UUID
    ) {
        guard var activity = attachmentImportActivity,
              activity.requestID == requestID else { return }
        activity.state = state
        attachmentImportActivity = activity
    }

    private func clearAttachmentImportActivity(requestID: UUID) {
        guard attachmentImportActivity?.requestID == requestID else { return }
        attachmentImportActivity = nil
    }

    private func removeMaterializationsAfterSuccessfulSave(
        _ references: [AttachmentFileReference]
    ) {
        guard !references.isEmpty else { return }
        Task { [attachmentFileStore] in
            try? await attachmentFileStore.removeMaterializations(references)
        }
    }

    private func removeImportedMaterializations(
        _ imported: [ImportedAttachment]
    ) async throws {
        guard !imported.isEmpty else { return }
        try await attachmentFileStore.removeMaterializations(
            imported.map {
                AttachmentFileReference(
                    id: $0.id,
                    digest: $0.digest,
                    filename: $0.filename,
                    payload: nil
                )
            }
        )
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
