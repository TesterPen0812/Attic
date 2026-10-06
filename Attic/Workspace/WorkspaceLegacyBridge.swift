import Foundation
import ObjectiveC
import SwiftData

/// Plain writes save the store context in place. Journaled writes retain the
/// fresh-context envelope/receipt path and full publication refresh.
@MainActor
enum WorkspaceLegacyBridge {
    private final class WeakCoordinator {
        weak var value: WorkspaceOperationCoordinator?
        init(_ value: WorkspaceOperationCoordinator) { self.value = value }
    }
    /// Complete scope guards are taken only when a context is opened/refreshed.
    /// Incremental replacement mutates dictionaries in place; ordinary saves
    /// neither enumerate a membership nor copy the full inventory.
    @MainActor private final class ScopeBaseline {
        var inventory: [WorkspaceOwner: WorkspaceModelToken] = [:]
        var membership: [WorkspaceScope: [WorkspaceOwner: WorkspaceModelToken]] = [:]
        init(_ inventory: [WorkspaceOwner: WorkspaceModelToken]) throws { try replace(inventory) }
        func replace(_ updates: [WorkspaceOwner: WorkspaceModelToken]) throws {
            for (owner, token) in updates {
                if let old = inventory[owner] {
                    for replica in old.replicas {
                        for scope in try WorkspaceCommitLedger.membership(owner, fields: replica.fields) {
                            membership[scope]?[owner] = nil
                        }
                    }
                }
                inventory[owner] = token
                for replica in token.replicas {
                    for scope in try WorkspaceCommitLedger.membership(owner, fields: replica.fields) {
                        membership[scope, default: [:]][owner] = token
                    }
                }
            }
        }
        func token(_ scope: WorkspaceScope) -> WorkspaceScopeToken {
            let members: [WorkspaceModelToken]
            if case let .all(entity) = scope { members = inventory.values.filter { $0.owner.entity == entity && !$0.replicas.isEmpty } }
            else { members = Array(membership[scope, default: [:]].values) }
            return WorkspaceScopeToken(scope: scope, members: members.sorted { $0.owner.id.uuidString < $1.owner.id.uuidString })
        }
    }
    private final class RootRow {
        let physicalID: PersistentIdentifier
        weak var model: (any PersistentModel)?
        init(_ row: any PersistentModel) { physicalID = row.persistentModelID; model = row }
    }
    private final class ContextState {
        let coordinator: WorkspaceOperationCoordinator
        var baseline: [WorkspaceOwner: WorkspaceModelToken]
        var scopes: [WorkspaceScope: WorkspaceScopeToken] = [:]
        var captureFailed = false
        let includeCanvas: Bool
        var plainCommit = false
        var scopeBaseline: ScopeBaseline?
        // Only references and scalar membership from rows presentation already
        // fetched. Owner fingerprints and dependency guards are demand-loaded.
        var rootFamilies: [WorkspaceOwner: [RootRow]] = [:]
        var rootMembers: [WorkspaceScope: Set<WorkspaceOwner>] = [:]
        var rootEntities = Set<WorkspaceOwner.Entity>()
        var capturedOwners = Set<WorkspaceOwner>()
        var foreignAttachmentsChanged: ((Set<UUID>?) -> Void)?
        init(_ coordinator: WorkspaceOperationCoordinator, _ baseline: [WorkspaceOwner: WorkspaceModelToken], includeCanvas: Bool,
             scopes: [WorkspaceScope: WorkspaceScopeToken] = [:]) {
            self.coordinator = coordinator; self.baseline = baseline; self.includeCanvas = includeCanvas; self.scopes = scopes
        }
    }
    private static var coordinators: [ObjectIdentifier: WeakCoordinator] = [:]
    private static var contextKey: UInt8 = 0
    private final class JournalDirectory {
        weak var container: ModelContainer?
        let url: URL
        init(_ url: URL, _ container: ModelContainer) { self.url = url; self.container = container }
    }
    private static var journalDirectories: [ObjectIdentifier: JournalDirectory] = [:]
    private static func trimRegistries() {
        coordinators = coordinators.filter { $0.value.value != nil }
        journalDirectories = journalDirectories.filter { $0.value.container != nil }
    }
    static func configureJournalDirectory(_ directory: URL, for container: ModelContainer) {
        trimRegistries()
        journalDirectories[ObjectIdentifier(container)] = JournalDirectory(directory, container)
    }
    static func register(_ coordinator: WorkspaceOperationCoordinator) {
        trimRegistries()
        coordinators[ObjectIdentifier(coordinator.container)] = WeakCoordinator(coordinator)
    }
    static func coordinator(for container: ModelContainer) throws -> WorkspaceOperationCoordinator {
        trimRegistries()
        if let existing = coordinators[ObjectIdentifier(container)]?.value { return existing }
        let directory: URL
        if let configured = journalDirectories[ObjectIdentifier(container)] {
            directory = configured.url
        } else if let disk = container.configurations.first(where: { !$0.isStoredInMemoryOnly }) {
            directory = disk.url.deletingLastPathComponent().appendingPathComponent("NoteDrafts", isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AtticWorkspaceBridge-\(UUID().uuidString)", isDirectory: true)
        }
        return try WorkspaceOperationCoordinator(container: container, journal: NoteDraftJournal(directory: directory))
    }
    static func context(for container: ModelContainer, includeCanvas: Bool = false, captureScopes: Bool = true) -> ModelContext {
        let context = ModelContext(container); context.autosaveEnabled = false
        // A failed baseline is represented by no registration. persist then
        // refuses; it never manufactures an empty read set from the failure.
        try? registerContext(context, includeCanvas: includeCanvas, captureScopes: captureScopes)
        return context
    }
    static func registerContext(_ context: ModelContext, includeCanvas: Bool = false,
                                baseline: [WorkspaceOwner: WorkspaceModelToken]? = nil, captureScopes: Bool = true) throws {
        context.autosaveEnabled = false
        let coordinator = try coordinator(for: context.container)
        coordinator.ledger.register(context)
        let baseline = baseline ?? [:]
        let state = ContextState(coordinator, baseline, includeCanvas: includeCanvas)
        if captureScopes {
            let entities: Set<WorkspaceOwner.Entity> = [.task, .note, .attachment, .version, .proposal, .association, .preservation]
            let inventory = try inventory(in: context, includeCanvas: false,
                entities: entities.intersection(WorkspaceCommitLedger.supportedEntities(in: context.container)))
            state.scopeBaseline = try ScopeBaseline(inventory)
        }
        objc_setAssociatedObject(context, &contextKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func foreignContextDidSave(_ context: ModelContext, identifiers: [PersistentIdentifier], deleted: [PersistentIdentifier]) {
        guard let state = objc_getAssociatedObject(context, &contextKey) as? ContextState else { return }
        // Confirm only the direct save's rows. Cached unrelated values are not
        // refreshed by didSave, so its original ledger generation stays put.
        var owners = Set<WorkspaceOwner>()
        for id in identifiers {
            // The registered-model cache is weak: an inline inserted fixture
            // row may have gone away while its permanent identifier remains.
            let row = WorkspaceCommitLedger.registeredModel(id, in: context) ?? context.model(for: id)
            if let owner = WorkspaceOperationCoordinator.owner(row) { owners.insert(owner) }
            else { state.captureFailed = true }
        }
        for id in deleted {
            if let owner = (Array(state.baseline.values) + Array(state.scopeBaseline?.inventory.values ?? [:].values) + state.scopes.values.flatMap(\.members))
                .first(where: { $0.replicas.contains { $0.physicalID == id } })?.owner { owners.insert(owner) }
            else if let entity = WorkspaceCommitLedger.entity(for: id) {
                // The saving fixture never acquired this deleted owner's guard.
                // Its entity is already invalidated in the ledger; drop only
                // unconfirmable scope snapshots in this saving context.
                state.scopes = state.scopes.filter { $0.key.entity != entity }
            } else { state.captureFailed = true }
        }
        let attachments = Set(owners.filter { $0.entity == .attachment }.map(\.id))
        if identifiers.contains(where: { $0.entityName == "NoteAttachment" }) || deleted.contains(where: { $0.entityName == "NoteAttachment" }) {
            state.foreignAttachmentsChanged?(attachments.isEmpty ? nil : attachments)
        }
        do {
            let confirmed = try WorkspaceModelToken.read(owners: owners, in: context)
            try updateScopeGuards(confirmed, state: state, in: context)
            state.baseline.merge(confirmed) { _, saved in saved }
            try state.scopeBaseline?.replace(confirmed)
            state.capturedOwners.removeAll()
        } catch { state.captureFailed = true }
    }
    static func observeForeignAttachmentWrites(in context: ModelContext, handler: @escaping (Set<UUID>?) -> Void) {
        (objc_getAssociatedObject(context, &contextKey) as? ContextState)?.foreignAttachmentsChanged = handler
    }
    static func establishScopeBaseline(_ context: ModelContext, roots: [any PersistentModel],
                                       entities: Set<WorkspaceOwner.Entity>) throws {
        guard let state = objc_getAssociatedObject(context, &contextKey) as? ContextState else { throw WorkspaceFoundationError.unknown }
        state.rootEntities = entities
        state.rootFamilies.removeAll()
        state.rootMembers.removeAll()
        for row in roots {
            guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.unknown }
            state.rootFamilies[owner, default: []].append(RootRow(row))
            for scope in WorkspaceCommitLedger.membership(row) { state.rootMembers[scope, default: []].insert(owner) }
        }
    }
    private static func rootToken(_ owner: WorkspaceOwner, state: ContextState, in source: ModelContext) throws -> WorkspaceModelToken? {
        guard let rows = state.rootFamilies[owner] else { return nil }
        return try WorkspaceModelToken.capture(owners: [owner], models: rows.map { $0.model ?? source.model(for: $0.physicalID) })[owner]
    }
    /// Mutation sites prepare the owner's dependency guards once, before
    /// staging. The capture-only API below itself performs no SQL/scope reads.
    static func prepareMutation(_ row: any PersistentModel, in source: ModelContext) {
        prepareMutations([row], in: source)
    }
    static func prepareMutations(_ rows: [any PersistentModel], in source: ModelContext) {
        captureBeforeMutations(rows, in: source)
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState, !state.captureFailed else { return }
        do {
            var tokens = rows.compactMap { WorkspaceOperationCoordinator.owner($0).flatMap { state.baseline[$0] } }
            for token in tokens {
                for replica in token.replicas {
                    for field in ["parentID", "taskID"] {
                        if let bytes = replica.fields[field], let id = try JSONDecoder().decode(UUID?.self, from: bytes) {
                            tokens.append(try capturedToken(.init(entity: .task, id: id), in: source))
                        }
                    }
                }
            }
            _ = try scopeTokens(WorkspaceScopeToken.scopes(for: tokens), state: state, in: source)
        } catch { state.captureFailed = true }
    }
    private static func scopeTokens(_ scopes: Set<WorkspaceScope>, state: ContextState, in source: ModelContext) throws -> [WorkspaceScopeToken] {
        var missing = scopes.filter { state.scopes[$0] == nil }
        for scope in missing {
            if let baseline = state.scopeBaseline {
                state.scopes[scope] = baseline.token(scope)
            } else if state.rootEntities.contains(scope.entity) {
                let owners: Set<WorkspaceOwner>
                if case let .all(entity) = scope { owners = Set(state.rootFamilies.keys.filter { $0.entity == entity }) }
                else { owners = state.rootMembers[scope] ?? [] }
                let members = try owners.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { owner in
                    try state.baseline[owner] ?? rootToken(owner, state: state, in: source)
                }
                state.scopes[scope] = WorkspaceScopeToken(scope: scope, members: members)
            }
        }
        missing = missing.filter { state.scopes[$0] == nil }
        if !missing.isEmpty {
            let read = try WorkspaceScopeToken.read(scopes: missing, in: source)
            let inserted = Set(source.insertedModelsArray.map(\.persistentModelID))
            // A batch may already have staged other captured rows. Restore
            // their before-values and expected absence in these new guards.
            for scope in missing {
                var members = Dictionary(uniqueKeysWithValues: read[scope]!.members.map { ($0.owner, $0) })
                for (owner, token) in members {
                    let persisted = token.replicas.filter { !inserted.contains($0.physicalID) }
                    members[owner] = persisted.isEmpty ? nil : WorkspaceModelToken(owner: owner, replicas: persisted)
                }
                for (owner, original) in state.baseline where owner.entity == scope.entity {
                    let belongs = try original.replicas.contains { replica in
                        if case .all = scope { return true }
                        return try WorkspaceCommitLedger.membership(owner, fields: replica.fields).contains(scope)
                    }
                    if belongs { members[owner] = original }
                    else { members[owner] = nil }
                }
                state.scopes[scope] = WorkspaceScopeToken(scope: scope, members: members.values.sorted { $0.owner.id.uuidString < $1.owner.id.uuidString })
            }
        }
        return scopes.map { state.scopes[$0]! }
    }
    private static func updateScopeGuards(_ updates: [WorkspaceOwner: WorkspaceModelToken], state: ContextState, in source: ModelContext) throws {
        for (owner, token) in updates {
            let previous = state.baseline[owner]
            var affected: Set<WorkspaceScope> = [.all(owner.entity)]
            for value in [previous, token].compactMap({ $0 }) {
                for replica in value.replicas { affected.formUnion(try WorkspaceCommitLedger.membership(owner, fields: replica.fields)) }
            }
            for scope in affected {
                let belongs = try token.replicas.contains { replica in
                    if case .all = scope { return true }
                    return try WorkspaceCommitLedger.membership(owner, fields: replica.fields).contains(scope)
                }
                if state.rootEntities.contains(owner.entity) {
                    if belongs { state.rootMembers[scope, default: []].insert(owner) }
                    else { state.rootMembers[scope]?.remove(owner) }
                }
                if let guardToken = state.scopes[scope] {
                    var members = guardToken.members.filter { $0.owner != owner }
                    if belongs { members.append(token) }
                    state.scopes[scope] = WorkspaceScopeToken(scope: scope, members: members.sorted { $0.owner.id.uuidString < $1.owner.id.uuidString })
                }
            }
            if state.rootEntities.contains(owner.entity),
               state.rootFamilies[owner]?.map(\.physicalID) != token.replicas.map(\.physicalID) {
                // An in-place save preserves the existing family instances.
                // Rebuild weak roots only for physical inserts or removals.
                state.rootFamilies[owner] = token.replicas.isEmpty ? nil : token.replicas.map { RootRow(source.model(for: $0.physicalID)) }
            }
        }
    }
    static func capturedToken(_ owner: WorkspaceOwner, in source: ModelContext) throws -> WorkspaceModelToken {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else { throw WorkspaceFoundationError.unknown }
        if let token = state.baseline[owner] { return token }
        let token = try state.scopeBaseline?.inventory[owner] ?? rootToken(owner, state: state, in: source) ?? WorkspaceModelToken.read(owner, in: source)
        state.baseline[owner] = token
        return token
    }
    static func captureBeforeMutation(_ row: any PersistentModel, in source: ModelContext) {
        captureBeforeMutations([row], in: source)
    }
    static func captureBeforeMutations(_ rows: [any PersistentModel], in source: ModelContext) {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else { return }
        let inserted = Set(source.insertedModelsArray.map { ObjectIdentifier($0) })
        let existing = rows.filter { !inserted.contains(ObjectIdentifier($0)) }
        let owners = Set(existing.compactMap { WorkspaceOperationCoordinator.owner($0) })
        do {
            let missing = owners.filter { state.baseline[$0] == nil }
            for owner in missing {
                if let known = state.scopeBaseline?.inventory[owner] { state.baseline[owner] = known; continue }
                // Presented replicas are already resident. Include the complete
                // logical family without faulting or fetching other owners.
                let resident = (state.rootFamilies[owner] ?? []).compactMap(\.model)
                let family = Dictionary((resident + existing.filter { WorkspaceOperationCoordinator.owner($0) == owner })
                    .map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first }).values
                state.baseline.merge(try WorkspaceModelToken.capture(owners: [owner], models: Array(family))) { saved, _ in saved }
            }
            // An early capture freezes the visible row before its family
            // fetch can refresh values. A weak, unpresented replica may not
            // have been resident then. Complete only physical IDs known at
            // presentation open from the supplied, still-unstaged family;
            // never admit an externally inserted replica into that baseline.
            for owner in owners {
                guard let original = state.baseline[owner], let roots = state.rootFamilies[owner] else { continue }
                if roots.count == 1, original.replicas.count == 1,
                   roots[0].physicalID == original.replicas[0].physicalID { continue }
                let known = Set(roots.map(\.physicalID))
                let captured = Set(original.replicas.map(\.physicalID))
                let additional = existing.filter {
                    WorkspaceOperationCoordinator.owner($0) == owner && known.contains($0.persistentModelID) && !captured.contains($0.persistentModelID)
                }
                if !additional.isEmpty, let extra = try WorkspaceModelToken.capture(owners: [owner], models: additional)[owner] {
                    state.baseline[owner] = WorkspaceModelToken(owner: owner,
                        replicas: (original.replicas + extra.replicas).sorted { String(describing: $0.physicalID) < String(describing: $1.physicalID) })
                }
            }
            state.capturedOwners.formUnion(owners)
            try state.coordinator.ledger.observe(owners.compactMap { state.baseline[$0] })
        } catch { state.captureFailed = true }
    }
    static func delete(_ row: any PersistentModel, in context: ModelContext) {
        prepareMutation(row, in: context)
        context.delete(row)
    }
    static func wasPlainCommit(in source: ModelContext) throws -> Bool {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else { throw WorkspaceFoundationError.unknown }
        return state.plainCommit
    }

    /// Reuse only complete, durable families from an in-place commit. A
    /// missing resident replica or an intervening writer requires a fetch.
    static func confirmedTaskReplicas(_ ids: Set<UUID>, in source: ModelContext) -> [TaskItem]? {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState,
              state.plainCommit, !source.hasChanges else { return nil }
        let owners = Set(ids.map { WorkspaceOwner(entity: .task, id: $0) })
        guard state.coordinator.ledger.canValidate(source, owners: owners, scopes: []) else { return nil }
        var rows: [TaskItem] = []
        for owner in owners {
            guard let token = state.baseline[owner] else { return nil }
            for replica in token.replicas {
                guard let row = source.registeredModel(for: replica.physicalID) as TaskItem?,
                      row.id == owner.id else { return nil }
                rows.append(row)
            }
        }
        return rows
    }

    struct CommitHeld: Error {}

    static func persist(_ source: ModelContext, using writer: @escaping (ModelContext) throws -> Void,
                        sourceName: String, history: Bool = true) throws {
        guard let state = objc_getAssociatedObject(source, &contextKey) as? ContextState else {
            throw WorkspaceFoundationError.unknown
        }
        guard !state.captureFailed else { throw WorkspaceFoundationError.unknown }
        let changes = source.insertedModelsArray + source.changedModelsArray + source.deletedModelsArray
        guard let admission = state.coordinator.ownership.tryAcquire(try state.coordinator.admissionIDs(changes, before: Array(state.baseline.values)), kind: .admission) else {
            throw WorkspaceFoundationError.pendingPublication
        }
        defer { admission.release() }
        let writes = Set(try changes.map { row -> WorkspaceOwner in
            guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.conflict }
            return owner
        })
        if writes.isEmpty { return }
        // No save has been attempted for this edit. Refusal must use the
        // caller's rollback path, never the ambiguous-save dirty-state path.
        guard state.coordinator.retryHeldWrites(affecting: writes) else {
            throw WorkspaceFoundationError.protectedOwner
        }
        var before: [WorkspaceOwner: WorkspaceModelToken] = [:]
        for owner in writes {
            // Inserts have expected absence; changed/deleted owners must have
            // a guard captured before their first staged mutation.
            if let captured = state.baseline[owner] { before[owner] = captured; state.capturedOwners.insert(owner) }
            else if let captured = state.scopeBaseline?.inventory[owner] {
                // Membership guards captured this complete physical family at
                // full refresh too. Direct fixture deletes can use that exact
                // before-token without a late read of their staged values.
                before[owner] = captured
                state.capturedOwners.insert(owner)
            }
            else if state.rootFamilies[owner] != nil {
                let scopes = WorkspaceScopeToken.scopes(for: [WorkspaceModelToken(owner: owner, replicas: [])])
                guard state.coordinator.ledger.canValidate(source, owners: [owner], scopes: scopes) else { throw WorkspaceFoundationError.conflict }
                let original = try WorkspaceModelToken.read(owner, in: state.coordinator.freshContext())
                before[owner] = original; state.baseline[owner] = original; state.capturedOwners.insert(owner)
            }
            else if changes.filter({ WorkspaceOperationCoordinator.owner($0) == owner }).allSatisfy({ row in
                source.insertedModelsArray.contains { $0 === row }
            }) { before[owner] = WorkspaceModelToken(owner: owner, replicas: []) }
            else { throw WorkspaceFoundationError.unknown }
        }
        for owner in writes {
            if let roots = state.rootFamilies[owner],
               !Set(roots.map(\.physicalID)).isSubset(of: Set(before[owner]?.replicas.map(\.physicalID) ?? [])) {
                // A partial early capture is not a complete logical-family
                // guard. The mutation site must supply its unstaged replicas.
                throw WorkspaceFoundationError.conflict
            }
        }
        let after = try WorkspaceModelToken.capture(owners: writes,
            models: WorkspaceModelToken.stagedModels(owners: writes, before: before, in: source))
        // Include metadata consumed at associated endpoints and parent heads.
        // Membership scopes below come from the original staging baseline.
        for token in Array(before.values) + Array(after.values) {
            for replica in token.replicas {
                for field in ["parentID", "taskID"] {
                    if let bytes = replica.fields[field], let id = try JSONDecoder().decode(UUID?.self, from: bytes) {
                        let owner = WorkspaceOwner(entity: .task, id: id)
                        // A parent created in this same batch still has
                        // expected absence; never replace it with staged rows.
                        if before[owner] == nil { before[owner] = try capturedToken(owner, in: source) }
                    }
                }
            }
        }
        let reads = before.values.sorted { ($0.owner.entity.rawValue, $0.owner.id.uuidString) < ($1.owner.entity.rawValue, $1.owner.id.uuidString) }
        let plain = try state.coordinator.mayUsePlainSave(
            before: writes.map { before[$0]! }, after: writes.map { after[$0]! }, in: source)
        let requiredScopes = WorkspaceScopeToken.scopes(for: reads)
        if plain {
            var confirmed: [WorkspaceOwner: WorkspaceModelToken] = [:]
            let result = state.coordinator.commitInPlace(source, before: reads, requiredScopes: requiredScopes,
                scopes: { try scopeTokens(requiredScopes, state: state, in: source) },
                after: writes.map { after[$0]! }, capturedOwners: state.capturedOwners, using: writer,
                confirmed: { confirmed = $0 })
            guard result == .committed else {
                if result == .unknown { throw CommitHeld() }
                throw result == .conflict ? WorkspaceFoundationError.conflict : WorkspaceFoundationError.unknown
            }
            try updateScopeGuards(confirmed, state: state, in: source)
            state.baseline.merge(confirmed) { _, saved in saved }
            try state.scopeBaseline?.replace(confirmed)
            state.capturedOwners.removeAll()
            state.plainCommit = true
            return
        }
        let scopes = try scopeTokens(requiredScopes, state: state, in: source)
        var staged: [StagedNoteAttachment] = []
        for row in changes.compactMap({ $0 as? NoteAttachment }) {
            let old = before[.init(entity: .attachment, id: row.id)]?.replicas.first { $0.physicalID == row.persistentModelID }
            guard let next = after[.init(entity: .attachment, id: row.id)]?.replicas.first(where: { $0.physicalID == row.persistentModelID }),
                  old?.fields["payload"] != next.fields["payload"] else { continue }
            // New bytes are already supplied by ingestion. Only this class
            // needs payload materialization and a durable envelope.
            guard let payload = row.payload else { throw WorkspaceFoundationError.protectedOwner }
            staged.append(try state.coordinator.journal.verifiedAttachmentSynchronously(id: row.id,
                filename: row.originalFilename, contentType: row.contentTypeIdentifier,
                byteCount: row.byteCount, digest: row.contentDigest, bytes: payload))
        }
        var documents: [UUID: Data] = [:]
        if !plain {
            for owner in writes where owner.entity == .note {
                let id = owner.id
                let rows = try source.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
                let contents = rows.compactMap(\.content)
                if contents.count == rows.count, Set(contents).count == 1 { documents[id] = contents.first }
            }
        }
        var preDraft: NoteDraftJournalEntry?
        if !plain, documents.count == 1, let (id, document) = documents.first {
            let newNote = before[.init(entity: .note, id: id)]?.replicas.isEmpty == true
            let pre = state.coordinator.freshContext()
            let beforeContent = try pre.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first?.content
            preDraft = NoteDraftJournalEntry(noteID: id, isPersisted: !newNote, baseRevisionID: nil,
                content: !history || newNote ? document : (beforeContent ?? document), selectionLocation: 0, selectionLength: 0,
                staged: staged.map { .init(id: $0.id, filename: $0.filename, contentTypeIdentifier: $0.contentTypeIdentifier,
                    byteCount: $0.byteCount, digest: $0.digest) }, savedAt: Date())
        }
        var confirmed: [WorkspaceOwner: WorkspaceModelToken]?
        try state.coordinator.commitCompatibility(tokens: reads, scopes: scopes, writes: writes, intent: sourceName,
            plain: plain, writer: writer, staged: staged, afterDocuments: documents, preDraft: preDraft,
            confirmed: { confirmed = $0 }, stage: { target in
                for owner in writes {
                    guard let old = before[owner], let new = after[owner] else { throw WorkspaceFoundationError.unknown }
                    let oldByID = Dictionary(uniqueKeysWithValues: old.replicas.map { ($0.physicalID, $0.fields) })
                    let newIDs = Set(new.replicas.map(\.physicalID))
                    for replica in old.replicas where !newIDs.contains(replica.physicalID) {
                        target.delete(target.model(for: replica.physicalID))
                    }
                    for replica in new.replicas {
                        if let previous = oldByID[replica.physicalID] {
                            let patch = replica.fields.filter { previous[$0.key] != $0.value }
                            try WorkspaceModelFields.copy(Set(patch.keys), from: source.model(for: replica.physicalID),
                                to: target.model(for: replica.physicalID))
                        } else {
                            let row = try makeRow(owner.entity)
                            try WorkspaceModelFields.copy(Set(replica.fields.keys), from: source.model(for: replica.physicalID), to: row)
                            target.insert(row)
                        }
                    }
                }
            })
        // The source context remains presentation/staging only; stores replace
        // it with a fresh presentation after a confirmed commit.
        // An ambiguous-save reconciliation or journaled operation still
        // confirms from disk. Successful plain saves already returned guards
        // of every saved instance, including its now-permanent physical ID.
        let updates = try confirmed ?? WorkspaceModelToken.read(owners: writes, in: state.coordinator.freshContext())
        state.baseline = updates
        state.scopes.removeAll()
        state.plainCommit = false
    }
    static func persistSharedChanges(_ source: ModelContext, using writer: @escaping (ModelContext) throws -> Void) throws {
        if (source.insertedModelsArray + source.changedModelsArray + source.deletedModelsArray).contains(where: { $0 is ItemLink || $0 is TaskItem || $0 is NoteItem }) {
            try persist(source, using: writer, sourceName: "canvas shared-owner mutation")
        } else {
            try writer(source)
        }
    }

    static func inventory(in context: ModelContext, includeCanvas: Bool, entities: Set<WorkspaceOwner.Entity>? = nil) throws -> [WorkspaceOwner: WorkspaceModelToken] {
        let schema = Set(context.container.schema.entities.map(\.name))
        var families: [WorkspaceOwner: [WorkspaceModelToken.Replica]] = [:]
        func include<M: PersistentModel>(_ type: M.Type, name: String) throws {
            let entity: WorkspaceOwner.Entity
            switch name {
            case "TaskItem": entity = .task
            case "NoteItem": entity = .note
            case "NoteAttachment": entity = .attachment
            case "NoteVersion": entity = .version
            case "NotePendingEdit": entity = .proposal
            case "ItemLink": entity = .link
            case "TaskNoteAssociation": entity = .association
            case "TaskDeletionPreservation": entity = .preservation
            case "OperationReceipt": entity = .receipt
            case "CanvasBoardItem": entity = .board
            case "CanvasStrokeItem": entity = .stroke
            case "CanvasImageItem": entity = .image
            case "CanvasSemanticObjectItem": entity = .semantic
            default: throw WorkspaceFoundationError.unsupportedField(name)
            }
            if let entities, !entities.contains(entity) { return }
            if let entities, entities.contains(entity), !schema.contains(name) { throw WorkspaceFoundationError.unsupportedField(name) }
            guard schema.contains(name) else { return }
            for row in try context.fetch(FetchDescriptor<M>()) {
                guard let owner = WorkspaceOperationCoordinator.owner(row) else { throw WorkspaceFoundationError.unknown }
                families[owner, default: []].append(.init(physicalID: row.persistentModelID, fields: try WorkspaceModelFields.fingerprint(row)))
            }
        }
        try include(TaskItem.self, name: "TaskItem"); try include(NoteItem.self, name: "NoteItem")
        try include(NoteAttachment.self, name: "NoteAttachment"); try include(NoteVersion.self, name: "NoteVersion")
        try include(NotePendingEdit.self, name: "NotePendingEdit"); try include(ItemLink.self, name: "ItemLink")
        try include(TaskNoteAssociation.self, name: "TaskNoteAssociation"); try include(TaskDeletionPreservation.self, name: "TaskDeletionPreservation")
        try include(OperationReceipt.self, name: "OperationReceipt")
        if includeCanvas {
            try include(CanvasBoardItem.self, name: "CanvasBoardItem")
            try include(CanvasStrokeItem.self, name: "CanvasStrokeItem"); try include(CanvasImageItem.self, name: "CanvasImageItem")
            try include(CanvasSemanticObjectItem.self, name: "CanvasSemanticObjectItem")
        }
        return Dictionary(uniqueKeysWithValues: families.map { owner, rows in
            (owner, WorkspaceModelToken(owner: owner, replicas: rows.sorted { String(describing: $0.physicalID) < String(describing: $1.physicalID) }))
        })
    }
    private static func makeRow(_ entity: WorkspaceOwner.Entity) throws -> any PersistentModel {
        switch entity {
        case .task: TaskItem(title: "")
        case .note: NoteItem()
        case .attachment: NoteAttachment(noteID: UUID(), originalFilename: "", byteCount: 0, sortIndex: 0, contentDigest: "")
        case .version: NoteVersion(noteID: UUID(), createdAt: Date(), reason: .replacedByDraft, content: nil, contentFormat: 0, title: "", body: "", attachmentIDs: [], sourceRevisionID: nil)
        case .proposal: NotePendingEdit(noteID: UUID(), baseRevisionToken: "", proposedContent: Data(), agentName: "", createdAt: Date())
        case .link: ItemLink(source: .init(.task, UUID()), target: .init(.note, UUID()), kind: .reference)
        case .association: TaskNoteAssociation(taskID: UUID(), noteID: UUID())
        case .preservation: TaskDeletionPreservation(rootID: UUID(), deletedAt: Date(), capturedAt: Date(), provenance: "", snapshot: Data())
        case .receipt: OperationReceipt(id: UUID(), envelopeDigest: "", affectedIDs: Data(), resultingTokens: Data())
        case .board: CanvasBoardItem()
        case .stroke: CanvasStrokeItem()
        case .image: CanvasImageItem()
        case .semantic: CanvasSemanticObjectItem()
        }
    }
}
