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
        contrast == .increased ? 0.52 : 0.46
    }

    static func nonselectedThemeBoundaryLineWidth(
        for contrast: ColorSchemeContrast
    ) -> CGFloat {
        contrast == .increased ? 1 : 0.5
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        SettingsPage(
            title: "Appearance",
            subtitle: "Keep Attic calm and readable in every workspace.",
            accessibilityIdentifier: "settings-page-appearance"
        ) {
            SettingsGroup("Mode") {
                SettingsRow(
                    title: "Appearance",
                    description: "Follow your Mac, or keep Attic in Light or Dark.",
                    systemImage: "sun.max"
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
            }

            SettingsGroup("Palette") {
                VStack(alignment: .leading, spacing: 12) {
                    PanelThemeChooser(selection: $settings.panelTheme)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(
                    AppearanceSettingsPresentation.themeChooserAccessibilityIdentifier
                )
            }

            SettingsGroup("Surface") {
                SettingsRow(
                    title: "Surface",
                    description: settings.panelSurfaceStyle.detail,
                    systemImage: settings.panelSurfaceStyle.systemImage
                ) {
                    Picker("Surface", selection: $settings.panelSurfaceStyle) {
                        ForEach(PanelSurfaceStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .accessibilityLabel("Panel surface")
                    .accessibilityIdentifier("setting-panel-surface")
                }

                SettingsDivider()

                SettingsRow(
                    title: "Depth",
                    description: "A soft shade across the top of the panel.",
                    systemImage: "rectangle.tophalf.filled"
                ) {
                    Toggle("Depth", isOn: $settings.panelDepthEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Depth")
                        .accessibilityIdentifier("setting-panel-depth")
                }

                SettingsDivider()

                SettingsRow(
                    title: "Tint",
                    description: settings.panelTint.detail,
                    systemImage: "paintbrush.pointed"
                ) {
                    Picker("Tint", selection: $settings.panelTint) {
                        ForEach(PanelTintLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                    .accessibilityLabel("Panel tint")
                    .accessibilityIdentifier("setting-panel-tint")
                }
            }
        }
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

private struct PanelThemeChooser: View {
    @Binding var selection: AtticPanelTheme

    private let columns = [
        GridItem(.adaptive(minimum: 126, maximum: 176), spacing: 8, alignment: .top)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(AtticPanelTheme.allCases) { theme in
                PanelThemeChoice(
                    theme: theme,
                    isSelected: selection == theme
                ) {
                    selection = theme
                }
            }
        }
        .accessibilityLabel("Panel theme")
    }
}

private struct PanelThemeChoice: View {
    let theme: AtticPanelTheme
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var currentPalette: AtticPanelThemePalette {
        theme.palette(for: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    ThemePairPreview(
                        theme: theme,
                        contrast: colorSchemeContrast
                    )

                    Spacer(minLength: 0)

                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isSelected ? currentPalette.accentColor : Color.clear)
                        .frame(width: 16, height: 16)
                        .background(
                            isSelected
                                ? currentPalette.accentColor.opacity(0.13)
                                : Color.clear,
                            in: Circle()
                        )
                        .accessibilityHidden(true)
                }

                Text(theme.title)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(
                        AppearanceSettingsPresentation.themeTitleLineLimit,
                        reservesSpace: true
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(
                maxWidth: .infinity,
                minHeight: AppearanceSettingsPresentation.themeChoiceHeight,
                maxHeight: AppearanceSettingsPresentation.themeChoiceHeight,
                alignment: .leading
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(
                isSelected
                    ? currentPalette.accentColor.opacity(currentPalette.selectedFillOpacity)
                    : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        choiceBoundaryColor,
                        lineWidth: choiceBoundaryLineWidth
                    )
            }
        }
        .buttonStyle(.plain)
        .help(theme.detail)
        .accessibilityLabel(theme.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(theme.detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(theme.accessibilityIdentifier)
    }

    private var choiceBoundaryColor: Color {
        if isSelected {
            return currentPalette.accentColor
        }
        if colorSchemeContrast == .increased {
            return Color.primary.opacity(
                AppearanceSettingsPresentation.nonselectedThemeBoundaryOpacity(
                    for: colorSchemeContrast
                )
            )
        }
        return Color(nsColor: .separatorColor).opacity(
            AppearanceSettingsPresentation.nonselectedThemeBoundaryOpacity(
                for: colorSchemeContrast
            )
        )
    }

    private var choiceBoundaryLineWidth: CGFloat {
        if isSelected {
            return colorSchemeContrast == .increased ? 2 : 1.5
        }
        return AppearanceSettingsPresentation.nonselectedThemeBoundaryLineWidth(
            for: colorSchemeContrast
        )
    }
}

private struct ThemePairPreview: View {
    let theme: AtticPanelTheme
    let contrast: ColorSchemeContrast

    var body: some View {
        HStack(spacing: 3) {
            ThemeMiniPanel(
                palette: theme.palette(
                    for: AtticPanelThemeAppearance.light,
                    contrast: contrast
                )
            )
            ThemeMiniPanel(
                palette: theme.palette(
                    for: AtticPanelThemeAppearance.dark,
                    contrast: contrast
                )
            )
        }
        .accessibilityHidden(true)
    }
}

private struct ThemeMiniPanel: View {
    let palette: AtticPanelThemePalette

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(palette.opaqueSurfaceColor)
            .frame(width: 27, height: 22)
            .overlay(alignment: .bottomLeading) {
                Capsule()
                    .fill(palette.accentColor)
                    .frame(width: 12, height: 2.5)
                    .padding(4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        palette.edgeTint.swiftUIColor(opacity: 0.52),
                        lineWidth: 0.75
                    )
            }
    }
}
