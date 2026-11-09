import Foundation
import Darwin
import XCTest
@testable import Attic

@MainActor
final class AgentHelperLaunchTests: XCTestCase {
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

    private func verifyForgedPeerDoesNotPreventRealHelper(stolenToken: Bool) async throws {
        let helper = try AgentHelperClient()
        var fakeFD: Int32 = -1
        defer {
            if fakeFD >= 0 { _ = Darwin.close(fakeFD) }
            helper.stop()
        }
        helper.onInvitationReadyForTests = { [self] port, token in
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
