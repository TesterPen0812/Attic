import Darwin
import Foundation

/// Stable inode, advisory process lifetime lock. Never unlink/recreate this
/// file: doing so would allow two writers to lock different inodes.
final class WorkspaceWriterLease {
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
