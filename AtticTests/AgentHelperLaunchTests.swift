import Foundation
import Darwin
import XCTest
@testable import Attic

@MainActor
final class AgentHelperLaunchTests: XCTestCase {
    #if DEBUG
    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticLaunchFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func fakeCLI(_ name: String, in directory: URL, body: String) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    private func until(_ type: String, from helper: AgentHelperClient) async -> AgentHelperFrame? {
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(35))
            if !Task.isCancelled { helper.stop() }
        }
        defer { timeout.cancel() }
        for await frame in helper.events where frame.type == type { return frame }
        return nil
    }

    private func configure(_ helper: AgentHelperClient, claude: [URL] = [], codex: [URL] = []) async {
        helper.configureTestCLIs(claude: claude.map(\.path), codex: codex.map(\.path))
        let ready = await until("testCLIsReady", from: helper)
        XCTAssertNotNil(ready, "The real signed helper must accept fixtures only from its unit-test host")
    }

    func testRealHelperGrantsAtticToolsToNoninteractiveClaude() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("claude-arguments.txt")
        let fake = try fakeCLI("claude", in: directory, body: """
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
        printf '%s\\n' "$@" > '\(log.path)'
        printf 'PATH_SET=%s\\n' "${PATH:+yes}" >> '\(log.path)'
        granted=no
        prior=
        for arg in "$@"; do
            if [ "$prior" = "--allowedTools" ] && [ "$arg" = "mcp__attic" ]; then granted=yes; fi
            prior="$arg"
        done
        if [ "$granted" != yes ]; then
            printf 'mcp__attic__list_tasks is not allowed\\n' >&2
            exit 7
        fi
        printf '{"type":"result","is_error":false}\\n'
        """)
        let helper = try AgentHelperClient()
        defer { helper.stop() }
        try await helper.start()
        await configure(helper, claude: [fake])
        helper.startBackend("claude", instructions: "fake launch", mcpURL: "http://127.0.0.1:7335/mcp",
                            mcpToken: String(repeating: "x", count: 40), sessionID: nil)
        let exit = await until("exited", from: helper)
        XCTAssertEqual(exit?.status, 0, "Without --allowedTools mcp__attic the fake CLI refuses the real helper's launch")
        let recorded = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(recorded.contains("--allowedTools\nmcp__attic\n"))
        XCTAssertTrue(recorded.contains("--strict-mcp-config\n"))
        XCTAssertTrue(recorded.contains("PATH_SET=yes"), "The child must receive a controlled environment")
    }

    func testRealHelperReportsBrokenCodexConfigurationInsteadOfSignedOut() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("codex-status.txt")
        let broken = try fakeCLI("codex", in: directory, body: """
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then
            printf '%s\\n' "$@" > '\(log.path)'
            printf 'PATH_SET=%s\\n' "${PATH:+yes}" >> '\(log.path)'
            printf 'Error loading configuration: ~/.codex/config.toml:151:1: invalid type: map, expected a boolean\\n' >&2
            exit 1
        fi
        exit 91
        """)
        let helper = try AgentHelperClient()
        defer { helper.stop() }
        try await helper.start()
        await configure(helper, codex: [broken])
        helper.probe()
        let availability = await until("availability", from: helper)
        XCTAssertEqual(availability?.codexStatus, "update")
        XCTAssertEqual(availability?.codexIssue, broken.path)
        XCTAssertEqual(availability?.codexSignedIn, false)
        helper.startBackend("codex", instructions: "fake launch", mcpURL: "http://127.0.0.1:7335/mcp",
                            mcpToken: String(repeating: "x", count: 40), sessionID: nil)
        let failed = await until("failed", from: helper)
        XCTAssertTrue(failed?.message?.contains(broken.path) == true)
        XCTAssertTrue(failed?.message?.contains("Update Codex") == true)
        XCTAssertFalse(failed?.message?.contains("Sign in") == true)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "login\nstatus\nPATH_SET=yes\n")
    }

    func testRealHelperChoosesWorkingVerifiedCandidateAfterBrokenOne() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("selected-codex.txt")
        let broken = try fakeCLI("codex-broken", in: directory, body: """
        printf 'Error loading configuration: ~/.codex/config.toml:151:1: invalid type: map, expected a boolean\\n' >&2
        exit 1
        """)
        let working = try fakeCLI("codex-working", in: directory, body: """
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then exit 0; fi
        printf '%s\\n' "$@" > '\(record.path)'
        printf 'TOKEN_SET=%s\\n' "${ATTIC_RUN_MCP_TOKEN:+yes}" >> '\(record.path)'
        """)
        let helper = try AgentHelperClient()
        defer { helper.stop() }
        try await helper.start()
        await configure(helper, codex: [broken, working])
        helper.probe()
        let availability = await until("availability", from: helper)
        XCTAssertEqual(availability?.codexStatus, "ready")
        guard availability?.codexStatus == "ready" else { return }
        helper.startBackend("codex", instructions: "fake launch", mcpURL: "http://127.0.0.1:7335/mcp",
                            mcpToken: String(repeating: "x", count: 40), sessionID: nil)
        let exit = await until("exited", from: helper)
        XCTAssertEqual(exit?.status, 0)
        let recorded = try String(contentsOf: record, encoding: .utf8)
        XCTAssertTrue(recorded.contains("app-server\n--strict-config\n"))
        XCTAssertTrue(recorded.contains("TOKEN_SET=yes"))
    }

    // MARK: The in-app agent's own model and thinking level (2026-11-10)

    func testRealHelperPassesTheChosenModelAndEffortToEachCLI() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let claudeLog = directory.appendingPathComponent("claude-arguments.txt")
        let codexLog = directory.appendingPathComponent("codex-arguments.txt")
        let claude = try fakeCLI("claude", in: directory, body: """
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
        printf '%s\\n' "$@" > '\(claudeLog.path)'
        """)
        let codex = try fakeCLI("codex", in: directory, body: """
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then exit 0; fi
        printf '%s\\n' "$@" > '\(codexLog.path)'
        """)
        let helper = try AgentHelperClient()
        defer { helper.stop() }
        try await helper.start()
        await configure(helper, claude: [claude], codex: [codex])

        helper.startBackend("claude", instructions: "fake launch", mcpURL: "http://127.0.0.1:7335/mcp",
                            mcpToken: String(repeating: "x", count: 40), sessionID: nil,
                            model: "opus", effort: "high")
        let claudeExit = await until("exited", from: helper)
        XCTAssertEqual(claudeExit?.status, 0)
        let claudeArguments = try String(contentsOf: claudeLog, encoding: .utf8)
        XCTAssertTrue(claudeArguments.contains("--model\nopus\n--effort\nhigh\n"), claudeArguments)
        XCTAssertTrue(claudeArguments.contains("--allowedTools\nmcp__attic\n"), "The tool grant stays")
        XCTAssertTrue(claudeArguments.contains("--strict-mcp-config\n"), "The strict MCP config stays")

        helper.startBackend("codex", instructions: "fake launch", mcpURL: "http://127.0.0.1:7335/mcp",
                            mcpToken: String(repeating: "x", count: 40), sessionID: nil,
                            model: "gpt-6.1-sol", effort: "medium")
        let codexExit = await until("exited", from: helper)
        XCTAssertEqual(codexExit?.status, 0)
        let codexArguments = try String(contentsOf: codexLog, encoding: .utf8)
        XCTAssertTrue(codexArguments.contains("app-server\n--strict-config\n"), "The strict config stays")
        XCTAssertTrue(codexArguments.contains(
            "--config\nmodel=\"gpt-6.1-sol\"\n--config\nmodel_reasoning_effort=\"medium\"\n"), codexArguments)
        XCTAssertTrue(codexArguments.contains("--disable\nshell_tool\n"), "Native tools stay off")
    }

    func testRealHelperRefusesAModelOrEffortAtticDoesNotList() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ran = directory.appendingPathComponent("ran.txt")
        let claude = try fakeCLI("claude", in: directory, body: """
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
        printf '%s\\n' "$@" >> '\(ran.path)'
        """)
        let codex = try fakeCLI("codex", in: directory, body: """
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then exit 0; fi
        printf '%s\\n' "$@" >> '\(ran.path)'
        """)
        let helper = try AgentHelperClient()
        defer { helper.stop() }
        try await helper.start()
        await configure(helper, claude: [claude], codex: [codex])

        let refused: [(String, String, String?)] = [
            ("codex", #"gpt-6.1-sol" --config shell_tool=true"#, "medium"),
            ("codex", "gpt-6.1-sol", "turbo"),
            ("claude", "fable", "medium"),
            ("claude", "sonnet", nil)
        ]
        for (backend, model, effort) in refused {
            helper.startBackend(backend, instructions: "fake launch", mcpURL: "http://127.0.0.1:7335/mcp",
                                mcpToken: String(repeating: "x", count: 40), sessionID: nil,
                                model: model, effort: effort)
            let failed = await until("failed", from: helper)
            XCTAssertEqual(failed?.message, "Invalid agent request.", "\(backend) \(model)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path),
                       "No refused choice may launch either CLI")
    }
    #endif

    private func forgeConnection(port: UInt16, token: String) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { _ = Darwin.close(fd); return -1 }
        let hello = ["type": "hello", "token": token, "pid": Int(getpid())] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: hello) else {
            _ = Darwin.close(fd)
            return -1
        }
        let payload = data + Data([10])
        let written = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { _ = Darwin.close(fd); return -1 }
        return fd
    }

    private func forgeIdentityConnection(socketPath: String) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        let bytes = socketPath.utf8CString.map { UInt8(bitPattern: $0) }
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            _ = Darwin.close(fd)
            return -1
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { _ = Darwin.close(fd); return -1 }
        return fd
    }

    private func verifyForgedPeerDoesNotPreventRealHelper(stolenToken: Bool) async throws {
        let helper = try AgentHelperClient()
        var fakeFD: Int32 = -1
        defer {
            if fakeFD >= 0 { _ = Darwin.close(fakeFD) }
            helper.stop()
        }
        helper.onInvitationReadyForTests = { [self] port, token, _ in
            fakeFD = forgeConnection(port: port, token: stolenToken ? token : "wrong-token")
        }
        try await helper.start()
        XCTAssertGreaterThanOrEqual(fakeFD, 0)
        helper.probe()
        for await frame in helper.events where frame.type == "availability" {
            XCTAssertNotNil(frame.claudeInstalled)
            XCTAssertNotNil(frame.codexInstalled)
            return
        }
        XCTFail("The legitimate signed helper did not authenticate after a forged connection")
    }

    func testUntrustedLocalSocketCannotOccupyHelperConnection() async throws {
        try await verifyForgedPeerDoesNotPreventRealHelper(stolenToken: false)
    }

    func testStolenTicketTokenAloneCannotImpersonateSignedHelper() async throws {
        try await verifyForgedPeerDoesNotPreventRealHelper(stolenToken: true)
    }

    func testUntrustedUnixPeerCannotClaimHelperProof() async throws {
        let helper = try AgentHelperClient()
        var fakeFD: Int32 = -1
        defer {
            if fakeFD >= 0 { _ = Darwin.close(fakeFD) }
            helper.stop()
        }
        helper.onInvitationReadyForTests = { [self] _, _, socketPath in
            fakeFD = forgeIdentityConnection(socketPath: socketPath)
        }
        try await helper.start()
        XCTAssertGreaterThanOrEqual(fakeFD, 0)
        // The socket can be connected by the test host, but only the signed
        // bundled executable may receive the proof or occupy the helper slot.
        if fakeFD >= 0 {
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            _ = Darwin.setsockopt(fakeFD, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                                  socklen_t(MemoryLayout<timeval>.size))
            var byte: UInt8 = 0
            let count = Darwin.read(fakeFD, &byte, 1)
            XCTAssertLessThanOrEqual(count, 0, "A different executable must never receive the identity proof")
        }
        helper.discoverInstalledBackends()
        for await frame in helper.events where frame.type == "availability" {
            XCTAssertNotNil(frame.claudeInstalled)
            XCTAssertNotNil(frame.codexInstalled)
            return
        }
        XCTFail("A forged Unix peer prevented the legitimate signed helper from connecting")
    }

    func testInstalledBackendDiscoveryDoesNotRunSignInChecks() async throws {
        let helper = try AgentHelperClient()
        defer { helper.stop() }
        try await helper.start()
        helper.discoverInstalledBackends()
        for await frame in helper.events where frame.type == "availability" {
            XCTAssertNotNil(frame.claudeInstalled)
            XCTAssertNotNil(frame.codexInstalled)
            XCTAssertNil(frame.claudeSignedIn)
            XCTAssertNil(frame.codexSignedIn)
            return
        }
        XCTFail("Installed agent discovery did not answer")
    }

    /// Runs inside the sandboxed invisible AtticUnitTestHost. A real signed
    /// Launch Services helper must connect and authenticate without UI or a
    /// copied credential file; no model CLI is launched by this test.
    func testBundledBackgroundHelperAuthenticatesAndFindsLoginShellPrograms() async throws {
        let helper = try AgentHelperClient()
        defer { helper.stop() }
        do { try await helper.start() }
        catch {
            XCTFail("Helper launch: \(error.localizedDescription), terminated: \(String(describing: helper.launchAppIsTerminated))")
            return
        }
        helper.probe()
        var found = false
        for await frame in helper.events {
            if frame.type == "availability" {
                XCTAssertNotNil(frame.claudeInstalled)
                XCTAssertNotNil(frame.codexInstalled)
                // This call runs the CLIs' own sign-in *status* checks. It
                // reads neither account output nor a credentials file.
                XCTAssertNotNil(frame.claudeSignedIn)
                XCTAssertNotNil(frame.codexSignedIn)
                found = true
                break
            }
        }
        XCTAssertTrue(found)
    }

    func testSimultaneousHelperLaunchesUseIndependentInvitations() async throws {
        let first = try AgentHelperClient()
        let second = try AgentHelperClient()
        defer { first.stop(); second.stop() }

        async let firstReady: Void = first.start()
        async let secondReady: Void = second.start()
        try await firstReady
        try await secondReady

        first.probe()
        second.probe()
        var firstAvailable = false
        for await frame in first.events {
            if frame.type == "availability" {
                firstAvailable = true
                break
            }
        }
        var secondAvailable = false
        for await frame in second.events {
            if frame.type == "availability" {
                secondAvailable = true
                break
            }
        }
        XCTAssertTrue(firstAvailable)
        XCTAssertTrue(secondAvailable)
        XCTAssertNotEqual(first.launchAppIsTerminated, true)
        XCTAssertNotEqual(second.launchAppIsTerminated, true)
    }

    func testAnExpiredInvitationCannotHijackANewHelperLaunch() async throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AtticAgentInvitations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The expired ticket sorts first, exercising the helper's expiry
        // check before it claims its fresh, independent invitation.
        let ticket = directory.appendingPathComponent("00000000-0000-0000-0000-00000000000F.ticket")
        let stale: [String: Any] = ["port": "9", "token": String(repeating: "s", count: 43),
                                    "expires": Date().addingTimeInterval(-60).timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: stale).write(to: ticket, options: .atomic)
        defer { try? FileManager.default.removeItem(at: ticket) }
        let helper = try AgentHelperClient()
        defer { helper.stop() }
        try await helper.start()
        helper.probe()
        var receivedAvailability = false
        for await frame in helper.events {
            if frame.type == "availability" {
                receivedAvailability = true
                break
            }
        }
        XCTAssertTrue(receivedAvailability, "The helper must ignore a stale invitation and authenticate its current launch")
    }

}
