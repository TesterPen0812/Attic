import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var loginItemService: LoginItemService
    @ObservedObject var globalHotKey: GlobalHotKey

    var body: some View {
        SettingsPage(section: .general) {
            SettingsGroup(
                title: String(localized: "Startup"),
                footnote: String(localized: "Attic lives in the corner of your screen and in the menu bar. It has no Dock icon.")
            ) {
                AtticSwitchRow(
                    title: String(localized: "Launch at login"),
                    isOn: loginBinding,
                    identifier: "setting-launch-at-login"
                )
                .help(String(localized: "Open Attic automatically when you log in"))

                if SettingsVisibility.showsLoginApproval(requiresApproval: loginItemService.requiresApproval) {
                    AtticGroupDivider()
                    AtticActionRow(
                        title: String(localized: "Approval needed"),
                        value: String(localized: "Allow Attic in Login Items"),
                        actionTitle: String(localized: "Open Login Items"),
                        actionIdentifier: "settings-open-login-items",
                        actionHelp: String(localized: "Open Login Items in System Settings")
                    ) {
                        loginItemService.openSystemSettings()
                    }
                    .accessibilityIdentifier("settings-login-approval")
                }

                if let error = loginItemService.errorMessage {
                    AtticGroupDivider()
                    AtticGroupMessage(text: error, tone: .error)
                        .accessibilityIdentifier("settings-login-error")
                }
            }

            SettingsGroup(
                title: String(localized: "Behaviour"),
                footnote: String(localized: "A light tap on the trackpad when you complete a task or drop something into place.")
            ) {
                AtticSwitchRow(
                    title: String(localized: "Haptics"),
                    isOn: $settings.hapticsEnabled,
                    identifier: "setting-haptics"
                )
            }

            // Nothing is shown while the shortcut works: the menu already
            // advertises it. Only a refusal needs explaining.
            if let failure = SettingsVisibility.globalShortcutFailure(globalHotKey.registration) {
                SettingsGroup(title: String(localized: "Shortcut")) {
                    AtticGroupMessage(text: failure.settingsMessage, tone: .warning)
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
