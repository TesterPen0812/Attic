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
    @ObservedObject var globalHotKey: GlobalHotKey

    @AppStorage(SettingsSection.selectionStorageKey)
    private var selectedSectionRawValue = SettingsSection.general.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: sidebarSelection)
                .navigationSplitViewColumnWidth(min: 172, ideal: 196, max: 230)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: SettingsWindowLayout.minimumContentSize.width,
            minHeight: SettingsWindowLayout.minimumContentSize.height
        )
        .tint(settingsAccentColor)
        .accentColor(settingsAccentColor)
        .environment(
            \.atticPanelUsesSystemAccent,
            settings.panelTheme.usesSystemAccent
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

    /// Settings follow the panel's palette accent, as they always have.
    private var settingsAccentColor: Color {
        settings.panelTheme.usesSystemAccent
            ? Color.accentColor
            : settings.panelTheme.palette(
                for: colorScheme,
                contrast: colorSchemeContrast
            ).accentColor
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedSection {
        case .general:
            GeneralSettingsView(
                loginItemService: loginItemService,
                globalHotKey: globalHotKey
            )
        case .panel:
            PanelSettingsView(settings: settings)
        case .appearance:
            AppearanceSettingsView(settings: settings)
        case .agentAccess:
            AgentAccessSettingsView(
                settings: settings,
                agentServer: agentServer
            )
        case .about:
            AboutSettingsView()
        }
    }
}

/// The sidebar: Attic's identity at the top, then one tinted row per pane.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection?

    var body: some View {
        List(SettingsSection.allCases, selection: $selection) { section in
            Label {
                Text(section.title)
            } icon: {
                SettingsIcon(systemImage: section.systemImage, tint: section.tint)
            }
            .tag(section)
            .help(section.title)
            .accessibilityIdentifier(section.accessibilityIdentifier)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Attic")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Attic Settings")
        }
        .accessibilityLabel("Settings sections")
        .accessibilityIdentifier("settings-sidebar")
    }
}
