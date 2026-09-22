import SwiftUI

/// The palette chooser: one tile per palette showing its Light and Dark
/// surfaces side by side with the accent, named underneath.
struct PaletteChooser: View {
    @Binding var selection: AtticPanelTheme

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 8, alignment: .top)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(AtticPanelTheme.allCases) { theme in
                PaletteTile(theme: theme, isSelected: selection == theme) {
                    selection = theme
                }
            }
        }
        .accessibilityLabel("Panel palette")
    }
}

private struct PaletteTile: View {
    let theme: AtticPanelTheme
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var accent: Color {
        theme.palette(for: colorScheme, contrast: colorSchemeContrast).accentColor
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    PaletteSwatch(palette: theme.palette(for: AtticPanelThemeAppearance.light, contrast: colorSchemeContrast),
                                  contrast: colorSchemeContrast)
                    PaletteSwatch(palette: theme.palette(for: AtticPanelThemeAppearance.dark, contrast: colorSchemeContrast),
                                  contrast: colorSchemeContrast)
                }
                .accessibilityHidden(true)

                Text(theme.title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(AppearanceSettingsPresentation.themeTitleLineLimit, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: AppearanceSettingsPresentation.themeChoiceHeight, alignment: .topLeading)
            .background(
                isSelected ? accent.opacity(0.10) : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: SettingsDesign.tileCornerRadius, style: .continuous)
            )
            .settingsTileSelection(isSelected: isSelected, accent: accent, contrast: colorSchemeContrast)
            .contentShape(RoundedRectangle(cornerRadius: SettingsDesign.tileCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(theme.detail)
        .accessibilityLabel(theme.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(theme.detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityRemoveTraits(isSelected ? [] : .isSelected)
        .accessibilityIdentifier(theme.accessibilityIdentifier)
    }
}

/// One mode of a palette: its solid surface, a text line and the accent.
private struct PaletteSwatch: View {
    let palette: AtticPanelThemePalette
    let contrast: ColorSchemeContrast

    var body: some View {
        Squircle(cornerRadius: 9, exponent: AtticStyle.panelSquircleExponent)
            .fill(palette.opaqueSurfaceColor)
            .frame(width: 40, height: 30)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Capsule()
                        .fill(palette.primaryForegroundColor.opacity(0.8))
                        .frame(width: 18, height: 2.5)
                    Capsule()
                        .fill(palette.secondaryForegroundColor.opacity(0.45))
                        .frame(width: 12, height: 2.5)
                }
                .padding(7)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(palette.accentColor)
                    .frame(width: 7, height: 7)
                    .padding(6)
            }
            .overlay {
                Squircle(cornerRadius: 9, exponent: AtticStyle.panelSquircleExponent)
                    .stroke(palette.edgeTint.swiftUIColor(opacity: contrast == .increased ? 0.7 : 0.45), lineWidth: 0.75)
            }
    }
}

/// Solid · Glass · Frosted as three tiles, each with a small picture of what
/// the surface does to what is behind it, a title and one line.
struct SurfaceChooser: View {
    @Binding var selection: PanelSurfaceStyle
    let palette: AtticPanelThemePalette
    let appearance: AtticPanelThemeAppearance
    let accent: Color
    /// The solved readable foundation for the glass surfaces of this
    /// palette and appearance, so the hint shows the real coverage.
    let glassFoundation: Double

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(PanelSurfaceStyle.allCases) { style in
                let isSelected = selection == style
                Button {
                    selection = style
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        SurfaceHint(style: style, palette: palette, appearance: appearance,
                                    glassFoundation: glassFoundation)
                            .accessibilityHidden(true)
                        Text(style.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(style.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(
                        isSelected ? accent.opacity(0.10) : Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: SettingsDesign.tileCornerRadius, style: .continuous)
                    )
                    .settingsTileSelection(isSelected: isSelected, accent: accent, contrast: colorSchemeContrast)
                    .contentShape(RoundedRectangle(cornerRadius: SettingsDesign.tileCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(style.detail)
                .accessibilityLabel(style.title)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityHint(style.detail)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityRemoveTraits(isSelected ? [] : .isSelected)
                .accessibilityIdentifier(style.accessibilityIdentifier)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel surface")
        .accessibilityValue(selection.title)
        .accessibilityIdentifier("setting-panel-surface")
    }
}

/// A tiny desktop with the surface over it: Solid hides it, Glass shows it
/// through the readable foundation, Frosted blurs it under the palette wash.
private struct SurfaceHint: View {
    let style: PanelSurfaceStyle
    let palette: AtticPanelThemePalette
    let appearance: AtticPanelThemeAppearance
    let glassFoundation: Double

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { index in
                    Rectangle().fill(SurfaceHint.stripe(index, dark: appearance == .dark))
                }
            }
            .blur(radius: style == .frosted ? 3 : 0)
            Squircle(cornerRadius: 14, exponent: AtticStyle.panelSquircleExponent)
                .fill(palette.opaqueSurfaceColor.opacity(Self.foundation(for: style, glassFoundation: glassFoundation)))
                .overlay {
                    if Self.wash(for: style) > 0 {
                        Squircle(cornerRadius: 14, exponent: AtticStyle.panelSquircleExponent)
                            .fill(palette.surfaceTint.swiftUIColor(opacity: Self.wash(for: style)))
                    }
                }
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(palette.primaryForegroundColor.opacity(0.85)).frame(width: 20, height: 2.5)
                        Capsule().fill(palette.secondaryForegroundColor.opacity(0.5)).frame(width: 13, height: 2.5)
                    }
                    .padding(8)
                }
                .overlay {
                    Squircle(cornerRadius: 14, exponent: AtticStyle.panelSquircleExponent)
                        .stroke(palette.edgeTint.swiftUIColor(opacity: 0.4), lineWidth: 0.75)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// How much of the surface colour covers the little desktop: all of it
    /// for Solid, the solved readable foundation for Glass and Frosted.
    static func foundation(for style: PanelSurfaceStyle, glassFoundation: Double) -> Double {
        style == .solid ? 1 : min(max(glassFoundation, 0), 1)
    }

    /// Frosted adds its palette wash; the others carry none.
    static func wash(for style: PanelSurfaceStyle) -> Double {
        style == .frosted ? 0.18 : 0
    }

    private static func stripe(_ index: Int, dark: Bool) -> Color {
        let colors: [Color] = [
            Color(red: 0.98, green: 0.62, blue: 0.36),
            Color(red: 0.36, green: 0.62, blue: 0.98),
            Color(red: 0.62, green: 0.86, blue: 0.5),
            Color(red: 0.86, green: 0.5, blue: 0.86),
            Color(red: 0.98, green: 0.85, blue: 0.4),
            Color(red: 0.4, green: 0.85, blue: 0.85)
        ]
        return colors[index % colors.count].opacity(dark ? 0.75 : 0.9)
    }
}

/// Off · Subtle · Vivid · Bold as four pills, each showing the accent wash at
/// the strength it really gets on the current palette, surface and Depth
/// state; a clamped cell therefore shows the faintness it will have.
struct TintChooser: View {
    @Binding var selection: PanelTintLevel
    let treatment: AtticPanelSurfaceTreatment
    let accent: Color

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PanelTintLevel.allCases) { level in
                let isSelected = selection == level
                Button {
                    selection = level
                } label: {
                    VStack(spacing: 6) {
                        TintSample(treatment: treatment, level: level)
                            .accessibilityHidden(true)
                        Text(level.title)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        isSelected ? accent.opacity(0.10) : Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: SettingsDesign.tileCornerRadius, style: .continuous)
                    )
                    .settingsTileSelection(isSelected: isSelected, accent: accent, contrast: colorSchemeContrast)
                    .contentShape(RoundedRectangle(cornerRadius: SettingsDesign.tileCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(level.detail)
                .accessibilityLabel(level.title)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityHint(level.detail)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityRemoveTraits(isSelected ? [] : .isSelected)
                .accessibilityIdentifier(level.accessibilityIdentifier)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel tint")
        .accessibilityValue(selection.title)
        .accessibilityIdentifier("setting-panel-tint")
    }
}

/// The top of the panel at one tint step: the surface's own composite over
/// the worst-case backdrop, the crown if Depth is on, then the wash at the
/// calibrated opacity, fading over the sample's height.
private struct TintSample: View {
    let treatment: AtticPanelSurfaceTreatment
    let level: PanelTintLevel

    var body: some View {
        let shape = Squircle(cornerRadius: 12, exponent: AtticStyle.panelSquircleExponent)
        let sample = AtticPanelSurfaceTreatment(
            theme: treatment.theme, kind: treatment.kind, palette: treatment.palette,
            appearance: treatment.appearance, usesSystemOpaqueSurface: treatment.usesSystemOpaqueSurface,
            depth: treatment.depth, tint: level
        )
        let backdrop = PanelTintCalibration.worstCaseBackdrop(for: treatment.appearance)
        ZStack {
            shape.fill(sample.compositedSurface(over: backdrop, location: 1).swiftUIColor())
            if sample.depth {
                PanelDepthCrownView(appearance: sample.appearance, shape: shape)
            }
            if sample.tintTopOpacity > 0 {
                let wash = sample.washColor
                LinearGradient(stops: [
                    .init(color: wash.swiftUIColor(opacity: sample.tintTopOpacity), location: 0),
                    .init(color: wash.swiftUIColor(opacity: 0), location: PanelTintCalibration.fadeEnd),
                    .init(color: wash.swiftUIColor(opacity: 0), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .clipShape(shape)
            }
            shape.stroke(treatment.palette.edgeTint.swiftUIColor(opacity: 0.4), lineWidth: 0.75)
        }
        .frame(height: 34)
    }
}
