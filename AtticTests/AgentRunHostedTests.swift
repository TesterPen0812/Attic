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

    func testDamagedThreadJournalIsReportedWithoutOverwritingItsContents() async throws {
        let url = journalURL()
        let original = Data("{partial-thread-from-interrupted-save".utf8)
        try original.write(to: url)
        let helper = FakeRunHelper()
        let runner = AgentRunEngine(helper: { helper }, tools: { FakeRunTools() }, journalURL: url)

        XCTAssertTrue(runner.threadSnapshot().entries.contains { $0.role == "error" },
                      "A damaged journal must be visible to its owner")
        _ = runner.send("Continue the saved chat", watching: false)
        XCTAssertFalse(runner.threadSnapshot().isRunning,
                       "A damaged journal must refuse a new run immediately")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(runner.threadSnapshot().isRunning)
        runner.shutdown()
    }

    // MARK: Chat history and context

    private static let done = #"{"type":"result","is_error":false}"#
    private static func session(_ id: String) -> String { #"{"type":"system","subtype":"init","session_id":""# + id + #""}"# }
    private static func text(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":""# + text + #""}}}"#
    }

    func testChatsAreKeptListedReopenedAndSurviveRelaunch() async {
        let url = journalURL()
        var helpers: [FakeRunHelper] = []
        let make = { () -> FakeRunHelper in let helper = FakeRunHelper(); helpers.append(helper); return helper }
        let runner = AgentRunEngine(helper: { make() }, tools: { FakeRunTools() }, journalURL: url)
        XCTAssertTrue(runner.chats().isEmpty)
        _ = runner.send("Boiler quotes", watching: true)
        await wait { helpers.count == 1 && helpers[0].inputs.count == 1 }
        helpers[0].emitLine(Self.session("claude-boiler"))
        helpers[0].emitLine(Self.text("Three quotes."))
        helpers[0].emitLine(Self.done)
        await wait { !runner.threadSnapshot().isRunning }
        runner.forgetThread()
        XCTAssertTrue(runner.threadSnapshot().entries.isEmpty, "New chat starts empty")
        XCTAssertEqual(runner.chats().map(\.title), ["Boiler quotes"], "and the old one is kept")

        _ = runner.send("Plan the move", watching: true)
        await wait { helpers.count == 2 && helpers[1].inputs.count == 1 }
        XCTAssertEqual(helpers[1].startedSession, "first", "A new chat starts a new session")
        helpers[1].emitLine(Self.done)
        await wait { !runner.threadSnapshot().isRunning }
        XCTAssertEqual(runner.chats().map(\.title), ["Plan the move", "Boiler quotes"], "Newest first, current included")
        runner.shutdown()

        let relaunched = AgentRunEngine(helper: { make() }, tools: { FakeRunTools() }, journalURL: url)
        let chats = relaunched.chats()
        XCTAssertEqual(chats.map(\.title), ["Plan the move", "Boiler quotes"], "History survives relaunch")
        XCTAssertTrue(relaunched.reopen(chat: chats[1].id))
        XCTAssertEqual(relaunched.threadSnapshot().entries.first?.text, "Boiler quotes")
        XCTAssertEqual(relaunched.threadSnapshot().entries.first { $0.role == "assistant" }?.text, "Three quotes.")
        XCTAssertEqual(Set(relaunched.chats().map(\.id)), Set(chats.map(\.id)), "Reopening moves a chat, never copies it")
        _ = relaunched.send("And the cheapest?", watching: true)
        await wait { helpers.count == 3 && helpers[2].startedSession != nil }
        XCTAssertEqual(helpers[2].startedSession, "claude-boiler", "A reopened chat continues its session")
        XCTAssertEqual(relaunched.chats().first?.title, "Boiler quotes")
        relaunched.cancel()
    }

    func testAChatTheCLICannotContinueStartsAFreshSessionAndSaysSo() async {
        var helpers: [FakeRunHelper] = []
        let runner = AgentRunEngine(helper: {
            let helper = FakeRunHelper()
            helper.exitWhenResuming = true
            helpers.append(helper)
            return helper
        }, tools: { FakeRunTools() }, journalURL: journalURL())
        _ = runner.send("First", watching: true)
        await wait { helpers.count == 1 && helpers[0].inputs.count == 1 }
        helpers[0].emitLine(Self.session("gone-session"))
        helpers[0].emitLine(Self.done)
        await wait { !runner.threadSnapshot().isRunning }

        _ = runner.send("Second", watching: true)
        await wait { helpers.count == 3 && helpers[2].inputs.count == 1 }
        XCTAssertEqual(helpers[1].startedSession, "gone-session")
        XCTAssertTrue(helpers[1].stopped)
        XCTAssertEqual(helpers[2].startedSession, "first", "The retry starts a new session")
        helpers[2].emitLine(Self.session("fresh"))
        helpers[2].emitLine(Self.done)
        await wait { !runner.threadSnapshot().isRunning }
        let entries = runner.threadSnapshot().entries
        XCTAssertTrue(entries.contains { $0.role == "notice" && $0.text == AgentRunEngine.freshSessionNotice(.claude) },
                      "The thread says the old session could not be continued")
        XCTAssertFalse(entries.contains { $0.role == "error" })
    }

    func testTheRequestCarriesItsContextButTheThreadKeepsOnlyTheMessage() async {
        var helpers: [FakeRunHelper] = []
        let runner = AgentRunEngine(helper: { let helper = FakeRunHelper(); helpers.append(helper); return helper },
                                    tools: { FakeRunTools() }, journalURL: journalURL(),
                                    describeContext: { "PAGE=\($0.page?.rawValue ?? "none")" })
        _ = runner.send("Tidy these", context: AgentRequestContext(page: .tasks), watching: true)
        await wait { helpers.count == 1 && helpers[0].inputs.count == 1 }
        XCTAssertTrue(helpers[0].inputs[0].contains("PAGE=tasks"), "The page goes with the request")
        XCTAssertTrue(helpers[0].inputs[0].contains("Tidy these"))
        XCTAssertEqual(runner.threadSnapshot().entries.last { $0.role == "user" }?.text, "Tidy these")
        helpers[0].emitLine(Self.done)
        await wait { !runner.threadSnapshot().isRunning }

        _ = runner.send("No page", context: .none, watching: true)
        await wait { helpers.count == 2 && helpers[1].inputs.count == 1 }
        XCTAssertFalse(helpers[1].inputs[0].contains("PAGE="), "No chip, no page context")
        runner.cancel()
    }

    func testEachMessageStartsWithTheModelChosenBeforeIt() async {
        var choice = AgentRunChoice(model: "opus", effort: "high")
        var helpers: [FakeRunHelper] = []
        let runner = AgentRunEngine(selectedBackend: { .claude },
                                    selectedChoice: { _ in choice },
                                    helper: { let helper = FakeRunHelper(); helpers.append(helper); return helper },
                                    tools: { FakeRunTools() }, journalURL: journalURL())
        _ = runner.send("First", watching: true)
        await wait { helpers.first?.inputs.count == 1 }
        XCTAssertEqual(helpers.first?.startedChoice, AgentRunChoice(model: "opus", effort: "high"))

        choice = AgentRunChoice(model: "haiku", effort: "low")
        XCTAssertEqual(helpers.count, 1, "A change never restarts a run already going")
        helpers[0].emitLine(#"{"type":"result","is_error":false}"#)
        await wait { !runner.threadSnapshot().isRunning }
        XCTAssertEqual(helpers[0].startedChoice, AgentRunChoice(model: "opus", effort: "high"))

        _ = runner.send("Second", watching: true)
        await wait { helpers.count == 2 && helpers[1].inputs.count == 1 }
        XCTAssertEqual(helpers[1].startedChoice, AgentRunChoice(model: "haiku", effort: "low"),
                       "A change applies from the next message")
        runner.cancel()
    }

    func testRunsUseEachAgentsDefaultAndHealAnUnlistedChoice() async {
        let helper = FakeRunHelper()
        let runner = AgentRunEngine(selectedBackend: { .codex }, helper: { helper },
                                    tools: { FakeRunTools() }, journalURL: journalURL())
        _ = runner.send("Default", watching: true)
        await wait { helper.startedChoice != nil }
        XCTAssertEqual(helper.startedChoice, AgentRunChoice(model: "gpt-6.1-sol", effort: "medium"))
        runner.cancel()
        await wait { !runner.threadSnapshot().isRunning }

        let stale = FakeRunHelper()
        let staleRunner = AgentRunEngine(selectedBackend: { .claude },
                                         selectedChoice: { _ in AgentRunChoice(model: "claude-retired", effort: "max") },
                                         helper: { stale }, tools: { FakeRunTools() }, journalURL: journalURL())
        _ = staleRunner.send("Stale", watching: true)
        await wait { stale.startedChoice != nil }
        XCTAssertEqual(stale.startedChoice, AgentRunChoice(model: "sonnet", effort: "medium"))
        staleRunner.cancel()
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
        await wait { !runner.threadSnapshot().isRunning }
        XCTAssertTrue(helper.stopped)
        XCTAssertTrue(tools.closed)
        XCTAssertTrue(runner.threadSnapshot().events.contains {
            if case let .failed(message) = $0 { return message.contains("cancelled") }; return false
        })
    }

    func testCancelKeepsCommittedUndoReceiptBeforeFailure() async {
        let helper = FakeRunHelper()
        let tools = FakeRunTools()
        let change = AgentChangeSet(id: UUID(), title: "Saved task", pages: [.tasks], count: 1)
        tools.change = change
        let runner = AgentRunEngine(helper: { helper }, tools: { tools }, journalURL: journalURL(),
                                    undo: { _ in })
        _ = runner.send("Create a task", watching: true)
        await wait { helper.inputs.count == 1 }
        runner.cancel()
        await wait { !runner.threadSnapshot().isRunning }
        let events = runner.threadSnapshot().events
        XCTAssertEqual(events.suffix(2), [.changes(change), .failed("Agent request cancelled.")])
    }

    func testMalformedStreamKeepsCommittedUndoReceiptBeforeFailure() async {
        let helper = FakeRunHelper()
        let tools = FakeRunTools()
        let change = AgentChangeSet(id: UUID(), title: "Saved note", pages: [.notes], count: 1)
        tools.change = change
        let runner = AgentRunEngine(helper: { helper }, tools: { tools }, journalURL: journalURL(),
                                    undo: { _ in })
        _ = runner.send("Create a note", watching: true)
        await wait { helper.inputs.count == 1 }
        helper.emitLine("{broken json")
        await wait { !runner.threadSnapshot().isRunning }
        let events = runner.threadSnapshot().events
        XCTAssertEqual(events.dropLast().last, .changes(change))
        XCTAssertTrue(events.last.map { if case .failed = $0 { return true }; return false } ?? false)
    }

    func testUnexpectedHelperStreamEndFinishesRunAndReleasesWorkingState() async {
        let helper = FakeRunHelper()
        let tools = FakeRunTools()
        let runner = AgentRunEngine(helper: { helper }, tools: { tools }, journalURL: journalURL())
        _ = runner.send("Start", watching: false)
        await wait { helper.inputs.count == 1 }
        helper.disconnect()
        await wait { !runner.threadSnapshot().isRunning }
        XCTAssertTrue(helper.stopped)
        XCTAssertTrue(tools.closed)
        XCTAssertTrue(runner.threadSnapshot().events.contains { event in
            if case let .failed(reason) = event { return reason.contains("disconnected") }
            return false
        })
    }

    func testStopWaitsForCommitReceiptBeforePublishingTerminalEvent() async {
        let helper = FakeRunHelper()
        let tools = FakeRunTools()
        tools.holdDrain = true
        let change = AgentChangeSet(id: UUID(), title: "Late calendar save", pages: [.calendar], count: 1)
        let runner = AgentRunEngine(helper: { helper }, tools: { tools }, journalURL: journalURL(),
                                    undo: { _ in })
        _ = runner.send("Create event", watching: true)
        await wait { helper.inputs.count == 1 }
        runner.cancel()
        await wait { tools.closed }
        XCTAssertTrue(runner.threadSnapshot().isRunning, "No terminal event while a write is in flight")
        XCTAssertFalse(runner.threadSnapshot().events.contains { if case .failed = $0 { return true }; return false })
        tools.change = change
        tools.releaseDrain()
        await wait { !runner.threadSnapshot().isRunning }
        XCTAssertEqual(runner.threadSnapshot().events.suffix(2),
                       [.changes(change), .failed("Agent request cancelled.")])
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

    func testCLIPermissionPassesThroughToTrustedActionPolicyWhileChatIsClosed() async throws {
        let helper = FakeRunHelper()
        let runner = AgentRunEngine(helper: { helper }, tools: { FakeRunTools() }, journalURL: journalURL())
        _ = runner.send("Update", watching: true)
        await wait { helper.inputs.count == 1 }
        runner.setWatching(false)
        helper.emitLine(#"{"type":"control_request","request_id":"approval-1","request":{"subtype":"can_use_tool","tool_name":"mcp__attic__update_task","input":{"id":"item"}}}"#)
        await wait { helper.inputs.count == 2 }
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(helper.inputs[1].utf8)) as? [String: Any])
        XCTAssertEqual(((response["response"] as? [String: Any])?["response"] as? [String: Any])?["behavior"] as? String,
                       "allow")
        XCTAssertFalse(runner.threadSnapshot().events.contains { if case .approvalNeeded = $0 { return true }; return false })
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

    func testRelaunchRestoresReviewableCommittedReceipt() async {
        let url = journalURL()
        let helper = FakeRunHelper()
        let tools = FakeRunTools()
        let change = AgentChangeSet(id: UUID(), title: "Created tasks", pages: [.tasks], count: 1)
        tools.change = change
        let first = AgentRunEngine(helper: { helper }, tools: { tools }, journalURL: url,
                                   undo: { _ in })
        _ = first.send("Make a task", watching: false)
        await wait { helper.inputs.count == 1 }
        helper.emitLine(#"{"type":"result","is_error":false}"#)
        await wait { !first.threadSnapshot().isRunning }

        let reopened = AgentRunEngine(helper: { FakeRunHelper() }, tools: { FakeRunTools() }, journalURL: url)
        let chat = AgentChatModel()
        chat.pacing = .instant
        chat.connect(reopened)
        let receipts = chat.entries.compactMap { entry -> AgentChatChanges? in
            if case let .changes(changes) = entry.content { return changes }
            return nil
        }
        XCTAssertEqual(receipts.map(\.set), [change])
        XCTAssertEqual(receipts.first?.state, .recovered, "History closures do not survive app relaunch")
    }

    func testRelaunchMarksInterruptedRunForReview() async {
        let url = journalURL()
        let first = AgentRunEngine(helper: { FakeRunHelper() }, tools: { FakeRunTools() }, journalURL: url)
        _ = first.send("Still doing work", watching: false)
        let restarted = AgentRunEngine(helper: { FakeRunHelper() }, tools: { FakeRunTools() }, journalURL: url)
        XCTAssertTrue(restarted.threadSnapshot().entries.contains {
            $0.role == "error" && $0.text.localizedCaseInsensitiveContains("interrupted")
        })
        first.cancel()
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
        await wait { !runner.threadSnapshot().isRunning }
        helper.completeStart()
    }

    #if !ATTIC_GENERATED_TESTS
    func testSystemPromptNamesTheLocalClockAndTimeZone() throws {
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let winter = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-10T18:15:00Z"))
        let summer = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-10T18:15:00Z"))
        XCTAssertTrue(AgentRunEngine.systemPrompt(date: winter, timeZone: london)
            .contains("2026-11-10T18:15:00Z (Europe/London)"))
        XCTAssertTrue(AgentRunEngine.systemPrompt(date: summer, timeZone: london)
            .contains("2026-08-10T19:15:00+01:00 (Europe/London)"))
    }

    func testSendImmediatelyAfterNewChatWaitsForOldReceiptAndKeepsTheNewMessage() async {
        let tools = FakeRunTools()
        tools.holdDrain = true
        var helpers: [FakeRunHelper] = []
        let runner = AgentRunEngine(helper: {
            let helper = FakeRunHelper()
            helpers.append(helper)
            return helper
        }, tools: { tools }, journalURL: journalURL())
        let chat = AgentChatModel()
        chat.pacing = .instant
        chat.connect(runner)

        chat.draft = "Original chat"
        chat.send()
        await wait { helpers.count == 1 && helpers[0].inputs.count == 1 }
        chat.newChat()
        chat.draft = "Follow-up in new chat"
        chat.send()
        tools.releaseDrain()

        await wait { helpers.count == 2 && helpers[1].inputs.count == 1 }
        guard helpers.count > 1 else { return }
        XCTAssertEqual(runner.threadSnapshot().entries.filter { $0.role == "user" }.map(\.text),
                       ["Follow-up in new chat"])
        XCTAssertEqual(chat.entries.filter {
            if case .asked("Follow-up in new chat") = $0.content { return true }
            return false
        }.count, 1)
        helpers[1].emitLine(Self.text("New chat reply."))
        helpers[1].emitLine(Self.done)
        await wait { !runner.threadSnapshot().isRunning }
        XCTAssertTrue(runner.threadSnapshot().entries.contains {
            $0.role == "assistant" && $0.text == "New chat reply."
        })
    }
    #endif

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
    var holdDrain = false
    private var drainWaiter: CheckedContinuation<Void, Never>?
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
    func drain() async -> AgentChangeSet? {
        if holdDrain { await withCheckedContinuation { drainWaiter = $0 } }
        return change
    }
    func releaseDrain() { holdDrain = false; drainWaiter?.resume(); drainWaiter = nil }
}

@MainActor
private final class FakeRunHelper: AgentHelperTransmitting {
    let events: AsyncStream<AgentHelperFrame>
    private let continuation: AsyncStream<AgentHelperFrame>.Continuation
    var inputs: [String] = []
    var startedSession: String?
    var startedChoice: AgentRunChoice?
    var startFailure: String?
    var stopped = false
    var onInput: ((String, FakeRunHelper) -> Void)?
    var deferStart = false
    /// Exits at once when asked to continue a session, as a CLI does whose
    /// session is gone.
    var exitWhenResuming = false
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
                      mcpToken: String, sessionID: String?, model: String?, effort: String?) {
        startedSession = sessionID ?? "first"
        startedChoice = model.map { AgentRunChoice(model: $0, effort: effort) }
        if exitWhenResuming, sessionID != nil { continuation.yield(AgentHelperFrame(["type": "exited"])) }
        else if let startFailure { continuation.yield(AgentHelperFrame(["type": "failed", "message": startFailure])) }
        else { continuation.yield(AgentHelperFrame(["type": "started", "backend": backend])) }
    }
    func writeLine(_ line: String) {
        inputs.append(line)
        onInput?(line, self)
    }
    func emitLine(_ line: String) { continuation.yield(AgentHelperFrame(["type": "line", "line": line])) }
    func disconnect() { continuation.finish() }
    func interrupt() {}
    func stop() { stopped = true; continuation.finish() }
}
