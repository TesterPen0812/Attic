import Foundation
import SwiftData
import Security
import XCTest
@testable import Attic

@MainActor
final class OperationCrashHarnessTests: XCTestCase {
    private func runChild(_ mode: String, root: URL, point: String? = nil, saveThenThrow: Bool = false) async throws -> Int32 {
        let child = Process()
        child.executableURL = try XCTUnwrap(Bundle.main.executableURL)
            .deletingLastPathComponent().appendingPathComponent("AtticOperationCrashHelper")
        child.arguments = [mode, root.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ATTIC_CRASH_POINT")
        environment.removeValue(forKey: "ATTIC_SAVE_THEN_THROW")
        if let point { environment["ATTIC_CRASH_POINT"] = point }
        if saveThenThrow { environment["ATTIC_SAVE_THEN_THROW"] = "1" }
        child.environment = environment
        let done = expectation(description: "\(mode) \(point ?? "complete") exits")
        child.terminationHandler = { _ in done.fulfill() }
        try child.run()
        await fulfillment(of: [done], timeout: 40)
        if child.isRunning { child.terminate(); throw WorkspaceFoundationError.unknown }
        XCTAssertEqual(child.terminationReason, .exit)
        return child.terminationStatus
    }

    func testC2SecondProcessWriterLeaseRefusesTheSameStoreAndReleasesOnDeath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOperationCrash-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var container: ModelContainer? = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        XCTAssertNotNil(container)
        let refused = try await runChild("writer-probe", root: root)
        XCTAssertEqual(refused, 76)
        container = nil
        let launched = try await runChild("launch-probe", root: root)
        XCTAssertEqual(launched, 73)
    }

    func testC4ConversionCrashMatrixReopensTwiceWithoutPartialRowsOrLostOriginals() async throws {
        let points = ["K0", "K1", "K2", "K3-validation", "K3-task", "K3-note", "K3-association", "K4",
                      "K5", "K6-1", "K6-2", "K6-3", "K6-4", "K6-5", "K7", "save-then-throw"]
        let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent("AtticCrashSentinel-\(UUID())")
        let sentinelBytes = Data("outside fixture: preserve me".utf8)
        try sentinelBytes.write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        for (index, point) in points.enumerated() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOperationCrash-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let seeded = try await runChild("seed-conversion", root: root)
            XCTAssertEqual(seeded, 73, point)
            let crashed = try await runChild("convert", root: root, point: point == "save-then-throw" ? nil : point,
                                            saveThenThrow: point == "save-then-throw")
            XCTAssertEqual(crashed, point == "save-then-throw" ? 73 : 86, point)
            let committed = index >= 8
            for reopen in 0..<2 {
                let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                let journal = WorkspaceCrashFixture.journal(root)
                let coordinator = try WorkspaceOperationCoordinator(container: container, journal: journal)
                if point != "save-then-throw" && (reopen == 0 || !committed) {
                    do { _ = try await journal.readRecoveryEntries(); XCTFail("offering must await receipt reconciliation: \(point)") }
                    catch { }
                }
                try await coordinator.reconcileStartup()
                let context = coordinator.freshContext()
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), committed ? 2 : 1, point)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskNoteAssociation>()), committed ? 1 : 0, point)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteVersion>()), committed ? 1 : 0, point)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteAttachment>()), committed ? 1 : 0, point)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceipt>()), committed ? 1 : 0, point)
                let recovery = try await journal.readRecoveryEntries()
                if committed {
                    XCTAssertTrue(recovery.isEmpty, "committed pre-copy must not be offered: \(point)")
                    XCTAssertTrue(coordinator.preOperationRecoveryCopies.isEmpty)
                    XCTAssertEqual(try context.fetch(FetchDescriptor<NoteAttachment>()).first?.payload, WorkspaceCrashFixture.bytes)
                    let content = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first?.content)
                    XCTAssertEqual(NoteContentCodec.decode(content).document, WorkspaceCrashFixture.candidate)
                } else {
                    guard case let .valid(pre, staged, _) = recovery.first else { XCTFail("lost pre-copy: \(point)"); continue }
                    XCTAssertEqual(NoteContentCodec.decode(pre.content).document, WorkspaceCrashFixture.original)
                    XCTAssertEqual(staged.first?.data, WorkspaceCrashFixture.bytes)
                    XCTAssertEqual(coordinator.preOperationRecoveryCopies.count, 1)
                }
                XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
            }
        }
    }
    func testK8CoordinatedPurgeCrashesLeaveOnlyRecoverableExclusiveFileSurplus() async throws {
        let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent("AtticPurgeSentinel-\(UUID())")
        let sentinelBytes = Data("outside purge fixture".utf8); try sentinelBytes.write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        for point in ["K8-before-unlink", "K8-cache"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOperationCrash-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let seed = try await runChild("seed-purge", root: root); XCTAssertEqual(seed, 73)
            let crash = try await runChild("purge", root: root, point: point); XCTAssertEqual(crash, 86)
            let references = try WorkspaceCrashFixture.purgeFiles(root)
            for _ in 0..<2 {
                let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                let coordinator = try WorkspaceOperationCoordinator(container: container, journal: WorkspaceCrashFixture.journal(root))
                try await coordinator.reconcileStartup()
                let context = coordinator.freshContext()
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), 0)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskDeletionPreservation>()), 1)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceipt>()), 1)
                let note = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first)
                XCTAssertNil(note.taskID); XCTAssertEqual(note.title, "Parent")
                let doc = try XCTUnwrap(note.content.flatMap { NoteContentCodec.decode($0).document })
                XCTAssertFalse(doc.requires.contains("taskNote")); XCTAssertEqual(doc.blocks[1].text, "Retain body")
                let files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
                var remaining = 0
                for reference in references { if try await files.verifiedURL(for: reference) != nil { remaining += 1 } }
                XCTAssertEqual(remaining, point == "K8-before-unlink" ? 2 : 1)
                XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
            }
            let files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles")); await files.remove(references)
            for reference in references { let url = try await files.verifiedURL(for: reference); XCTAssertNil(url) }
        }
    }
    func testC4EmbeddedChildLaunchesAndReopensExactSchemaInsideHostSandbox() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticOperationCrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Bundle.main is the hosted executable, not the XCTest bundle. Resolve
        // relative to it so product/executable-name preview overrides work.
        let executable = try XCTUnwrap(Bundle.main.executableURL)
            .deletingLastPathComponent().appendingPathComponent("AtticOperationCrashHelper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        // Assert the signatures at launch time too; build evidence alone must
        // not mask any test-runner re-signing of the embedded executable.
        var hostCode: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &hostCode), errSecSuccess)
        var hostStatic: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(hostCode), [], &hostStatic), errSecSuccess)
        try assertSandboxAndRuntime(try XCTUnwrap(hostStatic), helper: false)
        var helperCode: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(executable as CFURL, [], &helperCode), errSecSuccess)
        try assertSandboxAndRuntime(try XCTUnwrap(helperCode), helper: true)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["launch-probe", root.path]
        let done = expectation(description: "crash helper exits")
        child.terminationHandler = { _ in done.fulfill() }
        try child.run()
        await fulfillment(of: [done], timeout: 30)
        if child.isRunning { child.terminate(); XCTFail("helper did not exit"); return }
        XCTAssertEqual(child.terminationReason, .exit)
        XCTAssertEqual(child.terminationStatus, 73, "child must save then exit abruptly")
        let childSchema = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: root.appendingPathComponent("schema.json"))
        )
        for _ in 0..<2 {
            try autoreleasepool {
                let container = try PersistenceController.makeContainer(
                    cloudSyncEnabled: false, storeDirectory: root
                )
                XCTAssertEqual(childSchema, container.schema.entities.map(\.name).sorted())
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let tasks = try context.fetch(FetchDescriptor<TaskItem>())
                let notes = try context.fetch(FetchDescriptor<NoteItem>())
                XCTAssertEqual(tasks.count, 1)
                XCTAssertEqual(notes.count, 1)
                XCTAssertEqual(tasks.first?.title, "child task")
                XCTAssertEqual(notes.first?.body, "durable child bytes")
                XCTAssertEqual(notes.first?.taskID, tasks.first?.id)
            }
        }
    }
    private func assertSandboxAndRuntime(_ code: SecStaticCode, helper: Bool) throws {
        var information: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information), errSecSuccess)
        let info = try XCTUnwrap(information as? [String: Any])
        let flags = try XCTUnwrap(info[kSecCodeInfoFlags as String] as? NSNumber).uint32Value
        XCTAssertNotEqual(flags & 0x10000, 0, "hardened runtime must be active")
        let entitlements = try XCTUnwrap(info[kSecCodeInfoEntitlementsDict as String] as? [String: Any])
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        if helper {
            XCTAssertEqual(Set(entitlements.keys), ["com.apple.security.app-sandbox", "com.apple.security.inherit"])
            XCTAssertEqual(entitlements["com.apple.security.inherit"] as? Bool, true)
        }
    }
}
