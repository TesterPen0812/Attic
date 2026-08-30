import SwiftUI

struct PanelSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(
            title: "Panel",
            subtitle: "Control where the panel waits and how it fits your workspace.",
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
                    SettingsSliderControl(
                        label: "Reveal delay",
                        value: $settings.revealDelay,
                        range: 0.2...2.0,
                        step: 0.1,
                        valueText: secondsText(settings.revealDelay),
                        accessibilityValue: secondsAccessibilityText(settings.revealDelay),
                        accessibilityIdentifier: "setting-reveal-delay"
                    )
                }

                SettingsDivider()

                SettingsRow(
                    title: "Hide delay",
                    description: "How long Attic waits after the pointer leaves before hiding.",
                    systemImage: "eye.slash"
                ) {
                    SettingsSliderControl(
                        label: "Hide delay",
                        value: $settings.hideDelay,
                        range: 0.1...2.0,
                        step: 0.1,
                        valueText: secondsText(settings.hideDelay),
                        accessibilityValue: secondsAccessibilityText(settings.hideDelay),
                        accessibilityIdentifier: "setting-hide-delay"
                    )
                }
            }

            SettingsGroup("Shape and size") {
                SettingsRow(
                    title: "Corner size",
                    description: "Round the panel without changing its usable bounds.",
                    systemImage: "square.dashed"
                ) {
                    SettingsSliderControl(
                        label: "Panel corner size",
                        value: $settings.panelCornerSize,
                        range: PanelCornerSize.min...PanelCornerSize.max,
                        step: 1,
                        valueText: pointsText(settings.panelCornerSize),
                        accessibilityValue: pointsAccessibilityText(settings.panelCornerSize),
                        accessibilityIdentifier: "setting-panel-corner-size"
                    )
                }

                SettingsDivider()

                SettingsRow(
                    title: "Panel width",
                    description: "Adjust the panel width. Live resizing remains available from the panel itself.",
                    systemImage: "arrow.left.and.right"
                ) {
                    SettingsSliderControl(
                        label: "Panel width",
                        value: $settings.panelContentSize,
                        range: PanelContentSize.min...PanelContentSize.max,
                        step: 1,
                        valueText: pointsText(settings.panelContentSize),
                        accessibilityValue: pointsAccessibilityText(settings.panelContentSize),
                        accessibilityIdentifier: "setting-panel-width"
                    )
                }
            }
        }
    }

    private func secondsText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    private func secondsAccessibilityText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " seconds"
    }

    private func pointsText(_ value: Double) -> String {
        "\(Int(value.rounded())) pt"
    }

    private func pointsAccessibilityText(_ value: Double) -> String {
        "\(Int(value.rounded())) points"
    }
}

private struct SettingsSliderControl: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String
    let accessibilityValue: String
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .frame(minWidth: 112, idealWidth: 172, maxWidth: 205)
                .accessibilityLabel(label)
                .accessibilityValue(accessibilityValue)
                .accessibilityIdentifier(accessibilityIdentifier)

            Text(valueText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }
}
