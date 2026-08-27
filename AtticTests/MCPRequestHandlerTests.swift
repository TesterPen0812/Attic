import Foundation
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

    func testNonObjectToolArgumentsReturnInvalidParamsWithoutCallingTool() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "create_task", "arguments": ["not-an-object"]]
        ])
        let response = try decode(handler.handle(body: body))
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testOversizedJSONRPCBodyIsRejectedBeforeParsing() throws {
        let result = handler.handle(body: Data(repeating: 0x20, count: 1_048_577))

        XCTAssertEqual(result.status, 413)
        XCTAssertNil(result.body)
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
            ["create_task", "delete_task", "list_tasks", "update_task"]
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

    func testTaskToolRejectsUnknownArgumentsWithoutMutating() throws {
        let response = try send(method: "tools/call", params: [
            "name": "create_task",
            "arguments": ["title": "Keep out", "path": "/tmp/anything"]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let error = try XCTUnwrap(structured["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_arguments")
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
            [
                "append_note", "create_note", "create_task", "delete_note", "delete_task",
                "get_note", "list_notes", "list_tasks", "update_note", "update_task"
            ]
        )
    }

    func testNoteToolSchemasAreStrictAndDescribeRevisionAndPlainTextLimits() throws {
        let (_, noteHandler) = try makeNoteHandler()
        let response = try send(noteHandler, method: "tools/list")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        for name in ["list_notes", "get_note", "create_note", "update_note", "append_note", "delete_note"] {
            let tool = try XCTUnwrap(tools.first { $0["name"] as? String == name })
            let input = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(input["type"] as? String, "object")
            XCTAssertEqual(input["additionalProperties"] as? Bool, false)
            XCTAssertNotNil(tool["outputSchema"] as? [String: Any])
        }

        let create = try XCTUnwrap(tools.first { $0["name"] as? String == "create_note" })
        let createInput = try XCTUnwrap(create["inputSchema"] as? [String: Any])
        let createProperties = try XCTUnwrap(createInput["properties"] as? [String: Any])
        let title = try XCTUnwrap(createProperties["title"] as? [String: Any])
        let body = try XCTUnwrap(createProperties["body"] as? [String: Any])
        XCTAssertEqual(title["maxLength"] as? Int, 512)
        XCTAssertEqual(body["maxLength"] as? Int, 262_144)

        for name in ["update_note", "append_note", "delete_note"] {
            let tool = try XCTUnwrap(tools.first { $0["name"] as? String == name })
            let input = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            let required = Set(try XCTUnwrap(input["required"] as? [String]))
            XCTAssertTrue(required.isSuperset(of: ["id", "revision"]))
        }
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
        XCTAssertEqual(note["contentFormat"] as? String, "plain_text")
        XCTAssertNotNil(note["revision"] as? String)
        XCTAssertEqual(noteStore.notes.count, 1)
    }

    func testCreateNoteAllowsEmptyBodyWhenTitleHasContent() throws {
        let (_, noteHandler) = try makeNoteHandler()
        let payload = try callNoteTool(noteHandler, "create_note", [
            "title": "Title only",
            "body": ""
        ])
        let note = try XCTUnwrap(payload["note"] as? [String: Any])
        XCTAssertEqual(note["body"] as? String, "")
    }

    func testCreateNotePreservesUnicodePlainTextExactly() throws {
        let (_, noteHandler) = try makeNoteHandler()
        let body = "\n  👩🏽‍💻 café — مرحبا\n# literal Markdown  "
        let payload = try callNoteTool(noteHandler, "create_note", ["body": body])
        let note = try XCTUnwrap(payload["note"] as? [String: Any])
        XCTAssertEqual(note["body"] as? String, body)
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
        _ = noteStore.create(title: "One", body: String(repeating: "a", count: 400))
        _ = noteStore.create(title: "Two", body: "b")

        let firstPage = try callNoteTool(handler, "list_notes", ["limit": 1])
        XCTAssertEqual(firstPage["count"] as? Int, 1)
        let summaries = try XCTUnwrap(firstPage["notes"] as? [[String: Any]])
        XCTAssertNil(summaries.first?["body"])
        XCTAssertNotNil(summaries.first?["preview"] as? String)
        XCTAssertNotNil(summaries.first?["revision"] as? String)

        let cursor = try XCTUnwrap(firstPage["nextCursor"] as? String)
        let secondPage = try callNoteTool(handler, "list_notes", ["limit": 1, "cursor": cursor])
        XCTAssertEqual(secondPage["count"] as? Int, 1)
        XCTAssertNil(secondPage["nextCursor"])
    }

    func testGetNoteReturnsFullBodyAndCurrentRevision() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let note = try XCTUnwrap(noteStore.create(title: "Title", body: "full body"))

        let payload = try callNoteTool(handler, "get_note", ["id": note.id.uuidString])
        let fetched = try XCTUnwrap(payload["note"] as? [String: Any])
        XCTAssertEqual(fetched["body"] as? String, "full body")
        XCTAssertNotNil(fetched["revision"] as? String)
    }

    func testUpdateNoteReplacesOnlyProvidedFieldsWithCurrentRevision() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let note = try XCTUnwrap(noteStore.create(title: "Title", body: "old"))
        let fetched = try callNoteTool(handler, "get_note", ["id": note.id.uuidString])
        let current = try XCTUnwrap(fetched["note"] as? [String: Any])
        let revision = try XCTUnwrap(current["revision"] as? String)

        let payload = try callNoteTool(handler, "update_note", [
            "id": note.id.uuidString,
            "revision": revision,
            "body": "new body"
        ])
        let updated = try XCTUnwrap(payload["note"] as? [String: Any])
        XCTAssertEqual(updated["body"] as? String, "new body")
        XCTAssertEqual(updated["title"] as? String, "Title")
        XCTAssertNotEqual(updated["revision"] as? String, revision)
        XCTAssertEqual(noteStore.notes.first?.body, "new body")
    }

    func testAppendNoteAddsContentExactlyWithoutImplicitSeparator() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let note = try XCTUnwrap(noteStore.create(title: "Log", body: "first"))
        let fetched = try callNoteTool(handler, "get_note", ["id": note.id.uuidString])
        let current = try XCTUnwrap(fetched["note"] as? [String: Any])

        let payload = try callNoteTool(handler, "append_note", [
            "id": note.id.uuidString,
            "revision": try XCTUnwrap(current["revision"] as? String),
            "content": "\n👋 second"
        ])
        let updated = try XCTUnwrap(payload["note"] as? [String: Any])
        XCTAssertEqual(updated["body"] as? String, "first\n👋 second")
    }

    func testStaleRevisionReturnsStructuredConflictWithoutOverwritingNewerEdit() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let note = try XCTUnwrap(noteStore.create(title: "Title", body: "v1"))
        let fetched = try callNoteTool(handler, "get_note", ["id": note.id.uuidString])
        let current = try XCTUnwrap(fetched["note"] as? [String: Any])
        let staleRevision = try XCTUnwrap(current["revision"] as? String)
        XCTAssertTrue(noteStore.update(note, body: "newer UI edit"))

        let response = try send(handler, method: "tools/call", params: [
            "name": "update_note",
            "arguments": [
                "id": note.id.uuidString,
                "revision": staleRevision,
                "body": "stale MCP edit"
            ]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let error = try XCTUnwrap(structured["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "conflict")
        XCTAssertNotNil(error["currentRevision"] as? String)
        XCTAssertEqual(noteStore.notes.first?.body, "newer UI edit")
    }

    func testNoteToolRejectsUnknownFieldsAndNULWithoutMutation() throws {
        let (noteStore, handler) = try makeNoteHandler()

        for arguments: [String: Any] in [
            ["body": "safe", "path": "/etc/passwd"],
            ["body": "bad\0text"]
        ] {
            let response = try send(handler, method: "tools/call", params: [
                "name": "create_note",
                "arguments": arguments
            ])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true)
        }
        XCTAssertTrue(noteStore.notes.isEmpty)
    }

    func testNoteBodyMaximumIsAcceptedAndOneByteOverIsRejected() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let accepted = String(repeating: "a", count: 262_144)
        _ = try callNoteTool(handler, "create_note", ["body": accepted])
        XCTAssertEqual(noteStore.notes.first?.body.utf8.count, 262_144)

        let response = try send(handler, method: "tools/call", params: [
            "name": "create_note",
            "arguments": ["body": accepted + "b"]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(noteStore.notes.count, 1)
    }

    func testNoteTitleMaximumIsAcceptedAndOneByteOverIsRejected() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let accepted = String(repeating: "t", count: 512)
        _ = try callNoteTool(handler, "create_note", ["title": accepted])
        XCTAssertEqual(noteStore.notes.first?.title.utf8.count, 512)

        let response = try send(handler, method: "tools/call", params: [
            "name": "create_note",
            "arguments": ["title": accepted + "x"]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(noteStore.notes.count, 1)
    }

    func testOversizedExistingUINoteReturnsSafeErrorButBoundedSummary() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let note = try XCTUnwrap(noteStore.create(
            title: String(repeating: "t", count: 600),
            body: String(repeating: "b", count: 262_145)
        ))

        let listPayload = try callNoteTool(handler, "list_notes", [:])
        let summaries = try XCTUnwrap(listPayload["notes"] as? [[String: Any]])
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary["titleTruncated"] as? Bool, true)
        XCTAssertLessThanOrEqual(try XCTUnwrap(summary["title"] as? String).utf8.count, 512)
        XCTAssertLessThanOrEqual(try XCTUnwrap(summary["preview"] as? String).utf8.count, 512)

        let response = try send(handler, method: "tools/call", params: [
            "name": "get_note",
            "arguments": ["id": note.id.uuidString]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let error = try XCTUnwrap(structured["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "content_too_large")
    }

    func testNonexistentNoteIDReturnsNotFoundCode() throws {
        let (_, handler) = try makeNoteHandler()
        let response = try send(handler, method: "tools/call", params: [
            "name": "get_note",
            "arguments": ["id": UUID().uuidString]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let error = try XCTUnwrap(structured["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "not_found")
    }

    func testNoteIDRejectsPathLikeInputAsInvalidArguments() throws {
        let (_, handler) = try makeNoteHandler()
        let response = try send(handler, method: "tools/call", params: [
            "name": "get_note",
            "arguments": ["id": "../../Library/private.store"]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let error = try XCTUnwrap(structured["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_arguments")
    }

    func testDeleteNoteRemovesNote() throws {
        let (noteStore, handler) = try makeNoteHandler()
        let note = try XCTUnwrap(noteStore.create(body: "Remove me"))
        let fetched = try callNoteTool(handler, "get_note", ["id": note.id.uuidString])
        let current = try XCTUnwrap(fetched["note"] as? [String: Any])

        let payload = try callNoteTool(handler, "delete_note", [
            "id": note.id.uuidString,
            "revision": try XCTUnwrap(current["revision"] as? String)
        ])
        XCTAssertEqual(payload["deleted"] as? String, note.id.uuidString)
        XCTAssertTrue(noteStore.notes.isEmpty)
    }

    func testNoteToolsUpdateAndDeleteEveryPhysicalReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        context.insert(NoteItem(
            id: sharedID,
            title: "Older",
            body: "a",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        context.insert(NoteItem(
            id: sharedID,
            title: "Visible",
            body: "b",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        ))
        try context.save()
        let duplicateStore = NoteStore(container: container)
        let duplicateHandler = MCPRequestHandler(
            tools: AgentTaskTools(store: store, noteStore: duplicateStore),
            serverVersion: "test"
        )
        let fetchedPayload = try callNoteTool(
            duplicateHandler,
            "get_note",
            ["id": sharedID.uuidString]
        )
        let fetched = try XCTUnwrap(fetchedPayload["note"] as? [String: Any])
        let updatedPayload = try callNoteTool(duplicateHandler, "update_note", [
            "id": sharedID.uuidString,
            "revision": try XCTUnwrap(fetched["revision"] as? String),
            "body": "unified"
        ])

        var verificationContext = ModelContext(container)
        var replicas = try verificationContext.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(replicas.count, 2)
        XCTAssertTrue(replicas.allSatisfy { $0.title == "Visible" && $0.body == "unified" })

        let updated = try XCTUnwrap(updatedPayload["note"] as? [String: Any])
        _ = try callNoteTool(duplicateHandler, "delete_note", [
            "id": sharedID.uuidString,
            "revision": try XCTUnwrap(updated["revision"] as? String)
        ])
        verificationContext = ModelContext(container)
        replicas = try verificationContext.fetch(FetchDescriptor<NoteItem>())
        XCTAssertTrue(replicas.isEmpty)
    }

    func testNoteToolsAreUnknownWhenNoNoteStoreProvided() throws {
        let response = try send(method: "tools/call", params: ["name": "list_notes"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    private func makeNoteHandler() throws -> (NoteStore, MCPRequestHandler) {
        let noteStore = try makeTestNoteStore()
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

    private func send(
        _ target: MCPRequestHandler,
        method: String,
        params: [String: Any] = [:],
        id: Int = 1
    ) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])
        return try decode(target.handle(body: body))
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

@MainActor
final class AgentServerIntegrationTests: XCTestCase {
    func testLoopbackProtocolBoundaryAndTemporaryDevelopmentStoreRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("development.store")
        let token = "integration-test-token"

        var firstContainer: ModelContainer? = try makeContainer(at: storeURL)
        var taskStore: TaskStore? = TaskStore(container: try XCTUnwrap(firstContainer))
        var noteStore: NoteStore? = NoteStore(container: try XCTUnwrap(firstContainer))
        var server: AgentServer? = AgentServer(
            port: 0,
            bearerToken: token,
            handler: MCPRequestHandler(
                tools: AgentTaskTools(
                    store: try XCTUnwrap(taskStore),
                    noteStore: try XCTUnwrap(noteStore)
                ),
                serverVersion: "integration-test"
            )
        )
        defer { server?.stop() }
        try XCTUnwrap(server).start()
        let firstPort = try await waitUntilRunning(try XCTUnwrap(server))
        let firstEndpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(firstPort)/mcp"))

        let ping = try rpcBody(method: "ping")
        let unauthorized = try await MCPTestClient.post(
            endpoint: firstEndpoint,
            token: nil,
            body: ping
        )
        XCTAssertEqual(unauthorized.response.statusCode, 401)
        XCTAssertTrue(unauthorized.data.isEmpty)

        let malformed = try await MCPTestClient.post(
            endpoint: firstEndpoint,
            token: token,
            body: Data("not json".utf8)
        )
        XCTAssertEqual(malformed.response.statusCode, 200)
        let malformedJSON = try decodeObject(malformed.data)
        let malformedError = try XCTUnwrap(malformedJSON["error"] as? [String: Any])
        XCTAssertEqual(malformedError["code"] as? Int, -32700)

        let discovery = try await call(
            endpoint: firstEndpoint,
            token: token,
            method: "tools/list"
        )
        let discoveryResult = try XCTUnwrap(discovery["result"] as? [String: Any])
        let discoveredTools = try XCTUnwrap(discoveryResult["tools"] as? [[String: Any]])
        XCTAssertTrue(discoveredTools.contains { $0["name"] as? String == "get_note" })
        XCTAssertTrue(discoveredTools.contains { $0["name"] as? String == "append_note" })
        XCTAssertTrue(discoveredTools.contains { $0["name"] as? String == "create_task" })

        let createdPayload = try await callTool(
            endpoint: firstEndpoint,
            token: token,
            name: "create_note",
            arguments: ["title": "Smoke", "body": "first 👋"]
        )
        let created = try XCTUnwrap(createdPayload["note"] as? [String: Any])
        let noteID = try XCTUnwrap(created["id"] as? String)
        let revision = try XCTUnwrap(created["revision"] as? String)

        let listedPayload = try await callTool(
            endpoint: firstEndpoint,
            token: token,
            name: "list_notes",
            arguments: ["limit": 100]
        )
        let listedNotes = try XCTUnwrap(listedPayload["notes"] as? [[String: Any]])
        XCTAssertTrue(listedNotes.contains { $0["id"] as? String == noteID })

        let appendedPayload = try await callTool(
            endpoint: firstEndpoint,
            token: token,
            name: "append_note",
            arguments: [
                "id": noteID,
                "revision": revision,
                "content": "\nsecond"
            ]
        )
        let appended = try XCTUnwrap(appendedPayload["note"] as? [String: Any])
        XCTAssertEqual(appended["body"] as? String, "first 👋\nsecond")

        let updatedPayload = try await callTool(
            endpoint: firstEndpoint,
            token: token,
            name: "update_note",
            arguments: [
                "id": noteID,
                "revision": try XCTUnwrap(appended["revision"] as? String),
                "title": "Updated smoke"
            ]
        )
        let updated = try XCTUnwrap(updatedPayload["note"] as? [String: Any])
        XCTAssertEqual(updated["title"] as? String, "Updated smoke")

        let concurrentBodies = try (0..<8).map { index in
            try rpcBody(method: "tools/call", params: [
                "name": "create_note",
                "arguments": ["body": "concurrent-\(index)"]
            ], id: index + 20)
        }
        let concurrentResponses = try await withThrowingTaskGroup(of: Data.self) { group in
            for body in concurrentBodies {
                group.addTask {
                    let result = try await MCPTestClient.post(
                        endpoint: firstEndpoint,
                        token: token,
                        body: body
                    )
                    guard result.response.statusCode == 200 else {
                        throw MCPTestClient.Failure.unexpectedStatus(result.response.statusCode)
                    }
                    return result.data
                }
            }
            var collected: [Data] = []
            for try await data in group {
                collected.append(data)
            }
            return collected
        }
        XCTAssertEqual(concurrentResponses.count, 8)
        for responseData in concurrentResponses {
            let response = try decodeObject(responseData)
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false)
        }

        try XCTUnwrap(server).stop()
        server = nil
        noteStore = nil
        taskStore = nil
        firstContainer = nil

        let relaunchedContainer = try makeContainer(at: storeURL)
        let relaunchedTaskStore = TaskStore(container: relaunchedContainer)
        let relaunchedNoteStore = NoteStore(container: relaunchedContainer)
        let relaunchedServer = AgentServer(
            port: 0,
            bearerToken: token,
            handler: MCPRequestHandler(
                tools: AgentTaskTools(
                    store: relaunchedTaskStore,
                    noteStore: relaunchedNoteStore
                ),
                serverVersion: "integration-test"
            )
        )
        relaunchedServer.start()
        defer { relaunchedServer.stop() }
        let relaunchedPort = try await waitUntilRunning(relaunchedServer)
        let relaunchedEndpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(relaunchedPort)/mcp")
        )

        let relaunchedPayload = try await callTool(
            endpoint: relaunchedEndpoint,
            token: token,
            name: "get_note",
            arguments: ["id": noteID]
        )
        let persisted = try XCTUnwrap(relaunchedPayload["note"] as? [String: Any])
        XCTAssertEqual(persisted["title"] as? String, "Updated smoke")
        XCTAssertEqual(persisted["body"] as? String, "first 👋\nsecond")

        let taskPayload = try await callTool(
            endpoint: relaunchedEndpoint,
            token: token,
            name: "create_task",
            arguments: ["title": "Existing task tools still work"]
        )
        XCTAssertNotNil(taskPayload["task"] as? [String: Any])

        let deletedPayload = try await callTool(
            endpoint: relaunchedEndpoint,
            token: token,
            name: "delete_note",
            arguments: [
                "id": noteID,
                "revision": try XCTUnwrap(persisted["revision"] as? String)
            ]
        )
        XCTAssertEqual(deletedPayload["deleted"] as? String, noteID)
        XCTAssertFalse(relaunchedNoteStore.notes.contains { $0.id.uuidString == noteID })
    }

    private func makeContainer(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "development-test",
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: TaskItem.self,
            NoteItem.self,
            configurations: configuration
        )
    }

    private func waitUntilRunning(_ server: AgentServer) async throws -> UInt16 {
        for _ in 0..<200 {
            if case .running = server.state, let port = server.listeningPort {
                return port
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Agent server did not start: \(server.state)")
        throw MCPTestClient.Failure.serverDidNotStart
    }

    private func call(
        endpoint: URL,
        token: String,
        method: String,
        params: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let result = try await MCPTestClient.post(
            endpoint: endpoint,
            token: token,
            body: try rpcBody(method: method, params: params)
        )
        XCTAssertEqual(result.response.statusCode, 200)
        return try decodeObject(result.data)
    }

    private func callTool(
        endpoint: URL,
        token: String,
        name: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        let response = try await call(
            endpoint: endpoint,
            token: token,
            method: "tools/call",
            params: ["name": name, "arguments": arguments]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try decodeObject(Data(text.utf8))
    }

    private func rpcBody(
        method: String,
        params: [String: Any] = [:],
        id: Int = 1
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])
    }

    private func decodeObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private enum MCPTestClient {
    enum Failure: Error, Sendable {
        case serverDidNotStart
        case unexpectedStatus(Int)
    }

    static func post(
        endpoint: URL,
        token: String?,
        body: Data
    ) async throws -> (response: HTTPURLResponse, data: Data) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }
}
