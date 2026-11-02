#if ATTIC_CLOUD_SYNC && !ATTIC_LOCAL_ONLY
import CryptoKit
import Foundation

// Stage 5a's durable, account-scoped wire model. Nothing here opens a CloudKit
// database or a SwiftData store; Stage 5b must connect the writer transactions.
struct PhoneFakeSyncScope: Codable, Hashable {
    enum Environment: String, Codable { case development, production }
    let environment: Environment
    let account: String

    init(environment: Environment, account: String) {
        self.environment = environment
        self.account = account
    }
}

struct PhoneFakeSyncKey: Codable, Hashable {
    enum Kind: String, Codable { case task, taskNoteLink, noteHead, noteRevision, assetManifest, assetBytes, taskPlacement }
    let kind: Kind
    let id: UUID
    var revisionID: UUID? = nil

    var recordName: String {
        var components = [kind.rawValue, id.uuidString]
        if let revisionID { components.append(revisionID.uuidString) }
        return components.joined(separator: "/")
    }
}

enum PhoneFakeSyncFailure: Error, Equatable {
    case offline, interruptedAsset, interruptedCommit, accountUnavailable, missingAncestor
    case accountMismatch, divergentReplicas, invalidPayload, immutableMismatch, incompleteFetch
}

struct PhoneFakeSyncTask: Codable, Equatable {
    enum Status: String, Codable { case now, later, done }
    let id: UUID
    let operationID: UUID
    let parents: [UUID]
    var title: String
    var status: Status
    var parentID: UUID?
    var completedAt: Date?
    var doneLoggedAt: Date?

    init(id: UUID, operationID: UUID = UUID(), parents: [UUID] = [], title: String,
         status: Status = .now, parentID: UUID? = nil, completedAt: Date? = nil,
         doneLoggedAt: Date? = nil) {
        self.id = id; self.operationID = operationID; self.parents = parents
        self.title = title; self.status = status; self.parentID = parentID
        self.completedAt = completedAt; self.doneLoggedAt = doneLoggedAt
    }
}

struct PhoneFakeSyncAsset: Codable, Equatable {
    let id: UUID
    let byteCount: Int
    let digest: String

    init(id: UUID, bytes: Data) {
        self.id = id; byteCount = bytes.count; digest = PhoneFakeSyncDigest.of(bytes)
    }
}

enum PhoneFakeSyncDigest {
    static func of(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct PhoneFakeSyncRevision: Codable, Equatable {
    let noteID: UUID
    let id: UUID
    let parentIDs: [UUID]
    let contentFormat: Int
    let bytes: Data
    let digest: String
    let attachmentIDs: [UUID]

    init(noteID: UUID, id: UUID, parentIDs: [UUID], contentFormat: Int,
         bytes: Data, attachmentIDs: [UUID]) {
        self.noteID = noteID; self.id = id; self.parentIDs = parentIDs
        self.contentFormat = contentFormat; self.bytes = bytes
        digest = PhoneFakeSyncDigest.of(bytes); self.attachmentIDs = attachmentIDs
    }
}

struct PhoneFakeSyncDeletion: Codable, Equatable {
    let id: UUID
    let target: PhoneFakeSyncKey
}

/// Two devices can create a different note for the same task while offline.
/// Both identities survive until an explicit ownership review resolves them.
struct PhoneFakeSyncTaskNoteLink: Codable, Equatable {
    let taskID: UUID
    let noteID: UUID
    let operationID: UUID
}

enum PhoneFakeSyncBody: Codable, Equatable {
    case task(PhoneFakeSyncTask)
    case taskNoteLink(PhoneFakeSyncTaskNoteLink)
    case revision(PhoneFakeSyncRevision)
    case head(noteID: UUID, revisionID: UUID)
    case assetManifest(PhoneFakeSyncAsset)
    case assetBytes(id: UUID, data: Data)
    case tombstone(PhoneFakeSyncDeletion)
    case restore(target: PhoneFakeSyncKey, tombstoneID: UUID)
}

struct PhoneFakeSyncChange: Codable, Equatable {
    let id: UUID
    let key: PhoneFakeSyncKey
    let generation: Int64
    let after: [UUID]
    let body: PhoneFakeSyncBody
}

struct PhoneFakeSyncReceipt: Equatable {
    let scope: PhoneFakeSyncScope
    let id: UUID
    let recordName: String
    let generation: Int64
}

struct PhoneFakeSyncEnvelope: Codable, Equatable {
    let sequence: Int64
    let change: PhoneFakeSyncChange
}

struct PhoneFakeSyncFetch {
    let scope: PhoneFakeSyncScope
    let changes: [PhoneFakeSyncEnvelope]
    let upperBound: Int64
    let finished: Bool
}

/// The delegate boundary CKSyncEngine will drive in Stage 5b. Tests use a
/// deterministic implementation, so event ordering is under their control.
protocol PhoneFakeSyncTransport: AnyObject {
    func send(_ change: PhoneFakeSyncChange, scope: PhoneFakeSyncScope) throws -> PhoneFakeSyncReceipt?
    func fetch(scope: PhoneFakeSyncScope, after: Int64) throws -> PhoneFakeSyncFetch
}

struct PhoneFakeSyncStored: Codable {
    var outgoing: [PhoneFakeSyncChange] = []
    var acknowledged: Set<UUID> = []
    var processed: [UUID: PhoneFakeSyncChange] = [:]
    var buffered: [Int64: PhoneFakeSyncEnvelope] = [:]
    var checkpoint: Int64 = 0
    var nextGeneration: Int64 = 0
    var engineState: Data? = nil
    var recordSystemFields: [String: Data] = [:]

    var tasks: [UUID: [UUID: PhoneFakeSyncTask]] = [:]
    var taskHeads: [UUID: Set<UUID>] = [:]
    var taskNoteLinks: [UUID: [UUID: PhoneFakeSyncTaskNoteLink]] = [:]
    var taskNoteCandidates: [UUID: Set<UUID>] = [:]
    // Physical replicas are deliberately arrays, never unique UUID rows.
    var physicalTasks: [UUID: [PhoneFakeSyncTask]] = [:]
    var revisions: [UUID: PhoneFakeSyncRevision] = [:]
    var noteHeads: [UUID: Set<UUID>] = [:]
    var waitingHeads: [UUID: Set<UUID>] = [:]
    var manifests: [UUID: PhoneFakeSyncAsset] = [:]
    var assets: [UUID: Data] = [:]
    var tombstones: [String: [UUID: PhoneFakeSyncDeletion]] = [:]
    var restoredTombstones: Set<UUID> = []

    func deleted(_ key: PhoneFakeSyncKey) -> Bool {
        (tombstones[key.recordName] ?? [:]).keys.contains { !restoredTombstones.contains($0) }
    }

    func physicalDivergence(_ id: UUID) -> Bool {
        guard let copies = physicalTasks[id], let first = copies.first else { return false }
        return copies.dropFirst().contains { $0 != first }
    }

    func taskHead(_ id: UUID) -> PhoneFakeSyncTask? {
        guard !deleted(.init(kind: .task, id: id)),
              taskHeads[id]?.count == 1, !physicalDivergence(id),
              let head = taskHeads[id]?.first else { return nil }
        return tasks[id]?[head]
    }

    func noteBranches(_ id: UUID) -> [PhoneFakeSyncRevision] {
        guard !deleted(.init(kind: .noteHead, id: id)) else { return [] }
        return (noteHeads[id] ?? []).compactMap { revisions[$0] }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func assetIsAvailable(_ id: UUID) -> Bool {
        guard let meta = manifests[id], let bytes = assets[id] else { return false }
        return meta.byteCount == bytes.count && meta.digest == PhoneFakeSyncDigest.of(bytes)
    }

    // Determine ancestry by identities, never by device clocks. Missing parents
    // do not justify discarding either branch.
    func taskDescends(_ child: UUID, from parent: UUID, id: UUID,
                      seen: inout Set<UUID>) -> Bool {
        guard seen.insert(child).inserted, let record = tasks[id]?[child] else { return false }
        if record.parents.contains(parent) { return true }
        return record.parents.contains { taskDescends($0, from: parent, id: id, seen: &seen) }
    }

    func noteDescends(_ child: UUID, from parent: UUID, seen: inout Set<UUID>) -> Bool {
        guard seen.insert(child).inserted, let record = revisions[child] else { return false }
        if record.parentIDs.contains(parent) { return true }
        return record.parentIDs.contains { noteDescends($0, from: parent, seen: &seen) }
    }

    mutating func apply(_ change: PhoneFakeSyncChange) throws {
        switch change.body {
        case let .task(task):
            guard change.key == .init(kind: .task, id: task.id), change.id == task.operationID else {
                throw PhoneFakeSyncFailure.invalidPayload
            }
            if let old = tasks[task.id]?[task.operationID], old != task {
                throw PhoneFakeSyncFailure.immutableMismatch
            }
            tasks[task.id, default: [:]][task.operationID] = task
            var heads = taskHeads[task.id] ?? []
            heads.insert(task.operationID)
            for candidate in Array(heads) where candidate != task.operationID {
                var seen: Set<UUID> = []
                if taskDescends(task.operationID, from: candidate, id: task.id, seen: &seen) {
                    heads.remove(candidate)
                } else {
                    seen.removeAll()
                    if taskDescends(candidate, from: task.operationID, id: task.id, seen: &seen) {
                        heads.remove(task.operationID)
                    }
                }
            }
            taskHeads[task.id] = heads
            if heads.count == 1, let winner = heads.first.flatMap({ tasks[task.id]?[$0] }),
               !physicalDivergence(task.id) {
                let count = max(1, physicalTasks[task.id]?.count ?? 0)
                physicalTasks[task.id] = Array(repeating: winner, count: count)
            }
        case let .taskNoteLink(link):
            guard change.key == .init(kind: .taskNoteLink, id: link.noteID),
                  change.id == link.operationID else { throw PhoneFakeSyncFailure.invalidPayload }
            if let old = taskNoteLinks[link.taskID]?[link.operationID], old != link {
                throw PhoneFakeSyncFailure.immutableMismatch
            }
            taskNoteLinks[link.taskID, default: [:]][link.operationID] = link
            taskNoteCandidates[link.taskID, default: []].insert(link.noteID)
        case let .revision(revision):
            guard change.key == .init(kind: .noteRevision, id: revision.noteID, revisionID: revision.id),
                  revision.digest == PhoneFakeSyncDigest.of(revision.bytes), revision.contentFormat >= 0 else {
                throw PhoneFakeSyncFailure.invalidPayload
            }
            if let old = revisions[revision.id], old != revision { throw PhoneFakeSyncFailure.immutableMismatch }
            revisions[revision.id] = revision
            for noteID in Array(waitingHeads.keys) { resolveHeads(noteID) }
        case let .head(noteID, revisionID):
            guard change.key == .init(kind: .noteHead, id: noteID) else { throw PhoneFakeSyncFailure.invalidPayload }
            waitingHeads[noteID, default: []].insert(revisionID)
            resolveHeads(noteID)
        case let .assetManifest(meta):
            guard change.key == .init(kind: .assetManifest, id: meta.id), meta.byteCount >= 0,
                  meta.digest.count == 64 else { throw PhoneFakeSyncFailure.invalidPayload }
            if let old = manifests[meta.id], old != meta { throw PhoneFakeSyncFailure.immutableMismatch }
            manifests[meta.id] = meta
            try validateAsset(meta.id)
        case let .assetBytes(id, data):
            guard change.key == .init(kind: .assetBytes, id: id) else { throw PhoneFakeSyncFailure.invalidPayload }
            if let old = assets[id], old != data { throw PhoneFakeSyncFailure.immutableMismatch }
            assets[id] = data
            try validateAsset(id)
        case let .tombstone(tombstone):
            guard change.id == tombstone.id, change.key == tombstone.target,
                  [.task, .noteHead, .taskPlacement].contains(tombstone.target.kind) else {
                throw PhoneFakeSyncFailure.invalidPayload
            }
            tombstones[tombstone.target.recordName, default: [:]][tombstone.id] = tombstone
        case let .restore(target, tombstoneID):
            guard change.key == target, target.kind == .task || target.kind == .noteHead || target.kind == .taskPlacement else {
                throw PhoneFakeSyncFailure.invalidPayload
            }
            // Remember a causally authorized restore even if its delete arrives later.
            restoredTombstones.insert(tombstoneID)
        }
    }

    private mutating func resolveHeads(_ noteID: UUID) {
        let ready = (waitingHeads[noteID] ?? []).filter { revisions[$0]?.noteID == noteID }
        for incoming in ready.sorted(by: { $0.uuidString < $1.uuidString }) {
            var heads = noteHeads[noteID] ?? []
            heads.insert(incoming)
            for candidate in Array(heads) where candidate != incoming {
                var seen: Set<UUID> = []
                if noteDescends(incoming, from: candidate, seen: &seen) {
                    heads.remove(candidate)
                } else {
                    seen.removeAll()
                    if noteDescends(candidate, from: incoming, seen: &seen) { heads.remove(incoming) }
                }
            }
            noteHeads[noteID] = heads
            waitingHeads[noteID]?.remove(incoming)
        }
    }

    private func validateAsset(_ id: UUID) throws {
        guard let meta = manifests[id], let bytes = assets[id] else { return }
        guard meta.byteCount == bytes.count && meta.digest == PhoneFakeSyncDigest.of(bytes) else {
            throw PhoneFakeSyncFailure.invalidPayload
        }
    }
}

/// In production a SwiftData writer and the outgoing intent must commit in the
/// SAME transaction. This value-type fake is an atomic test double for that seam.
struct PhoneFakeSyncSnapshot: Codable { var scopes: [PhoneFakeSyncScope: PhoneFakeSyncStored] = [:] }

final class PhoneFakeSyncRepository {
    private(set) var snapshot: PhoneFakeSyncSnapshot
    var failNextCommit = false

    init(snapshot: PhoneFakeSyncSnapshot = .init()) { self.snapshot = snapshot }
    convenience init(encoded: Data) throws {
        self.init(snapshot: try JSONDecoder().decode(PhoneFakeSyncSnapshot.self, from: encoded))
    }

    func encoded() throws -> Data { try JSONEncoder().encode(snapshot) }

    @discardableResult
    func transaction<T>(_ scope: PhoneFakeSyncScope,
                        _ work: (inout PhoneFakeSyncStored) throws -> T) throws -> T {
        var draft = snapshot
        var account = draft.scopes[scope] ?? .init()
        let result = try work(&account)
        if failNextCommit {
            failNextCommit = false
            throw PhoneFakeSyncFailure.interruptedCommit
        }
        draft.scopes[scope] = account
        snapshot = draft
        return result
    }

    func state(_ scope: PhoneFakeSyncScope) -> PhoneFakeSyncStored { snapshot.scopes[scope] ?? .init() }
}

final class PhoneFakeSyncSession {
    let repository: PhoneFakeSyncRepository
    let transport: PhoneFakeSyncTransport
    private(set) var scope: PhoneFakeSyncScope?
    private var fetchedThisSession: Set<PhoneFakeSyncScope> = []

    init(repository: PhoneFakeSyncRepository, transport: PhoneFakeSyncTransport,
         scope: PhoneFakeSyncScope?) {
        self.repository = repository; self.transport = transport; self.scope = scope
    }

    func changeAccount(to next: PhoneFakeSyncScope?) {
        scope = next
        // A new account/session needs its own completed fetch before maintenance.
        fetchedThisSession.removeAll()
    }

    func state() throws -> PhoneFakeSyncStored {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        return repository.state(scope)
    }

    func recordEngineState(_ serialized: Data, recordFields: [String: Data] = [:]) throws {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        try repository.transaction(scope) { s in
            s.engineState = serialized
            s.recordSystemFields.merge(recordFields) { _, new in new }
        }
    }

    private func enqueue(_ body: PhoneFakeSyncBody, key: PhoneFakeSyncKey, id: UUID = UUID(),
                         after: [UUID] = [], into state: inout PhoneFakeSyncStored) throws -> UUID {
        guard state.nextGeneration < .max else { throw PhoneFakeSyncFailure.invalidPayload }
        state.nextGeneration += 1
        let change = PhoneFakeSyncChange(id: id, key: key, generation: state.nextGeneration,
                                        after: after, body: body)
        try state.apply(change)
        state.outgoing.append(change)
        return id
    }

    @discardableResult
    func saveTask(_ task: PhoneFakeSyncTask) throws -> UUID {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        return try repository.transaction(scope) { s in
            guard !s.physicalDivergence(task.id) else { throw PhoneFakeSyncFailure.divergentReplicas }
            return try enqueue(.task(task), key: .init(kind: .task, id: task.id),
                               id: task.operationID, into: &s)
        }
    }

    func associateTaskNote(taskID: UUID, noteID: UUID) throws {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        try repository.transaction(scope) { s in
            let link = PhoneFakeSyncTaskNoteLink(taskID: taskID, noteID: noteID, operationID: UUID())
            _ = try enqueue(.taskNoteLink(link), key: .init(kind: .taskNoteLink, id: noteID),
                            id: link.operationID, into: &s)
        }
    }

    /// The attachment metadata and bytes, immutable revision, then mutable head
    /// become eligible in this order. A lost receipt prevents head publication.
    @discardableResult
    func saveNote(_ revision: PhoneFakeSyncRevision,
                  attachments: [(PhoneFakeSyncAsset, Data)] = []) throws -> UUID {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        return try repository.transaction(scope) { s in
            let supplied = Set(attachments.map(\.0.id))
            guard supplied.count == attachments.count,
                  supplied.isSubset(of: Set(revision.attachmentIDs)),
                  revision.attachmentIDs.allSatisfy({ supplied.contains($0) || s.manifests[$0] != nil }) else {
                throw PhoneFakeSyncFailure.invalidPayload
            }
            var prerequisites: [UUID] = []
            for (meta, bytes) in attachments {
                guard meta.byteCount == bytes.count, meta.digest == PhoneFakeSyncDigest.of(bytes) else {
                    throw PhoneFakeSyncFailure.invalidPayload
                }
                let manifest = try enqueue(.assetManifest(meta), key: .init(kind: .assetManifest, id: meta.id), into: &s)
                let bytesID = try enqueue(.assetBytes(id: meta.id, data: bytes),
                                          key: .init(kind: .assetBytes, id: meta.id), after: [manifest], into: &s)
                prerequisites.append(bytesID)
            }
            let version = try enqueue(.revision(revision),
                                      key: .init(kind: .noteRevision, id: revision.noteID, revisionID: revision.id),
                                      after: prerequisites, into: &s)
            return try enqueue(.head(noteID: revision.noteID, revisionID: revision.id),
                               key: .init(kind: .noteHead, id: revision.noteID), after: [version], into: &s)
        }
    }

    func delete(_ target: PhoneFakeSyncKey) throws {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        try repository.transaction(scope) { s in
            let id = UUID()
            _ = try enqueue(.tombstone(.init(id: id, target: target)), key: target, id: id, into: &s)
        }
    }

    func restore(_ target: PhoneFakeSyncKey, tombstoneID: UUID) throws {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        try repository.transaction(scope) { s in
            guard s.tombstones[target.recordName]?[tombstoneID] != nil else {
                throw PhoneFakeSyncFailure.missingAncestor
            }
            _ = try enqueue(.restore(target: target, tombstoneID: tombstoneID), key: target, into: &s)
        }
    }

    /// Simulates an existing SwiftData store with duplicate physical UUID rows.
    /// Never invokes a uniqueness constraint, collapse, or winner-on-read repair.
    func addPhysicalTaskCopy(_ copy: PhoneFakeSyncTask) throws {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        try repository.transaction(scope) { s in s.physicalTasks[copy.id, default: []].append(copy) }
    }

    func acknowledge(_ receipt: PhoneFakeSyncReceipt) throws {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        guard receipt.scope == scope else { throw PhoneFakeSyncFailure.accountMismatch }
        try repository.transaction(scope) { s in
            guard let queued = s.outgoing.first(where: { $0.id == receipt.id }),
                  queued.key.recordName == receipt.recordName,
                  queued.generation == receipt.generation else { return }
            s.acknowledged.insert(receipt.id)
            s.outgoing.removeAll { $0.id == receipt.id }
        }
    }

    func sendPending() throws {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        // One pass over a snapshot: a withheld ack does not cause a busy retry.
        for change in repository.state(scope).outgoing {
            let latest = repository.state(scope)
            guard latest.outgoing.contains(where: { $0.id == change.id }),
                  change.after.allSatisfy({ latest.acknowledged.contains($0) }) else { continue }
            if let receipt = try transport.send(change, scope: scope) { try acknowledge(receipt) }
        }
    }

    /// A batch may be duplicated or reordered. Only committed contiguous
    /// sequences advance the checkpoint; a failed commit retries the same data.
    func receive(_ batch: PhoneFakeSyncFetch) throws {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        guard batch.scope == scope else { throw PhoneFakeSyncFailure.accountMismatch }
        let complete = try repository.transaction(scope) { s -> Bool in
            for envelope in batch.changes where envelope.sequence > s.checkpoint {
                guard envelope.sequence > 0 else { throw PhoneFakeSyncFailure.invalidPayload }
                if let saved = s.buffered[envelope.sequence], saved != envelope {
                    throw PhoneFakeSyncFailure.immutableMismatch
                }
                s.buffered[envelope.sequence] = envelope
            }
            while let next = s.buffered[s.checkpoint + 1] {
                if let previous = s.processed[next.change.id] {
                    guard previous == next.change else { throw PhoneFakeSyncFailure.immutableMismatch }
                } else {
                    try s.apply(next.change)
                    s.processed[next.change.id] = next.change
                }
                s.checkpoint += 1
                s.buffered.removeValue(forKey: s.checkpoint)
            }
            return batch.finished && s.checkpoint >= batch.upperBound && s.buffered.isEmpty
        }
        if complete { fetchedThisSession.insert(scope) }
        else { fetchedThisSession.remove(scope) }
    }

    func fetch() throws {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        let batch = try transport.fetch(scope: scope, after: repository.state(scope).checkpoint)
        try receive(batch)
    }

    func hasCompletedFetch() -> Bool { scope.map { fetchedThisSession.contains($0) } ?? false }

    /// Moves eligible Done families into history, preserving Task records and
    /// tombstoning only active placement. A stale/offline session cannot purge.
    @discardableResult
    func cleanDone(at now: Date, calendar: Calendar) throws -> Set<UUID> {
        guard let scope else { throw PhoneFakeSyncFailure.accountUnavailable }
        // Reconcile again immediately before deciding what to remove. If the
        // device is now offline, an earlier fetch is not a sufficient gate.
        try fetch()
        guard fetchedThisSession.contains(scope) else { throw PhoneFakeSyncFailure.incompleteFetch }
        return try repository.transaction(scope) { s in
            let cutoff = calendar.startOfDay(for: now)
            let ids = Set(s.tasks.keys)
            var eligible: Set<UUID> = []
            var links: [UUID: Set<UUID>] = [:]
            for id in ids {
                // Read every active branch and physical family link. An
                // inconsistent copy can reference another parent and veto both
                // families, but obsolete causal ancestors do not count as links.
                if !s.deleted(.init(kind: .task, id: id)) {
                    let variants = (s.taskHeads[id] ?? []).compactMap { s.tasks[id]?[$0] } + (s.physicalTasks[id] ?? [])
                    for variant in variants {
                        if let parent = variant.parentID {
                            links[parent, default: []].insert(id)
                            links[id, default: []].insert(parent)
                        }
                    }
                }
                guard let head = s.taskHead(id), !s.deleted(.init(kind: .taskPlacement, id: id)) else { continue }
                if head.status == .done, head.doneLoggedAt == nil,
                   head.completedAt.map({ $0 < cutoff }) == true { eligible.insert(id) }
            }
            // Any connected missing, open, deleted, forked or divergent member
            // vetoes cleanup for its entire family, including siblings.
            var blocked = Set(links.keys).subtracting(eligible)
            for (parent, children) in links where !ids.contains(parent) {
                blocked.insert(parent)
                blocked.formUnion(children)
            }
            while let id = blocked.first {
                blocked.remove(id)
                for next in links[id] ?? [] where eligible.remove(next) != nil { blocked.insert(next) }
            }
            let ordered = eligible.sorted { $0.uuidString < $1.uuidString }
            for id in ordered {
                guard let old = s.taskHead(id) else { throw PhoneFakeSyncFailure.divergentReplicas }
                let archival = PhoneFakeSyncTask(id: id, parents: [old.operationID], title: old.title,
                                                 status: old.status, parentID: old.parentID,
                                                 completedAt: old.completedAt, doneLoggedAt: now)
                let taskID = try enqueue(.task(archival), key: .init(kind: .task, id: id),
                                         id: archival.operationID, into: &s)
                let deletedID = UUID(), placement = PhoneFakeSyncKey(kind: .taskPlacement, id: id)
                _ = try enqueue(.tombstone(.init(id: deletedID, target: placement)),
                                key: placement, id: deletedID, after: [taskID], into: &s)
            }
            return Set(ordered)
        }
    }
}
#endif
