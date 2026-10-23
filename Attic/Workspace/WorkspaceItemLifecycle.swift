import Foundation
import SwiftData

/// 2026-10-23: the two persisted endpoints are one deletable item. Membership
/// lives on the rows themselves; there is no additional manifest or redirect.
@MainActor
enum WorkspaceItemLifecycle {
    static func has(_ name: String, in context: ModelContext) -> Bool {
        context.container.schema.entities.contains { $0.name == name }
    }
    static func taskOwner(noteID: UUID, in context: ModelContext) throws -> UUID? {
        let notes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        let links = has("TaskNoteAssociation", in: context)
            ? try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID && $0.detachedAt == nil })) : []
        let ids = Set(notes.compactMap(\.taskID)).union(links.map(\.taskID))
        guard ids.count <= 1 else { throw WorkspaceFoundationError.conflict }
        guard let id = ids.first, has("TaskItem", in: context) else { return nil }
        let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        return tasks.contains(where: { $0.deletedAt == nil }) ? id : nil
    }
    static func writing(taskIDs: Set<UUID>, in context: ModelContext) throws -> [NoteItem] {
        guard has("NoteItem", in: context) else { return [] }
        let all = try context.fetch(FetchDescriptor<NoteItem>())
        let links = has("TaskNoteAssociation", in: context) ? try context.fetch(FetchDescriptor<TaskNoteAssociation>()) : []
        let ids = Set(all.filter { $0.taskID.map(taskIDs.contains) == true }.map(\.id))
            .union(links.filter { taskIDs.contains($0.taskID) && $0.detachedAt == nil }.map(\.noteID))
        let rows = all.filter { ids.contains($0.id) }
        guard rows.allSatisfy({ $0.taskID == nil || taskIDs.contains($0.taskID!) }),
              links.filter({ ids.contains($0.noteID) && $0.detachedAt == nil }).allSatisfy({ taskIDs.contains($0.taskID) }) else {
            throw WorkspaceFoundationError.conflict
        }
        return rows
    }
    static func stageWritingDeletion(_ rows: [NoteItem], group: UUID, timestamp: Date, in context: ModelContext) throws {
        WorkspaceLegacyBridge.markItemLifecycle(in: context)
        let attachments = has("NoteAttachment", in: context) ? try context.fetch(FetchDescriptor<NoteAttachment>()) : []
        WorkspaceLegacyBridge.prepareMutations(rows, in: context)
        for row in rows where row.deletedAt == nil {
            row.deletedAt = timestamp
            row.deletionGroupID = group
            row.deletedAttachmentIDsRaw = Set(attachments.filter { $0.noteID == row.id }.map(\.id))
                .map(\.uuidString).sorted().joined(separator: " ")
        }
        WorkspaceCrashHook.reach("A-delete-writing")
    }
    static func stageDeletion(rootID: UUID, tasks: [TaskItem], group: UUID = UUID(), timestamp: Date,
                              in context: ModelContext) throws {
        let live = tasks.filter { $0.deletedAt == nil }
        guard !live.isEmpty else { throw WorkspaceFoundationError.conflict }
        let members = Set(live.map(\.id)).map(\.uuidString).sorted().joined(separator: " ")
        let notes = try writing(taskIDs: Set(tasks.map(\.id)), in: context)
        WorkspaceLegacyBridge.prepareMutations(tasks, in: context)
        for row in live {
            row.deletedAt = timestamp; row.deletionRootID = rootID
            row.deletionMembersRaw = members; row.deletionGroupID = group
        }
        WorkspaceCrashHook.reach("A-delete-tasks")
        try stageWritingDeletion(notes, group: group, timestamp: timestamp, in: context)
        try WorkspacePurge.stageDeletionCapture(rootID: rootID, rows: tasks, deletedAt: timestamp, in: context)
    }
    /// Old independent deletions continue through their existing restore path.
    /// Only matching group rows return, preserving each physical row's fields.
    static func stageRestore(group: UUID, timestamp: Date, in context: ModelContext, validateTasks: Bool = true) throws {
        WorkspaceLegacyBridge.markItemLifecycle(in: context)
        let tasks = has("TaskItem", in: context) ? try context.fetch(FetchDescriptor<TaskItem>()) : []
        let notes = has("NoteItem", in: context) ? try context.fetch(FetchDescriptor<NoteItem>()) : []
        let restoringTasks = tasks.filter { $0.deletionGroupID == group }
        let restoringNotes = notes.filter { $0.deletionGroupID == group }
        guard !restoringTasks.isEmpty || !restoringNotes.isEmpty,
              restoringTasks.allSatisfy({ $0.deletedAt != nil }), restoringNotes.allSatisfy({ $0.deletedAt != nil }) else {
            throw WorkspaceFoundationError.conflict
        }
        let roots = Set(restoringTasks.compactMap(\.deletionRootID))
        let dates = Set(restoringTasks.compactMap(\.deletedAt) + restoringNotes.compactMap(\.deletedAt))
        guard dates.count == 1, let date = dates.first else { throw WorkspaceFoundationError.conflict }
        let records = has("TaskDeletionPreservation", in: context) ? try context.fetch(FetchDescriptor<TaskDeletionPreservation>()).filter {
            roots.contains($0.rootID) && $0.deletedAt == date && $0.retiredAt == nil
        } : []
        let snapshots = try records.map { try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: $0.snapshot) }
        for root in roots {
            let batch = restoringTasks.filter { $0.deletionRootID == root }
            guard let first = batch.first, first.deletionMembers.contains(root),
                  Set(batch.map(\.id)) == first.deletionMembers,
                  batch.allSatisfy({ $0.deletionMembersRaw == first.deletionMembersRaw }) else {
                throw TaskReplicaMutationError.incompleteRestore(root)
            }
            if let parent = batch.first(where: { $0.id == root })?.parentID,
               !restoringTasks.contains(where: { $0.id == parent }) {
                let parents = tasks.filter { $0.id == parent }
                guard parents.isEmpty || parents.contains(where: { $0.deletedAt == nil }) else { throw TaskReplicaMutationError.parentNotLive(root) }
            }
        }
        // A late live replica must agree. A foreign deletion is left alone
        // only with immutable evidence that it already existed at deletion.
        for row in restoringTasks {
            let peers = tasks.filter { $0.id == row.id && $0.deletionGroupID != group }
            for peer in peers {
                if peer.deletedAt == nil {
                    guard TaskContentSnapshot(peer) == TaskContentSnapshot(row) else { throw TaskReplicaMutationError.divergentLiveCopy(row.id) }
                } else {
                    let fields = try WorkspaceModelFields.read(peer)
                    guard snapshots.flatMap(\.members).filter({ $0.id == row.id }).contains(where: {
                        ($0.replicas ?? [$0.fields]).contains(fields)
                    }) else { throw TaskReplicaMutationError.incompleteRestore(row.id) }
                }
            }
        }
        for row in restoringNotes {
            let peers = notes.filter { $0.id == row.id && $0.deletedAt == nil }
            guard peers.allSatisfy({ $0.content == row.content && $0.taskID == row.taskID && $0.tagsRaw == row.tagsRaw }) else {
                throw WorkspaceFoundationError.conflict
            }
        }
        for snapshot in snapshots {
            for dependency in snapshot.dependencies ?? [] where dependency.owner.entity == .note {
                guard notes.contains(where: { $0.id == dependency.owner.id }) else { throw WorkspaceFoundationError.conflict }
            }
        }
        // Capture every physical replica of each logical owner before a
        // subset changes, including late live and previously deleted copies.
        WorkspaceLegacyBridge.prepareMutations(tasks.filter { row in restoringTasks.contains { $0.id == row.id } }, in: context)
        WorkspaceLegacyBridge.prepareMutations(notes.filter { row in restoringNotes.contains { $0.id == row.id } }, in: context)
        try WorkspacePurge.stageRetirement(rootIDs: roots, timestamp: timestamp, deletedAt: date, in: context)
        for row in restoringTasks {
            row.deletedAt = nil; row.deletionGroupID = nil; row.deletionRootID = nil; row.deletionMembersRaw = ""
        }
        for row in restoringNotes {
            row.deletedAt = nil; row.deletionGroupID = nil; row.deletedAttachmentIDsRaw = nil
        }
    }
}

extension WorkspaceItemLifecycle {
    /// One irreversible group boundary. Full tokens include every physical
    /// member and every ownership query; any ambiguity retains the group.
    static func purge(group: UUID, before cutoff: Date, confirmed: Date?, coordinator: WorkspaceOperationCoordinator,
                      files: TaskImageFiles, inventory: () throws -> WorkspacePurge.Inventory?,
                      publication: WorkspaceOperationCoordinator.Publication) async -> WorkspacePurge.Result {
        func refused(_ outcome: WorkspaceOperationCoordinator.Outcome = .conflict, line: Int = #line) -> WorkspacePurge.Result {
            print("GROUP PURGE REFUSED", line, outcome)
            return .init(outcome: outcome, operationID: nil, removedIDs: [], preservationID: nil)
        }
        do {
            let context = coordinator.freshContext()
            let initial = try WorkspaceLegacyBridge.inventory(in: context, includeCanvas: false)
            let index = try WorkspaceScopeIndex(initial)
            let allTasks = try context.fetch(FetchDescriptor<TaskItem>())
            let allNotes = try context.fetch(FetchDescriptor<NoteItem>())
            let tasks = allTasks.filter { $0.deletionGroupID == group }
            let notes = allNotes.filter { $0.deletionGroupID == group }
            let taskIDs = Set(tasks.map(\.id)), noteIDs = Set(notes.map(\.id))
            let dates = Set(tasks.compactMap(\.deletedAt) + notes.compactMap(\.deletedAt))
            guard let date = dates.first, dates.count == 1, date < cutoff,
                  confirmed == nil || confirmed == date, !tasks.isEmpty || !notes.isEmpty,
                  allTasks.filter({ taskIDs.contains($0.id) }).allSatisfy({ $0.deletionGroupID == group && $0.deletedAt == date }),
                  allNotes.filter({ noteIDs.contains($0.id) }).allSatisfy({ $0.deletionGroupID == group && $0.deletedAt == date }),
                  let ownership = try inventory(), ownership.drafts.isEmpty,
                  noteIDs.isDisjoint(with: ownership.blockedNotes),
                  noteIDs.allSatisfy({ ownership.sessions[$0]?.canCommit ?? true }),
                  noteIDs.allSatisfy({ !coordinator.recoveryDependsOnNote($0) }),
                  coordinator.collectionProtectedRecoveryBytes != nil else { return refused() }
            for root in Set(tasks.compactMap(\.deletionRootID)) {
                guard let family = try TaskStore.guardedDeletedFamily(in: context, rootID: root, before: cutoff, confirmed: confirmed),
                      Set(family.map(\.id)).isSubset(of: taskIDs) else { return refused() }
            }
            let allAttachments = try context.fetch(FetchDescriptor<NoteAttachment>())
            let attachments = allAttachments.filter { noteIDs.contains($0.noteID) }
            let attachmentIDs = Set(attachments.map(\.id))
            guard allAttachments.filter({ attachmentIDs.contains($0.id) }).allSatisfy({ noteIDs.contains($0.noteID) }) else { return refused() }
            for note in notes {
                guard note.deletedAttachmentIDs == Set(attachments.filter { $0.noteID == note.id }.map(\.id)) else { return refused() }
            }
            guard attachments.allSatisfy({ $0.createdAt <= date && $0.updatedAt <= date && ($0.deletedAt.map { $0 <= date } ?? true) }) else { return refused() }
            let versions = try context.fetch(FetchDescriptor<NoteVersion>())
            let proposals = try context.fetch(FetchDescriptor<NotePendingEdit>())
            let ownVersions = versions.filter { noteIDs.contains($0.noteID) }
            let ownProposals = proposals.filter { noteIDs.contains($0.noteID) }
            let versionIDs = Set(ownVersions.map(\.id)), proposalIDs = Set(ownProposals.map(\.id))
            guard versions.filter({ versionIDs.contains($0.id) }).allSatisfy({ noteIDs.contains($0.noteID) }),
                  proposals.filter({ proposalIDs.contains($0.id) }).allSatisfy({ noteIDs.contains($0.noteID) }),
                  proposals.filter({ !noteIDs.contains($0.noteID) }).allSatisfy({ $0.baseVersionID.map { !versionIDs.contains($0) } ?? true }) else { return refused() }
            let associations = try context.fetch(FetchDescriptor<TaskNoteAssociation>())
            let associationIDs = Set(associations.filter { taskIDs.contains($0.taskID) || noteIDs.contains($0.noteID) }.map(\.id))
            let touchingAssociations = associations.filter { associationIDs.contains($0.id) }
            guard touchingAssociations.allSatisfy({ $0.detachedAt != nil || taskIDs.contains($0.taskID) }),
                  try writing(taskIDs: taskIDs, in: context).filter({ $0.deletedAt == nil }).isEmpty else { return refused() }
            // Previously deleted writing stays independently restorable via
            // its existing detached association and immutable preservation.
            let olderNotes = allNotes.filter { $0.taskID.map(taskIDs.contains) == true && !noteIDs.contains($0.id) }
            guard olderNotes.allSatisfy({ $0.deletedAt != nil }) else { return refused() }
            let touching: Set<AtticItemRef> = Set(taskIDs.map { .init(.task, $0) } + noteIDs.map { .init(.note, $0) })
            let allLinks = try context.fetch(FetchDescriptor<ItemLink>())
            let linkIDs = Set(allLinks.filter { $0.source.map(touching.contains) == true || $0.target.map(touching.contains) == true }.map(\.id))
            let links = allLinks.filter { linkIDs.contains($0.id) }
            let roots = Set(tasks.compactMap(\.deletionRootID))
            let preservations = try context.fetch(FetchDescriptor<TaskDeletionPreservation>()).filter { roots.contains($0.rootID) && $0.retiredAt == nil }
            guard roots.isSubset(of: Set(preservations.map(\.rootID))) else { return refused() }
            let missingRedirects = Dictionary(uniqueKeysWithValues: Set(olderNotes.map(\.id)).subtracting(Set(touchingAssociations.map(\.noteID))).map { ($0, UUID()) })
            let rows: [any PersistentModel] = tasks + notes + attachments + ownVersions + ownProposals + touchingAssociations + olderNotes + links + preservations
            let owners = Set(rows.compactMap(WorkspaceOperationCoordinator.owner)).union(missingRedirects.values.map { WorkspaceOwner(entity: .association, id: $0) })
            guard ownership.rows.isDisjoint(with: owners) else { return refused() }
            for owner in owners {
                let peers = rows.filter { WorkspaceOperationCoordinator.owner($0) == owner }
                guard let first = peers.first else { continue }
                let fields = try WorkspaceModelFields.read(first)
                guard try peers.allSatisfy({ try WorkspaceModelFields.read($0) == fields }) else { return refused() }
            }
            // Decode every surviving reference before collecting anything.
            var survivingBytes = ownership.bytes.union(coordinator.retainedHistoryBytes).union(coordinator.retainedRecoveryBytes)
            for task in allTasks where !taskIDs.contains(task.id) { survivingBytes.formUnion(try WorkspacePurge.legacyReferences(task).map(\.id)) }
            for note in allNotes where !noteIDs.contains(note.id) {
                if note.contentFormat == 0 && note.content == nil { continue }
                guard let bytes = note.content, let document = NoteContentCodec.decode(bytes).document else { return refused(.unknown) }
                survivingBytes.formUnion(document.attachmentIDs)
            }
            for version in versions where !versionIDs.contains(version.id) {
                if version.contentFormat == 0 && version.content == nil { continue }
                guard let bytes = version.content, let document = NoteContentCodec.decode(bytes).document else { return refused(.unknown) }
                survivingBytes.formUnion(document.attachmentIDs)
            }
            for proposal in proposals where !proposalIDs.contains(proposal.id) {
                guard proposal.workspaceTaskID.map({ !taskIDs.contains($0) }) ?? true else { return refused() }
                if let data = proposal.workspaceOperationData {
                    guard let intent = try? JSONDecoder().decode(AgentWorkspaceIntent.self, from: data) else { return refused(.unknown) }
                    guard intent.taskID.map({ !taskIDs.contains($0) }) ?? true,
                          intent.subtaskID.map({ !taskIDs.contains($0) }) ?? true else { return refused() }
                }
                guard let bytes = proposal.proposedContent, let document = NoteContentCodec.decode(bytes).document else { return refused(.unknown) }
                survivingBytes.formUnion(document.attachmentIDs)
            }
            // An outside document using a note-owned row needs that owner too.
            guard attachmentIDs.isDisjoint(with: survivingBytes) else { return refused() }
            let references = try tasks.flatMap(WorkspacePurge.legacyReferences)
            let leased = Set(rows.compactMap(WorkspaceOperationCoordinator.owner).map(\.id)).union(references.map(\.id)).union(attachmentIDs)
            files.files.registerWriter(coordinator.ownership)
            guard let collection = files.files.acquireCollection(leased) else { return refused() }
            defer { collection.release() }
            let envelope = try coordinator.newEnvelope(intent: "Purge whole item", reads: Array(initial.values) + missingRedirects.values.map { WorkspaceModelToken(owner: .init(entity: .association, id: $0), replicas: []) }, writes: owners,
                scopes: Set(initial.keys.map { $0.entity }).map { index.token(.all($0)) })
            let result = await coordinator.execute(envelope, sessionValid: {
                guard let current = try? inventory() else { return false }
                return current.generation == ownership.generation && files.files.validatesCollection(collection, ids: leased)
            }, collection: collection, stage: { commit in
                for row in rows {
                    guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.unknown }
                    let stored = commit.model(for: row.persistentModelID)
                    if owner.entity == .preservation {
                        guard let record = stored as? TaskDeletionPreservation else { throw WorkspaceFoundationError.unknown }
                        record.retiredAt = Date(); record.purgedAt = record.retiredAt
                    } else if owner.entity == .association {
                        let association = stored as! TaskNoteAssociation
                        if noteIDs.contains(association.noteID) { commit.delete(association) }
                        else {
                            guard let record = preservations.first(where: { $0.rootID == tasks.first(where: { $0.id == association.taskID })?.deletionRootID }) else { throw WorkspaceFoundationError.conflict }
                            association.detachedAt = Date(); association.detachedPreservationID = record.id
                        }
                    } else if let old = stored as? NoteItem, !noteIDs.contains(old.id) {
                        old.taskID = nil
                    } else { commit.delete(stored) }
                }
                for (noteID, id) in missingRedirects {
                    guard let old = olderNotes.first(where: { $0.id == noteID }), let taskID = old.taskID,
                          let rootID = tasks.first(where: { $0.id == taskID })?.deletionRootID,
                          let record = preservations.first(where: { $0.rootID == rootID }) else { throw WorkspaceFoundationError.conflict }
                    let association = TaskNoteAssociation(id: id, taskID: taskID, noteID: noteID)
                    association.detachedAt = Date(); association.detachedPreservationID = record.id
                    commit.insert(association)
                }
                WorkspaceCrashHook.reach("A-purge-staged")
            }, publication: publication)
            if result == .committed {
                WorkspaceCrashHook.reach("K8-before-unlink")
                // Migration and surviving/recovery owners retain their bytes.
                let covered = try TaskAttachmentMigration.coveredAttachmentIDs(in: coordinator.freshContext())
                let retained = survivingBytes.union(covered)
                await files.remove(references.filter { !retained.contains($0.id) }, collection: collection)
            }
            return .init(outcome: result, operationID: envelope.id,
                removedIDs: [.committed, .publicationPending].contains(result) ? taskIDs : [], preservationID: preservations.first?.id)
        } catch { return refused(.unknown) }
    }
}

extension WorkspaceItemLifecycle {
    static func beginDeletion(taskIDs: Set<UUID>, noteID: UUID?, container: ModelContainer) throws -> () -> Void {
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        guard let controller = coordinator.lifecycleNotes else { return {} }
        let context = coordinator.freshContext()
        var ids = taskIDs
        if let noteID, let owner = try taskOwner(noteID: noteID, in: context) { ids.insert(owner) }
        if has("TaskItem", in: context) {
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            ids.formUnion(all.filter { $0.parentID.map(ids.contains) == true && $0.deletedAt == nil }.map(\.id))
        }
        var notes = Set(try writing(taskIDs: ids, in: context).filter { $0.deletedAt == nil }.map(\.id))
        if let noteID { notes.insert(noteID) }
        return try controller.prepareWholeItemDeletion(noteIDs: notes, taskIDs: ids)
    }
    static func didCommit(in container: ModelContainer) {
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: container) else { return }
        coordinator.lifecycleLibrary?.refreshItemStores()
        coordinator.lifecycleNotes?.publishWholeItemLifecycle()
    }
}

extension NotesPageController {
    func prepareWholeItemDeletion(noteIDs: Set<UUID>, taskIDs: Set<UUID>) throws -> () -> Void {
        let sessions = wholeItemSessions(noteIDs: noteIDs, taskIDs: taskIDs)
        for session in sessions {
            session.engine.refreshCompositionActivity()
            guard session.engine.activity == .idle, !session.isImporting,
                  session.engine.textView?.hasMarkedText() != true, !session.isConflict else { throw WorkspaceFoundationError.conflict }
            if !session.isReadOnly, !(session.isUntouchedDraft && !session.isPersisted) {
                guard settleForWorkspaceOperation(session) else { throw WorkspaceFoundationError.conflict }
            }
            guard retireWholeItemRecovery(session) else { throw WorkspaceFoundationError.pendingPublication }
        }
        guard let histories = reserveTaskNoteInput(Set(sessions.map(\.noteID))) else { throw WorkspaceFoundationError.conflict }
        return { histories.forEach { $0.releaseInput() } }
    }
}
