import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var loginItemService: LoginItemService

    var body: some View {
        SettingsPage(
            title: "General",
            subtitle: "Choose how Attic starts on this Mac.",
            accessibilityIdentifier: "settings-page-general"
        ) {
            SettingsGroup("Startup") {
                SettingsRow(
                    title: "Launch at login",
                    description: "Keep Attic ready whenever you sign in to this Mac.",
                    systemImage: "power"
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
                    SettingsDivider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Approval is required in System Settings.", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Open Login Items") {
                            loginItemService.openSystemSettings()
                        }
                        .controlSize(.small)
                        .help("Open Login Items in System Settings")
                        .accessibilityIdentifier("settings-open-login-items")
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .accessibilityIdentifier("settings-login-approval")
                }

                if let error = loginItemService.errorMessage {
                    SettingsDivider()
                    SettingsMessage(text: error, tone: .error)
                        .accessibilityIdentifier("settings-login-error")
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
