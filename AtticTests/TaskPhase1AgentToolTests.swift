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
    private func archivedFamily(in store: TaskStore) throws -> (UUID, UUID) {
        let parent = try XCTUnwrap(store.create(title: "Parent", priority: .low))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(store.update(parent, tags: ["old"], dueDay: .some(DueDay(rawValue: "2026-09-22"))))
        XCTAssertTrue(store.completeFamily(taskID: parent.id))
        XCTAssertEqual(store.moveCompletedToDoneLog(before: clock.value.addingTimeInterval(86_400)), 2)
        return (parent.id, child.id)
    }

    func testFailedArchivedCompoundUpdatePreservesFamilyAndHistory() throws {
        let gate = PersistenceGate()
        store = try makeTestStore(now: { [clock] in clock.value }, persist: gate.save)
        library = AtticLibrary(tasks: store)
        tools = AgentTaskTools(store: store, library: library)
        let (parentID, _) = try archivedFamily(in: store)
        func durableRows() throws -> [TaskItem] {
            try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
                .sorted { $0.id.uuidString < $1.id.uuidString }
        }
        let before = try durableRows().map(TaskEditableState.init)
        let logging = try durableRows().map(\.doneLoggedAt)
        let updated = try durableRows().map(\.updatedAt)
        let history = library.undo.undoName(in: .tasks)
        let saves = gate.saveCount
        gate.shouldFail = true
        XCTAssertFalse(error("update_task", ["id": parentID.uuidString, "state": "inProgress",
                                             "title": "Changed", "priority": "high", "tags": ["new"], "due": NSNull()]).isEmpty)
        XCTAssertEqual(try durableRows().map(TaskEditableState.init), before)
        XCTAssertEqual(try durableRows().map(\.doneLoggedAt), logging)
        XCTAssertEqual(try durableRows().map(\.updatedAt), updated)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(library.undo.undoName(in: .tasks), history)
        XCTAssertEqual(gate.saveCount, saves)
    }

    func testArchivedCompoundUpdateUsesOneSaveAndOneHistoryStep() throws {
        let gate = PersistenceGate()
        store = try makeTestStore(now: { [clock] in clock.value }, persist: gate.save)
        library = AtticLibrary(tasks: store)
        tools = AgentTaskTools(store: store, library: library)
        let (parentID, childID) = try archivedFamily(in: store)
        let before = try XCTUnwrap(store.listedEditableState(of: parentID))
        let loggedAt = try XCTUnwrap(store.listedTask(withID: parentID)?.doneLoggedAt)
        let childBefore = try XCTUnwrap(store.listedEditableState(of: childID))
        let saves = gate.saveCount
        _ = try call("update_task", ["id": parentID.uuidString, "state": "inProgress", "title": "Changed",
                                    "priority": "high", "tags": ["new"], "due": NSNull()])
        XCTAssertEqual(gate.saveCount, saves + 1)
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        let parent = try XCTUnwrap(rows.first { $0.id == parentID })
        XCTAssertEqual(parent.title, "Changed")
        XCTAssertEqual(parent.status, .inProgress)
        XCTAssertEqual(parent.priority, .high)
        XCTAssertEqual(parent.tags, ["new"])
        XCTAssertNil(parent.dueDay)
        XCTAssertNil(parent.completedAt)
        XCTAssertNil(parent.completedFromRaw)
        XCTAssertNil(parent.completedFromOrder)
        XCTAssertTrue(rows.allSatisfy { $0.doneLoggedAt == nil })
        XCTAssertEqual(store.editableState(of: childID), childBefore)
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(store.listedEditableState(of: parentID), before)
        XCTAssertEqual(store.listedTask(withID: parentID)?.doneLoggedAt, loggedAt)
        XCTAssertEqual(store.listedEditableState(of: childID), childBefore)
        XCTAssertNil(library.undo.undoName(in: .tasks), "one undo reverses the whole compound step")
        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertEqual(store.task(withID: parentID)?.title, "Changed")
        XCTAssertNil(store.task(withID: childID)?.doneLoggedAt)
    }

    func testArchivedCompoundUpdateSucceedsWhenOnlyOneSaveCanCommit() throws {
        // The original split restore/edit path committed its first save,
        // then failed its second. This test catches that on its own through
        // the command result and durable fields, without counting saves.
        var savesRemaining: Int?
        store = try makeTestStore(now: { [clock] in clock.value }, persist: { context in
            if let remaining = savesRemaining {
                guard remaining > 0 else { throw PersistenceGate.Failure() }
                savesRemaining = remaining - 1
            }
            try context.save()
        })
        library = AtticLibrary(tasks: store)
        tools = AgentTaskTools(store: store, library: library)
        let (parentID, childID) = try archivedFamily(in: store)
        let childBefore = try XCTUnwrap(store.listedEditableState(of: childID))
        savesRemaining = 1
        let result = try call("update_task", ["id": parentID.uuidString, "state": "inProgress",
                                               "title": "Changed", "priority": "high", "tags": ["new"], "due": NSNull()])
        XCTAssertEqual((result["task"] as? [String: Any])?["title"] as? String, "Changed")
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        let parent = try XCTUnwrap(rows.first { $0.id == parentID })
        XCTAssertEqual(parent.title, "Changed")
        XCTAssertEqual(parent.status, .inProgress)
        XCTAssertEqual(parent.priority, .high)
        XCTAssertEqual(parent.tags, ["new"])
        XCTAssertNil(parent.dueDay)
        XCTAssertNil(parent.completedAt)
        XCTAssertNil(parent.completedFromRaw)
        XCTAssertNil(parent.completedFromOrder)
        XCTAssertTrue(rows.allSatisfy { $0.doneLoggedAt == nil })
        XCTAssertEqual(rows.first { $0.id == childID }.map(TaskEditableState.init), childBefore)
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Change Task State")
    }

    func testCommittedArchivedUpdateReportsSuccessAndRetriesFailedListRefresh() throws {
        let (parentID, childID) = try archivedFamily(in: store)
        let before = try XCTUnwrap(store.listedEditableState(of: parentID))
        let childBefore = try XCTUnwrap(store.listedEditableState(of: childID))
        let loggedAt = try XCTUnwrap(store.listedTask(withID: parentID)?.doneLoggedAt)
        store.listRefreshFailures = 1
        let result = try call("update_task", ["id": parentID.uuidString, "state": "inProgress", "title": "Committed"])
        XCTAssertNotNil(result["task"], "a committed command must not invite an agent retry")
        XCTAssertEqual(store.listRefreshFailures, 0)
        let shown = try XCTUnwrap(store.tasks.first { $0.id == parentID })
        XCTAssertEqual(shown.title, "Committed", "the scheduled retry publishes the durable update without an unrelated refresh")
        XCTAssertEqual(shown.status, .inProgress)
        XCTAssertTrue(shown === store.task(withID: parentID), "list and family readers agree after the retry")
        XCTAssertNil(store.errorNotice, "a successful retry clears the presentation warning")
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Change Task State", "the recovered after-state retains the compound Undo")
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        let parent = try XCTUnwrap(rows.first { $0.id == parentID })
        XCTAssertEqual(parent.title, "Committed")
        XCTAssertEqual(parent.status, .inProgress)
        XCTAssertTrue(rows.allSatisfy { $0.doneLoggedAt == nil })
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertEqual(store.listedEditableState(of: parentID), before)
        XCTAssertEqual(store.listedEditableState(of: childID), childBefore)
        XCTAssertEqual(store.listedTask(withID: parentID)?.doneLoggedAt, loggedAt)
        XCTAssertEqual(store.listedTask(withID: childID)?.doneLoggedAt, loggedAt)
        XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
        XCTAssertEqual(store.task(withID: parentID)?.title, "Committed")
    }

    func testCompoundRedoIsDroppedWhenUndoCannotReturnChangedFamilyToDoneLog() throws {
        let gate = PersistenceGate()
        store = try makeTestStore(now: { [clock] in clock.value }, persist: gate.save)
        library = AtticLibrary(tasks: store)
        tools = AgentTaskTools(store: store, library: library)
        let (parentID, childID) = try archivedFamily(in: store)
        let before = try XCTUnwrap(store.listedEditableState(of: parentID))
        _ = try call("update_task", ["id": parentID.uuidString, "state": "inProgress", "title": "Changed"])
        let child = try XCTUnwrap(store.task(withID: childID))
        XCTAssertTrue(store.update(child, status: .todo), "a later child change prevents family rearchiving")
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertEqual(store.editableState(of: parentID), before, "Undo still restores the edited fields")
        XCTAssertNil(store.task(withID: parentID)?.doneLoggedAt)
        XCTAssertEqual(store.task(withID: childID)?.status, .todo)
        let saves = gate.saveCount
        XCTAssertEqual(library.undo.redoStep(in: .tasks), .obsolete)
        XCTAssertNil(library.undo.redoName(in: .tasks))
        XCTAssertNil(library.undo.redoStep(in: .tasks), "the obsolete compound step cannot repeatedly fail")
        XCTAssertEqual(gate.saveCount, saves)
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.first { $0.id == parentID }.map(TaskEditableState.init), before)
        XCTAssertTrue(rows.allSatisfy { $0.doneLoggedAt == nil })
    }

    func testDoneLogReadFailureStopsAfterOneReadAndExplicitRetryWorks() throws {
        _ = try archivedFamily(in: store)
        store.doneLogReadFailures = 10_000
        let start = Date()
        XCTAssertThrowsError(try call("list_tasks", ["include_done_log": true])) { error in
            guard case AgentToolError.storeFailure = error else {
                return XCTFail("Expected a store failure, got \(error)")
            }
        }
        XCTAssertEqual(store.doneLogReadFailures, 9_999, "no implicit retry on the main actor")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        store.doneLogReadFailures = 0
        XCTAssertEqual(Set(titles(try call("list_tasks", ["include_done_log": true]))), ["Parent", "Child"])
    }

    func testDoneLogChildReadFailuresAreErrorsAndExplicitRetryWorks() throws {
        _ = try archivedFamily(in: store)
        func check(_ arguments: [String: Any], expected: Set<String>) throws {
            for skip in [0, 1] {
                store.doneFamilyReadsToSkipBeforeFailing = skip
                XCTAssertThrowsError(try call("list_tasks", arguments)) { error in
                    guard case AgentToolError.storeFailure = error else {
                        return XCTFail("Expected a store failure, got \(error)")
                    }
                }
                XCTAssertEqual(Set(titles(try call("list_tasks", arguments))), expected)
            }
        }
        try check(["include_done_log": true], expected: ["Parent", "Child"])
        // parent_id currently accepts live main tasks only. Exercise its
        // throwing Done-log child read without changing that validation.
        let parent = try XCTUnwrap(store.create(title: "Live parent"))
        _ = try XCTUnwrap(store.create(title: "Live child", parentID: parent.id))
        try check(["include_done_log": true, "parent_id": parent.id.uuidString], expected: ["Live child"])
    }

    func testChildOnlyReopeningRefusesCompletedParentReplicasWithoutMutatingFamily() throws {
        for archived in [false, true] {
            for divergent in [false, true] {
                let gate = PersistenceGate()
                store = try makeTestStore(now: { [clock] in clock.value }, persist: gate.save)
                library = AtticLibrary(tasks: store)
                tools = AgentTaskTools(store: store, library: library)
                let parent = try XCTUnwrap(store.create(title: "Parent"))
                let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
                XCTAssertTrue(store.completeFamily(taskID: parent.id))
                if archived {
                    XCTAssertEqual(store.moveCompletedToDoneLog(before: clock.value.addingTimeInterval(86_400)), 2)
                }
                if divergent {
                    // Presentation picks this open copy; the hidden Done
                    // replica must still block reopening the child.
                    let context = ModelContext(store.container)
                    let copy = TaskItem(id: parent.id, title: "Open parent replica", status: .todo,
                                        createdAt: clock.value, updatedAt: clock.value.addingTimeInterval(10))
                    copy.listOrderVersion = TaskItem.currentListOrderVersion
                    copy.manualOrder = parent.manualOrder
                    copy.doneLoggedAt = store.listedTask(withID: parent.id)?.doneLoggedAt
                    context.insert(copy)
                    try context.save()
                    store.refresh()
                    XCTAssertEqual(store.listedTask(withID: parent.id)?.status, .todo)
                }
                func durableRows() throws -> [TaskItem] {
                    try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>()).sorted { $0.title < $1.title }
                }
                let before = try durableRows().map(TaskEditableState.init)
                let logging = try durableRows().map(\.doneLoggedAt)
                let updated = try durableRows().map(\.updatedAt)
                let saves = gate.saveCount
                let arguments: [String: Any] = ["id": child.id.uuidString, "state": "todo", "title": "Changed",
                                                "priority": "high", "tags": ["new"], "due": "2026-09-30"]
                XCTAssertTrue(error("update_task", arguments).contains("Reopen the main task"))
                XCTAssertFalse(library.restoreToNow(child.id).isApplied, "standalone restore has the same guard")
                XCTAssertEqual(try durableRows().map(TaskEditableState.init), before)
                XCTAssertEqual(try durableRows().map(\.doneLoggedAt), logging)
                XCTAssertEqual(try durableRows().map(\.updatedAt), updated)
                XCTAssertEqual(gate.saveCount, saves, "refuse before saving")
                XCTAssertNil(library.undo.undoName(in: .tasks))
                if !divergent {
                    _ = try call("update_task", ["id": parent.id.uuidString, "state": "todo"])
                    _ = try call("update_task", arguments)
                    XCTAssertEqual(store.task(withID: child.id)?.status, .todo)
                    XCTAssertEqual(store.task(withID: child.id)?.title, "Changed")
                }
            }
        }
    }

}
