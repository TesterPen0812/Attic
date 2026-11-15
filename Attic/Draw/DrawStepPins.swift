import Foundation

/// Legacy offer bookkeeping, retained until R6 replaces protection with
/// expiration. Tokens contain identities, never history payloads.
final class DrawStepPins: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UUID: Set<UUID>] = [:]
    private var generation: UInt64 = 0
    var didRelease: (@Sendable () -> Void)?
    private var notificationPending = false
    func acknowledgeReleaseChange() {
        lock.lock(); notificationPending = false; lock.unlock()
    }
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    var hasPins: Bool { lock.lock(); defer { lock.unlock() }; return !counts.isEmpty }
    func pin(_ step: UUID) -> Pin {
        let token = UUID()
        lock.lock(); counts[step, default: []].insert(token); generation &+= 1; lock.unlock()
        return Pin(book: self, step: step, token: token)
    }
    func isPinned(_ step: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return counts[step]?.isEmpty == false
    }
    private func contains(_ step: UUID, token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return counts[step]?.contains(token) == true
    }
    func expire(_ step: UUID) {
        lock.lock()
        guard counts.removeValue(forKey: step) != nil else { lock.unlock(); return }
        changedWhileLocked()
    }
    private func release(_ step: UUID, token: UUID) {
        lock.lock()
        guard var held = counts[step], held.remove(token) != nil else { lock.unlock(); return }
        counts[step] = held.isEmpty ? nil : held
        changedWhileLocked()
    }
    private func changedWhileLocked() {
        generation &+= 1
        let notify = !notificationPending
        notificationPending = true
        lock.unlock()
        if notify { didRelease?() }
    }
    final class Pin: @unchecked Sendable {
        let book: DrawStepPins
        let step: UUID
        private let token: UUID
        private let lock = NSLock()
        private var cancelled = false
        var isActive: Bool { book.contains(step, token: token) }
        init(book: DrawStepPins, step: UUID, token: UUID) { self.book = book; self.step = step; self.token = token }
        func cancel() {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            cancelled = true; lock.unlock()
            book.release(step, token: token)
        }
        deinit { cancel() }
    }
}
