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

func makeTestAttachmentFileStore(rootURL: URL? = nil) -> AttachmentFileStore {
    let isolatedRoot = rootURL ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("AtticNoteStoreTests-\(UUID().uuidString)", isDirectory: true)
    return AttachmentFileStore(rootURL: isolatedRoot)
}

@MainActor
func makeTestNoteStore(
    now: @escaping () -> Date = Date.init,
    persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
    attachmentFileStore: AttachmentFileStore,
    attachmentImporter: (any NoteAttachmentFileImporting)? = nil
) throws -> NoteStore {
    let container = try PersistenceController.makeContainer(inMemory: true)
    return NoteStore(
        container: container,
        now: now,
        persist: persist,
        attachmentFileStore: attachmentFileStore,
        attachmentImporter: attachmentImporter
    )
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
    private(set) var bookkeepingSaveCount = 0

    func save(_ context: ModelContext) throws {
        if shouldFail { throw Failure() }
        let rows = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
        // The phase-3 contract separates the one model+receipt transaction
        // from later receipt-only publication bookkeeping. Continue measuring
        // domain atomicity, and record every successful bookkeeping save too.
        let bookkeeping = !rows.isEmpty && rows.allSatisfy { $0 is OperationReceipt }
        try context.save()
        if bookkeeping { bookkeepingSaveCount += 1 } else { saveCount += 1 }
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
