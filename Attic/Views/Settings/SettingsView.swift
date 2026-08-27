import AppKit
import SwiftUI

enum AgentSetupPrompt {
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
    @ObservedObject var store: TaskStore
    let agentAccessToken: String
    @ObservedObject var opticalPermissionController: OpticalPermissionController
    @State private var didCopyAgentSetupPrompt = false
    @State private var isOpticalGlassAdvancedExpanded = false

    var body: some View {
        // Scrolls when the window is shorter than the content (small screens,
        // extra sections like sync errors); the window caps its own height.
        ScrollView {
            content
        }
        .frame(width: 520)
        .onAppear {
            loginItemService.refresh()
            opticalPermissionController.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemService.refresh()
            opticalPermissionController.refresh()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            HStack(alignment: .top, spacing: 28) {
                CornerPicker(selection: $settings.corner)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Hiding corner")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(settings.corner.title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("The same corner works on every connected display.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("macOS Hot Corners may activate at the same time.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Hide delay", systemImage: "eye.slash")
                        .font(.headline)
                    Spacer()
                    Text(settings.hideDelay, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                    Text("sec")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.hideDelay, in: 0.1...2.0, step: 0.1)
                Text("Wait this long after the cursor leaves before Attic hides.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Reveal delay", systemImage: "timer")
                        .font(.headline)
                    Spacer()
                    Text(settings.revealDelay, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                    Text("sec")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.revealDelay, in: 0.2...2.0, step: 0.1)
                Text("Pause in the corner for this long before Attic appears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Appearance", systemImage: "sun.max")
                        .font(.headline)
                    Spacer()
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppearancePreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .labelsHidden()
                }
                Text("Force light or dark for Attic, or follow your Mac's appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            opticalGlassSection

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Corner size", systemImage: "square.dashed")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(settings.panelCornerSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.panelCornerSize, in: PanelCornerSize.min...PanelCornerSize.max, step: 1)
                Text("Control how round the panel corners are. Larger corners curve more content inward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Panel size", systemImage: "rectangle.expand.vertical")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(settings.panelContentSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.panelContentSize, in: PanelContentSize.min...PanelContentSize.max, step: 1)
                Text("Adjust the panel width. Content insets adapt automatically to keep everything inside the squircle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: loginBinding) {
                    Label("Launch at login", systemImage: "power")
                        .font(.headline)
                }

                Text("Open Attic automatically when you log in to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if loginItemService.requiresApproval {
                    HStack {
                        Text("Approval is required in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open Login Items") { loginItemService.openSystemSettings() }
                            .buttonStyle(.link)
                    }
                }

                if let error = loginItemService.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Divider()

            cloudSyncSection

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $settings.isAgentAccessEnabled) {
                    Label("Agent access", systemImage: "sparkles")
                        .font(.headline)
                }
                .toggleStyle(.switch)

                Text("Allow local AI agents to read, create, update and permanently delete tasks over MCP.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.isAgentAccessEnabled {
                    agentServerStatus

                    Text(verbatim: "http://127.0.0.1:\(settings.agentServerPort)/mcp")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)

                    Text("Authorization: Bearer \(agentAccessToken)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help("Required authorization header for local MCP clients")

                    HStack(spacing: 8) {
                        Button(action: copyAgentSetupPrompt) {
                            Label(
                                didCopyAgentSetupPrompt ? "Copy setup prompt again" : "Copy setup prompt",
                                systemImage: didCopyAgentSetupPrompt ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if didCopyAgentSetupPrompt {
                            Text("Ready to paste")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    Text("Paste into Codex, Synara, or Claude. The copied prompt includes your private access token.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let message = settings.cloudSyncStartupErrorMessage {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Label("iCloud sync unavailable", systemImage: "exclamationmark.icloud.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("Attic is using its local task store for this launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .help(message)
                }
            }

            aboutFooter
        }
        .padding(28)
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary)
                    .frame(width: 48, height: 48)
                Image(systemName: "eye.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Attic")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("A quiet list, right around the corner.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var opticalGlassSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Optical glass", systemImage: "circle.hexagongrid")
                    .font(.headline)
                Text("Attic samples the live macOS backdrop. The task and note interface stays in a separate, undistorted foreground layer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Performance", systemImage: "gauge.with.dots.needle.50percent")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("Performance", selection: $settings.glassPerformancePreset) {
                        ForEach(OpticalPerformancePreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 132)
                    .labelsHidden()
                    .accessibilityIdentifier("optical-performance-preset")
                }
                Text(settings.glassPerformancePreset.powerImpactDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.glassPerformancePreset == .off {
                    Text("Off stops ScreenCaptureKit and releases the Metal renderer. Transparency, Frost, and Refraction settings remain saved for the next enabled profile.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            opticalPermissionSection

            opticalControl(
                title: "Transparency",
                systemImage: "circle.lefthalf.filled",
                value: $settings.glassTransparency,
                description: "Controls how much of the live desktop remains visible. 0 is opaque; 100 is clearest."
            )

            opticalControl(
                title: "Frost",
                systemImage: "cloud.fog",
                value: $settings.glassFrost,
                description: "Adds diffusion without changing transparency or edge refraction."
            )

            opticalControl(
                title: "Refraction",
                systemImage: "arrow.left.and.right",
                value: $settings.glassRefraction,
                description: "Bends only the perimeter backdrop. 0 is an exact identity; 100 is the strongest resting profile supported by the selected workload."
            )

            DisclosureGroup(isExpanded: $isOpticalGlassAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    opticalControl(
                        title: "Edge shine",
                        systemImage: "sparkle",
                        value: $settings.glassEdgeShine,
                        description: "Adds a broad optical highlight inside the edge band, never a stroked outline."
                    )
                    opticalControl(
                        title: "Tint",
                        systemImage: "paintpalette",
                        value: $settings.glassTint,
                        description: "Adds a restrained adaptive colour cast without changing the optical displacement."
                    )
                    opticalControl(
                        title: "Readability",
                        systemImage: "textformat",
                        value: $settings.glassReadability,
                        description: "Adds a soft centre veil behind content while leaving the foreground geometry untouched."
                    )
                    opticalControl(
                        title: "Interaction response",
                        systemImage: "cursorarrow.click",
                        value: $settings.glassInteractionResponse,
                        description: "Controls the brief refraction pulse from pointer and scroll interaction. The resting profile is unchanged."
                    )
                }
                .padding(.top, 12)
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("optical-advanced-controls")
        }
    }

    @ViewBuilder
    private var opticalPermissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch opticalPermissionController.state {
            case .notRequested:
                Label("Live refraction needs Screen Recording access", systemImage: "rectangle.inset.filled.and.person.filled")
                    .font(.subheadline.weight(.semibold))
                Text("macOS does not otherwise provide the live backdrop pixels needed for real displacement. Attic will request access only when you press the button below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Enable Live Refraction") {
                    opticalPermissionController.requestAccess()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("optical-permission-action")

            case .authorized:
                Label("Live backdrop access enabled", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text("While Attic is visible, it captures only the small overscanned panel region, excludes Attic's own windows, records no audio or cursor, and never saves screen frames. Hiding the panel or choosing Off releases capture and GPU resources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check Access Again") {
                    opticalPermissionController.refresh()
                }
                .buttonStyle(.link)
                .controlSize(.small)

            case .denied:
                Label("Using the lightweight native fallback", systemImage: "exclamationmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Screen Recording access was not granted, so Attic remains fully functional with native material and does not imitate refraction with a rim or saved screenshot. In System Settings, open Privacy & Security → Screen & System Audio Recording, enable Attic, then return here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Open System Settings") {
                        opticalPermissionController.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Check Again") {
                        opticalPermissionController.refresh()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func opticalControl(
        title: String,
        systemImage: String,
        value: Binding<Double>,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(0)))
                    .monospacedDigit()
                Text("%")
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...100, step: 1)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginItemService.isEnabled },
            set: { loginItemService.setEnabled($0) }
        )
    }

    private func copyAgentSetupPrompt() {
        let endpoint = "http://127.0.0.1:\(settings.agentServerPort)/mcp"
        let prompt = AgentSetupPrompt.make(
            endpoint: endpoint,
            bearerToken: agentAccessToken
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        didCopyAgentSetupPrompt = true
    }

    private var cloudSyncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(store.cloudSyncStatus.title, systemImage: store.cloudSyncStatus.symbolName)
                .font(.headline)
                .foregroundStyle(
                    store.cloudSyncStatus.lastErrorMessage == nil ? Color.primary : Color.orange
                )

            if let lastSuccess = store.cloudSyncStatus.lastSuccessfulActivityAt {
                Text("Last successful iCloud activity \(lastSuccess.formatted(date: .abbreviated, time: .standard)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Attic is waiting for its first completed iCloud import or export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = store.cloudSyncStatus.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .help(error)
            }
        }
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
            VStack(alignment: .leading, spacing: 6) {
                Label("Could not start the server", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { agentServer.start() }
                    .buttonStyle(.link)
            }
        }
    }

    private var aboutFooter: some View {
        VStack(spacing: 7) {
            Text("Made by Emanuele Di Pietro")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Link(destination: URL(string: "https://github.com/Emanuele-web04/Attic")!) {
                Label("Open source on GitHub", systemImage: "arrow.up.right")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Open the Attic repository")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}
