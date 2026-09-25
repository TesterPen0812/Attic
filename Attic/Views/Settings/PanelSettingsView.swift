import SwiftUI

struct PanelSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(section: .panel) {
            SettingsGroup(
                title: String(localized: "Corner"),
                footnote: String(localized: "Works on every display. Drag the panel's top edge to another corner, or swipe two fingers toward the screen edge to hide it.")
            ) {
                AtticPopUpRow(
                    label: String(localized: "Reveal from"),
                    choices: ScreenCorner.allCases.map { ($0, $0.title) },
                    selection: $settings.corner,
                    identifier: "setting-hiding-corner"
                )
            }

            SettingsGroup(title: String(localized: "Timing")) {
                AtticSliderRow(
                    label: String(localized: "Reveal delay"),
                    valueText: SettingsPointFormat.seconds(settings.revealDelay),
                    value: $settings.revealDelay,
                    range: PanelSettingsRanges.revealDelay,
                    step: 0.1,
                    accessibilityValue: SettingsPointFormat.spokenSeconds(settings.revealDelay),
                    identifier: "setting-reveal-delay"
                )
                AtticGroupDivider()
                AtticSliderRow(
                    label: String(localized: "Hide delay"),
                    valueText: SettingsPointFormat.seconds(settings.hideDelay),
                    value: $settings.hideDelay,
                    range: PanelSettingsRanges.hideDelay,
                    step: 0.1,
                    accessibilityValue: SettingsPointFormat.spokenSeconds(settings.hideDelay),
                    identifier: "setting-hide-delay"
                )
            }

            SettingsGroup(
                title: String(localized: "Shape"),
                footnote: String(localized: "You can also drag the panel's inward edge. The docked corner stays put.")
            ) {
                AtticSliderRow(
                    label: String(localized: "Corner size"),
                    valueText: SettingsPointFormat.points(settings.panelCornerSize),
                    value: $settings.panelCornerSize,
                    range: PanelCornerSize.min...PanelCornerSize.max,
                    step: 1,
                    accessibilityValue: SettingsPointFormat.spokenPoints(settings.panelCornerSize),
                    identifier: "setting-panel-corner-size"
                )
                AtticGroupDivider()
                AtticSliderRow(
                    label: String(localized: "Width"),
                    valueText: SettingsPointFormat.points(settings.panelContentSize),
                    value: $settings.panelContentSize,
                    range: PanelContentSize.min...max(PanelContentSize.max, settings.panelContentSize),
                    step: 1,
                    accessibilityValue: SettingsPointFormat.spokenPoints(settings.panelContentSize),
                    identifier: "setting-panel-width"
                )
            }
        }
    }
}

enum PanelSettingsRanges {
    static let revealDelay: ClosedRange<Double> = 0.2...2.0
    static let hideDelay: ClosedRange<Double> = 0.1...2.0
}
