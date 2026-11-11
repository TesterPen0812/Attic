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

    #if !ATTIC_GENERATED_TESTS
    func testDurableUndoJournalUsesSandboxSupportWhenNoRootIsInjected() {
        let normal = AppRuntimeEnvironment(environment: [:], bundleIdentifier: "com.taha.Attic.preview.agentpass")
        XCTAssertEqual(normal.agentUndoJournalURL?.lastPathComponent, "AtticAgentUndo.json")
        XCTAssertNotNil(normal.agentUndoJournalURL, "Normal launches must actually persist inverses")
        let testing = AppRuntimeEnvironment(environment: ["ATTIC_UI_TESTING": "1"],
                                            processIdentifier: 42, testRunIdentifier: "agentpass",
                                            bundleIdentifier: "com.taha.Attic.preview.agentpass")
        XCTAssertEqual(testing.agentUndoJournalURL,
                       testing.galleryScratchRoot.appendingPathComponent("AgentUndo.json"))
    }

    func testModesEnforceEveryWriteAtRunBoundaryAndKeepStoresUnchanged() async throws {
        let f = try fixture()
        let context = ModelContext(f.store.container)
        let taskID = UUID()
        context.insert(TaskItem(id: taskID, title: "Protected"))
        try context.save()
        f.store.refresh()
        let canvas = f.draw.create(name: "Protected sketch")
        let handler = MCPRequestHandler(tools: f.actions.tasks, actions: f.actions, approvalWait: 0)
        let token = try handler.beginAgentRun(title: "No changes", watching: true)
        try handler.setMode(.readOnly, runToken: token)
        let listed = try await mcp(handler, "tools/list", token: token)
        let definitions = (listed["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let visible = Set(definitions.compactMap { $0["name"] as? String })
        XCTAssertTrue(visible.contains("list_tasks"))
        XCTAssertFalse(visible.contains("delete_task"))
        XCTAssertFalse(visible.contains("open_page"))
        let writes = f.actions.definitions.compactMap { $0["name"] as? String }
            .filter { !AgentActions.isReadOnlyAction($0) }
        XCTAssertFalse(writes.isEmpty)
        for name in writes {
            let output = try await mcpTool(handler, name, args: [:], token: token)
            XCTAssertEqual(output["status"] as? String, "refused", name)
        }
        XCTAssertEqual(f.store.task(withID: taskID)?.title, "Protected")
        XCTAssertEqual(try f.draw.open(canvas.id).objects.count, 0)
        XCTAssertTrue(f.backend.events.isEmpty)
        XCTAssertNil(handler.runChangeSet(token: token))
    }

    func testAutoDeletesWithoutApprovalAskFirstStillPromptsAndReadOnlyRevokesPending() async throws {
        let f = try fixture()
        let context = ModelContext(f.store.container)
        let taskID = UUID()
        context.insert(TaskItem(id: taskID, title: "Switch modes"))
        try context.save()
        f.store.refresh()
        let handler = MCPRequestHandler(tools: f.actions.tasks, actions: f.actions, approvalWait: 0)
        let token = try handler.beginAgentRun(title: "Modes", watching: false)
        let args = ["id": taskID.uuidString]
        let ask = try await mcpTool(handler, "delete_task", args: args, token: token)
        XCTAssertEqual(ask["status"] as? String, "waiting")
        let waitingID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(ask["approval_id"] as? String)))
        try handler.setMode(.readOnly, runToken: token)
        let refused = try await mcpTool(handler, "agent_approval_status",
                                        args: ["approval_id": waitingID.uuidString], token: token)
        XCTAssertEqual(refused["status"] as? String, "refused")
        XCTAssertNil(f.store.task(withID: taskID)?.deletedAt)
        try handler.setMode(.auto, runToken: token)
        let automatic = try await mcpTool(handler, "delete_task", args: args, token: token)
        XCTAssertEqual(automatic["status"] as? String, "done")
        let persisted = try ModelContext(f.store.container).fetch(FetchDescriptor<TaskItem>())
            .filter { $0.id == taskID }
        XCTAssertEqual(persisted.count, 1)
        XCTAssertNotNil(persisted.first?.deletedAt)
        XCTAssertNotNil(handler.runChangeSet(token: token))
    }

    func testApprovalWordsNameActualTargetsForEveryToolThatCanPrompt() async throws {
        let f = try fixture()
        let id = UUID()
        let context = ModelContext(f.store.container)
        context.insert(TaskItem(id: id, title: "Send the invoice"))
        try context.save()
        f.store.refresh()
        let request = f.actions.beginRequest(title: "Review changes")
        let deletion = try approval(await f.actions.call(name: "delete_task",
            arguments: ["id": id.uuidString], watching: true, requestID: request))
        XCTAssertEqual(deletion.title, "Delete Send the invoice?")
        XCTAssertEqual(deletion.targets.map(\.title), ["Send the invoice"])
        XCTAssertNil(f.store.task(withID: id)?.deletedAt)

        let calendar = try approval(await f.actions.call(name: "calendar_create", arguments: [
            "title": "Dentist", "start": iso(Date(timeIntervalSince1970: 1_793_361_600)),
            "calendar_id": "home"
        ], watching: true, requestID: request))
        XCTAssertEqual(calendar.title, "Add Dentist to Calendar?")
        XCTAssertEqual(calendar.targets.map(\.title), ["Dentist"])
        XCTAssertTrue(f.backend.events.isEmpty)

        let first = AgentTarget(page: .tasks, itemID: UUID(), title: "Pay rent")
        let second = AgentTarget(page: .tasks, itemID: UUID(), title: "Book dentist")
        let batch = [first, second]
        XCTAssertEqual(AgentApprovalWords.title("delete_task", arguments: [:], targets: batch), "Delete 2 tasks?")
        XCTAssertEqual(batch.compactMap(\.title), ["Pay rent", "Book dentist"])
        XCTAssertEqual(AgentApprovalWords.title("delete_item", arguments: ["kind": "canvas"],
                                                targets: [AgentTarget(page: .draw, title: "A"),
                                                          AgentTarget(page: .draw, title: "B")]),
                       "Delete 2 canvases?")
        for (name, args, target, expected) in [
            ("delete_note", [:], AgentTarget(page: .notes, title: "My plan"), "Delete My plan?"),
            ("delete_item", ["kind": "canvas"], AgentTarget(page: .draw, title: "Launch"), "Delete Launch?"),
            ("make_note_checkbox", [:], first, "Move Pay rent into its note?"),
            ("remove_from_tasks", [:], first, "Move Pay rent into Notes?"),
            ("calendar_update", [:], AgentTarget(page: .calendar, title: "Dentist"), "Change Dentist in Calendar?"),
            ("calendar_delete", [:], AgentTarget(page: .calendar, title: "Dentist"), "Delete Dentist from Calendar?")
        ] as [(String, [String: String], AgentTarget, String)] {
            XCTAssertTrue(AgentActionApprovalPolicy.requiresApproval(name, arguments: args), name)
            XCTAssertEqual(AgentApprovalWords.title(name, arguments: args, targets: [target]), expected)
        }
        let tableArgs: [String: Any] = ["operations": [["op": "delete_row"], ["op": "delete_row"]]]
        XCTAssertTrue(AgentActionApprovalPolicy.requiresApproval("update_note_table", arguments: tableArgs))
        XCTAssertEqual(AgentApprovalWords.title("update_note_table", arguments: tableArgs,
                                                targets: [.init(page: .notes, title: "My plan")]),
                       "Delete 2 rows from My plan?")
    }
    #endif

    func testDefinitionsAreClosedAndApprovalPolicyIsCodeEnforced() throws {
        let f = try fixture()
        let defs = f.actions.definitions
        let names = Set(defs.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["list_tasks", "create_task", "create_tasks", "update_tasks",
                                             "search_items", "open_page", "calendar_search",
                                             "calendar_read", "calendar_create", "calendar_update", "calendar_delete",
                                             "draw_list_canvases", "draw_read_canvas", "draw_move_object",
                                             "draw_add_text", "draw_add_shape", "draw_add_strokes"]))
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

    func testCalendarCreateEditDeleteUndoSurvivesNewActionModelWithFakeCalendar() async throws {
        let tasks = try makeTestStore()
        let backend = FakeCalendarEventWriteStore()
        backend.availableCalendars = [CalendarWriteCalendar(
            id: "home", title: "Home", colour: .init(red: 0.2, green: 0.5, blue: 0.8),
            sourceID: "local", sourceTitle: "Local", isWritable: true)]
        let record = try CalendarOwnershipRecord()
        let journal = ownedTemporaryDirectory(prefix: "AgentCalendarUndo").appendingPathComponent("undo.json")
        let library = AtticLibrary(tasks: tasks)
        let writer = EventKitCalendarEventWriter(store: backend, record: record,
                                                 undoRoute: library.undo)
        let actions = AgentActions(tasks: AgentTaskTools(store: tasks,
            library: library), calendarWriter: writer, journalURL: journal)
        let request = actions.beginRequest(title: "Three event changes")
        let start = Date(timeIntervalSince1970: 1_793_361_600)
        let create = try approval(await actions.call(name: "calendar_create", arguments: [
            "title": "Lunch", "start": iso(start), "end": iso(start.addingTimeInterval(3600)),
            "calendar_id": "home"
        ], watching: false, requestID: request))
        let createResult = try await actions.resolve(approval: create.id, allow: true)
        let created = try XCTUnwrap(createResult)
        let eventID = try XCTUnwrap(payload(created.text)["id"] as? String)
        let edit = try approval(await actions.call(name: "calendar_update", arguments: [
            "id": eventID, "title": "Dinner"
        ], watching: false, requestID: request))
        _ = try await actions.resolve(approval: edit.id, allow: true)
        let remove = try approval(await actions.call(name: "calendar_delete", arguments: [
            "id": eventID
        ], watching: false, requestID: request))
        _ = try await actions.resolve(approval: remove.id, allow: true)
        XCTAssertTrue(backend.events.isEmpty)

        let newTasks = TaskStore(container: tasks.container)
        let newLibrary = AtticLibrary(tasks: newTasks)
        let newWriter = EventKitCalendarEventWriter(store: backend, record: record,
                                                    undoRoute: newLibrary.undo)
        let relaunched = AgentActions(tasks: AgentTaskTools(store: newTasks,
            library: newLibrary), calendarWriter: newWriter, journalURL: journal)
        XCTAssertTrue(relaunched.canRecoverUndo(request))
        let undone = await relaunched.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 3)
        XCTAssertTrue(undone.failures.isEmpty, "\(undone.failures)")
        XCTAssertTrue(backend.events.isEmpty, "Reversing create, edit and delete leaves no event")
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

    // MARK: What goes with a chat request

    func testRequestContextCarriesThePageItsItemAndAddedNotesAsData() throws {
        let tasks = try makeTestStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: AtticLibrary(tasks: tasks, notes: notes))
        let actions = AgentActions(tasks: tools)
        let task = try payload(tools.call(name: "create_task", arguments: ["title": "Call the plumber"]))
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((task["task"] as? [String: Any])?["id"] as? String)))
        let note = try payload(tools.call(name: "create_note", arguments: [
            "title": "Boiler quotes", "body": "Friday quote is cheapest"]))
        let noteID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((note["note"] as? [String: Any])?["id"] as? String)))

        let context = actions.requestContext(AgentRequestContext(
            page: .tasks, pageItem: AgentTarget(page: .tasks, itemID: taskID, title: "Call the plumber"),
            items: [AgentTarget(page: .notes, itemID: noteID, title: "Boiler quotes")],
            files: [AgentFileAttachment(name: "list.txt", text: "eggs")]))
        XCTAssertTrue(context.contains("Tasks page"))
        XCTAssertTrue(context.contains("Call the plumber") && context.contains(taskID.uuidString))
        XCTAssertTrue(context.contains("Friday quote is cheapest"), "An added note's content goes with the request")
        XCTAssertTrue(context.contains("list.txt") && context.contains("eggs"))
        XCTAssertTrue(context.contains("not instructions"))
        XCTAssertEqual(actions.requestContext(.none), "")

        XCTAssertEqual(actions.pickerMatches("plumb").first?.itemID, taskID)
        XCTAssertEqual(actions.pickerMatches("cheapest").first?.itemID, noteID, "A note is found by its text")
        XCTAssertTrue(actions.pickerMatches("  ").isEmpty)
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

    #if !ATTIC_GENERATED_TESTS
    func testUndoCreatedNoteRefusesToDeleteARevisionEditedByTheOwner() async throws {
        let tasks = try makeTestStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: AtticLibrary(tasks: tasks, notes: notes))
        let actions = AgentActions(tasks: tools)
        let request = actions.beginRequest(title: "Create an outline")
        let result = try performed(await actions.call(name: "create_note", arguments: [
            "title": "Outline", "body": "Agent draft"
        ], watching: false, requestID: request))
        let created = try XCTUnwrap(try payload(result.text)["note"] as? [String: Any])
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created["id"] as? String)))
        let revision = try XCTUnwrap(notes.note(withID: id)?.revisionToken)

        let ownerEdit = try payload(tools.call(name: "update_note", arguments: [
            "id": id.uuidString, "base_revision": revision, "body": "Owner's important changes"
        ]))
        XCTAssertEqual(ownerEdit["status"] as? String, "applied")

        let undone = await actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 0)
        XCTAssertFalse(undone.failures.isEmpty)
        XCTAssertEqual(notes.note(withID: id)?.body, "Owner's important changes")
        XCTAssertNotNil(undone.remaining)
    }

    func testUndoCreatedNoteAfterAnAgentEditStillRemovesIt() async throws {
        let tasks = try makeTestStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: AtticLibrary(tasks: tasks, notes: notes))
        let actions = AgentActions(tasks: tools)
        let request = actions.beginRequest(title: "Write a note")
        let created = try performed(await actions.call(name: "create_note", arguments: [
            "title": "Draft", "body": "First version"
        ], watching: false, requestID: request))
        let id = try XCTUnwrap(created.step.targets.first?.itemID)
        _ = try performed(await actions.call(name: "update_note", arguments: [
            "id": id.uuidString, "body": "Second version"
        ], watching: false, requestID: request))
        XCTAssertEqual(actions.changeSet(for: request)?.count, 2)

        let undone = await actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 2)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertNil(notes.note(withID: id))
    }

    func testUndoCreatedNoteKeepsDivergentPhysicalReplica() async throws {
        let tasks = try makeTestStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: AtticLibrary(tasks: tasks, notes: notes))
        let actions = AgentActions(tasks: tools)
        let request = actions.beginRequest(title: "Create note")
        let created = try performed(await actions.call(name: "create_note", arguments: [
            "title": "Draft", "body": "Agent content"
        ], watching: false, requestID: request))
        let id = try XCTUnwrap(created.step.targets.first?.itemID)
        let original = try XCTUnwrap(notes.note(withID: id))
        let ownerCopy = NoteItem(id: id, title: original.title, body: "Owner's divergent content")
        ownerCopy.revisionID = UUID()
        let seed = ModelContext(tasks.container)
        seed.insert(ownerCopy)
        try seed.save()

        let undone = await actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 0)
        XCTAssertEqual(undone.remaining?.count, 1)
        let physical = try ModelContext(tasks.container).fetch(FetchDescriptor<NoteItem>(
            predicate: #Predicate { $0.id == id }))
        XCTAssertEqual(physical.count, 2)
        XCTAssertTrue(physical.allSatisfy { $0.deletedAt == nil })
    }

    func testUndoCreatedNoteKeepsOwnerTagsThatDidNotChangeRevision() async throws {
        let tasks = try makeTestStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: AtticLibrary(tasks: tasks, notes: notes))
        let actions = AgentActions(tasks: tools)
        let request = actions.beginRequest(title: "Create outline")
        let created = try performed(await actions.call(name: "create_note", arguments: [
            "title": "Outline", "body": "A draft"
        ], watching: false, requestID: request))
        let id = try XCTUnwrap(created.step.targets.first?.itemID)
        let initial = try XCTUnwrap(notes.note(withID: id))
        let revision = initial.revisionToken
        XCTAssertTrue(notes.setTags(["important"], for: initial))
        XCTAssertEqual(notes.note(withID: id)?.revisionToken, revision)

        let undone = await actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 0)
        XCTAssertNotNil(undone.remaining)
        XCTAssertEqual(notes.note(withID: id)?.tags, ["important"])
    }

    func testUndoCreatedNoteWithItsOwnInitialTagsAndPin() async throws {
        let tasks = try makeTestStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        let actions = AgentActions(tasks: AgentTaskTools(store: tasks, noteStore: notes,
                                                          library: AtticLibrary(tasks: tasks, notes: notes)))
        let request = actions.beginRequest(title: "Prepare a pinned outline")
        let created = try performed(await actions.call(name: "create_note", arguments: [
            "title": "Pinned outline", "body": "Draft", "tags": ["research", "priority"], "pinned": true
        ], watching: false, requestID: request))
        let id = try XCTUnwrap(created.step.targets.first?.itemID)
        XCTAssertEqual(notes.note(withID: id)?.tags, ["priority", "research"])
        XCTAssertNotNil(notes.note(withID: id)?.pinnedAt)
        if case let .createdNote(_, revision, metadata, _) = actions.journals[request]?.entries.first {
            XCTAssertEqual(notes.agentCreatedNoteMetadata(id), metadata, "Metadata changed immediately after creation")
            XCTAssertEqual(Set((0..<8).compactMap { _ in notes.agentCreatedNoteMetadata(id) }), [metadata],
                           "An unchanged note must have one stable physical Undo seal")
            let persisted = try ModelContext(tasks.container).fetch(FetchDescriptor<NoteItem>())
                .filter { $0.id == id }
            XCTAssertEqual(persisted.count, 1)
            XCTAssertTrue(persisted.allSatisfy { $0.revisionToken == revision },
                          "Presented and persisted revisions differ immediately after creation")
            XCTAssertTrue(persisted.allSatisfy { $0.deletedAt == nil })
            XCTAssertTrue(persisted.allSatisfy { $0.imageCount == 0 && $0.fileCount == 0 },
                          "A new text-only note must not contain attachments")
            XCTAssertTrue(notes.agentCreatedNoteIsUnchanged(id, revision: revision, metadata: metadata), "Created note changed before Undo")
        } else { XCTFail("Expected one created-note inverse") }
        let undone = await actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 1)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertNil(notes.note(withID: id))
    }

    func testUndoCreatedTaskNoteWithItsOwnInitialAssociationButNotItsTask() async throws {
        let tasks = try makeTestStore()
        let taskID = UUID()
        let seed = ModelContext(tasks.container)
        seed.insert(TaskItem(id: taskID, title: "My task"))
        try seed.save()
        tasks.refresh()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        let actions = AgentActions(tasks: AgentTaskTools(store: tasks, noteStore: notes,
                                                          library: AtticLibrary(tasks: tasks, notes: notes)))
        let request = actions.beginRequest(title: "Write in a task")
        let created = try performed(await actions.call(name: "create_note", arguments: [
            "title": "Task note", "body": "Draft", "task_id": taskID.uuidString
        ], watching: false, requestID: request))
        let id = try XCTUnwrap(created.step.targets.first?.itemID)
        XCTAssertEqual(notes.note(withID: id)?.taskID, taskID)
        if case let .createdNote(_, revision, metadata, _) = actions.journals[request]?.entries.first {
            XCTAssertEqual(notes.agentCreatedNoteMetadata(id), metadata, "Task-note association metadata changed after creation")
            XCTAssertTrue(notes.agentCreatedNoteIsUnchanged(id, revision: revision, metadata: metadata))
        } else { XCTFail("Expected one created-note inverse") }
        let undone = await actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 1)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertNil(notes.note(withID: id))
        XCTAssertNotNil(tasks.task(withID: taskID))
    }

    func testUndoCreatedNoteWithInitialMetadataRefusesAnOwnerPinChange() async throws {
        let tasks = try makeTestStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        let actions = AgentActions(tasks: AgentTaskTools(store: tasks, noteStore: notes,
                                                          library: AtticLibrary(tasks: tasks, notes: notes)))
        let request = actions.beginRequest(title: "Create a pinned note")
        let created = try performed(await actions.call(name: "create_note", arguments: [
            "title": "Pinned", "body": "Draft", "pinned": true
        ], watching: false, requestID: request))
        let id = try XCTUnwrap(created.step.targets.first?.itemID)
        XCTAssertTrue(notes.setPinned(false, noteID: id))
        let undone = await actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 0)
        XCTAssertNotNil(undone.remaining)
        XCTAssertNotNil(notes.note(withID: id))
    }

    func testAgentCreatedNoteUndoSurvivesNewStoreAndModelAndRefusesEditedReplica() async throws {
        let tasks = try makeTestStore()
        let root = ownedTemporaryDirectory(prefix: "AgentDurableUndo")
        let journalURL = root.appendingPathComponent("undo.json")
        let attachments = makeTestAttachmentFileStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: attachments)
        let actions = AgentActions(tasks: AgentTaskTools(store: tasks, noteStore: notes,
                                                          library: AtticLibrary(tasks: tasks, notes: notes)),
                                   journalURL: journalURL)
        let request = actions.beginRequest(title: "Write a note")
        let result = try performed(await actions.call(name: "create_note", arguments: [
            "title": "Saved for later", "body": "The draft", "tags": ["review"], "pinned": true
        ], watching: false, requestID: request))
        let id = try XCTUnwrap(result.step.targets.first?.itemID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        let relaunchedTasks = TaskStore(container: tasks.container)
        let relaunchedNotes = NoteStore(container: tasks.container, attachmentFileStore: attachments)
        let relaunched = AgentActions(tasks: AgentTaskTools(store: relaunchedTasks, noteStore: relaunchedNotes,
                                                             library: AtticLibrary(tasks: relaunchedTasks, notes: relaunchedNotes)),
                                      journalURL: journalURL)
        XCTAssertTrue(relaunched.canRecoverUndo(request))
        let recoveredUndo = await relaunched.undo(changeSet: request)
        XCTAssertEqual(recoveredUndo.undone, 1)
        XCTAssertNil(relaunchedNotes.note(withID: id))

        let next = relaunched.beginRequest(title: "Write another")
        let second = try performed(await relaunched.call(name: "create_note", arguments: [
            "title": "Protected from old Undo", "body": "Draft"
        ], watching: false, requestID: next))
        let secondID = try XCTUnwrap(second.step.targets.first?.itemID)
        let modified = try ModelContext(tasks.container).fetch(FetchDescriptor<NoteItem>())
            .filter { $0.id == secondID }
        XCTAssertEqual(modified.count, 1)
        XCTAssertTrue(relaunchedNotes.setPinned(true, noteID: secondID))
        let again = AgentActions(tasks: AgentTaskTools(store: TaskStore(container: tasks.container),
            noteStore: NoteStore(container: tasks.container, attachmentFileStore: attachments)), journalURL: journalURL)
        let refusal = await again.undo(changeSet: next)
        XCTAssertEqual(refusal.undone, 0)
        XCTAssertFalse(refusal.failures.isEmpty)
        XCTAssertNotNil(again.tasks.noteStore?.note(withID: secondID))
    }

    func testTaskEditUndoSurvivesNewStoreAndModelButRefusesChangedReplica() async throws {
        let tasks = try makeTestStore()
        let journalURL = ownedTemporaryDirectory(prefix: "AgentTaskUndo").appendingPathComponent("undo.json")
        let id = UUID()
        let context = ModelContext(tasks.container)
        // Both replicas have the versioned list order production receives at
        // startup. Inserting a legacy version-0 row after startup would cause
        // the *next* TaskStore initializer to migrate it during this test.
        for _ in 0..<2 {
            let replica = TaskItem(id: id, title: "Before")
            replica.manualOrder = 1_024
            replica.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(replica)
        }
        try context.save()
        tasks.refresh()
        let actions = AgentActions(tasks: AgentTaskTools(store: tasks, library: AtticLibrary(tasks: tasks)),
                                   journalURL: journalURL)
        let request = actions.beginRequest(title: "Rename task")
        _ = try performed(await actions.call(name: "update_task", arguments: [
            "id": id.uuidString, "title": "After"
        ], watching: false, requestID: request))

        let restoredTasks = TaskStore(container: tasks.container)
        let restored = AgentActions(tasks: AgentTaskTools(store: restoredTasks,
            library: AtticLibrary(tasks: restoredTasks)), journalURL: journalURL)
        XCTAssertTrue(restored.canRecoverUndo(request), "Every committed task edit needs a durable inverse")
        if let entry = restored.journals[request]?.entries.first,
           case let .taskEdit(_, after, proof, _) = entry {
            let freshContext = ModelContext(tasks.container)
            let replicas = try freshContext.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == id }
            XCTAssertEqual(replicas.count, 2)
            for replica in replicas { XCTAssertEqual(TaskEditableState(replica), after, "Editable state drifted before Undo") }
            let actual = try WorkspaceModelToken.read(WorkspaceOwner(entity: .task, id: id), in: freshContext)
            XCTAssertEqual(actual.replicas.count, proof.replicas.count)
            XCTAssertEqual(actual.replicas.map(\.physicalID), proof.replicas.map(\.physicalID), "Physical identities drifted")
            for (index, row) in actual.replicas.enumerated() where index < proof.replicas.count {
                XCTAssertEqual(row.fields.keys.sorted(), proof.replicas[index].fields.keys.sorted())
                XCTAssertEqual(row.fields.filter { proof.replicas[index].fields[$0.key] != $0.value }.keys.sorted(), [], "Fingerprint fields drifted")
            }
        } else { XCTFail("Task inverse was not recovered") }
        let applied = await restored.undo(changeSet: request)
        XCTAssertEqual(applied.undone, 1)
        XCTAssertTrue(applied.failures.isEmpty, "\(applied.failures)")
        XCTAssertEqual(try ModelContext(tasks.container).fetch(FetchDescriptor<TaskItem>())
            .filter { $0.id == id }.map(\.title), ["Before", "Before"])

        let another = restored.beginRequest(title: "Rename again")
        _ = try performed(await restored.call(name: "update_task", arguments: [
            "id": id.uuidString, "title": "Again"
        ], watching: false, requestID: another))
        let owner = ModelContext(tasks.container)
        let ownerRows = try owner.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == id }
        ownerRows[0].title = "Owner changed one replica"
        try owner.save()
        let newestTasks = TaskStore(container: tasks.container)
        let newest = AgentActions(tasks: AgentTaskTools(store: newestTasks,
            library: AtticLibrary(tasks: newestTasks)), journalURL: journalURL)
        let blocked = await newest.undo(changeSet: another)
        XCTAssertEqual(blocked.undone, 0)
        XCTAssertFalse(blocked.failures.isEmpty)
        XCTAssertEqual(try ModelContext(tasks.container).fetch(FetchDescriptor<TaskItem>())
            .filter { $0.id == id && $0.title == "Owner changed one replica" }.count, 1)
    }

    func testTaskCreationUndoSurvivesNewStoreAndRefusesEditedReplica() async throws {
        let tasks = try makeTestStore()
        let journalURL = ownedTemporaryDirectory(prefix: "AgentCreatedTaskUndo").appendingPathComponent("undo.json")
        let actions = AgentActions(tasks: AgentTaskTools(store: tasks, library: AtticLibrary(tasks: tasks)),
                                   journalURL: journalURL)
        let request = actions.beginRequest(title: "Create two tasks")
        let result = try performed(await actions.call(name: "create_tasks", arguments: [
            "tasks": [["title": "Task one"], ["title": "Task two"]]
        ], watching: false, requestID: request))
        let ids = result.step.targets.compactMap(\.itemID)
        XCTAssertEqual(ids.count, 2)

        let freshTasks = TaskStore(container: tasks.container)
        let fresh = AgentActions(tasks: AgentTaskTools(store: freshTasks, library: AtticLibrary(tasks: freshTasks)),
                                 journalURL: journalURL)
        XCTAssertTrue(fresh.canRecoverUndo(request), "Creation of a task must have an inverse after relaunch")
        let undo = await fresh.undo(changeSet: request)
        XCTAssertEqual(undo.undone, 2)
        XCTAssertTrue(undo.failures.isEmpty, "\(undo.failures)")
        XCTAssertTrue(ids.allSatisfy { freshTasks.task(withID: $0) == nil })

        let another = fresh.beginRequest(title: "A new task")
        let added = try performed(await fresh.call(name: "create_task", arguments: [
            "title": "Preserve owner edits"
        ], watching: false, requestID: another))
        let id = try XCTUnwrap(added.step.targets.first?.itemID)
        let context = ModelContext(tasks.container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first(where: { $0.id == id }))
        row.title = "Edited by the owner"
        try context.save()

        let relaunchedTasks = TaskStore(container: tasks.container)
        let relaunched = AgentActions(tasks: AgentTaskTools(store: relaunchedTasks,
            library: AtticLibrary(tasks: relaunchedTasks)), journalURL: journalURL)
        let refused = await relaunched.undo(changeSet: another)
        XCTAssertEqual(refused.undone, 0)
        XCTAssertFalse(refused.failures.isEmpty)
        XCTAssertEqual(relaunchedTasks.task(withID: id)?.title, "Edited by the owner")
    }

    func testBatchTaskEditsRecoverTwoIndependentInversesAfterRelaunch() async throws {
        let tasks = try makeTestStore()
        let created = try XCTUnwrap(AtticLibrary(tasks: tasks).createTasks([
            TaskDraft(title: "Plan"), TaskDraft(title: "Review")
        ]))
        let journal = ownedTemporaryDirectory(prefix: "AgentBatchTaskUndo").appendingPathComponent("undo.json")
        let actions = AgentActions(tasks: AgentTaskTools(store: tasks, library: AtticLibrary(tasks: tasks)),
                                   journalURL: journal)
        let request = actions.beginRequest(title: "Priorities")
        _ = try performed(await actions.call(name: "update_tasks", arguments: ["updates": [
            ["id": created[0].id.uuidString, "priority": "high"],
            ["id": created[1].id.uuidString, "priority": "high"]
        ]], watching: false, requestID: request))
        let relaunchedTasks = TaskStore(container: tasks.container)
        let relaunched = AgentActions(tasks: AgentTaskTools(store: relaunchedTasks,
            library: AtticLibrary(tasks: relaunchedTasks)), journalURL: journal)
        XCTAssertTrue(relaunched.canRecoverUndo(request))
        let result = await relaunched.undo(changeSet: request)
        XCTAssertEqual(result.undone, 2)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        for item in created {
            XCTAssertEqual(relaunchedTasks.task(withID: item.id)?.priority, TaskPriority.none)
        }
    }

    func testLegacyPlainTextNoteEditUndoSurvivesRelaunch() async throws {
        let tasks = try makeTestStore()
        let attachments = makeTestAttachmentFileStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: attachments)
        let original = try XCTUnwrap(notes.create(title: "Legacy note", body: "Before"))
        let journal = ownedTemporaryDirectory(prefix: "AgentPlainNoteUndo").appendingPathComponent("undo.json")
        let actions = AgentActions(tasks: AgentTaskTools(store: tasks, noteStore: notes,
            library: AtticLibrary(tasks: tasks, notes: notes)), journalURL: journal)
        let request = actions.beginRequest(title: "Edit older note")
        _ = try performed(await actions.call(name: "update_note", arguments: [
            "id": original.id.uuidString, "body": "After"
        ], watching: false, requestID: request))
        let relaunchedTasks = TaskStore(container: tasks.container)
        let relaunchedNotes = NoteStore(container: tasks.container, attachmentFileStore: attachments)
        let relaunched = AgentActions(tasks: AgentTaskTools(store: relaunchedTasks,
            noteStore: relaunchedNotes, library: AtticLibrary(tasks: relaunchedTasks, notes: relaunchedNotes)),
            journalURL: journal)
        XCTAssertTrue(relaunched.canRecoverUndo(request))
        let result = await relaunched.undo(changeSet: request)
        XCTAssertEqual(result.undone, 1)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(relaunchedNotes.note(withID: original.id)?.body, "Before")
    }

    func testRecoveredUndoOnlyOffersTheNewestChangeSet() async throws {
        let tasks = try makeTestStore()
        let journal = ownedTemporaryDirectory(prefix: "AgentNewestUndo").appendingPathComponent("undo.json")
        let library = AtticLibrary(tasks: tasks)
        let actions = AgentActions(tasks: AgentTaskTools(store: tasks, library: library), journalURL: journal)
        let older = actions.beginRequest(title: "First creation")
        _ = try performed(await actions.call(name: "create_task", arguments: ["title": "First"],
                                             watching: false, requestID: older))
        let newer = actions.beginRequest(title: "Second creation")
        _ = try performed(await actions.call(name: "create_task", arguments: ["title": "Second"],
                                             watching: false, requestID: newer))

        let relaunchedTasks = TaskStore(container: tasks.container)
        let relaunchedLibrary = AtticLibrary(tasks: relaunchedTasks)
        let restored = AgentActions(tasks: AgentTaskTools(store: relaunchedTasks, library: relaunchedLibrary),
                                    journalURL: journal)
        XCTAssertFalse(restored.canRecoverUndo(older), "An older receipt must not show an unusable Undo button")
        XCTAssertTrue(restored.canRecoverUndo(newer))
        let newestUndo = await restored.undo(changeSet: newer)
        XCTAssertEqual(newestUndo.undone, 1)
        XCTAssertTrue(newestUndo.failures.isEmpty)
        XCTAssertTrue(restored.canRecoverUndo(older), "Undo of the newer change reveals the prior one")
    }

    func testDrawCreationUndoSurvivesNewStoreAndModel() async throws {
        let tasks = try makeTestStore()
        let repository = DrawMemoryRepository()
        let journalURL = ownedTemporaryDirectory(prefix: "AgentCanvasUndo").appendingPathComponent("undo.json")
        let firstDraw = DrawStore(repository: repository)
        let first = AgentActions(tasks: AgentTaskTools(store: tasks, library: AtticLibrary(tasks: tasks)),
                                 draw: firstDraw, journalURL: journalURL)
        let request = first.beginRequest(title: "Create canvas")
        let result = try performed(await first.call(name: "draw_create_canvas", arguments: [
            "name": "Reopen and undo"
        ], watching: false, requestID: request))
        let id = try XCTUnwrap(result.step.targets.first?.itemID)
        let freshDraw = DrawStore(repository: repository)
        let freshTasks = TaskStore(container: tasks.container)
        let fresh = AgentActions(tasks: AgentTaskTools(store: freshTasks,
            library: AtticLibrary(tasks: freshTasks)), draw: freshDraw, journalURL: journalURL)
        XCTAssertTrue(fresh.canRecoverUndo(request), "Canvas's save step must survive the new DrawStore")
        let undone = await fresh.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 1)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertFalse(try freshDraw.library().contains(where: { $0.id == id }))
    }

    func testTwoDrawEditsUndoInOrderAfterNewStoreAndModel() async throws {
        let tasks = try makeTestStore()
        let repository = DrawMemoryRepository()
        let draw = DrawStore(repository: repository)
        let canvas = draw.create(name: "One canvas")
        let object = DrawObject(content: .text("Before"))
        XCTAssertTrue(draw.perform(.put([object]), on: canvas.id).isSaved)
        let journal = ownedTemporaryDirectory(prefix: "AgentDrawChainUndo").appendingPathComponent("undo.json")
        let actions = AgentActions(tasks: AgentTaskTools(store: tasks,
            library: AtticLibrary(tasks: tasks)), draw: draw, journalURL: journal)
        let request = actions.beginRequest(title: "Two changes to one canvas")
        for (old, new) in [("Before", "Middle"), ("Middle", "After")] {
            _ = try performed(await actions.call(name: "draw_edit_text", arguments: [
                "canvas_id": canvas.id.uuidString, "object_id": object.id.uuidString,
                "expected_text": old, "text": new
            ], watching: false, requestID: request))
        }

        let restoredDraw = DrawStore(repository: repository)
        let restoredTasks = TaskStore(container: tasks.container)
        let restored = AgentActions(tasks: AgentTaskTools(store: restoredTasks,
            library: AtticLibrary(tasks: restoredTasks)), draw: restoredDraw, journalURL: journal)
        XCTAssertTrue(restored.canRecoverUndo(request))
        let undone = await restored.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 2)
        XCTAssertTrue(undone.failures.isEmpty, "\(undone.failures)")
        XCTAssertEqual(try restoredDraw.open(canvas.id).objects.first, object)
    }

    func testDrawReadAndMoveObjectRespectReadOnlyAndUndo() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Plan")
        let points = [DrawPoint(x: 10, y: 20), DrawPoint(x: 30, y: 50)]
        let object = DrawObject(frame: DrawFrame(x: 10, y: 20, width: 20, height: 30),
                                content: .stroke(points))
        XCTAssertTrue(f.draw.perform(.put([object]), on: canvas.id).isSaved)
        let request = f.actions.beginRequest(title: "Position the sketch")
        try f.actions.setMode(.readOnly, for: request)
        let read = try performed(await f.actions.call(name: "draw_read_canvas", arguments: [
            "canvas_name": "Plan"
        ], watching: false, requestID: request))
        let response = try payload(read.text)
        let objects = try XCTUnwrap(response["objects"] as? [[String: Any]])
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects.first?["id"] as? String, object.id.uuidString)
        XCTAssertEqual(objects.first?["point_count"] as? Int, 2)
        XCTAssertEqual(f.actions.changeSet(for: request)?.count, nil)
        let arguments: [String: Any] = ["canvas_id": canvas.id.uuidString,
            "object_id": object.id.uuidString, "expected_x": 10, "expected_y": 20,
            "x": 50, "y": 70]
        do {
            _ = try await f.actions.call(name: "draw_move_object", arguments: arguments,
                                         watching: false, requestID: request)
            XCTFail("Read only must refuse object movement")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Read only"))
        }
        try f.actions.setMode(.askFirst, for: request)
        _ = try performed(await f.actions.call(name: "draw_move_object", arguments: arguments,
                                               watching: false, requestID: request))
        let moved = try XCTUnwrap(f.draw.open(canvas.id).objects.first)
        XCTAssertEqual(moved.frame.x, 50)
        XCTAssertEqual(moved.frame.y, 70)
        if case let .stroke(movedPoints) = moved.content {
            XCTAssertEqual(movedPoints.map(\.x), [50, 70])
            XCTAssertEqual(movedPoints.map(\.y), [70, 100])
        } else { XCTFail("The stroke should stay a stroke") }
        let undo = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undo.undone, 1)
        XCTAssertTrue(undo.failures.isEmpty)
        XCTAssertEqual(try f.draw.open(canvas.id).objects.first, object)
    }

    func testDrawMoveRefusesAnObjectPositionChangedSinceReading() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Board")
        let original = DrawObject(frame: DrawFrame(x: 4, y: 8), content: .text("Owner"))
        XCTAssertTrue(f.draw.perform(.put([original]), on: canvas.id).isSaved)
        var changed = original
        changed.frame.x = 16
        XCTAssertTrue(f.draw.perform(.put([changed]), on: canvas.id).isSaved)
        let request = f.actions.beginRequest(title: "Move text")
        do {
            _ = try await f.actions.call(name: "draw_move_object", arguments: [
                "canvas_id": canvas.id.uuidString, "object_id": original.id.uuidString,
                "expected_x": 4, "expected_y": 8, "x": 70, "y": 80
            ], watching: false, requestID: request)
            XCTFail("An agent must re-read an object changed by its owner")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("moved since"))
        }
        XCTAssertEqual(try f.draw.open(canvas.id).objects.first, changed)
        XCTAssertNil(f.actions.changeSet(for: request))
    }

    func testDrawTextEditRefusesStaleTextAndUndoesTheAcceptedEdit() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Draft board")
        let object = DrawObject(content: .text("First draft"))
        XCTAssertTrue(f.draw.perform(.put([object]), on: canvas.id).isSaved)
        let request = f.actions.beginRequest(title: "Improve text")
        do {
            _ = try await f.actions.call(name: "draw_edit_text", arguments: [
                "canvas_name": "Draft board", "object_id": object.id.uuidString,
                "expected_text": "Outdated draft", "text": "Agent version"
            ], watching: false, requestID: request)
            XCTFail("A stale text edit must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("text changed"))
        }
        XCTAssertEqual(try f.draw.open(canvas.id).objects.first, object)

        _ = try performed(await f.actions.call(name: "draw_edit_text", arguments: [
            "canvas_id": canvas.id.uuidString, "object_id": object.id.uuidString,
            "expected_text": "First draft", "text": "Agent version"
        ], watching: false, requestID: request))
        XCTAssertEqual(try f.draw.open(canvas.id).objects.first?.text, "Agent version")
        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 1)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertEqual(try f.draw.open(canvas.id).objects.first, object)
    }

    func testDrawUndoNeverConsumesANewerOwnerHistoryStepWithUnchangedObjects() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Sketch")
        XCTAssertTrue(f.draw.perform(.put([DrawObject(content: .text("Owner's draft"))]), on: canvas.id).isSaved)
        let request = f.actions.beginRequest(title: "Add to sketch")
        _ = try performed(await f.actions.call(name: "draw_add_text", arguments: [
            "canvas_id": canvas.id.uuidString, "text": "Agent addition", "x": 10, "y": 25
        ], watching: false, requestID: request))
        let agentObjects = try f.draw.open(canvas.id).objects

        // Tags change the canvas history without changing visible objects or its name.
        // Undo of the agent request must never consume this later owner command.
        XCTAssertTrue(f.draw.perform(.tags(["owner"]), on: canvas.id).isSaved)
        let ownerStep = try XCTUnwrap(f.draw.undoStepID(on: canvas.id))
        let result = await f.actions.undo(changeSet: request)
        XCTAssertEqual(result.undone, 0)
        XCTAssertNotNil(result.remaining)
        XCTAssertEqual(try f.draw.open(canvas.id).canvas.tags, ["owner"])
        XCTAssertEqual(try f.draw.open(canvas.id).objects, agentObjects)
        XCTAssertEqual(f.draw.undoStepID(on: canvas.id), ownerStep)
    }

    func testDrawRenameAndApprovedDeleteUndoInReverseOrder() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Original canvas")
        XCTAssertTrue(f.draw.perform(.put([DrawObject(content: .text("Work"))]), on: canvas.id).isSaved)
        let request = f.actions.beginRequest(title: "Organise sketch")
        let renamed = try performed(await f.actions.call(name: "draw_rename_canvas", arguments: [
            "canvas_id": canvas.id.uuidString, "expected_name": "Original canvas", "name": "Updated canvas"
        ], watching: false, requestID: request))
        XCTAssertEqual(renamed.step.targets.first?.itemID, canvas.id)
        XCTAssertEqual(try f.draw.open(canvas.id).canvas.name, "Updated canvas")
        let removal = try approval(await f.actions.call(name: "draw_delete_canvas", arguments: [
            "canvas_name": "Updated canvas"
        ], watching: false, requestID: request))
        XCTAssertEqual(removal.targets.first?.title, "Updated canvas")
        XCTAssertNil(try f.draw.open(canvas.id).canvas.deletedAt)
        _ = try await f.actions.resolve(approval: removal.id, allow: true)
        XCTAssertNotNil(try f.draw.open(canvas.id).canvas.deletedAt)

        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 2)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertEqual(try f.draw.open(canvas.id).canvas.name, "Original canvas")
        XCTAssertNil(try f.draw.open(canvas.id).canvas.deletedAt)
        XCTAssertEqual(try f.draw.open(canvas.id).objects.count, 1)
    }

    func testDrawRenameRefusesAnInterveningOwnerChange() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "First")
        XCTAssertTrue(f.draw.perform(.put([DrawObject(content: .text("Work"))]), on: canvas.id).isSaved)
        XCTAssertTrue(f.draw.perform(.rename("Owner's name"), on: canvas.id).isSaved)
        let request = f.actions.beginRequest(title: "Rename sketch")
        do {
            _ = try await f.actions.call(name: "draw_rename_canvas", arguments: [
                "canvas_id": canvas.id.uuidString, "expected_name": "First", "name": "Agent's name"
            ], watching: false, requestID: request)
            XCTFail("A stale canvas name must not be overwritten")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("name changed"))
        }
        XCTAssertEqual(try f.draw.open(canvas.id).canvas.name, "Owner's name")
        XCTAssertNil(f.actions.changeSet(for: request))
    }

    func testAgentCanPersistEmptyCanvasDuplicateItAndUndoEachCreation() async throws {
        let f = try fixture()
        let create = f.actions.beginRequest(title: "New sketch")
        let created = try performed(await f.actions.call(name: "draw_create_canvas", arguments: [
            "name": "A blank page"
        ], watching: false, requestID: create))
        let id = try XCTUnwrap(created.step.targets.first?.itemID)
        XCTAssertEqual(try f.draw.library().map(\.id), [id], "Empty canvases must be saved")
        let copy = f.actions.beginRequest(title: "Duplicate blank sketch")
        let duplicated = try performed(await f.actions.call(name: "draw_duplicate_canvas", arguments: [
            "canvas_id": id.uuidString, "name": "Blank copy"
        ], watching: false, requestID: copy))
        let copyID = try XCTUnwrap(duplicated.step.targets.first?.itemID)
        XCTAssertEqual(Set(try f.draw.library().map(\.id)), [id, copyID])
        let undoneCopy = await f.actions.undo(changeSet: copy)
        XCTAssertEqual(undoneCopy.undone, 1)
        XCTAssertEqual(try f.draw.library().map(\.id), [id])
        let undoneOriginal = await f.actions.undo(changeSet: create)
        XCTAssertEqual(undoneOriginal.undone, 1)
        XCTAssertTrue(try f.draw.library().isEmpty)
    }

    func testAgentRestyleResizeAndApprovedObjectDeletionUndoExactly() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Map")
        let original = DrawObject(frame: DrawFrame(x: 10, y: 20, width: 80, height: 60),
                                  content: .shape(.rectangle))
        XCTAssertTrue(f.draw.perform(.put([original]), on: canvas.id).isSaved)
        let request = f.actions.beginRequest(title: "Edit map")
        func token() async throws -> String {
            let read = try performed(await f.actions.call(name: "draw_read_canvas", arguments: [
                "canvas_id": canvas.id.uuidString
            ], watching: false, requestID: request))
            let response = try payload(read.text)
            return try XCTUnwrap((response["objects"] as? [[String: Any]])?.first?["object_token"] as? String)
        }
        _ = try performed(await f.actions.call(name: "draw_restyle_object", arguments: [
            "canvas_id": canvas.id.uuidString, "object_id": original.id.uuidString,
            "object_token": try await token(), "colour": "red", "corners": "rounded"
        ], watching: false, requestID: request))
        _ = try performed(await f.actions.call(name: "draw_resize_object", arguments: [
            "canvas_id": canvas.id.uuidString, "object_id": original.id.uuidString,
            "object_token": try await token(), "width": 120, "height": 90
        ], watching: false, requestID: request))
        let approval = try approval(await f.actions.call(name: "draw_delete_object", arguments: [
            "canvas_id": canvas.id.uuidString, "object_id": original.id.uuidString,
            "object_token": try await token()
        ], watching: false, requestID: request))
        XCTAssertEqual(try f.draw.open(canvas.id).objects.count, 1)
        _ = try await f.actions.resolve(approval: approval.id, allow: true)
        XCTAssertTrue(try f.draw.open(canvas.id).objects.isEmpty)
        let reverted = await f.actions.undo(changeSet: request)
        XCTAssertEqual(reverted.undone, 3)
        XCTAssertTrue(reverted.failures.isEmpty)
        XCTAssertEqual(try f.draw.open(canvas.id).objects, [original])
    }

    func testApprovedDrawDeletionRefusesStaleObjectToken() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Keep work")
        let object = DrawObject(content: .text("Keep"))
        XCTAssertTrue(f.draw.perform(.put([object]), on: canvas.id).isSaved)
        let request = f.actions.beginRequest(title: "Remove old text")
        let read = try performed(await f.actions.call(name: "draw_read_canvas", arguments: [
            "canvas_id": canvas.id.uuidString
        ], watching: false, requestID: request))
        let token = try XCTUnwrap((try payload(read.text)["objects"] as? [[String: Any]])?.first?["object_token"] as? String)
        let pending = try approval(await f.actions.call(name: "draw_delete_object", arguments: [
            "canvas_id": canvas.id.uuidString, "object_id": object.id.uuidString,
            "object_token": token
        ], watching: false, requestID: request))
        var ownerCopy = object
        ownerCopy.content = .text("Changed by owner")
        XCTAssertTrue(f.draw.perform(.put([ownerCopy]), on: canvas.id).isSaved)
        do {
            _ = try await f.actions.resolve(approval: pending.id, allow: true)
            XCTFail("An owner change must invalidate approval")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertEqual(try f.draw.open(canvas.id).objects, [ownerCopy])
        XCTAssertNil(f.actions.changeSet(for: request))
    }
    #endif

    func testUndoPutsBackANoteLeftOnScreenByAWatchedWriteOnlyWhenItsEditorIsClean() async throws {
        let tasks = try makeTestStore()
        let notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: AtticLibrary(tasks: tasks, notes: notes))
        let actions = AgentActions(tasks: tools)
        let original = try payload(tools.call(name: "create_note", arguments: ["title": "Blog post", "body": "Draft"]))
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((original["note"] as? [String: Any])?["id"] as? String)))
        for clean in [false, true] {
            let request = actions.beginRequest(title: "Checklist")
            let revision = try XCTUnwrap(notes.note(withID: id)?.revisionToken)
            notes.agentWriteDisposition = { _ in .direct }
            _ = try performed(await actions.call(name: "update_note", arguments: [
                "id": id.uuidString, "base_revision": revision, "body": "Draft\n\nLaunch checklist"
            ], watching: true, requestID: request))
            XCTAssertNotNil(notes.takeAgentWriteBase(id), "The text before is kept for the writing")
            // The watched write left the note open on the Notes page.
            notes.agentWriteDisposition = { _ in .proposal }
            notes.agentUndoMayReplaceOnScreen = { _ in clean }
            var reloaded: [UUID] = []
            notes.agentUndoReplacedOnScreen = { reloaded.append($0) }
            let undone = await actions.undo(changeSet: request)
            if clean {
                XCTAssertEqual(undone.undone, 1)
                XCTAssertEqual(notes.note(withID: id)?.body, "Draft")
                XCTAssertEqual(reloaded, [id])
            } else {
                XCTAssertEqual(undone.undone, 0, "Unsaved text in its editor is never replaced")
                XCTAssertTrue(reloaded.isEmpty)
                notes.agentWriteDisposition = { _ in .direct }
                _ = await actions.undo(changeSet: request)
            }
            XCTAssertTrue(notes.pendingEdits(noteID: id).isEmpty)
        }
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

    func testUndoCreatedTaskPreservesAnUnrelatedNewOwnerTask() async throws {
        let f = try fixture()
        let request = f.actions.beginRequest(title: "One task")
        let created = try performed(await f.actions.call(name: "create_task", arguments: ["title": "Agent"],
                                                          watching: false, requestID: request))
        let createdID = try XCTUnwrap(created.step.targets.first?.itemID)
        XCTAssertNotNil(f.library.createTasks([TaskDraft(title: "Owner")]))
        // AG-08 reverses only the agent's unchanged physical task family.
        // Adding an independent task must not block that precise inverse,
        // and must not delete the owner's newer task.
        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 1)
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertNil(f.store.task(withID: createdID))
        XCTAssertEqual(f.store.tasks.map(\.title), ["Owner"])
        XCTAssertNil(undone.remaining)
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
                                              "draw_list_canvases", "draw_read_canvas", "draw_move_object",
                                              "draw_add_text", "draw_add_shape", "draw_add_strokes",
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

        let createdID = try XCTUnwrap((ready["data"] as? [String: Any])?["id"] as? String)
        let refused = try await mcpTool(handler, "calendar_delete", args: ["id": createdID], token: run)
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
        let createdID = try XCTUnwrap((completed["data"] as? [String: Any])?["id"] as? String)
        let pending = try await mcpTool(handler, "calendar_delete", args: ["id": createdID], token: token)
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

    func testAgentCanUpdateTasksByLooseNameInOneBatchWithPartialFailures() async throws {
        let f = try fixture()
        let first = try XCTUnwrap(f.library.createTasks([
            TaskDraft(title: "Pay electricity bill"), TaskDraft(title: "Send project proposal")
        ]))
        let request = f.actions.beginRequest(title: "Friday tasks")
        let result = try performed(await f.actions.call(name: "update_tasks", arguments: [
            "updates": [
                ["query": "electric bills", "due": "friday"],
                ["query": "send proposal", "priority": "high"],
                ["query": "nonexistent errand", "due": "tomorrow"]
            ]
        ], watching: false, requestID: request))
        let json = try payload(result.text)
        XCTAssertEqual(json["updated"] as? Int, 2)
        XCTAssertEqual(json["failed"] as? Int, 1)
        let rows = try XCTUnwrap(json["results"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual((rows[0]["task"] as? [String: Any])?["id"] as? String, first[0].id.uuidString)
        XCTAssertEqual((rows[1]["task"] as? [String: Any])?["id"] as? String, first[1].id.uuidString)
        XCTAssertTrue((rows[2]["error"] as? String ?? "").contains("search_items"))
        XCTAssertEqual(result.step.targets.count, 2)
        XCTAssertEqual(f.actions.changeSet(for: request)?.count, 2)
        let undone = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undone.undone, 2)
        XCTAssertTrue(undone.failures.isEmpty)
    }

    func testRunBatchMCPReportsPartialAndAllFailedResultsAccurately() async throws {
        let f = try fixture()
        _ = try XCTUnwrap(f.library.createTasks([TaskDraft(title: "Send invoice")]))
        let handler = MCPRequestHandler(tools: f.actions.tasks, actions: f.actions, approvalWait: 0)
        let token = try handler.beginAgentRun(title: "Batch status", watching: false)
        let partial = try await mcpTool(handler, "update_tasks", args: ["updates": [
            ["query": "send invoice", "priority": "high"],
            ["query": "missing invoice", "priority": "high"]
        ]], token: token)
        XCTAssertEqual(partial["status"] as? String, "partial")
        let partialData = try XCTUnwrap(partial["data"] as? [String: Any])
        XCTAssertEqual(partialData["updated"] as? Int, 1)
        XCTAssertEqual(partialData["failed"] as? Int, 1)
        XCTAssertEqual(handler.runChangeSet(token: token)?.count, 1)

        let allFailed = try await mcp(handler, "tools/call", params: [
            "name": "update_tasks", "arguments": ["updates": [["query": "no matching task", "priority": "high"]]]
        ], token: token)
        let outcome = try XCTUnwrap(allFailed["result"] as? [String: Any])
        XCTAssertEqual(outcome["isError"] as? Bool, true)
        let content = try XCTUnwrap(outcome["content"] as? [[String: Any]])
        let response = try payload(try XCTUnwrap(content.first?["text"] as? String))
        XCTAssertEqual(response["status"] as? String, "failed")
        XCTAssertEqual((response["data"] as? [String: Any])?["failed"] as? Int, 1)
        XCTAssertEqual(handler.runChangeSet(token: token)?.count, 1,
                       "An unsuccessful batch must not create a phantom Undo entry")
    }

    func testRunLooseNameRejectsAmbiguousTaskMatches() async throws {
        let f = try fixture()
        _ = try XCTUnwrap(f.library.createTasks([
            TaskDraft(title: "Pay electric bill"), TaskDraft(title: "Pay water bill")
        ]))
        let request = f.actions.beginRequest(title: "Ambiguous task")
        do {
            _ = try await f.actions.call(name: "update_task", arguments: [
                "query": "pay bill", "priority": "high"
            ], watching: false, requestID: request)
            XCTFail("A loose query with multiple matches must not modify either task")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Ambiguous task"))
        }
        XCTAssertNil(f.actions.changeSet(for: request))
        XCTAssertTrue(f.store.orderedTasks(for: .todo).allSatisfy { $0.priority == .none })
    }

    func testRunConvenienceNoteEditsResolveTitleAndRevisionWithoutPreRead() async throws {
        let store = try makeTestStore()
        let notes = NoteStore(container: store.container, attachmentFileStore: makeTestAttachmentFileStore())
        let tools = AgentTaskTools(store: store, noteStore: notes)
        let actions = AgentActions(tasks: tools)
        let note = try payload(tools.call(name: "create_note", arguments: ["title": "Annual planning", "body": "Before"]))
        let row = try XCTUnwrap(note["note"] as? [String: Any])
        let id = try XCTUnwrap(row["id"] as? String)
        let request = actions.beginRequest(title: "Update a note")
        let updated = try performed(await actions.call(name: "update_note", arguments: [
            "query": "annual plan", "body": "After"
        ], watching: false, requestID: request))
        let result = try payload(updated.text)
        XCTAssertEqual(result["status"] as? String, "applied")
        XCTAssertEqual((result["note"] as? [String: Any])?["id"] as? String, id)
        XCTAssertEqual((result["note"] as? [String: Any])?["body"] as? String, "After")
        let undo = await actions.undo(changeSet: request)
        XCTAssertEqual(undo.undone, 1)
        XCTAssertEqual(notes.note(withID: try XCTUnwrap(UUID(uuidString: id)))?.body, "Before")
    }

    func testCalendarCreateAndPartialUpdateUseDefaultsAndOccurrenceIdentifier() async throws {
        let f = try fixture()
        let request = f.actions.beginRequest(title: "Calendar convenience")
        let date = Date(timeIntervalSince1970: 1_793_361_600)
        let created = try approval(await f.actions.call(name: "calendar_create", arguments: [
            "title": "Lunch", "start": iso(date)
        ], watching: false, requestID: request))
        let resolvedCreation = try await f.actions.resolve(approval: created.id, allow: true)
        let event = try XCTUnwrap(resolvedCreation)
        let row = try payload(event.text)
        let stableID = try XCTUnwrap(row["id"] as? String)
        XCTAssertEqual(row["calendar_id"] as? String, "home")
        XCTAssertEqual(row["end"] as? String, iso(date.addingTimeInterval(3600)))
        let edit = try approval(await f.actions.call(name: "calendar_update", arguments: [
            "id": stableID, "title": "Later lunch"
        ], watching: false, requestID: request))
        let resolvedUpdate = try await f.actions.resolve(approval: edit.id, allow: true)
        let updated = try XCTUnwrap(resolvedUpdate)
        XCTAssertEqual(try payload(updated.text)["title"] as? String, "Later lunch")
        XCTAssertEqual(f.backend.events.count, 1)
        XCTAssertEqual(f.backend.events.values.first?.draft.title, "Later lunch")
        let remove = try approval(await f.actions.call(name: "calendar_delete", arguments: [
            "occurrence_id": try XCTUnwrap(payload(updated.text)["occurrence_id"] as? String)
        ], watching: false, requestID: request))
        _ = try await f.actions.resolve(approval: remove.id, allow: true)
        XCTAssertTrue(f.backend.events.isEmpty)
        let undo = await f.actions.undo(changeSet: request)
        XCTAssertEqual(undo.undone, 3)
        XCTAssertTrue(undo.failures.isEmpty)
    }

    func testCalendarApprovalRechecksOwnershipWhenEventChanges() async throws {
        let f = try fixture()
        let request = f.actions.beginRequest(title: "Calendar ownership")
        let date = Date(timeIntervalSince1970: 1_793_361_600)
        let pendingCreate = try approval(await f.actions.call(name: "calendar_create", arguments: [
            "title": "Meeting", "start": iso(date)
        ], watching: false, requestID: request))
        let resolvedCreate = try await f.actions.resolve(approval: pendingCreate.id, allow: true)
        let created = try XCTUnwrap(resolvedCreate)
        let stableID = try XCTUnwrap(try payload(created.text)["id"] as? String)
        let pendingEdit = try approval(await f.actions.call(name: "calendar_update", arguments: [
            "id": stableID, "title": "Agent meeting"
        ], watching: false, requestID: request))
        let eventID = try XCTUnwrap(f.backend.events.keys.first)
        f.backend.events[eventID]?.draft.title = "Owner changed meeting"
        do {
            _ = try await f.actions.resolve(approval: pendingEdit.id, allow: true)
            XCTFail("A delayed approval cannot replace an owner's newer event edit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changed"))
        }
        XCTAssertEqual(f.backend.events[eventID]?.draft.title, "Owner changed meeting")
        XCTAssertEqual(f.actions.changeSet(for: request)?.count, 1)
    }

    func testDrawCanSelectOnlyCanvasWithoutLookup() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Only board")
        // A newly created empty canvas is an unsaved draft and is deliberately
        // absent from library(). Give the selection a saved canvas to find.
        XCTAssertTrue(f.draw.perform(.put([DrawObject(content: .text("Existing"))]), on: canvas.id).isSaved)
        let request = f.actions.beginRequest(title: "Sketch")
        let result = try performed(await f.actions.call(name: "draw_add_text", arguments: [
            "text": "Idea", "x": 8, "y": 12
        ], watching: false, requestID: request))
        XCTAssertEqual(result.step.targets.first?.containerID, canvas.id)
        XCTAssertEqual(try f.draw.open(canvas.id).objects.count, 2)
        XCTAssertTrue(try f.draw.open(canvas.id).objects.contains { $0.text == "Idea" })
    }

    func testLooseSearchReturnsTasksNotesAndSavedCanvases() async throws {
        let store = try makeTestStore()
        let notes = NoteStore(container: store.container, attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: store, notes: notes)
        let draw = DrawInMemoryStore()
        let actions = AgentActions(tasks: AgentTaskTools(store: store, noteStore: notes, library: library), draw: draw)
        _ = try XCTUnwrap(library.createTasks([TaskDraft(title: "Plan agenda")]))
        _ = try XCTUnwrap(notes.create(title: "Planning notes", body: "Discuss agenda"))
        let canvas = draw.create(name: "Plan board")
        XCTAssertTrue(draw.perform(.put([DrawObject(content: .text("Start"))]), on: canvas.id).isSaved)
        let request = actions.beginRequest(title: "Find the plan")
        let result = try performed(await actions.call(name: "search_items", arguments: [
            "query": "plan"
        ], watching: false, requestID: request))
        let data = try payload(result.text)
        let items = try XCTUnwrap(data["items"] as? [[String: Any]])
        XCTAssertEqual(data["count"] as? Int, 3)
        XCTAssertEqual(Set(items.compactMap { $0["page"] as? String }), Set(["tasks", "notes", "draw"]))
        XCTAssertNil(result.changeSet)
    }

    func testRealisticMultiPageRequestMeasuresMCPToolCallCount() async throws {
        let f = try fixture()
        let canvas = f.draw.create(name: "Plan")
        XCTAssertTrue(f.draw.perform(.put([DrawObject(content: .text("Existing"))]), on: canvas.id).isSaved)
        let handler = MCPRequestHandler(tools: f.actions.tasks, actions: f.actions, approvalWait: 0)
        let run = try handler.beginAgentRun(title: "Plan the week", watching: false)
        var callCount = 0
        func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
            callCount += 1
            return try await mcpTool(handler, name, args: args, token: run)
        }
        let created = try await call("create_tasks", ["tasks": [
            ["title": "Prepare agenda"], ["title": "Send reminder"], ["title": "Review notes"]
        ]])
        XCTAssertEqual((created["text"] as? String).flatMap { try? payload($0)["created"] as? Int }, 3)
        let changed = try await call("update_tasks", ["updates": [
            ["query": "prepare agenda", "due": "friday"],
            ["query": "send reminder", "due": "friday"]
        ]])
        XCTAssertEqual((changed["text"] as? String).flatMap { try? payload($0)["updated"] as? Int }, 2)
        let date = Date(timeIntervalSince1970: 1_793_361_600)
        let event = try await call("calendar_create", ["title": "Team planning", "start": iso(date)])
        let prompt = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(event["approval_id"] as? String)))
        try await handler.resolveRunApproval(id: prompt, allow: true, token: run)
        let approvalResult = try await call("agent_approval_status", ["approval_id": prompt.uuidString])
        XCTAssertEqual(approvalResult["status"] as? String, "done")
        XCTAssertEqual((approvalResult["data"] as? [String: Any])?["title"] as? String, "Team planning")
        XCTAssertEqual(handler.runChangeSet(token: run)?.pages, Set([.tasks, .calendar]))
        let sketch = try await call("draw_add_text", ["text": "Plan", "x": 10, "y": 20])
        XCTAssertEqual(sketch["status"] as? String, "done")
        XCTAssertEqual(try f.draw.open(canvas.id).objects.count, 2)
        XCTAssertEqual(handler.runChangeSet(token: run)?.pages, Set([.tasks, .calendar, .draw]))
        print("AGENT_REALISTIC_REQUEST_MCP_TOOL_CALLS=\(callCount)")
        XCTAssertEqual(callCount, 5)
    }
}
