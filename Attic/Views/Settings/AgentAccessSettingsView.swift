import AppKit
import SwiftUI

struct AgentAccessSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var agentServer: AgentServer

    @State private var didCopyAgentSetupPrompt = false
    @State private var didCopyEndpoint = false

    var body: some View {
        SettingsPage(
            title: "Agent Access",
            subtitle: "Let trusted AI tools on this Mac work with your tasks through MCP.",
            accessibilityIdentifier: "settings-page-agentAccess"
        ) {
            Section {
                SettingsRow(
                    title: "Allow agent access",
                    description: "Local agents can read, create, update and permanently delete items.",
                    systemImage: "sparkles",
                    tint: .orange
                ) {
                    Toggle("Allow local AI agent access", isOn: $settings.isAgentAccessEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help("Enable Attic's loopback-only MCP server")
                        .accessibilityLabel("Allow local AI agent access")
                        .accessibilityIdentifier("setting-agent-access")
                }

                if !SettingsVisibility.showsAgentConnection(isEnabled: settings.isAgentAccessEnabled) {
                    SettingsMessage(text: "Agent Access is off. Nothing is listening.", tone: .information)
                        .accessibilityIdentifier("settings-agent-disabled-message")
                }
            } header: {
                Text("Access")
            }

            if SettingsVisibility.showsAgentConnection(
                isEnabled: settings.isAgentAccessEnabled
            ) {
                Section {
                    agentServerStatus
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings-agent-server-status")
                } header: {
                    Text("Local server")
                } footer: {
                    SettingsFootnote("Attic listens only on this Mac, at the loopback address below.")
                }

                Section {
                    LabeledContent {
                        HStack(spacing: 10) {
                            endpointText
                            copyEndpointButton
                        }
                    } label: {
                        SettingsRowLabel(
                            title: "Endpoint",
                            description: nil,
                            systemImage: "link",
                            tint: .blue
                        )
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-agent-connection")

                    LabeledContent {
                        HStack(alignment: .center, spacing: 10) {
                            if didCopyAgentSetupPrompt {
                                Text("Ready to paste")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .accessibilityIdentifier("settings-agent-setup-copied")
                            }
                            Button(action: copyAgentSetupPrompt) {
                                Label(
                                    didCopyAgentSetupPrompt ? "Copy Setup Prompt Again" : "Copy Setup Prompt",
                                    systemImage: didCopyAgentSetupPrompt ? "checkmark" : "doc.on.clipboard"
                                )
                            }
                            .disabled(!AgentAccessTokenStore.isValid(agentServer.setupToken))
                            .accessibilityIdentifier("settings-copy-agent-setup")
                            .help("Copy connection instructions with the private token")
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Authorization")
                                Text(AgentSetupPrompt.authorizationSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("settings-agent-authorization-summary")
                            }
                        } icon: {
                            SettingsIcon(systemImage: "key.fill", tint: .gray)
                        }
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    SettingsFootnote(
                        "The setup prompt puts the private token on your clipboard. "
                        + "Paste it only into a trusted local AI client."
                    )
                }
            }
        }
    }

    private var endpoint: String {
        "http://127.0.0.1:\(settings.agentServerPort)/mcp"
    }

    private var endpointText: some View {
        Text(endpoint)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .accessibilityIdentifier("settings-agent-endpoint")
    }

    private var copyEndpointButton: some View {
        Button {
            copyEndpoint()
        } label: {
            Label(
                didCopyEndpoint ? "Copied" : "Copy",
                systemImage: didCopyEndpoint ? "checkmark" : "doc.on.doc"
            )
        }
        .controlSize(.small)
        .help("Copy the local MCP endpoint")
        .accessibilityIdentifier("settings-copy-agent-endpoint")
    }

    @ViewBuilder
    private var agentServerStatus: some View {
        switch agentServer.state {
        case .stopped:
            SettingsRow(title: "Server stopped", systemImage: "circle", tint: .gray) { EmptyView() }
        case .starting:
            SettingsRow(title: "Starting the local server…", systemImage: "circle.dotted", tint: .gray) {
                ProgressView().controlSize(.small)
            }
        case .running:
            SettingsRow(
                title: "Listening on this Mac only",
                systemImage: "checkmark.circle.fill",
                tint: .green
            ) { EmptyView() }
        case let .failed(message):
            SettingsRow(
                title: "Could not start the server",
                description: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .red
            ) {
                Button("Retry") {
                    agentServer.start()
                }
                .accessibilityIdentifier("settings-agent-retry")
            }
            .help(message)
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
