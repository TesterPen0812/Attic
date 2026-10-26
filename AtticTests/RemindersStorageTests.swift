import CoreData
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class RemindersStorageTests: XCTestCase {
    func testSchemaHasDefaultedFlagAndOptionalURL() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let entity = try XCTUnwrap(container.schema.entities.first { $0.name == "TaskItem" })
        let flag = try XCTUnwrap(entity.attributes.first { $0.name == "isFlagged" })
        XCTAssertEqual(flag.defaultValue as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(entity.attributes.first { $0.name == "url" }).isOptional)
    }

    func testAgentReadsSetsAndClearsBothInOneUndoStep() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let tools = AgentTaskTools(store: store, library: library)
        let task = try XCTUnwrap(store.create(title: "Reference"))
        let json = try tools.call(name: "update_task", arguments: ["id": task.id.uuidString,
            "is_flagged": true, "url": "  HTTPS://EXAMPLE.COM/review?q=one  "])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let row = try XCTUnwrap(payload["task"] as? [String: Any])
        XCTAssertEqual(row["is_flagged"] as? Bool, true)
        XCTAssertEqual(row["url"] as? String, "https://example.com/review?q=one")
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        let listed = try tools.call(name: "list_tasks", arguments: [:])
        XCTAssertTrue(listed.contains("is_flagged"))
        XCTAssertFalse(listed.contains("example.com"))
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        let cleared = try tools.call(name: "update_task", arguments: ["id": task.id.uuidString, "is_flagged": false, "url": NSNull()])
        XCTAssertFalse(cleared.contains("example.com"))
        for name in ["create_task", "update_task"] {
            let def = try XCTUnwrap(tools.definitions.first { $0["name"] as? String == name })
            let props = (def["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
            XCTAssertNotNil(props?["is_flagged"]); XCTAssertNotNil(props?["url"])
        }
    }
}
