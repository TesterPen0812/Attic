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

}
