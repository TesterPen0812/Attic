import AppKit
import SwiftUI

struct PanelSettingsView: View {
    @ObservedObject var settings: AppSettings
    /// The connected displays, read when the page appears and when the
    /// displays change (not polled).
    @State private var displays: [AtticDisplay] = []

    var body: some View {
        SettingsPage(section: .panel) {
            // Control audit item 10: hover can be turned off, can need a
            // key, and can answer only on chosen displays. The menu bar
            // icon and the quick capture shortcut always open the panel.
            SettingsGroup(
                title: String(localized: "Corner")
            ) {
                AtticSwitchRow(
                    title: String(localized: "Reveal on hover"),
                    isOn: $settings.revealOnHover,
                    identifier: "setting-reveal-on-hover"
                )
                .help(String(localized: "Open the panel when the pointer rests in the corner"))
                AtticGroupDivider()
                AtticPopUpRow(
                    label: String(localized: "Reveal from"),
                    choices: ScreenCorner.allCases.map { ($0, $0.title) },
                    selection: $settings.corner,
                    identifier: "setting-hiding-corner"
                )
                AtticGroupDivider()
                AtticPopUpRow(
                    label: String(localized: "Only while holding"),
                    choices: RevealModifier.allCases.map { ($0, $0.title) },
                    selection: $settings.revealModifier,
                    identifier: "setting-reveal-modifier"
                )
                .disabled(!settings.revealOnHover)
                .help(String(localized: "A key to hold as the pointer reaches the corner, so passing by opens nothing"))
                AtticGroupDivider()
                AtticPopUpRow(
                    label: String(localized: "Displays"),
                    choices: RevealDisplays.allCases.map { ($0, $0.title) },
                    selection: displaysBinding,
                    identifier: "setting-reveal-displays"
                )
                .disabled(!settings.revealOnHover)
                if settings.revealDisplays == .selected {
                    ForEach(displays) { display in
                        AtticGroupDivider()
                        AtticSwitchRow(
                            title: display.name,
                            isOn: displayBinding(display.id),
                            identifier: "setting-reveal-display-\(display.id)"
                        )
                        .disabled(!settings.revealOnHover)
                    }
                }
            }

            // Accepted 2026-11-01 "Island position: seven spots around the panel".
            SettingsGroup(title: String(localized: "Island")) {
                PanelIslandSpotRow(settings: settings)
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
                .disabled(!settings.revealOnHover)
                AtticGroupDivider()
                AtticPopUpRow(
                    label: String(localized: "Dismiss panel"),
                    choices: PanelDismissMode.allCases.map { ($0, $0.title) },
                    selection: $settings.panelDismissMode,
                    identifier: "setting-panel-dismiss"
                )
                if settings.panelDismissMode == .moveCursorAway {
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
            }

            SettingsGroup(
                title: String(localized: "Shape")
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
        .onAppear { displays = AtticDisplay.connected() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = AtticDisplay.connected()
        }
    }

    /// All Displays or Selected Displays. Choosing Selected with none
    /// chosen yet starts with the display this window is on, so hover
    /// never stops everywhere by surprise.
    private var displaysBinding: Binding<RevealDisplays> {
        Binding(
            get: { settings.revealDisplays },
            set: { choice in
                if choice == .selected, settings.revealDisplayIDs.isEmpty,
                   let current = (NSApp.keyWindow?.screen ?? NSScreen.main).flatMap(AtticDisplay.identifier(for:)) {
                    settings.revealDisplayIDs = [current]
                }
                settings.revealDisplays = choice
            }
        )
    }

    private func displayBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.revealDisplayIDs.contains(id) },
            set: { on in
                if on { settings.revealDisplayIDs.append(id) } else { settings.revealDisplayIDs.removeAll { $0 == id } }
            }
        )
    }
}

enum PanelSettingsRanges {
    static let revealDelay: ClosedRange<Double> = 0.2...2.0
    static let hideDelay: ClosedRange<Double> = 0.1...2.0
}
