import AppKit
import SwiftUI

enum AppearanceSettingsPresentation {
    static let themeChooserAccessibilityIdentifier = "setting-panel-theme"
    static let themeChoiceHeight: CGFloat = 74
    static let themeTitleLineLimit = 2

    static var orderedThemeAccessibilityIdentifiers: [String] {
        AtticPanelTheme.allCases.map(\.accessibilityIdentifier)
    }

    static func nonselectedThemeBoundaryOpacity(
        for contrast: ColorSchemeContrast
    ) -> Double {
        SettingsDesign.tileBoundaryOpacity(for: contrast)
    }

    static func nonselectedThemeBoundaryLineWidth(
        for contrast: ColorSchemeContrast
    ) -> CGFloat {
        SettingsDesign.tileBoundaryLineWidth(for: contrast)
    }

    static let depthDescription = "A soft shade across the top of the panel."

    /// The one line the pane shows when the readability floor, not the
    /// chosen step, sets the wash for this palette, surface and Depth state;
    /// nil when the step reaches its full strength.
    static func tintFloorNote(for treatment: AtticPanelSurfaceTreatment) -> String? {
        guard treatment.tint != .off,
              let cell = PanelTintCalibration.cell(
                  theme: treatment.theme, appearance: treatment.appearance,
                  kind: treatment.kind, depth: treatment.depth, level: treatment.tint
              ),
              cell.isClamped else { return nil }
        return treatment.depth
            ? "Tint is kept faint here so text stays readable."
            : "Tint is kept faint on this surface so text stays readable. Turn on Depth for the full range."
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        SettingsPage(
            title: "Appearance",
            subtitle: "How the panel looks on your desktop.",
            accessibilityIdentifier: "settings-page-appearance"
        ) {
            Section {
                AppearancePreviewCard(settings: settings)
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))

                SettingsRow(
                    title: "Mode",
                    description: "Follow your Mac, or keep Attic in Light or Dark.",
                    systemImage: "circle.lefthalf.filled",
                    tint: .purple
                ) {
                    Picker("Appearance", selection: appearanceSelection) {
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
            } footer: {
                if reduceTransparency {
                    SettingsFootnote("Reduce Transparency is on, so the panel is drawn solid. Your Surface choice is kept.")
                }
            }

            Section {
                PaletteChooser(selection: $settings.panelTheme)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AppearanceSettingsPresentation.themeChooserAccessibilityIdentifier)
            } header: {
                Text("Palette")
            } footer: {
                SettingsFootnote("Each palette has a Light and a Dark pair. Original is Attic's neutral look.")
            }

            Section {
                SurfaceChooser(
                    selection: $settings.panelSurfaceStyle,
                    palette: palette,
                    appearance: appearance,
                    accent: accent,
                    glassFoundation: settings.panelTheme.surfaceTreatment(
                        appearance: appearance, surface: .glass, depth: false, tint: .off,
                        reduceTransparency: false
                    ).foundationOpacity
                )

                SettingsRow(
                    title: "Depth",
                    description: AppearanceSettingsPresentation.depthDescription,
                    systemImage: "rectangle.tophalf.filled",
                    tint: .indigo
                ) {
                    Toggle("Depth", isOn: $settings.panelDepthEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help("Shade the top of the panel")
                        .accessibilityLabel("Depth")
                        .accessibilityIdentifier("setting-panel-depth")
                }

                VStack(alignment: .leading, spacing: 10) {
                    SettingsRowLabel(
                        title: "Tint",
                        description: settings.panelTint.detail,
                        systemImage: "paintbrush.pointed.fill",
                        tint: .pink
                    )
                    TintChooser(selection: $settings.panelTint, treatment: treatment, accent: accent)
                }
            } header: {
                Text("Surface")
            } footer: {
                if let note = AppearanceSettingsPresentation.tintFloorNote(for: treatment) {
                    SettingsFootnote(note)
                }
            }
        }
    }

    private var effectiveColorScheme: ColorScheme {
        switch settings.appearance {
        case .light: .light
        case .dark: .dark
        case .system: colorScheme
        }
    }

    private var appearance: AtticPanelThemeAppearance {
        effectiveColorScheme == .dark ? .dark : .light
    }

    private var palette: AtticPanelThemePalette {
        settings.panelTheme.palette(for: effectiveColorScheme, contrast: colorSchemeContrast)
    }

    private var treatment: AtticPanelSurfaceTreatment {
        settings.panelSurfaceTreatment(
            colorScheme: effectiveColorScheme,
            contrast: colorSchemeContrast,
            reduceTransparency: reduceTransparency
        )
    }

    private var accent: Color {
        settings.panelTheme.usesSystemAccent
            ? Color.accentColor
            : settings.panelTheme.palette(for: colorScheme, contrast: colorSchemeContrast).accentColor
    }

    private var appearanceSelection: Binding<AppearancePreference> {
        Binding {
            settings.appearance
        } set: { preference in
            // Native segmented Picker can deliver its binding callback
            // during a SwiftUI view update. Publish after that callback.
            DispatchQueue.main.async {
                guard settings.appearance != preference else { return }
                settings.appearance = preference
            }
        }
    }
}
