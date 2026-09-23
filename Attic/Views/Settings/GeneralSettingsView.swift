import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var loginItemService: LoginItemService
    @ObservedObject var globalHotKey: GlobalHotKey

    var body: some View {
        SettingsPage(
            title: "General",
            subtitle: "How Attic starts on this Mac.",
            accessibilityIdentifier: "settings-page-general"
        ) {
            Section {
                SettingsRow(
                    title: "Launch at login",
                    description: "Attic is ready as soon as you sign in.",
                    systemImage: "power",
                    tint: .green
                ) {
                    Toggle("Launch Attic at login", isOn: loginBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help("Open Attic automatically when you log in")
                        .accessibilityLabel("Launch Attic at login")
                        .accessibilityIdentifier("setting-launch-at-login")
                }

                if SettingsVisibility.showsLoginApproval(
                    requiresApproval: loginItemService.requiresApproval
                ) {
                    SettingsRow(
                        title: "Approval needed",
                        description: "macOS asks you to allow Attic in Login Items.",
                        systemImage: "exclamationmark.circle.fill",
                        tint: .orange
                    ) {
                        Button("Open Login Items") {
                            loginItemService.openSystemSettings()
                        }
                        .help("Open Login Items in System Settings")
                        .accessibilityIdentifier("settings-open-login-items")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-login-approval")
                }

                if let error = loginItemService.errorMessage {
                    SettingsMessage(text: error, tone: .error)
                        .accessibilityIdentifier("settings-login-error")
                }
            } header: {
                Text("Startup")
            } footer: {
                SettingsFootnote("Attic lives in the corner of your screen and in the menu bar. It has no Dock icon.")
            }

            // Nothing is shown while the shortcut works: the menu already
            // advertises it. Only a refusal needs explaining.
            if let failure = SettingsVisibility.globalShortcutFailure(globalHotKey.registration) {
                Section("Shortcut") {
                    SettingsMessage(text: failure.settingsMessage, tone: .warning)
                        .accessibilityIdentifier("settings-global-shortcut-unavailable")
                }
            }
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginItemService.isEnabled },
            set: { loginItemService.setEnabled($0) }
        )
    }
}
