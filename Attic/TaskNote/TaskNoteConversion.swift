import AppKit
import Foundation
import SwiftData

/// Add to Tasks creates a fresh task in Now and preserves the note's
/// identity, literal title, writing, files, versions and incoming links.
/// Checkboxes stay writing. Both circle changes use one gated commit and
/// the controller's retained workspace history across projection changes.
@MainActor
enum TaskNoteConversion {
    enum Outcome: Equatable {
        case made(taskID: UUID)
        case refused(String)
    }

    @MainActor private struct ResultGuard {
        let tokens: [WorkspaceModelToken]
        let scopes: [WorkspaceScopeToken]
        func validateCurrent(using coordinator: WorkspaceOperationCoordinator) throws -> Self {
            let context = coordinator.freshContext()
            func semantic(_ token: WorkspaceModelToken) -> WorkspaceModelToken {
                .init(owner: token.owner, replicas: token.replicas.map { replica in
                    var fields = replica.fields
                    // Save/association counters describe writes. The complete
                    // current tokens still guard commit-time races; history
                    // compares physical ownership, membership and user data.
                    if token.owner.entity == .task {
                        fields.removeValue(forKey: "updatedAt"); fields.removeValue(forKey: "associationGeneration")
                    }
                    if token.owner.entity == .association {
                        fields.removeValue(forKey: "taskGeneration"); fields.removeValue(forKey: "noteGeneration")
                    }
                    if token.owner.entity == .association,
                       let dateData = fields["detachedAt"], (try? JSONDecoder().decode(Date.self, from: dateData)) != nil,
                       let idData = fields["detachedPreservationID"], let id = try? JSONDecoder().decode(UUID.self, from: idData),
                       let rows = try? context.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.id == id })),
                       let record = rows.first, record.provenance == "circle removed",
                       rows.allSatisfy({ $0.snapshot == record.snapshot && $0.rootID == record.rootID && $0.provenance == record.provenance }),
                       let snapshot = try? JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot),
                       let taskData = fields["taskID"], let taskID = try? JSONDecoder().decode(UUID.self, from: taskData),
                       snapshot.rootID == taskID, snapshot.members.contains(where: { $0.id == taskID }) {
                        // A chronological Redo Remove retimes the same retired
                        // family. Compare its immutable contents and redirect
                        // identity, not the new deletion group/date/record ID.
                        let normalized = snapshot.members.map { member in
                            WorkspacePurge.Preservation.Member(id: member.id,
                                fields: member.fields.filter { !["deletedAt", "deletionGroupID", "associationGeneration"].contains($0.key) },
                                replicas: member.replicas?.map { $0.filter { !["deletedAt", "deletionGroupID", "associationGeneration"].contains($0.key) } })
                        }
                        if let bytes = try? WorkspaceModelFields.encode(normalized) {
                            fields.removeValue(forKey: "detachedAt")
                            fields["detachedPreservationID"] = bytes
                        }
                    }
                    if token.owner.entity == .note {
                        for key in ["updatedAt", "revision", "revisionID", "associationGeneration"] { fields.removeValue(forKey: key) }
                    }
                    return .init(physicalID: replica.physicalID, fields: fields)
                })
            }
            let current = try tokens.map { try WorkspaceModelToken.read($0.owner, in: context) }
            let currentScopes = try scopes.map { try WorkspaceScopeToken.read($0.scope, in: context) }
            let sameScopes = zip(currentScopes, scopes).allSatisfy { current, expected in
                guard current.scope == expected.scope else { return false }
                let actual = current.members.map(semantic), old = expected.members.map(semantic)
                switch current.scope {
                case .versions:
                    // Later conversions append immutable versions even when
                    // undone. Old version bytes/membership still must agree.
                    return old.allSatisfy { actual.contains($0) }
                case let .preservations(root):
                    let extras = current.members.filter { member in !expected.members.contains { $0.owner == member.owner } }
                    // Undo Remove leaves an immutable, retired recovery row.
                    // It owns no live deletion and must not block Undo Add.
                    guard extras.allSatisfy({ token in token.replicas.allSatisfy { replica in
                        (try? JSONDecoder().decode(UUID.self, from: replica.fields["rootID"] ?? Data())) == root
                            && (try? JSONDecoder().decode(String.self, from: replica.fields["provenance"] ?? Data())) == "circle removed"
                            && (try? JSONDecoder().decode(Date.self, from: replica.fields["retiredAt"] ?? Data())) != nil
                            && replica.fields["purgedAt"] == (try? WorkspaceModelFields.encode(Date?.none))
                    } }) else { return false }
                    return old.allSatisfy { actual.contains($0) }
                case .noteAssociations:
                    let extras = current.members.filter { member in !expected.members.contains { $0.owner == member.owner } }
                    // An undone Add leaves a detached redirect for its fresh
                    // retired task. It cannot authorize active reassociation.
                    guard extras.allSatisfy({ token in token.replicas.allSatisfy { replica in
                        (try? JSONDecoder().decode(Date?.self, from: replica.fields["detachedAt"] ?? Data())) != nil
                            && (try? JSONDecoder().decode(UUID?.self, from: replica.fields["detachedPreservationID"] ?? Data())) != nil
                    } }) else { return false }
                    return old.allSatisfy { actual.contains($0) }
                default: return actual == old
                }
            }
            guard current.map(semantic) == tokens.map(semantic), sameScopes else { throw WorkspaceFoundationError.conflict }
            return Self(tokens: current, scopes: currentScopes)
        }
        static func capture(noteID: UUID, taskID: UUID, using coordinator: WorkspaceOperationCoordinator) throws -> Self {
            let read = try AgentWorkspaceReadSet.capture(taskID: taskID, noteID: noteID, in: coordinator.freshContext())
            let migration = try WorkspaceModelToken.read(.init(entity: .migration, id: taskID), in: coordinator.freshContext())
            return Self(tokens: read.tokens + [migration], scopes: read.scopes)
        }
    }

    private struct Change {
        let envelope: WorkspaceOperationEnvelope
        let stage: (ModelContext) throws -> Void
    }
    @MainActor private final class ResultState {
        var value: ResultGuard?
        var wasPending = false
    }

    static func makeTask(fromNote noteID: UUID, notes: NotesPageController, tasks: TaskStore, workspaceSession: NoteSession? = nil) async -> Outcome {
        let agent = AgentWorkspaceCall.current
        guard let session = workspaceSession ?? notes.active, session.noteID == noteID, !session.isReadOnly else {
            return .refused(String(localized: "This note can't become a task here"))
        }
        guard notes.settleForWorkspaceOperation(session) else { return .refused(String(localized: "Couldn't save the note first")) }
        guard let note = notes.store.note(withID: noteID), note.taskID == nil,
              let before = notes.store.loadDocument(noteID: noteID)?.content.document,
              before.isWritableByThisBuild, !before.requires.contains("taskNote") else {
            return .refused(String(localized: "This note is already a task's note"))
        }
        let title = before.title
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else {
            return .refused(String(localized: "Couldn't make the task"))
        }
        let history = session.engine.history.workspace ?? notes.undoRoute.workspace(for: .note(noteID))
        guard session.engine.history.workspace != nil || session.engine.history.redoOps.isEmpty else {
            return .refused(String(localized: "Couldn't make the task"))
        }
        history.attach(session.engine.history)
        let stamp = session.callbackStamp, tags = note.tags, taskID = UUID(), entryID = UUID(), associationID = UUID()
        let result = ResultState()
        let outcome = await history.performCommand(using: coordinator) {
            let change = try association(noteID: noteID, taskID: taskID, associationID: associationID, title: title, before: before, tags: tags,
                creating: TaskDraft(title: title, tags: tags, status: .todo), coordinator: coordinator,
                historyEffect: WorkspaceModelFields.encode(WorkspaceHistory.ForwardEffect(workspaceID: history.id, entryID: entryID)))
            return .init(entryID: entryID, envelope: change.envelope, sessionValid: { [weak notes, weak session] in
                guard let notes, let session else { return false }
                return (notes.active === session || agent?.session === session) && session.accepts(stamp) && (agent?.valid() ?? true)
            }, stage: change.stage, record: { [weak notes, weak tasks, weak coordinator, weak history] operation, entry in
                guard let notes, let tasks, let coordinator, let history else { return }
                guard notes.undoRoute.alias(.taskWorkspace(taskID), to: history.historyID) else {
                    preconditionFailure("Conversion must retain one workspace history")
                }
                recordConversion(operation: operation, entry: entry, noteID: noteID, taskID: taskID, associationID: associationID,
                    title: title, before: before, tags: tags, result: result, history: history,
                    coordinator: coordinator, notes: notes, tasks: tasks)
            }, publication: .init(steps: [{ [weak notes, weak tasks, weak coordinator, weak history, weak session] _ in
                guard let coordinator else { return }
                result.value = try ResultGuard.capture(noteID: noteID, taskID: taskID, using: coordinator)
                if let notes, let history, let session, session.accepts(stamp), !history.hasNewerPublicationDraft {
                    guard session.engine.history.canPrepareWorkspaceCommand, !session.isImporting else {
                        throw WorkspaceFoundationError.conflict
                    }
                    notes.installCommittedTaskNote(noteID)
                }
                tasks?.refresh()
                WorkspaceCrashHook.reach("B-add-published")
            }]), completion: { [weak notes, weak history, weak session] in
                guard let notes, let history, !history.hasNewerPublicationDraft else { return }
                // A pending conversion may already have opened its task page.
                if session?.usesWorkspaceBinding != true, !history.hasQueuedTyping {
                    await notes.retireConvertedNote(noteID, installingCommittedForm: false)
                }
                if result.wasPending { _ = notes.openTaskPage?(taskID) }
            })
        }
        agent?.observe(outcome)
        result.wasPending = outcome == .unknown || outcome == .publicationPending
        switch outcome {
        case .committed, .publicationPending: return .made(taskID: taskID)
        case .unknown: return .refused(String(localized: "Couldn't finish saving"))
        default: return .refused(String(localized: "Couldn't make the task"))
        }
    }

    private static func recordConversion(operation: UUID, entry: UUID, noteID: UUID, taskID: UUID, associationID: UUID,
        title: String, before: NoteDocument, tags: [String], result: ResultState,
        history: WorkspaceHistory, coordinator: WorkspaceOperationCoordinator, notes: NotesPageController, tasks: TaskStore) {
        history.recordOperation(id: operation, entryID: entry, name: String(localized: "Add to Tasks"),
            coordinator: coordinator) { [weak notes, weak tasks, weak coordinator, weak history] redo, effect in
                guard let notes, let tasks, let coordinator, let history, let expected = result.value else {
                    throw WorkspaceFoundationError.conflict
                }
                if let session = notes.workspaceSessionIfCached(noteID) {
                    guard !session.isImporting, session.engine.textView?.hasMarkedText() != true,
                          session.engine.matchesContentIgnoringFolds(notes.store.loadDocument(noteID: noteID)?.content.document),
                          session.engine.tags == notes.store.note(withID: noteID)?.tags else { throw WorkspaceFoundationError.conflict }
                }
                let current = try expected.validateCurrent(using: coordinator)
                let historyEffect = try WorkspaceModelFields.encode(effect)
                let change = try redo
                    ? association(noteID: noteID, taskID: taskID, associationID: associationID, title: title, before: before, tags: tags,
                        creating: nil, coordinator: coordinator, expected: current, historyEffect: historyEffect, replayOf: operation)
                    : dissociation(noteID: noteID, taskID: taskID, before: before, tags: tags,
                        coordinator: coordinator, expected: current, historyEffect: historyEffect, replayOf: operation)
                return .init(envelope: change.envelope, stage: change.stage,
                    publication: .init(steps: [{ [weak notes, weak tasks, weak coordinator, weak history] _ in
                        guard let coordinator else { return }
                        result.value = try ResultGuard.capture(noteID: noteID, taskID: taskID, using: coordinator)
                        if history?.hasNewerPublicationDraft != true {
                            if let session = notes?.workspaceSessionIfCached(noteID) {
                                guard session.engine.history.canPrepareWorkspaceCommand, !session.isImporting else {
                                    throw WorkspaceFoundationError.conflict
                                }
                            }
                            notes?.installCommittedTaskNote(noteID)
                        }
                        tasks?.refresh()
                    }]), completion: { [weak notes, weak history] in
                        guard history?.hasNewerPublicationDraft != true else { return }
                        guard history?.hasQueuedTyping != true else { return }
                        await notes?.retireConvertedNote(noteID, installingCommittedForm: false)
                    })
            }
    }

    /// The note becomes `taskID`'s own note. Only Redo may return the
    /// task created by this history entry; a new Add always creates a UUID.
    private static func association(noteID: UUID, taskID: UUID, associationID: UUID, title: String, before: NoteDocument, tags: [String],
                              creating draft: TaskDraft?, coordinator: WorkspaceOperationCoordinator,
                              expected: ResultGuard? = nil, historyEffect: Data, replayOf: UUID? = nil) throws -> Change {
        let document = try before.taskSnapshot(title: title)
        let prepared = try PreparedNoteDocument(document)
        let context = coordinator.freshContext()
        let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        guard !rows.isEmpty, rows.allSatisfy({ $0.taskID == nil && $0.deletedAt == nil && $0.tags == tags
            && $0.content.flatMap { NoteContentCodec.decode($0).document } == before }) else { throw WorkspaceFoundationError.conflict }
        guard try associationRows(noteID: noteID, in: context).allSatisfy({ $0.detachedAt != nil }),
              rows.allSatisfy({ $0.associationGeneration == rows[0].associationGeneration }) else { throw WorkspaceFoundationError.conflict }
        let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) })
        let previous = try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.id == associationID }))
        guard draft != nil ? previous.isEmpty : (!previous.isEmpty && previous.allSatisfy({ $0.taskID == taskID && $0.noteID == noteID && $0.detachedAt != nil })) else { throw WorkspaceFoundationError.conflict }
        var writes: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID), .init(entity: .note, id: noteID),
                                           .init(entity: .association, id: associationID)]
        writes.formUnion(versions.values.map { .init(entity: .version, id: $0) })
        if draft == nil {
            writes.formUnion(try context.fetch(FetchDescriptor<TaskDeletionPreservation>())
                .filter { $0.rootID == taskID && $0.retiredAt == nil }.map { .init(entity: .preservation, id: $0.id) })
        }
        let agent = replayOf == nil ? AgentWorkspaceCall.current : nil
        let read = try AgentWorkspaceReadSet.capture(taskID: taskID, noteID: noteID, in: context)
        let baseEnvelope = try coordinator.newEnvelope(intent: "Add to Tasks", reads: coordinator.capture(writes.union(read.tokens.map(\.owner))),
                                                   writes: writes, inverseGuards: expected?.tokens, scopes: expected?.scopes ?? read.scopes, afterDocuments: [noteID: prepared.content], historyEffect: historyEffect, replayOf: replayOf)
        let envelope = try agent?.guarded(baseEnvelope, coordinator: coordinator) ?? baseEnvelope
        return Change(envelope: envelope, stage: { commit in
            if let draft {
                _ = try TaskStore.stageCreation(in: commit, drafts: [draft], ids: [taskID], timestamp: Date(), allowingBlankTitle: true)
            } else {
                try TaskStore.stageRestoreDeleted(in: commit, taskIDs: [taskID], timestamp: Date())
            }
            try NoteStore.stageDocument(in: commit, noteID: noteID, document: document, prepared: prepared,
                                        revisionID: UUID(), versionIDs: versions, tags: [], timestamp: Date())
            let task = try commit.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID }))
            let notes = try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            guard !task.isEmpty else { throw WorkspaceFoundationError.conflict }
            for row in task { row.associationGeneration += 1 }
            for row in notes { row.taskID = taskID; row.associationGeneration += 1 }
            let associations: [TaskNoteAssociation]
            if draft != nil {
                let association = TaskNoteAssociation(id: associationID, taskID: taskID, noteID: noteID)
                commit.insert(association); associations = [association]
            } else {
                associations = try commit.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.id == associationID }))
            }
            for association in associations {
                association.detachedAt = nil; association.detachedPreservationID = nil
                association.taskGeneration = task.map(\.associationGeneration).max() ?? 1
                association.noteGeneration = notes.map(\.associationGeneration).max() ?? 1
            }
            WorkspaceCrashHook.reach("B-add-association")
            try agent?.stageResolution(in: commit)
        })
    }

    /// Undo retires the fresh task, hidden from Recently Deleted, and
    /// returns the note exactly as it was, ordinary, with its tags.
    private static func dissociation(noteID: UUID, taskID: UUID, before: NoteDocument, tags: [String],
                               coordinator: WorkspaceOperationCoordinator, expected: ResultGuard, historyEffect: Data, replayOf: UUID) throws -> Change {
        let prepared = try PreparedNoteDocument(before)
        let context = coordinator.freshContext()
        let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        guard !rows.isEmpty, rows.allSatisfy({ $0.taskID == taskID && $0.deletedAt == nil }) else { throw WorkspaceFoundationError.conflict }
        let links = try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID && $0.detachedAt == nil }))
        let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) })
        let preservation = UUID()
        var writes: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID), .init(entity: .note, id: noteID),
                                           .init(entity: .preservation, id: preservation)]
        writes.formUnion(versions.values.map { .init(entity: .version, id: $0) })
        writes.formUnion(links.map { .init(entity: .association, id: $0.id) })
        let envelope = try coordinator.newEnvelope(intent: "Undo Add to Tasks", reads: coordinator.capture(writes),
                                                   writes: writes, inverseGuards: expected.tokens, scopes: expected.scopes, afterDocuments: [noteID: prepared.content], historyEffect: historyEffect, replayOf: replayOf)
        return Change(envelope: envelope, stage: { commit in
            try NoteStore.stageDocument(in: commit, noteID: noteID, document: before, prepared: prepared,
                                        revisionID: UUID(), versionIDs: versions, tags: tags, timestamp: Date())
            for row in try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) {
                row.taskID = nil; row.associationGeneration += 1
            }
            for link in try commit.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID && $0.detachedAt == nil })) {
                link.detachedAt = Date(); link.detachedPreservationID = preservation; link.noteGeneration += 1; link.taskGeneration += 1
            }
            try stageCircleRetirement(taskID: taskID, preservationID: preservation, in: commit)
        })
    }
}

/// 2026-10-23: circle removal retains the exact family for session Undo,
/// while its ordinary writing has an independent, live lifetime.
extension TaskNoteConversion {
    enum RemovalOutcome: Equatable { case removed(noteID: UUID); case refused(String) }
    static let earlierFilesReason = String(localized: "Move Files into Note before removing from Tasks")
    static let earlierWritingReason = String(localized: "Restore or empty the deleted subtask's writing before removing from Tasks")

    /// Capturing an earlier child hides its whole deletion group. Refuse
    /// while any writing could lose its restore window, including group-only
    /// notes and independently deleted writing in old stores.
    private static func proveEarlierWritingAbsent(taskID: UUID, in context: ModelContext) throws {
        let earlier = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.parentID == taskID && $0.deletedAt != nil }
        guard !earlier.isEmpty else { return }
        let ids = Set(earlier.map(\.id)), groups = Set(earlier.compactMap(\.deletionGroupID))
        let writing = try WorkspaceItemLifecycle.writing(taskIDs: ids, in: context)
        let grouped = try context.fetch(FetchDescriptor<NoteItem>()).contains { $0.deletionGroupID.map(groups.contains) == true }
        guard writing.isEmpty, !grouped else { throw RemovalRefusal.earlierWriting }
    }

    /// Shared by Remove and Undo Add. The reason is stored on the existing
    /// immutable preservation, rather than introducing another lifecycle model.
    static func stageCircleRetirement(taskID: UUID, preservationID: UUID, in context: ModelContext) throws {
        // Recheck in the fresh commit context after journal IO. Undo Add and
        // redo use this boundary too; preflight alone cannot protect new rows.
        try proveEarlierWritingAbsent(taskID: taskID, in: context)
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let ids = Set(all.filter { ($0.id == taskID || $0.parentID == taskID) && $0.deletedAt == nil }.map(\.id))
        let rows = all.filter { ids.contains($0.id) }
        guard rows.allSatisfy({ $0.deletedAt == nil && ($0.id == taskID ? $0.parentID == nil : $0.parentID == taskID) }) else { throw WorkspaceFoundationError.conflict }
        guard rows.contains(where: { $0.id == taskID }) else { throw WorkspaceFoundationError.conflict }
        let date = Date(), group = UUID(), members = Set(rows.map(\.id)).map(\.uuidString).sorted().joined(separator: " ")
        for row in rows {
            row.deletedAt = date; row.deletionRootID = taskID
            row.deletionGroupID = group; row.deletionMembersRaw = members
        }
        WorkspaceCrashHook.reach("B-remove-tasks")
        // Earlier independent deletions keep every field, but their immutable
        // replicas join this family's eventual purge. Undo changes only `rows`.
        let capturedIDs = Set(all.filter { $0.id == taskID || $0.parentID == taskID }.map(\.id))
        let captured = all.filter { capturedIDs.contains($0.id) }
        guard captured.allSatisfy({ $0.deletedAt != nil && ($0.id == taskID ? $0.parentID == nil : $0.parentID == taskID) }) else {
            throw WorkspaceFoundationError.conflict
        }
        for root in Set(captured.filter { !ids.contains($0.id) }.compactMap(\.deletionRootID)) {
            guard let earlier = try TaskStore.guardedDeletedFamily(in: context, rootID: root, before: .distantFuture),
                  Set(earlier.map(\.id)).isSubset(of: capturedIDs) else { throw WorkspaceFoundationError.conflict }
        }
        try WorkspacePurge.stageDeletionCapture(id: preservationID, rootID: taskID, rows: captured,
            deletedAt: date, in: context, provenance: "circle removed")
    }

    static func hasWriting(_ taskID: UUID, in context: ModelContext) -> Bool {
        guard let roots = try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })),
              !roots.isEmpty, roots.allSatisfy({ $0.parentID == nil && $0.deletedAt == nil }),
              let writing = try? WorkspaceItemLifecycle.writing(taskIDs: [taskID], in: context) else { return false }
        return writing.contains { row in
            guard row.deletedAt == nil, let doc = row.content.flatMap({ NoteContentCodec.decode($0).document }) else { return false }
            return documentHasWriting(doc)
        }
    }

    /// An item's writing: anything after its title block (text, files,
    /// objects). The one rule Remove from Tasks and All notes share
    /// ("Writing makes it a note", owner answer 2).
    static func documentHasWriting(_ document: NoteDocument) -> Bool {
        !NoteDocument(blocks: Array(document.blocks.dropFirst())).isEmpty
    }

    /// Prove all legacy entries, including removed and child-held files, have
    /// independently readable note-owned bytes. Metadata alone is insufficient.
    private static func proveFiles(taskID: UUID, noteID: UUID, in context: ModelContext) throws {
        guard case let .family(family) = try TaskAttachmentMigration.inventory(rootID: taskID, in: context), !family.isDeleted else {
            throw WorkspaceFoundationError.conflict
        }
        guard !family.manifest.entries.isEmpty else { return }
        let records = try context.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>(predicate: #Predicate { $0.id == taskID }))
        guard let record = records.first, record.stateRaw == "migrated", record.noteID == noteID,
              records.allSatisfy({ $0.stateRaw == record.stateRaw && $0.noteID == noteID && $0.manifestData == record.manifestData && $0.afterData == record.afterData }),
              let manifest = try? JSONDecoder().decode(TaskAttachmentMigration.Manifest.self, from: record.manifestData),
              family.manifest.entries.allSatisfy({ manifest.entries.contains($0) }) else { throw WorkspaceFoundationError.conflict }
        for entry in family.manifest.entries {
            let id = entry.reference.id
            let files = try context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == id }))
            guard !files.isEmpty, files.allSatisfy({ file in
                guard file.noteID == noteID, let bytes = file.payload else { return false }
                return Int64(bytes.count) == entry.reference.byteCount && NotePayloadDigest.sha256(bytes) == entry.reference.digest.lowercased()
            }) else { throw WorkspaceFoundationError.conflict }
        }
    }

    /// Resolve association UUIDs before checking endpoints, just like task
    /// UUIDs. Filtering first could hide a physical foreign-owner replica.
    static func associationRows(noteID: UUID, in context: ModelContext) throws -> [TaskNoteAssociation] {
        let all = try context.fetch(FetchDescriptor<TaskNoteAssociation>())
        let ids = Set(all.filter { $0.noteID == noteID }.map(\.id))
        let rows = all.filter { ids.contains($0.id) }
        guard rows.allSatisfy({ $0.noteID == noteID }) else { throw WorkspaceFoundationError.conflict }
        for copies in Dictionary(grouping: rows, by: \.id).values {
            let fields = try WorkspaceModelFields.read(copies[0])
            guard try copies.allSatisfy({ try WorkspaceModelFields.read($0) == fields }) else { throw WorkspaceFoundationError.conflict }
        }
        return rows
    }

    private struct RemovalSource {
        let taskID: UUID
        let noteID: UUID
        let before: NoteDocument
        let after: NoteDocument
        let tags: [String]
        let originalTags: [String]
        let tasks: [WorkspaceModelToken.Replica]
        let associations: [WorkspaceModelToken.Replica]
    }

    private static func removalSource(_ taskID: UUID, coordinator: WorkspaceOperationCoordinator) throws -> RemovalSource {
        let context = coordinator.freshContext()
        try proveEarlierWritingAbsent(taskID: taskID, in: context)
        guard hasWriting(taskID, in: context) else { throw WorkspaceFoundationError.conflict }
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let candidateIDs = Set(all.filter { $0.id == taskID || $0.parentID == taskID }.map(\.id))
        let family = all.filter { candidateIDs.contains($0.id) }
        guard family.allSatisfy({ $0.id == taskID ? $0.parentID == nil : $0.parentID == taskID }) else { throw WorkspaceFoundationError.conflict }
        // Previously independently deleted children keep their own deletion.
        // Mixed live/deleted replicas of an input UUID are ambiguous.
        let live = family.filter { $0.deletedAt == nil }
        for (id, copies) in Dictionary(grouping: family, by: \.id) where live.contains(where: { $0.id == id }) {
            let fields = try WorkspaceModelFields.read(copies[0])
            guard try copies.allSatisfy({ try WorkspaceModelFields.read($0) == fields }),
                  !all.contains(where: { $0.parentID == id && id != taskID && $0.deletedAt == nil }) else { throw WorkspaceFoundationError.conflict }
        }
        let writing = try WorkspaceItemLifecycle.writing(taskIDs: Set(live.map(\.id)), in: context)
        let own = writing.filter { $0.deletedAt == nil }
        guard let first = own.first, Set(own.map(\.id)).count == 1, first.taskID == taskID,
              writing.allSatisfy({ $0.id == first.id || $0.deletedAt != nil }),
              let before = first.content.flatMap({ NoteContentCodec.decode($0).document }), before.isWritableByThisBuild,
              before.requires.contains("taskNote"),
              own.allSatisfy({ $0.taskID == taskID && $0.content == first.content && $0.tags == first.tags
                  && $0.associationGeneration == first.associationGeneration }) else { throw WorkspaceFoundationError.conflict }
        let snapshot = WorkspacePurge.Preservation(rootID: taskID, title: live.first { $0.id == taskID }!.title,
            members: try Dictionary(grouping: live, by: \.id).map { id, rows in
                .init(id: id, fields: try WorkspaceModelFields.read(rows[0]))
            }, originals: [])
        let material = try WorkspaceTaskNoteMaterializer.materialize(before, taskID: taskID, preservation: snapshot,
            childOrder: TaskNotePresenter.open(for: taskID)?.model.rows.map(\.id))
        let associations = try associationRows(noteID: first.id, in: context).filter { $0.detachedAt == nil }
        guard associations.allSatisfy({ $0.taskID == taskID }) else { throw WorkspaceFoundationError.conflict }
        return try RemovalSource(taskID: taskID, noteID: first.id, before: before, after: material.document,
            tags: Array(Set(material.tags + first.tags)).sorted(), originalTags: first.tags,
            tasks: live.map { .init(physicalID: $0.persistentModelID, fields: try WorkspaceModelFields.read($0)) },
            associations: associations.map { .init(physicalID: $0.persistentModelID, fields: try WorkspaceModelFields.read($0)) })
    }

    static func removeTask(_ taskID: UUID, notes: NotesPageController, tasks: TaskStore,
                           workspaceSession: NoteSession? = nil) async -> RemovalOutcome {
        if let page = TaskNotePresenter.open(for: taskID), !page.model.resolveFieldDrafts() {
            return .refused(String(localized: "Couldn't save the task's fields first"))
        }
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else { return .refused("Couldn't remove from Tasks") }
        do { try proveEarlierWritingAbsent(taskID: taskID, in: coordinator.freshContext()) }
        catch RemovalRefusal.earlierWriting { return .refused(earlierWritingReason) }
        catch { return .refused(String(localized: "Resolve this item's writing and copies before removing from Tasks")) }
        guard let initial = try? removalSource(taskID, coordinator: coordinator),
              let session = workspaceSession ?? notes.workspaceSession(noteID: initial.noteID),
              session.noteID == initial.noteID, !session.isReadOnly else {
            return .refused(String(localized: "Resolve this item's writing and copies before removing from Tasks"))
        }
        session.engine.refreshCompositionActivity()
        guard session.engine.activity == .idle, session.engine.textView?.hasMarkedText() != true,
              !session.isImporting, notes.settleForWorkspaceOperation(session) else {
            return .refused(String(localized: "Finish typing and save the writing first"))
        }
        let history = session.engine.history.workspace ?? notes.undoRoute.workspace(for: .taskWorkspace(taskID))
        guard session.engine.history.workspace != nil || session.engine.history.redoOps.isEmpty else { return .refused("Couldn't remove from Tasks") }
        history.attach(session.engine.history)
        guard notes.undoRoute.alias(.note(initial.noteID), to: history.historyID) else { return .refused("Couldn't remove from Tasks") }
        let result = ResultState(), entryID = UUID(), stamp = session.callbackStamp, agent = AgentWorkspaceCall.current
        let outcome = await history.performCommand(using: coordinator) {
            let source = try removalSource(taskID, coordinator: coordinator)
            do { try proveFiles(taskID: taskID, noteID: source.noteID, in: coordinator.freshContext()) }
            catch { throw RemovalRefusal.earlierFiles }
            let change = try removal(source, redo: true, coordinator: coordinator,
                effect: WorkspaceModelFields.encode(WorkspaceHistory.ForwardEffect(workspaceID: history.id, entryID: entryID)))
            return .init(entryID: entryID, envelope: change.envelope,
                sessionValid: { session.accepts(stamp) && (agent?.valid() ?? true) }, stage: change.stage,
                record: { [weak notes, weak tasks, weak history, weak coordinator] operation, entry in
                    guard let notes, let tasks, let history, let coordinator else { return }
                    history.recordOperation(id: operation, entryID: entry, name: String(localized: "Remove from Tasks"),
                        coordinator: coordinator, attachmentIDs: Set(source.before.attachmentIDs)) { [weak notes, weak tasks, weak history, weak coordinator] redo, effect in
                        guard let notes, let tasks, let history, let coordinator, let expected = result.value else { throw WorkspaceFoundationError.conflict }
                        if let session = notes.workspaceSessionIfCached(source.noteID) {
                            guard !session.isImporting, session.engine.textView?.hasMarkedText() != true,
                                  session.engine.matchesContentIgnoringFolds(notes.store.loadDocument(noteID: source.noteID)?.content.document),
                                  session.engine.tags == notes.store.note(withID: source.noteID)?.tags else { throw WorkspaceFoundationError.conflict }
                        }
                        let current = try expected.validateCurrent(using: coordinator)
                        let change = try removal(source, redo: redo, coordinator: coordinator,
                            effect: WorkspaceModelFields.encode(effect), expected: current, replayOf: operation)
                        return .init(envelope: change.envelope, stage: change.stage,
                            publication: removalPublication(source, result: result, notes: notes, tasks: tasks, history: history, coordinator: coordinator),
                            completion: { [weak notes, weak history] in
                                guard let notes, let history, !history.hasNewerPublicationDraft, !history.hasQueuedTyping else { return }
                                await notes.retireConvertedNote(source.noteID, installingCommittedForm: false)
                                if !redo { _ = notes.openTaskPage?(source.taskID) }
                            })
                    }
                }, publication: removalPublication(source, result: result, notes: notes, tasks: tasks, history: history, coordinator: coordinator))
        }
        agent?.observe(outcome)
        if [.committed, .publicationPending].contains(outcome) { return .removed(noteID: initial.noteID) }
        do { try proveEarlierWritingAbsent(taskID: taskID, in: coordinator.freshContext()) }
        catch RemovalRefusal.earlierWriting { return .refused(earlierWritingReason) }
        catch { return .refused(String(localized: "Couldn't remove from Tasks")) }
        if (try? proveFiles(taskID: taskID, noteID: initial.noteID, in: coordinator.freshContext())) == nil {
            return .refused(earlierFilesReason)
        }
        return .refused(String(localized: "Couldn't remove from Tasks"))
    }
    private enum RemovalRefusal: Error { case earlierFiles, earlierWriting }

    private static func removalPublication(_ source: RemovalSource, result: ResultState, notes: NotesPageController,
        tasks: TaskStore, history: WorkspaceHistory, coordinator: WorkspaceOperationCoordinator) -> WorkspaceOperationCoordinator.Publication {
        .init(steps: [{ [weak notes, weak tasks, weak history, weak coordinator] _ in
            guard let coordinator else { throw WorkspaceFoundationError.conflict }
            result.value = try ResultGuard.capture(noteID: source.noteID, taskID: source.taskID, using: coordinator)
            if let notes, let history, !history.hasNewerPublicationDraft {
                if let session = notes.workspaceSessionIfCached(source.noteID) {
                    guard session.engine.history.canPrepareWorkspaceCommand, !session.isImporting else { throw WorkspaceFoundationError.conflict }
                }
                notes.installCommittedTaskNote(source.noteID, preservingWritingSelection: true)
            }
            tasks?.refresh()
            WorkspaceCrashHook.reach("B-remove-published")
        }])
    }

    private static func removal(_ source: RemovalSource, redo: Bool, coordinator: WorkspaceOperationCoordinator,
        effect: Data, expected: ResultGuard? = nil, replayOf: UUID? = nil) throws -> Change {
        let taskID = source.taskID, noteID = source.noteID, context = coordinator.freshContext()
        let read = try AgentWorkspaceReadSet.capture(taskID: taskID, noteID: noteID, in: context)
        let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        guard !rows.isEmpty, rows.allSatisfy({ $0.deletedAt == nil && $0.taskID == (redo ? taskID : nil) }) else { throw WorkspaceFoundationError.conflict }
        let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) })
        let preservationID = UUID(), redirectID = UUID()
        let links = try context.fetch(FetchDescriptor<TaskNoteAssociation>()).filter { $0.taskID == taskID && $0.noteID == noteID }
        var writes = Set<WorkspaceOwner>()
        for replica in source.tasks {
            guard let bytes = replica.fields["id"] else { throw WorkspaceFoundationError.unknown }
            writes.insert(.init(entity: .task, id: try JSONDecoder().decode(UUID.self, from: bytes)))
        }
        writes.insert(.init(entity: .note, id: noteID))
        writes.formUnion(versions.values.map { .init(entity: .version, id: $0) })
        writes.formUnion(links.map { .init(entity: .association, id: $0.id) })
        if redo { writes.insert(.init(entity: .preservation, id: preservationID)); if source.associations.isEmpty { writes.insert(.init(entity: .association, id: redirectID)) } }
        else { writes.formUnion(read.tokens.filter { $0.owner.entity == .preservation }.map(\.owner)) }
        let document = redo ? source.after : source.before, prepared = try PreparedNoteDocument(document)
        let agent = replayOf == nil ? AgentWorkspaceCall.current : nil
        let base = try coordinator.newEnvelope(intent: redo ? "Remove from Tasks" : "Undo Remove from Tasks",
            reads: coordinator.capture(writes.union(read.tokens.map(\.owner)).union([.init(entity: .migration, id: taskID)])), writes: writes,
            inverseGuards: expected?.tokens, scopes: expected?.scopes ?? read.scopes,
            afterDocuments: [noteID: prepared.content], historyEffect: effect, replayOf: replayOf)
        return Change(envelope: try agent?.guarded(base, coordinator: coordinator) ?? base, stage: { commit in
            try NoteStore.stageDocument(in: commit, noteID: noteID, document: document, prepared: prepared,
                revisionID: UUID(), versionIDs: versions, tags: redo ? source.tags : source.originalTags, timestamp: Date())
            for row in try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) {
                row.taskID = redo ? nil : taskID; row.associationGeneration += 1
            }
            WorkspaceCrashHook.reach("B-remove-writing")
            if redo {
                let active = try commit.fetch(FetchDescriptor<TaskNoteAssociation>()).filter { $0.taskID == taskID && $0.noteID == noteID && $0.detachedAt == nil }
                if active.isEmpty {
                    let link = TaskNoteAssociation(id: redirectID, taskID: taskID, noteID: noteID)
                    link.detachedAt = Date(); link.detachedPreservationID = preservationID; commit.insert(link)
                } else {
                    for link in active { link.detachedAt = Date(); link.detachedPreservationID = preservationID }
                }
                try stageCircleRetirement(taskID: taskID, preservationID: preservationID, in: commit)
            } else {
                for replica in source.tasks { try WorkspaceModelFields.apply(replica.fields, to: commit.model(for: replica.physicalID)) }
                try WorkspacePurge.stageRetirement(rootIDs: [taskID], timestamp: Date(), in: commit)
                for replica in source.associations { try WorkspaceModelFields.apply(replica.fields, to: commit.model(for: replica.physicalID)) }
                let taskGeneration = try commit.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).map(\.associationGeneration).max() ?? 0
                let noteGeneration = try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })).map(\.associationGeneration).max() ?? 0
                for replica in source.associations {
                    guard let link = commit.model(for: replica.physicalID) as? TaskNoteAssociation, link.detachedAt == nil else { continue }
                    link.taskGeneration = taskGeneration
                    link.noteGeneration = noteGeneration
                }
                // A compatibility task without an association got a redirect
                // on Remove; Undo leaves it detached, retaining old references.
            }
            try agent?.stageResolution(in: commit)
        })
    }
}

extension TaskNoteConversion {
    static func commands(taskID: UUID?, hasWriting: Bool, isSubtask: Bool,
                         add: @escaping () -> Void, remove: @escaping () -> Void) -> [AtticMenuCommand] {
        guard !isSubtask else { return [] }
        if taskID != nil {
            guard hasWriting else { return [] }
            return [AtticMenuCommand("Remove from Tasks", identifier: "one-item-remove-from-tasks", action: remove)]
        }
        return [AtticMenuCommand("Add to Tasks", identifier: "one-item-add-to-tasks", action: add)]
    }
}
