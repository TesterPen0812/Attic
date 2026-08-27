import SwiftUI

struct PanelSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(
            title: "Panel",
            subtitle: "Control where the panel lives and how quickly it responds.",
            accessibilityIdentifier: "settings-page-panel"
        ) {
            SettingsGroup("Hiding corner") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Reveal Attic from", systemImage: "rectangle.inset.filled")
                        .font(.system(size: 13, weight: .medium))

                    CornerPicker(selection: $settings.corner)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("The same corner works on every connected display.")
                        Text("macOS Hot Corners may activate at the same time.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(15)
            }

            SettingsGroup("Timing") {
                SettingsRow(
                    title: "Reveal delay",
                    description: "How long the pointer rests in the corner before Attic appears.",
                    systemImage: "timer"
                ) {
                    DelayControl(
                        label: "Reveal delay",
                        value: $settings.revealDelay,
                        range: 0.2...2.0,
                        accessibilityIdentifier: "setting-reveal-delay"
                    )
                }

                SettingsDivider()

                SettingsRow(
                    title: "Hide delay",
                    description: "How long Attic waits after the pointer leaves before hiding.",
                    systemImage: "eye.slash"
                ) {
                    DelayControl(
                        label: "Hide delay",
                        value: $settings.hideDelay,
                        range: 0.1...2.0,
                        accessibilityIdentifier: "setting-hide-delay"
                    )
                }
            }
        }
    }
}

private struct DelayControl: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: 0.1)
                .frame(minWidth: 135, idealWidth: 190, maxWidth: 220)
                .accessibilityLabel(label)
                .accessibilityValue("\(formattedValue) seconds")
                .accessibilityIdentifier(accessibilityIdentifier)

            Text("\(formattedValue) s")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 43, alignment: .trailing)
                .textSelection(.enabled)
                .accessibilityHidden(true)
        }
    }

    private var formattedValue: String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}
