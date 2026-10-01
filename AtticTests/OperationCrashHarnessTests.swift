import Foundation
import SwiftData
import Security
import XCTest
@testable import Attic

@MainActor
final class OperationCrashHarnessTests: XCTestCase {
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
