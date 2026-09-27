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

/// Where the Settings window's pieces sit (spec § Settings). The window's
/// traffic lights are moved onto the page title's line
/// (`SettingsWindowController`), so these also place them.
enum SettingsChromeLayout {
    /// The back button's centre, from the window's top edge: the content
    /// card's 8 pt inset, the header's 12 pt padding, half the 34 pt button.
    static let titleLineCenterY: CGFloat = AtticSpacing.settingsCardInset + AtticSpacing.s12
        + AtticControlSize.settingsBackButton.height / 2
    /// The close button's leading edge.
    static let trafficLightsLeading: CGFloat = 20
    /// The sidebar's first heading starts below the traffic lights.
    static let sidebarTop: CGFloat = titleLineCenterY + 22
    /// About sits at the bottom, apart from the groups by space alone.
    static let sidebarBottom: CGFloat = AtticSpacing.s12
    /// Space between the sidebar's groups.
    static let sidebarGroupGap: CGFloat = AtticSpacing.s16
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var loginItemService: LoginItemService
    @ObservedObject var agentServer: AgentServer
    @ObservedObject var globalHotKey: GlobalHotKey
    let library: AtticLibrary?

    @StateObject private var navigation = SettingsNavigation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: AtticLayout.settingsSidebarWidth)
            AtticContentCard {
                page
                    .id(navigation.selection)
                    .transition(.opacity)
            }
            // 8 pt from the window's edges; the sidebar rows' own 8 pt inset
            // makes the gap to the sidebar.
            .padding([.top, .bottom, .trailing], AtticSpacing.settingsCardInset)
            .animation(AtticMotionPreset.pageSwitch.animation(reduceMotion: reduceMotion), value: navigation.selection)
        }
        .background(AtticSidebarBackground())
        .ignoresSafeArea()
        .frame(
            minWidth: SettingsWindowLayout.minimumContentSize.width,
            minHeight: SettingsWindowLayout.minimumContentSize.height
        )
        .environmentObject(navigation)
        // Customisation changes only the background and the accent; the
        // window follows the chosen Light, Dark or System, and so do its
        // native menus (the pop-up rows), set on the window itself.
        .atticDesignFromSystem(
            palette: settings.panelTheme,
            surface: settings.panelSurfaceStyle,
            tint: settings.panelTint,
            tintLength: settings.panelTintLength,
            hapticsEnabled: settings.hapticsEnabled
        )
        .atticWindowAppearance(SettingsAppearance.mode(for: settings.appearance))
        .environment(\.atticPanelUsesSystemAccent, settings.panelTheme.usesSystemAccent)
        .onAppear {
            loginItemService.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemService.refresh()
        }
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.selection {
        case .general:
            GeneralSettingsView(settings: settings, loginItemService: loginItemService, globalHotKey: globalHotKey)
        case .panel:
            PanelSettingsView(settings: settings)
        case .appearance:
            AppearanceSettingsView(settings: settings)
        case .recentlyDeleted:
            RecentlyDeletedSettingsView(library: library)
        case .agentAccess:
            AgentAccessSettingsView(settings: settings, agentServer: agentServer)
        case .about:
            AboutSettingsView()
        }
    }
}

/// Attic's Light, Dark or System as a design mode (nil follows the Mac).
enum SettingsAppearance {
    static func mode(for preference: AppearancePreference) -> AtticDesignContext.Mode? {
        switch preference {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The translucent sidebar: App (General, Panel, Appearance, Recently
/// Deleted), Connections (Agent Access, with its quiet hint), and About at
/// the bottom. ↑ ↓ move between pages once the sidebar has keyboard focus;
/// its ring shows only when the keyboard put it there.
private struct SettingsSidebar: View {
    @EnvironmentObject private var navigation: SettingsNavigation
    @FocusState private var isFocused: Bool
    /// True while the keyboard drives the sidebar (Tab, ↑ ↓); a click
    /// clears it, so a mouse selection never draws a ring.
    @State private var keyboardDriven = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: SettingsChromeLayout.sidebarTop)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            ForEach(Array(SettingsSection.Group.allCases.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Color.clear.frame(height: SettingsChromeLayout.sidebarGroupGap)
                }
                AtticSidebarHeading(title: group.title)
                ForEach(group.sections) { section in
                    row(section)
                }
                if let hint = group.hint {
                    AtticSidebarHint(text: hint)
                }
            }
            Spacer(minLength: AtticSpacing.s16)
            row(.about)
                .padding(.bottom, SettingsChromeLayout.sidebarBottom)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            // Tab (a key press) shows the ring; the window's first focus on
            // opening, or a click, does not.
            keyboardDriven = focused && NSApp.currentEvent?.type == .keyDown
        }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Settings sections"))
        .accessibilityIdentifier("settings-sidebar")
    }

    private func row(_ section: SettingsSection) -> some View {
        let isSelected = navigation.selection == section
        return AtticSidebarRow(
            systemName: section.systemImage,
            title: section.title,
            isSelected: isSelected,
            identifier: section.accessibilityIdentifier,
            keyboardFocused: isSelected && isFocused && keyboardDriven
        ) {
            keyboardDriven = false
            isFocused = true
            navigation.select(section)
        }
        .focusable(false)
        .help(section.title)
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard let target = navigation.neighbour(offset: offset) else { return .handled }
        keyboardDriven = true
        navigation.select(target)
        return .handled
    }
}
