import Foundation
import SwiftUI

enum AtticPanelTheme: String, CaseIterable, Identifiable, Sendable {
    // These raw values are persisted. Keep them explicit and stable.
    case original = "original"
    case midnightCobalt = "midnightCobalt"
    case porcelainVapor = "porcelainVapor"
    case smokedUmber = "smokedUmber"
    case electricBlue = "electricBlue"
    case seaGlass = "seaGlass"
    case amethyst = "amethyst"

    static let defaultTheme: AtticPanelTheme = .original

    var id: String { rawValue }

    var accessibilityIdentifier: String {
        "setting-panel-theme-\(rawValue)"
    }

    var usesSystemAccent: Bool { self == .original }

    var title: String {
        switch self {
        case .original: return "Original"
        case .midnightCobalt: return "Midnight Cobalt"
        case .porcelainVapor: return "Porcelain Vapor"
        case .smokedUmber: return "Smoked Umber"
        case .electricBlue: return "Electric Blue"
        case .seaGlass: return "Sea Glass"
        case .amethyst: return "Amethyst"
        }
    }

    var detail: String {
        switch self {
        case .original:
            return "Attic's neutral system palette."
        case .midnightCobalt:
            return "Deep navy glass with a luminous cobalt edge."
        case .porcelainVapor:
            return "Quiet pearl and graphite with an icy highlight."
        case .smokedUmber:
            return "Warm graphite glass with restrained bronze light."
        case .electricBlue:
            return "Neutral glass with a crisp electric-blue accent."
        case .seaGlass:
            return "Soft mineral glass with a calm mint accent."
        case .amethyst:
            return "Ink-black and pearl glass with a violet accent."
        }
    }

    func palette(for colorScheme: ColorScheme) -> AtticPanelThemePalette {
        palette(for: colorScheme, contrast: .standard)
    }

    func palette(
        for colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> AtticPanelThemePalette {
        palette(
            for: colorScheme == .dark
                ? AtticPanelThemeAppearance.dark
                : AtticPanelThemeAppearance.light,
            contrast: contrast
        )
    }

    func palette(for appearance: AtticPanelThemeAppearance) -> AtticPanelThemePalette {
        palette(for: appearance, contrast: .standard)
    }

    func palette(
        for appearance: AtticPanelThemeAppearance,
        contrast: ColorSchemeContrast
    ) -> AtticPanelThemePalette {
        let palette = standardPalette(for: appearance)
        switch contrast {
        case .increased:
            return palette.increasingContrast(for: appearance)
        default:
            return palette
        }
    }

    private func standardPalette(
        for appearance: AtticPanelThemeAppearance
    ) -> AtticPanelThemePalette {
        switch (self, appearance) {
        case (.original, .dark):
            return .init(
                accent: .init(red: 0.116, green: 0.478, blue: 0.980),
                opaqueSurface: .init(red: 0.075, green: 0.075, blue: 0.082),
                surfaceTint: .init(red: 0, green: 0, blue: 0),
                edgeTint: .init(red: 1, green: 1, blue: 1),
                clearTintOpacity: 0.06,
                frostedTintOpacity: 0.22,
                glassmorphismTintOpacity: 0,
                selectedFillOpacity: 0.15,
                selectedStrokeOpacity: 0.22
            )
        case (.original, .light):
            return .init(
                // Match the existing AccentColor asset in both schemes so
                // choosing (or defaulting to) Original is visually inert.
                accent: .init(red: 0.116, green: 0.478, blue: 0.980),
                opaqueSurface: .init(red: 0.965, green: 0.965, blue: 0.975),
                surfaceTint: .init(red: 1, green: 1, blue: 1),
                edgeTint: .init(red: 0, green: 0, blue: 0),
                clearTintOpacity: 0.08,
                frostedTintOpacity: 0.24,
                glassmorphismTintOpacity: 0,
                selectedFillOpacity: 0.12,
                selectedStrokeOpacity: 0.20
            )
        case (.midnightCobalt, .dark):
            return .init(
                accent: .init(red: 0.471, green: 0.569, blue: 1.000),
                opaqueSurface: .init(red: 0.027, green: 0.067, blue: 0.153),
                surfaceTint: .init(red: 0.157, green: 0.247, blue: 0.541),
                edgeTint: .init(red: 0.490, green: 0.612, blue: 1.000),
                clearTintOpacity: 0.065,
                frostedTintOpacity: 0.145,
                glassmorphismTintOpacity: 0.045,
                selectedFillOpacity: 0.17,
                selectedStrokeOpacity: 0.42
            )
        case (.midnightCobalt, .light):
            return .init(
                accent: .init(red: 0.153, green: 0.298, blue: 0.620),
                opaqueSurface: .init(red: 0.933, green: 0.953, blue: 0.988),
                surfaceTint: .init(red: 0.302, green: 0.412, blue: 0.698),
                edgeTint: .init(red: 0.176, green: 0.345, blue: 0.722),
                clearTintOpacity: 0.045,
                frostedTintOpacity: 0.105,
                glassmorphismTintOpacity: 0.032,
                selectedFillOpacity: 0.12,
                selectedStrokeOpacity: 0.34
            )
        case (.porcelainVapor, .dark):
            return .init(
                accent: .init(red: 0.659, green: 0.773, blue: 0.847),
                opaqueSurface: .init(red: 0.102, green: 0.118, blue: 0.141),
                surfaceTint: .init(red: 0.533, green: 0.604, blue: 0.651),
                edgeTint: .init(red: 0.718, green: 0.800, blue: 0.847),
                clearTintOpacity: 0.030,
                frostedTintOpacity: 0.075,
                glassmorphismTintOpacity: 0.018,
                selectedFillOpacity: 0.12,
                selectedStrokeOpacity: 0.30
            )
        case (.porcelainVapor, .light):
            return .init(
                accent: .init(red: 0.282, green: 0.404, blue: 0.471),
                opaqueSurface: .init(red: 0.965, green: 0.965, blue: 0.957),
                surfaceTint: .init(red: 0.718, green: 0.776, blue: 0.808),
                edgeTint: .init(red: 0.392, green: 0.494, blue: 0.545),
                clearTintOpacity: 0.030,
                frostedTintOpacity: 0.070,
                glassmorphismTintOpacity: 0.018,
                selectedFillOpacity: 0.09,
                selectedStrokeOpacity: 0.28
            )
        case (.smokedUmber, .dark):
            return .init(
                // Desaturated bronze stays separate from semantic orange
                // priority/warning colors while retaining the reference's warmth.
                accent: .init(red: 0.816, green: 0.716, blue: 0.545),
                opaqueSurface: .init(red: 0.090, green: 0.078, blue: 0.067),
                surfaceTint: .init(red: 0.420, green: 0.329, blue: 0.259),
                edgeTint: .init(red: 0.827, green: 0.694, blue: 0.553),
                clearTintOpacity: 0.050,
                frostedTintOpacity: 0.115,
                glassmorphismTintOpacity: 0.035,
                selectedFillOpacity: 0.15,
                selectedStrokeOpacity: 0.36
            )
        case (.smokedUmber, .light):
            return .init(
                accent: .init(red: 0.478, green: 0.374, blue: 0.196),
                opaqueSurface: .init(red: 0.961, green: 0.933, blue: 0.906),
                surfaceTint: .init(red: 0.663, green: 0.518, blue: 0.400),
                edgeTint: .init(red: 0.510, green: 0.349, blue: 0.231),
                clearTintOpacity: 0.040,
                frostedTintOpacity: 0.095,
                glassmorphismTintOpacity: 0.028,
                selectedFillOpacity: 0.10,
                selectedStrokeOpacity: 0.30
            )
        case (.electricBlue, .dark):
            return .init(
                accent: .init(red: 0.153, green: 0.545, blue: 1.000),
                opaqueSurface: .init(red: 0.067, green: 0.075, blue: 0.090),
                surfaceTint: .init(red: 0.086, green: 0.459, blue: 0.910),
                edgeTint: .init(red: 0.231, green: 0.600, blue: 1.000),
                clearTintOpacity: 0.040,
                frostedTintOpacity: 0.085,
                glassmorphismTintOpacity: 0.022,
                selectedFillOpacity: 0.16,
                selectedStrokeOpacity: 0.40
            )
        case (.electricBlue, .light):
            return .init(
                accent: .init(red: 0.043, green: 0.392, blue: 0.847),
                opaqueSurface: .init(red: 0.980, green: 0.984, blue: 0.992),
                surfaceTint: .init(red: 0.227, green: 0.561, blue: 0.941),
                edgeTint: .init(red: 0.067, green: 0.427, blue: 0.863),
                clearTintOpacity: 0.032,
                frostedTintOpacity: 0.072,
                glassmorphismTintOpacity: 0.018,
                selectedFillOpacity: 0.10,
                selectedStrokeOpacity: 0.32
            )
        case (.seaGlass, .dark):
            return .init(
                accent: .init(red: 0.392, green: 0.804, blue: 0.722),
                opaqueSurface: .init(red: 0.063, green: 0.110, blue: 0.110),
                surfaceTint: .init(red: 0.239, green: 0.561, blue: 0.490),
                edgeTint: .init(red: 0.459, green: 0.843, blue: 0.765),
                clearTintOpacity: 0.045,
                frostedTintOpacity: 0.095,
                glassmorphismTintOpacity: 0.028,
                selectedFillOpacity: 0.15,
                selectedStrokeOpacity: 0.37
            )
        case (.seaGlass, .light):
            return .init(
                accent: .init(red: 0.149, green: 0.475, blue: 0.408),
                opaqueSurface: .init(red: 0.949, green: 0.965, blue: 0.945),
                surfaceTint: .init(red: 0.510, green: 0.718, blue: 0.655),
                edgeTint: .init(red: 0.184, green: 0.502, blue: 0.435),
                clearTintOpacity: 0.038,
                frostedTintOpacity: 0.082,
                glassmorphismTintOpacity: 0.024,
                selectedFillOpacity: 0.10,
                selectedStrokeOpacity: 0.30
            )
        case (.amethyst, .dark):
            return .init(
                accent: .init(red: 0.667, green: 0.518, blue: 0.961),
                opaqueSurface: .init(red: 0.094, green: 0.082, blue: 0.133),
                surfaceTint: .init(red: 0.439, green: 0.322, blue: 0.659),
                edgeTint: .init(red: 0.729, green: 0.588, blue: 1.000),
                clearTintOpacity: 0.045,
                frostedTintOpacity: 0.100,
                glassmorphismTintOpacity: 0.030,
                selectedFillOpacity: 0.15,
                selectedStrokeOpacity: 0.38
            )
        case (.amethyst, .light):
            return .init(
                accent: .init(red: 0.420, green: 0.282, blue: 0.706),
                opaqueSurface: .init(red: 0.969, green: 0.953, blue: 0.984),
                surfaceTint: .init(red: 0.667, green: 0.576, blue: 0.820),
                edgeTint: .init(red: 0.459, green: 0.325, blue: 0.737),
                clearTintOpacity: 0.038,
                frostedTintOpacity: 0.085,
                glassmorphismTintOpacity: 0.024,
                selectedFillOpacity: 0.10,
                selectedStrokeOpacity: 0.30
            )
        }
    }

    func surfaceTreatment(
        colorScheme: ColorScheme,
        glassStyle: PanelGlassStyle,
        isTranslucent: Bool,
        reduceTransparency: Bool
    ) -> AtticPanelSurfaceTreatment {
        surfaceTreatment(
            colorScheme: colorScheme,
            contrast: .standard,
            glassStyle: glassStyle,
            isTranslucent: isTranslucent,
            reduceTransparency: reduceTransparency
        )
    }

    func surfaceTreatment(
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast,
        glassStyle: PanelGlassStyle,
        isTranslucent: Bool,
        reduceTransparency: Bool
    ) -> AtticPanelSurfaceTreatment {
        surfaceTreatment(
            appearance: colorScheme == .dark
                ? AtticPanelThemeAppearance.dark
                : AtticPanelThemeAppearance.light,
            contrast: contrast,
            glassStyle: glassStyle,
            isTranslucent: isTranslucent,
            reduceTransparency: reduceTransparency
        )
    }

    func surfaceTreatment(
        appearance: AtticPanelThemeAppearance,
        glassStyle: PanelGlassStyle,
        isTranslucent: Bool,
        reduceTransparency: Bool
    ) -> AtticPanelSurfaceTreatment {
        surfaceTreatment(
            appearance: appearance,
            contrast: .standard,
            glassStyle: glassStyle,
            isTranslucent: isTranslucent,
            reduceTransparency: reduceTransparency
        )
    }

    func surfaceTreatment(
        appearance: AtticPanelThemeAppearance,
        contrast: ColorSchemeContrast,
        glassStyle: PanelGlassStyle,
        isTranslucent: Bool,
        reduceTransparency: Bool
    ) -> AtticPanelSurfaceTreatment {
        let palette = palette(for: appearance, contrast: contrast)
        let kind: AtticPanelSurfaceTreatment.Kind

        if !isTranslucent || reduceTransparency {
            kind = .opaque
        } else {
            switch glassStyle {
            case .clear: kind = .clearGlass
            case .frosted: kind = .frostedGlass
            case .glassmorphism: kind = .glassmorphism
            }
        }

        return AtticPanelSurfaceTreatment(
            kind: kind,
            palette: palette,
            usesSystemOpaqueSurface: self == .original
        )
    }
}

enum AtticPanelThemeAppearance: String, CaseIterable, Sendable {
    case light
    case dark
}

struct AtticThemeColor: Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var isValid: Bool {
        red.isFinite && green.isFinite && blue.isFinite
            && (0...1).contains(red)
            && (0...1).contains(green)
            && (0...1).contains(blue)
    }

    func swiftUIColor(opacity: Double = 1) -> Color {
        Color(
            red: red,
            green: green,
            blue: blue,
            opacity: min(max(opacity, 0), 1)
        )
    }

    var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return (0.2126 * linear(red))
            + (0.7152 * linear(green))
            + (0.0722 * linear(blue))
    }

    func contrastRatio(with other: AtticThemeColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func mixed(with other: AtticThemeColor, amount: Double) -> AtticThemeColor {
        let amount = min(max(amount, 0), 1)
        return AtticThemeColor(
            red: red + ((other.red - red) * amount),
            green: green + ((other.green - green) * amount),
            blue: blue + ((other.blue - blue) * amount)
        )
    }
}

struct AtticPanelThemePalette: Equatable, Sendable {
    let accent: AtticThemeColor
    let opaqueSurface: AtticThemeColor
    let surfaceTint: AtticThemeColor
    let edgeTint: AtticThemeColor
    let clearTintOpacity: Double
    let frostedTintOpacity: Double
    let glassmorphismTintOpacity: Double
    let selectedFillOpacity: Double
    let selectedStrokeOpacity: Double

    var isValid: Bool {
        [accent, opaqueSurface, surfaceTint, edgeTint].allSatisfy(\.isValid)
            && [
                clearTintOpacity,
                frostedTintOpacity,
                glassmorphismTintOpacity,
                selectedFillOpacity,
                selectedStrokeOpacity
            ].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    var accentColor: Color { accent.swiftUIColor() }
    var opaqueSurfaceColor: Color { opaqueSurface.swiftUIColor() }

    fileprivate func increasingContrast(
        for appearance: AtticPanelThemeAppearance
    ) -> AtticPanelThemePalette {
        // Increased Contrast should reinforce local edges and selected controls,
        // not darken the panel or shift the theme's semantic accent.
        let edgeTarget: AtticThemeColor = appearance == .dark
            ? .init(red: 1, green: 1, blue: 1)
            : .init(red: 0, green: 0, blue: 0)

        return AtticPanelThemePalette(
            accent: accent,
            opaqueSurface: opaqueSurface,
            surfaceTint: surfaceTint,
            edgeTint: edgeTint.mixed(with: edgeTarget, amount: 0.14),
            clearTintOpacity: clearTintOpacity,
            frostedTintOpacity: frostedTintOpacity,
            glassmorphismTintOpacity: glassmorphismTintOpacity,
            selectedFillOpacity: min(selectedFillOpacity + 0.04, 1),
            selectedStrokeOpacity: min(selectedStrokeOpacity + 0.14, 1)
        )
    }
}

struct AtticPanelSurfaceTreatment: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case opaque
        case clearGlass
        case frostedGlass
        case glassmorphism
    }

    let kind: Kind
    let palette: AtticPanelThemePalette
    let usesSystemOpaqueSurface: Bool

    var tintOpacity: Double {
        switch kind {
        // Opaque surfaces are filled with `opaqueSurface`; they are never a
        // full-strength tint overlay. Keeping this at zero makes accidental
        // overlay use harmless and keeps style choices irrelevant in opaque
        // and Reduce Transparency states.
        case .opaque: 0
        case .clearGlass: palette.clearTintOpacity
        case .frostedGlass: palette.frostedTintOpacity
        case .glassmorphism: palette.glassmorphismTintOpacity
        }
    }

    func surfaceEdgeOpacity(for contrast: ColorSchemeContrast) -> Double {
        let standardOpacity: Double
        let increasedContrastAdjustment: Double

        if usesSystemOpaqueSurface {
            standardOpacity = kind == .glassmorphism ? 0.055 : 0.11
            increasedContrastAdjustment = 0.10
        } else {
            switch kind {
            case .opaque: standardOpacity = 0.18
            case .clearGlass: standardOpacity = 0.22
            case .frostedGlass: standardOpacity = 0.20
            case .glassmorphism: standardOpacity = 0.17
            }
            increasedContrastAdjustment = 0.14
        }

        return contrast == .increased
            ? min(standardOpacity + increasedContrastAdjustment, 1)
            : standardOpacity
    }

    func surfaceEdgeLineWidth(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 1 : 0.75
    }
}

private struct AtticPanelThemePaletteKey: EnvironmentKey {
    static let defaultValue = AtticPanelTheme.original.palette(
        for: AtticPanelThemeAppearance.light
    )
}

private struct AtticPanelUsesSystemAccentKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var atticPanelThemePalette: AtticPanelThemePalette {
        get { self[AtticPanelThemePaletteKey.self] }
        set { self[AtticPanelThemePaletteKey.self] = newValue }
    }


    var atticPanelUsesSystemAccent: Bool {
        get { self[AtticPanelUsesSystemAccentKey.self] }
        set { self[AtticPanelUsesSystemAccentKey.self] = newValue }
    }
}
