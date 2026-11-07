import Foundation
import XCTest
@testable import Attic

@MainActor
final class AgentHelperLaunchTests: XCTestCase {
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
