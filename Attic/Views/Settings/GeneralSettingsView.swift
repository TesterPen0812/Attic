import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var loginItemService: LoginItemService
    @ObservedObject var globalHotKey: GlobalHotKey

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

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
                footnote: SettingsVisibility.behaviourFootnote(systemReducesMotion: systemReduceMotion)
            ) {
                AtticSwitchRow(
                    title: String(localized: "Haptics"),
                    isOn: $settings.hapticsEnabled,
                    identifier: "setting-haptics"
                )
                .help(String(localized: "A light tap on the trackpad when you complete a task or drop something into place"))
                AtticGroupDivider()
                // Lively (the default) or Subtle springs, or Reduced to
                // crossfades and instant changes (round 9, owner item 26;
                // Lively and Subtle: the Motion Lab's finish).
                AtticPopUpRow(
                    label: String(localized: "Animations"),
                    choices: AtticAnimationLevel.allCases.map { ($0, $0.title) },
                    selection: $settings.animations,
                    identifier: "setting-animations"
                )
                .help(String(localized: "Lively springs things in and away. Subtle does the same more quietly. Reduced fades or changes at once instead of moving."))
            }

            // The Motion Lab: preview builds only (never the release
            // identity), to feel the motion live and pick it.
            if settings.motionLabAvailable {
                MotionLabSettingsGroup(settings: settings)
            }

            // Round 10 (the capability audit): the global quick capture
            // shortcut can be recorded, reset, turned off, and tried again
            // after a refusal.
            SettingsGroup(
                title: String(localized: "Quick Capture"),
                footnote: String(localized: "From any app, the shortcut opens Attic on Tasks with the add bar ready.")
            ) {
                AtticSwitchRow(
                    title: String(localized: "Quick capture shortcut"),
                    isOn: $settings.quickCaptureEnabled,
                    identifier: "setting-quick-capture"
                )
                AtticGroupDivider()
                AtticShortcutRecorderRow(
                    title: String(localized: "Shortcut"),
                    value: settings.quickCaptureShortcut.displayName ?? "",
                    spokenValue: settings.quickCaptureShortcut.spokenName ?? "",
                    isDefault: settings.quickCaptureShortcut == .newTask,
                    identifier: "setting-quick-capture-shortcut",
                    recordingChanged: recordingChanged,
                    record: record,
                    reset: { settings.quickCaptureShortcut = .newTask }
                )
                .disabled(!settings.quickCaptureEnabled)
                // Only a refusal needs explaining: while it works, the menu
                // bar's menu advertises it.
                if settings.quickCaptureEnabled, let failure = SettingsVisibility.globalShortcutFailure(globalHotKey.registration) {
                    AtticGroupDivider()
                    AtticGroupMessage(text: failure.settingsMessage, tone: .warning)
                        .accessibilityIdentifier("settings-global-shortcut-unavailable")
                    AtticGroupDivider()
                    AtticActionRow(
                        title: String(localized: "Shortcut is off"),
                        actionTitle: String(localized: "Try Again"),
                        actionIdentifier: "settings-global-shortcut-retry",
                        actionHelp: String(localized: "Claim the shortcut again")
                    ) {
                        globalHotKey.retry()
                    }
                }
            }
        }
    }

    /// Whether the claim was held when recording began: while a new
    /// combination is typed the old one is released (else pressing it
    /// would open the panel instead of being recorded), and it is claimed
    /// again if the recording ends without a new one.
    @State private var claimedBeforeRecording = false

    private func recordingChanged(_ recording: Bool) {
        if recording {
            claimedBeforeRecording = globalHotKey.registration.isActive
            if claimedBeforeRecording { globalHotKey.unregister() }
        } else if claimedBeforeRecording, !globalHotKey.registration.isActive {
            // Unchanged (Esc, or the same combination): claim it again. A
            // new combination is claimed by the app as the setting changes.
            globalHotKey.apply(settings.quickCaptureShortcut, enabled: settings.quickCaptureEnabled)
        }
    }

    /// A key pressed while recording: taken when Attic can claim it
    /// (`GlobalHotKeyCombination.recordingProblem`), else why not.
    private func record(_ event: NSEvent) -> String? {
        let combination = GlobalHotKeyCombination(keyCode: UInt32(event.keyCode),
                                                  modifiers: GlobalHotKeyCombination.carbonModifiers(event.modifierFlags))
        if let problem = combination.recordingProblem { return problem }
        settings.quickCaptureShortcut = combination
        return nil
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginItemService.isEnabled },
            set: { loginItemService.setEnabled($0) }
        )
    }
}
