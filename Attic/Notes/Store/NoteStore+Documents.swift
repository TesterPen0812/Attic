import Foundation
import CryptoKit
import SwiftData

/// An image imported by the editor but not yet saved. Its bytes stay with
/// the editor session (and its draft journal) until the document that
/// shows it is saved: the attachment row is inserted in the same save as
/// that document, or never (requirement 7).
struct StagedNoteAttachment: Equatable, Sendable {
    let id: UUID
    let filename: String
    let contentTypeIdentifier: String
    let byteCount: Int64
    let digest: String
    let data: Data
}

/// Immutable projection prepared away from the main actor for autosave.
struct PreparedNoteDocument: Sendable {
    let content: Data
    let title: String
    let body: String
    let plainText: String
    let imageCount: Int
    let fileCount: Int
    let firstFileName: String?

    init(_ document: NoteDocument) throws {
        content = try NoteContentCodec.encode(document)
        title = NoteStore.normalizedTitle(document.title)
        body = NoteTextExport.plainBody(document)
        plainText = NoteTextExport.plainText(document)
        imageCount = document.blocks.filter { $0.kind == .image }.count
        fileCount = document.blocks.filter { $0.kind == .file }.count
        firstFileName = document.blocks.first { $0.kind == .file }?.filename
    }
}

enum NoteDocumentStoreError: LocalizedError, Equatable {
    /// No live row has this id: a write that would change nothing fails.
    case noteMissing(UUID)
    /// The note moved on since the caller read it.
    case staleRevision(expected: String, current: String)
    /// Stored by a newer Attic (or unreadable): only its original bytes are kept.
    case readOnly
    case versionMissing(UUID)
    case encodingFailed(String)
    case saveFailed(String)
    case invalidDocument(String)

    var errorDescription: String? {
        switch self {
        case let .noteMissing(id): "No note exists with id \(id.uuidString)."
        case let .staleRevision(expected, current):
            "The note changed since it was read (read revision \(expected), now \(current)). Read it again and retry."
        case .readOnly: "This note was saved by a newer version of Attic and is read-only here."
        case let .versionMissing(id): "No saved version exists with id \(id.uuidString)."
        case let .encodingFailed(message): "The note could not be encoded: \(message)"
        case let .saveFailed(message): message
        case let .invalidDocument(message): message
        }
    }
}

/// What the editor opens.
struct NoteDocumentLoad: Equatable {
    let noteID: UUID
    let content: NoteContent
    let revisionID: UUID?
}

enum NoteAgentWriteOutcome: Equatable {
    /// Written; the note is at this new revision.
    case applied(revisionToken: String)
    /// The note is open in the editor: kept as a pending edit (by id).
    case pending(editID: UUID)
}

enum NoteAgentWriteDisposition: Equatable {
    case proposal, direct, refuse(String)
}

enum NoteMutationFormat: Equatable {
    case legacy
    case document
    case editable
}

struct NoteMutationPreflight {
    let replicas: [NoteItem]
    let canonical: NoteItem
}

private struct NotePreservationState: Hashable {
    let format: Int
    let content: Data?
    let title: String
    let body: String

    init(_ note: NoteItem) {
        format = note.contentFormat
        content = note.content
        title = note.title
        body = note.body
    }
}

/// The note-format side of `NoteStore`: documents, versions, agents'
/// pending edits and reference-aware attachment retention. Every write
/// here stages all of its rows in one context and saves them together, so
/// a document and the version that preserves what it replaced commit (or
/// fail) as one transaction.
extension NoteStore {
    /// Recently Deleted acts on a document placement, not only its row.
    /// saveDocument commits placement, version, derived columns and row
    /// visibility across the replica family in one transaction.
    func removeDocumentAttachment(_ id: UUID, noteID: UUID) -> Bool {
        guard let loaded = loadDocument(noteID: noteID), var document = loaded.content.document,
              document.attachmentIDs.contains(id) else { return false }
        document.blocks.removeAll { $0.attachmentID == id && ($0.kind == .image || $0.kind == .file) }
        switch saveDocument(noteID: noteID, document: document, baseRevisionID: loaded.revisionID) {
        case .success: return true
        case let .failure(error): setAttachmentError(error.localizedDescription); return false
        }
    }

    func restoreDocumentAttachment(_ row: NoteAttachment) -> Bool {
        let noteID = row.noteID
        guard let loaded = loadDocument(noteID: noteID), var document = loaded.content.document else { return false }
        if !document.attachmentIDs.contains(row.id) {
            let past = versions(noteID: noteID).compactMap { version -> (NoteDocument, Int)? in
                guard let data = version.content, let historical = NoteContentCodec.decode(data).document,
                      let index = historical.blocks.firstIndex(where: { $0.attachmentID == row.id }) else { return nil }
                return (historical, index)
            }.first
            let block = past.map { $0.0.blocks[$0.1] } ?? (row.isImage
                ? .image(attachmentID: row.id)
                : .file(attachmentID: row.id, filename: row.originalFilename,
                        contentTypeIdentifier: row.contentTypeIdentifier, byteCount: row.byteCount))
            let index = min(max(1, past?.1 ?? document.blocks.count), document.blocks.count)
            document.blocks.insert(block, at: index)
        }
        switch saveDocument(noteID: noteID, document: document, baseRevisionID: loaded.revisionID) {
        case .success: return true
        case let .failure(error): setAttachmentError(error.localizedDescription); return false
        }
    }

    /// Every writer uses this before touching a physical replica. Format 0
    /// has no document bytes; format 1 must be fully understood. A future or
    /// damaged row makes the entire logical note read-only.
    func noteMutationPreflight(_ noteID: UUID, format: NoteMutationFormat) throws -> NoteMutationPreflight {
        let replicas = try liveReplicas(of: noteID)
        guard let selected = canonical(replicas) else { throw NoteDocumentStoreError.noteMissing(noteID) }
        for replica in replicas {
            switch replica.contentFormat {
            case 0:
                guard replica.content == nil, format != .document || replicas.contains(where: \.usesDocumentFormat) else {
                    throw NoteDocumentStoreError.invalidDocument("This note has not been moved to the new format.")
                }
            case 1:
                guard format != .legacy else { throw NoteDocumentStoreError.readOnly }
                guard let data = replica.content else { throw NoteDocumentStoreError.readOnly }
                let key = ObjectIdentifier(replica)
                let editable: Bool
                if let cached = documentReplicaCapabilityCache[key],
                   cached.revisionID == replica.revisionID, cached.content == data {
                    editable = cached.editable
                } else {
                    editable = NoteContentCodec.decode(data).isEditable
                    countDocumentReplicaDecode()
                    documentReplicaCapabilityCache[key] = (replica.revisionID, data, editable)
                }
                guard editable else {
                    throw NoteDocumentStoreError.readOnly
                }
            default:
                throw NoteDocumentStoreError.readOnly
            }
        }
        return NoteMutationPreflight(replicas: replicas, canonical: selected)
    }

    /// Preserve each different displaced document, including two physical
    /// rows with the same revision token but different bytes or legacy text.
    @discardableResult
    func stageDisplacedReplicas(_ replicas: [NoteItem], reason: NoteVersionReason, timestamp: Date,
                                excludingUnchangedBase baseRevisionID: UUID? = nil) -> Int {
        var seen = Set<NotePreservationState>()
        var inserted = 0
        let baseReplicas = replicas.filter { baseRevisionID != nil && $0.revisionID == baseRevisionID }
        let commonBaseState = Set(baseReplicas.map(NotePreservationState.init)).count == 1
            ? baseReplicas.first.map(NotePreservationState.init) : nil
        for replica in replicas where seen.insert(NotePreservationState(replica)).inserted {
            if baseRevisionID != nil, replica.revisionID == baseRevisionID,
               commonBaseState == NotePreservationState(replica) { continue }
            if let latest = latestVersion(noteID: replica.id), isSameState(latest, replica) { continue }
            stageVersion(of: replica, reason: reason, timestamp: timestamp, context: modelContext)
            inserted += 1
        }
        return inserted
    }

    // MARK: Metadata

    /// Pin to Top / Unpin from Top, on every replica. Metadata, like tags:
    /// the note keeps its place in the newest-first order and its revision.
    @discardableResult
    func setPinned(_ pinned: Bool, noteID: UUID) -> Bool {
        switch setPinnedOutcome(pinned, noteID: noteID) {
        case .changed, .unchanged: return true
        case .failed: return false
        }
    }

    /// What a pin request did to the UUID's whole replica family.
    enum PinResult: Equatable {
        /// At least one replica disagreed and every replica now agrees.
        case changed
        /// Every replica already had the requested state; nothing was written.
        case unchanged
        /// The note is gone or the write was refused or did not save.
        case failed
    }

    /// The replica-aware pin: the store, not a presentation representative,
    /// decides between a mutation and a no-op across every live replica, and
    /// says which happened so history records the actual result.
    @discardableResult
    func setPinnedOutcome(_ pinned: Bool, noteID: UUID) -> PinResult {
        do {
            let replicas = try liveReplicas(of: noteID)
            guard !replicas.isEmpty else { throw NoteDocumentStoreError.noteMissing(noteID) }
            guard replicas.contains(where: { $0.isPinned != pinned }) else { return .unchanged }
            let timestamp = pinned ? currentDate : nil
            for replica in replicas { replica.pinnedAt = timestamp }
        } catch {
            modelContext.rollback()
            recordError(error.localizedDescription)
            return .failed
        }
        return commitStagedChanges() ? .changed : .failed
    }

    // MARK: Search

    /// All notes' search: titles, text and image or file names. Read from
    /// its own context away from the main actor, so typing never waits for
    /// it; the caller keeps its earlier results on screen meanwhile.
    func searchNoteIDs(matching query: String) async throws -> Set<UUID> {
        let container = self.container
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let notes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { note in
                note.deletedAt == nil && (note.title.localizedStandardContains(text)
                    || note.plainText.localizedStandardContains(text)
                    || note.body.localizedStandardContains(text))
            }))
            var ids = Set(notes.map(\.id))
            let files = try context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { attachment in
                attachment.deletedAt == nil && attachment.originalFilename.localizedStandardContains(text)
            }))
            ids.formUnion(files.map(\.noteID))
            return ids
        }.value
    }

    // MARK: Loading

    func loadDocument(noteID: UUID) -> NoteDocumentLoad? {
        guard let note = note(withID: noteID), note.usesDocumentFormat, let data = note.content else { return nil }
        return NoteDocumentLoad(noteID: noteID, content: NoteContentCodec.decode(data), revisionID: note.revisionID)
    }

    // MARK: Saving

    /// Creates a note in the new format. The reserved id must remain stable;
    /// callers that want a new note supply a new id themselves.
    func createDocumentNote(
        id: UUID,
        document: NoteDocument,
        staged: [StagedNoteAttachment] = [],
        prepared: PreparedNoteDocument? = nil,
        tags: [String]? = nil
    ) -> Result<(noteID: UUID, revisionID: UUID), NoteDocumentStoreError> {
        let context = modelContext
        if let existing = try? replicasIncludingDeleted(of: id), !existing.isEmpty {
            if existing.contains(where: { $0.deletedAt != nil }) { return .failure(.noteMissing(id)) }
            // A crashed first save or a legacy row may already own this ID.
            // The caller has no revision proving it may replace that row.
            return .failure(.staleRevision(expected: NoteItem.initialRevisionToken,
                                           current: canonical(existing)?.revisionToken ?? NoteItem.initialRevisionToken))
        }
        let projection: PreparedNoteDocument
        let attachmentPlan: AttachmentStagePlan
        do {
            guard document.isWritableByThisBuild else { throw NoteDocumentStoreError.readOnly }
            projection = try prepared ?? PreparedNoteDocument(document)
            attachmentPlan = try attachmentStagePlan(staged, referencedBy: document, noteID: id)
        } catch let error as NoteDocumentStoreError {
            return .failure(error)
        } catch {
            return .failure(.encodingFailed(error.localizedDescription))
        }
        let timestamp = currentDate
        let note = NoteItem(id: id, createdAt: timestamp, updatedAt: timestamp)
        let revisionID: UUID
        do {
            revisionID = try stage(document, on: [note], timestamp: timestamp, revision: 0, prepared: projection,
                                   tags: tags.map(AtticTag.encode))
            stageAttachments(attachmentPlan, noteID: id, context: context, timestamp: timestamp)
        } catch let error as NoteDocumentStoreError {
            context.rollback()
            return .failure(error)
        } catch {
            context.rollback()
            return .failure(.encodingFailed(error.localizedDescription))
        }
        context.insert(note)
        guard commitStagedChanges() else {
            return .failure(.saveFailed(lastErrorMessage ?? "The note could not be saved."))
        }
        present(note)
        refreshAfterDocumentSave(insertedAttachments: !staged.isEmpty)
        return .success((id, revisionID))
    }

    /// Saves an editor's document to every replica. When the presented copy
    /// moved past `baseRevisionID`, reject the draft. Divergent secondary
    /// replicas are preserved as versions before the family is converged.
    ///
    /// `tags` (the editor's tag set, when the person changed it) is written
    /// in the same transaction as the text, so a title shorthand's text and
    /// tag commit together. When only the tags changed (every replica already
    /// holds this exact document), only the tags are written: like
    /// `setTags`, that neither moves the note nor changes its revision.
    func saveDocument(
        noteID: UUID,
        document: NoteDocument,
        baseRevisionID: UUID?,
        staged: [StagedNoteAttachment] = [],
        prepared: PreparedNoteDocument? = nil,
        tags: [String]? = nil
    ) -> Result<UUID, NoteDocumentStoreError> {
        let preflight: NoteMutationPreflight
        do {
            preflight = try noteMutationPreflight(noteID, format: .document)
        } catch {
            return .failure(error as? NoteDocumentStoreError ?? .noteMissing(noteID))
        }
        let replicas = preflight.replicas
        // The editor based its draft on the presented row. A secondary row
        // arriving later may become the preflight's sorting winner before the
        // page refreshes, but it does not make that presented base stale.
        let main = note(withID: noteID) ?? preflight.canonical
        let presentedRevisionID = main.revisionID
        documentSaveAttempt?(baseRevisionID, presentedRevisionID)
        guard replicas.contains(where: { $0 === main }),
              main.usesDocumentFormat, presentedRevisionID == baseRevisionID else {
            return .failure(.staleRevision(expected: baseRevisionID?.uuidString ?? NoteItem.initialRevisionToken,
                                           current: main.revisionToken))
        }
        let encodedTags = tags.map(AtticTag.encode)
        if staged.isEmpty, let encodedTags, let presentedRevisionID,
           let projection = try? prepared ?? PreparedNoteDocument(document),
           replicas.allSatisfy({ $0.content == projection.content && $0.contentFormat == document.format
               && $0.revisionID == presentedRevisionID }) {
            guard replicas.contains(where: { $0.tagsRaw != encodedTags }) else { return .success(presentedRevisionID) }
            for replica in replicas { replica.tagsRaw = encodedTags }
            guard commitStagedChanges() else {
                return .failure(.saveFailed(lastErrorMessage ?? "The note could not be saved."))
            }
            documentSaveCommitted?(baseRevisionID, presentedRevisionID)
            return .success(presentedRevisionID)
        }
        // Reject an invalid batch before touching any presented replica or
        // displaced version. SwiftData rollback need not restore the same
        // in-memory object graph on every supported macOS version.
        let projection: PreparedNoteDocument
        let attachmentPlan: AttachmentStagePlan
        do {
            guard document.isWritableByThisBuild else { throw NoteDocumentStoreError.readOnly }
            projection = try prepared ?? PreparedNoteDocument(document)
            attachmentPlan = try attachmentStagePlan(staged, referencedBy: document, noteID: noteID)
        } catch let error as NoteDocumentStoreError {
            return .failure(error)
        } catch {
            return .failure(.encodingFailed(error.localizedDescription))
        }
        let timestamp = currentDate
        let context = modelContext
        let priorIDs = Set((NoteContentCodec.decode(main.content ?? Data()).document)?.attachmentIDs ?? [])
        let removedIDs = priorIDs.subtracting(document.attachmentIDs)
        stageDisplacedReplicas(replicas, reason: .replacedByDraft, timestamp: timestamp,
                               excludingUnchangedBase: removedIDs.isEmpty ? baseRevisionID : nil)
        do {
            let revisionID = try stage(document, on: replicas, timestamp: timestamp,
                                       revision: replicas.map(\.revision).max() ?? 0, prepared: projection,
                                       tags: encodedTags)
            stageAttachments(attachmentPlan, noteID: noteID, context: context, timestamp: timestamp)
            let visibilityChanged = try stageAttachmentVisibility(referencedBy: document, noteID: noteID,
                timestamp: timestamp)
            guard commitStagedChanges() else {
                return .failure(.saveFailed(lastErrorMessage ?? "The note could not be saved."))
            }
            refreshAfterDocumentSave(insertedAttachments: !staged.isEmpty || visibilityChanged)
            documentSaveCommitted?(baseRevisionID, presentedRevisionID)
            return .success(revisionID)
        } catch let error as NoteDocumentStoreError {
            context.rollback()
            return .failure(error)
        } catch {
            context.rollback()
            return .failure(.encodingFailed(error.localizedDescription))
        }
    }

    /// Writes `document` and its derived columns onto rows (not saved).
    @discardableResult
    private func stage(_ document: NoteDocument, on replicas: [NoteItem], timestamp: Date, revision: Int64,
                       prepared: PreparedNoteDocument? = nil, tags: String? = nil) throws -> UUID {
        guard document.isWritableByThisBuild else { throw NoteDocumentStoreError.readOnly }
        let projection: PreparedNoteDocument
        do { projection = try prepared ?? PreparedNoteDocument(document) }
        catch { throw NoteDocumentStoreError.encodingFailed(error.localizedDescription) }
        let revisionID = UUID()
        let canonical = canonical(replicas)
        for replica in replicas {
            replica.content = projection.content
            replica.contentFormat = document.format
            replica.title = projection.title
            replica.body = projection.body
            replica.plainText = projection.plainText
            replica.imageCount = projection.imageCount
            replica.fileCount = projection.fileCount
            replica.firstFileName = projection.firstFileName
            replica.revision = revision &+ 1
            replica.revisionID = revisionID
            replica.updatedAt = timestamp
            replica.deletedAt = nil
            replica.deletedAttachmentIDsRaw = nil
            documentReplicaCapabilityCache[ObjectIdentifier(replica)] = (revisionID, projection.content, true)
            if let canonical, canonical !== replica {
                replica.createdAt = canonical.createdAt
                replica.tagsRaw = canonical.tagsRaw
                replica.taskID = canonical.taskID
                replica.pinnedAt = canonical.pinnedAt
            }
            if let tags { replica.tagsRaw = tags }
        }
        return revisionID
    }

    private struct AttachmentStagePlan {
        let new: [StagedNoteAttachment]
        let nextSortIndex: Int64
    }

    /// Validate the proposed document and batch before mutating note rows.
    /// Staged images the document no longer shows (an undone paste) are
    /// ignored, as before.
    private func attachmentStagePlan(
        _ staged: [StagedNoteAttachment],
        referencedBy document: NoteDocument,
        noteID: UUID
    ) throws -> AttachmentStagePlan {
        let shown = Set(document.attachmentIDs)
        guard staged.filter({ shown.contains($0.id) }).allSatisfy({
            $0.byteCount > 0 && $0.byteCount <= AttachmentLimits.maxBytesPerAttachment
                && $0.byteCount == Int64($0.data.count)
                && $0.digest == SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined()
        }) else {
            throw NoteDocumentStoreError.invalidDocument("An image has no complete payload.")
        }
        let rows = try attachmentRows(forNoteID: noteID)
        let existing = Set(rows.map(\.id))
        let visible = Dictionary(rows.filter { shown.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }).values
        let new = staged.filter { shown.contains($0.id) && !existing.contains($0.id) }
        guard shown.count <= AttachmentLimits.maxAttachmentsPerNote,
              shown.isSubset(of: existing.union(new.map(\.id))),
              visible.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= AttachmentLimits.maxBytesPerAttachment }),
              visible.reduce(Int64.zero, { $0 + $1.byteCount }) + new.reduce(Int64.zero, { $0 + $1.byteCount })
                <= AttachmentLimits.maxBytesPerNote else {
            throw NoteDocumentStoreError.invalidDocument("This batch exceeds the note's attachment limits.")
        }
        return AttachmentStagePlan(new: new, nextSortIndex: (rows.map(\.sortIndex).max() ?? -1) &+ 1)
    }

    /// Inserts validated rows; note, rows and versions still save together.
    private func stageAttachments(_ plan: AttachmentStagePlan, noteID: UUID,
                                  context: ModelContext, timestamp: Date) {
        var nextIndex = plan.nextSortIndex
        for item in plan.new {
            let row = NoteAttachment(
                id: item.id,
                noteID: noteID,
                originalFilename: item.filename,
                contentTypeIdentifier: item.contentTypeIdentifier,
                byteCount: item.byteCount,
                sortIndex: nextIndex,
                contentDigest: item.digest,
                createdAt: timestamp,
                payload: item.data
            )
            nextIndex &+= 1
            context.insert(row)
        }
    }

    /// The document, deletion timestamp and displaced version commit in the
    /// same SwiftData save. Undo can restore the same row by referencing it
    /// again; purge waits for versions, drafts and proposals to release it.
    @discardableResult
    private func stageAttachmentVisibility(referencedBy document: NoteDocument, noteID: UUID,
                                           timestamp: Date) throws -> Bool {
        let shown = Set(document.attachmentIDs)
        var changed = false
        for row in try attachmentRows(forNoteID: noteID) {
            if shown.contains(row.id) {
                if row.deletedAt != nil {
                    changed = true
                    row.updatedAt = timestamp
                }
                row.deletedAt = nil
            } else if row.deletedAt == nil {
                row.deletedAt = timestamp
                row.updatedAt = timestamp
                changed = true
            }
        }
        return changed
    }

    private func refreshAfterDocumentSave(insertedAttachments: Bool) {
        // A plain text save changes no attachment: the rows already shown are
        // current. New rows need a reload so they are presented and their
        // files reconciled.
        guard insertedAttachments else { return }
        do {
            try reloadPresentation()
        } catch {
            recordError("Saved, but the note could not be refreshed: \(error.localizedDescription)")
        }
    }

    // MARK: Versions

    /// Keeps the note as it is now as a version, unless the newest version
    /// already holds this exact revision.
    @discardableResult
    func recordVersion(noteID: UUID, reason: NoteVersionReason) -> Bool {
        guard let preflight = try? noteMutationPreflight(noteID, format: .editable) else { return false }
        let inserted = stageDisplacedReplicas(preflight.replicas, reason: reason, timestamp: currentDate)
        if inserted == 0 { return true }
        guard commitStagedChanges() else { return false }
        thinVersions(noteID: noteID)
        return true
    }

    /// Keep every snapshot from the last day, then the newest in each hour
    /// for a week and each day for a month. Proposal bases and recovery bases
    /// remain until their owner is gone. Safety versions taken at exactly the
    /// same instant are kept together so divergent replicas are not collapsed.
    func thinVersions(noteID: UUID) {
        let all = versions(noteID: noteID)
        let targetID = noteID
        let physical = (try? modelContext.fetch(FetchDescriptor<NoteVersion>(
            predicate: #Predicate { $0.noteID == targetID }
        ))) ?? []
        let copies = Dictionary(grouping: physical, by: \.id)
        let protectedIDs = Set(pendingEdits(noteID: noteID).compactMap(\.baseVersionID))
        // If any recovery entry is unreadable, its base is unknown. Keep the
        // whole history until the entry can be inspected safely.
        guard let recoveryBases = try? recoveryProtectedRevisionIDs() else { return }
        let day: TimeInterval = 86_400
        let hour: TimeInterval = 3_600
        let now = currentDate
        var buckets = Set<Int64>()
        var keptTimes = Set<Date>()
        var removed = false
        for version in all {
            if protectedIDs.contains(version.id) || version.sourceRevisionID.map(recoveryBases.contains) == true
                || version.reason == nil {
                keptTimes.insert(version.createdAt)
                continue
            }
            let age = max(0, now.timeIntervalSince(version.createdAt))
            if age < day { keptTimes.insert(version.createdAt); continue }
            if keptTimes.contains(version.createdAt) { continue }
            let bucket: Int64
            if age < 7 * day {
                bucket = Int64(version.createdAt.timeIntervalSince1970 / hour)
            } else if age < 30 * day {
                bucket = Int64(version.createdAt.timeIntervalSince1970 / day) - 1_000_000_000
            } else {
                copies[version.id]?.forEach(modelContext.delete)
                removed = true
                continue
            }
            if buckets.insert(bucket).inserted {
                keptTimes.insert(version.createdAt)
            } else {
                copies[version.id]?.forEach(modelContext.delete)
                removed = true
            }
        }
        if removed { _ = commitStagedChanges() }
    }

    /// Newest first, one per id.
    func versions(noteID: UUID) -> [NoteVersion] {
        let targetID = noteID
        let rows = (try? modelContext.fetch(FetchDescriptor<NoteVersion>(
            predicate: #Predicate { $0.noteID == targetID }
        ))) ?? []
        var seen = Set<UUID>()
        return rows.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id.uuidString > rhs.id.uuidString
        }.filter { seen.insert($0.id).inserted }
    }

    /// Restores a version. What the note holds now is kept as a version
    /// first, in the same save: Restore succeeds only when both commit.
    func restoreVersion(_ versionID: UUID, noteID: UUID) -> Result<String, NoteDocumentStoreError> {
        let preflight: NoteMutationPreflight
        do {
            preflight = try noteMutationPreflight(noteID, format: .editable)
        } catch {
            return .failure(error as? NoteDocumentStoreError ?? .noteMissing(noteID))
        }
        let replicas = preflight.replicas
        let targetID = versionID
        guard let version = ((try? modelContext.fetch(FetchDescriptor<NoteVersion>(
            predicate: #Predicate { $0.id == targetID }
        ))) ?? []).first, version.noteID == noteID else {
            return .failure(.versionMissing(versionID))
        }
        guard version.contentFormat == 0 && version.content == nil
            || (version.contentFormat == NoteDocument.currentFormat
                && version.content.map { NoteContentCodec.decode($0).isEditable } == true) else {
            return .failure(.readOnly)
        }
        let timestamp = currentDate
        let context = modelContext
        stageDisplacedReplicas(replicas, reason: .beforeRestore, timestamp: timestamp)
        let revisionID = UUID()
        let revision = (replicas.map(\.revision).max() ?? 0) &+ 1
        let derived = Self.derivedColumns(content: version.content, format: version.contentFormat,
                                          title: version.title, body: version.body)
        for replica in replicas {
            replica.content = version.contentFormat >= 1 ? version.content : nil
            replica.contentFormat = version.contentFormat
            replica.title = derived.title
            replica.body = derived.body
            replica.plainText = derived.plainText
            replica.imageCount = derived.imageCount
            replica.fileCount = derived.fileCount
            replica.firstFileName = derived.firstFileName
            replica.revision = revision
            replica.revisionID = revisionID
            replica.updatedAt = timestamp
            replica.deletedAt = nil
            replica.deletedAttachmentIDsRaw = nil
            if replica !== preflight.canonical {
                replica.createdAt = preflight.canonical.createdAt
                replica.tagsRaw = preflight.canonical.tagsRaw
                replica.taskID = preflight.canonical.taskID
            }
        }
        if let data = version.content, let restored = NoteContentCodec.decode(data).document {
            do { try stageAttachmentVisibility(referencedBy: restored, noteID: noteID, timestamp: timestamp) }
            catch {
                context.rollback()
                return .failure(.saveFailed(error.localizedDescription))
            }
        }
        guard commitStagedChanges() else {
            return .failure(.saveFailed(lastErrorMessage ?? "The version could not be restored."))
        }
        refreshAfterDocumentSave(insertedAttachments: true)
        return .success(revisionID.uuidString)
    }

    func stageVersion(of replica: NoteItem, reason: NoteVersionReason, timestamp: Date, context: ModelContext) {
        let attachmentIDs: [UUID]
        if replica.usesDocumentFormat, let data = replica.content,
           case let .editable(document) = NoteContentCodec.decode(data) {
            attachmentIDs = document.attachmentIDs
        } else {
            // Legacy, newer or unreadable content: keep every row the note has.
            attachmentIDs = ((try? attachmentRows(forNoteID: replica.id)) ?? [])
                .filter { $0.deletedAt == nil }.map(\.id)
        }
        context.insert(NoteVersion(
            noteID: replica.id,
            createdAt: timestamp,
            reason: reason,
            content: replica.content,
            contentFormat: replica.contentFormat,
            title: replica.title,
            body: replica.body,
            attachmentIDs: attachmentIDs,
            sourceRevisionID: replica.revisionID
        ))
    }

    private func latestVersion(noteID: UUID) -> NoteVersion? {
        let targetID = noteID
        var descriptor = FetchDescriptor<NoteVersion>(
            predicate: #Predicate { $0.noteID == targetID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func isSameState(_ version: NoteVersion, _ note: NoteItem) -> Bool {
        return version.contentFormat == note.contentFormat && version.content == note.content
            && version.title == note.title && version.body == note.body
    }

    /// The replica presentation shows for these rows.
    private func canonical(_ replicas: [NoteItem]) -> NoteItem? {
        Self.canonicalReplicas(from: replicas).first
    }

    static func derivedColumns(content: Data?, format: Int, title: String, body: String)
        -> (title: String, body: String, plainText: String, imageCount: Int, fileCount: Int, firstFileName: String?) {
        guard format >= 1, let content else {
            return (title, body, legacyPlainText(title: title, body: body), 0, 0, nil)
        }
        guard let document = NoteContentCodec.decode(content).document else { return (title, body, title, 0, 0, nil) }
        return (normalizedTitle(document.title), NoteTextExport.plainBody(document), NoteTextExport.plainText(document),
                document.blocks.filter { $0.kind == .image }.count,
                document.blocks.filter { $0.kind == .file }.count,
                document.blocks.first { $0.kind == .file }?.filename)
    }

    // MARK: Agent edits (requirement 5)

    /// An agent's whole-note edit. The note must exist, `baseRevisionToken`
    /// must be the token the agent read, and the write must change a row;
    /// anything else fails. A note on screen receives a proposal instead.
    func agentWrite(
        noteID: UUID,
        baseRevisionToken: String,
        document: NoteDocument,
        agentName: String,
        disposition: NoteAgentWriteDisposition
    ) -> Result<NoteAgentWriteOutcome, NoteDocumentStoreError> {
        if case let .refuse(reason) = disposition { return .failure(.saveFailed(reason)) }
        let preflight: NoteMutationPreflight
        do {
            preflight = try noteMutationPreflight(noteID, format: .document)
        } catch {
            return .failure(error as? NoteDocumentStoreError ?? .noteMissing(noteID))
        }
        let replicas = preflight.replicas
        let current = preflight.canonical
        guard current.revisionToken == baseRevisionToken else {
            return .failure(.staleRevision(expected: baseRevisionToken, current: current.revisionToken))
        }
        if let content = current.content, case let .editable(base) = NoteContentCodec.decode(content) {
            do { try NoteAgentTextSafety.validate(base: base, proposed: document) }
            catch { return .failure(.saveFailed(error.localizedDescription)) }
        }
        let data: Data
        guard document.isWritableByThisBuild else { return .failure(.readOnly) }
        do {
            data = try NoteContentCodec.encode(document)
        } catch {
            return .failure(.encodingFailed(error.localizedDescription))
        }
        let timestamp = currentDate
        if disposition == .proposal {
            // The proposal and the exact base it compared with commit together.
            let baseVersionID = UUID()
            modelContext.insert(NoteVersion(id: baseVersionID, noteID: noteID, createdAt: timestamp,
                                            reason: .beforeAgentEdit, content: current.content,
                                            contentFormat: current.contentFormat, title: current.title, body: current.body,
                                            attachmentIDs: (try? attachmentRows(forNoteID: noteID).map(\.id)) ?? [],
                                            sourceRevisionID: current.revisionID))
            let edit = NotePendingEdit(noteID: noteID, baseRevisionToken: baseRevisionToken,
                                       proposedContent: data, agentName: agentName, createdAt: timestamp,
                                       baseVersionID: baseVersionID)
            modelContext.insert(edit)
            guard commitStagedChanges() else {
                return .failure(.saveFailed(lastErrorMessage ?? "The edit could not be kept."))
            }
            return .success(.pending(editID: edit.id))
        }
        stageDisplacedReplicas(replicas, reason: .beforeAgentEdit, timestamp: timestamp)
        do {
            let revisionID = try stage(document, on: replicas, timestamp: timestamp,
                                       revision: replicas.map(\.revision).max() ?? 0)
            guard commitStagedChanges() else {
                return .failure(.saveFailed(lastErrorMessage ?? "The note could not be saved."))
            }
            return .success(.applied(revisionToken: revisionID.uuidString))
        } catch let error as NoteDocumentStoreError {
            modelContext.rollback()
            return .failure(error)
        } catch {
            modelContext.rollback()
            return .failure(.encodingFailed(error.localizedDescription))
        }
    }

    /// An agent's edit of a legacy note (the old editor handles a note it
    /// has open by itself): the note as it was is kept as a version in the
    /// same save. The caller has checked the base revision.
    func agentUpdateLegacy(_ note: NoteItem, title: String?, body: String?) -> Bool {
        update(note, title: title, body: body, bodyEditBatch: nil,
               preservationReason: .beforeAgentEdit)
    }

    /// Oldest first, one per id.
    func pendingEdits(noteID: UUID) -> [NotePendingEdit] {
        pendingEditFetchCount += 1
        let targetID = noteID
        let rows = (try? modelContext.fetch(FetchDescriptor<NotePendingEdit>(
            predicate: #Predicate { $0.noteID == targetID }
        ))) ?? []
        var seen = Set<UUID>()
        return rows.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id.uuidString < rhs.id.uuidString
        }.filter { seen.insert($0.id).inserted }
    }

    /// Runs when the user leaves a note: each pending edit whose base is
    /// still the note's revision applies (a version first, then the edit,
    /// then the pending row goes, in one save); any other waits for review.
    /// Returns how many applied.
    @discardableResult
    func applyPendingEdits(noteID: UUID) -> Int {
        var applied = 0
        for edit in pendingEdits(noteID: noteID) {
            guard let preflight = try? noteMutationPreflight(noteID, format: .editable) else { break }
            let replicas = preflight.replicas
            let current = preflight.canonical
            let editRows = pendingEditRows(edit.id)
            guard current.revisionToken == edit.baseRevisionToken,
                  let data = edit.proposedContent,
                  case let .editable(document) = NoteContentCodec.decode(data),
                  let baseData = current.content,
                  case let .editable(base) = NoteContentCodec.decode(baseData),
                  (try? NoteAgentTextSafety.validate(base: base, proposed: document)) != nil else {
                if editRows.contains(where: { !$0.needsReview }) {
                    editRows.forEach { $0.needsReview = true }
                    _ = commitStagedChanges()
                }
                continue
            }
            let timestamp = currentDate
            stageDisplacedReplicas(replicas, reason: .beforeAgentEdit, timestamp: timestamp)
            do {
                try stage(document, on: replicas, timestamp: timestamp, revision: replicas.map(\.revision).max() ?? 0)
            } catch {
                modelContext.rollback()
                continue
            }
            editRows.forEach(modelContext.delete)
            if commitStagedChanges() { applied += 1 }
        }
        return applied
    }

    private func pendingEditRows(_ id: UUID) -> [NotePendingEdit] {
        let targetID = id
        return (try? modelContext.fetch(FetchDescriptor<NotePendingEdit>(
            predicate: #Predicate { $0.id == targetID }
        ))) ?? []
    }

    // MARK: Migration gate (requirement 2)

    /// A legacy note as it is shown today, or why it can't be read as one.
    func legacySnapshot(noteID: UUID) -> Result<LegacyNoteSnapshot, LegacyMigrationRefusal> {
        guard let preflight = try? noteMutationPreflight(noteID, format: .legacy) else {
            if let replicas = try? liveReplicas(of: noteID),
               !replicas.isEmpty, replicas.allSatisfy(\.usesDocumentFormat) {
                return .failure(.alreadyMigrated)
            }
            return .failure(.changedSincePlanned)
        }
        let replicas = preflight.replicas
        let current = preflight.canonical
        guard replicas.allSatisfy({ $0.title == current.title && $0.body == current.body }) else {
            return .failure(.replicasDisagree)
        }
        let rows = ((try? attachmentRows(forNoteID: noteID)) ?? []).filter { $0.deletedAt == nil }
        // Replicas of one attachment id must agree on what the gate reads.
        var byID: [UUID: NoteAttachment] = [:]
        for row in rows {
            if let seen = byID[row.id] {
                guard seen.inlineOffset == row.inlineOffset, seen.sortIndex == row.sortIndex,
                      seen.createdAt == row.createdAt, seen.isImage == row.isImage,
                      seen.originalFilename == row.originalFilename,
                      seen.contentTypeIdentifier == row.contentTypeIdentifier,
                      seen.byteCount == row.byteCount, seen.contentDigest == row.contentDigest,
                      seen.payload == row.payload else { return .failure(.replicasDisagree) }
            } else {
                byID[row.id] = row
            }
        }
        return .success(LegacyNoteSnapshot(
            noteID: noteID,
            title: current.title,
            body: current.body,
            attachments: LegacyNoteMigration.displayOrder(byID.values.map {
                .init(id: $0.id, inlineOffset: $0.inlineOffset, sortIndex: $0.sortIndex,
                      createdAt: $0.createdAt, isImage: $0.isImage,
                      filename: $0.originalFilename, contentTypeIdentifier: $0.contentTypeIdentifier,
                      byteCount: $0.byteCount, payload: $0.payload)
            }),
            revisionToken: current.revisionToken
        ))
    }

    /// Commits a verified migration: a "before migration" version, then the
    /// document on every replica, in one save. Title, body and attachment
    /// rows are left exactly as they were (the revert path).
    func commitMigration(_ migration: VerifiedLegacyMigration) -> Result<String, LegacyMigrationRefusal> {
        let plan = migration.plan
        guard case let .success(now) = legacySnapshot(noteID: plan.snapshot.noteID) else {
            return .failure(.changedSincePlanned)
        }
        guard now.revisionToken == plan.snapshot.revisionToken, now.title == plan.snapshot.title,
              now.body == plan.snapshot.body,
              now.attachments == plan.snapshot.attachments else {
            return .failure(.changedSincePlanned)
        }
        guard let preflight = try? noteMutationPreflight(plan.snapshot.noteID, format: .legacy),
              plan.document.isWritableByThisBuild,
              let data = try? NoteContentCodec.encode(plan.document) else {
            return .failure(.changedSincePlanned)
        }
        let replicas = preflight.replicas
        let timestamp = currentDate
        stageDisplacedReplicas(replicas, reason: .beforeMigration, timestamp: timestamp)
        let revisionID = UUID()
        let revision = (replicas.map(\.revision).max() ?? 0) &+ 1
        for replica in replicas {
            replica.content = data
            replica.contentFormat = plan.document.format
            replica.plainText = NoteTextExport.plainText(plan.document)
            replica.imageCount = plan.document.blocks.filter { $0.kind == .image }.count
            replica.fileCount = plan.document.blocks.filter { $0.kind == .file }.count
            replica.firstFileName = plan.document.blocks.first { $0.kind == .file }?.filename
            replica.revision = revision
            replica.revisionID = revisionID
            if replica !== preflight.canonical {
                replica.createdAt = preflight.canonical.createdAt
                replica.tagsRaw = preflight.canonical.tagsRaw
                replica.taskID = preflight.canonical.taskID
                replica.pinnedAt = preflight.canonical.pinnedAt
            }
        }
        guard commitStagedChanges() else {
            return .failure(.saveFailed(lastErrorMessage ?? "unknown error"))
        }
        return .success(revisionID.uuidString)
    }

    // MARK: Retention

    /// Every attachment row a note in the new format shows, a kept version
    /// shows, or a pending agent edit would show. A note whose content this
    /// build can't read keeps all of its rows. Throws on a failed read, so
    /// callers keep everything rather than guess.
    func documentReferencedAttachmentIDs(excludingNoteID excluded: UUID? = nil) throws -> Set<UUID> {
        var ids = try recoveryReferencedAttachmentIDs()
        let notes = try modelContext.fetch(FetchDescriptor<NoteItem>(
            predicate: #Predicate { $0.contentFormat >= 1 }
        ))
        for note in notes {
            if note.id == excluded { continue }
            if let data = note.content, case let .editable(document) = NoteContentCodec.decode(data) {
                ids.formUnion(document.attachmentIDs)
            } else {
                ids.formUnion(try attachmentRows(forNoteID: note.id).map(\.id))
            }
        }
        for version in try modelContext.fetch(FetchDescriptor<NoteVersion>()) {
            if version.noteID == excluded { continue }
            ids.formUnion(version.attachmentIDs)
        }
        for edit in try modelContext.fetch(FetchDescriptor<NotePendingEdit>()) {
            if edit.noteID == excluded { continue }
            guard let data = edit.proposedContent else { continue }
            if case let .editable(document) = NoteContentCodec.decode(data) {
                ids.formUnion(document.attachmentIDs)
            } else {
                ids.formUnion(try attachmentRows(forNoteID: edit.noteID).map(\.id))
            }
        }
        return ids
    }

    /// Stages the removal of purged notes' versions and pending edits.
    func stageRemovalOfHistory(forNoteIDs noteIDs: Set<UUID>) throws {
        let ids = Array(noteIDs)
        try modelContext.fetch(FetchDescriptor<NoteVersion>(
            predicate: #Predicate { ids.contains($0.noteID) }
        )).forEach(modelContext.delete)
        try modelContext.fetch(FetchDescriptor<NotePendingEdit>(
            predicate: #Predicate { ids.contains($0.noteID) }
        )).forEach(modelContext.delete)
    }
}
