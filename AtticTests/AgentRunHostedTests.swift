import Foundation
import XCTest
@testable import Attic

@MainActor
final class AgentRunHostedTests: XCTestCase {
    /// Explicit Air-only integration gate: the real signed-in Codex process
    /// uses the same sandboxed host and MCP server as Chat, against an empty
    /// in-memory test store. Never run against a person's Attic identity.
    func testRealCodexReadsWritesNeedsApprovalAndUndoesUsingAtticTools() async throws {
        guard ProcessInfo.processInfo.environment["ATTIC_REAL_CODEX_SMOKE"] == "1" else {
            throw XCTSkip("Air-only live Codex gate; set ATTIC_REAL_CODEX_SMOKE=1")
        }
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let tools = AgentTaskTools(store: store, library: library)
        let server = AgentServer(port: 0, bearerToken: try AgentAccessTokenStore.generateToken(),
                                 handler: MCPRequestHandler(tools: tools, actions: AgentActions(tasks: tools)))
        let runner = AgentRunEngine(selectedBackend: { .codex },
                                    tools: { AgentRunMCPServer.live(server: server) },
                                    journalURL: journalURL(), undo: { id in
            let result = try await server.undoFinishedAgentChangeSet(id: id)
            guard result.failures.isEmpty, result.remaining == nil else {
                throw AgentRunError.undoUnavailable
            }
        })
        defer { runner.shutdown(); server.stop() }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(110))
            if runner.threadSnapshot().isRunning { runner.cancel() }
        }
        defer { watchdog.cancel() }

        let prompt = """
        Exercise the real Attic MCP tools for this isolated test store. First CALL list_tasks to read the tasks.
        Next CALL create_task with title 'Attic CLI smoke item'. Then CALL delete_task for that created item.
        Deleting needs my approval: wait for approval, then poll agent_approval_status if told to wait.
        Report completion only after those real Attic calls. Do not guess the store's state or answer without tools.
        """
        var events = [AgentEvent]()
        for await event in runner.send(prompt, watching: true) {
            events.append(event)
            if case let .approvalNeeded(approval) = event {
                runner.resolve(approval: approval.id, allow: true)
            }
        }
        let steps = events.compactMap { event -> AgentStep? in
            if case let .stepFinished(step) = event { return step }
            return nil
        }
        XCTAssertTrue(steps.contains { $0.title.lowercased().contains("list") }, "Codex must read through Attic MCP")
        XCTAssertTrue(steps.contains { $0.kind == .create }, "Codex must write through Attic MCP")
        XCTAssertTrue(steps.contains { $0.kind == .delete }, "Codex must request a protected deletion")
        XCTAssertTrue(events.contains { if case .approvalNeeded = $0 { return true }; return false },
                      "Deletion must need a trusted owner approval")
        let changes = try XCTUnwrap(events.compactMap { event -> AgentChangeSet? in
            if case let .changes(set) = event { return set }
            return nil
        }.last)
        XCTAssertEqual(changes.count, 2)
        try await runner.undo(changeSet: changes.id)
        XCTAssertTrue(store.tasks.isEmpty, "Undo must return the test store to its initial state")
        XCTAssertEqual(events.last, .finished)
    }

    func testStreamingBackgroundReopenAndRelaunch() async throws {
        let url = journalURL()
        let helper = FakeRunHelper()
        let tools = FakeRunTools()
        let runner = AgentRunEngine(helper: { helper }, tools: { tools }, journalURL: url)
        _ = runner.send("Hello", watching: true)
        await wait { helper.inputs.count == 1 }

        helper.emitLine(#"{"type":"system","subtype":"init","session_id":"claude-remembered"}"#)
        helper.emitLine(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello from "}}}"#)
        await wait { runner.threadSnapshot().entries.last?.text == "Hello from " }
        runner.setWatching(false)
        helper.emitLine(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Attic."}}}"#)
        let reopened = runner.observe()
        var iterator = reopened.makeAsyncIterator()
        let firstObservedEvent = await iterator.next()
        XCTAssertEqual(firstObservedEvent, .textDelta("Hello from "))
        helper.emitLine(#"{"type":"result","is_error":false}"#)
        await wait { !runner.threadSnapshot().isRunning }
        XCTAssertEqual(runner.threadSnapshot().entries.filter { $0.role == "assistant" }.last?.text,
                       "Hello from Attic.")
        XCTAssertTrue(helper.stopped, "A completed turn must release its CLI helper")
        XCTAssertTrue(tools.closed, "The temporary MCP endpoint must close after the turn")
        runner.shutdown()

        let relaunchHelper = FakeRunHelper()
        let reopenedRunner = AgentRunEngine(helper: { relaunchHelper },
                                            tools: { FakeRunTools() }, journalURL: url)
        XCTAssertEqual(reopenedRunner.threadSnapshot().entries.filter { $0.role == "assistant" }.last?.text,
                       "Hello from Attic.")
        _ = reopenedRunner.send("Second turn", watching: true)
        await wait { relaunchHelper.startedSession != nil }
        XCTAssertEqual(relaunchHelper.startedSession, "claude-remembered")
        reopenedRunner.cancel()
    }

    func testCancelMidStreamStopsHelperAndToolServer() async {
        let helper = FakeRunHelper()
        let tools = FakeRunTools()
        let runner = AgentRunEngine(helper: { helper }, tools: { tools }, journalURL: journalURL())
        _ = runner.send("Keep going", watching: true)
        await wait { helper.inputs.count == 1 }
        helper.emitLine(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Partial"}}}"#)
        await wait { runner.threadSnapshot().entries.last?.text == "Partial" }
        runner.cancel()
        XCTAssertFalse(runner.threadSnapshot().isRunning)
        XCTAssertTrue(helper.stopped)
        XCTAssertTrue(tools.closed)
        XCTAssertTrue(runner.threadSnapshot().events.contains {
            if case let .failed(message) = $0 { return message.contains("cancelled") }; return false
        })
    }

    func testMissingOrSignedOutCLIFailsWithActionableMessage() async {
        let helper = FakeRunHelper()
        helper.startFailure = "Sign in with claude auth login."
        let runner = AgentRunEngine(helper: { helper }, tools: { FakeRunTools() }, journalURL: journalURL())
        _ = runner.send("Hello", watching: false)
        await wait { !runner.threadSnapshot().isRunning }
        XCTAssertTrue(runner.threadSnapshot().events.contains {
            if case let .failed(message) = $0 { return message.contains("claude auth login") }; return false
        })
    }

    func testApprovalWaitsWhileChatIsClosed() async throws {
        let helper = FakeRunHelper()
        let runner = AgentRunEngine(helper: { helper }, tools: { FakeRunTools() }, journalURL: journalURL())
        _ = runner.send("Update", watching: true)
        await wait { helper.inputs.count == 1 }
        runner.setWatching(false)
        helper.emitLine(#"{"type":"control_request","request_id":"approval-1","request":{"subtype":"can_use_tool","tool_name":"mcp__attic__update_task","input":{"id":"item"}}}"#)
        await wait { runner.threadSnapshot().events.contains { if case .approvalNeeded = $0 { return true }; return false } }
        XCTAssertEqual(helper.inputs.count, 1, "No response is sent before the owner answers")
        guard let approval = runner.threadSnapshot().events.compactMap({ event -> AgentApproval? in
            if case .approvalNeeded(let approval) = event { return approval }
            return nil
        }).first else { return XCTFail("Expected an approval") }
        runner.resolve(approval: approval.id, allow: false)
        await wait { helper.inputs.count == 2 }
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(helper.inputs[1].utf8)) as? [String: Any])
        XCTAssertEqual(((response["response"] as? [String: Any])?["response"] as? [String: Any])?["behavior"] as? String,
                       "deny")
        runner.cancel()
    }

    func testCodexTextAndToolStepsViaFakeAppServer() async {
        let helper = FakeRunHelper()
        helper.onInput = { line, helper in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            switch method {
            case "initialize": helper.emitLine(#"{"id":1,"result":{}}"#)
            case "thread/start": helper.emitLine(#"{"id":2,"result":{"thread":{"id":"codex-thread"}}}"#)
            case "turn/start":
                helper.emitLine(#"{"id":3,"result":{"turn":{"id":"turn"}}}"#)
                helper.emitLine(#"{"method":"item/agentMessage/delta","params":{"delta":"Done."}}"#)
                helper.emitLine(#"{"method":"item/started","params":{"item":{"id":"1","type":"mcpToolCall","server":"attic","tool":"list_tasks"}}}"#)
                helper.emitLine(#"{"method":"item/completed","params":{"item":{"id":"1","type":"mcpToolCall","server":"attic","tool":"list_tasks","status":"completed"}}}"#)
                helper.emitLine(#"{"method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
            default: break
            }
        }
        let runner = AgentRunEngine(selectedBackend: { .codex }, helper: { helper },
                                    tools: { FakeRunTools() }, journalURL: journalURL())
        _ = runner.send("List tasks", watching: true)
        await wait { !runner.threadSnapshot().isRunning }
        XCTAssertEqual(runner.threadSnapshot().entries.first { $0.role == "assistant" }?.text, "Done.")
        XCTAssertTrue(runner.threadSnapshot().events.contains { if case .stepFinished = $0 { return true }; return false })
        runner.shutdown()
    }

    func testRunScopedApprovalAndDurableUndoID() async throws {
        let helper = FakeRunHelper()
        let tools = FakeRunTools()
        let changeID = UUID()
        let change = AgentChangeSet(id: changeID, title: "Updated task", pages: [.tasks], count: 1)
        tools.change = change
        var undone: UUID?
        let runner = AgentRunEngine(helper: { helper }, tools: { tools }, journalURL: journalURL(),
                                    undo: { id in undone = id })
        _ = runner.send("Change a task", watching: true)
        await wait { helper.inputs.count == 1 }
        runner.setWatching(false)
        XCTAssertEqual(tools.watchingHistory.last, false)
        let approval = AgentApproval(id: UUID(), title: "Update task?", targets: [])
        tools.approval = approval
        await wait { runner.threadSnapshot().events.contains(.approvalNeeded(approval)) }
        runner.resolve(approval: approval.id, allow: false)
        await wait { tools.resolved[approval.id] == false }
        helper.emitLine(#"{"type":"result","is_error":false}"#)
        await wait { !runner.threadSnapshot().isRunning }
        let events = runner.threadSnapshot().events
        guard let changedIndex = events.firstIndex(of: .changes(change)),
              let finishedIndex = events.firstIndex(of: .finished) else {
            return XCTFail("Expected the real Undo change set and completion")
        }
        XCTAssertLessThan(changedIndex, finishedIndex, "The chat must receive Undo before completion")
        XCTAssertEqual(events.last, .finished)
        try await runner.undo(changeSet: changeID)
        XCTAssertEqual(undone, changeID)
    }

    func testCancelDuringHelperStartupStopsThePendingHelper() async {
        let helper = FakeRunHelper()
        helper.deferStart = true
        let tools = FakeRunTools()
        let runner = AgentRunEngine(helper: { helper }, tools: { tools }, journalURL: journalURL())
        _ = runner.send("Hello", watching: false)
        await wait { helper.startContinuation != nil }
        runner.cancel()
        XCTAssertTrue(helper.stopped)
        XCTAssertTrue(tools.closed)
        XCTAssertFalse(runner.threadSnapshot().isRunning)
        helper.completeStart()
    }

    private func journalURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("attic-agent-hosted-\(UUID().uuidString).json")
    }

    private func wait(_ predicate: @escaping @MainActor () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<250 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Agent fixture did not advance", file: file, line: line)
    }
}

@MainActor
private final class FakeRunTools: AgentRunToolServing {
    var closed = false
    var watchingHistory: [Bool] = []
    var approval: AgentApproval?
    var change: AgentChangeSet?
    var resolved: [UUID: Bool] = [:]
    func open(title: String, watching: Bool) async throws -> AgentRunMCPAddress {
        watchingHistory.append(watching)
        return AgentRunMCPAddress(url: "http://127.0.0.1:4400/mcp", token: String(repeating: "a", count: 43))
    }
    func setWatching(_ watching: Bool) { watchingHistory.append(watching) }
    func pendingApprovals() -> [AgentApproval] { approval.map { [$0] } ?? [] }
    func resolve(approval id: UUID, allow: Bool) async throws {
        resolved[id] = allow
        approval = nil
    }
    func changeSet() -> AgentChangeSet? { change }
    func close() { closed = true }
}

@MainActor
private final class FakeRunHelper: AgentHelperTransmitting {
    let events: AsyncStream<AgentHelperFrame>
    private let continuation: AsyncStream<AgentHelperFrame>.Continuation
    var inputs: [String] = []
    var startedSession: String?
    var startFailure: String?
    var stopped = false
    var onInput: ((String, FakeRunHelper) -> Void)?
    var deferStart = false
    var startContinuation: CheckedContinuation<Void, Error>?

    init() { (events, continuation) = AsyncStream.makeStream(of: AgentHelperFrame.self) }
    func start() async throws {
        if deferStart {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
            }
        }
    }
    func completeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
    func startBackend(_ backend: String, instructions: String, mcpURL: String,
                      mcpToken: String, sessionID: String?) {
        startedSession = sessionID ?? "first"
        if let startFailure { continuation.yield(AgentHelperFrame(["type": "failed", "message": startFailure])) }
        else { continuation.yield(AgentHelperFrame(["type": "started", "backend": backend])) }
    }
    func writeLine(_ line: String) {
        inputs.append(line)
        onInput?(line, self)
    }
    func emitLine(_ line: String) { continuation.yield(AgentHelperFrame(["type": "line", "line": line])) }
    func interrupt() {}
    func stop() { stopped = true; continuation.finish() }
}
