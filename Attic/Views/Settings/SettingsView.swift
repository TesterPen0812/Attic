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
    /// The title line's centre: the content card's 8 pt inset, the
    /// header's 12 pt padding, half the 34 pt header.
    static let titleLineCenterY: CGFloat = AtticSpacing.settingsCardInset + AtticSpacing.s12
        + AtticControlSize.settingsHeaderHeight / 2
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

    @StateObject private var navigation: SettingsNavigation
    @StateObject private var keyboardFocusTracker = AtticKeyboardFocusTracker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(settings: AppSettings, loginItemService: LoginItemService,
         agentServer: AgentServer, globalHotKey: GlobalHotKey, library: AtticLibrary?) {
        self.settings = settings
        self.loginItemService = loginItemService
        self.agentServer = agentServer
        self.globalHotKey = globalHotKey
        self.library = library
        _navigation = StateObject(wrappedValue: SettingsNavigation(defaults: settings.userDefaults))
    }

    var body: some View {
        GeometryReader { available in
            SettingsAdaptiveScroll(size: available.size) {
                settingsContent
            }
        }
        .ignoresSafeArea()
        .atticKeyboardFocusTracking(keyboardFocusTracker)
        .environmentObject(navigation)
        // Customisation changes only the background and the accent; the
        // window follows the chosen Light, Dark or System, and so do its
        // native menus (the pop-up rows), set on the window itself.
        .atticDesignFromSystem(
            palette: settings.panelTheme,
            surface: settings.panelSurfaceStyle,
            tint: settings.panelTint,
            tintLength: settings.panelTintLength,
            hapticsEnabled: settings.hapticsEnabled,
            brightenGlass: settings.brightenGlass,
            animations: settings.animations,
            motion: settings.motionTuning
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

    private var settingsContent: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: AtticLayout.settingsSidebarWidth)
            AtticContentCard {
                page
                    .id(navigation.selection)
                    // Sections cross-fade, 0.16 s ease-out (Accepted
                    // 2026-11-10); pages never scale.
                    .transition(.opacity)
            }
            // 8 pt from the window's edges; the sidebar rows' own 8 pt inset
            // makes the gap to the sidebar.
            .padding([.top, .bottom, .trailing], AtticSpacing.settingsCardInset)
            .animation(AtticMotionScale.resolved(AtticMotionScale.crossfade,
                                                 reduceMotion: reduceMotion || settings.animations == .reduced),
                       value: navigation.selection)
        }
        .background(AtticSidebarBackground())
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

/// Keep the selected page mounted when an unusually small work area requires
/// scrolling. Only the scroll behaviour and minimum content size change.
struct SettingsAdaptiveScroll<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: () -> Content
    /// The style AppKit gives the native scrollers. The bridge below applies
    /// the same preference to the mounted views, on mount and on each change.
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    var body: some View {
        let needsScroll = SettingsWindowLayout.needsContentScroll(size)
        // Only an unusually narrow work area needs horizontal scrolling.
        // Keeping that axis at normal widths lets a focused Appearance
        // control shift the whole sidebar sideways during a theme change.
        let axes: Axis.Set = size.width < SettingsWindowLayout.minimumContentSize.width
            ? [.horizontal, .vertical] : .vertical
        // A legacy horizontal track takes its height from the clip. AppKit's
        // own clip for this frame, worked out in this pass, keeps the page
        // from gaining a spurious vertical range on every resize step.
        let clipHeight = NSScrollView.contentSize(
            forFrameSize: size,
            horizontalScrollerClass: axes.contains(.horizontal) ? NSScroller.self : nil,
            verticalScrollerClass: nil, borderType: .noBorder,
            controlSize: .regular, scrollerStyle: scrollerStyle).height
        ScrollView(axes) {
            content()
                // A vertical ScrollView proposes its *clip* width to the
                // document, after a legacy scrollbar has claimed its gutter.
                // Only an undersized window needs the fixed 640 pt document
                // (and therefore the horizontal scrolling axis).
                .frame(minWidth: size.width < SettingsWindowLayout.minimumContentSize.width
                           ? SettingsWindowLayout.minimumContentSize.width : nil,
                       maxWidth: .infinity)
                .frame(height: max(SettingsWindowLayout.minimumContentSize.height, clipHeight))
        }
        .frame(width: size.width, height: size.height)
        // Beside the scroll view, never behind its document: a platform view
        // there stops the accessibility hit test at the scroll view, so
        // VoiceOver and UI tests cannot reach the sidebar (CI 43876814715).
        .background(SettingsHorizontalScroller(enabled: axes.contains(.horizontal)))
        .scrollDisabled(!needsScroll)
        .scrollIndicators(needsScroll ? .visible : .hidden)
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
    }
}

/// Sync the retained native horizontal axis, and keep the mounted scrollers on
/// the system's scroller style, including the Always-visible preference.
/// It sits behind the outer scroll view with the same frame, which is how it
/// finds that scroll view.
private struct SettingsHorizontalScroller: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> BridgeView { BridgeView(frame: .zero) }
    func updateNSView(_ view: BridgeView, context: Context) {
        view.enabled = enabled
        view.apply()
    }

    final class BridgeView: NSView {
        var enabled = false
        private var preferenceObserver: NSObjectProtocol?
        private weak var scroll: NSScrollView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, preferenceObserver == nil {
                preferenceObserver = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.followPreferredScrollerStyle() }
                }
            } else if window == nil, let preferenceObserver {
                NotificationCenter.default.removeObserver(preferenceObserver)
                self.preferenceObserver = nil
            }
            followPreferredScrollerStyle()
            apply()
        }
        override func layout() { super.layout(); apply() }

        /// The scroll view this view backs: the nearest one, up this view's
        /// own superview chain, that has exactly this view's frame.
        private func resolveScrollView() -> NSScrollView? {
            if let scroll, scroll.window === window { return scroll }
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return nil }
            let target = convert(bounds, to: nil)
            func sameFrame(_ view: NSView) -> Bool {
                let frame = view.convert(view.bounds, to: nil)
                return abs(frame.minX - target.minX) <= 0.5 && abs(frame.minY - target.minY) <= 0.5 &&
                    abs(frame.width - target.width) <= 0.5 && abs(frame.height - target.height) <= 0.5
            }
            func find(in view: NSView) -> NSScrollView? {
                if let candidate = view as? NSScrollView, sameFrame(candidate) { return candidate }
                for child in view.subviews where child !== self {
                    if let found = find(in: child) { return found }
                }
                return nil
            }
            var ancestor = superview
            while let current = ancestor {
                if let found = find(in: current) {
                    scroll = found
                    // First sight of this scroll view: give it the system style.
                    followPreferredScrollerStyle()
                    return found
                }
                ancestor = current.superview
            }
            return nil
        }

        private func followPreferredScrollerStyle() {
            guard window != nil, let scroll = scroll ?? resolveScrollView() else { return }
            // SwiftUI's inner page and the outer viewport both follow the
            // system preference, including live changes while Settings is open.
            let preferredStyle = NSScroller.preferredScrollerStyle
            func update(_ view: NSView) {
                if let nested = view as? NSScrollView, nested.scrollerStyle != preferredStyle {
                    nested.scrollerStyle = preferredStyle
                }
                for child in view.subviews { update(child) }
            }
            update(scroll)
        }

        func apply() {
            guard window != nil, let scroll = resolveScrollView(),
                  scroll.hasHorizontalScroller != enabled else { return }
            scroll.hasHorizontalScroller = enabled
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
