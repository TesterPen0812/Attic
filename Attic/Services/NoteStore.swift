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
    let ownerLabel: String
    var originWasPersisted: Bool
    var state: AttachmentImportState
}

enum NoteAttachmentImportPresentation: Equatable {
    case idle
    case current(AttachmentImportState)
    case background(ownerLabel: String, state: AttachmentImportState)
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
    let deletedAt: Date?
    let deletedAttachmentIDsRaw: String?
    let tagsRaw: String

    init(_ note: NoteItem) {
        id = note.id
        title = note.title
        body = note.body
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        deletedAt = note.deletedAt
        deletedAttachmentIDsRaw = note.deletedAttachmentIDsRaw
        tagsRaw = note.tagsRaw
    }
}

private struct PresentationIndex {
    let revision: UInt64
    let ordered: [NoteItem]
    let byID: [UUID: NoteItem]
}

private enum NoteReplicaMutationError: LocalizedError {
    case missingReplica(UUID)
    case notRecentlyDeleted(UUID)
    case attachmentOwnersDisagree(UUID)

    var errorDescription: String? {
        switch self {
        case let .missingReplica(id):
            "The note replicas for \(id.uuidString) could not be loaded safely."
        case let .notRecentlyDeleted(id):
            "The note \(id.uuidString) is not in Recently Deleted."
        case .attachmentOwnersDisagree:
            "Copies of this attachment belong to different notes, so it can’t be removed safely. Refresh and try again."
        }
    }
}

#if os(macOS)
/// Every stored field of an attachment row, bytes included.
private struct NoteAttachmentReplicaSnapshot: Equatable {
    let id: UUID
    let noteID: UUID
    let originalFilename: String
    let contentTypeIdentifier: String
    let byteCount: Int64
    let sortIndex: Int64
    let inlineOffset: Int?
    let displayWidth: Double?
    let displayHeight: Double?
    let contentDigest: String
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let payload: Data?

    init(_ row: NoteAttachment) {
        id = row.id
        noteID = row.noteID
        originalFilename = row.originalFilename
        contentTypeIdentifier = row.contentTypeIdentifier
        byteCount = row.byteCount
        sortIndex = row.sortIndex
        inlineOffset = row.inlineOffset
        displayWidth = row.displayWidth
        displayHeight = row.displayHeight
        contentDigest = row.contentDigest
        createdAt = row.createdAt
        updatedAt = row.updatedAt
        deletedAt = row.deletedAt
        payload = row.payload
    }
}

private struct NotePresentationSnapshot {
    let notes: [NoteItem]
    let attachments: [NoteAttachment]
}

private enum NotePersistenceRefreshOutcome {
    case persisted
    case persistedButRefreshFailed(String)
    case failed(String)
}
#endif

/// Local-first store for notes, sharing the same CloudKit-backed container as
/// tasks. It follows the same invariants as `TaskStore`: deduplicate physical
/// replicas only for presentation, apply mutations to every replica, replace
/// the long-lived `ModelContext` after a CloudKit import, and hold a bounded
/// `ProcessInfo` activity assertion around export/import windows so the
/// `LSUIElement` Mac app does not nap while Core Data is mirroring.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [NoteItem] = [] {
        didSet { presentationIndex = nil }
    }
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var revision: UInt64 = 0
    /// Test/diagnostic seam for PERF-A3: body-only callers derive at most once
    /// per update, while editor-originated saves can supply the exact batch.
    private(set) var attachmentAnchorFallbackDerivations = 0
    @Published private(set) var cloudSyncStatus = CloudSyncStatus()
#if os(macOS)
    @Published private(set) var attachmentsByNoteID: [UUID: [NoteAttachment]] = [:]
    @Published private(set) var attachmentImportActivity: NoteAttachmentImportActivity?
    @Published private(set) var attachmentFailures: [UUID: String] = [:]
    @Published private(set) var attachmentRetryVersions: [UUID: UInt64] = [:]

    var attachmentImportState: AttachmentImportState {
        attachmentImportActivity?.state ?? .idle
    }
#endif

    let container: ModelContainer
#if os(macOS)
    private let attachmentFileStore: AttachmentFileStore
    private let attachmentImporter: any NoteAttachmentFileImporting
#endif
    private var context: ModelContext
    private var presentationIndex: PresentationIndex?
    private let now: () -> Date
    private let persist: (ModelContext) throws -> Void
    private let makeFreshContext: () throws -> ModelContext
    private(set) var remoteChangeObservation: AnyCancellable?
    private(set) var cloudKitEventObservation: AnyCancellable?
    private(set) var cloudImportRefreshTask: Task<Void, Never>?
    private var cloudSyncProtection = CloudSyncProtectionState()
#if os(macOS)
    private(set) var exportActivityToken: NSObjectProtocol?
    private(set) var importActivityToken: NSObjectProtocol?
    private(set) var exportActivityTimeoutTask: Task<Void, Never>?
    private(set) var importActivityTimeoutTask: Task<Void, Never>?
    private var attachmentImportInFlight = false
    private var invalidatedAttachmentImportIDs = Set<UUID>()
    private var attachmentReconciliationTask: Task<Void, Never>?
    private var attachmentReconciliationGeneration: UInt64 = 0
    private var reconciledAttachmentSignature: Int?
    /// Test/diagnostic seam: how many full metadata reconciliations ran.
    private(set) var attachmentReconciliationPasses = 0
    private static let cloudSyncActivityTimeout: Duration = .seconds(120)
#endif

    init(
        container: ModelContainer,
        now: @escaping () -> Date = Date.init,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
        attachmentFileStore: NoteAttachmentFileStore? = nil,
        attachmentImporter: NoteAttachmentImporter? = nil,
        makeFreshContext: (() throws -> ModelContext)? = nil
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
        self.makeFreshContext = makeFreshContext ?? { ModelContext(container) }
        refresh()
        observeRemoteChanges()
        observeCloudKitEvents()
    }

    @discardableResult
    func create(id: UUID = UUID(), title: String = "", body: String = "") -> NoteItem? {
        let normalizedTitle = Self.normalizedTitle(title)
        guard !normalizedTitle.isEmpty || Self.hasMeaningfulBody(body) else { return nil }

        // An id that belongs to a note in Recently Deleted is never reused: a
        // live replica beside deleted ones would make the copies disagree and
        // could resurrect the deleted note's attachments. A draft that reserved
        // that id simply gets a new note (callers adopt the returned id).
        var resolvedID = id
        if let existing = try? storedNotesIncludingDeleted(matching: id),
           existing.contains(where: { $0.deletedAt != nil }) {
            resolvedID = UUID()
        }
        let timestamp = now()
        let note = NoteItem(
            id: resolvedID,
            title: normalizedTitle,
            body: body,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        context.insert(note)
        notes.append(note)
        guard save() else { return nil }
#if os(macOS)
        markAttachmentImportOriginPersisted(noteID: resolvedID)
#endif
        return note
    }

    @discardableResult
    func update(
        _ note: NoteItem,
        title: String? = nil,
        body: String? = nil,
        bodyEditBatch: NoteBodyEditBatch? = nil
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
        let bodyChanged = !NoteTextReplacement.utf16Equal(destinationBody, note.body)
        let visibleSnapshot = NoteReplicaSnapshot(note)
        let replicasNeedRepair = replicas.contains { NoteReplicaSnapshot($0) != visibleSnapshot }
        guard titleChanged || bodyChanged || replicasNeedRepair else { return true }

        let timestamp = now()
        if bodyChanged {
            do {
                let attachments = try storedAttachments(forNoteID: note.id)
                // One ordered edit list per save: paragraphs that survive
                // between disjoint edits keep their anchors instead of
                // collapsing into one spanning replacement.
                let hasInlineAttachments = attachments.contains { $0.inlineOffset != nil }
                let edits: [NoteTextReplacement]
                if !hasInlineAttachments {
                    edits = []
                } else if let supplied = bodyEditBatch?.validatedEdits(
                    from: note.body,
                    to: destinationBody
                ) {
                    edits = supplied
                } else {
                    attachmentAnchorFallbackDerivations += 1
                    edits = NoteTextReplacement.edits(from: note.body, to: destinationBody)
                }
                for attachment in attachments {
                    if let offset = attachment.inlineOffset {
                        attachment.inlineOffset = NoteInlineAnchor.moved(offset, by: edits, in: destinationBody)
                    }
                }
            } catch {
                context.rollback()
                lastErrorMessage = error.localizedDescription
                return false
            }
        }
        for replica in replicas {
            replica.title = destinationTitle
            replica.body = destinationBody
            replica.createdAt = note.createdAt
            replica.tagsRaw = note.tagsRaw
            replica.deletedAt = nil
            replica.deletedAttachmentIDsRaw = nil
            replica.updatedAt = timestamp
        }
        return save()
    }

    /// Tags are metadata: setting them does not move the note in the
    /// newest-first list (its `updatedAt` is kept), on every replica.
    @discardableResult
    func setTags(_ tags: [String], for note: NoteItem) -> Bool {
        guard let note = notes.first(where: { $0.id == note.id }) else { return false }
        let encoded = AtticTag.encode(tags)
        do {
            let replicas = try storedNotes(matching: note.id)
            guard replicas.contains(where: { $0.tagsRaw != encoded }) else { return true }
            for replica in replicas { replica.tagsRaw = encoded }
        } catch {
            context.rollback()
            lastErrorMessage = error.localizedDescription
            return false
        }
        return save()
    }

    /// Moves a note to Recently Deleted. Every replica is marked; the note's
    /// attachment rows, their bytes and their files are left exactly as they
    /// are, so a restore brings everything back. An import still copying into
    /// this note is refused when it finishes, as before.
    @discardableResult
    func delete(_ note: NoteItem) -> Bool {
        guard let note = notes.first(where: { $0.id == note.id }) else { return false }
        let replicas: [NoteItem]
        let attachmentFamily: String
        do {
            replicas = try storedNotes(matching: note.id)
#if os(macOS)
            // Every attachment row the note holds now, shown or removed:
            // exactly what a purge 30 days later may remove with it.
            attachmentFamily = Set(try storedAttachments(forNoteID: note.id).map(\.id))
                .map(\.uuidString).sorted().joined(separator: " ")
#else
            attachmentFamily = ""
#endif
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
#if os(macOS)
        let attachmentImportIDToInvalidate = attachmentImportInFlight
            && attachmentImportActivity?.origin.noteID == note.id
            ? attachmentImportActivity?.requestID
            : nil
#endif
        // `updatedAt` is kept, so a restored note returns to its place in
        // the newest-first list.
        let timestamp = now()
        for replica in replicas {
            replica.deletedAt = timestamp
            replica.deletedAttachmentIDsRaw = attachmentFamily
        }
        notes.removeAll { $0.id == note.id }
#if os(macOS)
        attachmentsByNoteID[note.id] = nil
#endif
        guard save() else { return false }
#if os(macOS)
        if let attachmentImportIDToInvalidate {
            invalidatedAttachmentImportIDs.insert(attachmentImportIDToInvalidate)
        }
#endif
        return true
    }

    /// Notes in Recently Deleted, newest deletion first.
    func recentlyDeletedNotes() -> [DeletedItemSummary] {
        do {
            let freshContext = try makeFreshContext()
            let deleted = try freshContext.fetch(FetchDescriptor<NoteItem>(
                predicate: #Predicate { $0.deletedAt != nil }
            ))
#if os(macOS)
            let attachmentNoteIDs = try freshContext.fetch(FetchDescriptor<NoteAttachment>()).map(\.noteID)
            var attachmentCounts: [UUID: Int] = [:]
            for noteID in attachmentNoteIDs { attachmentCounts[noteID, default: 0] += 1 }
#else
            let attachmentCounts: [UUID: Int] = [:]
#endif
            return visibleUniqueNotes(from: deleted).compactMap { note -> DeletedItemSummary? in
                guard let deletedAt = note.deletedAt else { return nil }
                let title = note.title.isEmpty
                    ? String(note.body.split(whereSeparator: \.isNewline).first ?? "")
                    : note.title
                return DeletedItemSummary(
                    ref: AtticItemRef(.note, note.id),
                    title: title,
                    deletedAt: deletedAt,
                    includedCount: attachmentCounts[note.id] ?? 0,
                    retentionStart: deletedAt
                )
            }
            .sorted { lhs, rhs in
                lhs.deletedAt != rhs.deletedAt
                    ? lhs.deletedAt > rhs.deletedAt
                    : lhs.ref.id.uuidString < rhs.ref.id.uuidString
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return []
        }
    }

    /// Brings a note back with its attachments, on every replica, in one
    /// save. Its place in the list is where it was (its `updatedAt` is kept).
    @discardableResult
    func restoreDeleted(noteID: UUID) -> Bool {
        do {
            let replicas = try storedNotesIncludingDeleted(matching: noteID)
            guard replicas.contains(where: { $0.deletedAt != nil }) else {
                throw NoteReplicaMutationError.notRecentlyDeleted(noteID)
            }
            for replica in replicas {
                replica.deletedAt = nil
                replica.deletedAttachmentIDsRaw = nil
            }
        } catch {
            context.rollback()
            lastErrorMessage = error.localizedDescription
            return false
        }
        guard save() else { return false }
#if os(macOS)
        // Reconcile the returning attachments' files in full on the reload.
        reconciledAttachmentSignature = nil
#endif
        do {
            try reloadModels()
        } catch {
            lastErrorMessage = "Restored, but the list could not be refreshed: \(error.localizedDescription)"
        }
        return true
    }

    /// Removes for good the notes deleted before `cutoff`, with their
    /// attachment rows and private files. A note is purged only when every
    /// replica agrees and its attachments are exactly what the delete hid
    /// (none added or changed after it, replicas identical); anything else
    /// keeps it. Returns the purged ids.
    @discardableResult
    func purgeDeleted(before cutoff: Date) -> Set<UUID> {
        var purgedIDs = Set<UUID>()
#if os(macOS)
        var references: [AttachmentFileReference] = []
#endif
        do {
            let deleted = try context.fetch(FetchDescriptor<NoteItem>(
                predicate: #Predicate { $0.deletedAt != nil }
            ))
            let expiredIDs = Set(deleted.filter { ($0.deletedAt ?? .distantFuture) < cutoff }.map(\.id))
            for id in expiredIDs {
                let replicas = try storedNotesIncludingDeleted(matching: id)
                guard let first = replicas.first, first.deletedAt.map({ $0 < cutoff }) == true else { continue }
                let snapshot = NoteReplicaSnapshot(first)
                guard replicas.allSatisfy({ NoteReplicaSnapshot($0) == snapshot }) else { continue }
                // The delete must have recorded its attachment family; a note
                // deleted before that was recorded is kept, not guessed at.
                guard let recordedFamily = first.deletedAttachmentIDs else { continue }
#if os(macOS)
                let attachments = try storedAttachments(forNoteID: id)
                // A file is removed only when no surviving row anywhere holds
                // the same attachment identity; an attachment id that also
                // appears under another note makes the purge ambiguous, so the
                // note waits.
                var shared = false
                for attachmentID in Set(attachments.map(\.id)) {
                    if try storedAttachments(matching: attachmentID).contains(where: { $0.noteID != id }) {
                        shared = true
                        break
                    }
                }
                guard !shared else { continue }
                // The attachments must be exactly what the delete hid: the
                // same ids it recorded (a row that arrived later, whatever
                // its timestamps, has an id outside the record), no row
                // changed after the delete, and the replicas of each
                // attachment identical, bytes included. Anything else keeps
                // the note for now.
                guard Set(attachments.map(\.id)) == recordedFamily,
                      let deletedAt = first.deletedAt,
                      attachments.allSatisfy({ row in
                          row.createdAt <= deletedAt && row.updatedAt <= deletedAt
                              && (row.deletedAt.map { $0 <= deletedAt } ?? true)
                      }),
                      Dictionary(grouping: attachments, by: \.id).values.allSatisfy({ group in
                          guard group.count > 1 else { return true }
                          let snapshot = NoteAttachmentReplicaSnapshot(group[0])
                          return group.dropFirst().allSatisfy { NoteAttachmentReplicaSnapshot($0) == snapshot }
                      }) else { continue }
                references += attachments.map { AttachmentFileReference($0, includePayload: false) }
                attachments.forEach(context.delete)
#else
                _ = recordedFamily
#endif
                replicas.forEach(context.delete)
                purgedIDs.insert(id)
            }
        } catch {
            context.rollback()
            lastErrorMessage = error.localizedDescription
            return []
        }
        guard !purgedIDs.isEmpty else { return [] }
        guard save() else { return [] }
#if os(macOS)
        removeMaterializationsAfterSuccessfulSave(references)
#endif
        return purgedIDs
    }

#if os(macOS)
    func attachments(for noteID: UUID) -> [NoteAttachment] {
        attachmentsByNoteID[noteID] ?? []
    }

    func attachmentImportState(for editorSession: NoteEditorSession) -> AttachmentImportState {
        guard attachmentImportActivity?.editorSession == editorSession else { return .idle }
        return attachmentImportState
    }

    func attachmentImportPresentation(
        for editorSession: NoteEditorSession
    ) -> NoteAttachmentImportPresentation {
        guard let activity = attachmentImportActivity else { return .idle }
        if activity.editorSession == editorSession {
            return .current(activity.state)
        }
        return .background(ownerLabel: activity.ownerLabel, state: activity.state)
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
        let originWasPersistedByDefinition: Bool
        switch request.origin {
        case .note:
            originWasPersistedByDefinition = true
        case .blankDraft:
            originWasPersistedByDefinition = false
        }
        attachmentImportInFlight = true
        attachmentImportActivity = NoteAttachmentImportActivity(
            requestID: request.id,
            editorSession: request.editorSession,
            origin: request.origin,
            ownerLabel: attachmentImportOwnerLabel(for: request.origin),
            originWasPersisted: originWasPersistedByDefinition,
            state: .importing(completed: 0, total: request.urls.count)
        )
        defer {
            attachmentImportInFlight = false
            invalidatedAttachmentImportIDs.remove(request.id)
        }
        var imported: [ImportedAttachment] = []
        var transactionContext: ModelContext?

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
            if originWasPersistedAtStart {
                markAttachmentImportOriginPersisted(noteID: targetNoteID)
            }

            let existing = try visibleAttachments(forNoteID: targetNoteID)
            guard let baseSortIndex = AttachmentLimits.nextSortIndex(
                after: existing.map(\.sortIndex).max(),
                adding: request.urls.count
            ) else {
                throw AttachmentFileStoreError.sortIndexExhausted
            }
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
            let refreshedContext = try makeFreshContext()
            transactionContext = refreshedContext
            let originWasPersisted = attachmentImportActivity?.requestID == request.id
                ? attachmentImportActivity?.originWasPersisted ?? originWasPersistedAtStart
                : originWasPersistedAtStart
            switch request.origin {
            case .note:
                // The file copy can yield to CloudKit refresh notifications.
                // Recheck the logical note before committing attachments so a
                // note deleted remotely during the copy cannot gain orphaned
                // attachment rows. Re-read its attachments as well: a remote
                // insert during the copy must not let this batch exceed the
                // per-note limit or reuse stale sort indexes.
                _ = try storedNotes(matching: targetNoteID, in: refreshedContext)
            case .blankDraft:
                let noteReplicas = try storedNotesIfPresent(
                    matching: targetNoteID,
                    in: refreshedContext
                )
                if noteReplicas.isEmpty {
                    // If this reserved origin had already become durable and is
                    // now absent, deletion wins over the attachment completion.
                    guard !originWasPersisted else {
                        throw NoteReplicaMutationError.missingReplica(targetNoteID)
                    }
                    let timestamp = now()
                    refreshedContext.insert(NoteItem(
                        id: targetNoteID,
                        title: "",
                        body: "",
                        createdAt: timestamp,
                        updatedAt: timestamp
                    ))
                }
            }

            try Task.checkCancellation()
            let currentAttachments = try visibleAttachments(
                forNoteID: targetNoteID,
                in: refreshedContext
            )
            guard currentAttachments.count <= AttachmentLimits.maxAttachmentsPerNote,
                  imported.count <= AttachmentLimits.maxAttachmentsPerNote - currentAttachments.count else {
                throw AttachmentFileStoreError.tooManyAttachments
            }
            let importedBytes = totalAttachmentBytes(imported)
            let currentBytes = totalAttachmentBytes(currentAttachments)
            guard importedBytes <= AttachmentLimits.maxBytesPerNote - currentBytes else {
                throw AttachmentFileStoreError.noteTooLarge
            }
            guard let currentBaseSortIndex = AttachmentLimits.nextSortIndex(
                after: currentAttachments.map(\.sortIndex).max(),
                adding: imported.count
            ) else {
                throw AttachmentFileStoreError.sortIndexExhausted
            }
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
            references.forEach(refreshedContext.insert)
            // Attachment changes participate in the same note recency as text.
            let timestamp = now()
            for note in try storedNotes(matching: targetNoteID, in: refreshedContext) {
                note.updatedAt = timestamp
            }
            let presentation = try presentationSnapshot(in: refreshedContext)
            switch persistImport(
                in: refreshedContext,
                fallbackPresentation: presentation
            ) {
            case .persisted, .persistedButRefreshFailed:
                clearAttachmentImportActivity(requestID: request.id)
                return .imported(noteID: targetNoteID)
            case let .failed(message):
                try? await removeImportedMaterializations(imported)
                updateAttachmentImportState(.failed(message), requestID: request.id)
                return .failed(message)
            }
        } catch is CancellationError {
            transactionContext?.rollback()
            try? await removeImportedMaterializations(imported)
            clearAttachmentImportActivity(requestID: request.id)
            return .cancelled
        } catch NoteReplicaMutationError.missingReplica {
            transactionContext?.rollback()
            try? await removeImportedMaterializations(imported)
            let message = "The note is no longer available."
            updateAttachmentImportState(.failed(message), requestID: request.id)
            lastErrorMessage = message
            return .originUnavailable
        } catch {
            transactionContext?.rollback()
            try? await removeImportedMaterializations(imported)
            updateAttachmentImportState(
                .failed(error.localizedDescription),
                requestID: request.id
            )
            lastErrorMessage = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// Changes presentation metadata only; image bytes are never decoded or copied here.
    @discardableResult
    func placeAttachment(_ id: UUID, in noteID: UUID, offset: Int?, before targetID: UUID? = nil,
                         size: CGSize? = nil) -> Bool {
        do {
            let all = try storedAttachments(forNoteID: noteID)
            guard all.contains(where: { $0.id == id }) else { return false }
            let note = notes.first { $0.id == noteID }
            let anchor = offset.map { NoteInlineAnchor.paragraphStart($0, in: note?.body ?? "") }
            for replica in all where replica.id == id {
                replica.inlineOffset = anchor
                if let size {
                    replica.displayWidth = min(600, max(150, size.width.isFinite ? size.width : 250))
                    replica.displayHeight = min(400, max(56, size.height.isFinite ? size.height : 56))
                }
                replica.updatedAt = now()
            }
            if size == nil || targetID != nil {
                let current = attachments(for: noteID).map(\.id)
                var order = current.filter { $0 != id }
                // A card dropped on itself is not a reorder: it must stay where
                // it is. `order` no longer holds the source, so a target equal
                // to it missed the lookup and the card was appended to the end
                // (A,B,C dropping A on A produced B,C,A).
                let index = targetID == id
                    ? current.firstIndex(of: id)
                    : targetID.flatMap { order.firstIndex(of: $0) }
                order.insert(id, at: min(index ?? order.endIndex, order.endIndex))
                let indices = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, Int64($0.offset)) })
                for replica in all { replica.sortIndex = indices[replica.id] ?? replica.sortIndex }
            }
            for owner in try storedNotesIfPresent(matching: noteID) { owner.updatedAt = now() }
            guard save() else { return false }
            attachmentsByNoteID[noteID] = visibleUniqueAttachments(from: all)[noteID]
            return true
        } catch {
            context.rollback()
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Removes one attachment into Recently Deleted: every replica is
    /// marked, and its bytes and file stay until the removal is purged 30 days
    /// later. The note moves up the list as for any attachment change.
    /// Replicas that claim different notes are refused and left exactly as
    /// they are: which note owns the attachment is unresolved, and removing
    /// it from one note must not hide it from another.
    @discardableResult
    func removeAttachment(_ attachment: NoteAttachment) -> Bool {
        let replicas: [NoteAttachment]
        do {
            replicas = try storedAttachments(matching: attachment.id)
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        guard let noteID = replicas.first?.noteID, replicas.allSatisfy({ $0.noteID == noteID }) else {
            lastErrorMessage = NoteReplicaMutationError.attachmentOwnersDisagree(attachment.id).localizedDescription
            return false
        }
        let timestamp = now()
        do {
            for note in try storedNotesIfPresent(matching: noteID) { note.updatedAt = timestamp }
        } catch {
            context.rollback()
            lastErrorMessage = error.localizedDescription
            return false
        }
        for replica in replicas {
            replica.deletedAt = timestamp
            replica.updatedAt = timestamp
        }
        for noteID in attachmentsByNoteID.keys {
            attachmentsByNoteID[noteID]?.removeAll { $0.id == attachment.id }
        }
        guard save() else { return false }
        attachmentFailures[attachment.id] = nil
        attachmentRetryVersions[attachment.id] = nil
        // What is shown changed without a reload; the next presentation
        // (a restore, a refresh) must reconcile files again, not match the
        // signature from before the removal and skip its repair.
        reconciledAttachmentSignature = nil
        return true
    }

    /// Attachments removed from notes that are still shown, newest first.
    func recentlyDeletedAttachments() -> [DeletedAttachmentSummary] {
        do {
            let rows = try makeFreshContext().fetch(FetchDescriptor<NoteAttachment>(
                predicate: #Predicate { $0.deletedAt != nil }
            ))
            let liveNoteIDs = Set(notes.map(\.id))
            var newest: [UUID: NoteAttachment] = [:]
            for row in rows where liveNoteIDs.contains(row.noteID) {
                if let existing = newest[row.id], existing.updatedAt >= row.updatedAt { continue }
                newest[row.id] = row
            }
            return newest.values.compactMap { row -> DeletedAttachmentSummary? in
                guard let deletedAt = row.deletedAt else { return nil }
                return DeletedAttachmentSummary(
                    attachmentID: row.id,
                    owner: AtticItemRef(.note, row.noteID),
                    filename: row.originalFilename,
                    deletedAt: deletedAt
                )
            }
            .sorted { $0.deletedAt != $1.deletedAt ? $0.deletedAt > $1.deletedAt : $0.attachmentID.uuidString < $1.attachmentID.uuidString }
        } catch {
            lastErrorMessage = error.localizedDescription
            return []
        }
    }

    /// Brings a removed attachment back to its note, every replica, in one save.
    @discardableResult
    func restoreAttachment(_ attachmentID: UUID) -> Bool {
        do {
            let replicas = try storedAttachments(matching: attachmentID)
            guard replicas.contains(where: { $0.deletedAt != nil }),
                  let noteID = replicas.first?.noteID,
                  replicas.allSatisfy({ $0.noteID == noteID }),
                  notes.contains(where: { $0.id == noteID }) else {
                throw NoteReplicaMutationError.notRecentlyDeleted(attachmentID)
            }
            guard attachments(for: noteID).count < AttachmentLimits.maxAttachmentsPerNote else {
                throw AttachmentFileStoreError.tooManyAttachments
            }
            let timestamp = now()
            for replica in replicas {
                replica.deletedAt = nil
                replica.updatedAt = timestamp
            }
            for note in try storedNotes(matching: noteID) { note.updatedAt = timestamp }
        } catch {
            context.rollback()
            lastErrorMessage = error.localizedDescription
            return false
        }
        guard save() else { return false }
        // The reload below reconciles files in full, so a restored
        // attachment whose file went missing is materialised again.
        reconciledAttachmentSignature = nil
        do {
            try reloadModels()
        } catch {
            lastErrorMessage = "Restored, but the note could not be refreshed: \(error.localizedDescription)"
        }
        return true
    }

    /// Removes for good the attachments removed before `cutoff`, when every
    /// replica of the attachment agrees (removed, same note, same bytes).
    /// Returns how many attachments were purged.
    @discardableResult
    func purgeRemovedAttachments(before cutoff: Date) -> Int {
        var references: [AttachmentFileReference] = []
        do {
            let removed = try context.fetch(FetchDescriptor<NoteAttachment>(
                predicate: #Predicate { $0.deletedAt != nil }
            ))
            let ids = Set(removed.filter { ($0.deletedAt ?? .distantFuture) < cutoff }.map(\.id))
            for id in ids {
                let replicas = try storedAttachments(matching: id)
                guard let first = replicas.first,
                      replicas.allSatisfy({
                          ($0.deletedAt ?? .distantFuture) < cutoff && $0.noteID == first.noteID
                              && $0.contentDigest == first.contentDigest
                      }) else { continue }
                references.append(AttachmentFileReference(first, includePayload: false))
                replicas.forEach(context.delete)
            }
        } catch {
            context.rollback()
            lastErrorMessage = error.localizedDescription
            return 0
        }
        guard !references.isEmpty, save() else { return 0 }
        removeMaterializationsAfterSuccessfulSave(references)
        return references.count
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
                guard let current = attachmentsByNoteID.values.lazy.flatMap({ $0 }).first(where: {
                    $0.id == metadata.id && $0.contentDigest == metadata.digest
                }) else { return nil }
                let reference = AttachmentFileReference(current)
                guard let repaired = try await attachmentFileStore.ensureMaterialized(reference) else {
                    reportAttachmentFailure(metadata.id, message: "The original file is missing. Locate it to restore this attachment.")
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
                    $0.id == metadata.id
                        && $0.contentDigest == metadata.digest
                }
            }
            guard stillVisible else {
                // The request is refused either way. The file goes only when
                // no stored row still holds this attachment: one removed into
                // Recently Deleted, or in a deleted note, may have no bytes in
                // its row (`payload` is optional), so its file can be the
                // only copy a restore brings back.
                if !storedRowsReference(metadata) {
                    try? await attachmentFileStore.removeMaterializations([metadata])
                }
                return nil
            }
            if attachmentFailures[metadata.id] != nil { attachmentFailures[metadata.id] = nil }
            return url
        } catch {
            reportAttachmentFailure(metadata.id, message: error.localizedDescription)
            return nil
        }
    }

    /// True when any stored attachment row, shown, removed or in a deleted
    /// note, has this identity and content. A failed read counts as
    /// referenced, so a file is never removed on a guess.
    private func storedRowsReference(_ reference: AttachmentFileReference) -> Bool {
        let targetID = reference.id
        let digest = reference.digest.lowercased()
        do {
            return try context.fetch(FetchDescriptor<NoteAttachment>(
                predicate: #Predicate { $0.id == targetID }
            )).contains { $0.contentDigest.lowercased() == digest }
        } catch {
            return true
        }
    }

    func reportAttachmentFailure(_ id: UUID, message: String) {
        guard attachmentsByNoteID.values.contains(where: { $0.contains(where: { $0.id == id }) }) else { return }
        guard attachmentFailures[id] != message else { return }
        attachmentFailures[id] = message
    }

    func retryAttachment(_ attachment: NoteAttachment) {
        attachmentFailures[attachment.id] = nil
        attachmentRetryVersions[attachment.id, default: 0] &+= 1
    }

    /// Repairs the existing logical attachment using an explicitly selected
    /// original file. Different bytes are rejected rather than replacing it.
    @discardableResult
    func locateAttachment(_ attachment: NoteAttachment, at sourceURL: URL) async -> Bool {
        let id = attachment.id
        let expectedDigest = attachment.contentDigest
        let expectedBytes = attachment.byteCount
        var imported: [ImportedAttachment] = []
        var transactionContext: ModelContext?
        do {
            imported = try await attachmentFileStore.importFiles(
                [sourceURL], baseSortIndex: 0, existingCount: 0, existingBytes: 0
            )
            try Task.checkCancellation()
            guard let original = imported.first,
                  original.digest == expectedDigest,
                  original.byteCount == expectedBytes else {
                throw AttachmentFileStoreError.inaccessible(sourceURL, "Choose the original file; this file has different contents.")
            }
            let refreshedContext = try makeFreshContext()
            transactionContext = refreshedContext
            let replicas = try storedAttachments(matching: id, in: refreshedContext)
            guard replicas.allSatisfy({ $0.contentDigest == expectedDigest && $0.byteCount == expectedBytes }) else {
                throw AttachmentFileStoreError.inaccessible(sourceURL, "The attachment changed while the file was being selected. Retry with its current version.")
            }
            for replica in replicas { replica.payload = original.payload }
            let presentation = try presentationSnapshot(in: refreshedContext)
            if case let .failed(message) = persistImport(in: refreshedContext, fallbackPresentation: presentation) {
                reportAttachmentFailure(id, message: message)
                try? await removeImportedMaterializations(imported)
                return false
            }
            try? await removeImportedMaterializations(imported)
            retryAttachment(attachment)
            return true
        } catch {
            transactionContext?.rollback()
            try? await removeImportedMaterializations(imported)
            var message = error.localizedDescription
            do {
                try reloadModels()
            } catch {
                message += " · Reload failed: \(error.localizedDescription)"
            }
            reportAttachmentFailure(id, message: message)
            return false
        }
    }

    /// The user dismissed the notice; the next save clears it anyway.
    func dismissError() {
        guard lastErrorMessage != nil else { return }
        lastErrorMessage = nil
    }

    func setAttachmentError(_ message: String) {
        lastErrorMessage = message
    }
#endif

    /// Newest first, with a deterministic tiebreak so a refreshed duplicate
    /// keeps its position instead of flickering between physical rows.
    ///
    /// The panel asks for this list several times per note revision and once
    /// per body evaluation, and every read touches persistent-store backed
    /// properties. Memoizing per `revision` — the same pattern as
    /// `TaskStore.snapshotCache` — keeps the sort to once per change
    /// (PERF-14/PERF-008). `notes` invalidates the index on assignment, so a
    /// mutation that fails before its revision bump cannot serve stale rows.
    func orderedNotes() -> [NoteItem] {
        currentPresentationIndex().ordered
    }

    /// Presentation lookup by app-level UUID. `notes` already holds one
    /// visible row per UUID, so this is the deduplicated presentation record —
    /// never a substitute for the replica fetches that mutations use.
    func note(withID id: UUID) -> NoteItem? {
        currentPresentationIndex().byID[id]
    }

    private func currentPresentationIndex() -> PresentationIndex {
        if let presentationIndex, presentationIndex.revision == revision {
            return presentationIndex
        }
        let ordered = notes.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
        let index = PresentationIndex(
            revision: revision,
            ordered: ordered,
            byID: Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
        presentationIndex = index
        return index
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
        #if ATTIC_LOCAL_ONLY
        return
        #else
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
        #endif
    }

    // MARK: - Persistence

    @discardableResult
    private func save() -> Bool {
        do {
            try persist(context)
            lastErrorMessage = nil
            registerSuccessfulLocalSave()
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
        let refreshedContext = try makeFreshContext()
        let presentation = try presentationSnapshot(in: refreshedContext)
        installPresentation(presentation, using: refreshedContext)
    }

    private func registerSuccessfulLocalSave() {
        revision &+= 1
        #if !ATTIC_LOCAL_ONLY
        cloudSyncProtection.noteLocalSave()
        reconcileProtectedCloudSyncActivity(for: .exportData)
        #endif
    }

#if os(macOS)
    private func presentationSnapshot(
        in sourceContext: ModelContext
    ) throws -> NotePresentationSnapshot {
        let fetchedNotes = try sourceContext.fetch(FetchDescriptor<NoteItem>())
        let fetchedAttachments = try sourceContext.fetch(FetchDescriptor<NoteAttachment>())
        return NotePresentationSnapshot(
            notes: fetchedNotes,
            attachments: fetchedAttachments
        )
    }

    private func installPresentation(
        _ presentation: NotePresentationSnapshot,
        using sourceContext: ModelContext
    ) {
        context = sourceContext
        let uniqueNotes = visibleUniqueNotes(from: presentation.notes)
        notes = uniqueNotes.filter { $0.deletedAt == nil }
        // A deleted note's attachments stay stored (and their files stay
        // reconciled below) but are not presented.
        let deletedNoteIDs = Set(uniqueNotes.filter { $0.deletedAt != nil }.map(\.id))
        attachmentsByNoteID = visibleUniqueAttachments(from: presentation.attachments)
            .filter { !deletedNoteIDs.contains($0.key) }
        let availableIDs = Set(attachmentsByNoteID.values.flatMap { $0.map(\.id) })
        attachmentFailures = attachmentFailures.filter { availableIDs.contains($0.key) }
        attachmentRetryVersions = attachmentRetryVersions.filter { availableIDs.contains($0.key) }
        revision &+= 1
        reconcileFileStorage(with: presentation.attachments)
    }

    private func persistImport(
        in transactionContext: ModelContext,
        fallbackPresentation: NotePresentationSnapshot
    ) -> NotePersistenceRefreshOutcome {
        do {
            try persist(transactionContext)
            registerSuccessfulLocalSave()
        } catch {
            let saveError = error.localizedDescription
            transactionContext.rollback()
            do {
                try reloadModels()
                lastErrorMessage = saveError
            } catch {
                lastErrorMessage = "\(saveError) · Reload failed: \(error.localizedDescription)"
            }
            return .failed(lastErrorMessage ?? "Unable to save attachments.")
        }

        do {
            try reloadModels()
            lastErrorMessage = nil
            return .persisted
        } catch {
            // Persistence has already succeeded. Adopt the committed
            // transaction and its precomputed presentation instead of
            // reporting total failure or leaving the old arrays visible.
            installPresentation(fallbackPresentation, using: transactionContext)
            let message = "Attachments were saved and the saved version is shown, but a fresh reload failed: \(error.localizedDescription)"
            lastErrorMessage = message
            return .persistedButRefreshFailed(message)
        }
    }
#else
    private func presentationSnapshot(in sourceContext: ModelContext) throws -> [NoteItem] {
        try sourceContext.fetch(FetchDescriptor<NoteItem>())
    }

    private func installPresentation(_ fetchedNotes: [NoteItem], using sourceContext: ModelContext) {
        context = sourceContext
        notes = visibleUniqueNotes(from: fetchedNotes).filter { $0.deletedAt == nil }
        revision &+= 1
    }
#endif

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

    private func storedNotes(
        matching id: UUID,
        in sourceContext: ModelContext? = nil
    ) throws -> [NoteItem] {
        let replicas = try storedNotesIfPresent(matching: id, in: sourceContext)
        guard !replicas.isEmpty else {
            throw NoteReplicaMutationError.missingReplica(id)
        }
        return replicas
    }

    private func storedNotesIfPresent(
        matching id: UUID,
        in sourceContext: ModelContext? = nil
    ) throws -> [NoteItem] {
        // A note in Recently Deleted is absent for every edit and import: only
        // a restore brings it back. Copies that disagree (some deleted) stay
        // editable, and the edit makes them agree again.
        let replicas = try storedNotesIncludingDeleted(matching: id, in: sourceContext)
        return replicas.allSatisfy({ $0.deletedAt != nil }) ? [] : replicas
    }

    private func storedNotesIncludingDeleted(
        matching id: UUID,
        in sourceContext: ModelContext? = nil
    ) throws -> [NoteItem] {
        let targetID = id
        let descriptor = FetchDescriptor<NoteItem>(
            predicate: #Predicate<NoteItem> { note in
                note.id == targetID
            }
        )
        return try (sourceContext ?? context).fetch(descriptor)
    }

#if os(macOS)
    private func storedAttachments(
        matching id: UUID,
        in sourceContext: ModelContext? = nil
    ) throws -> [NoteAttachment] {
        let targetID = id
        let descriptor = FetchDescriptor<NoteAttachment>(
            predicate: #Predicate<NoteAttachment> { attachment in
                attachment.id == targetID
            }
        )
        let replicas = try (sourceContext ?? context).fetch(descriptor)
        guard !replicas.isEmpty else {
            throw NoteReplicaMutationError.missingReplica(id)
        }
        return replicas
    }

    private func storedAttachments(
        forNoteID noteID: UUID,
        in sourceContext: ModelContext? = nil
    ) throws -> [NoteAttachment] {
        let targetNoteID = noteID
        let descriptor = FetchDescriptor<NoteAttachment>(
            predicate: #Predicate<NoteAttachment> { attachment in
                attachment.noteID == targetNoteID
            }
        )
        return try (sourceContext ?? context).fetch(descriptor)
    }

    private func visibleAttachments(
        forNoteID noteID: UUID,
        in sourceContext: ModelContext? = nil
    ) throws -> [NoteAttachment] {
        let replicas = try storedAttachments(forNoteID: noteID, in: sourceContext)
        return visibleUniqueAttachments(from: replicas)[noteID] ?? []
    }

    private func totalAttachmentBytes(_ attachments: [NoteAttachment]) -> Int64 {
        totalAttachmentBytes(attachments.map(\.byteCount))
    }

    private func totalAttachmentBytes(_ attachments: [ImportedAttachment]) -> Int64 {
        totalAttachmentBytes(attachments.map(\.byteCount))
    }

    private func totalAttachmentBytes(_ byteCounts: [Int64]) -> Int64 {
        AttachmentLimits.cappedByteCount(byteCounts)
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

        // An attachment removed into Recently Deleted is stored but not shown
        // and does not count toward a note's limits.
        return Dictionary(grouping: newestByID.values.filter { $0.deletedAt == nil }) { $0.noteID }
            .mapValues { attachments in
                attachments.sorted {
                    if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
            }
    }

    /// Metadata reconciliation only reads id, digest, filename and byte count.
    /// An unchanged attachment set therefore cannot produce a different report,
    /// so a note-body edit no longer re-runs the full pass (PERF-14/PERF-008).
    /// The first load and every attachment change still reconcile completely,
    /// and a failed or cancelled pass clears the signature so the next
    /// revision retries.
    private func attachmentReconciliationSignature(_ attachments: [NoteAttachment]) -> Int {
        var hasher = Hasher()
        hasher.combine(attachments.count)
        for attachment in attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.contentDigest)
            hasher.combine(attachment.originalFilename)
            hasher.combine(attachment.byteCount)
            // Removing or restoring an attachment changes what is shown.
            hasher.combine(attachment.deletedAt != nil)
        }
        return hasher.finalize()
    }

    private func reconcileFileStorage(with attachments: [NoteAttachment]) {
        let signature = attachmentReconciliationSignature(attachments)
        guard reconciledAttachmentSignature != signature else { return }
        reconciledAttachmentSignature = signature
        attachmentReconciliationPasses += 1
        attachmentReconciliationTask?.cancel()
        attachmentReconciliationGeneration &+= 1
        let generation = attachmentReconciliationGeneration
        let metadata = attachments.map {
            AttachmentFileReference($0, includePayload: false)
        }
        attachmentReconciliationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let report = try await attachmentFileStore.reconcileMetadata(metadata)
                guard !Task.isCancelled, generation == attachmentReconciliationGeneration else { return }
                let neededKeys = Set(report.needsMaterialization.map {
                    "\($0.id.uuidString)/\($0.digest.lowercased())"
                })
                let repairs = attachmentsByNoteID.values.flatMap { $0 }.compactMap { attachment -> AttachmentFileReference? in
                    let key = "\(attachment.id.uuidString)/\(attachment.contentDigest.lowercased())"
                    return neededKeys.contains(key) ? AttachmentFileReference(attachment) : nil
                }
                let repairFailures = await attachmentFileStore.repairMaterializations(repairs)
                guard !Task.isCancelled, generation == attachmentReconciliationGeneration else { return }
                for failure in report.failures + repairFailures {
                    reportAttachmentFailure(failure.attachmentID, message: failure.message)
                    NSLog(
                        "Attic attachment reconciliation skipped %@: %@",
                        failure.attachmentID.uuidString,
                        failure.message
                    )
                }
            } catch {
                // Let the next revision try again rather than trusting a
                // signature whose pass never completed.
                reconciledAttachmentSignature = nil
                NSLog("Attic attachment reconciliation failed: %@", error.localizedDescription)
            }
        }
    }

    private func attachmentImportOwnerLabel(
        for origin: NoteAttachmentImportOrigin
    ) -> String {
        switch origin {
        case .blankDraft:
            return "previous draft"
        case let .note(noteID):
            guard let note = notes.first(where: { $0.id == noteID }) else {
                return "previous note"
            }
            let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return "note “\(String(title.prefix(48)))”"
            }
            let body = note.body
                .split(whereSeparator: \.isNewline)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !body.isEmpty else { return "previous note" }
            return "note “\(String(body.prefix(48)))”"
        }
    }

    private func markAttachmentImportOriginPersisted(noteID: UUID) {
        guard var activity = attachmentImportActivity,
              activity.origin.noteID == noteID,
              !activity.originWasPersisted else { return }
        activity.originWasPersisted = true
        attachmentImportActivity = activity
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
        #if !ATTIC_LOCAL_ONLY
        remoteChangeObservation = NotificationCenter.default.publisher(
            for: .NSPersistentStoreRemoteChange
        )
        .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refresh()
        }
        #endif
    }

    private func observeCloudKitEvents() {
        #if !ATTIC_LOCAL_ONLY
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
        #endif
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

    static func normalizedTitle(_ title: String) -> String {
        title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func hasMeaningfulBody(_ body: String) -> Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func tieBreakKey(for note: NoteItem) -> String {
        [
            note.title,
            note.body,
            String(note.createdAt.timeIntervalSinceReferenceDate.bitPattern),
            String(note.updatedAt.timeIntervalSinceReferenceDate.bitPattern),
            note.deletedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "",
            note.tagsRaw,
            String(reflecting: note.persistentModelID)
        ].joined(separator: "\u{1F}")
    }
}
