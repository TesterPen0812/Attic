import AppKit
import SwiftUI

enum AgentSetupPrompt {
    static let authorizationSummary = "Kept private and never shown in Settings."

    static func make(endpoint: String, bearerToken: String) -> String {
        """
        Set up the local Attic MCP server in the AI client you are currently running.

        Connection:
        - Name: attic
        - Transport: Streamable HTTP
        - URL: \(endpoint)
        - Authorization: Bearer \(bearerToken)

        Complete the setup now using this client's native MCP configuration:
        - Detect whether you are running in Codex, Synara, or Claude and use its user-level configuration.
        - In Codex, configure `mcp_servers.attic` with the URL and `bearer_token_env_var = "ATTIC_MCP_TOKEN"`, then securely set that environment variable for GUI launches. Tell me if Codex must be restarted or a new task opened.
        - In Claude or Synara, register a user-scoped HTTP MCP server named `attic` with the Authorization header above.
        - If `attic` already exists, repair that entry instead of creating a duplicate.
        - Do not alter or remove any other MCP servers.

        Treat the bearer token as a secret: do not echo it in your reply or expose it in logs. After setup, verify the connection by listing Attic's MCP tools. Report only whether setup succeeded and any restart still required.
        """
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var loginItemService: LoginItemService
    @ObservedObject var agentServer: AgentServer
    let agentAccessToken: String

    @AppStorage(SettingsSection.selectionStorageKey)
    private var selectedSectionRawValue = SettingsSection.general.rawValue

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: sidebarSelection)
                .navigationSplitViewColumnWidth(min: 156, ideal: 180, max: 210)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: SettingsWindowLayout.minimumContentSize.width,
            minHeight: SettingsWindowLayout.minimumContentSize.height
        )
        .onAppear {
            loginItemService.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemService.refresh()
        }
    }

    private var sidebarSelection: Binding<SettingsSection?> {
        Binding(
            get: { selectedSection },
            set: { newValue in
                guard let newValue else { return }
                selectedSectionRawValue = newValue.rawValue
            }
        )
    }

    private var selectedSection: SettingsSection {
        SettingsSection.restored(from: selectedSectionRawValue)
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedSection {
        case .general:
            GeneralSettingsView(loginItemService: loginItemService)
        case .panel:
            PanelSettingsView(settings: settings)
        case .appearance:
            AppearanceSettingsView(settings: settings)
        case .agentAccess:
            AgentAccessSettingsView(
                settings: settings,
                agentServer: agentServer,
                agentAccessToken: agentAccessToken
            )
        case .about:
            AboutSettingsView()
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Attic")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.top, 13)
            .padding(.bottom, 9)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Attic Settings")

            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .font(.system(size: 13))
                    .tag(section)
                    .help(section.title)
                    .accessibilityIdentifier(section.accessibilityIdentifier)
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Settings sections")
            .accessibilityIdentifier("settings-sidebar")
        }
    }
}
