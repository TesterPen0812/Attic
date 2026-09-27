import Foundation
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

    init(_ document: NoteDocument) throws {
        content = try NoteContentCodec.encode(document)
        title = NoteStore.normalizedTitle(document.title)
        body = NoteTextExport.plainBody(document)
        plainText = NoteTextExport.plainText(document)
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

    // MARK: Loading

    func loadDocument(noteID: UUID) -> NoteDocumentLoad? {
        guard let note = note(withID: noteID), note.usesDocumentFormat, let data = note.content else { return nil }
        return NoteDocumentLoad(noteID: noteID, content: NoteContentCodec.decode(data), revisionID: note.revisionID)
    }

    // MARK: Saving

    /// Creates a note in the new format. `id` is the draft's reserved id; a
    /// note in Recently Deleted with that id is never revived (a fresh id is
    /// returned instead).
    func createDocumentNote(
        id: UUID,
        document: NoteDocument,
        staged: [StagedNoteAttachment] = [],
        prepared: PreparedNoteDocument? = nil
    ) -> Result<(noteID: UUID, revisionID: UUID), NoteDocumentStoreError> {
        let context = modelContext
        var resolvedID = id
        if let existing = try? replicasIncludingDeleted(of: id), !existing.isEmpty {
            if existing.contains(where: { $0.deletedAt != nil }) || existing.contains(where: { !$0.usesDocumentFormat }) {
                resolvedID = UUID()
            } else {
                // A crashed first save may already have committed this ID.
                // The caller has no revision proving it may replace that row.
                return .failure(.staleRevision(expected: NoteItem.initialRevisionToken,
                                               current: canonical(existing)?.revisionToken ?? NoteItem.initialRevisionToken))
            }
        }
        let timestamp = currentDate
        let note = NoteItem(id: resolvedID, createdAt: timestamp, updatedAt: timestamp)
        let revisionID: UUID
        do {
            revisionID = try stage(document, on: [note], timestamp: timestamp, revision: 0, prepared: prepared)
            try stageAttachments(staged, referencedBy: document, noteID: resolvedID, context: context, timestamp: timestamp)
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
        return .success((resolvedID, revisionID))
    }

    /// Saves an editor's document to every replica. When the presented copy
    /// moved past `baseRevisionID`, reject the draft. Divergent secondary
    /// replicas are preserved as versions before the family is converged.
    func saveDocument(
        noteID: UUID,
        document: NoteDocument,
        baseRevisionID: UUID?,
        staged: [StagedNoteAttachment] = [],
        prepared: PreparedNoteDocument? = nil
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
        guard replicas.contains(where: { $0 === main }),
              main.usesDocumentFormat, main.revisionID == baseRevisionID else {
            return .failure(.staleRevision(expected: baseRevisionID?.uuidString ?? NoteItem.initialRevisionToken,
                                           current: main.revisionToken))
        }
        let timestamp = currentDate
        let context = modelContext
        stageDisplacedReplicas(replicas, reason: .replacedByDraft, timestamp: timestamp,
                               excludingUnchangedBase: baseRevisionID)
        do {
            let revisionID = try stage(document, on: replicas, timestamp: timestamp,
                                       revision: replicas.map(\.revision).max() ?? 0, prepared: prepared)
            try stageAttachments(staged, referencedBy: document, noteID: noteID, context: context, timestamp: timestamp)
            guard commitStagedChanges() else {
                return .failure(.saveFailed(lastErrorMessage ?? "The note could not be saved."))
            }
            refreshAfterDocumentSave(insertedAttachments: !staged.isEmpty)
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
                       prepared: PreparedNoteDocument? = nil) throws -> UUID {
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
            }
        }
        return revisionID
    }

    /// Inserts rows for the staged images the document shows and that have
    /// no row yet. Staged images the document no longer shows (an undone
    /// paste) are simply not inserted.
    private func stageAttachments(
        _ staged: [StagedNoteAttachment],
        referencedBy document: NoteDocument,
        noteID: UUID,
        context: ModelContext,
        timestamp: Date
    ) throws {
        guard !staged.isEmpty else { return }
        let shown = Set(document.attachmentIDs)
        guard staged.filter({ shown.contains($0.id) }).allSatisfy({
            $0.byteCount > 0 && $0.byteCount <= AttachmentLimits.maxBytesPerAttachment
                && $0.byteCount == Int64($0.data.count) && !$0.digest.isEmpty
        }) else {
            throw NoteDocumentStoreError.invalidDocument("An image has no complete payload.")
        }
        let existing = Set((try? attachmentRows(forNoteID: noteID))?.map(\.id) ?? [])
        let highest = (try? attachmentRows(forNoteID: noteID))?.map(\.sortIndex).max() ?? -1
        var nextIndex = highest &+ 1
        for item in staged where shown.contains(item.id) && !existing.contains(item.id) {
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
        guard commitStagedChanges() else {
            return .failure(.saveFailed(lastErrorMessage ?? "The version could not be restored."))
        }
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
        -> (title: String, body: String, plainText: String) {
        guard format >= 1, let content else {
            return (title, body, legacyPlainText(title: title, body: body))
        }
        guard let document = NoteContentCodec.decode(content).document else { return (title, body, title) }
        return (normalizedTitle(document.title), NoteTextExport.plainBody(document), NoteTextExport.plainText(document))
    }

    // MARK: Agent edits (requirement 5)

    /// An agent's whole-note edit. The note must exist, `baseRevisionToken`
    /// must be the token the agent read, and the write must change a row;
    /// anything else fails. A note open in the editor is not written: the
    /// edit is kept as a pending edit and applies when the note is left.
    func agentWrite(
        noteID: UUID,
        baseRevisionToken: String,
        document: NoteDocument,
        agentName: String,
        noteIsOpen: Bool
    ) -> Result<NoteAgentWriteOutcome, NoteDocumentStoreError> {
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
        let data: Data
        guard document.isWritableByThisBuild else { return .failure(.readOnly) }
        do {
            data = try NoteContentCodec.encode(document)
        } catch {
            return .failure(.encodingFailed(error.localizedDescription))
        }
        let timestamp = currentDate
        if noteIsOpen {
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
                  case let .editable(document) = NoteContentCodec.decode(data) else {
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
                      createdAt: $0.createdAt, isImage: $0.isImage, payload: $0.payload)
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
            replica.revision = revision
            replica.revisionID = revisionID
            if replica !== preflight.canonical {
                replica.createdAt = preflight.canonical.createdAt
                replica.tagsRaw = preflight.canonical.tagsRaw
                replica.taskID = preflight.canonical.taskID
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
