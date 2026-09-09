import XCTest
@testable import Attic

@MainActor
final class AgentServerIntegrationTests: XCTestCase {
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

    func testPlaceholderAndEmptyCredentialsNeverOpenListener() throws {
        for token in ["", "attic-local-only-agent-disabled", "attic-test-agent-token"] {
            let server = AgentServer(port: 0, bearerToken: token, handler: MCPRequestHandler(tools: AgentTaskTools(store: try makeTestStore())))
            server.start()
            guard case .failed = server.state else { return XCTFail("Unsafe credential must fail closed") }
            XCTAssertNil(server.boundPort)
        }
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
