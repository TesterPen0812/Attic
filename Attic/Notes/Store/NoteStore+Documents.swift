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

/// The note-format side of `NoteStore`: documents, versions, agents'
/// pending edits and reference-aware attachment retention. Every write
/// here stages all of its rows in one context and saves them together, so
/// a document and the version that preserves what it replaced commit (or
/// fail) as one transaction.
extension NoteStore {
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
        staged: [StagedNoteAttachment] = []
    ) -> Result<(noteID: UUID, revisionID: UUID), NoteDocumentStoreError> {
        let context = modelContext
        var resolvedID = id
        if let existing = try? replicasIncludingDeleted(of: id), !existing.isEmpty {
            if existing.contains(where: { $0.deletedAt != nil }) || existing.contains(where: { !$0.usesDocumentFormat }) {
                resolvedID = UUID()
            } else {
                // Already created (a retried first save): save into it.
                return saveDocument(noteID: id, document: document, baseRevisionID: existing.first?.revisionID, staged: staged)
                    .map { (id, $0) }
            }
        }
        let timestamp = currentDate
        let note = NoteItem(id: resolvedID, createdAt: timestamp, updatedAt: timestamp)
        let revisionID: UUID
        do {
            revisionID = try stage(document, on: [note], timestamp: timestamp, revision: 0)
        } catch let error as NoteDocumentStoreError {
            return .failure(error)
        } catch {
            return .failure(.encodingFailed(error.localizedDescription))
        }
        context.insert(note)
        stageAttachments(staged, referencedBy: document, noteID: resolvedID, context: context, timestamp: timestamp)
        guard commitStagedChanges() else {
            return .failure(.saveFailed(lastErrorMessage ?? "The note could not be saved."))
        }
        present(note)
        refreshAfterDocumentSave(insertedAttachments: !staged.isEmpty)
        return .success((resolvedID, revisionID))
    }

    /// Saves an editor's document to every replica. When the stored note is
    /// no longer at `baseRevisionID` (a recovered draft, an agent edit that
    /// applied while the note was closed, a divergent replica), what is
    /// stored is first kept as a version, in the same save.
    func saveDocument(
        noteID: UUID,
        document: NoteDocument,
        baseRevisionID: UUID?,
        staged: [StagedNoteAttachment] = []
    ) -> Result<UUID, NoteDocumentStoreError> {
        let replicas: [NoteItem]
        do {
            replicas = try liveReplicas(of: noteID)
        } catch {
            return .failure(.noteMissing(noteID))
        }
        // A legacy note changes format only through the migration gate.
        guard replicas.allSatisfy(\.usesDocumentFormat) else {
            return .failure(.invalidDocument("This note has not been moved to the new format."))
        }
        guard replicas.allSatisfy({ $0.content.map { NoteContentCodec.decode($0).isEditable } ?? false }) else {
            return .failure(.readOnly)
        }
        let timestamp = currentDate
        let context = modelContext
        // Keep every stored state the draft was not based on.
        var preserved = Set<UUID?>()
        for replica in replicas where replica.revisionID != baseRevisionID && !preserved.contains(replica.revisionID) {
            preserved.insert(replica.revisionID)
            stageVersion(of: replica, reason: .replacedByDraft, timestamp: timestamp, context: context)
        }
        do {
            let revisionID = try stage(document, on: replicas, timestamp: timestamp,
                                       revision: replicas.map(\.revision).max() ?? 0)
            stageAttachments(staged, referencedBy: document, noteID: noteID, context: context, timestamp: timestamp)
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
    private func stage(_ document: NoteDocument, on replicas: [NoteItem], timestamp: Date, revision: Int64) throws -> UUID {
        let data: Data
        do {
            data = try NoteContentCodec.encode(document)
        } catch {
            throw NoteDocumentStoreError.encodingFailed(error.localizedDescription)
        }
        let revisionID = UUID()
        let canonical = replicas.first
        let title = Self.normalizedTitle(document.title)
        let body = NoteTextExport.plainBody(document)
        let plainText = NoteTextExport.plainText(document)
        for replica in replicas {
            replica.content = data
            replica.contentFormat = document.format
            replica.title = title
            replica.body = body
            replica.plainText = plainText
            replica.revision = revision &+ 1
            replica.revisionID = revisionID
            replica.updatedAt = timestamp
            replica.deletedAt = nil
            replica.deletedAttachmentIDsRaw = nil
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
    ) {
        guard !staged.isEmpty else { return }
        let shown = Set(document.attachmentIDs)
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
        guard let replicas = try? liveReplicas(of: noteID), let current = canonical(replicas) else { return false }
        if let latest = latestVersion(noteID: noteID), isSameState(latest, current) { return true }
        stageVersion(of: current, reason: reason, timestamp: currentDate, context: modelContext)
        return commitStagedChanges()
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
        let replicas: [NoteItem]
        do {
            replicas = try liveReplicas(of: noteID)
        } catch {
            return .failure(.noteMissing(noteID))
        }
        let targetID = versionID
        guard let version = ((try? modelContext.fetch(FetchDescriptor<NoteVersion>(
            predicate: #Predicate { $0.id == targetID }
        ))) ?? []).first, version.noteID == noteID else {
            return .failure(.versionMissing(versionID))
        }
        let timestamp = currentDate
        let context = modelContext
        if let current = canonical(replicas) {
            stageVersion(of: current, reason: .beforeRestore, timestamp: timestamp, context: context)
        }
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
            attachmentIDs = ((try? attachmentRows(forNoteID: replica.id)) ?? []).map(\.id)
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
        if let source = version.sourceRevisionID, source == note.revisionID { return true }
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
        let replicas: [NoteItem]
        do {
            replicas = try liveReplicas(of: noteID)
        } catch {
            return .failure(.noteMissing(noteID))
        }
        guard let current = canonical(replicas) else { return .failure(.noteMissing(noteID)) }
        guard current.revisionToken == baseRevisionToken else {
            return .failure(.staleRevision(expected: baseRevisionToken, current: current.revisionToken))
        }
        if current.usesDocumentFormat, let data = current.content, !NoteContentCodec.decode(data).isEditable {
            return .failure(.readOnly)
        }
        let data: Data
        do {
            data = try NoteContentCodec.encode(document)
        } catch {
            return .failure(.encodingFailed(error.localizedDescription))
        }
        let timestamp = currentDate
        if noteIsOpen {
            let edit = NotePendingEdit(noteID: noteID, baseRevisionToken: baseRevisionToken,
                                       proposedContent: data, agentName: agentName, createdAt: timestamp)
            modelContext.insert(edit)
            guard commitStagedChanges() else {
                return .failure(.saveFailed(lastErrorMessage ?? "The edit could not be kept."))
            }
            return .success(.pending(editID: edit.id))
        }
        stageVersion(of: current, reason: .beforeAgentEdit, timestamp: timestamp, context: modelContext)
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
        let timestamp = currentDate
        let context = modelContext
        return update(note, title: title, body: body, bodyEditBatch: nil) { [weak self] current in
            self?.stageVersion(of: current, reason: .beforeAgentEdit, timestamp: timestamp, context: context)
        }
    }

    /// Oldest first, one per id.
    func pendingEdits(noteID: UUID) -> [NotePendingEdit] {
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
            guard let replicas = try? liveReplicas(of: noteID), let current = canonical(replicas) else { break }
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
            stageVersion(of: current, reason: .beforeAgentEdit, timestamp: timestamp, context: modelContext)
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
        guard let replicas = try? liveReplicas(of: noteID), let current = canonical(replicas) else {
            return .failure(.changedSincePlanned)
        }
        guard !current.usesDocumentFormat else { return .failure(.alreadyMigrated) }
        guard replicas.allSatisfy({ $0.title == current.title && $0.body == current.body }) else {
            return .failure(.replicasDisagree)
        }
        let rows = ((try? attachmentRows(forNoteID: noteID)) ?? []).filter { $0.deletedAt == nil }
        // Replicas of one attachment id must agree on what the gate reads.
        var byID: [UUID: NoteAttachment] = [:]
        for row in rows {
            if let seen = byID[row.id] {
                guard seen.inlineOffset == row.inlineOffset, seen.sortIndex == row.sortIndex,
                      seen.contentDigest == row.contentDigest else { return .failure(.replicasDisagree) }
            } else {
                byID[row.id] = row
            }
        }
        return .success(LegacyNoteSnapshot(
            noteID: noteID,
            title: current.title,
            body: current.body,
            attachments: byID.values.map {
                .init(id: $0.id, inlineOffset: $0.inlineOffset, sortIndex: $0.sortIndex,
                      createdAt: $0.createdAt, isImage: $0.isImage)
            },
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
              Set(now.attachments.map(\.id)) == Set(plan.snapshot.attachments.map(\.id)) else {
            return .failure(.changedSincePlanned)
        }
        guard let replicas = try? liveReplicas(of: plan.snapshot.noteID), let current = canonical(replicas),
              let data = try? NoteContentCodec.encode(plan.document) else {
            return .failure(.changedSincePlanned)
        }
        let timestamp = currentDate
        stageVersion(of: current, reason: .beforeMigration, timestamp: timestamp, context: modelContext)
        let revisionID = UUID()
        let revision = (replicas.map(\.revision).max() ?? 0) &+ 1
        for replica in replicas {
            replica.content = data
            replica.contentFormat = plan.document.format
            replica.plainText = NoteTextExport.plainText(plan.document)
            replica.revision = revision
            replica.revisionID = revisionID
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
    func documentReferencedAttachmentIDs() throws -> Set<UUID> {
        var ids = Set<UUID>()
        let notes = try modelContext.fetch(FetchDescriptor<NoteItem>(
            predicate: #Predicate { $0.contentFormat >= 1 }
        ))
        for note in notes {
            if let data = note.content, case let .editable(document) = NoteContentCodec.decode(data) {
                ids.formUnion(document.attachmentIDs)
            } else {
                ids.formUnion(try attachmentRows(forNoteID: note.id).map(\.id))
            }
        }
        for version in try modelContext.fetch(FetchDescriptor<NoteVersion>()) {
            ids.formUnion(version.attachmentIDs)
        }
        for edit in try modelContext.fetch(FetchDescriptor<NotePendingEdit>()) {
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
