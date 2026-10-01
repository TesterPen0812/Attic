import Foundation

/// Shared by the writer and filesystem actors. A collection lease freezes the
/// affected IDs while providers suspend; admissions wait without holding a
/// ModelContext. Synchronous callers refuse and retain their draft for retry.
final class WorkspaceOwnershipGate: @unchecked Sendable {
    enum Kind: Sendable { case admission, collection }
    final class Lease: @unchecked Sendable {
        let id: UUID
        let ids: Set<UUID>
        private let gate: WorkspaceOwnershipGate
        fileprivate init(id: UUID, ids: Set<UUID>, gate: WorkspaceOwnershipGate) {
            self.id = id; self.ids = ids; self.gate = gate
        }
        func release() { gate.release(id) }
        deinit { release() }
    }
    private struct Held { let ids: Set<UUID>; let kind: Kind }
    private struct Waiter {
        let id: UUID; let ids: Set<UUID>; let excluding: UUID?
        let continuation: CheckedContinuation<Lease, Error>
    }
    private let lock = NSLock()
    private var held: [UUID: Held] = [:]
    private var waiting: [Waiter] = []
    private var cancelled: Set<UUID> = []
    private var pending: Set<UUID> = []
    private var epoch: UInt64 = 0
    private var unlinked: Set<UUID> = []
    let identity = UUID()
    /// Unknown byte reachability overlaps every collection in this domain.
    let unknownID = UUID()
    var generation: UInt64 { lock.withLock { epoch } }
    func wasUnlinked(_ id: UUID) -> Bool { lock.withLock { unlinked.contains(id) } }
    func didUnlink(_ id: UUID) { lock.withLock { _ = unlinked.insert(id) } }
    func didVerify(_ id: UUID) { lock.withLock { _ = unlinked.remove(id) } }

    private func available(_ ids: Set<UUID>, kind: Kind, excluding: UUID?) -> Bool {
        !held.contains { token, value in
            token != excluding && !value.ids.isDisjoint(with: ids)
                && (kind == .collection || value.kind == .collection)
        }
    }
    private func make(_ ids: Set<UUID>, kind: Kind) -> Lease {
        let id = UUID(); held[id] = Held(ids: ids, kind: kind); epoch &+= 1
        return Lease(id: id, ids: ids, gate: self)
    }
    func tryAcquire(_ ids: Set<UUID>, kind: Kind, excluding: Lease? = nil) -> Lease? {
        let ids = kind == .collection ? ids.union([unknownID]) : ids
        return lock.withLock {
            guard available(ids, kind: kind, excluding: excluding?.id) else { return nil }
            return make(ids, kind: kind)
        }
    }
    func admit(_ ids: Set<UUID>, excluding: Lease? = nil) async throws -> Lease {
        let token = UUID()
        lock.withLock { _ = pending.insert(token) }
        let lease: Lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lease, Error>) in
                lock.lock()
                if cancelled.remove(token) != nil || Task.isCancelled {
                    pending.remove(token)
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                if available(ids, kind: .admission, excluding: excluding?.id) {
                    pending.remove(token)
                    let lease = make(ids, kind: .admission)
                    lock.unlock(); continuation.resume(returning: lease)
                } else {
                    waiting.append(Waiter(id: token, ids: ids, excluding: excluding?.id, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: { self.cancel(token) }
        do { try Task.checkCancellation() } catch { lease.release(); throw error }
        return lease
    }
    private func cancel(_ id: UUID) {
        let continuation: CheckedContinuation<Lease, Error>? = lock.withLock {
            guard pending.contains(id) else { return nil }
            if let index = waiting.firstIndex(where: { $0.id == id }) {
                pending.remove(id); return waiting.remove(at: index).continuation
            }
            cancelled.insert(id); return nil
        }
        continuation?.resume(throwing: CancellationError())
    }
    private func release(_ id: UUID) {
        var ready: [(CheckedContinuation<Lease, Error>, Lease)] = []
        lock.lock()
        guard held.removeValue(forKey: id) != nil else { lock.unlock(); return }
        epoch &+= 1
        var remaining: [Waiter] = []
        for waiter in waiting {
            if available(waiter.ids, kind: .admission, excluding: waiter.excluding) {
                pending.remove(waiter.id)
                ready.append((waiter.continuation, make(waiter.ids, kind: .admission)))
            } else { remaining.append(waiter) }
        }
        waiting = remaining
        lock.unlock()
        for (continuation, lease) in ready { continuation.resume(returning: lease) }
    }
    func validatesCollection(_ lease: Lease, ids: Set<UUID>) -> Bool {
        lock.withLock { held[lease.id].map { $0.kind == .collection && ids.isSubset(of: $0.ids) } ?? false }
    }

    /// Multiple filesystem actors addressing the same tree share one gate.
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: WorkspaceOwnershipGate] = [:]
        func gate(_ key: String) -> WorkspaceOwnershipGate {
            lock.withLock {
                if let value = values[key] { return value }
                let value = WorkspaceOwnershipGate(); values[key] = value; return value
            }
        }
    }
    private static let registry = Registry()
    static func shared(for key: String) -> WorkspaceOwnershipGate { registry.gate(key) }
}

/// All bound writer domains and the filesystem tree participate. Nonblocking
/// collection defers if an import/writer owns a candidate; admission waits.
final class WorkspaceOwnershipLeases: @unchecked Sendable {
    let leases: [UUID: WorkspaceOwnershipGate.Lease]
    init(_ leases: [UUID: WorkspaceOwnershipGate.Lease]) { self.leases = leases }
    func lease(for gate: WorkspaceOwnershipGate) -> WorkspaceOwnershipGate.Lease? { leases[gate.identity] }
    func release() { leases.values.forEach { $0.release() } }
    deinit { release() }
}
