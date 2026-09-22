import SwiftUI

struct PanelSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(
            title: "Panel",
            subtitle: "Where the panel waits, and how it fits your desk.",
            accessibilityIdentifier: "settings-page-panel"
        ) {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    SettingsRowLabel(
                        title: "Reveal from",
                        description: "Rest the pointer in this corner of any display to open Attic.",
                        systemImage: "arrow.up.right.square.fill",
                        tint: .blue
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    CornerPicker(selection: $settings.corner)
                }
            } header: {
                Text("Corner")
            } footer: {
                SettingsFootnote(
                    "Drag the panel's top edge to move it to another corner. "
                    + "Swipe two fingers toward the screen edge to hide it, even while it's pinned; "
                    + "canvas gestures stay on the canvas. Hot Corners can trigger at the same time."
                )
            }

            Section("Timing") {
                SettingsRow(
                    title: "Reveal delay",
                    description: "How long the pointer rests in the corner first.",
                    systemImage: "timer",
                    tint: .orange
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

                SettingsRow(
                    title: "Hide delay",
                    description: "How long Attic waits after the pointer leaves.",
                    systemImage: "eye.slash.fill",
                    tint: .orange
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

            Section {
                SettingsRow(
                    title: "Corner size",
                    description: "Rounder corners, same usable space.",
                    systemImage: "square.dashed",
                    tint: .indigo
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

                SettingsRow(
                    title: "Width",
                    description: "You can also drag the panel's inward edge.",
                    systemImage: "arrow.left.and.right",
                    tint: .indigo
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
            } header: {
                Text("Shape")
            } footer: {
                SettingsFootnote("The docked corner stays put; the panel grows toward the middle of the screen.")
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
        "\(SettingsPointFormat.rounded(value)) pt"
    }

    private func pointsAccessibilityText(_ value: Double) -> String {
        "\(SettingsPointFormat.rounded(value)) points"
    }
}

/// Point values are rendered from whatever the model currently holds, so the
/// formatting must be total over every `Double`. `Int(value.rounded())` traps
/// on any magnitude `Int` cannot represent, and a corrupt preference can carry
/// a finite value such as `1e30` past validation — reading Settings then
/// crashed the app rather than showing a number.
enum SettingsPointFormat {
    static func rounded(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
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
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }
}
