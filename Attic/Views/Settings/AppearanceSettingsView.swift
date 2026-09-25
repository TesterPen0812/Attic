import SwiftUI

enum AppearanceSettingsPresentation {
    static let themeChooserAccessibilityIdentifier = "setting-panel-theme"

    static var orderedThemeAccessibilityIdentifiers: [String] {
        AtticPanelTheme.allCases.map(\.accessibilityIdentifier)
    }

    static func modeAccessibilityIdentifier(_ preference: AppearancePreference) -> String {
        "setting-appearance-\(preference.rawValue)"
    }

    /// What the Tint length row shows and VoiceOver reads.
    static func tintLengthDescription(_ length: Double) -> String {
        let percent = Int((PanelTintLength.clamped(length) * 100).rounded())
        return percent >= 100 ? "Full height" : "\(percent) percent of the panel"
    }

    /// The Tint length value as the row shows it ("Full height", "60 %").
    static func tintLengthValue(_ length: Double) -> String {
        let percent = Int((PanelTintLength.clamped(length) * 100).rounded())
        return percent >= 100 ? String(localized: "Full height") : String(localized: "\(percent) % of the panel")
    }

    /// The one line the pane shows when the readability floor, not the
    /// chosen step, sets the wash for this palette and surface; nil when the
    /// step reaches its full strength.
    static func tintFloorNote(for treatment: AtticPanelSurfaceTreatment) -> String? {
        guard treatment.tint != .off, treatment.isTintClamped else { return nil }
        return "Tint is kept faint here so text stays readable."
    }

    /// The footnote under Surface and tint: why the surface looks solid,
    /// or why the tint is fainter than chosen, or nothing.
    static func surfaceFootnote(reduceTransparency: Bool, treatment: AtticPanelSurfaceTreatment) -> String? {
        if reduceTransparency {
            return String(localized: "Reduce Transparency is on, so the panel is drawn solid. Your surface choice is kept.")
        }
        return tintFloorNote(for: treatment)
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Palette tiles keep their size and wrap, 12 pt apart.
    private let paletteColumns = [
        GridItem(
            .adaptive(minimum: AtticPaletteTileMetrics.width, maximum: AtticPaletteTileMetrics.width),
            spacing: AtticPaletteTileMetrics.spacing,
            alignment: .leading
        )
    ]

    var body: some View {
        SettingsPage(section: .appearance) {
            AtticAppearancePreview(accessibilityLabel: previewDescription) {
                SettingsPanelMiniature(cornerSize: CGFloat(PanelGeometryCornerSize.sanitised(settings.panelCornerSize)))
            }
            .accessibilityIdentifier("setting-appearance-preview")
            Color.clear.frame(height: AtticSpacing.s12)

            AtticGroupCard {
                HStack(spacing: AtticModeTileMetrics.tileSpacing) {
                    ForEach(AppearancePreference.allCases) { preference in
                        AtticModeTile(
                            choice: modeChoice(preference),
                            isSelected: settings.appearance == preference,
                            identifier: AppearanceSettingsPresentation.modeAccessibilityIdentifier(preference)
                        ) {
                            guard settings.appearance != preference else { return }
                            settings.appearance = preference
                        }
                    }
                }
                .padding(.vertical, AtticSpacing.s16)
                .frame(maxWidth: .infinity)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Appearance"))
            .accessibilityValue(settings.appearance.title)
            .accessibilityIdentifier("setting-appearance")
            .padding(.bottom, AtticSpacing.settingsBetweenSections)

            SettingsTileSection(title: String(localized: "Palette")) {
                LazyVGrid(columns: paletteColumns, alignment: .leading, spacing: AtticPaletteTileMetrics.spacing) {
                    ForEach(AtticPanelTheme.allCases) { theme in
                        AtticPaletteTile(
                            palette: theme,
                            isSelected: settings.panelTheme == theme,
                            identifier: theme.accessibilityIdentifier
                        ) {
                            settings.panelTheme = theme
                        }
                        .help(theme.detail)
                    }
                }
                // The tiles' selection ring sits 4 pt outside them.
                .padding(.horizontal, AtticRingMetrics.outset)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Palette"))
                .accessibilityIdentifier(AppearanceSettingsPresentation.themeChooserAccessibilityIdentifier)
            }

            SettingsGroup(
                title: String(localized: "Surface and tint"),
                footnote: AppearanceSettingsPresentation.surfaceFootnote(
                    reduceTransparency: reduceTransparency, treatment: treatment
                )
            ) {
                AtticPopUpRow(
                    label: String(localized: "Surface"),
                    choices: PanelSurfaceStyle.allCases.map { ($0, $0.title) },
                    selection: $settings.panelSurfaceStyle,
                    identifier: "setting-panel-surface"
                )
                .help(settings.panelSurfaceStyle.detail)
                AtticGroupDivider()
                AtticPopUpRow(
                    label: String(localized: "Tint"),
                    choices: PanelTintLevel.allCases.map { ($0, $0.title) },
                    selection: $settings.panelTint,
                    identifier: "setting-panel-tint"
                )
                .help(settings.panelTint.detail(neutral: settings.panelTheme.usesNeutralTint))
            }

            SettingsGroup(
                title: String(localized: "Advanced"),
                footnote: settings.panelTint == .off ? String(localized: "Choose a tint to set how far down the panel it reaches.") : nil
            ) {
                AtticSliderRow(
                    label: String(localized: "Tint length"),
                    valueText: AppearanceSettingsPresentation.tintLengthValue(settings.panelTintLength),
                    value: $settings.panelTintLength,
                    range: PanelTintLength.range,
                    accessibilityValue: AppearanceSettingsPresentation.tintLengthDescription(settings.panelTintLength),
                    identifier: "setting-panel-tint-length"
                )
                .disabled(settings.panelTint == .off)
            }
        }
    }

    private func modeChoice(_ preference: AppearancePreference) -> AtticModeTile.Choice {
        switch preference {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }

    private var effectiveColorScheme: ColorScheme {
        switch settings.appearance {
        case .light: .light
        case .dark: .dark
        case .system: colorScheme
        }
    }

    private var treatment: AtticPanelSurfaceTreatment {
        settings.panelSurfaceTreatment(
            colorScheme: effectiveColorScheme,
            contrast: colorSchemeContrast,
            reduceTransparency: reduceTransparency
        )
    }

    private var previewDescription: String {
        AppearancePreviewDescription.accessibilityLabel(
            theme: settings.panelTheme,
            surface: settings.panelSurfaceStyle,
            tint: settings.panelTint,
            tintLength: settings.panelTintLength,
            appearance: effectiveColorScheme == .dark ? .dark : .light,
            reduceTransparency: reduceTransparency
        )
    }
}

/// A corner size the miniature can draw: the stored value, or the default
/// when it is not a usable number.
enum PanelGeometryCornerSize {
    static func sanitised(_ value: Double) -> Double {
        guard value.isFinite else { return PanelCornerSize.defaultValue }
        return min(max(value, PanelCornerSize.min), PanelCornerSize.max)
    }
}
