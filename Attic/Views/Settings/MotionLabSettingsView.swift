import SwiftUI

/// Preview tools retained for edge blur and the native-popover experiment.
struct MotionLabSettingsGroup: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var edgeBlur = AtticEdgeBlurLab.shared

    var body: some View {
        SettingsGroup(
            title: "Motion Lab",
            footnote: "Preview builds only. Each change applies at once: open the panel and try it.",
            identifier: "settings-motion-lab"
        ) {
            if edgeBlur.offersTuning {
                AtticSliderRow(label: "Edge blur strength", valueText: String(format: "%.1f pt", edgeBlur.radius),
                               value: $edgeBlur.radius, range: AtticEdgeBlurLab.radiusRange, step: 0.5,
                               identifier: "setting-edge-blur-radius")
                AtticGroupDivider()
                AtticSliderRow(label: "Edge blur reach", valueText: String(format: "%.0f pt", edgeBlur.reach),
                               value: $edgeBlur.reach, range: AtticEdgeBlurLab.reachRange, step: 1,
                               identifier: "setting-edge-blur-reach")
                AtticGroupDivider()
            }
            AtticSwitchRow(
                title: "Native pop-overs spring in (experimental)",
                isOn: $settings.motionTuning.popsNativePopovers,
                identifier: "setting-motion-native-popovers"
            )
        }
    }
}

/// Preview-only speed lab (owner, 2026-10-19): the chosen hide animation's
/// hide and reveal durations, to tune on screen. The values become each
/// animation's default later and the lab goes. Never under the release
/// identity (`GeneralSettingsView` shows it only with `motionLabAvailable`).
struct HideSpeedLabSettingsGroup: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let mode = settings.hideAnimation
        let lab = settings.hideSpeedLab
        let isDefault = lab.duration(mode, hiding: true) == mode.defaultHideDuration
            && lab.duration(mode, hiding: false) == mode.defaultRevealDuration
        SettingsGroup(
            title: "Hide Speed Lab: \(mode.title)",
            footnote: "Preview builds only. Applies on the next hide or reveal. Pick another Hide animation above to tune it; each keeps its own values.",
            identifier: "settings-hide-speed-lab"
        ) {
            row("Hide", mode: mode, hiding: true)
            AtticGroupDivider()
            row("Reveal", mode: mode, hiding: false)
            AtticGroupDivider()
            HStack {
                AtticText(verbatim: String(format: "Default: hide %.0f ms, reveal %.0f ms",
                                           mode.defaultHideDuration * 1000, mode.defaultRevealDuration * 1000),
                          style: .rowSingle, ink: .body)
                Spacer(minLength: AtticSettingsMetrics.rowTrailingMinGap)
                AtticRaisedButton(systemName: nil, title: "Reset", height: AtticSettingsRowMetrics.actionHeight) {
                    settings.hideSpeedLab.setDuration(mode.defaultHideDuration, mode, hiding: true)
                    settings.hideSpeedLab.setDuration(mode.defaultRevealDuration, mode, hiding: false)
                }
                .fixedSize()
                .disabled(isDefault)
                .atticIdentifier("setting-hide-speed-reset")
            }
            .padding(.leading, AtticLayout.groupedRowTextInset)
            .padding(.trailing, AtticLayout.groupedRowTextInset)
            .frame(height: AtticLayout.groupedRowSingle)
        }
    }

    private func row(_ label: String, mode: PanelHideAnimation, hiding: Bool) -> some View {
        let milliseconds = settings.hideSpeedLab.duration(mode, hiding: hiding) * 1000
        return AtticSliderRow(
            label: label, valueText: String(format: "%.0f ms", milliseconds),
            value: Binding(
                get: { settings.hideSpeedLab.duration(mode, hiding: hiding) * 1000 },
                set: { settings.hideSpeedLab.setDuration($0 / 1000, mode, hiding: hiding) }
            ),
            range: PanelHideSpeedLab.range, step: PanelHideSpeedLab.step,
            accessibilityValue: String(format: "%.0f milliseconds", milliseconds),
            identifier: "setting-hide-speed-\(hiding ? "hide" : "reveal")"
        )
    }
}
