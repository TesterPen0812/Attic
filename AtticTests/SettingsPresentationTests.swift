import AppKit
import XCTest
@testable import Attic

final class SettingsPresentationTests: XCTestCase {
    func testSettingsSectionsHaveStableLocalOnlyOrderAndIdentifiers() {
        XCTAssertEqual(
            SettingsSection.allCases,
            [.general, .panel, .appearance, .agentAccess, .about]
        )
        XCTAssertEqual(SettingsSection.restored(from: "panel"), .panel)
        XCTAssertEqual(SettingsSection.restored(from: "sync"), .general)
        XCTAssertEqual(SettingsSection.restored(from: "unknown"), .general)
        XCTAssertEqual(
            SettingsSection.allCases.map(\.accessibilityIdentifier),
            [
                "settings-nav-general",
                "settings-nav-panel",
                "settings-nav-appearance",
                "settings-nav-agentAccess",
                "settings-nav-about"
            ]
        )
    }

    func testAuthorizationSummaryNeverContainsSensitiveToken() {
        let token = "private-token-that-must-not-be-rendered"
        let prompt = AgentSetupPrompt.make(
            endpoint: "http://127.0.0.1:7335/mcp",
            bearerToken: token
        )

        XCTAssertTrue(prompt.contains(token), "The explicit clipboard setup action still needs the token.")
        XCTAssertFalse(AgentSetupPrompt.authorizationSummary.contains(token))
        XCTAssertFalse(AgentSetupPrompt.authorizationSummary.localizedCaseInsensitiveContains("bearer"))
    }

    func testConditionalSettingsRowsFollowTheirRealState() {
        XCTAssertFalse(SettingsVisibility.showsLoginApproval(requiresApproval: false))
        XCTAssertTrue(SettingsVisibility.showsLoginApproval(requiresApproval: true))

        XCTAssertFalse(SettingsVisibility.showsAgentConnection(isEnabled: false))
        XCTAssertTrue(SettingsVisibility.showsAgentConnection(isEnabled: true))
    }

    func testWindowUsesPreferredSizeWhenScreenHasRoom() {
        let size = SettingsWindowLayout.fittedContentSize(
            to: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(size.width, SettingsWindowLayout.preferredContentSize.width)
        XCTAssertEqual(size.height, SettingsWindowLayout.preferredContentSize.height)
    }

    func testWindowFitsCompactVisibleFrameWithoutDroppingBelowMinimum() {
        let size = SettingsWindowLayout.fittedContentSize(
            to: NSRect(x: 0, y: 0, width: 680, height: 520)
        )

        XCTAssertEqual(size.width, SettingsWindowLayout.minimumContentSize.width)
        XCTAssertEqual(size.height, 472)
    }
}
