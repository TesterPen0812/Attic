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
    let journal: NoteDraftJournal
    private let writerLease: WorkspaceWriterLease?
    private var allocatedIDs: Set<UUID> = []
    private var pending: [UUID: (WorkspaceOperationEnvelope, WorkspaceOperationClaim, Publication)] = [:]
    private var publicationStep: [UUID: Int] = [:]
    private var heldOwners: Set<WorkspaceOwner> = []
    private var plainUnknown: ([State], [State], Set<WorkspaceOwner>)?
    private(set) var startupReconciled = false
    var historyReferences: () throws -> Set<UUID> = { [] }
    var recoveryReferences: () throws -> Set<UUID> = { [] }
    var save: (ModelContext) throws -> Void = { try $0.save() }
    /// Read-error seam deliberately affects reconciliation, never converts it
    /// to receipt absence. Shipping callers leave this nil.
    var beforeReconciliationRead: (() throws -> Void)?

    init(container: ModelContainer, journal: NoteDraftJournal) throws {
        self.container = container; self.journal = journal
        let disk = container.configurations.first { !$0.isStoredInMemoryOnly }
        if let disk {
            try FileManager.default.createDirectory(at: disk.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writerLease = try WorkspaceWriterLease(storeURL: disk.url)
        } else { writerLease = nil }
    }

    func freshContext() -> ModelContext {
        let context = ModelContext(container); context.autosaveEnabled = false; return context
    }
    func capture(_ owners: Set<WorkspaceOwner>) throws -> [WorkspaceModelToken] {
        let context = freshContext()
        return try sorted(owners).map { try WorkspaceModelToken.read($0, in: context) }
    }
    func newEnvelope(intent: String, reads: [WorkspaceModelToken], writes: Set<WorkspaceOwner>,
                     inverseGuards: [WorkspaceModelToken]? = nil,
                     preDraft: NoteDraftJournalEntry? = nil, afterDocuments: [UUID: Data] = [:],
                     selection: NSRange = NSRange(location: 0, length: 0), draftGeneration: UInt64 = 0,
                     checkpointClaim: NoteRecoveryClaim? = nil, staged: [StagedNoteAttachment] = [],
                     historyEffect: Data? = nil, replayOf: UUID? = nil, compensationOf: UUID? = nil) -> WorkspaceOperationEnvelope {
        let id = UUID(); allocatedIDs.insert(id)
        return WorkspaceOperationEnvelope(id: id, intent: intent, tokens: reads, writes: writes,
            inverseGuards: inverseGuards ?? reads, preDraft: preDraft, afterDocuments: afterDocuments,
            selection: [selection.location, selection.length], draftGeneration: draftGeneration,
            checkpointClaim: checkpointClaim, payloads: staged.map(WorkspaceOperationEnvelope.Payload.init),
            historyEffect: historyEffect, replayOf: replayOf, compensationOf: compensationOf)
    }

    /// Async preparation carries values only. The final read/validate/stage/save
    /// below is synchronous on the main actor, with a fresh context and no await.
    func execute(_ envelope: WorkspaceOperationEnvelope,
                 sessionValid: () -> Bool = { true },
                 stage: (ModelContext) throws -> Void,
                 publication: Publication = Publication()) async -> Outcome {
        guard allocatedIDs.remove(envelope.id) != nil else { return .conflict }
        let affected = Set(envelope.tokens.map(\.owner)).union(envelope.writes)
        guard affected.isDisjoint(with: heldOwners), sessionValid() else { return .conflict }
        let claim: WorkspaceOperationClaim
        do { claim = try await journal.prepareOperation(envelope) }
        catch { return .notCommitted }
        // Concurrent preparation may have completed another writer; revalidate
        // its complete envelope here, never against warm presentation objects.
        guard affected.isDisjoint(with: heldOwners), sessionValid() else { return .conflict }
        let context = freshContext()
        do {
            for token in envelope.tokens + envelope.inverseGuards {
                guard try WorkspaceModelToken.read(token.owner, in: context) == token else {
                    return .conflict
                }
            }
            WorkspaceCrashHook.reach("K3-validation")
            try stage(context)
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
        return await retryPublication(envelope.id)
    }

    /// Ordinary existing-owner writes have no envelope, receipt, fsync or IO.
    /// The staged before/after fingerprints reconcile even a save-then-throw.
    /// Promotion is required whenever any new owner/undurable payload/history
    /// obligation is introduced; the staged write set enforces those limits.
    func plainSave(tokens: [WorkspaceModelToken], writes: Set<WorkspaceOwner>,
                   stage: (ModelContext) throws -> Void) -> Outcome {
        let affected = Set(tokens.map(\.owner)).union(writes)
        guard affected.isDisjoint(with: heldOwners), plainUnknown == nil else { return .unknown }
        let context = freshContext()
        do {
            for token in tokens {
                guard try WorkspaceModelToken.read(token.owner, in: context) == token else { return .conflict }
            }
            let before = try states(writes, in: context)
            try stage(context)
            try validateWriteSet(context, declared: writes)
            guard context.insertedModelsArray.isEmpty, context.deletedModelsArray.isEmpty else {
                return .conflict
            }
            let after = try states(writes, in: context)
            do { try save(context); return .committed }
            catch {
                plainUnknown = (before, after, affected)
                heldOwners.formUnion(affected)
                return reconcilePlain()
            }
        } catch { return .notCommitted }
    }
    func reconcilePlain() -> Outcome {
        guard let (before, after, affected) = plainUnknown else { return .conflict }
        do {
            try beforeReconciliationRead?()
            let current = try states(Set(before.map(\.owner)), in: freshContext())
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
                        row.payload.map { Int64($0.count) == meta.byteCount && NotePayloadDigest.sha256($0) == meta.digest } == true
                    }), let payload = family[0].payload else { return .publicationPending }
                    bytes[meta.id] = StagedNoteAttachment(id: meta.id, filename: meta.filename,
                        contentTypeIdentifier: meta.contentTypeIdentifier, byteCount: meta.byteCount,
                        digest: meta.digest, data: payload)
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
        let envelopes = try await journal.operationEnvelopes()
        for (envelope, claim) in envelopes {
            switch receiptTruth(envelope.id, digest: claim.digest) {
            case .committed:
                pending[envelope.id] = (envelope, claim, Publication())
                heldOwners.formUnion(Set(envelope.tokens.map(\.owner)).union(envelope.writes))
                guard await retryPublication(envelope.id) == .committed else { throw WorkspaceFoundationError.unknown }
            case .notCommitted: break // Keep the pre-copy, never rerun intent.
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
        startupReconciled = true
    }

    func prunePublishedReceipts(limit: Int = 64) throws -> Int {
        guard startupReconciled, limit > 0 else { return 0 }
        let referenced = try historyReferences().union(recoveryReferences()).union(pending.keys)
        let envelopes = Set(try FileManager.default.contentsOfDirectory(
            at: journal.directory.appendingPathComponent("operations"), includingPropertiesForKeys: nil
        ).compactMap { UUID(uuidString: $0.lastPathComponent) })
        let context = freshContext()
        let families = Dictionary(grouping: try context.fetch(FetchDescriptor<OperationReceipt>()), by: \.id)
        var removed = 0
        for id in families.keys.sorted(by: { $0.uuidString < $1.uuidString }) where removed < limit {
            let rows = families[id]!
            guard !referenced.contains(id), !envelopes.contains(id), try agreeing(rows),
                  rows.allSatisfy({ $0.publicationComplete && $0.handoffProof != nil && $0.envelopeReleased }) else { continue }
            guard NotePhysicalFamilyRetention.mayDelete(rows, decision: { _ in .eligible }) else { continue }
            rows.forEach(context.delete); removed += 1
        }
        if removed > 0 {
            do { try save(context) }
            catch {
                let fresh = freshContext()
                let survivors = try fresh.fetch(FetchDescriptor<OperationReceipt>())
                let deleted = Set(context.deletedModelsArray.compactMap { ($0 as? OperationReceipt)?.id })
                guard survivors.allSatisfy({ !deleted.contains($0.id) }) else { throw error }
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
    private func states(_ owners: Set<WorkspaceOwner>, in context: ModelContext) throws -> [State] {
        try sorted(owners).map { owner in
            let token = try WorkspaceModelToken.read(owner, in: context)
            return State(owner: owner, replicas: try token.replicas.map {
                NotePayloadDigest.sha256(try WorkspaceModelFields.encode($0.fields))
            }.sorted())
        }
    }
    private func validateWriteSet(_ context: ModelContext, declared: Set<WorkspaceOwner>) throws {
        for row in context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray {
            guard let owner = Self.owner(row), declared.contains(owner) else { throw WorkspaceFoundationError.conflict }
        }
    }
    static func owner(_ row: any PersistentModel) -> WorkspaceOwner? {
        switch row {
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
