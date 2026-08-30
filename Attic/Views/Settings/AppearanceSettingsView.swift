import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(
            title: "Appearance",
            subtitle: "Keep Attic calm and readable in every workspace.",
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
                    .frame(width: 190)
                    .help("Choose Attic's appearance")
                    .accessibilityLabel("Attic appearance")
                    .accessibilityIdentifier("setting-appearance")
                }
            }

            SettingsGroup("Panel surface") {
                SettingsRow(
                    title: "Translucent panel",
                    description: "Let the desktop show naturally through Attic's surface.",
                    systemImage: "circle.lefthalf.filled"
                ) {
                    Toggle("Use a translucent panel", isOn: $settings.isTranslucent)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help("Use a translucent surface in the Attic panel")
                        .accessibilityLabel("Use a translucent panel")
                        .accessibilityIdentifier("setting-translucency")
                }

                SettingsDivider()

                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .center, spacing: 13) {
                        Image(systemName: "drop.halffull")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.045), in: Circle())
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Glass character")
                                .font(.system(size: 13, weight: .medium))

                            Text(glassDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if settings.isTranslucent {
                        Picker("Glass style", selection: $settings.panelGlassStyle) {
                            ForEach(PanelGlassStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        .accessibilityLabel("Panel glass style")
                        .accessibilityIdentifier("setting-glass-style")
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var glassDescription: String {
        settings.isTranslucent
            ? settings.panelGlassStyle.detail
            : "The solid surface is active while translucency is off."
    }
}
