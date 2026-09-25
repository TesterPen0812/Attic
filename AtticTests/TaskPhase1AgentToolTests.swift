import SwiftData
import XCTest
@testable import Attic

/// Phase 1 agent parity for tasks (spec § Agent access): `state` (backlog
/// included) on create and update, `list_tasks` filters (state, tag, due
/// before and after, text) and the Done log, with the Phase 0 shapes kept.
@MainActor
final class TaskPhase1AgentToolTests: XCTestCase {
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var tools: AgentTaskTools!
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000)) // Mon 21 Sep 2026, 14:13 UTC

    override func setUp() async throws {
        store = try makeTestStore(now: { [clock] in clock.value })
        library = AtticLibrary(tasks: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parser = TaskTextParser(calendar: calendar, locale: Locale(identifier: "en_GB"), now: { [clock] in clock.value })
        tools = AgentTaskTools(store: store, library: library, parser: parser)
    }

    override func tearDown() {
        tools = nil
        library = nil
        store = nil
    }

    private func call(_ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let text = try tools.call(name: name, arguments: arguments)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func titles(_ payload: [String: Any]) -> [String] {
        (payload["tasks"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
    }

    private func error(_ name: String, _ arguments: [String: Any]) -> String {
        do {
            _ = try tools.call(name: name, arguments: arguments)
            return ""
        } catch let error as AgentToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    func testDefinitionsOfferStateAndTheNewFilters() throws {
        let definitions = tools.definitions
        func properties(_ name: String) -> [String: Any] {
            let tool = definitions.first { $0["name"] as? String == name }
            return (tool?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        }
        XCTAssertTrue(Set(properties("list_tasks").keys).isSuperset(of: [
            "status", "state", "parent_id", "tag", "due_before", "due_after", "text", "include_done_log"
        ]))
        XCTAssertNotNil(properties("create_task")["state"])
        XCTAssertNotNil(properties("update_task")["state"])
    }

    func testCreateAndUpdateTakeStateIncludingBacklog() throws {
        let created = try call("create_task", ["title": "Idea", "state": "backlog"])
        let task = try XCTUnwrap(created["task"] as? [String: Any])
        XCTAssertEqual(task["status"] as? String, "backlog")
        let id = try XCTUnwrap(task["id"] as? String)
        let moved = try call("update_task", ["id": id, "state": "todo"])
        XCTAssertEqual((moved["task"] as? [String: Any])?["status"] as? String, "todo")
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Change Task State", "agent edits are undoable steps")
        XCTAssertTrue(error("update_task", ["id": id, "state": "done", "status": "todo"]).contains("not both"))
        XCTAssertTrue(error("create_task", ["title": "Nope", "state": "done"]).contains("Invalid status"))
        // The Phase 0 name still works.
        XCTAssertEqual(((try call("create_task", ["title": "Old", "status": "backlog"]))["task"] as? [String: Any])?["status"] as? String,
                       "backlog")
    }

    func testListTasksFiltersByStateTagDueAndText() throws {
        _ = try call("create_task", ["title": "Email beta testers", "tags": ["launch"], "due": "2026-09-22"])
        _ = try call("create_task", ["title": "Book dentist", "due": "2026-09-30"])
        _ = try call("create_task", ["title": "Write launch notes", "tags": ["launch"], "state": "backlog"])
        _ = try call("create_task", ["title": "No date"])

        XCTAssertEqual(titles(try call("list_tasks", ["state": "backlog"])), ["Write launch notes"])
        XCTAssertEqual(Set(titles(try call("list_tasks", ["tag": "#Launch"]))), ["Email beta testers", "Write launch notes"])
        XCTAssertEqual(titles(try call("list_tasks", ["due_before": "2026-09-25"])), ["Email beta testers"])
        XCTAssertEqual(titles(try call("list_tasks", ["due_after": "sep 23"])), ["Book dentist"])
        XCTAssertEqual(titles(try call("list_tasks", ["due_after": "2026-09-22", "due_before": "2026-09-22"])),
                       ["Email beta testers"], "both ends are inclusive")
        XCTAssertEqual(titles(try call("list_tasks", ["text": "DENTIST"])), ["Book dentist"])
        XCTAssertEqual(titles(try call("list_tasks", ["tag": "launch", "state": "todo"])), ["Email beta testers"])
        let all = try call("list_tasks")
        XCTAssertEqual(all["count"] as? Int, 4, "no filter lists everything, as before")
        XCTAssertTrue(error("list_tasks", ["due_before": "someday"]).contains("due_before"))
        XCTAssertTrue(error("list_tasks", ["tag": "!!!"]).contains("tag"))
        XCTAssertTrue(error("list_tasks", ["include_done_log": "yes"]).contains("true or false"))
    }

    func testTheDoneLogIsListedOnRequestAndATaskComesBackToNow() throws {
        let created = try call("create_task", ["title": "Ship it"])
        let id = try XCTUnwrap((created["task"] as? [String: Any])?["id"] as? String)
        _ = try call("update_task", ["id": id, "status": "done"])
        clock.value = clock.value.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(store.moveCompletedToDoneLog(before: clock.value.addingTimeInterval(-86_400)), 1)

        XCTAssertEqual(titles(try call("list_tasks", ["state": "done"])), [], "the Done log is opt-in")
        let logged = try call("list_tasks", ["state": "done", "include_done_log": true])
        XCTAssertEqual(titles(logged), ["Ship it"])
        XCTAssertNotNil((logged["tasks"] as? [[String: Any]])?.first?["done_logged_at"])

        XCTAssertTrue(error("update_task", ["id": id, "title": "Rename"]).contains("Done log"))
        let back = try call("update_task", ["id": id, "state": "inProgress", "priority": "high"])
        let task = try XCTUnwrap(back["task"] as? [String: Any])
        XCTAssertEqual(task["status"] as? String, "inProgress")
        XCTAssertEqual(task["priority"] as? String, "high")
        XCTAssertNil(task["done_logged_at"])
        XCTAssertEqual(store.doneLogCount(), 0)
    }
}
