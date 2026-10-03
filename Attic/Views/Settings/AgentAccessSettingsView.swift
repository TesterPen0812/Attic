import AppKit
import SwiftUI

struct AgentAccessSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var agentServer: AgentServer

    @State private var didCopyAgentSetupPrompt = false
    @State private var didCopyEndpoint = false

    var body: some View {
        SettingsPage(section: .agentAccess) {
            SettingsGroup(
                title: String(localized: "Access"),
                footnote: String(localized: "Local agents can read, create and update tasks and notes. Their deletes go to Recently Deleted, never permanently.")
            ) {
                AtticSwitchRow(
                    title: String(localized: "Allow agent access"),
                    isOn: $settings.isAgentAccessEnabled,
                    identifier: "setting-agent-access"
                )
                .help(String(localized: "Turn on Attic's MCP server, reachable only from this Mac"))

                if !SettingsVisibility.showsAgentConnection(isEnabled: settings.isAgentAccessEnabled) {
                    AtticGroupDivider()
                    AtticGroupMessage(text: String(localized: "Agent Access is off. Nothing is listening."))
                        .accessibilityIdentifier("settings-agent-disabled-message")
                }
            }

            if SettingsVisibility.showsAgentConnection(isEnabled: settings.isAgentAccessEnabled) {
                SettingsGroup(
                    title: String(localized: "Local server"),
                    footnote: String(localized: "Attic listens only on this Mac, at the address below.")
                ) {
                    serverStatus
                }
                .accessibilityIdentifier("settings-agent-server-status")

                SettingsGroup(
                    title: String(localized: "Connection"),
                    footnote: String(localized: "The setup prompt puts the private token on your clipboard. Paste it only into a trusted local AI client.")
                ) {
                    AtticActionRow(
                        title: String(localized: "Endpoint"),
                        value: endpoint,
                        valueIsSelectable: true,
                        valueIdentifier: "settings-agent-endpoint",
                        actionTitle: didCopyEndpoint ? String(localized: "Copied") : String(localized: "Copy"),
                        actionIdentifier: "settings-copy-agent-endpoint",
                        actionHelp: String(localized: "Copy the local MCP endpoint"),
                        action: copyEndpoint
                    )
                    .accessibilityIdentifier("settings-agent-connection")
                    AtticGroupDivider()
                    AtticActionRow(
                        title: String(localized: "Authorization"),
                        value: AgentSetupPrompt.authorizationSummary,
                        actionTitle: didCopyAgentSetupPrompt
                            ? String(localized: "Copy again")
                            : String(localized: "Copy setup prompt"),
                        actionIdentifier: "settings-copy-agent-setup",
                        actionHelp: String(localized: "Copy connection instructions with the private token"),
                        action: copyAgentSetupPrompt
                    )
                    .disabled(!AgentAccessTokenStore.isValid(agentServer.setupToken))
                    if didCopyAgentSetupPrompt {
                        AtticGroupDivider()
                        AtticGroupMessage(text: String(localized: "Ready to paste into your AI client."))
                            .accessibilityIdentifier("settings-agent-setup-copied")
                    }
                }
            }
        }
    }

    private var endpoint: String {
        "http://127.0.0.1:\(settings.agentServerPort)/mcp"
    }

    @ViewBuilder
    private var serverStatus: some View {
        switch agentServer.state {
        case .stopped:
            AtticStatusRow(title: String(localized: "Server stopped"), systemName: "circle")
        case .starting:
            AtticStatusRow(title: String(localized: "Starting the local server…"), systemName: "circle.dotted")
        case .running:
            AtticStatusRow(title: String(localized: "Listening on this Mac only"), systemName: "checkmark.circle")
        case let .failed(message):
            AtticGroupMessage(
                text: String(localized: "Could not start the server: \(message)"),
                tone: .error,
                actionTitle: String(localized: "Retry")
            ) {
                agentServer.start()
            }
            .accessibilityIdentifier("settings-agent-retry")
        }
    }

    private func copyEndpoint() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(endpoint, forType: .string)
        didCopyEndpoint = true
    }

    private func copyAgentSetupPrompt() {
        guard AgentAccessTokenStore.isValid(agentServer.setupToken) else { return }
        let prompt = AgentSetupPrompt.make(
            endpoint: endpoint,
            bearerToken: agentServer.setupToken
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        didCopyAgentSetupPrompt = true
    }
}
