import Foundation
import XCTest
@testable import Attic

@MainActor
final class AgentCLIStreamTests: XCTestCase {
    func testClaudeStreamingToolStepAndSingleFinalAnswer() throws {
        var stream = AgentCLIStreamDecoder(backend: .claude, instructions: "Attic", workingDirectory: "/tmp")
        let first = stream.beginTurn("List tasks")
        XCTAssertEqual(try decoded(first.outbound[0])["type"] as? String, "user")

        let session = stream.accept(#"{"type":"system","subtype":"init","session_id":"claude-session"}"#)
        XCTAssertEqual(session.sessionID, "claude-session")
        let delta = stream.accept(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Here "}}}"#)
        XCTAssertEqual(delta.events, [.textDelta("Here ")])
        let next = stream.accept(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"are tasks."}}}"#)
        XCTAssertEqual(next.events, [.textDelta("are tasks.")])
        let earlyTool = stream.accept(#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"use-1","name":"mcp__attic__list_tasks","input":{}}}}"#)
        XCTAssertTrue(earlyTool.events.contains { if case .stepStarted = $0 { return true }; return false },
                      "Show a tool step as soon as Claude begins it")
        let tool = stream.accept(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Here are tasks."},{"type":"tool_use","id":"use-1","name":"mcp__attic__list_tasks","input":{}}]}}"#)
        XCTAssertEqual(tool.events.filter { if case .textDelta = $0 { return true }; return false }.count, 0, "Claude's full assistant block must not duplicate the streamed deltas")
        XCTAssertFalse(tool.events.contains { if case .stepStarted = $0 { return true }; return false },
                       "A complete tool block must not show a second step")
        let result = stream.accept(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"use-1","content":"[]"}]}}"#)
        XCTAssertTrue(result.events.contains { if case .stepFinished(let step) = $0 { return step.state == .done }; return false })
        let end = stream.accept(#"{"type":"result","is_error":false,"result":"Here are tasks."}"#)
        XCTAssertTrue(end.turnEnded)
        XCTAssertTrue(end.events.isEmpty)
    }

    func testClaudeToolFailureAndForbiddenTool() {
        var stream = AgentCLIStreamDecoder(backend: .claude, instructions: "Attic", workingDirectory: "/tmp")
        _ = stream.beginTurn("Try")
        _ = stream.accept(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"use-2","name":"mcp__attic__update_task","input":{}}]}}"#)
        let failed = stream.accept(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"use-2","is_error":true,"content":"No."}]}}"#)
        XCTAssertTrue(failed.events.contains { if case .stepFinished(let step) = $0 { if case .failed = step.state { return true } }; return false })
        let forbidden = stream.accept(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"use-3","name":"Bash","input":{"command":"pwd"}}]}}"#)
        XCTAssertNotNil(forbidden.failure)
    }

    func testPartialBatchStreamPreservesCommittedTargetsAndErrors() throws {
        let saved = UUID()
        let envelope: [String: Any] = [
            "status": "partial", "message": "1 of 2 operations failed",
            "step": ["title": "Create tasks", "kind": "create", "state": "done",
                     "targets": [["page": "tasks", "item_id": saved.uuidString, "title": "Saved task"]]],
            "data": ["results": [
                ["index": 0, "status": "done"],
                ["index": 1, "status": "failed", "error": "Missing title"]
            ]]
        ]
        let resultText = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        var claude = AgentCLIStreamDecoder(backend: .claude, instructions: "Attic", workingDirectory: "/tmp")
        _ = claude.beginTurn("Create two tasks")
        _ = claude.accept(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"partial","name":"mcp__attic__create_tasks"}]}}"#)
        let finishedLine = String(decoding: try JSONSerialization.data(withJSONObject: [
            "type": "user", "message": ["content": [[
                "type": "tool_result", "tool_use_id": "partial", "content": resultText
            ]]]
        ]), as: UTF8.self)
        let step = try XCTUnwrap(claude.accept(finishedLine).events.compactMap { event -> AgentStep? in
            if case let .stepFinished(value) = event { return value }
            return nil
        }.first)
        XCTAssertEqual(step.targets.first?.itemID, saved)
        if case let .partial(reason) = step.state {
            XCTAssertTrue(reason.contains("Missing title"))
        } else { XCTFail("Partial success should be distinct from total failure") }
    }

    func testCodexHandshakeStreamingAndParallelTools() throws {
        var stream = AgentCLIStreamDecoder(backend: .codex, instructions: "Attic", workingDirectory: "/tmp")
        let first = stream.beginTurn("Two tools")
        XCTAssertEqual(try decoded(first.outbound[0])["method"] as? String, "initialize")
        let initResponse = stream.accept(#"{"jsonrpc":"2.0","id":1,"result":{"userAgent":"Codex"}}"#)
        XCTAssertEqual(initResponse.outbound.count, 2)
        XCTAssertEqual(try decoded(initResponse.outbound[0])["method"] as? String, "initialized")
        XCTAssertEqual(try decoded(initResponse.outbound[1])["method"] as? String, "thread/start")
        let started = stream.accept(#"{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread-1"}}}"#)
        XCTAssertEqual(started.sessionID, "thread-1")
        XCTAssertEqual(try decoded(started.outbound[0])["method"] as? String, "turn/start")
        _ = stream.accept(#"{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn-1"}}}"#)
        let text = stream.accept(#"{"method":"item/agentMessage/delta","params":{"delta":"Hello"}}"#)
        XCTAssertEqual(text.events, [.textDelta("Hello")])
        let tool1 = stream.accept(#"{"method":"item/started","params":{"item":{"id":"c1","type":"mcpToolCall","server":"attic","tool":"list_tasks"}}}"#)
        let tool2 = stream.accept(#"{"method":"item/started","params":{"item":{"id":"c2","type":"mcpToolCall","server":"attic","tool":"list_notes"}}}"#)
        XCTAssertTrue(tool1.events.contains { if case .stepStarted = $0 { return true }; return false })
        XCTAssertTrue(tool2.events.contains { if case .progress(let done, let total) = $0 { return done == 0 && total == 2 }; return false })
        _ = stream.accept(#"{"method":"item/completed","params":{"item":{"id":"c2","type":"mcpToolCall","server":"attic","tool":"list_notes","status":"completed"}}}"#)
        let completion = stream.accept(#"{"method":"item/completed","params":{"item":{"id":"c1","type":"mcpToolCall","server":"attic","tool":"list_tasks","status":"completed"}}}"#)
        XCTAssertTrue(completion.events.contains { if case .progress(let done, let total) = $0 { return done == 2 && total == 2 }; return false })
        let end = stream.accept(#"{"method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
        XCTAssertTrue(end.turnEnded)
        XCTAssertTrue(end.events.isEmpty)

        let second = stream.beginTurn("Again")
        XCTAssertEqual(try decoded(second.outbound[0])["method"] as? String, "turn/start")
    }

    func testCodexResumesAndRejectsNonAtticTools() throws {
        var stream = AgentCLIStreamDecoder(backend: .codex, instructions: "Attic", sessionID: "old-thread", workingDirectory: "/tmp")
        _ = stream.beginTurn("Resume")
        let response = stream.accept(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        XCTAssertEqual(try decoded(response.outbound[1])["method"] as? String, "thread/resume")
        let invalid = stream.accept(#"{"method":"item/started","params":{"item":{"id":"f1","type":"commandExecution","command":"pwd"}}}"#)
        XCTAssertNotNil(invalid.failure)
    }

    func testClaudeRefusalAndCodexError() {
        var claude = AgentCLIStreamDecoder(backend: .claude, instructions: "Attic", workingDirectory: "/tmp")
        _ = claude.beginTurn("No")
        let refusal = claude.accept(#"{"type":"result","is_error":true,"result":"I cannot help."}"#)
        XCTAssertNotNil(refusal.failure)
        var codex = AgentCLIStreamDecoder(backend: .codex, instructions: "Attic", workingDirectory: "/tmp")
        _ = codex.beginTurn("No")
        let error = codex.accept(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Bad request"}}"#)
        XCTAssertNotNil(error.failure)
    }

    func testMCPActionResultsSupplyRealTargetsToBothBackends() throws {
        let taskID = UUID()
        let canvasID = UUID()
        let result: [String: Any] = [
            "status": "done",
            "step": ["id": UUID().uuidString, "title": "Moved report to Friday", "kind": "move",
                     "to_day": "2026-11-13T00:00:00Z", "state": "done",
                     "targets": [["page": "tasks", "item_id": taskID.uuidString, "title": "Report",
                                  "external_id": "event-identifier", "container_id": canvasID.uuidString]]]
        ]
        let resultText = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)

        var claude = AgentCLIStreamDecoder(backend: .claude, instructions: "Attic", workingDirectory: "/tmp")
        _ = claude.beginTurn("Move report")
        _ = claude.accept(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"claude-use","name":"mcp__attic__move_task"}]}}"#)
        let claudeLine = String(decoding: try JSONSerialization.data(withJSONObject: [
            "type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "claude-use", "content": resultText]
            ]]
        ]), as: UTF8.self)
        let claudeFinish = claude.accept(claudeLine)
        let claudeStep = try XCTUnwrap(claudeFinish.events.compactMap { event -> AgentStep? in
            if case let .stepFinished(step) = event { return step }
            return nil
        }.first)
        XCTAssertEqual(claudeStep.title, "Moved report to Friday")
        XCTAssertEqual(claudeStep.targets.first?.itemID, taskID)
        XCTAssertEqual(claudeStep.targets.first?.title, "Report")
        XCTAssertEqual(claudeStep.targets.first?.externalID, "event-identifier")
        XCTAssertEqual(claudeStep.targets.first?.containerID, canvasID)
        if case let .move(toDay) = claudeStep.kind { XCTAssertNotNil(toDay) }
        else { XCTFail("The real action kind must override the tool-name guess") }

        var codex = AgentCLIStreamDecoder(backend: .codex, instructions: "Attic", workingDirectory: "/tmp")
        _ = codex.beginTurn("Move report")
        _ = codex.accept(#"{"method":"item/started","params":{"item":{"id":"codex-use","type":"mcpToolCall","server":"attic","tool":"move_task"}}}"#)
        let codexLine = String(decoding: try JSONSerialization.data(withJSONObject: [
            "method": "item/completed", "params": ["item": [
                "id": "codex-use", "type": "mcpToolCall", "server": "attic", "tool": "move_task",
                "status": "completed", "result": ["content": [["type": "text", "text": resultText]]]
            ]]
        ]), as: UTF8.self)
        let codexFinish = codex.accept(codexLine)
        let codexStep = try XCTUnwrap(codexFinish.events.compactMap { event -> AgentStep? in
            if case let .stepFinished(step) = event { return step }
            return nil
        }.first)
        XCTAssertEqual(codexStep.title, "Moved report to Friday")
        XCTAssertEqual(codexStep.targets.first?.itemID, taskID)
        XCTAssertEqual(codexStep.targets.first?.page, .tasks)
        XCTAssertEqual(codexStep.state, .done)
    }

    #if !ATTIC_GENERATED_TESTS
    func testStepWordsComeFromActualCountsDaysAndResults() throws {
        let friday = "2026-11-13"
        let arguments: [String: Any] = ["updates": [
            ["query": "Review A", "due": friday],
            ["query": "Review B", "due": friday],
            ["query": "Review C", "due": friday]
        ]]
        var decoder = AgentCLIStreamDecoder(backend: .codex, instructions: "Attic", workingDirectory: "/tmp")
        _ = decoder.beginTurn("Move reviews")
        let initial = try JSONSerialization.data(withJSONObject: ["method": "item/started", "params": ["item": [
            "id": "three", "type": "mcpToolCall", "server": "attic", "tool": "update_tasks", "arguments": arguments
        ]]])
        let live = try XCTUnwrap(decoder.accept(String(decoding: initial, as: UTF8.self)).events.compactMap {
            if case let .stepStarted(step) = $0 { return step }
            return nil
        }.first)
        XCTAssertEqual(live.title, "Moving 3 tasks to Friday")
        let envelope: [String: Any] = ["status": "done", "step": [
            "title": "Moved 2 tasks to Friday", "kind": "move", "state": "done", "targets": []
        ]]
        let reply = try JSONSerialization.data(withJSONObject: ["method": "item/completed", "params": ["item": [
            "id": "three", "type": "mcpToolCall", "server": "attic", "tool": "update_tasks",
            "result": ["content": [["type": "text", "text": String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)]]]
        ]]])
        let done = try XCTUnwrap(decoder.accept(String(decoding: reply, as: UTF8.self)).events.compactMap {
            if case let .stepFinished(step) = $0 { return step }
            return nil
        }.first)
        XCTAssertEqual(done.title, "Moved 2 tasks to Friday")

        let tasks = AgentActionWords.completed("list_tasks", ["due_before": "2026-11-09"],
            response: #"{"count":7,"tasks":[]}"#, targets: [])
        XCTAssertEqual(tasks, "Read 7 overdue tasks")
        let sketch = AgentActionWords.completed("draw_add_text", ["text": "Press kit"],
            response: #"{"object":{"canvas_name":"Launch plan","text":"Press kit"}}"#, targets: [])
        XCTAssertEqual(sketch, "Added Press kit to Launch plan")
        let calendar = AgentActionWords.completed("calendar_create", ["start": "2026-11-13T10:00:00Z"],
            response: #"{"title":"Dentist"}"#, targets: [])
        XCTAssertEqual(calendar, "Added Dentist to Friday")
        let note = AgentActionWords.completed("update_note", ["body": "- [ ] Plan a launch"],
            response: #"{"status":"applied","note":{"title":"Launch notes"}}"#,
            targets: [.init(page: .notes, title: "Launch notes")], previousNoteBody: "Draft outline")
        XCTAssertEqual(note, "Added a checklist to Launch notes")
    }

    func testClaudeStreamingInputsRewordTheRunningStep() throws {
        var decoder = AgentCLIStreamDecoder(backend: .claude, instructions: "Attic", workingDirectory: "/tmp")
        _ = decoder.beginTurn("Add a calendar event")
        let start = decoder.accept(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"event-1","name":"mcp__attic__calendar_create","input":{}}}}"#)
        XCTAssertTrue(start.events.contains { if case .stepStarted = $0 { return true }; return false })
        _ = decoder.accept(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"title\":\"Dentist\",\"start\":\"2026-11-13T10:00:00Z\"}"}}}"#)
        let reword = decoder.accept(#"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#)
        XCTAssertTrue(reword.events.contains { if case let .stepReworded(step) = $0 { return step.title == "Adding Dentist to Calendar" }; return false })
    }

    func testPendingAndDeniedApprovalsNeverShowCompletedChanges() throws {
        func result(_ status: String) throws -> String {
            let payload: [String: Any] = ["status": status,
                                          "approval_title": "Delete Pay rent?",
                                          "approvalNeeded": ["title": "Delete Pay rent?"],
                                          "message": "Read only: action refused"]
            return String(decoding: try JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)]]
            ]), as: UTF8.self)
        }
        var stream = AgentCLIStreamDecoder(backend: .codex, instructions: "Attic", workingDirectory: "/tmp")
        _ = stream.beginTurn("Delete a task")
        func accept(_ id: String, _ stage: String, _ result: String? = nil) -> AgentCLITransition {
            let item: [String: Any] = ["id": id, "type": "mcpToolCall", "server": "attic",
                                       "tool": "delete_task", "result": result ?? ""]
            let message: [String: Any] = ["method": "item/\(stage)", "params": ["item": item]]
            return stream.accept(String(decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self))
        }
        _ = accept("a", "started")
        let pending = try XCTUnwrap(accept("a", "completed", result("waiting")).events.compactMap {
            if case let .stepFinished(value) = $0 { return value }; return nil
        }.first)
        XCTAssertEqual(pending.title, "Awaiting approval: Delete Pay rent")
        XCTAssertEqual(pending.kind, .read)
        _ = accept("b", "started")
        let refusal = try XCTUnwrap(accept("b", "completed", result("refused")).events.compactMap {
            if case let .stepFinished(value) = $0 { return value }; return nil
        }.first)
        XCTAssertEqual(refusal.title, "Refused: Delete Pay rent")
        XCTAssertEqual(refusal.kind, .read)
        if case .failed = refusal.state {} else { XCTFail("Refused actions must fail in the thread") }
    }
    #endif

    private func decoded(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
}
