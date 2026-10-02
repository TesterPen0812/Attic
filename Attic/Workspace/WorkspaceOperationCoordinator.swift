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
        cacheAdmission(document.content, ids: ids, hasTaskNote: document.hasTaskNote)
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
    private func cacheAdmission(_ content: Data, ids: Set<UUID>, hasTaskNote: Bool) {
        if cachedAdmission(content) == ids { return }
        let digest = WorkspaceModelFields.digest(content)
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
    private var plainUnknown: ([WorkspaceModelToken], [WorkspaceModelToken], Set<WorkspaceOwner>, [WorkspaceOwner: Set<PersistentIdentifier>])?
    private(set) var startupReconciled = false
    struct RecoveryCopy {
        let operationID: UUID
        let draft: NoteDraftJournalEntry
        let claim: WorkspaceOperationClaim
        let payloads: [WorkspaceOperationEnvelope.Payload]
    }
    private(set) var preOperationRecoveryCopies: [RecoveryCopy] = []
    private var historyOwners: [UUID: () -> Set<UUID>] = [:]
    private var historyBytes: [UUID: () -> Set<UUID>] = [:]
    func registerHistory(_ route: UndoRoute) {
        historyOwners[route.ownershipID] = { [weak route] in route?.referencedOperationIDs ?? [] }
        historyBytes[route.ownershipID] = { [weak route] in route?.referencedAttachmentIDs ?? [] }
    }
    var retainedHistoryBytes: Set<UUID> { historyBytes.values.reduce(into: []) { $0.formUnion($1()) } }
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
        let disk = container.configurations.first { !$0.isStoredInMemoryOnly }
        ownership = disk.map { WorkspaceOwnershipGate.shared(for: "store:" + $0.url.resolvingSymlinksInPath().path) } ?? WorkspaceOwnershipGate()
        if let disk {
            try FileManager.default.createDirectory(at: disk.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writerLease = try WorkspaceWriterLease.attached(to: container) ?? WorkspaceWriterLease.acquire(storeURL: disk.url)
        } else { writerLease = nil }
        WorkspaceLegacyBridge.register(self)
    }

    func adoptJournal(_ replacement: NoteDraftJournal) throws {
        guard pending.isEmpty, try journal.operationEnvelopesSynchronously().isEmpty else {
            throw WorkspaceFoundationError.unknown
        }
        // A legacy recovery file can be unreadable independently of the
        // workspace's writable operation journal. Do not move all subsequent
        // commits into that inaccessible directory.
        try FileManager.default.createDirectory(at: replacement.directory, withIntermediateDirectories: true)
        journal = replacement
    }

    func freshContext() -> ModelContext {
        let context = ModelContext(container); context.autosaveEnabled = false; return context
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
                try save(context)
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
                   stage: (ModelContext) throws -> Void) -> Outcome {
        let affected = Set(tokens.map(\.owner)).union(writes)
        guard affected.isDisjoint(with: heldOwners), plainUnknown == nil else { return .unknown }
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
            let stagedTokens = try WorkspaceModelToken.read(owners: writes, in: context)
            let next = sorted(writes).map { stagedTokens[$0]! }
            guard try mayUsePlainSave(before: previous, after: next, in: context) else {
                return .conflict
            }
            do { try save(context); return .committed }
            catch {
                // These immutable compact guards already describe both sides.
                // Hash/encode reconciliation proofs only for an ambiguous save,
                // not every successful tick or prepared note commit.
                plainUnknown = (previous, next, affected, physicalIDs)
                heldOwners.formUnion(affected)
                return reconcilePlain()
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
            .attachment: ["deletedAt", "updatedAt", "sortIndex", "inlineOffset", "displayWidth", "displayHeight"],
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
            func references(_ replica: WorkspaceModelToken.Replica) throws -> Set<UUID> {
                var ids = Set<UUID>()
                if let bytes = replica.fields["imageReferencesData"], let data = try JSONDecoder().decode(Data?.self, from: bytes) {
                    ids.formUnion(try JSONDecoder().decode([TaskImageReference].self, from: data).map(\.id))
                }
                if let bytes = replica.fields["removedAttachmentsData"], let data = try JSONDecoder().decode(Data?.self, from: bytes) {
                    ids.formUnion(try JSONDecoder().decode([RemovedTaskAttachment].self, from: data).map { $0.reference.id })
                }
                return ids
            }
            for task in after where task.owner.entity == .task {
                let owned = try (old[task.owner]?.replicas ?? []).reduce(into: Set<UUID>()) { $0.formUnion(try references($1)) }
                guard try task.replicas.allSatisfy({ try references($0).isSubset(of: owned) }) else { return false }
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
        let allowed: Set<String> = ["content", "contentFormat", "title", "body", "plainText", "imageCount", "fileCount", "firstFileName", "revision", "revisionID", "updatedAt", "tagsRaw", "pinnedAt", "deletedAt", "deletedAttachmentIDsRaw"]
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
        guard receiptTruth(id, digest: claim.digest) == .committed else { return .unknown }
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
            pending[id] = nil; publicationStep[id] = nil
            heldOwners.subtract(Set(envelope.tokens.map(\.owner)).union(envelope.writes))
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
        guard !checkpoints.contains(where: { if case .damaged = $0 { return true }; return false }) else {
            throw WorkspaceFoundationError.unknown
        }
        let envelopes = try await journal.operationEnvelopes()
        for (envelope, claim) in envelopes {
            switch receiptTruth(envelope.id, digest: claim.digest) {
            case .committed:
                pending[envelope.id] = (envelope, claim, Publication())
                heldOwners.formUnion(Set(envelope.tokens.map(\.owner)).union(envelope.writes))
                guard await retryPublication(envelope.id) == .committed else { throw WorkspaceFoundationError.unknown }
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
        let rows = try context.fetch(FetchDescriptor<OperationReceipt>())
        for (id, family) in Dictionary(grouping: rows, by: \.id) where !recorded.contains(id) {
            guard try agreeing(family), family.allSatisfy({ $0.publicationComplete && $0.handoffProof != nil }) else {
                throw WorkspaceFoundationError.unknown
            }
            if family.contains(where: { !$0.envelopeReleased }) {
                try bookkeeping(id) { $0.envelopeReleased = true }
            }
        }
        await journal.finishOperationReconciliation()
        startupReconciled = true
    }

    func prunePublishedReceipts(limit: Int = 64) throws -> Int {
        guard startupReconciled, limit > 0 else { return 0 }
        let referenced = try historyReferences().union(recoveryReferences()).union(pending.keys)
            .union(historyOwners.values.reduce(into: Set<UUID>()) { $0.formUnion($1()) })
        let envelopes = Set(try FileManager.default.contentsOfDirectory(
            at: journal.directory.appendingPathComponent("operations"), includingPropertiesForKeys: nil
        ).compactMap { UUID(uuidString: $0.lastPathComponent) })
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
            do { try save(context) }
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
        let rows = try context.fetch(FetchDescriptor<OperationReceipt>(predicate: #Predicate { $0.id == id }))
        guard try agreeing(rows), !rows.isEmpty else { throw WorkspaceFoundationError.unknown }
        rows.forEach(change)
        let expected = try rows.map { try WorkspaceModelFields.read($0) }
        do { try save(context) }
        catch {
            try beforeReconciliationRead?()
            let fresh = freshContext()
            let actual = try fresh.fetch(FetchDescriptor<OperationReceipt>(predicate: #Predicate { $0.id == id }))
            guard try actual.map({ try WorkspaceModelFields.read($0) }) == expected else { throw error }
        }
    }
    private func receiptTruth(_ id: UUID, digest: String) -> Outcome {
        do {
            try beforeReconciliationRead?()
            let context = freshContext()
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
    private func validateWriteSet(_ context: ModelContext, declared: Set<WorkspaceOwner>) throws {
        for row in context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray {
            guard let owner = Self.owner(row), declared.contains(owner) else { throw WorkspaceFoundationError.conflict }
        }
    }
    private func noteContents(_ tokens: [WorkspaceModelToken], in context: ModelContext) throws -> [PersistentIdentifier: Data] {
        var contents: [PersistentIdentifier: Data] = [:]
        for token in tokens where token.owner.entity == .note {
            let id = token.owner.id
            for row in try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })) {
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
                                                contents: [PersistentIdentifier: Data]) throws {
        let notes = before.filter { $0.owner.entity == .note }
        let inserted = Set(context.insertedModelsArray.map(\.persistentModelID))
        for row in context.changedModelsArray.compactMap({ $0 as? NoteItem }) where !inserted.contains(row.persistentModelID) {
            guard let original = notes.flatMap(\.replicas).first(where: { $0.physicalID == row.persistentModelID }),
                  let formatData = original.fields["contentFormat"] else { throw WorkspaceFoundationError.unknown }
            let format = try JSONDecoder().decode(Int.self, from: formatData)
            let content = contents[row.persistentModelID]
            // Metadata preserves opaque bytes without decoding them. Prepared
            // documents have already had capability validation off this path.
            if row.content == content && row.contentFormat == format { continue }
            let supported = format == 0 && content == nil || format == NoteDocument.currentFormat && content.map {
                cachedAdmission($0) != nil || NoteContentCodec.decode($0).isEditable
            } == true
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
    private func validateTombstones(_ context: ModelContext, before: [WorkspaceModelToken]) throws {
        guard context.container.schema.entities.contains(where: { $0.name == "TaskDeletionPreservation" }) else { return }
        let records = try context.fetch(FetchDescriptor<TaskDeletionPreservation>()).filter { $0.purgedAt != nil }
        guard !records.isEmpty else { return }
        var removed = Set<UUID>()
        for record in records {
            let snapshot = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot)
            removed.formUnion(snapshot.members.map(\.id))
        }
        let changes = context.insertedModelsArray + context.changedModelsArray
        for row in changes {
            if let task = row as? TaskItem, removed.contains(task.id) { throw WorkspaceFoundationError.protectedOwner }
            if let association = row as? TaskNoteAssociation,
               association.detachedAt == nil, removed.contains(association.taskID) { throw WorkspaceFoundationError.protectedOwner }
            if let note = row as? NoteItem {
                if note.taskID.map(removed.contains) == true { throw WorkspaceFoundationError.protectedOwner }
                if note.content.flatMap({ NoteContentCodec.decode($0).document })?.requires.contains("taskNote") == true {
                    let detached = try context.fetch(FetchDescriptor<TaskNoteAssociation>()).contains {
                        $0.noteID == note.id && $0.detachedPreservationID != nil
                    }
                    if detached {
                        let original = before.filter { $0.owner == WorkspaceOwner(entity: .note, id: note.id) }
                            .flatMap(\.replicas).first { $0.physicalID == note.persistentModelID }
                        guard let original, let content = original.fields["content"], let format = original.fields["contentFormat"],
                              content == (try WorkspaceModelFields.encode(WorkspaceModelFields.digest(note.content))),
                              try JSONDecoder().decode(Int.self, from: format) == note.contentFormat else { throw WorkspaceFoundationError.protectedOwner }
                    }
                }
            }
        }
    }

    private func validateLegacyAdmission(_ context: ModelContext, before: [WorkspaceModelToken]) throws {
        for task in (context.insertedModelsArray + context.changedModelsArray).compactMap({ $0 as? TaskItem }) {
            let next = try WorkspacePurge.legacyReferences(task)
            let old = try before.filter { $0.owner == WorkspaceOwner(entity: .task, id: task.id) }.flatMap { token in
                try token.replicas.flatMap { replica -> [TaskImageReference] in
                    var refs: [TaskImageReference] = []
                    if let field = replica.fields["imageReferencesData"], let data = try JSONDecoder().decode(Data?.self, from: field) {
                        refs += try JSONDecoder().decode([TaskImageReference].self, from: data)
                    }
                    if let field = replica.fields["removedAttachmentsData"], let data = try JSONDecoder().decode(Data?.self, from: field) {
                        refs += try JSONDecoder().decode([RemovedTaskAttachment].self, from: data).map(\.reference)
                    }
                    return refs
                }
            }
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
                if let data = task.imageReferencesData { ids.formUnion(try JSONDecoder().decode([TaskImageReference].self, from: data).map(\.id)) }
                if let data = task.removedAttachmentsData { ids.formUnion(try JSONDecoder().decode([RemovedTaskAttachment].self, from: data).map { $0.reference.id }) }
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
                             stage: (ModelContext) throws -> Void) throws {
        let previous = save; save = writer; defer { save = previous }
        if plain {
            guard plainSave(tokens: tokens, scopes: scopes, writes: writes, stage: stage) == .committed else {
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
        guard result == .publicationPending else { throw WorkspaceFoundationError.unknown }
        do {
            let context = freshContext()
            let id = envelope.id
            let receipts = try context.fetch(FetchDescriptor<OperationReceipt>(predicate: #Predicate { $0.id == id }))
            guard try agreeing(receipts), let receipt = receipts.first else { throw WorkspaceFoundationError.unknown }
            let expected = try JSONDecoder().decode([State].self, from: receipt.resultingTokens)
            guard try states(writes, in: context) == expected else { throw WorkspaceFoundationError.unknown }
            let proof = try WorkspaceModelFields.encode(expected)
            try bookkeeping(id) { $0.publicationComplete = true; $0.handoffProof = proof }
            try journal.releaseOperationSynchronously(claim)
            try bookkeeping(id) { $0.envelopeReleased = true }
            pending[id] = nil; heldOwners.subtract(affected)
        } catch {
            // The mutation committed. Retain its publication identity for
            // reconciliation; a cleanup failure is never "failed, unchanged".
        }
    }
}
