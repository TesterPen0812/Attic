import Foundation
import SwiftData
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
}
