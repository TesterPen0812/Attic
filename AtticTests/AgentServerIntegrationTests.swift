import Network
import XCTest
@testable import Attic

@MainActor
final class AgentServerIntegrationTests: XCTestCase {
    func testNormalCredentialLoadingIsDeferredAndOffMainThread() async throws {
        let probe = CredentialLoadProbe(token: try AgentAccessTokenStore.generateToken())
        let server = AgentServer(port: 0, handler: MCPRequestHandler(tools: AgentTaskTools(store: try makeTestStore())), tokenProvider: { try probe.load() })
        defer { server.stop() }
        XCTAssertEqual(probe.callCount, 0, "Disabled Agent Access must not contact Keychain at launch")
        XCTAssertEqual(server.state, .stopped)
        XCTAssertTrue(server.setupToken.isEmpty)
        let port = try await start(server)
        XCTAssertEqual(probe.callCount, 1)
        XCTAssertFalse(probe.calledOnMainThread)
        let response = try await post(port, token: probe.token, method: "ping")
        XCTAssertEqual(response.status, 200)
    }

    func testDisablingWhileCredentialApprovalIsPendingNeverStartsListener() async throws {
        let began = expectation(description: "Credential load began")
        let release = DispatchSemaphore(value: 0)
        let token = try AgentAccessTokenStore.generateToken()
        let server = AgentServer(port: 0, handler: MCPRequestHandler(tools: AgentTaskTools(store: try makeTestStore()))) {
            began.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return token
        }
        defer { release.signal(); server.stop() }
        server.start()
        await fulfillment(of: [began], timeout: 1)
        XCTAssertEqual(server.state, .starting)
        XCTAssertNil(server.boundPort)
        server.stop()
        release.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.state, .stopped)
        XCTAssertNil(server.boundPort)
        XCTAssertTrue(server.setupToken.isEmpty)
    }

    func testDeniedCredentialFailsClosedAndRetryCanRecover() async throws {
        let probe = CredentialLoadProbe(token: try AgentAccessTokenStore.generateToken(), failFirst: true)
        let server = AgentServer(port: 0, handler: MCPRequestHandler(tools: AgentTaskTools(store: try makeTestStore())), tokenProvider: { try probe.load() })
        defer { server.stop() }
        server.start()
        for _ in 0..<100 {
            if case .failed = server.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failed = server.state else { return XCTFail("Denied credential must fail closed") }
        XCTAssertNil(server.boundPort)
        _ = try await start(server)
        XCTAssertEqual(probe.callCount, 2)
    }

    func testOfficialMCPClientInteroperability() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let node = environment["ATTIC_MCP_NODE"],
              let sdk = environment["ATTIC_MCP_SDK_ROOT"] else {
            throw XCTSkip("Optional external-client gate: set ATTIC_MCP_NODE and ATTIC_MCP_SDK_ROOT")
        }
        let token = try AgentAccessTokenStore.generateToken()
        let store = try makeTestStore()
        let notes = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let server = AgentServer(port: 0, bearerToken: token, handler: MCPRequestHandler(tools: AgentTaskTools(store: store, noteStore: notes)))
        defer { server.stop() }
        let port = try await start(server)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/verify_mcp_client.mjs")
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path, "--exercise-test-data"]
        process.environment = [
            "ATTIC_MCP_ENDPOINT": "http://127.0.0.1:\(port)/mcp",
            "ATTIC_MCP_TOKEN": token,
            "ATTIC_MCP_SDK_ROOT": sdk
        ]
        process.standardOutput = output
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { child in continuation.resume(returning: child.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(status, 0, "Official SDK client must pass; credential-bearing process output is not logged")
        guard status == 0 else { return }
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["result"] as? String, "passed")
        XCTAssertEqual(report["authenticated"] as? Bool, true)
        XCTAssertEqual(report["reconnect"] as? Bool, true)
        XCTAssertEqual(report["subtasksVerified"] as? Bool, true)
        XCTAssertEqual(report["testDataRemoved"] as? Bool, true)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testRealHTTPHandshakeToolDiscoveryAndReadOnlyCall() async throws {
        let token = try AgentAccessTokenStore.generateToken()
        let store = try makeTestStore()
        let server = AgentServer(port: 0, bearerToken: token, handler: MCPRequestHandler(tools: AgentTaskTools(store: store)))
        defer { server.stop() }
        let port = try await start(server)

        let initialized = try await post(port, token: token, method: "initialize", params: [
            "protocolVersion": "2025-11-25", "capabilities": [:],
            "clientInfo": ["name": "attic-integration-test", "version": "1"]
        ])
        XCTAssertEqual(initialized.status, 200)
        XCTAssertEqual((initialized.json?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        let notified = try await post(port, token: token, method: "notifications/initialized", notification: true)
        XCTAssertEqual(notified.status, 202)
        let listed = try await post(port, token: token, method: "tools/list")
        let result = try XCTUnwrap(listed.json?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "list_tasks" })
        let called = try await post(port, token: token, method: "tools/call", params: ["name": "list_tasks", "arguments": [:]])
        XCTAssertEqual(called.status, 200)
        XCTAssertEqual((called.json?["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testRealHTTPRejectsMissingWrongAndPlaceholderTokensAndBrowserOrigins() async throws {
        let token = try AgentAccessTokenStore.generateToken()
        let server = AgentServer(port: 0, bearerToken: token, handler: MCPRequestHandler(tools: AgentTaskTools(store: try makeTestStore())))
        defer { server.stop() }
        let port = try await start(server)
        for supplied in [nil, "wrong", "attic-local-only-agent-disabled"] as [String?] {
            let response = try await post(port, token: supplied, method: "tools/list")
            XCTAssertEqual(response.status, 401)
            XCTAssertNil(response.json)
        }
        let browser = try await post(port, token: token, method: "tools/list", origin: "https://example.com")
        XCTAssertEqual(browser.status, 403)
    }

    func testStopAndRestartReconnectsWithSamePrivateCredential() async throws {
        let token = try AgentAccessTokenStore.generateToken()
        let server = AgentServer(port: 0, bearerToken: token, handler: MCPRequestHandler(tools: AgentTaskTools(store: try makeTestStore())))
        defer { server.stop() }
        let firstPort = try await start(server)
        let first = try await post(firstPort, token: token, method: "ping")
        XCTAssertEqual(first.status, 200)
        server.stop()
        XCTAssertEqual(server.state, .stopped)
        XCTAssertNil(server.boundPort)
        let nextPort = try await start(server)
        let next = try await post(nextPort, token: token, method: "ping")
        XCTAssertEqual(next.status, 200)
    }

    /// A client that connects and then says nothing held its accepted socket
    /// for as long as it liked, and `stop()` walked away from it: the listener
    /// was cancelled while the socket stayed open and served. Stopping now
    /// closes every accepted socket, and the peer sees the close.
    func testStopClosesSocketsThatNeverCompletedARequest() async throws {
        let token = try AgentAccessTokenStore.generateToken()
        let server = AgentServer(port: 0, bearerToken: token,
                                 handler: MCPRequestHandler(tools: AgentTaskTools(store: try makeTestStore())))
        defer { server.stop() }
        let port = try await start(server)
        XCTAssertEqual(server.openConnectionCount, 0)

        let idle = IdleSocket(port: port)
        defer { idle.close() }
        idle.open()
        await eventually { server.openConnectionCount == 1 }
        XCTAssertFalse(idle.isClosed, "the server must not close a socket that is merely slow")

        server.stop()
        XCTAssertEqual(server.openConnectionCount, 0, "stop() must not leave an accepted socket behind")
        await eventually { idle.isClosed }
        XCTAssertTrue(idle.isClosed)

        // A restart starts from an empty registry rather than inheriting the
        // previous generation's sockets.
        let nextPort = try await start(server)
        XCTAssertEqual(server.openConnectionCount, 0)
        let afterRestart = try await post(nextPort, token: token, method: "ping")
        XCTAssertEqual(afterRestart.status, 200)
    }

    /// The deadline is the backstop for a peer that never finishes its
    /// request while the server keeps running. Half a request is enough: the
    /// parser keeps waiting for the terminator forever on its own.
    func testAnUnfinishedRequestIsClosedByItsDeadline() async throws {
        let token = try AgentAccessTokenStore.generateToken()
        let server = AgentServer(port: 0, bearerToken: token,
                                 handler: MCPRequestHandler(tools: AgentTaskTools(store: try makeTestStore())),
                                 requestDeadline: 0.4)
        defer { server.stop() }
        let port = try await start(server)

        let truncated = IdleSocket(port: port)
        defer { truncated.close() }
        truncated.open()
        await eventually { server.openConnectionCount == 1 }
        truncated.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n")

        await eventually { truncated.isClosed }
        XCTAssertTrue(truncated.isClosed, "an unfinished request must not hold its socket open")
        await eventually { server.openConnectionCount == 0 }
        XCTAssertEqual(server.openConnectionCount, 0, "the closed socket must leave the registry")

        // The listener is still serving: the deadline closes one socket, not
        // the server.
        XCTAssertEqual(server.state, .running)
        let served = try await post(port, token: token, method: "ping")
        XCTAssertEqual(served.status, 200)
        await eventually { server.openConnectionCount == 0 }
        XCTAssertEqual(server.openConnectionCount, 0, "a completed request must not stay registered")
    }

    /// A closed connection must be let go of by everything the registry put in
    /// place for it, not just dropped from the dictionary. The deadline is the
    /// case that bites: a cancelled `DispatchWorkItem` stays on its queue until
    /// its scheduled time, so one that held the connection kept a closed socket
    /// alive for the rest of the deadline.
    ///
    /// It does not prove anything about the handler's own capture: Network
    /// releases a connection's state handler when it reaches a final state, so
    /// that cycle cannot be observed from here. Capturing the key by value
    /// instead of the connection is reviewed, not asserted.
    func testATrackedConnectionIsReleasedOnceItCloses() async throws {
        let registry = AcceptedConnections()
        let queue = DispatchQueue(label: "AgentServerTests.registry")
        weak var released: NWConnection?

        do {
            let connection = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
            released = connection
            XCTAssertTrue(registry.track(connection, on: queue, deadline: 60))
            XCTAssertEqual(registry.count, 1)
            XCTAssertNotNil(released)

            // Started so the state handler the registry installed is actually
            // delivered; closing it is then the only thing that removes the
            // entry, whether the close arrives as .cancelled or .failed.
            connection.start(queue: queue)
            connection.cancel()
            await eventually { registry.count == 0 }
        }

        // The registry has let go, and nothing else it scheduled may still be
        // holding on: the deadline is still pending on the queue.
        await eventually { released == nil }
        XCTAssertNil(released, "a closed connection must not be kept alive by its pending deadline")
        XCTAssertEqual(registry.count, 0)
    }

    /// A connection that never closes on its own is still released once the
    /// registry is shut down, so `stop()` frees the sockets as well as closing
    /// them.
    func testShutDownReleasesEverySocketItClosed() async throws {
        let registry = AcceptedConnections()
        let queue = DispatchQueue(label: "AgentServerTests.registry.shutdown")
        weak var released: NWConnection?

        do {
            let connection = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
            released = connection
            XCTAssertTrue(registry.track(connection, on: queue, deadline: 60))
            connection.start(queue: queue)
            registry.shutDown()
            XCTAssertEqual(registry.count, 0)
            XCTAssertFalse(registry.track(connection, on: queue, deadline: 60),
                           "a shut-down registry refuses further sockets")
        }

        await eventually { released == nil }
        XCTAssertNil(released)
    }

    /// A listener that fails keeps nothing: it will accept no further socket,
    /// so the ones it already accepted are closed immediately instead of being
    /// held until their request deadline elapses.
    func testAFailedListenerDrainsItsAcceptedSocketsImmediately() async throws {
        let token = try AgentAccessTokenStore.generateToken()
        let configured = AgentServer(
            port: 0,
            bearerToken: token,
            handler: MCPRequestHandler(tools: AgentTaskTools(store: try makeTestStore())),
            // Long enough that a deadline cannot be what closes the socket.
            requestDeadline: 600
        )
        defer { configured.stop() }
        let port = try await start(configured)

        let idle = IdleSocket(port: port)
        defer { idle.close() }
        idle.open()
        await eventually { configured.openConnectionCount == 1 }
        XCTAssertFalse(idle.isClosed)

        configured.failListenerForTesting("Listener refused")

        XCTAssertEqual(configured.state, .failed("Listener refused"))
        XCTAssertEqual(configured.openConnectionCount, 0,
                       "a failed listener must not leave an accepted socket behind")
        XCTAssertNil(configured.boundPort)
        await eventually { idle.isClosed }
        XCTAssertTrue(idle.isClosed, "the peer must see the close rather than wait out the deadline")

        // And the failure is not terminal for the object: a restart serves.
        let nextPort = try await start(configured)
        let served = try await post(nextPort, token: token, method: "ping")
        XCTAssertEqual(served.status, 200)
    }

    func testPlaceholderAndEmptyCredentialsNeverOpenListener() throws {
        for token in ["", "attic-local-only-agent-disabled", "attic-test-agent-token"] {
            let server = AgentServer(port: 0, bearerToken: token, handler: MCPRequestHandler(tools: AgentTaskTools(store: try makeTestStore())))
            server.start()
            guard case .failed = server.state else { return XCTFail("Unsafe credential must fail closed") }
            XCTAssertNil(server.boundPort)
        }
    }

    private func eventually(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition not reached within \(timeout)s", file: file, line: line)
    }

    private func start(_ server: AgentServer) async throws -> UInt16 {
        server.start()
        for _ in 0..<200 {
            if server.state == .running { return try XCTUnwrap(server.boundPort) }
            if case let .failed(message) = server.state {
                XCTFail("Listener failed: \(message)")
                throw URLError(.cannotConnectToHost)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Listener did not become ready")
        throw URLError(.timedOut)
    }

    private func post(
        _ port: UInt16, token: String?, method: String,
        params: [String: Any] = [:], notification: Bool = false, origin: String? = nil
    ) async throws -> (status: Int, json: [String: Any]?) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { message["id"] = 1 }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse).statusCode,
                (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }
}

/// A bare loopback peer: it connects, optionally sends a fragment, and never
/// completes a request. This is the client shape that used to outlive `stop()`.
private final class IdleSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var closed = false

    init(port: UInt16) {
        connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    var isClosed: Bool { lock.withLock { closed } }

    func open() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                waitForClose()
            case .failed, .cancelled:
                markClosed()
            default:
                break
            }
        }
        connection.start(queue: .global())
    }

    func send(_ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }

    /// A peer observes a closed socket as end-of-stream or as a reset; either
    /// answer means the server let go of it.
    private func waitForClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [self] _, _, isComplete, error in
            if isComplete || error != nil {
                markClosed()
            } else {
                waitForClose()
            }
        }
    }

    private func markClosed() {
        lock.withLock { closed = true }
    }
}

private final class CredentialLoadProbe: @unchecked Sendable {
    let token: String
    private let failFirst: Bool
    private let lock = NSLock()
    private var calls = 0
    private var usedMainThread = false
    var callCount: Int { lock.withLock { calls } }
    var calledOnMainThread: Bool { lock.withLock { usedMainThread } }

    init(token: String, failFirst: Bool = false) {
        self.token = token
        self.failFirst = failFirst
    }

    func load() throws -> String {
        let shouldFail = lock.withLock {
            calls += 1
            usedMainThread = usedMainThread || Thread.isMainThread
            return failFirst && calls == 1
        }
        if shouldFail { throw CocoaError(.fileReadNoPermission) }
        return token
    }
}
