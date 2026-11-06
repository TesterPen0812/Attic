import XCTest
import SwiftData
@testable import Attic

@MainActor
final class AgentActionsTests: XCTestCase {
    private struct Fixture {
        let actions: AgentActions
        let store: TaskStore
        let library: AtticLibrary
        let draw: DrawInMemoryStore
        let backend: FakeCalendarEventWriteStore
        let source: CalendarEventSourceStub
    }

    private func fixture(openPage: ((AgentPage) -> Bool)? = nil) throws -> Fixture {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let backend = FakeCalendarEventWriteStore()
        backend.availableCalendars = [CalendarWriteCalendar(
            id: "home", title: "Home", colour: .init(red: 0.2, green: 0.5, blue: 0.8),
            sourceID: "local", sourceTitle: "Local", isWritable: true)]
        let writer = EventKitCalendarEventWriter(store: backend, record: try CalendarOwnershipRecord(),
                                                 undoRoute: library.undo)
        let source = CalendarEventSourceStub()
        let draw = DrawInMemoryStore()
        let actions = AgentActions(tasks: AgentTaskTools(store: store, library: library),
                                   calendarSource: source, calendarWriter: writer, draw: draw,
                                   openPage: openPage)
        return Fixture(actions: actions, store: store, library: library, draw: draw,
                       backend: backend, source: source)
    }

    private func performed(_ output: AgentActionCall, file: StaticString = #filePath,
                           line: UInt = #line) throws -> AgentActionResult {
        guard case let .performed(result) = output else {
            XCTFail("Expected a performed action", file: file, line: line)
            throw AgentActionsError.invalid("Expected a performed action")
        }
        return result
    }

    private func approval(_ output: AgentActionCall, file: StaticString = #filePath,
                          line: UInt = #line) throws -> AgentApproval {
        guard case let .approvalNeeded(value) = output else {
            XCTFail("Expected approval", file: file, line: line)
            throw AgentActionsError.invalid("Expected approval")
        }
        return value
    }

    private func payload(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func mcp(_ handler: MCPRequestHandler, _ method: String,
                     params: [String: Any] = [:], token: String? = nil) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 71, "method": method, "params": params
        ])
        let response = await handler.handleAsync(body: data, runToken: token)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(response.body)) as? [String: Any])
    }

    private func mcpTool(_ handler: MCPRequestHandler, _ name: String,
                         args: [String: Any] = [:], token: String? = nil) async throws -> [String: Any] {
        let response = try await mcp(handler, "tools/call", params: ["name": name, "arguments": args], token: token)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "\(name) should succeed")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try payload(text)
    }

    func testDefinitionsAreClosedAndApprovalPolicyIsCodeEnforced() throws {
        let f = try fixture()
        let defs = f.actions.definitions
        let names = Set(defs.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["list_tasks", "create_task", "open_page", "calendar_search",
                                             "calendar_read", "calendar_create", "calendar_update", "calendar_delete",
                                             "draw_list_canvases", "draw_add_text", "draw_add_shape", "draw_add_strokes"]))
        for definition in defs {
            let schema = try XCTUnwrap(definition["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        }
        for name in ["delete_task", "delete_note", "delete_item", "calendar_create", "calendar_update", "calendar_delete"] {
            XCTAssertTrue(AgentActionApprovalPolicy.requiresApproval(name, arguments: [:]), name)
        }
        XCTAssertTrue(AgentActionApprovalPolicy.requiresApproval("update_note_table", arguments: [
            "operations": [["op": "delete_row"]]]))
        XCTAssertFalse(AgentActionApprovalPolicy.requiresApproval("update_note_table", arguments: [
            "operations": [["op": "set_cell"]]]))
        XCTAssertFalse(AgentActionApprovalPolicy.requiresApproval("create_task", arguments: ["title": "Delete everything"]),
                       "Task or note text never authorizes an action")
        XCTAssertFalse(names.contains("resolve_approval"), "The model must not have an approval tool")
    }

    func testApprovedTaskDeletionAndUndoReachEveryPhysicalUUIDReplica() async throws {
        let f = try fixture()
        let id = UUID()
        let context = ModelContext(f.store.container)
        let timestamp = Date(timeIntervalSince1970: 2_000)
        context.insert(TaskItem(id: id, title: "Same", updatedAt: timestamp))
        context.insert(TaskItem(id: id, title: "Same", updatedAt: timestamp))
        try context.save()
        f.store.refresh()
        let request = f.actions.beginRequest(title: "Deletion with replicas")
        let pending = try approval(await f.actions.call(name: "delete_task",
            arguments: ["id": id.uuidString], watching: false, requestID: request))
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == id && $0.deletedAt == nil }.count, 2)
        let resolved = try await f.actions.resolve(approval: pending.id, allow: true)
        XCTAssertEqual(resolved?.step.targets.first?.itemID, id)
        let fresh = ModelContext(f.store.container)
        let deleted = try fresh.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == id }
        XCTAssertEqual(deleted.count, 2)
        XCTAssertTrue(deleted.allSatisfy { $0.deletedAt != nil })
        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 1)
        let afterUndo = ModelContext(f.store.container)
        XCTAssertEqual(try afterUndo.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == id && $0.deletedAt == nil }.count, 2)
    }

    func testOpenPageNeverNavigatesInBackground() async throws {
        var opened: [AgentPage] = []
        let f = try fixture(openPage: { opened.append($0); return true })
        let request = f.actions.beginRequest(title: "Navigation")
        do {
            _ = try await f.actions.call(name: "open_page", arguments: ["page": "calendar"],
                                         watching: false, requestID: request)
            XCTFail("Background navigation must fail")
        } catch {}
        XCTAssertTrue(opened.isEmpty)
        let result = try performed(await f.actions.call(name: "open_page", arguments: ["page": "calendar"],
                                                        watching: true, requestID: request))
        XCTAssertEqual(opened, [.calendar])
        XCTAssertEqual(result.step.kind, .openPage)
        XCTAssertEqual(result.step.targets.first?.page, .calendar)
        XCTAssertNil(result.changeSet)
    }

    func testCalendarSearchAndReadUseOnlyFakeSource() async throws {
        let f = try fixture()
        let date = Date(timeIntervalSince1970: 1_793_361_600)
        let occurrenceID = "fixture@\(date.timeIntervalSinceReferenceDate)"
        f.source.replace([CalendarEvent(id: occurrenceID, title: "Writing", start: date,
                                        end: date.addingTimeInterval(3600), isAllDay: false,
                                        location: "Room", calendarTitle: "Home",
                                        colour: .init(red: 0.1, green: 0.2, blue: 0.3))])
        let request = f.actions.beginRequest(title: "Read events")
        let search = try performed(await f.actions.call(name: "calendar_search", arguments: [
            "query": "Writing", "start": iso(date.addingTimeInterval(-3600)),
            "end": iso(date.addingTimeInterval(7200))], watching: false, requestID: request))
        XCTAssertEqual(try payload(search.text)["count"] as? Int, 1)
        XCTAssertEqual(search.step.targets.first?.externalID, occurrenceID)
        let read = try performed(await f.actions.call(name: "calendar_read", arguments: [
            "occurrence_id": occurrenceID], watching: false, requestID: request))
        XCTAssertEqual((try payload(read.text)["event"] as? [String: Any])?["title"] as? String, "Writing")
        XCTAssertTrue(f.backend.events.isEmpty)
    }

    func testCalendarWritesNeedRealResolutionAndUndoWithFakeWriter() async throws {
        let f = try fixture()
        let request = f.actions.beginRequest(title: "Calendar change")
        let date = Date(timeIntervalSince1970: 1_793_361_600)
        let args: [String: Any] = ["title": "Lunch", "start": iso(date),
                                  "end": iso(date.addingTimeInterval(3600)), "calendar_id": "home"]
        let pending = try approval(await f.actions.call(name: "calendar_create", arguments: args,
                                                         watching: false, requestID: request))
        XCTAssertTrue(f.backend.events.isEmpty)
        let denied = try await f.actions.resolve(approval: pending.id, allow: false)
        XCTAssertNil(denied)
        let allowed = try approval(await f.actions.call(name: "calendar_create", arguments: args,
                                                         watching: false, requestID: request))
        let resolved = try await f.actions.resolve(approval: allowed.id, allow: true)
        let created = try XCTUnwrap(resolved)
        let id = try XCTUnwrap(payload(created.text)["id"] as? String)
        XCTAssertEqual(created.step.targets.first?.itemID?.uuidString, id)
        XCTAssertEqual(f.backend.events.count, 1)
        var edited = args
        edited["title"] = "Dinner"
        edited["id"] = id
        let edit = try approval(await f.actions.call(name: "calendar_update", arguments: edited,
                                                      watching: true, requestID: request))
        _ = try await f.actions.resolve(approval: edit.id, allow: true)
        XCTAssertEqual(f.backend.events.values.first?.draft.title, "Dinner")
        let deletion = try approval(await f.actions.call(name: "calendar_delete", arguments: ["id": id],
                                                          watching: true, requestID: request))
        _ = try await f.actions.resolve(approval: deletion.id, allow: true)
        XCTAssertTrue(f.backend.events.isEmpty)
        XCTAssertEqual(f.actions.changeSet(for: request)?.count, 3)
        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 3)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertTrue(f.backend.events.isEmpty)
    }

    func testUndoWaitsForPendingOwnerApprovalBeforeReversingRequest() async throws {
        let f = try fixture()
        let request = f.actions.beginRequest(title: "Mixed request")
        let created = try performed(await f.actions.call(name: "create_task", arguments: ["title": "First"],
                                                         watching: false, requestID: request))
        let start = Date(timeIntervalSince1970: 1_793_361_600)
        let pending = try approval(await f.actions.call(name: "calendar_create", arguments: [
            "title": "Maybe", "start": iso(start), "end": iso(start.addingTimeInterval(600)), "calendar_id": "home"
        ], watching: false, requestID: request))
        let blocked = await f.actions.undo(changeSet: request)
        XCTAssertEqual(blocked.undone, 0)
        XCTAssertEqual(blocked.failures.count, 1)
        XCTAssertNotNil(f.store.task(withID: try XCTUnwrap(created.step.targets.first?.itemID)))
        _ = try await f.actions.resolve(approval: pending.id, allow: false)
        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 1)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertTrue(f.store.tasks.isEmpty)
    }

    func testDrawListAndEachAddActionReturnsRealObjectTargetAndUndoes() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Sketch")
        let existing = DrawObject(content: .text("Existing"))
        XCTAssertTrue(f.draw.perform(.put([existing]), on: canvas.id).isSaved)
        let request = f.actions.beginRequest(title: "Draw")
        let listing = try performed(await f.actions.call(name: "draw_list_canvases", arguments: [:],
                                                         watching: false, requestID: request))
        XCTAssertEqual(listing.step.targets.first?.itemID, canvas.id)
        let base: [String: Any] = ["canvas_id": canvas.id.uuidString]
        let cases: [(String, [String: Any])] = [
            ("draw_add_text", base.merging(["text": "Hello", "x": 10, "y": 20]) { _, rhs in rhs }),
            ("draw_add_shape", base.merging(["shape": "rectangle", "x": 12, "y": 30,
                                              "width": 120, "height": 40]) { _, rhs in rhs }),
            ("draw_add_strokes", base.merging(["points": [["x": 0, "y": 0], ["x": 20, "y": 30]]]) { _, rhs in rhs })
        ]
        for (name, args) in cases {
            let result = try performed(await f.actions.call(name: name, arguments: args,
                                                             watching: false, requestID: request))
            XCTAssertEqual(result.step.targets.first?.containerID, canvas.id)
            XCTAssertEqual(result.step.targets.first?.itemID?.uuidString,
                           try payload(result.text)["object_id"] as? String)
        }
        XCTAssertEqual(try f.draw.open(canvas.id).objects.count, 4)
        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 3)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertEqual(try f.draw.open(canvas.id).objects.map(\.id), [existing.id])
    }

    func testJournalReversesTaskAndDrawAcrossPagesNewestFirst() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Board")
        XCTAssertTrue(f.draw.perform(.put([DrawObject(content: .text("base"))]), on: canvas.id).isSaved)
        let request = f.actions.beginRequest(title: "Plan")
        let created = try performed(await f.actions.call(name: "create_task", arguments: ["title": "Write outline"],
                                                         watching: false, requestID: request))
        let taskID = try XCTUnwrap(created.step.targets.first?.itemID)
        _ = try await f.actions.call(name: "draw_add_text", arguments: ["canvas_id": canvas.id.uuidString,
                                                                        "text": "Outline", "x": 20, "y": 20],
                                     watching: false, requestID: request)
        XCTAssertEqual(f.actions.changeSet(for: request)?.pages, Set([.tasks, .draw]))
        XCTAssertEqual(f.actions.changeSet(for: request)?.count, 2)
        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 2)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertNil(f.store.task(withID: taskID))
        XCTAssertEqual(try f.draw.open(canvas.id).objects.count, 1)
    }

    func testFailedMiddleActionLeavesPriorAndLaterChangesJournalled() async throws {
        let f = try fixture()
        let request = f.actions.beginRequest(title: "Three steps")
        _ = try await f.actions.call(name: "create_task", arguments: ["title": "One"],
                                     watching: false, requestID: request)
        do {
            _ = try await f.actions.call(name: "draw_add_shape", arguments: ["canvas_id": UUID().uuidString,
                                                                            "shape": "hexagon", "x": 0, "y": 0,
                                                                            "width": 10, "height": 10],
                                         watching: false, requestID: request)
            XCTFail("Invalid Draw edit must fail")
        } catch {}
        _ = try await f.actions.call(name: "create_task", arguments: ["title": "Two"],
                                     watching: false, requestID: request)
        XCTAssertEqual(f.actions.changeSet(for: request)?.count, 2)
        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 2)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertTrue(f.store.tasks.isEmpty)
    }

    func testUndoKeepsSuccessfulPagesWhenDrawConflicts() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Shared canvas")
        let request = f.actions.beginRequest(title: "Two pages")
        let task = try performed(await f.actions.call(name: "create_task", arguments: ["title": "Keep undo safe"],
                                                         watching: false, requestID: request))
        _ = try await f.actions.call(name: "draw_add_shape", arguments: [
            "canvas_id": canvas.id.uuidString, "shape": "ellipse", "x": 0, "y": 0,
            "width": 20, "height": 20], watching: false, requestID: request)
        // A person edits Draw after the agent's step: Undo must not erase it.
        XCTAssertTrue(f.draw.perform(.put([DrawObject(content: .text("Owner addition"))]),
                                     on: canvas.id).isSaved)
        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 1)
        XCTAssertEqual(undone.failures.count, 1)
        XCTAssertEqual(undone.remaining?.count, 1)
        XCTAssertNil(f.store.task(withID: try XCTUnwrap(task.step.targets.first?.itemID)))
        XCTAssertEqual(try f.draw.open(canvas.id).objects.count, 2)
    }

    func testUndoRestoresTwoEditsToOneNoteInReverseOrder() async throws {
        let tasks = try makeTestStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: tasks, notes: notes)
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: library)
        let actions = AgentActions(tasks: tools)
        let original = try payload(tools.call(name: "create_note", arguments: [
            "title": "Original", "body": "Before"]))
        let row = try XCTUnwrap(original["note"] as? [String: Any])
        let id = try XCTUnwrap(row["id"] as? String)
        let request = actions.beginRequest(title: "Two edits")
        for (title, body) in [("First title", "First"), ("Second title", "Second")] {
            let revision = try XCTUnwrap(notes.note(withID: try XCTUnwrap(UUID(uuidString: id)))?.revisionToken)
            _ = try performed(await actions.call(name: "update_note", arguments: [
                "id": id, "base_revision": revision, "title": title, "body": body],
                watching: false, requestID: request))
        }
        XCTAssertEqual(actions.changeSet(for: request)?.count, 2)
        let result = await actions.undo(changeSet: request)
        XCTAssertEqual(result.undone, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(notes.note(withID: try XCTUnwrap(UUID(uuidString: id)))?.body, "Before")
        XCTAssertEqual(notes.note(withID: try XCTUnwrap(UUID(uuidString: id)))?.title, "Original")
    }

    func testUndoDiscardsUnappliedNoteProposalWithoutTouchingSavedContent() async throws {
        let tasks = try makeTestStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: AtticLibrary(tasks: tasks, notes: notes))
        let actions = AgentActions(tasks: tools)
        let original = try payload(tools.call(name: "create_note", arguments: ["title": "Saved", "body": "Owner text"]))
        let row = try XCTUnwrap(original["note"] as? [String: Any])
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(row["id"] as? String)))
        let revision = try XCTUnwrap(notes.note(withID: id)?.revisionToken)
        notes.agentWriteDisposition = { _ in .proposal }

        let request = actions.beginRequest(title: "Proposed writing")
        let result = try performed(await actions.call(name: "update_note", arguments: [
            "id": id.uuidString, "base_revision": revision, "body": "Agent proposal"
        ], watching: false, requestID: request))
        XCTAssertEqual(try payload(result.text)["status"] as? String, "pending")
        XCTAssertEqual(actions.changeSet(for: request)?.count, 1)
        XCTAssertEqual(notes.pendingEdits(noteID: id).count, 1)
        let undone = await actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 1)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertTrue(notes.pendingEdits(noteID: id).isEmpty)
        XCTAssertEqual(notes.note(withID: id)?.body, "Owner text")
    }

    func testUndoRefusesToReverseNewerOwnerEdit() async throws {
        let f = try fixture()
        let request = f.actions.beginRequest(title: "One task")
        _ = try await f.actions.call(name: "create_task", arguments: ["title": "Agent"],
                                     watching: false, requestID: request)
        XCTAssertNotNil(f.library.createTasks([TaskDraft(title: "Owner")]))
        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 0)
        XCTAssertEqual(undone.failures.count, 1)
        XCTAssertEqual(f.store.tasks.count, 2)
        XCTAssertNotNil(undone.remaining)
    }

    func testMCPRunDiscoveryPreservesUnscopedExternalClients() async throws {
        let f = try fixture()
        let handler = MCPRequestHandler(tools: f.actions.tasks, actions: f.actions, serverVersion: "test",
                                        approvalWait: 0)
        let legacy = try await mcp(handler, "tools/list")
        let legacyNames = try XCTUnwrap((legacy["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            .compactMap { $0["name"] as? String }
        XCTAssertTrue(legacyNames.contains("create_task"))
        XCTAssertFalse(legacyNames.contains("open_page"))
        XCTAssertFalse(legacyNames.contains("agent_approval_status"))

        let token = try handler.beginAgentRun(title: "Agent in Attic", watching: true)
        let headers = ["host": "127.0.0.1:7335", "authorization": "Bearer \(token)"]
        XCTAssertEqual(handler.runActions?.authorizedRunToken(headers: headers), token)
        XCTAssertNil(handler.runActions?.authorizedRunToken(headers: [
            "host": "127.0.0.1:7335", "authorization": "Bearer \(UUID().uuidString)"]))
        let scoped = try await mcp(handler, "tools/list", token: token)
        let definitions = try XCTUnwrap((scoped["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(definitions.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["list_tasks", "create_task", "open_page", "calendar_search",
                                              "calendar_read", "calendar_create", "calendar_update", "calendar_delete",
                                              "draw_list_canvases", "draw_add_text", "draw_add_shape", "draw_add_strokes",
                                              "agent_approval_status"]))
        for definition in definitions {
            XCTAssertEqual((definition["inputSchema"] as? [String: Any])?["additionalProperties"] as? Bool, false)
        }

        // External clients still call the original tool path and response shape.
        let external = try await mcp(handler, "tools/call", params: [
            "name": "create_task", "arguments": ["title": "Legacy client"]])
        let result = try XCTUnwrap(external["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertNotNil(f.store.tasks.first)
        XCTAssertNil(handler.runChangeSet(token: token))
    }

    func testMCPRunTokenBindsWatchingTargetsAndCrossPageUndo() async throws {
        var opened: [AgentPage] = []
        let f = try fixture(openPage: { opened.append($0); return true })
        let handler = MCPRequestHandler(tools: f.actions.tasks, actions: f.actions, approvalWait: 0)
        let first = try handler.beginAgentRun(title: "First", watching: false)
        let second = try handler.beginAgentRun(title: "Second", watching: true)

        let background = try await mcp(handler, "tools/call", params: [
            "name": "open_page", "arguments": ["page": "calendar"]], token: first)
        XCTAssertEqual((background["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(opened.isEmpty)
        try handler.setWatching(true, runToken: first)
        let openedPage = try await mcpTool(handler, "open_page", args: ["page": "calendar"], token: first)
        XCTAssertEqual((openedPage["step"] as? [String: Any])?["kind"] as? String, "openPage")
        XCTAssertEqual(opened, [.calendar])

        let canvas = f.draw.create(name: "Plan")
        let task = try await mcpTool(handler, "create_task", args: ["title": "A step"], token: first)
        let target = try XCTUnwrap((task["step"] as? [String: Any])?["targets"] as? [[String: Any]])
        let taskID = try XCTUnwrap(target.first?["item_id"] as? String)
        _ = try await mcpTool(handler, "draw_add_text", args: [
            "canvas_id": canvas.id.uuidString, "text": "A step", "x": 10, "y": 10], token: first)
        let set = try XCTUnwrap(handler.runChangeSet(token: first))
        XCTAssertEqual(set.pages, Set([.tasks, .draw]))
        XCTAssertEqual(set.count, 2)
        XCTAssertNil(handler.runChangeSet(token: second))
        do {
            _ = try await handler.undoRunChangeSet(id: set.id, token: second)
            XCTFail("Another run must not undo this change set")
        } catch {}
        let undone = try await handler.undoRunChangeSet(id: set.id, token: first)
        XCTAssertEqual(undone.undone, 2)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertNil(f.store.task(withID: try XCTUnwrap(UUID(uuidString: taskID))))
        XCTAssertTrue(try f.draw.open(canvas.id).objects.isEmpty)
    }

    func testMCPApprovalSurvivesPollingAndOnlyOwnerCanResolve() async throws {
        let f = try fixture()
        let handler = MCPRequestHandler(tools: f.actions.tasks, actions: f.actions, approvalWait: 0)
        let run = try handler.beginAgentRun(title: "Calendar", watching: false)
        let another = try handler.beginAgentRun(title: "Other", watching: false)
        let now = Date(timeIntervalSince1970: 1_793_361_600)
        let args: [String: Any] = ["title": "Approved event", "start": iso(now),
                                   "end": iso(now.addingTimeInterval(1800)), "calendar_id": "home"]
        let first = try await mcpTool(handler, "calendar_create", args: args, token: run)
        XCTAssertEqual(first["status"] as? String, "waiting")
        let id = try XCTUnwrap((first["approvalNeeded"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(f.backend.events.isEmpty)
        XCTAssertEqual(handler.runApprovals(token: run).count, 1)
        let retry = try await mcpTool(handler, "calendar_create", args: args, token: run)
        XCTAssertEqual(retry["approval_id"] as? String, id)
        XCTAssertEqual(handler.runApprovals(token: run).count, 1)

        let unknown = try await mcp(handler, "tools/call", params: ["name": "agent_approval_status",
                    "arguments": ["approval_id": id]], token: another)
        XCTAssertEqual((unknown["result"] as? [String: Any])?["isError"] as? Bool, true)
        do {
            try await handler.resolveRunApproval(id: try XCTUnwrap(UUID(uuidString: id)), allow: true, token: another)
            XCTFail("Approval must belong to its run")
        } catch {}
        let waiting = try await mcpTool(handler, "agent_approval_status", args: ["approval_id": id], token: run)
        XCTAssertEqual(waiting["status"] as? String, "waiting")
        try await handler.resolveRunApproval(id: try XCTUnwrap(UUID(uuidString: id)), allow: true, token: run)
        let ready = try await mcpTool(handler, "agent_approval_status", args: ["approval_id": id], token: run)
        XCTAssertEqual(ready["status"] as? String, "done")
        XCTAssertEqual((ready["step"] as? [String: Any])?["kind"] as? String, "create")
        XCTAssertEqual(f.backend.events.count, 1)
        XCTAssertEqual(handler.runChangeSet(token: run)?.count, 1)

        let refused = try await mcpTool(handler, "calendar_delete", args: ["id": UUID().uuidString], token: run)
        let refusedID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(refused["approval_id"] as? String)))
        try await handler.resolveRunApproval(id: refusedID, allow: false, token: run)
        let refusal = try await mcpTool(handler, "agent_approval_status", args: [
            "approval_id": refusedID.uuidString], token: run)
        XCTAssertEqual(refusal["status"] as? String, "refused")
        XCTAssertEqual(f.backend.events.count, 1)
    }

    func testMCPRunShutdownRevokesPendingApprovalAndInvalidatesToken() async throws {
        let f = try fixture()
        let handler = MCPRequestHandler(tools: f.actions.tasks, actions: f.actions, approvalWait: 0)
        let token = try handler.beginAgentRun(title: "Stop", watching: false)
        let date = Date(timeIntervalSince1970: 1_793_361_600)
        let result = try await mcpTool(handler, "calendar_create", args: [
            "title": "Pending", "start": iso(date), "end": iso(date.addingTimeInterval(1800)),
            "calendar_id": "home"], token: token)
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(result["approval_id"] as? String)))
        handler.finishAgentRun(token: token)
        do {
            try await handler.resolveRunApproval(id: id, allow: true, token: token)
            XCTFail("Closed run must reject old approval")
        } catch {}
        let expired = try await mcp(handler, "tools/list", token: token)
        XCTAssertNotNil(expired["error"])
        XCTAssertTrue(f.backend.events.isEmpty)
        let legacy = try await mcp(handler, "tools/list")
        XCTAssertNotNil(legacy["result"])
    }

    func testMCPApprovalHoldsCallUntilOwnerAnswersAndFallsBackToPolling() async throws {
        let f = try fixture()
        let handler = MCPRequestHandler(tools: f.actions.tasks, actions: f.actions, approvalWait: 0.35)
        let token = try handler.beginAgentRun(title: "Owner approval", watching: false)
        let start = Date(timeIntervalSince1970: 1_793_361_600)
        let args: [String: Any] = ["title": "Approved", "start": iso(start),
                                   "end": iso(start.addingTimeInterval(1800)), "calendar_id": "home"]
        let call = Task { try await mcpTool(handler, "calendar_create", args: args, token: token) }
        var requested: AgentApproval?
        for _ in 0..<50 {
            requested = handler.runApprovals(token: token).first
            if requested != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let approval = try XCTUnwrap(requested)
        XCTAssertTrue(f.backend.events.isEmpty)
        try await handler.resolveRunApproval(id: approval.id, allow: true, token: token)
        let completed = try await call.value
        XCTAssertEqual(completed["status"] as? String, "done")
        XCTAssertEqual(f.backend.events.count, 1)

        let waitedFrom = Date()
        let pending = try await mcpTool(handler, "calendar_delete", args: ["id": UUID().uuidString], token: token)
        XCTAssertEqual(pending["status"] as? String, "waiting")
        XCTAssertGreaterThan(Date().timeIntervalSince(waitedFrom), 0.25)
        XCTAssertEqual(pending["poll_tool"] as? String, "agent_approval_status")
        let pendingID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(pending["approval_id"] as? String)))
        try await handler.resolveRunApproval(id: pendingID, allow: false, token: token)
        let refused = try await mcpTool(handler, "agent_approval_status", args: [
            "approval_id": pendingID.uuidString], token: token)
        XCTAssertEqual(refused["status"] as? String, "refused")
        XCTAssertEqual(f.backend.events.count, 1)
    }

    func testEndingRunDuringHeldApprovalCannotPublishResultOrWriteCalendar() async throws {
        let f = try fixture()
        let handler = MCPRequestHandler(tools: f.actions.tasks, actions: f.actions, approvalWait: 2)
        let token = try handler.beginAgentRun(title: "Aborted", watching: false)
        let start = Date(timeIntervalSince1970: 1_793_361_600)
        let args: [String: Any] = ["title": "Must not happen", "start": iso(start),
                                   "end": iso(start.addingTimeInterval(600)), "calendar_id": "home"]
        let task = Task { try await mcp(handler, "tools/call", params: [
            "name": "calendar_create", "arguments": args], token: token) }
        for _ in 0..<50 {
            if !handler.runApprovals(token: token).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(handler.runApprovals(token: token).count, 1)
        handler.finishAgentRun(token: token)
        let response = try await task.value
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(f.backend.events.isEmpty)
    }
}
