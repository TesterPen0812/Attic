import Foundation
import SwiftData

/// Headless coordinated task-family transaction. Recovery/session owners must
/// supply a complete inventory; absent or unreadable ownership defers deletion.
/// Files are collected separately by the existing guarded file store.
@MainActor
enum WorkspacePurge {
    struct SessionSnapshot {
        var activity: NoteEditorEngine.Activity = .idle
        var state: NoteSession.State = .clean
        var importing = false
        var proposal = false
        var replay = false
        var publication = false
        var canCommit: Bool {
            guard activity == .idle, !importing, !proposal, !replay, !publication else { return false }
            switch state { case .conflict, .readOnly: return false; default: return true }
        }
    }
    struct Inventory {
        let generation: UInt64
        let rows: Set<WorkspaceOwner>
        let bytes: Set<UUID>
        let drafts: [UUID: NoteDocument]
        let blockedNotes: Set<UUID>
        let sessions: [UUID: SessionSnapshot]
        let claims: [UUID: NoteRecoveryClaim]
        let staged: [UUID: [StagedNoteAttachment]]
        let tags: [UUID: [String]]
        let selections: [UUID: NSRange]
        init(generation: UInt64, rows: Set<WorkspaceOwner> = [], bytes: Set<UUID> = [],
             drafts: [UUID: NoteDocument] = [:], blockedNotes: Set<UUID> = [],
             sessions: [UUID: SessionSnapshot] = [:], claims: [UUID: NoteRecoveryClaim] = [:],
             staged: [UUID: [StagedNoteAttachment]] = [:], tags: [UUID: [String]] = [:], selections: [UUID: NSRange] = [:]) {
            self.generation = generation; self.rows = rows; self.bytes = bytes
            self.drafts = drafts; self.blockedNotes = blockedNotes
            self.sessions = sessions; self.claims = claims; self.staged = staged; self.tags = tags; self.selections = selections
        }
    }
    struct Preservation: Codable, Equatable {
        struct Member: Codable, Equatable {
            let id: UUID
            let fields: [String: Data]
            var replicas: [[String: Data]]? = nil
        }
        struct Original: Codable, Equatable { let reference: TaskImageReference; let wasMissing: Bool? }
        struct Dependency: Codable, Equatable {
            let owner: WorkspaceOwner
            let fields: [String: Data]
        }
        let rootID: UUID
        let title: String
        let members: [Member]
        let originals: [Original]
        var dependencies: [Dependency]? = nil
        func title(for taskID: UUID) throws -> String {
            guard let member = members.first(where: { $0.id == taskID }), let bytes = member.fields["title"] else { throw WorkspaceFoundationError.unknown }
            return try JSONDecoder().decode(String.self, from: bytes)
        }
    }
    struct Result {
        let outcome: WorkspaceOperationCoordinator.Outcome
        let operationID: UUID?
        let removedIDs: Set<UUID>
        let preservationID: UUID?
        var materialization: [WorkspaceMaterializationPatch] = []
        var checkpoint: (UUID, NoteRecoveryClaim)? = nil
        var retentionReason: String? = nil
        var retainedByteReasons: [UUID: String] = [:]
    }
    /// Global tag edits include deleted rows. No other captured task field
    /// may drift before Restore or destructive collection.
    static func matchesTaskCapture(_ fields: [String: Data], _ captured: [String: Data]) -> Bool {
        let tagFields: Set<String> = ["tagsRaw", "updatedAt"]
        return fields.filter { !tagFields.contains($0.key) }
            == captured.filter { !tagFields.contains($0.key) }
    }

    static func hasOwnNotesOrAssociations(_ taskIDs: Set<UUID>, in context: ModelContext) throws -> Bool {
        let schema = Set(context.container.schema.entities.map(\.name))
        let notes = schema.contains("NoteItem") ? try context.fetch(FetchDescriptor<NoteItem>()) : []
        let associations = schema.contains("TaskNoteAssociation") ? try context.fetch(FetchDescriptor<TaskNoteAssociation>()) : []
        return notes.contains { $0.taskID.map(taskIDs.contains) == true }
            || associations.contains { taskIDs.contains($0.taskID) && $0.detachedAt == nil }
    }

    /// New deletion records are immutable and share the soft-delete save.
    /// Original availability has not been checked here: nil records that fact,
    /// rather than inventing a deletion-time missing-file observation.
    static func stageDeletionCapture(id: UUID = UUID(), rootID: UUID, rows: [TaskItem], deletedAt: Date, in context: ModelContext, provenance: String = "soft deletion") throws {
        guard context.container.schema.entities.contains(where: { $0.name == "TaskDeletionPreservation" }) else { return }
        let members = try Dictionary(grouping: rows, by: \.id).values.map { replicas in
            let fields = try replicas.map { try WorkspaceModelFields.read($0) }
                .sorted { try WorkspaceModelFields.encode($0).lexicographicallyPrecedes(WorkspaceModelFields.encode($1)) }
            return Preservation.Member(id: replicas[0].id, fields: fields[0], replicas: fields)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard let head = rows.first(where: { $0.id == rootID }) else { throw WorkspaceFoundationError.conflict }
        let refs = uniqueReferences(try rows.flatMap(legacyReferences)).sorted {
            ($0.id.uuidString, $0.digest) < ($1.id.uuidString, $1.digest)
        }
        let dependencies = try preservationDependencies(taskIDs: Set(rows.map(\.id)), in: context)
            .filter { provenance != "circle removed" || $0.owner.entity == .association }
        let snapshot = Preservation(rootID: rootID, title: head.title, members: members,
            originals: refs.map { .init(reference: $0, wasMissing: nil) }, dependencies: dependencies)
        let record = TaskDeletionPreservation(id: id, rootID: rootID, deletedAt: deletedAt,
            capturedAt: deletedAt, provenance: provenance, snapshot: try WorkspaceModelFields.encode(snapshot))
        record.dependencyOwnersData = try WorkspaceModelFields.encode(dependencies.map(\.owner))
        context.insert(record)
    }

    private static func uniqueReferences(_ references: [TaskImageReference]) -> [TaskImageReference] {
        references.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Only an outstanding deletion owns dependencies. Purged records retain
    /// their immutable title/tombstone, not indefinite rights over ordinary
    /// notes. The compact owner index avoids decoding historical snapshots.
    static func preservationOwners(in context: ModelContext) throws -> Set<WorkspaceOwner> {
        guard context.container.schema.entities.contains(where: { $0.name == "TaskDeletionPreservation" }) else { return [] }
        var owners = Set<WorkspaceOwner>()
        let active = try context.fetch(FetchDescriptor<TaskDeletionPreservation>(
            predicate: #Predicate { $0.retiredAt == nil && $0.purgedAt == nil }))
        let deleted = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.deletedAt != nil }))
        for record in active {
            // Also handles rows restored before retirement metadata existed.
            guard deleted.contains(where: { $0.id == record.rootID && $0.deletedAt == record.deletedAt }) else { continue }
            if let indexed = record.dependencyOwnersData {
                owners.formUnion(try JSONDecoder().decode([WorkspaceOwner].self, from: indexed))
            } else {
                let snapshot = try JSONDecoder().decode(Preservation.self, from: record.snapshot)
                guard let dependencies = snapshot.dependencies else { throw WorkspaceFoundationError.unknown }
                owners.formUnion(dependencies.map(\.owner))
            }
        }
        return owners
    }

    static func stageRetirement(rootIDs: Set<UUID>, timestamp: Date, purged: Bool = false, deletedAt: Date? = nil, in context: ModelContext) throws {
        guard context.container.schema.entities.contains(where: { $0.name == "TaskDeletionPreservation" }) else { return }
        let records = try context.fetch(FetchDescriptor<TaskDeletionPreservation>()).filter {
            rootIDs.contains($0.rootID) && $0.retiredAt == nil && (deletedAt == nil || $0.deletedAt == deletedAt)
        }
        WorkspaceLegacyBridge.prepareMutations(records, in: context)
        records.forEach {
            $0.retiredAt = timestamp
            if purged && $0.purgedAt == nil { $0.purgedAt = timestamp }
        }
    }

    static func preservationDependencies(taskIDs: Set<UUID>, in context: ModelContext) throws -> [Preservation.Dependency] {
        let schema = Set(context.container.schema.entities.map(\.name))
        let associations = schema.contains("TaskNoteAssociation") ? try context.fetch(FetchDescriptor<TaskNoteAssociation>()).filter { taskIDs.contains($0.taskID) } : []
        let associatedNotes = Set(associations.map(\.noteID))
        let notes = schema.contains("NoteItem") ? try context.fetch(FetchDescriptor<NoteItem>()).filter { $0.taskID.map(taskIDs.contains) == true || associatedNotes.contains($0.id) } : []
        let noteIDs = Set(notes.map(\.id)).union(associations.map(\.noteID))
        var result = try associations.map { Preservation.Dependency(owner: .init(entity: .association, id: $0.id), fields: try WorkspaceModelFields.read($0)) }
        for note in notes {
            result.append(.init(owner: .init(entity: .note, id: note.id), fields: [
                "revisionID": try WorkspaceModelFields.encode(note.revisionID),
                "associationGeneration": try WorkspaceModelFields.encode(note.associationGeneration),
                "deletionGroupID": try WorkspaceModelFields.encode(note.deletionGroupID),
                "deletedAt": try WorkspaceModelFields.encode(note.deletedAt)]))
        }
        if schema.contains("NoteVersion") {
            for version in try context.fetch(FetchDescriptor<NoteVersion>()) where noteIDs.contains(version.noteID) {
                result.append(.init(owner: .init(entity: .version, id: version.id), fields: [
                    "noteID": try WorkspaceModelFields.encode(version.noteID),
                    "sourceRevisionID": try WorkspaceModelFields.encode(version.sourceRevisionID),
                    "attachmentIDsRaw": try WorkspaceModelFields.encode(version.attachmentIDsRaw)]))
            }
        }
        return result.sorted { ($0.owner.entity.rawValue, $0.owner.id.uuidString) < ($1.owner.entity.rawValue, $1.owner.id.uuidString) }
    }

    /// Unknown dependencies are not converted to absence. A surviving legacy
    /// byte owner defers this family until its original has been transferred.
    static func purge(rootID: UUID, before cutoff: Date, confirmed: Date? = nil,
                      coordinator: WorkspaceOperationCoordinator, files: TaskImageFiles,
                      inventory: () throws -> Inventory?,
                      publication: WorkspaceOperationCoordinator.Publication = .init(),
                      materialize: ((UUID, [WorkspaceMaterializationPatch]) throws -> Void)? = nil) async -> Result {
        let probe = coordinator.freshContext()
        if let rows = try? probe.fetch(FetchDescriptor<TaskItem>()),
           let group = rows.first(where: { $0.id == rootID })?.deletionGroupID {
            return await WorkspaceItemLifecycle.purge(group: group, before: cutoff, confirmed: confirmed,
                coordinator: coordinator, files: files, inventory: inventory, publication: publication, materialize: materialize)
        }
        var checkpoint: (UUID, NoteRecoveryClaim)?
        func refused(_ outcome: WorkspaceOperationCoordinator.Outcome = .conflict) -> Result {
            return Result(outcome: outcome, operationID: nil, removedIDs: [], preservationID: nil, checkpoint: checkpoint)
        }
        let context = coordinator.freshContext()
        do {
            let entities: Set<WorkspaceOwner.Entity> = [.task, .note, .attachment, .version, .proposal, .link, .association, .preservation]
            let initial = try WorkspaceLegacyBridge.inventory(in: context, includeCanvas: false, entities: entities)
            let index = try WorkspaceScopeIndex(initial)
            guard let ownership = try inventory(),
                  let family = try TaskStore.guardedDeletedFamily(in: context, rootID: rootID, before: cutoff, confirmed: confirmed),
                  let head = family.first(where: { $0.id == rootID }), let deletedAt = head.deletedAt else { return refused() }
            guard family.allSatisfy({ $0.associationGeneration < Int64.max }) else { return refused() }
            let ids = Set(family.map(\.id))
            let taskOwners = Set(ids.map { WorkspaceOwner(entity: .task, id: $0) })
            guard ownership.rows.isDisjoint(with: taskOwners) else { return refused() }
            let allNotes = try context.fetch(FetchDescriptor<NoteItem>())
            let allAssociations = try context.fetch(FetchDescriptor<TaskNoteAssociation>())
            let ownIDs = Set(allNotes.filter { $0.taskID.map(ids.contains) == true }.map(\.id))
                .union(allAssociations.filter { ids.contains($0.taskID) && $0.detachedAt == nil }.map(\.noteID))
            guard ownIDs.isDisjoint(with: ownership.blockedNotes),
                  ownIDs.allSatisfy({ ownership.sessions[$0]?.canCommit ?? true }),
                  ownership.drafts.count <= 1, Set(ownership.drafts.keys).isSubset(of: ownIDs) else { return refused() }
            let notes = allNotes.filter { ownIDs.contains($0.id) }
            guard ownIDs == Set(notes.map(\.id)), notes.allSatisfy({ $0.taskID.map(ids.contains) == true }) else { return refused() }
            guard notes.allSatisfy({ $0.associationGeneration < Int64.max }) else { return refused() }
            // Detached rows preserve historical context. Only active logical
            // families participate; include all replicas of each active UUID
            // so a detached/active divergence still refuses destructive work.
            let activeAssociationIDs = Set(allAssociations.filter {
                $0.detachedAt == nil && (ownIDs.contains($0.noteID) || ids.contains($0.taskID))
            }.map(\.id))
            let associations = allAssociations.filter { activeAssociationIDs.contains($0.id) }
            // These owners have not explicitly transferred their replay/base
            // rights to ordinary-note content. Retain the family rather than
            // treating a known surviving row owner as permission to detach it.
            let detachedOwners = Set(ownIDs.map { WorkspaceOwner(entity: .note, id: $0) })
                .union(associations.map { .init(entity: .association, id: $0.id) })
            guard ownership.rows.isDisjoint(with: detachedOwners) else { return refused() }
            guard associations.allSatisfy({ ids.contains($0.taskID) && ownIDs.contains($0.noteID) && $0.detachedAt == nil }) else { return refused() }
            for association in associations {
                guard family.filter({ $0.id == association.taskID }).allSatisfy({ $0.associationGeneration == association.taskGeneration }),
                      notes.filter({ $0.id == association.noteID }).allSatisfy({ $0.associationGeneration == association.noteGeneration }) else { return refused() }
            }
            for group in Dictionary(grouping: associations, by: \.id).values {
                guard let first = group.first else { return refused() }
                let fields = try WorkspaceModelFields.read(first)
                guard try group.allSatisfy({ try WorkspaceModelFields.read($0) == fields }) else { return refused() }
            }
            // Enumerate every stored survivor, including deleted versions and
            // proposals. An opaque/malformed dependency makes reachability unknown.
            let links = try context.fetch(FetchDescriptor<ItemLink>())
            let touching = Set(ids.map { AtticItemRef(.task, $0) })
            let affectedLinkIDs = Set(links.filter { ($0.source.map(touching.contains) ?? false) || ($0.target.map(touching.contains) ?? false) }.map(\.id))
            let affectedLinks = links.filter { affectedLinkIDs.contains($0.id) }
            for group in Dictionary(grouping: affectedLinks, by: \.id).values {
                let fields = try WorkspaceModelFields.read(group[0])
                guard try group.allSatisfy({ try WorkspaceModelFields.read($0) == fields }) else { return refused() }
            }
            guard ownership.rows.isDisjoint(with: Set(affectedLinkIDs.map { .init(entity: .link, id: $0) })) else { return refused() }
            let references = try family.flatMap(legacyReferences)
            files.files.registerWriter(coordinator.ownership)
            let leasedIDs = ids.union(affectedLinkIDs).union(ownIDs).union(associations.map(\.id)).union(references.map(\.id))
                .union(ownership.drafts.values.flatMap(\.attachmentIDs))
                .union(notes.compactMap { $0.content.flatMap { NoteContentCodec.decode($0).document } }.flatMap(\.attachmentIDs))
            guard let collection = files.files.acquireCollection(leasedIDs) else { return refused() }
            defer { collection.release() }
            var survivingBytes = ownership.bytes
            for task in try context.fetch(FetchDescriptor<TaskItem>()) where !ids.contains(task.id) {
                survivingBytes.formUnion(try legacyReferences(task).map(\.id))
            }
            for note in allNotes {
                if note.contentFormat == 0 && note.content == nil { continue }
                guard let data = note.content, case let .editable(document) = NoteContentCodec.decode(data) else {
                    if ownIDs.contains(note.id), references.isEmpty { continue }
                    return refused(.unknown)
                }
                survivingBytes.formUnion(document.attachmentIDs)
            }
            for version in try context.fetch(FetchDescriptor<NoteVersion>()) {
                if version.contentFormat == 0 && version.content == nil { continue }
                guard let data = version.content, case let .editable(document) = NoteContentCodec.decode(data) else { return refused(.unknown) }
                survivingBytes.formUnion(document.attachmentIDs)
            }
            for proposal in try context.fetch(FetchDescriptor<NotePendingEdit>()) {
                guard !ownIDs.contains(proposal.noteID), proposal.workspaceTaskID.map({ !ids.contains($0) }) ?? true else { return refused() }
                if let data = proposal.workspaceOperationData {
                    guard let intent = try? JSONDecoder().decode(AgentWorkspaceIntent.self, from: data) else { return refused(.unknown) }
                    if intent.taskID.map(ids.contains) == true || intent.subtaskID.map(ids.contains) == true { return refused() }
                }
                guard let data = proposal.proposedContent, case let .editable(document) = NoteContentCodec.decode(data) else { return refused(.unknown) }
                survivingBytes.formUnion(document.attachmentIDs)
            }
            guard Set(references.map(\.id)).isDisjoint(with: survivingBytes) else { return refused() }
            var originals: [Preservation.Original] = []
            for reference in references {
                // Missing exclusively owned originals do not strand a family.
                // Invalid/unreadable originals are unknown and still refuse.
                let path = try await files.files.materializedURL(for: reference.fileReference)
                let existed = FileManager.default.fileExists(atPath: path.path)
                let url = try await files.verifiedURL(for: reference)
                guard !existed || url != nil else { return refused(.unknown) }
                originals.append(.init(reference: reference, wasMissing: url == nil))
            }
            let members = try Dictionary(grouping: family, by: \.id).values.map { replicas in
                let row = replicas[0], fields = try WorkspaceModelFields.read(row)
                guard try replicas.allSatisfy({ try WorkspaceModelFields.read($0) == fields }) else { throw WorkspaceFoundationError.conflict }
                return Preservation.Member(id: row.id, fields: fields)
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            let snapshot = Preservation(rootID: rootID, title: head.title, members: members,
                originals: uniqueReferences(originals.map(\.reference)).sorted { ($0.id.uuidString, $0.digest) < ($1.id.uuidString, $1.digest) }.map { reference in originals.first { $0.reference == reference }! },
                dependencies: try preservationDependencies(taskIDs: ids, in: context))
            let snapshotBytes = try WorkspaceModelFields.encode(snapshot)
            let existing = try context.fetch(FetchDescriptor<TaskDeletionPreservation>()).filter { $0.rootID == rootID && $0.deletedAt == deletedAt && $0.retiredAt == nil }
            let preservationID = existing.first?.id ?? UUID()
            for record in existing {
                guard record.id == preservationID, record.purgedAt == nil else { return refused() }
                if record.provenance == "soft deletion" {
                    let captured = try JSONDecoder().decode(Preservation.self, from: record.snapshot)
                    guard captured.rootID == snapshot.rootID,
                          captured.members.map(\.id) == snapshot.members.map(\.id),
                          captured.members.allSatisfy({ member in
                              snapshot.members.first(where: { $0.id == member.id }).map { matchesTaskCapture($0.fields, member.fields) } == true
                                  && (member.replicas ?? [member.fields]).allSatisfy { $0 == member.fields }
                          }),
                          captured.originals.map(\.reference) == snapshot.originals.map(\.reference),
                          let dependencies = captured.dependencies, let currentDependencies = snapshot.dependencies,
                          dependencies.allSatisfy({ dependency in
                              guard let current = currentDependencies.first(where: { $0.owner == dependency.owner }) else { return false }
                              if dependency.owner.entity == .note {
                                  return current.fields["associationGeneration"] == dependency.fields["associationGeneration"]
                              }
                              return current.fields == dependency.fields
                          }) else { return refused() }
                } else if record.snapshot != snapshotBytes { return refused() }
            }
            var documents: [UUID: NoteDocument] = [:]
            var materializedTags: [UUID: [String]] = [:]
            var patches: [WorkspaceMaterializationPatch] = []
            for (id, replicas) in Dictionary(grouping: notes, by: \.id) {
                guard let first = replicas.first, replicas.allSatisfy({ $0.content == first.content && $0.contentFormat == first.contentFormat && $0.deletedAt == first.deletedAt && $0.taskID == first.taskID && $0.associationGeneration == first.associationGeneration }) else { return refused() }
                if first.deletedAt != nil { continue }
                guard let data = first.content, case let .editable(stored) = NoteContentCodec.decode(data) else { continue }
                let before = ownership.drafts[id] ?? stored
                let materialized = try WorkspaceTaskNoteMaterializer.materialize(before, taskID: first.taskID ?? rootID, preservation: snapshot)
                let after = materialized.document
                materializedTags[id] = materialized.tags
                documents[id] = after
                patches.append(.init(noteID: id, taskID: first.taskID ?? rootID, preservationRootID: rootID, preservationID: preservationID, before: before, after: after))
            }
            guard Set(ownership.drafts.keys).isSubset(of: Set(documents.keys)) else { return refused() }
            let draftVersionIDs = Dictionary(uniqueKeysWithValues: ownership.drafts.keys.map { ($0, UUID()) })
            let versionIDs = Dictionary(uniqueKeysWithValues: notes.filter { documents[$0.id] != nil }.map { ($0.persistentModelID, UUID()) })
            let attachmentRows = try context.fetch(FetchDescriptor<NoteAttachment>()).filter { ownIDs.contains($0.noteID) }
            let missingAssociations = ownIDs.subtracting(Set(associations.map(\.noteID)))
            let detachedIDs = Dictionary(uniqueKeysWithValues: missingAssociations.map { ($0, UUID()) })
            // These notes and associations are detached in this purge's own
            // envelope. Retain their links through the same redirect rather
            // than collecting a link whose writing endpoint survives.
            let linkedTaskIDs = Set((affectedLinks.compactMap(\.source) + affectedLinks.compactMap(\.target))
                .filter { $0.kind == .task }.map(\.id))
            var redirects: [UUID: UUID] = [:]
            for note in notes {
                let candidates = Set([note.taskID].compactMap { $0 })
                    .union(associations.filter { $0.noteID == note.id }.map(\.taskID))
                guard !candidates.isDisjoint(with: linkedTaskIDs) else { continue }
                guard candidates.count == 1, let taskID = candidates.first else { return refused() }
                if let old = redirects[taskID], old != note.id { return refused() }
                redirects[taskID] = note.id
            }
            var redirectedLinks: [PersistentIdentifier: (AtticItemRef, AtticItemRef)] = [:]
            for link in affectedLinks {
                guard let source = link.source, let target = link.target else { return refused() }
                func redirected(_ endpoint: AtticItemRef) -> AtticItemRef {
                    guard endpoint.kind == .task, let note = redirects[endpoint.id] else { return endpoint }
                    return .init(.note, note)
                }
                let afterSource = redirected(source), afterTarget = redirected(target)
                if afterSource != afterTarget, !touching.contains(afterSource), !touching.contains(afterTarget) {
                    redirectedLinks[link.persistentModelID] = (afterSource, afterTarget)
                }
            }
            let linkTimestamp = Date()

            var owners = taskOwners.union(notes.map { WorkspaceOwner(entity: .note, id: $0.id) })
                .union(associations.map { WorkspaceOwner(entity: .association, id: $0.id) })
                .union(detachedIDs.values.map { WorkspaceOwner(entity: .association, id: $0) })
            owners.formUnion(draftVersionIDs.values.map { .init(entity: .version, id: $0) })
            owners.formUnion(ownership.staged.values.flatMap { $0 }.map { .init(entity: .attachment, id: $0.id) })
            owners.formUnion(versionIDs.values.map { .init(entity: .version, id: $0) })
            owners.formUnion(attachmentRows.map { .init(entity: .attachment, id: $0.id) })
            owners.insert(.init(entity: .preservation, id: preservationID))
            owners.formUnion(affectedLinkIDs.map { .init(entity: .link, id: $0) })
            let prepared = try documents.mapValues { try PreparedNoteDocument($0) }
            let tokens = owners.union(initial.keys).map { initial[$0] ?? WorkspaceModelToken(owner: $0, replicas: []) }
            let scopes = entities.map { index.token(.all($0)) }
            var preDraft: NoteDraftJournalEntry?
            if let (id, document) = ownership.drafts.first, let row = notes.first(where: { $0.id == id }) {
                let staged = ownership.staged[id] ?? [], selection = ownership.selections[id] ?? NSRange(location: 0, length: 0)
                var entry = NoteDraftJournalEntry(noteID: id, isPersisted: true, baseRevisionID: row.revisionID,
                    content: try PreparedNoteDocument(document).content, selectionLocation: selection.location,
                    selectionLength: selection.length, staged: staged.map { .init(id: $0.id, filename: $0.filename,
                        contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount, digest: $0.digest) }, savedAt: Date())
                entry.tags = ownership.tags[id] ?? row.tags; entry.tagsChanged = ownership.tags[id] != nil
                let claim = try await coordinator.journal.writeDurably(entry, staged: staged, replacing: ownership.claims[id])
                checkpoint = (id, claim); preDraft = entry
            }
            let envelope = try coordinator.newEnvelope(intent: "Remove task permanently", reads: tokens, writes: owners, scopes: scopes,
                preDraft: preDraft, afterDocuments: prepared.mapValues(\.content), checkpointClaim: checkpoint?.1,
                staged: ownership.staged.values.flatMap { $0 })
            let materializationSteps: [@MainActor (UUID) throws -> Void] = materialize.map { handler in
                [{ operation in try handler(operation, patches) }]
            } ?? []
            let outcome = await coordinator.execute(envelope, sessionValid: {
                guard let current = try? inventory() else { return false }
                return current.generation == ownership.generation && files.files.validatesCollection(collection, ids: leasedIDs)
            }, collection: collection, stage: { commit in
                let records = try commit.fetch(FetchDescriptor<TaskDeletionPreservation>()).filter { $0.id == preservationID }
                if records.isEmpty {
                    let record = TaskDeletionPreservation(id: preservationID, rootID: rootID, deletedAt: deletedAt,
                        capturedAt: Date(), provenance: "legacy intact-row capture", snapshot: snapshotBytes)
                    record.purgedAt = Date(); record.retiredAt = record.purgedAt
                    record.dependencyOwnersData = try WorkspaceModelFields.encode(snapshot.dependencies?.map(\.owner) ?? [])
                    commit.insert(record)
                } else { records.forEach { $0.purgedAt = Date(); $0.retiredAt = $0.purgedAt } }
                for (id, document) in ownership.drafts {
                    let old = try PreparedNoteDocument(document), row = notes.first(where: { $0.id == id })!
                    commit.insert(NoteVersion(id: draftVersionIDs[id]!, noteID: id, createdAt: Date(), reason: .replacedByDraft,
                        content: old.content, contentFormat: document.format, title: old.title, body: old.body,
                        attachmentIDs: document.attachmentIDs, sourceRevisionID: row.revisionID))
                }
                for (id, document) in documents {
                    try NoteStore.stageDocument(in: commit, noteID: id, document: document, prepared: prepared[id]!,
                        revisionID: UUID(), versionIDs: versionIDs, staged: ownership.staged[id] ?? [],
                        tags: materializedTags[id], timestamp: Date())
                }
                for note in try commit.fetch(FetchDescriptor<NoteItem>()) where ownIDs.contains(note.id) {
                    note.taskID = nil; note.associationGeneration += 1
                }
                for association in try commit.fetch(FetchDescriptor<TaskNoteAssociation>()) where owners.contains(.init(entity: .association, id: association.id)) {
                    association.taskGeneration += 1; association.noteGeneration += 1
                    association.detachedAt = Date(); association.detachedPreservationID = preservationID
                }
                for (noteID, id) in detachedIDs {
                    let sourceID = notes.first(where: { $0.id == noteID })?.taskID ?? rootID
                    let association = TaskNoteAssociation(id: id, taskID: sourceID, noteID: noteID)
                    association.taskGeneration = family.first(where: { $0.id == sourceID }).map { $0.associationGeneration + 1 } ?? 1
                    association.detachedAt = Date(); association.detachedPreservationID = preservationID
                    association.noteGeneration = notes.filter { $0.id == noteID }.map(\.associationGeneration).max().map { $0 + 1 } ?? 1
                    commit.insert(association)
                }
                for row in affectedLinks {
                    guard let link = commit.model(for: row.persistentModelID) as? ItemLink else { throw WorkspaceFoundationError.conflict }
                    if let endpoints = redirectedLinks[row.persistentModelID] {
                        link.sourceKindRaw = endpoints.0.kind.rawValue; link.sourceID = endpoints.0.id
                        link.targetKindRaw = endpoints.1.kind.rawValue; link.targetID = endpoints.1.id
                        link.updatedAt = linkTimestamp
                    } else { commit.delete(link) }
                }
                _ = try TaskStore.stagePermanentRemoval(in: commit, rootID: rootID, before: cutoff, confirmed: confirmed)
            }, publication: .init(steps: materializationSteps + publication.steps))
            if outcome == .committed {
                WorkspaceCrashHook.reach("K8-before-unlink")
                // § 13: a migration record keeps the legacy originals it covers.
                let covered = (try? TaskAttachmentMigration.coveredAttachmentIDs(in: coordinator.freshContext())) ?? Set(references.map(\.id))
                await files.remove(references.filter { !covered.contains($0.id) }, collection: collection)
            }
            return Result(outcome: outcome, operationID: envelope.id,
                removedIDs: outcome == .committed || outcome == .publicationPending ? ids : [], preservationID: preservationID,
                materialization: [.committed, .publicationPending, .unknown].contains(outcome) ? patches : [], checkpoint: checkpoint)
        } catch { return refused(.unknown) }
    }
    static func legacyReferences(_ task: TaskItem) throws -> [TaskImageReference] {
        let shown = try task.imageReferencesData.map { try JSONDecoder().decode([TaskImageReference].self, from: $0) } ?? []
        let removed = try task.removedAttachmentsData.map { try JSONDecoder().decode([RemovedTaskAttachment].self, from: $0) } ?? []
        return shown + removed.map(\.reference)
    }
}
