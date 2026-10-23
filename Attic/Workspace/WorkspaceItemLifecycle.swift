import Foundation
import SwiftData

/// 2026-10-23: the two persisted endpoints are one deletable item. Membership
/// lives on the rows themselves; there is no additional manifest or redirect.
@MainActor
enum WorkspaceItemLifecycle {
    static func has(_ name: String, in context: ModelContext) -> Bool {
        context.container.schema.entities.contains { $0.name == name }
    }
    static func taskOwner(noteID: UUID, in context: ModelContext, includingDeleted: Bool = false) throws -> UUID? {
        let notes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        let links = has("TaskNoteAssociation", in: context)
            ? try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID && $0.detachedAt == nil })) : []
        let ids = Set(notes.compactMap(\.taskID)).union(links.map(\.taskID))
        guard ids.count <= 1 else { throw WorkspaceFoundationError.conflict }
        guard let id = ids.first, has("TaskItem", in: context) else { return nil }
        let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        return tasks.contains(where: { includingDeleted || $0.deletedAt == nil }) ? id : nil
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
        WorkspaceLegacyBridge.markItemLifecycle(in: context, taskIDs: Set(tasks.map(\.id)))
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
    static func stageRestore(group: UUID, timestamp: Date, in context: ModelContext) throws {
        WorkspaceLegacyBridge.markItemLifecycle(in: context)
        let tasks = has("TaskItem", in: context) ? try context.fetch(FetchDescriptor<TaskItem>()) : []
        let notes = has("NoteItem", in: context) ? try context.fetch(FetchDescriptor<NoteItem>()) : []
        let restoringTasks = tasks.filter { $0.deletionGroupID == group }
        let restoringNotes = notes.filter { $0.deletionGroupID == group }
        guard !restoringTasks.isEmpty || !restoringNotes.isEmpty,
              restoringTasks.allSatisfy({ $0.deletedAt != nil }), restoringNotes.allSatisfy({ $0.deletedAt != nil }) else {
            throw WorkspaceFoundationError.conflict
        }
        WorkspaceLegacyBridge.markItemLifecycle(in: context, taskIDs: Set(restoringTasks.map(\.id)))
        guard restoringTasks.allSatisfy({ $0.deletionRootID != nil }) else { throw WorkspaceFoundationError.conflict }
        let roots = Set(restoringTasks.compactMap(\.deletionRootID))
        let dates = Set(restoringTasks.compactMap(\.deletedAt) + restoringNotes.compactMap(\.deletedAt))
        guard dates.count == 1, let date = dates.first else { throw WorkspaceFoundationError.conflict }
        let records = has("TaskDeletionPreservation", in: context) ? try context.fetch(FetchDescriptor<TaskDeletionPreservation>()).filter {
            roots.contains($0.rootID) && $0.deletedAt == date && $0.retiredAt == nil
        } : []
        let snapshots = try records.map { try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: $0.snapshot) }
        guard roots.allSatisfy({ root in
            let peers = records.filter { $0.rootID == root }
            guard let first = peers.first else { return false }
            return Set(peers.map(\.id)).count == 1 && peers.allSatisfy {
                $0.snapshot == first.snapshot && $0.dependencyOwnersData == first.dependencyOwnersData
                    && $0.purgedAt == nil && $0.provenance == first.provenance
            }
        }) else { throw WorkspaceFoundationError.conflict }
        for snapshot in snapshots {
            let captured = try snapshot.members.flatMap { member in
                try (member.replicas ?? [member.fields]).filter { fields in
                    guard let bytes = fields["deletionGroupID"] else { return false }
                    return try JSONDecoder().decode(UUID?.self, from: bytes) == group
                }.map { fields in (member.id, fields) }
            }
            let actual = restoringTasks.filter { $0.deletionRootID == snapshot.rootID }
            guard Set(captured.map { $0.0 }) == Set(actual.map(\.id)),
                  try actual.allSatisfy({ row in
                      let fields = try WorkspaceModelFields.read(row)
                      return captured.contains { $0.0 == row.id && WorkspacePurge.matchesTaskCapture(fields, $0.1) }
                  }) else { throw WorkspaceFoundationError.conflict }
        }
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
                        ($0.replicas ?? [$0.fields]).contains { WorkspacePurge.matchesTaskCapture(fields, $0) }
                    }) else { throw TaskReplicaMutationError.incompleteRestore(row.id) }
                }
            }
        }
        for row in restoringNotes {
            let foreignDeleted = notes.filter { $0.id == row.id && $0.deletionGroupID != group && $0.deletedAt != nil }
            guard try foreignDeleted.allSatisfy({ peer in
                // A note-only group restores precisely its marked rows. It
                // has no task endpoint whose paired restore needs proof.
                if restoringTasks.isEmpty { return true }
                if peer.deletedAt! < date { return true }
                let fields = try WorkspaceModelFields.read(peer)
                return snapshots.flatMap { $0.dependencies ?? [] }.contains { dependency in
                    dependency.owner == .init(entity: .note, id: peer.id)
                        && dependency.fields.allSatisfy { fields[$0.key] == $0.value }
                }
            }) else { throw WorkspaceFoundationError.conflict }
            let peers = notes.filter { $0.id == row.id && $0.deletedAt == nil }
            guard peers.allSatisfy({ $0.content == row.content && $0.taskID == row.taskID && $0.tagsRaw == row.tagsRaw }) else {
                throw WorkspaceFoundationError.conflict
            }
        }
        if !restoringTasks.isEmpty {
            let capturedWriting = try Set(snapshots.flatMap { $0.dependencies ?? [] }.filter { dependency in
                guard dependency.owner.entity == .note, let bytes = dependency.fields["deletionGroupID"] else { return false }
                return try JSONDecoder().decode(UUID?.self, from: bytes) == group
            }.map { $0.owner.id })
            let ownedWriting = try writing(taskIDs: Set(restoringTasks.map(\.id)), in: context)
            guard capturedWriting == Set(restoringNotes.map(\.id)),
                  capturedWriting.isSubset(of: Set(ownedWriting.map(\.id))) else { throw WorkspaceFoundationError.conflict }
        } else {
            guard Set(restoringNotes.map(\.id)).count == 1 else { throw WorkspaceFoundationError.conflict }
        }
        // Capture every physical replica of each logical owner before a
        // subset changes, including late live and previously deleted copies.
        WorkspaceLegacyBridge.prepareMutations(tasks.filter { row in restoringTasks.contains { $0.id == row.id } }, in: context)
        WorkspaceLegacyBridge.prepareMutations(notes.filter { row in restoringNotes.contains { $0.id == row.id } }, in: context)
        try WorkspacePurge.stageRetirement(rootIDs: roots, timestamp: timestamp, deletedAt: date, in: context)
        for row in restoringTasks {
            row.deletedAt = nil; row.deletionGroupID = nil; row.deletionRootID = nil; row.deletionMembersRaw = ""
        }
        let normalizedRevisionIDs = Dictionary(uniqueKeysWithValues: Set(restoringNotes.map(\.id)).map { ($0, UUID()) })
        for row in restoringNotes {
            if let bytes = row.content, case let .editable(document) = NoteContentCodec.decode(bytes),
               let value = try WorkspaceRestoreNormalization.materialization(document, noteID: row.id, in: context) {
                let prepared = try PreparedNoteDocument(value.document)
                NoteStore.stageDocumentContent(prepared, format: value.document.format, on: [row],
                    timestamp: timestamp, revision: row.revision, revisionID: normalizedRevisionIDs[row.id]!)
                row.tags = value.tags
            } else if has("TaskNoteAssociation", in: context),
                      try context.fetch(FetchDescriptor<TaskNoteAssociation>()).contains(where: { $0.noteID == row.id && $0.detachedPreservationID != nil }),
                      row.content.map({ NoteContentCodec.decode($0).isEditable }) != true {
                throw NoteDocumentStoreError.readOnly
            }
            row.deletedAt = nil; row.deletionGroupID = nil; row.deletedAttachmentIDsRaw = nil
        }
    }
}

extension WorkspaceItemLifecycle {
    /// One irreversible group boundary. Full tokens include every physical
    /// member and every ownership query; any ambiguity retains the group.
    static func purge(group: UUID, before cutoff: Date, confirmed: Date?, coordinator: WorkspaceOperationCoordinator,
                      files: TaskImageFiles, inventory: () throws -> WorkspacePurge.Inventory?,
                      publication: WorkspaceOperationCoordinator.Publication,
                      materialize: ((UUID, [WorkspaceMaterializationPatch]) throws -> Void)? = nil) async -> WorkspacePurge.Result {
        func refused(_ outcome: WorkspaceOperationCoordinator.Outcome = .conflict) -> WorkspacePurge.Result {
            return .init(outcome: outcome, operationID: nil, removedIDs: [], preservationID: nil, retentionReason: "The whole item was retained because ownership or replica consistency could not be proved.")
        }
        do {
            let context = coordinator.freshContext()
            let initial = try WorkspaceLegacyBridge.inventory(in: context, includeCanvas: false)
            let index = try WorkspaceScopeIndex(initial)
            let allTasks = try context.fetch(FetchDescriptor<TaskItem>())
            let allNotes = try context.fetch(FetchDescriptor<NoteItem>())
            var tasks = allTasks.filter { $0.deletionGroupID == group }
            let notes = allNotes.filter { $0.deletionGroupID == group }
            var taskIDs = Set(tasks.map(\.id))
            let primaryTaskIDs = taskIDs, noteIDs = Set(notes.map(\.id))
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
            let associations = try context.fetch(FetchDescriptor<TaskNoteAssociation>())
            let activePreservations = try context.fetch(FetchDescriptor<TaskDeletionPreservation>()).filter { $0.retiredAt == nil }
            // A note owns the retired circle families that redirect to it.
            // Collect them in this same commit, each against its own deletion
            // date/capture. The selected group's confirmation remains exact.
            let dependentIDs = Set(associations.filter {
                noteIDs.contains($0.noteID) && $0.detachedAt != nil
            }.compactMap(\.detachedPreservationID))
            for record in activePreservations where dependentIDs.contains(record.id) && record.provenance == "circle removed" {
                guard record.purgedAt == nil, record.deletedAt < cutoff,
                      let family = try TaskStore.guardedDeletedFamily(in: context, rootID: record.rootID, before: cutoff,
                          confirmed: record.deletedAt),
                      family.allSatisfy({ $0.deletionGroupID != nil }) else { return refused() }
                taskIDs.formUnion(family.map(\.id))
            }
            tasks = allTasks.filter { taskIDs.contains($0.id) }
            for root in Set(tasks.compactMap(\.deletionRootID)) {
                guard let family = try TaskStore.guardedDeletedFamily(in: context, rootID: root, before: cutoff,
                          confirmed: primaryTaskIDs.contains(root) ? confirmed : nil),
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
            let recoveryBases = try coordinator.lifecycleNotes?.store.recoveryProtectedRevisionIDs() ?? []
            guard Dictionary(grouping: ownVersions, by: \.id).values.allSatisfy({
                NotePhysicalFamilyRetention.versionEligible($0, noteIDs: noteIDs, proposalBases: [], recoveryBases: recoveryBases)
            }), Dictionary(grouping: ownProposals, by: \.id).values.allSatisfy({
                NotePhysicalFamilyRetention.proposalEligible($0, noteIDs: noteIDs)
            }) else { return refused() }
            for proposal in ownProposals {
                guard proposal.workspaceTaskID.map(taskIDs.contains) ?? true else { return refused() }
                if let data = proposal.workspaceOperationData {
                    let intent = try JSONDecoder().decode(AgentWorkspaceIntent.self, from: data)
                    guard intent.taskID.map(taskIDs.contains) ?? true,
                          intent.subtaskID.map(taskIDs.contains) ?? true,
                          intent.noteID.map(noteIDs.contains) ?? true else { return refused() }
                }
            }
            let versionIDs = Set(ownVersions.map(\.id)), proposalIDs = Set(ownProposals.map(\.id))
            guard versions.filter({ versionIDs.contains($0.id) }).allSatisfy({ noteIDs.contains($0.noteID) }),
                  proposals.filter({ proposalIDs.contains($0.id) }).allSatisfy({ noteIDs.contains($0.noteID) }),
                  proposals.filter({ !noteIDs.contains($0.noteID) }).allSatisfy({ $0.baseVersionID.map { !versionIDs.contains($0) } ?? true }) else { return refused() }
            let associationIDs = Set(associations.filter { taskIDs.contains($0.taskID) || noteIDs.contains($0.noteID) }.map(\.id))
            let touchingAssociations = associations.filter { associationIDs.contains($0.id) }
            guard touchingAssociations.allSatisfy({ $0.detachedAt != nil || taskIDs.contains($0.taskID) }) else { return refused() }
            // Independent writing survives via its detached association and
            // preservation. Live writing is materialized in this same commit.
            let survivingNotes = try writing(taskIDs: taskIDs, in: context).filter { !noteIDs.contains($0.id) }
            let survivorIDs = Set(survivingNotes.map(\.id))
            guard survivorIDs.isDisjoint(with: ownership.blockedNotes),
                  survivorIDs.allSatisfy({ ownership.sessions[$0]?.canCommit ?? true }),
                  survivorIDs.allSatisfy({ !coordinator.recoveryDependsOnNote($0) }),
                  survivingNotes.allSatisfy({ $0.associationGeneration < Int64.max }) else { return refused() }
            var survivorTasks: [UUID: UUID] = [:]
            for (id, copies) in Dictionary(grouping: survivingNotes, by: \.id) {
                let owners = Set(copies.compactMap(\.taskID)).union(touchingAssociations.filter { $0.noteID == id && $0.detachedAt == nil }.map(\.taskID))
                guard owners.count == 1, let owner = owners.first else { return refused() }
                survivorTasks[id] = owner
            }
            let liveSurvivorIDs = Set(survivingNotes.filter { $0.deletedAt == nil }.map(\.id))
            for association in touchingAssociations where association.detachedAt == nil && survivorIDs.contains(association.noteID) {
                guard tasks.filter({ $0.id == association.taskID }).allSatisfy({ $0.associationGeneration == association.taskGeneration }),
                      survivingNotes.filter({ $0.id == association.noteID }).allSatisfy({ $0.associationGeneration == association.noteGeneration }) else { return refused() }
            }
            let touching: Set<AtticItemRef> = Set(taskIDs.map { .init(.task, $0) } + noteIDs.map { .init(.note, $0) })
            let allLinks = try context.fetch(FetchDescriptor<ItemLink>())
            let linkIDs = Set(allLinks.filter { $0.source.map(touching.contains) == true || $0.target.map(touching.contains) == true }.map(\.id))
            let links = allLinks.filter { linkIDs.contains($0.id) }
            let roots = Set(tasks.compactMap(\.deletionRootID))
            let preservations = activePreservations.filter { record in
                roots.contains(record.rootID) && tasks.contains { $0.deletionRootID == record.rootID && $0.deletedAt == record.deletedAt }
            }
            guard tasks.allSatisfy({ $0.deletionRootID != nil }),
                  roots.allSatisfy({ root in Set(preservations.filter { $0.rootID == root }.map(\.id)).count == 1 }) else { return refused() }
            for record in preservations {
                let snapshot = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot)
                let family = allTasks.filter { row in snapshot.members.contains { $0.id == row.id } }
                guard record.purgedAt == nil, snapshot.rootID == record.rootID,
                      snapshot.title == family.first(where: { $0.id == record.rootID })?.title,
                      snapshot.members.allSatisfy({ member in
                          let copies = family.filter { $0.id == member.id }
                          guard !copies.isEmpty, (member.replicas ?? [member.fields]).contains(member.fields) else { return false }
                          return copies.allSatisfy { row in
                              guard let fields = try? WorkspaceModelFields.read(row) else { return false }
                              return (member.replicas ?? [member.fields]).contains { WorkspacePurge.matchesTaskCapture(fields, $0) }
                          }
                      }), Set(snapshot.members.map(\.id)).isSuperset(of: Set(tasks.filter { $0.deletionRootID == record.rootID }.map(\.id))),
                      let dependencies = snapshot.dependencies else { return refused() }
                let originals = try family.flatMap(WorkspacePurge.legacyReferences)
                guard snapshot.originals.allSatisfy({ originals.contains($0.reference) }),
                      originals.allSatisfy({ reference in snapshot.originals.contains { $0.reference == reference } }) else { return refused() }
                let current = try WorkspacePurge.preservationDependencies(taskIDs: Set(family.map(\.id)), in: context)
                guard dependencies.allSatisfy({ captured in current.contains { actual in
                    guard actual.owner == captured.owner else { return false }
                    if captured.owner.entity == .note, liveSurvivorIDs.contains(captured.owner.id) {
                        // An independently deleted note may have been restored.
                        // Revision and association ownership must still agree.
                        let lifecycle: Set<String> = ["deletedAt", "deletionGroupID"]
                        return actual.fields.filter { !lifecycle.contains($0.key) }
                            == captured.fields.filter { !lifecycle.contains($0.key) }
                    }
                    return actual == captured
                } }) else { return refused() }
            }
            // Redirect old task endpoints in the already guarded purge. A
            // detached endpoint needs one proven circle preservation; ambiguous
            // replicas retain the whole family rather than deleting its links.
            var redirects: [UUID: UUID] = [:]
            for association in touchingAssociations where association.detachedAt != nil {
                guard taskIDs.contains(association.taskID),
                      let record = preservations.first(where: { $0.id == association.detachedPreservationID }),
                      record.provenance == "circle removed" else { continue }
                if let old = redirects[association.taskID], old != association.noteID { return refused() }
                redirects[association.taskID] = association.noteID
            }
            var redirectedLinks: [PersistentIdentifier: (AtticItemRef, AtticItemRef)] = [:]
            for link in links {
                guard let source = link.source, let target = link.target else { return refused() }
                func redirected(_ endpoint: AtticItemRef) -> AtticItemRef {
                    guard endpoint.kind == .task, let note = redirects[endpoint.id] else { return endpoint }
                    return .init(.note, note)
                }
                let afterSource = redirected(source), afterTarget = redirected(target)
                if !touching.contains(afterSource), !touching.contains(afterTarget) {
                    redirectedLinks[link.persistentModelID] = (afterSource, afterTarget)
                }
            }
            for other in activePreservations where !preservations.contains(where: { $0.id == other.id }) {
                let snapshot = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: other.snapshot)
                guard !(snapshot.dependencies ?? []).contains(where: { dependency in
                    noteIDs.contains(dependency.owner.id) || attachmentIDs.contains(dependency.owner.id)
                }) else { return refused() }
            }
            var documents: [UUID: NoteDocument] = [:]
            var materializedTags: [UUID: [String]] = [:]
            var patches: [WorkspaceMaterializationPatch] = []
            for id in liveSurvivorIDs {
                let copies = survivingNotes.filter { $0.id == id }
                guard let first = copies.first, let taskID = survivorTasks[id],
                      let root = tasks.first(where: { $0.id == taskID })?.deletionRootID,
                      let record = preservations.first(where: { $0.rootID == root }),
                      copies.allSatisfy({ $0.deletedAt == nil }),
                      let bytes = first.content, case let .editable(before) = NoteContentCodec.decode(bytes) else { return refused() }
                let snapshot = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot)
                let value = try WorkspaceTaskNoteMaterializer.materialize(before, taskID: taskID, preservation: snapshot)
                documents[id] = value.document
                // Tags are globally editable after the immutable capture.
                materializedTags[id] = tasks.first(where: { $0.id == taskID })?.tags ?? value.tags
                patches.append(.init(noteID: id, taskID: taskID, preservationRootID: root,
                    preservationID: record.id, before: before, after: value.document))
            }
            let prepared = try documents.mapValues { try PreparedNoteDocument($0) }
            let newVersions = Dictionary(uniqueKeysWithValues: survivingNotes.filter { liveSurvivorIDs.contains($0.id) }.map { ($0.persistentModelID, UUID()) })
            let survivorAttachments = allAttachments.filter { liveSurvivorIDs.contains($0.noteID) }
            let survivorAttachmentIDs = Set(survivorAttachments.map(\.id))
            guard allAttachments.filter({ survivorAttachmentIDs.contains($0.id) }).allSatisfy({ liveSurvivorIDs.contains($0.noteID) }),
                  touchingAssociations.allSatisfy({ $0.taskGeneration < Int64.max && $0.noteGeneration < Int64.max }) else { return refused() }
            let missingRedirects = Dictionary(uniqueKeysWithValues: Set(survivingNotes.map(\.id)).subtracting(Set(touchingAssociations.map(\.noteID))).map { ($0, UUID()) })
            let rows: [any PersistentModel] = tasks + notes + attachments + ownVersions + ownProposals + touchingAssociations + survivingNotes + links + preservations + survivorAttachments
            let owners = Set(rows.compactMap(WorkspaceOperationCoordinator.owner))
                .union(missingRedirects.values.map { WorkspaceOwner(entity: .association, id: $0) })
                .union(newVersions.values.map { WorkspaceOwner(entity: .version, id: $0) })
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
            // Ownership must be readable before the irreversible boundary.
            let covered = try TaskAttachmentMigration.coveredAttachmentIDs(in: context)
            let leased = Set(rows.compactMap(WorkspaceOperationCoordinator.owner).map(\.id)).union(references.map(\.id)).union(attachmentIDs).union(documents.values.flatMap(\.attachmentIDs))
            files.files.registerWriter(coordinator.ownership)
            guard let collection = files.files.acquireCollection(leased) else { return refused() }
            defer { collection.release() }
            let envelope = try coordinator.newEnvelope(intent: "Purge whole item", reads: Array(initial.values)
                    + missingRedirects.values.map { WorkspaceModelToken(owner: .init(entity: .association, id: $0), replicas: []) }
                    + newVersions.values.map { WorkspaceModelToken(owner: .init(entity: .version, id: $0), replicas: []) }, writes: owners,
                // Empty ownership tables are reads too: the first outside
                // proposal/version/association may arrive during journal IO.
                scopes: [WorkspaceOwner.Entity.task, .note, .attachment, .version, .proposal, .link, .association, .preservation, .migration]
                    .map { index.token(.all($0)) }, afterDocuments: prepared.mapValues(\.content))
            let materializationSteps: [@MainActor (UUID) throws -> Void] = materialize.map { handler in
                [{ operation in try handler(operation, patches) }]
            } ?? []
            let linkTimestamp = Date()
            let result = await coordinator.execute(envelope, sessionValid: {
                guard let current = try? inventory() else { return false }
                return current.generation == ownership.generation && files.files.validatesCollection(collection, ids: leased)
            }, collection: collection, stage: { commit in
                for (id, document) in documents {
                    try NoteStore.stageDocument(in: commit, noteID: id, document: document, prepared: prepared[id]!,
                        revisionID: UUID(), versionIDs: newVersions, tags: materializedTags[id], timestamp: Date())
                }
                for row in rows {
                    if row is NoteAttachment, survivorAttachments.contains(where: { $0.persistentModelID == row.persistentModelID }) { continue }
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
                            association.taskGeneration += 1; association.noteGeneration += 1
                            association.detachedAt = Date(); association.detachedPreservationID = record.id
                        }
                    } else if let link = stored as? ItemLink, let endpoints = redirectedLinks[row.persistentModelID] {
                        link.sourceKindRaw = endpoints.0.kind.rawValue; link.sourceID = endpoints.0.id
                        link.targetKindRaw = endpoints.1.kind.rawValue; link.targetID = endpoints.1.id
                        link.updatedAt = linkTimestamp
                        WorkspaceCrashHook.reach("B-purge-links")
                    } else if let old = stored as? NoteItem, !noteIDs.contains(old.id) {
                        old.taskID = nil; old.associationGeneration += 1
                    } else { commit.delete(stored) }
                }
                for (noteID, id) in missingRedirects {
                    guard let taskID = survivorTasks[noteID],
                          let rootID = tasks.first(where: { $0.id == taskID })?.deletionRootID,
                          let record = preservations.first(where: { $0.rootID == rootID }) else { throw WorkspaceFoundationError.conflict }
                    let association = TaskNoteAssociation(id: id, taskID: taskID, noteID: noteID)
                    association.detachedAt = Date(); association.detachedPreservationID = record.id
                    association.noteGeneration = (survivingNotes.first(where: { $0.id == noteID })?.associationGeneration ?? 0) + 1
                    commit.insert(association)
                }
                WorkspaceCrashHook.reach("A-purge-staged")
            }, publication: .init(steps: materializationSteps + publication.steps))
            var retainedReasons: [UUID: String] = [:]
            if result == .committed {
                WorkspaceCrashHook.reach("K8-before-unlink")
                let retained = survivingBytes.union(covered)
                for reference in references where retained.contains(reference.id) {
                    retainedReasons[reference.id] = covered.contains(reference.id)
                        ? "A migration record retains this original."
                        : "Another item, recovery copy or retained history still owns this original."
                }
                await files.remove(references.filter { !retained.contains($0.id) }, collection: collection)
            }
            return .init(outcome: result, operationID: envelope.id,
                removedIDs: [.committed, .publicationPending].contains(result) ? taskIDs : [], preservationID: preservations.first?.id,
                materialization: [.committed, .publicationPending, .unknown].contains(result) ? patches : [],
                retainedByteReasons: retainedReasons)
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

struct WholeItemDeletionScope: Equatable {
    let hasWriting: Bool
    let subtaskCount: Int
    let fileCount: Int
    var confirmationMessage: String {
        var parts: [String] = []
        if hasWriting { parts.append(String(localized: "Its writing")) }
        if subtaskCount > 0 { parts.append(subtaskCount == 1 ? String(localized: "1 subtask") : String(localized: "\(subtaskCount) subtasks")) }
        if fileCount > 0 { parts.append(fileCount == 1 ? String(localized: "1 file") : String(localized: "\(fileCount) files")) }
        guard !parts.isEmpty else { return String(localized: "The item goes to Recently Deleted for 30 days.") }
        let subject = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + String(localized: " and ") + parts.last!
        return subject + (parts.count == 1 ? String(localized: " goes to Recently Deleted for 30 days.") : String(localized: " go to Recently Deleted for 30 days."))
    }
}

extension AtticLibrary {
    func deletionScope(for taskID: UUID) -> WholeItemDeletionScope? {
        let context = ModelContext(tasks.container)
        do {
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            let linked = all.filter { ($0.id == taskID || $0.parentID == taskID) && $0.deletedAt == nil }
            guard linked.contains(where: { $0.id == taskID }) else { return nil }
            let ids = Set(linked.map(\.id))
            let writing = try WorkspaceItemLifecycle.writing(taskIDs: ids, in: context).filter { $0.deletedAt == nil }
            let noteIDs = Set(writing.map(\.id))
            let attachments = try context.fetch(FetchDescriptor<NoteAttachment>()).filter { noteIDs.contains($0.noteID) }
            let files = Set(try linked.flatMap(WorkspacePurge.legacyReferences).map(\.id)).union(attachments.map(\.id))
            return .init(hasWriting: !writing.isEmpty, subtaskCount: ids.subtracting([taskID]).count, fileCount: files.count)
        } catch { return nil }
    }
}
