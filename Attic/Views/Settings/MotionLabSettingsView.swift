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
