import Foundation
import XCTest
@testable import Attic

private final class AgentSSEProtocol: URLProtocol {
    static let lock = NSLock()
    static var fixtures: [Data] = []
    static var requests: [[String: Any]] = []
    static var headers: [[String: String]] = []
    static var held = false
    static var statuses: [Int] = []

    static func prepare(_ responses: [Data], held: Bool = false, statuses: [Int] = []) {
        lock.lock(); defer { lock.unlock() }
        fixtures = responses
        requests = []
        headers = []
        self.held = held
        self.statuses = statuses
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let data = Self.fixtures.isEmpty ? nil : Self.fixtures.removeFirst()
        let status = Self.statuses.isEmpty ? (data == nil ? 500 : 200) : Self.statuses.removeFirst()
        if let body = request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            Self.requests.append(json)
        }
        Self.headers.append(request.allHTTPHeaderFields ?? [:])
        let held = Self.held
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        if !held { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}

@MainActor
private final class FakeAgentTools: AgentToolProviding {
    var calls: [(String, Bool)] = []
    var response = AgentToolResponse(content: "done")
    var failure: Error?
    var requireApproval = false
    let approval = AgentApproval(id: UUID(), title: "Allow this change?", targets: [])

    func listTools() async throws -> [AgentToolDefinition] {
        [AgentToolDefinition(name: "do_thing", description: "Do a thing",
                             schema: .object(["type": .string("object"),
                                              "properties": .object(["label": .object(["type": .string("string")])]),
                                              "required": .array([.string("label")]),
                                              "additionalProperties": .bool(false)]))]
    }

    func call(name: String, arguments: [String: AgentJSON], approved: Bool) async throws -> AgentToolResponse {
        calls.append((name, approved))
        if let failure { throw failure }
        if requireApproval && !approved { return AgentToolResponse(content: "", approval: approval) }
        return response
    }
}

@MainActor
final class AgentRunEngineTests: XCTestCase {
    private var tempURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("attic-agent-test-\(UUID().uuidString)/thread.json")
    }

    private func engine(_ tools: FakeAgentTools, url: URL? = nil, key: String? = "test-only-key") -> AgentRunEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentSSEProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ClaudeMessagesClient(session: session, endpoint: URL(string: "https://claude.invalid/v1/messages")!)
        let store = AgentAPIKeyStore(bundleIdentifier: "test", read: { _ in key },
                                     write: { _, _ in }, erase: { _ in })
        return AgentRunEngine(tools: tools, client: client, keyStore: store, fileURL: url ?? tempURL,
                              now: { Date(timeIntervalSince1970: 1_783_600_000) })
    }

    private func event(_ name: String, _ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    private func message(text: String = "Hello", reason: String = "end_turn") -> Data {
        let sequence = [
            event("message_start", ["type": "message_start", "message": ["content": []]]),
            event("content_block_start", ["type": "content_block_start", "index": 0,
                                          "content_block": ["type": "text", "text": ""]]),
            event("content_block_delta", ["type": "content_block_delta", "index": 0,
                                          "delta": ["type": "text_delta", "text": text]]),
            event("content_block_stop", ["type": "content_block_stop", "index": 0]),
            event("message_delta", ["type": "message_delta", "delta": ["stop_reason": reason]]),
            event("message_stop", ["type": "message_stop"])
        ]
        return Data(sequence.joined().utf8)
    }

    private func toolsTurn(_ inputs: [String], reason: String = "tool_use") -> Data {
        var sequence = [event("message_start", ["type": "message_start", "message": ["content": []]])]
        for (i, input) in inputs.enumerated() {
            sequence.append(event("content_block_start", ["type": "content_block_start", "index": i,
                        "content_block": ["type": "tool_use", "id": "toolu_\(i)", "name": "do_thing", "input": [:]]]))
            sequence.append(event("content_block_delta", ["type": "content_block_delta", "index": i,
                        "delta": ["type": "input_json_delta", "partial_json": input]]))
            sequence.append(event("content_block_stop", ["type": "content_block_stop", "index": i]))
        }
        sequence.append(event("message_delta", ["type": "message_delta", "delta": ["stop_reason": reason]]))
        sequence.append(event("message_stop", ["type": "message_stop"]))
        return Data(sequence.joined().utf8)
    }

    private func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var received: [AgentEvent] = []
        for await event in stream {
            received.append(event)
            if case .finished = event { break }
            if case .failed = event { break }
        }
        return received
    }

    func testStreamingAndRequestShape() async {
        AgentSSEProtocol.prepare([message(text: "Hi there")])
        let run = engine(FakeAgentTools())
        let events = await collect(run.send("Hi", watching: true))
        XCTAssertTrue(events.contains(.textDelta("Hi there")))
        XCTAssertTrue(events.contains(.finished))
        XCTAssertEqual(run.threadSnapshot().entries.filter { $0.role == "assistant" }.map(\.text), ["Hi there"])
        let body = AgentSSEProtocol.requests.first
        XCTAssertEqual(body?["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body?["max_tokens"] as? Int, 64000)
        XCTAssertEqual(body?["stream"] as? Bool, true)
        XCTAssertEqual(body?["fallbacks"] as? String, "default")
        XCTAssertEqual((body?["output_config"] as? [String: String])?["effort"], "medium")
        XCTAssertNil(body?["thinking"])
        XCTAssertNil(body?["tool_choice"])
        let system = body?["system"] as? [[String: Any]]
        XCTAssertNotNil(system?.first?["cache_control"])
        let definitions = body?["tools"] as? [[String: Any]]
        XCTAssertEqual(definitions?.first?["eager_input_streaming"] as? Bool, true)
        XCTAssertNotNil(definitions?.last?["cache_control"])
        let headers = AgentSSEProtocol.headers.first ?? [:]
        XCTAssertEqual(headers["anthropic-version"], "2026-10-21")
        XCTAssertEqual(headers["anthropic-beta"], "server-side-fallback-2026-07-01")
    }

    func testSingleAndParallelToolsUseOneResultMessage() async {
        for count in [1, 2] {
            AgentSSEProtocol.prepare([toolsTurn(Array(repeating: "{\"label\":\"ok\"}", count: count)), message(text: "Done")])
            let fake = FakeAgentTools()
            let run = engine(fake)
            let events = await collect(run.send("Do it", watching: true))
            XCTAssertEqual(fake.calls.count, count)
            XCTAssertEqual(events.filter { if case .stepStarted = $0 { return true }; return false }.count, count)
            XCTAssertEqual(events.filter { if case .stepFinished = $0 { return true }; return false }.count, count)
            XCTAssertTrue(events.contains(.progress(done: count, total: count)))
            XCTAssertEqual(AgentSSEProtocol.requests.count, 2)
            let messages = AgentSSEProtocol.requests[1]["messages"] as? [[String: Any]] ?? []
            let last = messages.last
            XCTAssertEqual(last?["role"] as? String, "user")
            let results = last?["content"] as? [[String: Any]] ?? []
            XCTAssertEqual(results.count, count)
            for i in 0..<count {
                XCTAssertEqual(results[i]["tool_use_id"] as? String, "toolu_\(i)")
                XCTAssertEqual(results[i]["is_error"] as? Bool, false)
            }
        }
    }

    func testToolErrorsAndInvalidInputsNeverExecuteUnvalidatedCalls() async {
        AgentSSEProtocol.prepare([toolsTurn(["{\"label\":\"ok\"}"]), message()])
        let fake = FakeAgentTools()
        fake.failure = AgentToolError.notPerformed("Unable to save")
        _ = await collect(engine(fake).send("Do it", watching: true))
        let firstMessages = AgentSSEProtocol.requests[1]["messages"] as? [[String: Any]] ?? []
        let firstResult = (firstMessages.last?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(firstResult?["is_error"] as? Bool, true)

        AgentSSEProtocol.prepare([toolsTurn(["{\"label\":4}"]), message()])
        let invalid = FakeAgentTools()
        _ = await collect(engine(invalid).send("Do it", watching: true))
        XCTAssertTrue(invalid.calls.isEmpty)
        let invalidMessages = AgentSSEProtocol.requests[1]["messages"] as? [[String: Any]] ?? []
        let result = (invalidMessages.last?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(result?["is_error"] as? Bool, true)

        AgentSSEProtocol.prepare([toolsTurn(["{invalid"]), message()])
        let malformed = FakeAgentTools()
        _ = await collect(engine(malformed).send("Do it", watching: true))
        XCTAssertTrue(malformed.calls.isEmpty)
        let malformedMessages = AgentSSEProtocol.requests[1]["messages"] as? [[String: Any]] ?? []
        let malformedResult = (malformedMessages.last?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(malformedResult?["is_error"] as? Bool, true)
    }

    func testRefusalAndTokenLimitNeverRunTools() async {
        for reason in ["refusal", "max_tokens"] {
            AgentSSEProtocol.prepare([toolsTurn(["{\"label\":\"ok\"}"], reason: reason)])
            let fake = FakeAgentTools()
            let events = await collect(engine(fake).send("Do it", watching: true))
            XCTAssertTrue(fake.calls.isEmpty)
            XCTAssertEqual(AgentSSEProtocol.requests.count, 1)
            XCTAssertTrue(events.contains { if case .failed = $0 { return true }; return false })
        }
    }

    func testNoKeyFailsWithoutNetwork() async {
        AgentSSEProtocol.prepare([])
        let events = await collect(engine(FakeAgentTools(), key: nil).send("Hello", watching: true))
        XCTAssertTrue(events.contains(.failed("Add a Claude API key in Settings.")))
        XCTAssertTrue(AgentSSEProtocol.requests.isEmpty)
    }

    func testServerErrorsRetryButClientErrorsFailImmediately() async {
        AgentSSEProtocol.prepare([Data(), Data(), message(text: "Recovered")], statuses: [429, 503, 200])
        let events = await collect(engine(FakeAgentTools()).send("Retry", watching: true))
        XCTAssertTrue(events.contains(.finished))
        XCTAssertEqual(AgentSSEProtocol.requests.count, 3)

        AgentSSEProtocol.prepare([Data(), message()], statuses: [401, 200])
        let failed = await collect(engine(FakeAgentTools()).send("No access", watching: true))
        XCTAssertTrue(failed.contains(.failed("The Claude API key was rejected.")))
        XCTAssertEqual(AgentSSEProtocol.requests.count, 1)
    }

    func testPauseTurnResendsUneditedAssistantHistory() async {
        AgentSSEProtocol.prepare([message(text: "First", reason: "pause_turn"), message(text: "Then")])
        let events = await collect(engine(FakeAgentTools()).send("Go", watching: true))
        XCTAssertTrue(events.contains(.finished))
        let history = AgentSSEProtocol.requests[1]["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[1]["role"] as? String, "assistant")
        XCTAssertEqual((history[1]["content"] as? [[String: Any]])?.first?["text"] as? String, "First")
    }

    func testBackgroundCloseReattachAndRelaunch() async {
        AgentSSEProtocol.prepare([message(text: "Persisted")])
        let url = tempURL
        let run = engine(FakeAgentTools(), url: url)
        let stream = run.send("Read", watching: true)
        run.setWatching(false)
        _ = await collect(stream)
        XCTAssertFalse(run.isWatching)
        XCTAssertTrue(run.threadSnapshot().entries.contains(where: { $0.text == "Persisted" }))
        let reopened = engine(FakeAgentTools(), url: url)
        XCTAssertEqual(reopened.threadSnapshot().entries.first?.text, "Read")
        XCTAssertTrue(reopened.threadSnapshot().entries.contains(where: { $0.text == "Persisted" }))
        AgentSSEProtocol.prepare([message(text: "Again")])
        _ = await collect(reopened.send("Next", watching: true))
        let messages = AgentSSEProtocol.requests.first?["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual((messages[1]["content"] as? [[String: Any]])?.first?["text"] as? String, "Persisted")
    }

    func testApprovalWaitsForOwnerAndUsesExplicitAllow() async {
        AgentSSEProtocol.prepare([toolsTurn(["{\"label\":\"ok\"}"]), message()])
        let fake = FakeAgentTools()
        fake.requireApproval = true
        let run = engine(fake)
        let stream = run.send("Change", watching: false)
        var events: [AgentEvent] = []
        for await event in stream {
            events.append(event)
            if case let .approvalNeeded(approval) = event {
                XCTAssertEqual(fake.calls.map(\.1), [false])
                run.resolve(approval: approval.id, allow: true)
            }
            if case .finished = event { break }
            if case .failed = event { break }
        }
        XCTAssertTrue(events.contains(.finished))
        XCTAssertEqual(fake.calls.map(\.1), [false, true])
    }

    func testDeniedApprovalReturnsToolErrorWithoutWrite() async {
        AgentSSEProtocol.prepare([toolsTurn(["{\"label\":\"ok\"}"]), message()])
        let fake = FakeAgentTools()
        fake.requireApproval = true
        let run = engine(fake)
        for await event in run.send("Change", watching: false) {
            if case let .approvalNeeded(approval) = event { run.resolve(approval: approval.id, allow: false) }
            if case .finished = event { break }
            if case .failed = event { break }
        }
        XCTAssertEqual(fake.calls.map(\.1), [false])
        let messages = AgentSSEProtocol.requests[1]["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual((messages.last?["content"] as? [[String: Any]])?.first?["is_error"] as? Bool, true)
    }

    func testKeychainStoreInterfaceNeverPersistsKeyInThread() async throws {
        var saved: [String: String] = [:]
        let store = AgentAPIKeyStore(bundleIdentifier: "test", read: { saved[$0] },
                                     write: { saved[$0] = $1 }, erase: { saved.removeValue(forKey: $0) })
        XCTAssertNil(try store.load())
        try store.save("test-only-secret")
        XCTAssertEqual(try store.load(), "test-only-secret")
        try store.remove()
        XCTAssertNil(try store.load())

        AgentSSEProtocol.prepare([message()])
        let url = tempURL
        _ = await collect(engine(FakeAgentTools(), url: url).send("Hi", watching: false))
        let file = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(file.contains("test-only-key"))
    }

    func testCancelDuringStreamStopsFurtherWork() async {
        AgentSSEProtocol.prepare([message(text: "Partial")], held: true)
        let fake = FakeAgentTools()
        let run = engine(fake)
        var events: [AgentEvent] = []
        for await event in run.send("Change", watching: true) {
            events.append(event)
            if case .textDelta = event { run.cancel() }
            if case .failed = event { break }
        }
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertTrue(events.contains(.failed("Cancelled.")))
    }
}
