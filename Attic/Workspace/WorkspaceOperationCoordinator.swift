import Foundation
import SwiftData

@MainActor
final class WorkspaceOperationCoordinator {
    enum WriteClass: Equatable { case journaled, plain, bookkeeping }
    enum Outcome: Equatable {
        case notCommitted, conflict, unknown, committed, publicationPending
    }
    struct State: Codable, Equatable {
        let owner: WorkspaceOwner
        let replicas: [String]
    }
    struct Publication {
        /// History, editor, paired presentation, index, materialization. Each
        /// handler installs by operation identity and must be idempotent.
        let steps: [@MainActor (UUID) throws -> Void]
        init(steps: [@MainActor (UUID) throws -> Void] = []) { self.steps = steps }
    }

    let container: ModelContainer
    lazy var sessions = WorkspaceSessionRegistry.shared(for: self)
    let ledger: WorkspaceCommitLedger
    struct ValidationCounters: Equatable {
        var fastValidations = 0
        var slowValidations = 0
        var freshContexts = 0
    }
    var validationCounters = ValidationCounters()
    let ownership: WorkspaceOwnershipGate
    private struct Admission {
        let content: Data
        let ids: Set<UUID>
        let digest: String
    }
    // At most four immutable documents. Linear byte equality exits at the
    // first changed bytes; Data-key dictionaries rehash the entire 5k-line
    // document on every admission lookup on the main actor.
    private var admittedDocuments: [Admission] = []
    private var admittedNoteKinds: [String: Bool] = [:]
    func observePreparedDocument(_ document: PreparedNoteDocument) {
        guard let ids = document.admissionIDs else { return }
        cacheAdmission(document.content, ids: ids, hasTaskNote: document.hasTaskNote, digest: document.contentFingerprint)
    }
    func observeValidatedDocument(_ content: Data, attachmentIDs: Set<UUID>, hasTaskNote: Bool) {
        cacheAdmission(content, ids: attachmentIDs, hasTaskNote: hasTaskNote)
    }
    func admittedContentDigest(_ content: Data) -> String? {
        admittedDocuments.first { $0.content == content }?.digest
    }
    private func cachedAdmission(_ content: Data) -> Set<UUID>? {
        admittedDocuments.first { $0.content == content }?.ids
    }
    private func cacheAdmission(_ content: Data, ids: Set<UUID>, hasTaskNote: Bool, digest: String? = nil) {
        if cachedAdmission(content) == ids { return }
        let digest = digest ?? WorkspaceModelFields.digest(content)
        admittedNoteKinds[digest] = hasTaskNote
        admittedDocuments.removeAll { $0.content == content }
        admittedDocuments.append(Admission(content: content, ids: ids, digest: digest))
        while admittedDocuments.count > 4 || admittedDocuments.reduce(0, { $0 + $1.content.count }) > 2_097_152 {
            guard admittedDocuments.count > 1 else { break }
            let expired = admittedDocuments.removeFirst()
            admittedNoteKinds.removeValue(forKey: expired.digest)
        }
    }
    private func documentAdmissionIDs(_ content: Data) -> Set<UUID> {
        if let ids = cachedAdmission(content) { return ids }
        guard case let .editable(document) = NoteContentCodec.decode(content) else { return [ownership.unknownID] }
        let ids = Set(document.attachmentIDs)
        cacheAdmission(content, ids: ids, hasTaskNote: document.requires.contains("taskNote")); return ids
    }
    private struct TaskReferences {
        let shown: Data?
        let removed: Data?
        let values: [TaskImageReference]
    }
    private var taskReferenceCache: [TaskReferences] = []
    private func taskReferences(shown: Data?, removed: Data?) throws -> [TaskImageReference] {
        if let cached = taskReferenceCache.first(where: { $0.shown == shown && $0.removed == removed }) { return cached.values }
        let references = try shown.map { try JSONDecoder().decode([TaskImageReference].self, from: $0) } ?? []
        let removedReferences = try removed.map { try JSONDecoder().decode([RemovedTaskAttachment].self, from: $0).map(\.reference) } ?? []
        let values = references + removedReferences
        taskReferenceCache.append(TaskReferences(shown: shown, removed: removed, values: values))
        while taskReferenceCache.count > 8 { taskReferenceCache.removeFirst() }
        return values
    }
    private func taskReferences(_ replica: WorkspaceModelToken.Replica) throws -> [TaskImageReference] {
        let shown = try replica.fields["imageReferencesData"].map { try JSONDecoder().decode(Data?.self, from: $0) } ?? nil
        let removed = try replica.fields["removedAttachmentsData"].map { try JSONDecoder().decode(Data?.self, from: $0) } ?? nil
        return try taskReferences(shown: shown, removed: removed)
    }
    func taskReferenceIDs(_ rows: [TaskItem]) throws -> Set<UUID> {
        try rows.reduce(into: Set<UUID>()) { ids, row in
            ids.formUnion(try taskReferences(shown: row.imageReferencesData, removed: row.removedAttachmentsData).map(\.id))
        }
    }
    private var legacyFiles: [UUID: WorkspaceOwnershipGate] = [:]
    func registerLegacyFiles(_ files: AttachmentFileStore) {
        files.registerWriter(ownership); legacyFiles[files.ownership.identity] = files.ownership
    }
    private(set) var journal: NoteDraftJournal
    private let writerLease: WorkspaceWriterLease?
    private var allocatedIDs: Set<UUID> = []
    private var pending: [UUID: (WorkspaceOperationEnvelope, WorkspaceOperationClaim, Publication)] = [:]
    private var publicationStep: [UUID: Int] = [:]
    private var heldOwners: Set<WorkspaceOwner> = []
    private var purgedMembers: Set<UUID>?
    private var tombstonesNeedReload = false
    private(set) var tombstoneLoads = 0
    private var plainUnknown: ([WorkspaceModelToken], [WorkspaceModelToken], Set<WorkspaceOwner>, [WorkspaceOwner: Set<PersistentIdentifier>])?
    private(set) var startupReconciled = false
    private var launchWork: Task<Void, Error>?
    private var launchFinished = false
    private var launchHold: WorkspaceOwnershipGate.Lease?
    private var damagedCollectionHold: WorkspaceOwnershipGate.Lease?
    private(set) var damagedCheckpointNotes = Set<UUID>()
    private var compatibilityPending = Set<UUID>()
    private var abortedCompatibility: [UUID: (WorkspaceOperationEnvelope, WorkspaceOperationClaim)] = [:]
    private var checkpointOwners = Set<WorkspaceOwner>()
    private var checkpointBytes = Set<UUID>()
    private var checkpointCollectionHold: WorkspaceOwnershipGate.Lease?
    var retainedRecoveryBytes: Set<UUID> {
        checkpointBytes.union(pending.values.flatMap { $0.0.payloads.map(\.id) })
            .union(abortedCompatibility.values.flatMap { $0.0.payloads.map(\.id) })
    }
    private(set) var launchPruneBatches: [Int] = []
    private(set) var launchPruningError: String?

    /// Called before creating the launch presentation, including Tasks-only
    /// launches. Collection waits while immutable journal owners are registered.
    func beginLaunchRegistration() {
        if launchHold == nil { launchHold = ownership.tryAcquire([ownership.unknownID], kind: .admission) }
    }
    /// Shared by app launch and Notes recovery. Presentation construction is
    /// synchronous and precedes this asynchronous, bounded maintenance work.
    func finishLaunch() async throws {
        if let launchWork { return try await launchWork.value }
        if launchFinished { return }
        beginLaunchRegistration()
        let work = Task { @MainActor in
            try await self.reconcileStartup()
            self.launchPruningError = nil
            repeat {
                do {
                    let count = try self.prunePublishedReceipts(limit: 64)
                    self.launchPruneBatches.append(count)
                    if count < 64 { break }
                } catch {
                    // Reconciled checkpoint offers do not depend on successful
                    // collection. Retain receipts and retry at the next sweep.
                    self.launchPruningError = error.localizedDescription
                    break
                }
                await Task.yield()
            } while !Task.isCancelled
            try Task.checkCancellation()
            self.launchHold?.release(); self.launchHold = nil
            self.launchFinished = self.launchPruningError == nil
        }
        launchWork = work
        do { try await work.value; launchWork = nil }
        catch { launchWork = nil; throw error } // Hold remains; the next launch retry is explicit.
    }

    /// Standalone stores have no app-launch hold. Launch collectors wait for
    /// registered maintenance rather than skipping their only cleanup pass.
    func finishRegisteredLaunch() async throws {
        if launchHold != nil { try await finishLaunch() }
    }

    /// Offers depend on reconciliation, never on unrelated directory IO.
    func finishLaunchOfferingRecovery(offers: () -> Void, sweep: () async -> Void) async throws {
        try await finishLaunch()
        offers()
        await sweep()
    }

    private struct RetryState {
        var failures: Int = 0
        var due: TimeInterval = 0
    }
    private var compatibilityRetries: [UUID: RetryState] = [:]
    var retryNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private(set) var compatibilityRetryAttempts = 0
    private(set) var compatibilityReceiptFetches = 0
    private var isRetryingCompatibility = false
    static let automaticRetryLimit = 4

    private func deferCompatibilityRetry(_ id: UUID) {
        var state = compatibilityRetries[id] ?? RetryState()
        state.failures = min(state.failures + 1, 7)
        state.due = retryNow() + min(60, pow(2, Double(state.failures - 1)))
        compatibilityRetries[id] = state
    }
    private func retryCompatibility(_ id: UUID) {
        guard let (envelope, claim, _) = pending[id] else { return }
        compatibilityRetryAttempts += 1
        isRetryingCompatibility = true
        defer { isRetryingCompatibility = false }
        switch receiptTruth(id, digest: claim.digest) {
        case .committed:
            do { try finalizeCompatibility(envelope, claim: claim) }
            catch { deferCompatibilityRetry(id) }
        case .notCommitted:
            retainAbortedCompatibility(envelope, claim: claim)
            releasePending(envelope)
        default: deferCompatibilityRetry(id)
        }
    }
    /// An explicit recovery action bypasses the schedule for this identity;
    /// it never re-executes the mutation or releases a still-held owner.
    @discardableResult
    func retryHeldWrite(_ id: UUID) -> Bool {
        guard compatibilityPending.contains(id) else { return false }
        retryCompatibility(id)
        return !compatibilityPending.contains(id)
    }
    /// The idle path remains two empty checks. Automatic callers visit only
    /// due entries, with at most four receipt/finalization attempts per save.
    /// A nil scope is an explicit retry, retained for existing recovery callers.
    func retryHeldWrites(affecting affected: Set<WorkspaceOwner>? = nil) -> Bool {
        if plainUnknown != nil, reconcilePlain() == .unknown { return false }
        if !compatibilityPending.isEmpty {
            let now = retryNow()
            let due = compatibilityPending.filter { affected == nil || (compatibilityRetries[$0]?.due ?? 0) <= now }
                .sorted {
                    let left = compatibilityRetries[$0]?.due ?? 0, right = compatibilityRetries[$1]?.due ?? 0
                    return left == right ? $0.uuidString < $1.uuidString : left < right
                }
            for id in due.prefix(Self.automaticRetryLimit) { retryCompatibility(id) }
        }
        return affected.map { $0.isDisjoint(with: heldOwners) } ?? compatibilityPending.isEmpty
    }
    private func releasePending(_ envelope: WorkspaceOperationEnvelope) {
        pending[envelope.id] = nil; publicationStep[envelope.id] = nil; compatibilityPending.remove(envelope.id)
        compatibilityRetries[envelope.id] = nil
        heldOwners.subtract(Set(envelope.tokens.map(\.owner)).union(envelope.writes))
        journal.suppressPendingOperationClaims(pending.values.compactMap { $0.0.checkpointClaim })
    }
    struct RecoveryCopy {
        let operationID: UUID
        let draft: NoteDraftJournalEntry
        let claim: WorkspaceOperationClaim
        let payloads: [WorkspaceOperationEnvelope.Payload]
    }
    private(set) var preOperationRecoveryCopies: [RecoveryCopy] = []
    private final class WeakHistory {
        weak var value: UndoRoute?
        init(_ value: UndoRoute) { self.value = value }
    }
    private var histories: [UUID: WeakHistory] = [:]
    func registerHistory(_ route: UndoRoute) {
        histories = histories.filter { $0.value.value != nil }
        histories[route.ownershipID] = WeakHistory(route)
    }
    var retainedHistoryBytes: Set<UUID> { histories.values.reduce(into: []) { $0.formUnion($1.value?.referencedAttachmentIDs ?? []) } }
    var historyReferences: () throws -> Set<UUID> = { [] }
    var recoveryReferences: () throws -> Set<UUID> = { [] }
    var save: (ModelContext) throws -> Void = { try $0.save() }
    /// Read-error seam deliberately affects reconciliation, never converts it
    /// to receipt absence. Shipping callers leave this nil.
    var beforeReconciliationRead: (() throws -> Void)?
    #if ATTIC_OPERATION_CRASH_TESTS
    var afterPreparation: (() async -> Void)?
    #endif

    init(container: ModelContainer, journal: NoteDraftJournal) throws {
        self.container = container; self.journal = journal
        ledger = WorkspaceCommitLedger(container: container)
        let disk = container.configurations.first { !$0.isStoredInMemoryOnly }
        ownership = disk.map { WorkspaceOwnershipGate.shared(for: "store:" + $0.url.resolvingSymlinksInPath().path) } ?? WorkspaceOwnershipGate()
        if let disk {
            try FileManager.default.createDirectory(at: disk.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writerLease = try WorkspaceWriterLease.attached(to: container) ?? WorkspaceWriterLease.acquire(storeURL: disk.url)
        } else { writerLease = nil }
        ledger.foreignEntitiesDidChange = { [weak self] entities in
            if entities.contains(.preservation) { self?.tombstonesNeedReload = true }
        }
        ledger.foreignContextDidSave = { WorkspaceLegacyBridge.foreignContextDidSave($0, identifiers: $1, deleted: $2) }
        WorkspaceLegacyBridge.register(self)
        observeCheckpointInventory()
    }

    private func observeCheckpointInventory() {
        journal.inventoryChanged = { [weak self] entries in
            guard let self else { return }
            do { try self.registerCheckpointInventory(entries) }
            catch {
                // Keep the last known owners and hold unbounded collection.
                if self.damagedCollectionHold == nil {
                    self.damagedCollectionHold = self.ownership.tryAcquire([self.ownership.unknownID], kind: .admission)
                }
            }
        }
    }
    private func registerCheckpointInventory(_ entries: [NoteDraftRecoveryEntry]) throws {
        var rows = Set<WorkspaceOwner>(), bytes = Set<UUID>()
        for item in entries {
            guard case let .valid(entry, _, _) = item else { throw WorkspaceFoundationError.unknown }
            rows.insert(.init(entity: .note, id: entry.noteID))
            guard let document = NoteContentCodec.decode(entry.content).document else { throw WorkspaceFoundationError.unknown }
            let ids = Set(document.attachmentIDs).union(entry.staged.map(\.id))
                .union(entry.pendingImport?.items.compactMap(\.stagedID) ?? [])
            bytes.formUnion(ids); rows.formUnion(ids.map { .init(entity: .attachment, id: $0) })
        }
        guard let hold = ownership.tryAcquire(bytes.union(rows.map(\.id)), kind: .admission) else { throw WorkspaceFoundationError.unknown }
        checkpointCollectionHold?.release(); checkpointCollectionHold = hold
        checkpointOwners = rows; checkpointBytes = bytes
        try releaseAbortedCompatibility(ownedCheckpoints: entries)
    }
    /// Proven receipt absence cancels intent, but not recovery. Release only
    /// after an independently claimed checkpoint owns the exact pre-copy and
    /// every supplied payload. A damaged or different copy never qualifies;
    /// this handoff does not replace or retire any checkpoint.
    private func retainAbortedCompatibility(_ envelope: WorkspaceOperationEnvelope, claim: WorkspaceOperationClaim) {
        abortedCompatibility[envelope.id] = (envelope, claim)
        if let checkpoints = try? journal.inventoryCheckpointsSynchronously() {
            try? releaseAbortedCompatibility(ownedCheckpoints: checkpoints)
        }
    }
    private func releaseAbortedCompatibility(ownedCheckpoints entries: [NoteDraftRecoveryEntry]) throws {
        for (id, (envelope, claim)) in abortedCompatibility {
            if let pre = envelope.preDraft {
                guard entries.contains(where: { item in
                    guard case let .valid(entry, _, _) = item, entry.noteID == pre.noteID,
                          entry.content == pre.content, pre.changedTags == nil || entry.changedTags == pre.changedTags else { return false }
                    return envelope.payloads.allSatisfy { payload in
                        entry.staged.contains { $0.id == payload.id && $0.digest == payload.digest && $0.byteCount == payload.byteCount }
                    }
                }) else { continue }
            } else if !envelope.payloads.isEmpty { continue }
            try journal.releaseOperationSynchronously(claim)
            abortedCompatibility.removeValue(forKey: id)
        }
    }

    func adoptJournal(_ replacement: NoteDraftJournal) throws {
        // A fresh service over the same files must be able to reconcile an
        // aborted intent before offering checkpoints. Changing directories
        // still refuses while the old service owns any operation envelope.
        let sameDirectory = journal.directory.standardizedFileURL.resolvingSymlinksInPath()
            == replacement.directory.standardizedFileURL.resolvingSymlinksInPath()
        guard pending.isEmpty, try sameDirectory || journal.operationEnvelopesSynchronously().isEmpty else {
            throw WorkspaceFoundationError.unknown
        }
        // A legacy recovery file can be unreadable independently of the
        // workspace's writable operation journal. Do not move all subsequent
        // commits into that inaccessible directory.
        try FileManager.default.createDirectory(at: replacement.directory, withIntermediateDirectories: true)
        journal.inventoryChanged = nil
        journal = replacement
        startupReconciled = false; launchFinished = false
        observeCheckpointInventory()
    }

    /// The launch migration has a typed two-field invariant at its caller.
    /// Record its direct bookkeeping save without tokens or admission reads.
    func saveListOrderMigration(_ context: ModelContext, using writer: (ModelContext) throws -> Void) throws {
        let rows = context.changedModelsArray
        let owners = Set(rows.compactMap { Self.owner($0) })
        guard owners.isDisjoint(with: heldOwners),
              let admission = ownership.tryAcquire(Set(owners.map(\.id)), kind: .admission) else {
            throw WorkspaceFoundationError.protectedOwner
        }
        defer { admission.release() }
        try gatedSave(context, before: [], using: writer)
        ledger.evictLaunchMigrationEntries()
        // This fresh migration context now builds its first presentation.
        // Older registered contexts remain below the eviction floor.
        ledger.register(context)
    }

    private func gatedSave(_ context: ModelContext, before: [WorkspaceModelToken], using writer: (ModelContext) throws -> Void) throws {
        try validatePreservationLifetime(context, before: before)
        for row in context.deletedModelsArray {
            guard launchHold == nil || startupReconciled,
                  damagedCollectionHold == nil,
                  Self.owner(row).map({ !checkpointOwners.contains($0) && !heldOwners.contains($0) }) == true else {
                throw WorkspaceFoundationError.protectedOwner
            }
        }
        let records = (context.insertedModelsArray + context.changedModelsArray).compactMap { $0 as? TaskDeletionPreservation }
        var added = Set<UUID>()
        if purgedMembers != nil {
            for record in records where record.purgedAt != nil {
                added.formUnion(try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot).members.map(\.id))
            }
        }
        let removedPreservation = context.deletedModelsArray.contains { $0 is TaskDeletionPreservation }
        try ledger.gatedSave(context, before: before, using: writer) {
            if removedPreservation { tombstonesNeedReload = true }
            else { purgedMembers?.formUnion(added) }
        }
    }

    func freshContext() -> ModelContext {
        validationCounters.freshContexts += 1
        let context = ModelContext(container); context.autosaveEnabled = false
        ledger.register(context)
        return context
    }
    func capture(_ owners: Set<WorkspaceOwner>) throws -> [WorkspaceModelToken] {
        let context = freshContext()
        return try sorted(owners).map { try WorkspaceModelToken.read($0, in: context) }
    }
    func newEnvelope(intent: String, reads: [WorkspaceModelToken], writes: Set<WorkspaceOwner>,
                     inverseGuards: [WorkspaceModelToken]? = nil, scopes suppliedScopes: [WorkspaceScopeToken]? = nil,
                     preDraft: NoteDraftJournalEntry? = nil, afterDocuments: [UUID: Data] = [:],
                     selection: NSRange = NSRange(location: 0, length: 0), draftGeneration: UInt64 = 0,
                     checkpointClaim: NoteRecoveryClaim? = nil, staged: [StagedNoteAttachment] = [],
                     historyEffect: Data? = nil, replayOf: UUID? = nil, compensationOf: UUID? = nil) throws -> WorkspaceOperationEnvelope {
        guard writes.isSubset(of: Set(reads.map(\.owner))) else { throw WorkspaceFoundationError.conflict }
        let context = freshContext()
        let scopes = try suppliedScopes ?? WorkspaceScopeToken.scopes(for: reads).map { try WorkspaceScopeToken.read($0, in: context) }
        let id = UUID(); allocatedIDs.insert(id)
        return WorkspaceOperationEnvelope(id: id, intent: intent, tokens: reads, scopes: scopes, writes: writes,
            inverseGuards: inverseGuards ?? reads, preDraft: preDraft, afterDocuments: afterDocuments,
            selection: [selection.location, selection.length], draftGeneration: draftGeneration,
            checkpointClaim: checkpointClaim, payloads: staged.map(WorkspaceOperationEnvelope.Payload.init),
            historyEffect: historyEffect, replayOf: replayOf, compensationOf: compensationOf)
    }

    /// Async preparation carries values only. The final read/validate/stage/save
    /// below is synchronous on the main actor, with a fresh context and no await.
    func execute(_ envelope: WorkspaceOperationEnvelope,
                 sessionValid: () -> Bool = { true },
                 collection: WorkspaceOwnershipLeases? = nil,
                 stage: (ModelContext) throws -> Void,
                 publication: Publication = Publication()) async -> Outcome {
        guard allocatedIDs.remove(envelope.id) != nil else { return .conflict }
        let affected = Set(envelope.tokens.map(\.owner)).union(envelope.writes)
        guard !Task.isCancelled else { return .notCommitted }
        guard affected.isDisjoint(with: heldOwners), sessionValid() else { return .conflict }
        let admission: WorkspaceOwnershipGate.Lease
        do {
            admission = try await ownership.admit(admissionIDs(envelope), excluding: collection?.lease(for: ownership))
        } catch { return .notCommitted }
        defer { admission.release() }
        let claim: WorkspaceOperationClaim
        do { claim = try await journal.prepareOperation(envelope) }
        catch { return .notCommitted }
        #if ATTIC_OPERATION_CRASH_TESTS
        await afterPreparation?()
        #endif
        guard !Task.isCancelled else { return .notCommitted }
        // Concurrent preparation may have completed another writer; revalidate
        // its complete envelope here, never against warm presentation objects.
        guard affected.isDisjoint(with: heldOwners), sessionValid() else { return .conflict }
        let result = commitPrepared(envelope, claim: claim, collection: collection, stage: stage, publication: publication)
        return result == .publicationPending ? await retryPublication(envelope.id) : result
    }

    private func commitPrepared(_ envelope: WorkspaceOperationEnvelope, claim: WorkspaceOperationClaim, collection: WorkspaceOwnershipLeases? = nil,
                                stage: (ModelContext) throws -> Void, publication: Publication) -> Outcome {
        let affected = Set(envelope.tokens.map(\.owner)).union(envelope.writes)
        let context = freshContext()
        do {
            let validated = try WorkspaceModelToken.read(owners: Set((envelope.tokens + envelope.inverseGuards).map(\.owner)), in: context)
            for token in envelope.tokens + envelope.inverseGuards {
                let current = validated[token.owner]!
                guard current == token else {
                    return .conflict
                }
            }
            let validatedScopes = try WorkspaceScopeToken.read(scopes: Set(envelope.scopes.map(\.scope)), in: context)
            for scope in envelope.scopes {
                let current = validatedScopes[scope.scope]!
                guard current == scope else { return .conflict }
            }
            WorkspaceCrashHook.reach("K3-validation")
            let originalContents = try noteContents(envelope.tokens, in: context)
            try stage(context)
            for (id, content) in envelope.afterDocuments {
                guard envelope.writes.contains(.init(entity: .note, id: id)) else { throw WorkspaceFoundationError.conflict }
                let notes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
                guard !notes.isEmpty, notes.allSatisfy({ $0.content == content }) else { throw WorkspaceFoundationError.conflict }
            }
            try validateTombstones(context, before: envelope.tokens)
            try validateLegacyAdmission(context, before: envelope.tokens)
            guard let admission = ownership.tryAcquire(try admissionIDs(context.insertedModelsArray + context.changedModelsArray, before: envelope.tokens),
                kind: .admission, excluding: collection?.lease(for: ownership)) else { return .conflict }
            defer { admission.release() }
            try validatePreservedOpaqueContent(context, before: envelope.tokens, contents: originalContents)
            try validateWriteSet(context, declared: envelope.writes)
            let resulting = try states(envelope.writes, in: context)
            context.insert(OperationReceipt(id: envelope.id, envelopeDigest: claim.digest,
                affectedIDs: try WorkspaceModelFields.encode(sorted(affected)),
                resultingTokens: try WorkspaceModelFields.encode(resulting),
                historyEffect: envelope.historyEffect, replayOf: envelope.replayOf,
                compensationOf: envelope.compensationOf))
            WorkspaceCrashHook.reach("K4")
            do {
                try gatedSave(context, before: envelope.tokens, using: save)
                #if ATTIC_OPERATION_CRASH_TESTS
                if ProcessInfo.processInfo.environment["ATTIC_SAVE_THEN_THROW"] == "1" {
                    throw WorkspaceFoundationError.unknown
                }
                #endif
            } catch {
                // Discard, do not optimistically roll back a proven save.
                let truth = receiptTruth(envelope.id, digest: claim.digest)
                if truth == .notCommitted { return .notCommitted }
                if truth == .unknown {
                    heldOwners.formUnion(affected)
                    pending[envelope.id] = (envelope, claim, publication)
                    return .unknown
                }
            }
        } catch { return .notCommitted }
        WorkspaceCrashHook.reach("K5")
        heldOwners.formUnion(affected)
        pending[envelope.id] = (envelope, claim, publication)
        return .publicationPending
    }

    /// Ordinary existing-owner writes have no envelope, receipt, fsync or IO.
    /// The staged before/after fingerprints reconcile even a save-then-throw.
    /// Promotion is required whenever any new owner/undurable payload/history
    /// obligation is introduced; the staged write set enforces those limits.
    func plainSave(tokens: [WorkspaceModelToken], scopes: [WorkspaceScopeToken] = [], writes: Set<WorkspaceOwner>,
                   confirmed: (([WorkspaceOwner: WorkspaceModelToken]) -> Void)? = nil,
                   stage: (ModelContext) throws -> Void) -> Outcome {
        let affected = Set(tokens.map(\.owner)).union(writes)
        guard retryHeldWrites(affecting: affected) else { return .unknown }
        let context = freshContext()
        do {
            let validated = try WorkspaceModelToken.read(owners: Set(tokens.map(\.owner)).union(writes), in: context)
            for token in tokens {
                let current = validated[token.owner]!
                guard current == token else {
                    return .conflict
                }
            }
            let validatedScopes = try WorkspaceScopeToken.read(scopes: Set(scopes.map(\.scope)), in: context)
            for scope in scopes {
                guard validatedScopes[scope.scope] == scope else { return .conflict }
            }
            let previous = sorted(writes).map { validated[$0]! }
            let physicalIDs = Dictionary(uniqueKeysWithValues: previous.map { ($0.owner, Set($0.replicas.map(\.physicalID))) })
            let originalContents = try noteContents(previous, in: context)
            try stage(context)
            try validateTombstones(context, before: previous)
            try validateLegacyAdmission(context, before: previous)
            try validatePreservedOpaqueContent(context, before: previous, contents: originalContents)
            guard let admission = ownership.tryAcquire(try admissionIDs(context.insertedModelsArray + context.changedModelsArray, before: previous), kind: .admission) else { return .conflict }
            defer { admission.release() }
            try validateWriteSet(context, declared: writes)
            let stagedModels = try WorkspaceModelToken.stagedModels(owners: writes, before: validated, in: context)
            let stagedTokens = try WorkspaceModelToken.capture(owners: writes, models: stagedModels)
            let next = sorted(writes).map { stagedTokens[$0]! }
            guard try mayUsePlainSave(before: previous, after: next, in: context) else {
                return .conflict
            }
            do {
                try gatedSave(context, before: previous, using: save)
                // Inserted IDs can become permanent during save. Inspect
                // these saved instances before discarding the commit context.
                if let confirmed { confirmed(try WorkspaceModelToken.capture(owners: writes, models: stagedModels)) }
                return .committed
            }
            catch {
                // An idempotent repair can stage the same bytes twice. If
                // its save throws, identical before/after states cannot prove
                // success. Propagate failure so Locate takes its rollback and
                // proof-invalidation path; there is no changed state to hold.
                if previous == next { return .notCommitted }
                // These immutable compact guards already describe both sides.
                // Hash/encode reconciliation proofs only for an ambiguous save,
                // not every successful tick or prepared note commit.
                plainUnknown = (previous, next, affected, physicalIDs)
                heldOwners.formUnion(affected)
                return reconcilePlain()
            }
        } catch { return .notCommitted }
    }

    /// Plain writes save the presented rows themselves. Validation and save
    /// remain in one synchronous main-actor section; uncertainty is never a
    /// reason to grant authority to the presentation cache.
    func commitInPlace(_ context: ModelContext, before: [WorkspaceModelToken],
                       requiredScopes: Set<WorkspaceScope>, scopes: () throws -> [WorkspaceScopeToken], after: [WorkspaceModelToken],
                       capturedOwners: Set<WorkspaceOwner>, using writer: (ModelContext) throws -> Void,
                       confirmed: ([WorkspaceOwner: WorkspaceModelToken]) -> Void) -> Outcome {
        let writes = Set(after.map(\.owner))
        let affected = Set(before.map(\.owner)).union(writes)
        guard retryHeldWrites(affecting: affected) else { return .conflict }
        do {
            if ledger.canValidate(context, owners: affected, scopes: requiredScopes) {
                validationCounters.fastValidations += 1
            } else {
                validationCounters.slowValidations += 1
                let fresh = freshContext()
                let current = try WorkspaceModelToken.read(owners: affected, in: fresh)
                guard before.allSatisfy({ current[$0.owner] == $0 }) else { return .conflict }
                let baselineScopes = try scopes()
                let membership = try WorkspaceScopeToken.read(scopes: requiredScopes, in: fresh)
                guard baselineScopes.allSatisfy({ membership[$0.scope] == $0 }) else { return .conflict }
            }
            // No mutation or suspension occurs during validation. Snapshot
            // SwiftData's write lists once for the complete plain read set.
            let insertedRows = context.insertedModelsArray
            let changedRows = context.changedModelsArray
            let deletedRows = context.deletedModelsArray
            let changes = insertedRows + changedRows
            let inserted = Set(insertedRows.compactMap { Self.owner($0) })
            let afterByOwner = Dictionary(uniqueKeysWithValues: after.map { ($0.owner, $0) })
            try validateWriteSet(context, declared: capturedOwners.union(inserted), rows: changes + deletedRows)
            try validateTombstones(context, before: before, rows: changes)
            try validateLegacyAdmission(context, before: before, rows: changes, after: afterByOwner)
            // Changed supported content was admitted during classification;
            // opaque metadata is preserved without a document read or decode.
            let changedContents = before.filter { token in
                token.owner.entity == .note && token.replicas.contains { old in
                    after.first { $0.owner == token.owner }?.replicas.first { $0.physicalID == old.physicalID }?.fields["content"] != old.fields["content"]
                }
            }
            if !changedContents.isEmpty {
                // The bridge already fingerprinted these staged rows in this
                // unsuspended transaction. Reuse their content guards instead
                // of fingerprinting every large derived text field again.
                let contentGuards = Dictionary(uniqueKeysWithValues: after.filter { $0.owner.entity == .note }
                    .flatMap(\.replicas).compactMap { replica in replica.fields["content"].map { (replica.physicalID, $0) } })
                try validatePreservedOpaqueContent(context, before: before, contents: [:], contentGuards: contentGuards,
                    changedRows: changedRows, insertedIDs: Set(insertedRows.map(\.persistentModelID)))
            }
            guard let admission = ownership.tryAcquire(try admissionIDs(changes, before: before), kind: .admission) else { return .conflict }
            defer { admission.release() }
            let previous = before.filter { writes.contains($0.owner) }
            let physicalIDs = Dictionary(uniqueKeysWithValues: previous.map { ($0.owner, Set($0.replicas.map(\.physicalID))) })
            let stagedTokens = Dictionary(uniqueKeysWithValues: before.map { ($0.owner, $0) })
            let stagedModels = inserted.isEmpty ? [] : try WorkspaceModelToken.stagedModels(owners: writes, before: stagedTokens, in: context)
            do {
                try gatedSave(context, before: previous, using: writer)
                // Existing rows keep their physical identifiers through save.
                // Their already-computed after tokens are the confirmed baseline;
                // only inserts need their permanent identifiers captured now.
                var saved = afterByOwner
                if !inserted.isEmpty {
                    let newFamilies = stagedModels.filter { Self.owner($0).map(inserted.contains) == true }
                    saved.merge(try WorkspaceModelToken.capture(owners: inserted, models: newFamilies)) { _, permanent in permanent }
                }
                confirmed(saved)
                return .committed
            } catch {
                if previous == after { return .notCommitted }
                plainUnknown = (previous, after, affected, physicalIDs)
                heldOwners.formUnion(affected)
                let outcome = reconcilePlain()
                if outcome == .committed {
                    confirmed(try WorkspaceModelToken.read(owners: writes, in: freshContext()))
                }
                return outcome
            }
        } catch { return .notCommitted }
    }

    /// Classification lives at the writer boundary, so a caller cannot label
    /// a lifecycle/association/import transition as an ordinary autosave.
    func mayUsePlainSave(before: [WorkspaceModelToken], after: [WorkspaceModelToken], in context: ModelContext) throws -> Bool {
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.owner, $0) })
        // A metadata-only write carries neither an editor draft nor new bytes.
        // Keep mixed note/task transitions journaled, even if their fields are
        // individually metadata, and reject new physical payload rows here.
        let entities = Set(after.map { $0.owner.entity })
        if entities.contains(.note), entities.contains(.task) { return false }
        let metadata: [WorkspaceOwner.Entity: Set<String>] = [
            .note: ["tagsRaw", "pinnedAt", "deletedAt", "deletedAttachmentIDsRaw", "updatedAt"],
            .version: ["createdAt", "reasonRaw"],
            .proposal: ["needsReview", "agentName"],
            .attachment: ["originalFilename", "deletedAt", "updatedAt", "sortIndex", "inlineOffset", "displayWidth", "displayHeight"],
            .board: ["tagsRaw", "updatedAt"]
        ]
        if after.allSatisfy({ token in
            guard let allowed = metadata[token.owner.entity], let previous = old[token.owner] else { return false }
            let originals = Dictionary(uniqueKeysWithValues: previous.replicas.map { ($0.physicalID, $0.fields) })
            return token.replicas.allSatisfy { replica in
                guard let fields = originals[replica.physicalID] else { return false }
                return Set(replica.fields.keys.filter { fields[$0] != replica.fields[$0] }).isSubset(of: allowed)
            }
        }) { return true }
        // Tasks-only commands, including creation/reorder/soft deletion and
        // their preservation/link metadata, never acquire draft/byte durability.
        // A mixed task + note or any attachment write still promotes below.
        if after.allSatisfy({ [.task, .preservation, .link].contains($0.owner.entity) }) {
            // Adding a new legacy file reference is a new-byte obligation;
            // removals/restores of an already-owned reference remain plain.
            for task in after where task.owner.entity == .task {
                let previous = old[task.owner]?.replicas ?? []
                let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.physicalID, $0.fields) })
                if task.replicas.allSatisfy({ next in
                    guard let fields = previousByID[next.physicalID] else { return false }
                    return fields["imageReferencesData"] == next.fields["imageReferencesData"]
                        && fields["removedAttachmentsData"] == next.fields["removedAttachmentsData"]
                }) { continue }
                let owned = try previous.reduce(into: Set<UUID>()) { $0.formUnion(try taskReferences($1).map(\.id)) }
                guard try task.replicas.allSatisfy({ try Set(taskReferences($0).map(\.id)).isSubset(of: owned) }) else { return false }
            }
            return true
        }
        let roots = after.filter { $0.owner.entity == .note }
        guard roots.count == 1, let root = roots.first,
              let original = old[root.owner], !original.replicas.isEmpty,
              original.replicas.map(\.physicalID) == root.replicas.map(\.physicalID) else { return false }
        guard zip(original.replicas, root.replicas).allSatisfy({ $0.fields["contentFormat"] == $1.fields["contentFormat"] }) else { return false }
        for (a, b) in zip(original.replicas, root.replicas) where a.fields["content"] != b.fields["content"] {
            guard let oldBytes = a.fields["content"], let newBytes = b.fields["content"],
                  let oldKind = admittedNoteKinds[try JSONDecoder().decode(String.self, from: oldBytes)],
                  let newKind = admittedNoteKinds[try JSONDecoder().decode(String.self, from: newBytes)],
                  oldKind == newKind else { return false }
        }
        let allowed: Set<String> = ["content", "contentFingerprint", "contentFormat", "title", "body", "plainText", "imageCount", "fileCount", "firstFileName", "revision", "revisionID", "updatedAt", "tagsRaw", "pinnedAt", "deletedAt", "deletedAttachmentIDsRaw"]
        guard zip(original.replicas, root.replicas).allSatisfy({ a, b in
            Set(b.fields.keys.filter { b.fields[$0] != a.fields[$0] }).isSubset(of: allowed)
        }) else { return false }
        let encodedNoteID = try WorkspaceModelFields.encode(root.owner.id)
        for token in after where token.owner != root.owner {
            guard root.owner.entity == .note,
                  token.replicas.allSatisfy({ $0.fields["noteID"] == encodedNoteID }),
                  let previous = old[token.owner] else { return false }
            switch token.owner.entity {
            case .version:
                // Autosave may preserve displaced states, but expiry is a
                // separate ownership-checked bookkeeping operation.
                guard previous.replicas.isEmpty, !token.replicas.isEmpty else { return false }
                for version in token.replicas {
                    guard original.replicas.contains(where: { note in
                        ["content", "contentFormat", "title", "body"].allSatisfy { version.fields[$0] == note.fields[$0] }
                            && version.fields["sourceRevisionID"] == note.fields["revisionID"]
                    }) else { return false }
                }
            case .attachment:
                guard !previous.replicas.isEmpty, previous.replicas.map(\.physicalID) == token.replicas.map(\.physicalID),
                      zip(previous.replicas, token.replicas).allSatisfy({ a, b in
                          Set(b.fields.keys.filter { b.fields[$0] != a.fields[$0] })
                              .isSubset(of: ["deletedAt", "updatedAt", "sortIndex", "inlineOffset", "displayWidth", "displayHeight"])
                      }) else { return false }
            default: return false
            }
        }
        return true
    }
    func reconcilePlain() -> Outcome {
        guard let (beforeTokens, afterTokens, affected, physicalIDs) = plainUnknown else { return .conflict }
        do {
            let before = try states(tokens: beforeTokens, physical: true, baselineIDs: physicalIDs)
            let after = try states(tokens: afterTokens, physical: true, baselineIDs: physicalIDs)
            try beforeReconciliationRead?()
            let current = try states(Set(before.map(\.owner)), in: freshContext(), physical: true, baselineIDs: physicalIDs)
            let outcome: Outcome
            if current == after { outcome = .committed }
            else if current == before { outcome = .notCommitted }
            else { return .unknown }
            plainUnknown = nil; heldOwners.subtract(affected); return outcome
        } catch { return .unknown }
    }

    func retryPublication(_ id: UUID) async -> Outcome {
        guard let (envelope, claim, publication) = pending[id] else { return .conflict }
        switch receiptTruth(id, digest: claim.digest) {
        case .notCommitted: releasePending(envelope); return .notCommitted
        case .committed: break
        default: return .unknown
        }
        if envelope.checkpointClaim != nil, let note = envelope.preDraft?.noteID, damagedCheckpointNotes.contains(note) {
            return .publicationPending
        }
        do {
            let context = freshContext()
            let receipts = try context.fetch(FetchDescriptor<OperationReceipt>(predicate: #Predicate { $0.id == id }))
            let expected = try JSONDecoder().decode([State].self, from: receipts[0].resultingTokens)
            guard try states(envelope.writes, in: context) == expected else { return .publicationPending }
            var step = publicationStep[id] ?? 0
            while step < publication.steps.count {
                try publication.steps[step](id)
                step += 1; publicationStep[id] = step
                WorkspaceCrashHook.reach("K6-\(step)")
            }
            // Payload-inclusive state proof, rather than a timestamp/revision
            // guess, is durable on every physical receipt before release.
            let proof = try WorkspaceModelFields.encode(expected)
            try bookkeeping(id) { receipt in receipt.publicationComplete = true }
            if let pre = envelope.preDraft, let checkpointClaim = envelope.checkpointClaim {
                guard let content = envelope.afterDocuments[pre.noteID],
                      case let .editable(document) = NoteContentCodec.decode(content) else {
                    return .publicationPending
                }
                let savedContext = freshContext()
                let noteID = pre.noteID
                let notes = try savedContext.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
                guard !notes.isEmpty, notes.allSatisfy({ $0.content == content }) else { return .publicationPending }
                let attachments = try savedContext.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.noteID == noteID }))
                var bytes: [UUID: StagedNoteAttachment] = [:]
                for meta in pre.staged {
                    let family = attachments.filter { $0.id == meta.id }
                    guard !family.isEmpty, family.allSatisfy({ row in
                        row.payload.map { Int64($0.count) == meta.byteCount && (try? journal.digestSynchronously($0)) == meta.digest } == true
                    }), let payload = family[0].payload else { return .publicationPending }
                    bytes[meta.id] = try journal.verifiedAttachmentSynchronously(id: meta.id, filename: meta.filename,
                        contentType: meta.contentTypeIdentifier, byteCount: meta.byteCount,
                        digest: meta.digest, bytes: payload)
                }
                try bookkeeping(id) { $0.handoffProof = proof }
                try await journal.retireDurably(noteID: pre.noteID, claim: checkpointClaim,
                    saved: NoteRecoverySavedState(document: document, tags: notes[0].tags, attachments: bytes))
            }
            if envelope.preDraft == nil || envelope.checkpointClaim == nil {
                try bookkeeping(id) { $0.handoffProof = proof }
            }
            WorkspaceCrashHook.reach("K7")
            try await journal.releaseOperation(claim)
            try bookkeeping(id) { $0.envelopeReleased = true }
            releasePending(envelope)
            return .committed
        } catch { return .publicationPending }
    }

    /// Receipts are reconciled before independent checkpoints can be offered.
    /// Recovery never executes the recorded intent; an absent receipt is a
    /// recoverable pre-draft, an agreeing receipt is publication/handoff work.
    func reconcileStartup() async throws {
        startupReconciled = false
        preOperationRecoveryCopies.removeAll()
        let checkpoints = try await journal.inventoryCheckpoints()
        try registerCheckpointInventory(checkpoints.filter { if case .valid = $0 { return true }; return false })
        damagedCheckpointNotes = try await journal.damagedCheckpointNoteIDs()
        if checkpoints.contains(where: { if case .damaged = $0 { return true }; return false }) {
            // Raw damage can name arbitrary bytes. Its note publication hold
            // is bounded by the filename; byte collection stays conservative
            // until explicit archive/repair proves the complete inventory.
            if damagedCollectionHold == nil {
                damagedCollectionHold = ownership.tryAcquire([ownership.unknownID], kind: .admission)
            }
        } else { damagedCollectionHold?.release(); damagedCollectionHold = nil }
        let envelopes = try await journal.operationEnvelopes()
        for (envelope, claim) in envelopes {
            switch receiptTruth(envelope.id, digest: claim.digest) {
            case .committed:
                if pending[envelope.id] == nil { pending[envelope.id] = (envelope, claim, Publication()) }
                heldOwners.formUnion(Set(envelope.tokens.map(\.owner)).union(envelope.writes))
                let outcome = await retryPublication(envelope.id)
                guard outcome == .committed || outcome == .publicationPending else { throw WorkspaceFoundationError.unknown }
            case .notCommitted:
                if let pre = envelope.preDraft {
                    preOperationRecoveryCopies.append(RecoveryCopy(operationID: envelope.id,
                        draft: pre, claim: claim, payloads: envelope.payloads))
                } // Keep both foreign and operation copies; never rerun intent.
            default: throw WorkspaceFoundationError.unknown
            }
        }
        // The envelope may already have been durably released when death
        // interrupted its database bookkeeping. A durable completed handoff
        // remains authoritative across later revisions and session restart.
        let recorded = Set(envelopes.map { $0.0.id })
        let context = freshContext()
        let receiptRows = try context.fetch(FetchDescriptor<OperationReceipt>())
        for (id, family) in Dictionary(grouping: receiptRows, by: \.id) where !recorded.contains(id) {
            guard try agreeing(family), family.allSatisfy({ $0.publicationComplete && $0.handoffProof != nil }) else {
                throw WorkspaceFoundationError.unknown
            }
            if family.contains(where: { !$0.envelopeReleased }) {
                try bookkeeping(id) { $0.envelopeReleased = true }
            }
        }
        await journal.finishOperationReconciliation(suppressing: pending.values.compactMap { $0.0.checkpointClaim })
        startupReconciled = true
    }

    func prunePublishedReceipts(limit: Int = 64) throws -> Int {
        guard startupReconciled, limit > 0 else { return 0 }
        histories = histories.filter { $0.value.value != nil }
        let referenced = try historyReferences().union(recoveryReferences()).union(pending.keys)
            .union(histories.values.reduce(into: Set<UUID>()) { $0.formUnion($1.value?.referencedOperationIDs ?? []) })
        let operationFiles: [URL]
        do { operationFiles = try FileManager.default.contentsOfDirectory(
            at: journal.directory.appendingPathComponent("operations"), includingPropertiesForKeys: nil) }
        catch {
            let failure = error as NSError
            guard failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) else { throw error }
            operationFiles = []
        }
        let envelopes = Set(operationFiles.compactMap { UUID(uuidString: $0.lastPathComponent) })
        let context = freshContext()
        let families = Dictionary(grouping: try context.fetch(FetchDescriptor<OperationReceipt>()), by: \.id)
        var removed = 0
        var removedIDs = Set<UUID>()
        for id in families.keys.sorted(by: { $0.uuidString < $1.uuidString }) where removed < limit {
            let rows = families[id]!
            guard !referenced.contains(id), !envelopes.contains(id), try agreeing(rows),
                  rows.allSatisfy({ $0.publicationComplete && $0.handoffProof != nil && $0.envelopeReleased }) else { continue }
            guard NotePhysicalFamilyRetention.mayDelete(rows, decision: { _ in .eligible }) else { continue }
            rows.forEach(context.delete); removed += 1; removedIDs.insert(id)
        }
        if removed > 0 {
            do { try gatedSave(context, before: [], using: save) }
            catch {
                let fresh = freshContext()
                let survivors = try fresh.fetch(FetchDescriptor<OperationReceipt>())
                guard survivors.allSatisfy({ !removedIDs.contains($0.id) }) else { throw error }
            }
        }
        return removed
    }

    private func bookkeeping(_ id: UUID, change: (OperationReceipt) -> Void) throws {
        let context = freshContext()
        if isRetryingCompatibility { compatibilityReceiptFetches += 1 }
        let rows = try context.fetch(FetchDescriptor<OperationReceipt>(predicate: #Predicate { $0.id == id }))
        guard try agreeing(rows), !rows.isEmpty else { throw WorkspaceFoundationError.unknown }
        rows.forEach(change)
        let expected = try rows.map { try WorkspaceModelFields.read($0) }
        do { try gatedSave(context, before: [], using: save) }
        catch {
            try beforeReconciliationRead?()
            let fresh = freshContext()
            if isRetryingCompatibility { compatibilityReceiptFetches += 1 }
            let actual = try fresh.fetch(FetchDescriptor<OperationReceipt>(predicate: #Predicate { $0.id == id }))
            guard try actual.map({ try WorkspaceModelFields.read($0) }) == expected else { throw error }
        }
    }
    private func receiptTruth(_ id: UUID, digest: String) -> Outcome {
        do {
            try beforeReconciliationRead?()
            let context = freshContext()
            if isRetryingCompatibility { compatibilityReceiptFetches += 1 }
            let rows = try context.fetch(FetchDescriptor<OperationReceipt>(predicate: #Predicate { $0.id == id }))
            guard !rows.isEmpty else { return .notCommitted }
            guard try agreeing(rows), rows.allSatisfy({ $0.envelopeDigest == digest }) else { return .unknown }
            return .committed
        } catch { return .unknown }
    }
    private func agreeing(_ rows: [OperationReceipt]) throws -> Bool {
        let values = try rows.map { try WorkspaceModelFields.read($0) }
        return Set(try values.map { try WorkspaceModelFields.encode($0) }).count <= 1
    }
    private func sorted(_ owners: Set<WorkspaceOwner>) -> [WorkspaceOwner] {
        owners.sorted { ($0.entity.rawValue, $0.id.uuidString) < ($1.entity.rawValue, $1.id.uuidString) }
    }
    private func states(_ owners: Set<WorkspaceOwner>, in context: ModelContext, physical: Bool = false,
                        baselineIDs: [WorkspaceOwner: Set<PersistentIdentifier>]? = nil) throws -> [State] {
        let tokens = try WorkspaceModelToken.read(owners: owners, in: context)
        return try states(tokens: sorted(owners).map { tokens[$0]! }, physical: physical, baselineIDs: baselineIDs)
    }
    private func states(tokens: [WorkspaceModelToken], physical: Bool = false,
                        baselineIDs: [WorkspaceOwner: Set<PersistentIdentifier>]? = nil) throws -> [State] {
        return try tokens.map { token in
            return State(owner: token.owner, replicas: try token.replicas.map {
                let digest = WorkspaceModelFields.digest(try WorkspaceModelFields.encode($0.fields))
                guard physical else { return digest }
                let physicalKey = baselineIDs?[token.owner]?.contains($0.physicalID) == false
                    ? "new" : WorkspaceModelFields.digest(try WorkspaceModelFields.encode($0.physicalID))
                return physicalKey + ":" + digest
            }.sorted())
        }
    }
    private func validateWriteSet(_ context: ModelContext, declared: Set<WorkspaceOwner>, rows: [any PersistentModel]? = nil) throws {
        for row in rows ?? (context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray) {
            guard let owner = Self.owner(row), declared.contains(owner) else { throw WorkspaceFoundationError.conflict }
        }
    }
    private func noteContents(_ tokens: [WorkspaceModelToken], in context: ModelContext) throws -> [PersistentIdentifier: Data] {
        var contents: [PersistentIdentifier: Data] = [:]
        for token in tokens where token.owner.entity == .note {
            for replica in token.replicas {
                if let field = replica.fields["content"],
                   admittedNoteKinds[try JSONDecoder().decode(String.self, from: field)] != nil { continue }
                guard let row = context.model(for: replica.physicalID) as? NoteItem else { throw WorkspaceFoundationError.conflict }
                if let data = row.content {
                    contents[row.persistentModelID] = data
                    if cachedAdmission(data) == nil, case let .editable(document) = NoteContentCodec.decode(data) {
                        cacheAdmission(data, ids: Set(document.attachmentIDs), hasTaskNote: document.requires.contains("taskNote"))
                    }
                }
            }
        }
        return contents
    }
    private func validatePreservedOpaqueContent(_ context: ModelContext, before: [WorkspaceModelToken],
                                                contents: [PersistentIdentifier: Data],
                                                contentGuards: [PersistentIdentifier: Data] = [:],
                                                changedRows: [any PersistentModel]? = nil, insertedIDs: Set<PersistentIdentifier>? = nil) throws {
        let notes = before.filter { $0.owner.entity == .note }
        let inserted = insertedIDs ?? Set(context.insertedModelsArray.map(\.persistentModelID))
        for row in (changedRows ?? context.changedModelsArray).compactMap({ $0 as? NoteItem }) where !inserted.contains(row.persistentModelID) {
            guard let original = notes.flatMap(\.replicas).first(where: { $0.physicalID == row.persistentModelID }),
                  let formatData = original.fields["contentFormat"],
                  let contentData = original.fields["content"] else { throw WorkspaceFoundationError.unknown }
            let format = try JSONDecoder().decode(Int.self, from: formatData)
            let digest = try JSONDecoder().decode(String.self, from: contentData)
            let content = contents[row.persistentModelID]
            // Metadata preserves opaque bytes without decoding them. Prepared
            // documents have already had capability validation off this path.
            let currentContent = try contentGuards[row.persistentModelID] ?? WorkspaceModelFields.fingerprint(row)["content"]
            if currentContent == contentData, row.contentFormat == format { continue }
            let supported = format == 0 && digest == "nil" || format == NoteDocument.currentFormat && (admittedNoteKinds[digest] != nil || content.map {
                cachedAdmission($0) != nil || NoteContentCodec.decode($0).isEditable
            } == true)
            guard supported else { throw WorkspaceFoundationError.protectedOwner }
        }
    }
    static func owner(_ row: any PersistentModel) -> WorkspaceOwner? {
        switch row {
        case let r as CanvasBoardItem: WorkspaceOwner(entity: .board, id: r.id)
        case let r as CanvasStrokeItem: WorkspaceOwner(entity: .stroke, id: r.id)
        case let r as CanvasImageItem: WorkspaceOwner(entity: .image, id: r.id)
        case let r as CanvasSemanticObjectItem: WorkspaceOwner(entity: .semantic, id: r.id)
        case let r as TaskItem: WorkspaceOwner(entity: .task, id: r.id)
        case let r as NoteItem: WorkspaceOwner(entity: .note, id: r.id)
        case let r as NoteAttachment: WorkspaceOwner(entity: .attachment, id: r.id)
        case let r as NoteVersion: WorkspaceOwner(entity: .version, id: r.id)
        case let r as NotePendingEdit: WorkspaceOwner(entity: .proposal, id: r.id)
        case let r as ItemLink: WorkspaceOwner(entity: .link, id: r.id)
        case let r as TaskNoteAssociation: WorkspaceOwner(entity: .association, id: r.id)
        case let r as TaskDeletionPreservation: WorkspaceOwner(entity: .preservation, id: r.id)
        case let r as OperationReceipt: WorkspaceOwner(entity: .receipt, id: r.id)
        default: nil
        }
    }
}

extension WorkspaceOperationCoordinator {
    /// Permanent deletion is an irreversible boundary for every writer,
    /// including compatibility store wrappers and old replay payloads.
    /// Purged records are permanent UUID tombstones. Preservation snapshots
    /// retain their row/byte dependencies independently of the task lifetime.
    /// Current sweeps have no authorized last-owner retirement protocol.
    private func validatePreservationLifetime(_ context: ModelContext, before: [WorkspaceModelToken]) throws {
        guard !context.deletedModelsArray.contains(where: { $0 is TaskDeletionPreservation }) else {
            throw WorkspaceFoundationError.protectedOwner
        }
        for record in context.changedModelsArray.compactMap({ $0 as? TaskDeletionPreservation }) {
            guard let token = before.first(where: { $0.owner == Self.owner(record) }),
                  let original = token.replicas.first(where: { $0.physicalID == record.persistentModelID }) else {
                throw WorkspaceFoundationError.unknown
            }
            let fields = try WorkspaceModelFields.fingerprint(record)
            guard fields.filter({ $0.key != "purgedAt" }) == original.fields.filter({ $0.key != "purgedAt" }),
                  original.fields["purgedAt"] == (try WorkspaceModelFields.encode(Date?.none)) || fields["purgedAt"] == original.fields["purgedAt"] else {
                throw WorkspaceFoundationError.protectedOwner
            }
        }
    }
    private func validateTombstones(_ context: ModelContext, before: [WorkspaceModelToken], rows: [any PersistentModel]? = nil) throws {
        guard context.container.schema.entities.contains(where: { $0.name == "TaskDeletionPreservation" }) else { return }
        if purgedMembers == nil || tombstonesNeedReload {
            var descriptor = FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.purgedAt != nil })
            // Cache durable tombstones only. A purge staged in this context
            // may still roll back; gatedSave adds its members after success.
            descriptor.includePendingChanges = false
            let records = try context.fetch(descriptor)
            var members = Set<UUID>()
            for record in records {
                members.formUnion(try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot).members.map(\.id))
            }
            // A foreign writer can remove a physical preservation replica,
            // but cannot grant resurrection rights for a UUID already retired
            // in this session. Refresh additions without forgetting tombstones.
            if purgedMembers == nil { purgedMembers = members }
            else { purgedMembers?.formUnion(members) }
            tombstonesNeedReload = false; tombstoneLoads += 1
        }
        guard let removed = purgedMembers, !removed.isEmpty else { return }
        let changes = rows ?? (context.insertedModelsArray + context.changedModelsArray)
        for row in changes {
            if let task = row as? TaskItem, removed.contains(task.id) { throw WorkspaceFoundationError.protectedOwner }
            if let association = row as? TaskNoteAssociation,
               association.detachedAt == nil, removed.contains(association.taskID) { throw WorkspaceFoundationError.protectedOwner }
            if let note = row as? NoteItem {
                if note.taskID.map(removed.contains) == true { throw WorkspaceFoundationError.protectedOwner }
                let original = before.filter { $0.owner == WorkspaceOwner(entity: .note, id: note.id) }
                    .flatMap(\.replicas).first { $0.physicalID == note.persistentModelID }
                let content = try WorkspaceModelFields.fingerprint(note)["content"]
                guard original?.fields["content"] != content else { continue }
                if note.content.flatMap({ NoteContentCodec.decode($0).document })?.requires.contains("taskNote") == true {
                    let detached = try context.fetch(FetchDescriptor<TaskNoteAssociation>()).contains {
                        $0.noteID == note.id && $0.detachedPreservationID != nil
                    }
                    if detached {
                        guard let original, let content = original.fields["content"], let format = original.fields["contentFormat"],
                              content == (try WorkspaceModelFields.encode(WorkspaceModelFields.digest(note.content))),
                              try JSONDecoder().decode(Int.self, from: format) == note.contentFormat else { throw WorkspaceFoundationError.protectedOwner }
                    }
                }
            }
        }
    }

    private func validateLegacyAdmission(_ context: ModelContext, before: [WorkspaceModelToken],
                                         rows: [any PersistentModel]? = nil, after: [WorkspaceOwner: WorkspaceModelToken] = [:]) throws {
        let originals = Dictionary(uniqueKeysWithValues: before.map { ($0.owner, $0) })
        for task in (rows ?? (context.insertedModelsArray + context.changedModelsArray)).compactMap({ $0 as? TaskItem }) {
            let owner = WorkspaceOwner(entity: .task, id: task.id)
            let token = originals[owner]
            let original = token?.replicas.first { $0.physicalID == task.persistentModelID }
            if let original, let next = after[owner]?.replicas.first(where: { $0.physicalID == task.persistentModelID }),
               original.fields["imageReferencesData"] == next.fields["imageReferencesData"],
               original.fields["removedAttachmentsData"] == next.fields["removedAttachmentsData"] { continue }
            if let original {
                let shown = try original.fields["imageReferencesData"].map { try JSONDecoder().decode(Data?.self, from: $0) } ?? nil
                let removed = try original.fields["removedAttachmentsData"].map { try JSONDecoder().decode(Data?.self, from: $0) } ?? nil
                if shown == task.imageReferencesData && removed == task.removedAttachmentsData { continue }
            }
            let next = try taskReferences(shown: task.imageReferencesData, removed: task.removedAttachmentsData)
            let old = try (token?.replicas ?? []).flatMap { try taskReferences($0) }
            guard next.filter({ !old.contains($0) }).allSatisfy({ ref in !legacyFiles.values.contains { $0.wasUnlinked(ref.id) } }) else {
                throw WorkspaceFoundationError.protectedOwner
            }
        }
    }
    private func admissionIDs(_ envelope: WorkspaceOperationEnvelope) -> Set<UUID> {
        Set(envelope.writes.map(\.id)).union(envelope.payloads.map(\.id))
            .union(envelope.afterDocuments.keys)
            .union(envelope.afterDocuments.values.flatMap { documentAdmissionIDs($0) })
    }
    func admissionIDs(_ rows: [any PersistentModel], before: [WorkspaceModelToken] = []) throws -> Set<UUID> {
        var ids = Set(rows.compactMap { Self.owner($0)?.id })
        // Existing attachment lifecycle/anchor changes neither add a byte
        // root nor release the retained physical row. They can cross a file
        // collection lease: providers retain both shown and removed rows.
        // Keep the note owner admission, so an affected-family purge still
        // freezes them. New replicas or changed identity/payload stay admitted.
        let neutral = Set(["updatedAt", "deletedAt", "sortIndex", "inlineOffset", "inlineLength"])
        for (id, attachments) in Dictionary(grouping: rows.compactMap { $0 as? NoteAttachment }, by: \.id) {
            let token = before.first { $0.owner == WorkspaceOwner(entity: .attachment, id: id) }
            let unchanged = try attachments.allSatisfy { row in
                guard let original = token?.replicas.first(where: { $0.physicalID == row.persistentModelID }) else { return false }
                let current = try WorkspaceModelFields.fingerprint(row)
                return current.filter { !neutral.contains($0.key) } == original.fields.filter { !neutral.contains($0.key) }
            }
            if unchanged { ids.remove(id) }
        }
        for row in rows {
            if let task = row as? TaskItem {
                ids.formUnion(try taskReferenceIDs([task]))
            } else if let link = row as? ItemLink {
                ids.formUnion([link.sourceID, link.targetID])
            } else if let association = row as? TaskNoteAssociation {
                ids.formUnion([association.taskID, association.noteID])
            } else if let note = row as? NoteItem {
                if let data = note.content { ids.formUnion(documentAdmissionIDs(data)) }
            } else if let attachment = row as? NoteAttachment { ids.insert(attachment.noteID) }
            else if let version = row as? NoteVersion {
                ids.insert(version.noteID)
                let raw = version.attachmentIDsRaw.split(separator: " ")
                let references = raw.compactMap { UUID(uuidString: String($0)) }
                ids.formUnion(references)
                if references.count != raw.count { ids.insert(ownership.unknownID) }
                let old = before.first { $0.owner == Self.owner(version) }?.replicas.first { $0.physicalID == version.persistentModelID }
                // Existing version metadata/deletion uses its declared scalar
                // attachment roots. Only newly supplied content needs parsing.
                if old?.fields["content"] != (try WorkspaceModelFields.fingerprint(version))["content"],
                   let data = version.content { ids.formUnion(documentAdmissionIDs(data)) }
            } else if let proposal = row as? NotePendingEdit {
                ids.insert(proposal.noteID)
                let old = before.first { $0.owner == Self.owner(proposal) }?.replicas.first { $0.physicalID == proposal.persistentModelID }
                if old?.fields["proposedContent"] != (try WorkspaceModelFields.fingerprint(proposal))["proposedContent"],
                   let data = proposal.proposedContent { ids.formUnion(documentAdmissionIDs(data)) }
            }
        }
        return ids
    }
}


extension WorkspaceOperationCoordinator {
    /// Compatibility bridge for the existing synchronous command APIs. The
    /// shared IO actor receives immutable values, and the exact same prepared
    /// commit primitive performs the unsuspended fresh-context mutation.
    func commitCompatibility(tokens: [WorkspaceModelToken], scopes: [WorkspaceScopeToken], writes: Set<WorkspaceOwner>,
                             intent: String, plain: Bool, writer: @escaping (ModelContext) throws -> Void,
                             staged: [StagedNoteAttachment] = [], afterDocuments: [UUID: Data] = [:],
                             preDraft: NoteDraftJournalEntry? = nil,
                             confirmed: (([WorkspaceOwner: WorkspaceModelToken]) -> Void)? = nil,
                             stage: (ModelContext) throws -> Void) throws {
        let previous = save; save = writer; defer { save = previous }
        if plain {
            guard plainSave(tokens: tokens, scopes: scopes, writes: writes, confirmed: confirmed, stage: stage) == .committed else {
                throw WorkspaceFoundationError.unknown
            }
            return
        }
        let envelope = try newEnvelope(intent: intent, reads: tokens, writes: writes, scopes: scopes,
            preDraft: preDraft, afterDocuments: afterDocuments, staged: staged)
        allocatedIDs.remove(envelope.id)
        let affected = Set(tokens.map(\.owner)).union(writes)
        guard affected.isDisjoint(with: heldOwners) else { throw WorkspaceFoundationError.unknown }
        let claim = try journal.prepareOperationSynchronously(envelope)
        let result = commitPrepared(envelope, claim: claim, stage: stage, publication: Publication())
        if result == .unknown { compatibilityPending.insert(envelope.id); deferCompatibilityRetry(envelope.id) }
        if result == .notCommitted || result == .conflict {
            retainAbortedCompatibility(envelope, claim: claim)
        }
        guard result == .publicationPending else { throw WorkspaceFoundationError.unknown }
        compatibilityPending.insert(envelope.id)
        do { try finalizeCompatibility(envelope, claim: claim) }
        catch {
            deferCompatibilityRetry(envelope.id)
            // Committed model state remains authoritative. Keep this identity
            // so the next real command retries finalization without saving the
            // original mutation again, even after its envelope was released.
        }
    }
    private func finalizeCompatibility(_ envelope: WorkspaceOperationEnvelope, claim: WorkspaceOperationClaim) throws {
        let context = freshContext(), id = envelope.id
        if isRetryingCompatibility { compatibilityReceiptFetches += 1 }
        let receipts = try context.fetch(FetchDescriptor<OperationReceipt>(predicate: #Predicate { $0.id == id }))
        guard try agreeing(receipts), let receipt = receipts.first else { throw WorkspaceFoundationError.unknown }
        let expected = try JSONDecoder().decode([State].self, from: receipt.resultingTokens)
        guard try states(envelope.writes, in: context) == expected else { throw WorkspaceFoundationError.unknown }
        let proof = try WorkspaceModelFields.encode(expected)
        if !receipt.publicationComplete || receipt.handoffProof == nil {
            try bookkeeping(id) { $0.publicationComplete = true; $0.handoffProof = proof }
        }
        if !receipt.envelopeReleased {
            try journal.releaseOperationSynchronously(claim)
            try bookkeeping(id) { $0.envelopeReleased = true }
        }
        releasePending(envelope)
    }

}
