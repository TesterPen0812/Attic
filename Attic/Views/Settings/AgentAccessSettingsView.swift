import AppKit
import SwiftUI

struct AgentAccessSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var agentServer: AgentServer
    let agentAccessToken: String

    @State private var didCopyAgentSetupPrompt = false
    @State private var didCopyEndpoint = false

    var body: some View {
        SettingsPage(
            title: "Agent Access",
            subtitle: "Connect trusted local AI tools to Attic through MCP.",
            accessibilityIdentifier: "settings-page-agentAccess"
        ) {
            SettingsGroup("Access") {
                SettingsRow(
                    title: "Allow agent access",
                    description: "Local agents can read, create, update, and permanently delete tasks.",
                    systemImage: "sparkles"
                ) {
                    Toggle("Allow local AI agent access", isOn: $settings.isAgentAccessEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help("Enable Attic's loopback-only MCP server")
                        .accessibilityLabel("Allow local AI agent access")
                        .accessibilityIdentifier("setting-agent-access")
                }
            }

            if SettingsVisibility.showsAgentConnection(
                isEnabled: settings.isAgentAccessEnabled
            ) {
                SettingsGroup("Local server") {
                    VStack(alignment: .leading, spacing: 8) {
                        agentServerStatus

                        Text("Attic listens only on this Mac at the loopback address below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("settings-agent-server-status")

                SettingsGroup("Connection") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Endpoint")
                            .font(.system(size: 12, weight: .medium))

                        HStack(spacing: 10) {
                            Text(endpoint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Agent server endpoint, \(endpoint)")
                                .accessibilityIdentifier("settings-agent-endpoint")

                            Spacer(minLength: 10)

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

                        Divider()

                        Text("Authorization")
                            .font(.system(size: 12, weight: .medium))

                        Label(AgentSetupPrompt.authorizationSummary, systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings-agent-authorization-summary")

                        HStack(alignment: .center, spacing: 10) {
                            Button(action: copyAgentSetupPrompt) {
                                Label(
                                    didCopyAgentSetupPrompt ? "Copy setup prompt again" : "Copy setup prompt",
                                    systemImage: didCopyAgentSetupPrompt ? "checkmark" : "doc.on.clipboard"
                                )
                            }
                            .controlSize(.regular)
                            .accessibilityIdentifier("settings-copy-agent-setup")
                            .help("Copy connection instructions with the private token")

                            if didCopyAgentSetupPrompt {
                                Text("Ready to paste")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .accessibilityIdentifier("settings-agent-setup-copied")
                            }
                        }

                        Text("The setup prompt places the private token on your clipboard. Paste it only into a trusted local AI client.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("settings-agent-connection")
            } else {
                Text("Agent Access is off. No local MCP listener is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("settings-agent-disabled-message")
            }
        }
    }

    private var endpoint: String {
        "http://127.0.0.1:\(settings.agentServerPort)/mcp"
    }

    @ViewBuilder
    private var agentServerStatus: some View {
        switch agentServer.state {
        case .stopped:
            Label("Server stopped", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .starting:
            Label("Starting local server…", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .running:
            Label("Listening on this Mac only", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 7) {
                Label("Could not start the server", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(message)

                Button("Retry") {
                    agentServer.start()
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings-agent-retry")
            }
        }
    }

    private func copyEndpoint() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(endpoint, forType: .string)
        didCopyEndpoint = true
    }

    private func copyAgentSetupPrompt() {
        let prompt = AgentSetupPrompt.make(
            endpoint: endpoint,
            bearerToken: agentAccessToken
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        didCopyAgentSetupPrompt = true
    }
}
