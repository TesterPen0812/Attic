import SwiftData
import XCTest
@testable import Attic

@MainActor
final class MCPRequestHandlerTests: XCTestCase {
    private var store: TaskStore!
    private var handler: MCPRequestHandler!

    override func setUp() async throws {
        store = try makeTestStore()
        handler = MCPRequestHandler(tools: AgentTaskTools(store: store), serverVersion: "test")
    }

    override func tearDown() {
        store = nil
        handler = nil
    }

    func testAgentSetupPromptIncludesConnectionAndSafeClientInstructions() {
        let prompt = AgentSetupPrompt.make(
            endpoint: "http://127.0.0.1:7335/mcp",
            bearerToken: "secret-token"
        )

        XCTAssertTrue(prompt.contains("URL: http://127.0.0.1:7335/mcp"))
        XCTAssertTrue(prompt.contains("Authorization: Bearer secret-token"))
        XCTAssertTrue(prompt.contains("Codex, Synara, or Claude"))
        XCTAssertTrue(prompt.contains("bearer_token_env_var = \"ATTIC_MCP_TOKEN\""))
        XCTAssertTrue(prompt.contains("Do not alter or remove any other MCP servers"))
        XCTAssertTrue(prompt.contains("do not echo it in your reply"))
    }

    func testInitializeAdvertisesToolsAndEchoesSupportedVersion() throws {
        let response = try send(method: "initialize", params: ["protocolVersion": "2025-03-26"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"])
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "attic")
        let instructions = try XCTUnwrap(result["instructions"] as? String)
        XCTAssertTrue(instructions.contains("Do not open or control the Attic GUI with Computer Use"))
    }

    func testInitializeFallsBackToLatestSupportedVersion() throws {
        let response = try send(method: "initialize", params: ["protocolVersion": "1999-01-01"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
    }

    func testNotificationReturnsAcceptedWithoutBody() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ])
        let result = handler.handle(body: body)
        XCTAssertEqual(result.status, 202)
        XCTAssertNil(result.body)
    }

    func testMalformedJSONReturnsParseError() throws {
        let result = handler.handle(body: Data("not json".utf8))
        let response = try decode(result)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
    }

    func testMissingJSONRPCVersionReturnsInvalidRequest() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "id": 1,
            "method": "ping"
        ])
        let response = try decode(handler.handle(body: body))
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32600)
    }

    func testNullIDStillReceivesAResponse() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": NSNull(),
            "method": "ping"
        ])
        let response = try decode(handler.handle(body: body))
        XCTAssertTrue(response["id"] is NSNull)
        XCTAssertNotNil(response["result"])
    }

    func testBooleanIDReturnsInvalidRequest() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": true,
            "method": "ping"
        ])
        let response = try decode(handler.handle(body: body))
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32600)
    }

    func testUnsupportedProtocolVersionReturnsHTTPBadRequest() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])
        let result = handler.handle(body: body, protocolVersion: "1999-01-01")
        XCTAssertEqual(result.status, 400)
        XCTAssertEqual(result.reason, "Bad Request")
        XCTAssertNotNil(result.body)
    }

    func testNonObjectParamsReturnInvalidParams() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": []
        ])
        let response = try decode(handler.handle(body: body))
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testUnknownMethodReturnsMethodNotFound() throws {
        let response = try send(method: "resources/list")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testToolsListReturnsAllTaskTools() throws {
        let response = try send(method: "tools/list")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(
            tools.compactMap { $0["name"] as? String }.sorted(),
            // Phase 0 adds Recently Deleted, tag and link tools; the original
            // four keep their names.
            ["create_task", "delete_item", "delete_task", "link", "list_deleted", "list_tags",
             "list_tasks", "restore_item", "update_tags", "update_task"]
        )
        let listTool = try XCTUnwrap(tools.first { $0["name"] as? String == "list_tasks" })
        let annotations = try XCTUnwrap(listTool["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
    }

    func testCreateTaskInsertsTaskWithPriorityAndStatus() throws {
        let payload = try callTool("create_task", arguments: [
            "title": "  Ship   the MCP server ",
            "priority": "high",
            "status": "inProgress"
        ])
        let task = try XCTUnwrap(payload["task"] as? [String: Any])
        XCTAssertEqual(task["title"] as? String, "Ship the MCP server")
        XCTAssertEqual(task["status"] as? String, "inProgress")
        XCTAssertEqual(task["priority"] as? String, "high")
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.tasks.first?.status, .inProgress)
    }

    func testCreateTaskWithoutTitleReturnsToolError() throws {
        let response = try send(method: "tools/call", params: [
            "name": "create_task",
            "arguments": ["title": "   "]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testListTasksFiltersByStatus() throws {
        let todo = try XCTUnwrap(store.create(title: "Todo item"))
        let backlogged = try XCTUnwrap(store.create(title: "Backlog item", status: .backlog))

        let payload = try callTool("list_tasks", arguments: ["status": "backlog"])
        let tasks = try XCTUnwrap(payload["tasks"] as? [[String: Any]])
        XCTAssertEqual(payload["count"] as? Int, 1)
        XCTAssertEqual(tasks.first?["id"] as? String, backlogged.id.uuidString)

        let allPayload = try callTool("list_tasks", arguments: [:])
        let allIDs = try XCTUnwrap(allPayload["tasks"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(allIDs), Set([todo.id.uuidString, backlogged.id.uuidString]))
    }

    func testUpdateTaskToDoneSetsCompletedAt() throws {
        let task = try XCTUnwrap(store.create(title: "Finish me"))

        let payload = try callTool("update_task", arguments: [
            "id": task.id.uuidString,
            "status": "done",
            "priority": "low",
            "title": "Finished"
        ])
        let updated = try XCTUnwrap(payload["task"] as? [String: Any])
        XCTAssertEqual(updated["status"] as? String, "done")
        XCTAssertEqual(updated["priority"] as? String, "low")
        XCTAssertEqual(updated["title"] as? String, "Finished")
        XCTAssertNotNil(updated["completedAt"])
        XCTAssertNotNil(task.completedAt)
    }

    func testUpdateTaskWithInvalidPriorityChangesNothing() throws {
        let task = try XCTUnwrap(store.create(title: "Keep me intact"))

        let response = try send(method: "tools/call", params: [
            "name": "update_task",
            "arguments": ["id": task.id.uuidString, "title": "Renamed", "priority": "urgent"]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(task.title, "Keep me intact")
    }

    func testUpdateTaskWithNonStringTitleChangesNothing() throws {
        let task = try XCTUnwrap(store.create(title: "Keep me intact"))

        let response = try send(method: "tools/call", params: [
            "name": "update_task",
            "arguments": ["id": task.id.uuidString, "title": 123, "status": "done"]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(task.title, "Keep me intact")
        XCTAssertEqual(task.status, .todo)
    }

    func testUpdateTaskWithUnknownIDReturnsToolError() throws {
        let response = try send(method: "tools/call", params: [
            "name": "update_task",
            "arguments": ["id": UUID().uuidString, "status": "done"]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testDeleteTaskRemovesTask() throws {
        let task = try XCTUnwrap(store.create(title: "Remove me"))
        let payload = try callTool("delete_task", arguments: ["id": task.id.uuidString])
        XCTAssertEqual(payload["deleted"] as? String, task.id.uuidString)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testUnknownToolReturnsInvalidParams() throws {
        let response = try send(method: "tools/call", params: ["name": "explode"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testNonObjectToolArgumentsReturnInvalidParamsWithoutRunningTheTool() throws {
        let malformedArguments: [Any] = [["Write tests"], "Write tests", 7, true]
        for arguments in malformedArguments {
            let response = try send(
                method: "tools/call",
                params: ["name": "create_task", "arguments": arguments]
            )
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32602)
            XCTAssertNil(response["result"])
        }
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testNullToolArgumentsAreTreatedAsAbsent() throws {
        let response = try send(
            method: "tools/call",
            params: ["name": "list_tasks", "arguments": NSNull()]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
    }

    // MARK: - Notes

    func testToolsListIncludesNoteToolsWhenNoteStoreProvided() throws {
        let (_, handler) = try makeNoteHandler()
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])
        let response = try JSONSerialization.jsonObject(with: try XCTUnwrap(handler.handle(body: body).body)) as? [String: Any]
        let tools = try XCTUnwrap(try XCTUnwrap(response)["result"] as? [String: Any])["tools"] as? [[String: Any]]
        let names = try XCTUnwrap(tools).compactMap { $0["name"] as? String }
        XCTAssertEqual(
            names.sorted(),
            ["create_note", "create_task", "delete_item", "delete_note", "delete_task", "link", "list_deleted",
             "list_notes", "list_tags", "list_tasks", "restore_item", "update_note", "update_tags", "update_task"]
        )
    }

    func testCreateNoteInsertsTitleAndBody() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let payload = try callNoteTool(handler, "create_note", [
            "title": "  Ship   notes ",
            "body": "Body\nhere"
        ])
        let note = try XCTUnwrap(payload["note"] as? [String: Any])
        XCTAssertEqual(note["title"] as? String, "Ship notes")
        XCTAssertEqual(note["body"] as? String, "Body\nhere")
        XCTAssertEqual(noteStore.notes.count, 1)
    }

    func testCreateNoteWithoutBodyOrTitleReturnsToolError() throws {
        let (_, handler) = try makeNoteHandler()
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "create_note", "arguments": ["title": "   "]]
        ])
        let response = try JSONSerialization.jsonObject(with: try XCTUnwrap(handler.handle(body: body).body)) as? [String: Any]
        let result = try XCTUnwrap(try XCTUnwrap(response)["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testListNotesReturnsStoredNotes() throws {
        let (noteStore, handler) = try makeNoteHandler()
        _ = noteStore.create(title: "One", body: "a")
        _ = noteStore.create(title: "Two", body: "b")

        let payload = try callNoteTool(handler, "list_notes", [:])
        XCTAssertEqual(payload["count"] as? Int, 2)
    }

    func testUpdateNoteChangesBody() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let note = try XCTUnwrap(noteStore.create(title: "Title", body: "old"))

        let payload = try callNoteTool(handler, "update_note", [
            "id": note.id.uuidString,
            "body": "new body"
        ])
        let updated = try XCTUnwrap(payload["note"] as? [String: Any])
        XCTAssertEqual(updated["body"] as? String, "new body")
        XCTAssertEqual(note.body, "new body")
    }

    func testUpdateNoteRejectsBlankingWithAnAccurateMessage() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let note = try XCTUnwrap(noteStore.create(title: "Title", body: "Body"))
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "update_note",
                "arguments": ["id": note.id.uuidString, "title": "  ", "body": "\n"]
            ]
        ])
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(handler.handle(body: body).body))
                as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "A title or body must remain non-empty.")
        XCTAssertEqual(note.title, "Title")
        XCTAssertEqual(note.body, "Body")
    }

    func testDeleteNoteRemovesNote() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let note = try XCTUnwrap(noteStore.create(body: "Remove me"))

        let payload = try callNoteTool(handler, "delete_note", ["id": note.id.uuidString])
        XCTAssertEqual(payload["deleted"] as? String, note.id.uuidString)
        XCTAssertTrue(noteStore.notes.isEmpty)
    }

    func testNoteToolsAreUnknownWhenNoNoteStoreProvided() throws {
        let response = try send(method: "tools/call", params: ["name": "list_notes"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    // MARK: - Phase 0: Recently Deleted, tags, dates and links

    private func makeLibraryHandler() throws -> (AtticLibrary, MCPRequestHandler) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 10))!
        let noteStore = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: store, notes: noteStore, canvases: CanvasStore(container: store.container))
        let handler = MCPRequestHandler(
            tools: AgentTaskTools(
                store: store,
                noteStore: noteStore,
                library: library,
                parser: TaskTextParser(calendar: calendar, locale: Locale(identifier: "en_US"), now: { now })
            ),
            serverVersion: "test"
        )
        return (library, handler)
    }

    private func toolError(_ handler: MCPRequestHandler, _ name: String, _ arguments: [String: Any]) throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ])
        let response = try decode(handler.handle(body: body))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    func testDeleteTaskNowMovesTheFamilyToRecentlyDeletedAndRestoreItemBringsItBack() throws {
        let (library, handler) = try makeLibraryHandler()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        let payload = try callNoteTool(handler, "delete_task", ["id": parent.id.uuidString])
        XCTAssertEqual(payload["deleted"] as? String, parent.id.uuidString, "response shape unchanged")
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<TaskItem>()), 2, "nothing removed")

        let deleted = try callNoteTool(handler, "list_deleted", [:])
        XCTAssertEqual(deleted["count"] as? Int, 1)
        let item = try XCTUnwrap((deleted["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["kind"] as? String, "task")
        XCTAssertEqual(item["title"] as? String, "Parent")
        XCTAssertEqual(item["included"] as? Int, 1)
        XCTAssertNotNil(item["expiresAt"] as? String)

        let restored = try callNoteTool(handler, "restore_item", ["kind": "task", "id": parent.id.uuidString])
        XCTAssertEqual(restored["restored"] as? String, parent.id.uuidString)
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [child.id])
        XCTAssertTrue(library.undo.canUndo(in: .library), "agent changes are undoable")
    }

    func testDeleteNoteNowMovesTheNoteToRecentlyDeleted() throws {
        let (library, handler) = try makeLibraryHandler()
        let note = try XCTUnwrap(library.notes?.create(title: "Keep safe"))
        let payload = try callNoteTool(handler, "delete_note", ["id": note.id.uuidString])
        XCTAssertEqual(payload["deleted"] as? String, note.id.uuidString)
        XCTAssertTrue(try XCTUnwrap(library.notes).notes.isEmpty)
        XCTAssertEqual(library.state(of: AtticItemRef(.note, note.id)), .deleted)
        XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<NoteItem>()), 1)
    }

    func testDeleteItemWorksForEveryKindAndAgentsCannotDeletePermanently() throws {
        let (library, handler) = try makeLibraryHandler()
        let task = try XCTUnwrap(store.create(title: "Task"))
        let note = try XCTUnwrap(library.notes?.create(title: "Note"))
        XCTAssertNotNil(library.canvases?.createCanvas(name: "Keep"))
        let board = try XCTUnwrap(library.canvases?.createCanvas(name: "Board"))
        for (kind, id) in [("task", task.id), ("note", note.id), ("canvas", board.id)] {
            let payload = try callNoteTool(handler, "delete_item", ["kind": kind, "id": id.uuidString])
            XCTAssertEqual(payload["kind"] as? String, kind)
            XCTAssertNotNil(payload["restorable_until"] as? String)
        }
        XCTAssertEqual(try callNoteTool(handler, "list_deleted", [:])["count"] as? Int, 3)
        let context = ModelContext(store.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteItem>()), 1)

        let names = AgentTaskTools(store: store).definitions.compactMap { $0["name"] as? String }
        XCTAssertFalse(names.contains { $0.contains("purge") || $0.contains("empty") || $0.contains("permanent") })
        XCTAssertTrue(try toolError(handler, "delete_item", ["kind": "task", "id": task.id.uuidString]).contains("No task"))
        XCTAssertTrue(try toolError(handler, "delete_item", ["kind": "folder", "id": task.id.uuidString]).contains("kind"))
        XCTAssertTrue(try toolError(handler, "restore_item", ["kind": "note", "id": UUID().uuidString]).contains("Recently Deleted"))
    }

    func testCreateTaskAcceptsTagsDueAndPriorityThroughTheDraftStep() throws {
        let (library, handler) = try makeLibraryHandler()
        let payload = try callNoteTool(handler, "create_task", [
            "title": "Call mom tomorrow !",
            "tags": ["#Family", "calls"],
            "due": "sep 30",
            "priority": "high"
        ])
        let task = try XCTUnwrap(payload["task"] as? [String: Any])
        XCTAssertEqual(task["title"] as? String, "Call mom tomorrow !", "an agent's title is used as given")
        XCTAssertEqual(task["tags"] as? [String], ["calls", "family"])
        XCTAssertEqual(task["due"] as? String, "2026-09-30")
        XCTAssertEqual(task["priority"] as? String, "high")
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Add Task")

        let iso = try callNoteTool(handler, "create_task", ["title": "ISO", "due": "2027-01-15"])
        XCTAssertEqual((iso["task"] as? [String: Any])?["due"] as? String, "2027-01-15")
        let plain = try callNoteTool(handler, "create_task", ["title": "Plain"])
        XCTAssertEqual((plain["task"] as? [String: Any])?["tags"] as? [String], [])
        XCTAssertNil((plain["task"] as? [String: Any])?["due"])

        XCTAssertTrue(try toolError(handler, "create_task", ["title": "Bad", "due": "someday"]).contains("due date"))
        XCTAssertTrue(try toolError(handler, "create_task", ["title": "Bad", "tags": ["!!!"]]).contains("Invalid tag"))
        XCTAssertTrue(try toolError(handler, "create_task", ["title": "Bad", "tags": "home"]).contains("array"))
        XCTAssertTrue(try toolError(handler, "create_task", ["title": "Bad", "due": NSNull()]).contains("due"))
        XCTAssertEqual(store.tasks.count, 3, "invalid arguments create nothing")
    }

    func testUpdateTaskSetsReplacesAndClearsTagsAndDue() throws {
        let (library, handler) = try makeLibraryHandler()
        let task = try XCTUnwrap(store.create(title: "Task"))
        var updated = try callNoteTool(handler, "update_task", [
            "id": task.id.uuidString, "tags": ["a", "b"], "due": "fri"
        ])
        var payload = try XCTUnwrap(updated["task"] as? [String: Any])
        XCTAssertEqual(payload["tags"] as? [String], ["a", "b"])
        XCTAssertEqual(payload["due"] as? String, "2026-09-25")
        updated = try callNoteTool(handler, "update_task", ["id": task.id.uuidString, "tags": ["c"], "due": NSNull()])
        payload = try XCTUnwrap(updated["task"] as? [String: Any])
        XCTAssertEqual(payload["tags"] as? [String], ["c"])
        XCTAssertNil(payload["due"])
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 2)
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(task.tags, ["a", "b"])
        XCTAssertTrue(try toolError(handler, "update_task", ["id": task.id.uuidString, "due": "soonish"]).contains("due date"))
    }

    func testListTagsAndUpdateTagsRenameAndMerge() throws {
        let (library, handler) = try makeLibraryHandler()
        let first = try XCTUnwrap(store.create(title: "One"))
        let second = try XCTUnwrap(store.create(title: "Two"))
        let note = try XCTUnwrap(library.notes?.create(title: "Note"))
        XCTAssertTrue(library.setTags(["work", "urgent"], on: AtticItemRef(.task, first.id)))
        XCTAssertTrue(library.setTags(["job"], on: AtticItemRef(.task, second.id)))
        XCTAssertTrue(library.setTags(["work"], on: AtticItemRef(.note, note.id)))

        let listed = try callNoteTool(handler, "list_tags", [:])
        XCTAssertEqual(listed["count"] as? Int, 3)
        let tags = try XCTUnwrap(listed["tags"] as? [[String: Any]])
        XCTAssertEqual(tags.first?["name"] as? String, "work")
        XCTAssertEqual(tags.first?["count"] as? Int, 2)

        let renamed = try callNoteTool(handler, "update_tags", ["action": "rename", "from": "urgent", "to": "Now"])
        XCTAssertEqual(renamed["tag"] as? String, "now")
        XCTAssertEqual(store.task(withID: first.id)?.tags, ["now", "work"])
        _ = try callNoteTool(handler, "update_tags", ["action": "merge", "from": ["job", "work"], "to": "work"])
        XCTAssertEqual(store.task(withID: second.id)?.tags, ["work"])
        XCTAssertEqual(library.tags.counts().first, TagCount(name: "work", count: 3))

        XCTAssertTrue(try toolError(handler, "update_tags", ["action": "delete", "from": "work", "to": "x"]).contains("rename or merge"))
        XCTAssertTrue(try toolError(handler, "update_tags", ["action": "merge", "from": "work", "to": "x"]).contains("list"))
        XCTAssertTrue(try toolError(handler, "update_tags", ["action": "rename", "from": "work", "to": "#"]).contains("tag"))
    }

    func testLinkCreatesAndListsLinksAndBacklinks() throws {
        let (library, handler) = try makeLibraryHandler()
        let task = try XCTUnwrap(store.create(title: "Email testers"))
        let note = try XCTUnwrap(library.notes?.create(title: "Beta plan"))
        let created = try callNoteTool(handler, "link", [
            "item": ["kind": "note", "id": note.id.uuidString],
            "target": ["kind": "task", "id": task.id.uuidString],
            "link_kind": "card"
        ])
        let link = try XCTUnwrap(created["link"] as? [String: Any])
        XCTAssertEqual(link["kind"] as? String, "card")
        XCTAssertEqual((link["target"] as? [String: Any])?["title"] as? String, "Email testers")
        XCTAssertEqual((created["links"] as? [[String: Any]])?.count, 1)

        let listed = try callNoteTool(handler, "link", ["item": ["kind": "task", "id": task.id.uuidString]])
        XCTAssertEqual((listed["links"] as? [[String: Any]])?.count, 0)
        let backlinks = try XCTUnwrap(listed["backlinks"] as? [[String: Any]])
        XCTAssertEqual((backlinks.first?["source"] as? [String: Any])?["id"] as? String, note.id.uuidString)

        XCTAssertTrue(try toolError(handler, "link", [
            "item": ["kind": "task", "id": task.id.uuidString],
            "target": ["kind": "note", "id": UUID().uuidString]
        ]).contains("No note"))
        XCTAssertTrue(try toolError(handler, "link", [
            "item": ["kind": "task", "id": task.id.uuidString], "link_kind": "card"
        ]).contains("target"))
    }

    private func makeNoteHandler() throws -> (NoteStore, MCPRequestHandler) {
        let noteStore = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let handler = MCPRequestHandler(
            tools: AgentTaskTools(store: store, noteStore: noteStore),
            serverVersion: "test"
        )
        return (noteStore, handler)
    }

    private func callNoteTool(
        _ handler: MCPRequestHandler,
        _ name: String,
        _ arguments: [String: Any]
    ) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ])
        let response = try JSONSerialization.jsonObject(with: try XCTUnwrap(handler.handle(body: body).body)) as? [String: Any]
        let responseDict = try XCTUnwrap(response)
        let result = try XCTUnwrap(responseDict["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func send(method: String, params: [String: Any] = [:], id: Int = 1) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])
        return try decode(handler.handle(body: body))
    }

    private func callTool(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        let response = try send(method: "tools/call", params: ["name": name, "arguments": arguments])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func decode(_ result: MCPHTTPResult) throws -> [String: Any] {
        XCTAssertEqual(result.status, 200)
        let body = try XCTUnwrap(result.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}
