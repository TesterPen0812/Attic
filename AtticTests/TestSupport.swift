import Foundation
import SwiftData
@testable import Attic

@MainActor
func makeTestStore(
    now: @escaping () -> Date = Date.init,
    persist: @escaping (ModelContext) throws -> Void = { try $0.save() }
) throws -> TaskStore {
    let container = try PersistenceController.makeContainer(inMemory: true)
    return TaskStore(container: container, now: now, persist: persist)
}

extension XCTestCase {
    func makeTestAttachmentFileStore(rootURL: URL? = nil) -> AttachmentFileStore {
        let isolatedRoot = rootURL ?? ownedTemporaryDirectory(prefix: "AtticNoteStoreTests")
        return AttachmentFileStore(rootURL: isolatedRoot)
    }
}

extension XCTestCase {
    @MainActor
    func makeTestNoteStore(
        now: @escaping () -> Date = Date.init,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
        attachmentFileStore: AttachmentFileStore,
        attachmentImporter: (any NoteAttachmentFileImporting)? = nil
    ) throws -> NoteStore {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(
            container: container,
            now: now,
            persist: persist,
            attachmentFileStore: attachmentFileStore,
            attachmentImporter: attachmentImporter
        )
        addTeardownBlock { [weak store] in await store?.waitForAttachmentReconciliation() }
        return store
    }
}

@MainActor
func makeTestCanvasStore(
    now: @escaping () -> Date = Date.init,
    persist: @escaping (ModelContext) throws -> Void = { try $0.save() }
) throws -> CanvasStore {
    let container = try PersistenceController.makeContainer(inMemory: true)
    return CanvasStore(container: container, now: now, persist: persist)
}

final class MutableNow {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

@MainActor
final class PersistenceGate {
    struct Failure: Error {}

    var shouldFail = false
    private(set) var saveCount = 0

    func save(_ context: ModelContext) throws {
        if shouldFail { throw Failure() }
        try context.save()
        saveCount += 1
    }
}

/// Fails recovery-checkpoint unlinks on request, so tests reach the
/// journal's own retired-marker fallback.
final class UnlinkFailingFileManager: FileManager, @unchecked Sendable {
    struct Failure: Error {}
    private let failureLock = NSLock()
    private var failAll = false
    private var failNext = false
    var failCheckpointRemovals: Bool {
        get { failureLock.withLock { failAll } }
        set { failureLock.withLock { failAll = newValue } }
    }
    var failNextCheckpointRemoval: Bool {
        get { failureLock.withLock { failNext } }
        set { failureLock.withLock { failNext = newValue } }
    }

    override func removeItem(at url: URL) throws {
        let refuse = failureLock.withLock {
            guard url.pathExtension == "json", failAll || failNext else { return false }
            failNext = false
            return true
        }
        if refuse { throw Failure() }
        try super.removeItem(at: url)
    }
}

// XCTest's standard autoclosures cannot await. These adapters evaluate real
// asynchronous persistence before forwarding the same assertion and location.
import XCTest

@MainActor
func XCTAssertTrueAsync(_ value: @autoclosure () async throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { let result = try await value(); XCTAssertTrue(result, message, file: file, line: line) }
    catch { XCTFail("\(message): \(error)", file: file, line: line) }
}
@MainActor
func XCTAssertFalseAsync(_ value: @autoclosure () async throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { let result = try await value(); XCTAssertFalse(result, message, file: file, line: line) }
    catch { XCTFail("\(message): \(error)", file: file, line: line) }
}
@MainActor
func XCTAssertEqualAsync<T: Equatable>(_ lhs: @autoclosure () async throws -> T, _ rhs: @autoclosure () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { let a = try await lhs(), b = try await rhs(); XCTAssertEqual(a, b, message, file: file, line: line) }
    catch { XCTFail("\(message): \(error)", file: file, line: line) }
}
@MainActor
func XCTAssertNotEqualAsync<T: Equatable>(_ lhs: @autoclosure () async throws -> T, _ rhs: @autoclosure () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { let a = try await lhs(), b = try await rhs(); XCTAssertNotEqual(a, b, message, file: file, line: line) }
    catch { XCTFail("\(message): \(error)", file: file, line: line) }
}
@MainActor
func XCTAssertNilAsync<T>(_ value: @autoclosure () async throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { let result = try await value(); XCTAssertNil(result, message, file: file, line: line) }
    catch { XCTFail("\(message): \(error)", file: file, line: line) }
}
@MainActor
func XCTAssertNotNilAsync<T>(_ value: @autoclosure () async throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { let result = try await value(); XCTAssertNotNil(result, message, file: file, line: line) }
    catch { XCTFail("\(message): \(error)", file: file, line: line) }
}
@MainActor
func XCTAssertThrowsErrorAsync<T>(_ value: @autoclosure () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await value(); XCTFail("Expected error. \(message)", file: file, line: line) } catch {}
}
@MainActor
func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value(); return try XCTUnwrap(result, message, file: file, line: line)
}

/// A capability for exactly one UUID root. Merely knowing a temp prefix does
/// not authorize deleting its other children (including earlier test runs).
final class OwnedTestTemporaryDirectory: @unchecked Sendable {
    let url: URL
    private let temporaryRoot: URL
    private let prefix: String
    private let id = UUID()

    init(prefix: String) {
        precondition(!prefix.isEmpty && !prefix.contains("/") && !prefix.contains("\\"))
        self.prefix = prefix
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL
        temporaryRoot = temp.resolvingSymlinksInPath().standardizedFileURL
        // Keep the system's path spelling for code that checks its temp root.
        url = temp.appendingPathComponent("\(prefix)-\(id.uuidString)", isDirectory: true)
    }

    func remove() throws {
        let expectedName = "\(prefix)-\(id.uuidString)"
        guard url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path == temporaryRoot.path,
              url.lastPathComponent == expectedName,
              UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count + 1))) == id else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        // Absent roots are normal for tests whose system under test cleans up.
        // Refuse even a dangling symlink instead of following a replacement.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == temporaryRoot.appendingPathComponent(expectedName).path else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: url)
    }
}

extension XCTestCase {
    /// Allocate the name and register ownership before any fixture I/O can
    /// throw. The caller or store creates the directory when it needs it.
    func ownedTemporaryDirectory(prefix: String = "AtticTests") -> URL {
        let owned = OwnedTestTemporaryDirectory(prefix: prefix)
        addTeardownBlock { try owned.remove() }
        return owned.url
    }

    func ownedTemporaryFile(named name: String, prefix: String) throws -> URL {
        precondition(name == URL(fileURLWithPath: name).lastPathComponent)
        let root = ownedTemporaryDirectory(prefix: prefix)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root.appendingPathComponent(name)
    }

    /// The tested API itself created and returned this UUID child of a known
    /// exports/paste root. Never delete the shared parent or scan its siblings.
    func registerTemporaryProductDirectory(_ url: URL, parentName: String? = nil, prefix: String? = nil) {
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let expected = url.standardizedFileURL
        // /var and /private/var name the same macOS temp tree. Resolve only
        // the parent when recording ownership, so a symlink root is refused.
        let canonical = expected.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(expected.lastPathComponent, isDirectory: true).standardizedFileURL
        addTeardownBlock {
            let parent = canonical.deletingLastPathComponent()
            let uuid: String
            if let parentName {
                guard parent.path == temp.appendingPathComponent(parentName, isDirectory: true).path else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                if let prefix {
                    guard expected.lastPathComponent.hasPrefix(prefix + "-") else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                    uuid = String(expected.lastPathComponent.dropFirst(prefix.count + 1))
                } else {
                    uuid = expected.lastPathComponent
                }
            } else if let prefix {
                guard parent.path == temp.path, expected.lastPathComponent.hasPrefix(prefix + "-") else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                uuid = String(expected.lastPathComponent.dropFirst(prefix.count + 1))
            } else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            guard UUID(uuidString: uuid) != nil,
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: expected.path)) == nil else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            if FileManager.default.fileExists(atPath: expected.path) {
                guard expected.resolvingSymlinksInPath().standardizedFileURL.path == canonical.path else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                try FileManager.default.removeItem(at: expected)
            }
        }
    }
}

/// Direct-container fixtures also launch reconciliation. Drain it before the
/// earlier root teardown block runs, so late work cannot recreate that root.
extension XCTestCase {
    @MainActor
    func trackAttachmentReconciliation(of store: NoteStore) -> NoteStore {
        addTeardownBlock { [weak store] in await store?.waitForAttachmentReconciliation() }
        return store
    }
}
