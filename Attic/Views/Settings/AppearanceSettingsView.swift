import AppKit
import SwiftUI

enum AppearanceSettingsPresentation {
    static let themeChooserAccessibilityIdentifier = "setting-panel-theme"
    static let themeChoiceHeight: CGFloat = 74
    static let themeTitleLineLimit = 2

    static func gradientColorHex(from color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return AtticThemeColor(red: rgb.redComponent, green: rgb.greenComponent,
                               blue: rgb.blueComponent).hexString
    }

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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        SettingsPage(
            title: "Appearance",
            subtitle: "Keep Attic calm and readable in every workspace.",
            accessibilityIdentifier: "settings-page-appearance"
        ) {
            SettingsGroup("App appearance") {
                SettingsRow(
                    title: "Color scheme",
                    description: "Follow your Mac or keep Attic in Light or Dark appearance.",
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

            SettingsGroup("Panel theme") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 13) {
                        Image(systemName: "swatchpalette")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.045), in: Circle())
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Adaptive palette")
                                .font(.system(size: 13, weight: .medium))

                            Text("Choose a paired Light and Dark palette. Original keeps Attic's current look.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

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

            SettingsGroup("Panel surface") {
                SettingsRow(
                    title: "Translucent panel",
                    description: "Let the desktop show naturally through Attic's surface.",
                    systemImage: "circle.lefthalf.filled"
                ) {
                    Toggle("Use a translucent panel", isOn: $settings.isTranslucent)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help("Use a translucent surface in the Attic panel")
                        .accessibilityLabel("Use a translucent panel")
                        .accessibilityIdentifier("setting-translucency")
                }

                SettingsDivider()

                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .center, spacing: 13) {
                        Image(systemName: "drop.halffull")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.045), in: Circle())
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Glass character")
                                .font(.system(size: 13, weight: .medium))

                            Text(glassDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if settings.isTranslucent {
                        Picker("Glass style", selection: resolvedGlassStyle) {
                            ForEach(PanelGlassStyle.allCases.filter { $0 != .clear || isClearAvailable }) { style in
                                Text(style.title)
                                    .tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        .accessibilityLabel("Panel glass style")
                        .accessibilityIdentifier("setting-glass-style")

                        if !isClearAvailable {
                            Text(settings.panelGlassStyle == .clear
                                 ? "Frosted is active here. Your Clear choice returns with Original in Dark appearance."
                                 : "Clear is available with Original in Dark appearance.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("setting-clear-availability")
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsGroup("Panel gradient") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gradient coverage")
                            .font(.system(size: 13, weight: .medium))
                        Text("Choose how far the color extends. At 0%, the decorative gradient is off; readability stays on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Slider(value: $settings.panelGradientCoverage, in: 0...1, step: 0.01)
                            .accessibilityLabel("Panel gradient coverage")
                            .accessibilityValue(settings.panelGradientCoverage.formatted(.percent.precision(.fractionLength(0))))
                            .accessibilityIdentifier("setting-panel-gradient-coverage")
                        Text(settings.panelGradientCoverage, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                    .disabled(usesOriginalClear)

                    Divider()

                    HStack(spacing: 12) {
                        ColorPicker("Gradient color", selection: gradientColor, supportsOpacity: false)
                            .disabled(usesOriginalClear)
                            .accessibilityLabel("Panel gradient color")
                            .accessibilityIdentifier("setting-panel-gradient-color")
                        Button("Use theme color") { settings.panelGradientColorHex = "" }
                            .disabled(settings.panelGradientColorHex.isEmpty || usesOriginalClear)
                            .accessibilityLabel("Reset gradient to theme color")
                            .accessibilityIdentifier("setting-panel-gradient-color-reset")
                    }

                    Text(usesOriginalClear
                         ? "Original Clear keeps its signature lighting. Choose Frosted or Glassmorphism to customize the gradient."
                         : settings.panelGradientColorHex.isEmpty
                         ? "Using the theme's adaptive color."
                         : "Custom color: #\(settings.panelGradientColorHex). Tint adapts to keep text readable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private var gradientColor: Binding<Color> {
        Binding {
            let color = AtticThemeColor(hex: settings.panelGradientColorHex)
                ?? settings.panelTheme.palette(for: effectiveColorScheme, contrast: colorSchemeContrast).surfaceTint
            return color.swiftUIColor()
        } set: { color in
            guard let hex = AppearanceSettingsPresentation.gradientColorHex(from: color) else { return }
            settings.panelGradientColorHex = hex
        }
    }

    private var effectiveColorScheme: ColorScheme {
        switch settings.appearance {
        case .light: .light
        case .dark: .dark
        case .system: colorScheme
        }
    }

    private var isClearAvailable: Bool {
        PanelGlassStyle.clear.resolved(for: settings.panelTheme, colorScheme: effectiveColorScheme) == .clear
    }

    private var usesOriginalClear: Bool {
        settings.isTranslucent && !reduceTransparency && resolvedGlassStyle.wrappedValue == .clear
    }

    private var resolvedGlassStyle: Binding<PanelGlassStyle> {
        Binding {
            settings.panelGlassStyle.resolved(for: settings.panelTheme, colorScheme: effectiveColorScheme)
        } set: { style in
            guard style != .clear || isClearAvailable else { return }
            DispatchQueue.main.async {
                guard style != .clear || isClearAvailable else { return }
                guard settings.panelGlassStyle != style else { return }
                settings.panelGlassStyle = style
            }
        }
    }

    private var glassDescription: String {
        settings.isTranslucent
            ? settings.panelGlassStyle.resolved(for: settings.panelTheme, colorScheme: effectiveColorScheme).detail
            : "The solid surface is active while translucency is off."
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
