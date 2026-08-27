import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(
            title: "Appearance",
            subtitle: "Keep Attic comfortable and readable in your workspace.",
            accessibilityIdentifier: "settings-page-appearance"
        ) {
            SettingsGroup("App appearance") {
                SettingsRow(
                    title: "Color scheme",
                    description: "Follow your Mac or keep Attic in Light or Dark appearance.",
                    systemImage: "sun.max"
                ) {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppearancePreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .help("Choose Attic's appearance")
                    .accessibilityLabel("Attic appearance")
                    .accessibilityIdentifier("setting-appearance")
                }
            }

            SettingsGroup("Panel surface") {
                SettingsRow(
                    title: "Translucent panel",
                    description: "Let the desktop show naturally through the panel's native material.",
                    systemImage: "circle.lefthalf.filled"
                ) {
                    Toggle("Use a translucent panel", isOn: $settings.isTranslucent)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help("Use the native translucent material in the Attic panel")
                        .accessibilityLabel("Use a translucent panel")
                        .accessibilityIdentifier("setting-translucency")
                }
            }
        }
    }
}
