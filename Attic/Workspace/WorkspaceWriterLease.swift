import Darwin
import Foundation
import SwiftData
import ObjectiveC

/// Stable inode, advisory process lifetime lock. Never unlink/recreate this
/// file: doing so would allow two writers to lock different inodes.
final class WorkspaceWriterLease: @unchecked Sendable {
    private final class WeakLease {
        weak var value: WorkspaceWriterLease?
        init(_ value: WorkspaceWriterLease) { self.value = value }
    }
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var leases: [String: WeakLease] = [:]
        var containerKey: UInt8 = 0
    }
    private static let registry = Registry()
    static func acquire(storeURL: URL) throws -> WorkspaceWriterLease {
        registry.lock.lock(); defer { registry.lock.unlock() }
        let key = storeURL.resolvingSymlinksInPath().path
        if let existing = registry.leases[key]?.value { return existing }
        let lease = try WorkspaceWriterLease(storeURL: URL(fileURLWithPath: key))
        registry.leases[key] = WeakLease(lease)
        return lease
    }
    static func attach(_ lease: WorkspaceWriterLease, to container: ModelContainer) {
        objc_setAssociatedObject(container, &registry.containerKey, lease, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func attached(to container: ModelContainer) -> WorkspaceWriterLease? {
        objc_getAssociatedObject(container, &registry.containerKey) as? WorkspaceWriterLease
    }
    private let descriptor: Int32
    init(storeURL: URL) throws {
        let lockURL = URL(fileURLWithPath: storeURL.path + ".workspace-writer.lock")
        descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno; close(descriptor)
            if failure == EWOULDBLOCK { throw WorkspaceFoundationError.writerAlreadyActive }
            throw POSIXError(.init(rawValue: failure) ?? .EIO)
        }
    }
    deinit { close(descriptor) }
}
