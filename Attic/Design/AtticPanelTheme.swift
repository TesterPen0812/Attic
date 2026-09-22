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

    /// Original's Tint is a neutral shade (`PanelNeutralShade`); the custom
    /// palettes wash in their own accent colour (`PanelTintCalibration`).
    var usesNeutralTint: Bool { self == .original }

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
                frostedTintOpacity: 0,
                selectedFillOpacity: 0.15,
                selectedStrokeOpacity: 0.22
            )
        case (.original, .light):
            return .init(
                // Match the existing AccentColor asset in both schemes so
                // choosing (or defaulting to) Original is visually inert.
                accent: .init(red: 0.116, green: 0.478, blue: 0.980),
                // The Original opaque Light surface is exactly #FFFFFF. Its
                // boundary comes from the hairline edge and the shape
                // elevation, never from an off-white or grey fill.
                opaqueSurface: .init(red: 1, green: 1, blue: 1),
                surfaceTint: .init(red: 1, green: 1, blue: 1),
                edgeTint: .init(red: 0, green: 0, blue: 0),
                frostedTintOpacity: 0,
                selectedFillOpacity: 0.12,
                selectedStrokeOpacity: 0.20
            )
        case (.midnightCobalt, .dark):
            return .init(
                accent: .init(red: 0.471, green: 0.569, blue: 1.000),
                opaqueSurface: .init(red: 0.027, green: 0.067, blue: 0.153),
                surfaceTint: .init(red: 0.157, green: 0.247, blue: 0.541),
                edgeTint: .init(red: 0.490, green: 0.612, blue: 1.000),
                frostedTintOpacity: 0.045,
                selectedFillOpacity: 0.17,
                selectedStrokeOpacity: 0.42
            )
        case (.midnightCobalt, .light):
            return .init(
                accent: .init(red: 0.153, green: 0.298, blue: 0.620),
                opaqueSurface: .init(red: 0.933, green: 0.953, blue: 0.988),
                surfaceTint: .init(red: 0.302, green: 0.412, blue: 0.698),
                edgeTint: .init(red: 0.176, green: 0.345, blue: 0.722),
                frostedTintOpacity: 0.032,
                selectedFillOpacity: 0.12,
                selectedStrokeOpacity: 0.34
            )
        case (.porcelainVapor, .dark):
            return .init(
                accent: .init(red: 0.659, green: 0.773, blue: 0.847),
                opaqueSurface: .init(red: 0.102, green: 0.118, blue: 0.141),
                surfaceTint: .init(red: 0.533, green: 0.604, blue: 0.651),
                edgeTint: .init(red: 0.718, green: 0.800, blue: 0.847),
                frostedTintOpacity: 0.018,
                selectedFillOpacity: 0.12,
                selectedStrokeOpacity: 0.30
            )
        case (.porcelainVapor, .light):
            return .init(
                accent: .init(red: 0.282, green: 0.404, blue: 0.471),
                opaqueSurface: .init(red: 0.965, green: 0.965, blue: 0.957),
                surfaceTint: .init(red: 0.718, green: 0.776, blue: 0.808),
                edgeTint: .init(red: 0.392, green: 0.494, blue: 0.545),
                frostedTintOpacity: 0.018,
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
                frostedTintOpacity: 0.035,
                selectedFillOpacity: 0.15,
                selectedStrokeOpacity: 0.36
            )
        case (.smokedUmber, .light):
            return .init(
                accent: .init(red: 0.478, green: 0.374, blue: 0.196),
                opaqueSurface: .init(red: 0.961, green: 0.933, blue: 0.906),
                surfaceTint: .init(red: 0.663, green: 0.518, blue: 0.400),
                edgeTint: .init(red: 0.510, green: 0.349, blue: 0.231),
                frostedTintOpacity: 0.028,
                selectedFillOpacity: 0.10,
                selectedStrokeOpacity: 0.30
            )
        case (.electricBlue, .dark):
            return .init(
                accent: .init(red: 0.153, green: 0.545, blue: 1.000),
                opaqueSurface: .init(red: 0.067, green: 0.075, blue: 0.090),
                surfaceTint: .init(red: 0.086, green: 0.459, blue: 0.910),
                edgeTint: .init(red: 0.231, green: 0.600, blue: 1.000),
                frostedTintOpacity: 0.022,
                selectedFillOpacity: 0.16,
                selectedStrokeOpacity: 0.40
            )
        case (.electricBlue, .light):
            return .init(
                accent: .init(red: 0.043, green: 0.392, blue: 0.847),
                opaqueSurface: .init(red: 0.980, green: 0.984, blue: 0.992),
                surfaceTint: .init(red: 0.227, green: 0.561, blue: 0.941),
                edgeTint: .init(red: 0.067, green: 0.427, blue: 0.863),
                frostedTintOpacity: 0.018,
                selectedFillOpacity: 0.10,
                selectedStrokeOpacity: 0.32
            )
        case (.seaGlass, .dark):
            return .init(
                accent: .init(red: 0.392, green: 0.804, blue: 0.722),
                opaqueSurface: .init(red: 0.063, green: 0.110, blue: 0.110),
                surfaceTint: .init(red: 0.239, green: 0.561, blue: 0.490),
                edgeTint: .init(red: 0.459, green: 0.843, blue: 0.765),
                frostedTintOpacity: 0.028,
                selectedFillOpacity: 0.15,
                selectedStrokeOpacity: 0.37
            )
        case (.seaGlass, .light):
            return .init(
                accent: .init(red: 0.149, green: 0.475, blue: 0.408),
                opaqueSurface: .init(red: 0.949, green: 0.965, blue: 0.945),
                surfaceTint: .init(red: 0.510, green: 0.718, blue: 0.655),
                edgeTint: .init(red: 0.184, green: 0.502, blue: 0.435),
                frostedTintOpacity: 0.024,
                selectedFillOpacity: 0.10,
                selectedStrokeOpacity: 0.30
            )
        case (.amethyst, .dark):
            return .init(
                accent: .init(red: 0.667, green: 0.518, blue: 0.961),
                opaqueSurface: .init(red: 0.094, green: 0.082, blue: 0.133),
                surfaceTint: .init(red: 0.439, green: 0.322, blue: 0.659),
                edgeTint: .init(red: 0.729, green: 0.588, blue: 1.000),
                frostedTintOpacity: 0.030,
                selectedFillOpacity: 0.15,
                selectedStrokeOpacity: 0.38
            )
        case (.amethyst, .light):
            return .init(
                accent: .init(red: 0.420, green: 0.282, blue: 0.706),
                opaqueSurface: .init(red: 0.969, green: 0.953, blue: 0.984),
                surfaceTint: .init(red: 0.667, green: 0.576, blue: 0.820),
                edgeTint: .init(red: 0.459, green: 0.325, blue: 0.737),
                frostedTintOpacity: 0.024,
                selectedFillOpacity: 0.10,
                selectedStrokeOpacity: 0.30
            )
        }
    }

    func surfaceTreatment(
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast = .standard,
        surface: PanelSurfaceStyle,
        tint: PanelTintLevel,
        tintLength: Double = PanelTintLength.defaultValue,
        reduceTransparency: Bool
    ) -> AtticPanelSurfaceTreatment {
        surfaceTreatment(
            appearance: colorScheme == .dark
                ? AtticPanelThemeAppearance.dark
                : AtticPanelThemeAppearance.light,
            contrast: contrast,
            surface: surface,
            tint: tint,
            tintLength: tintLength,
            reduceTransparency: reduceTransparency
        )
    }

    /// The one resolution from settings to a drawable surface. Reduce
    /// Transparency forces Solid rendering and keeps the chosen Tint;
    /// Increased Contrast only changes the palette's edges.
    func surfaceTreatment(
        appearance: AtticPanelThemeAppearance,
        contrast: ColorSchemeContrast = .standard,
        surface: PanelSurfaceStyle,
        tint: PanelTintLevel,
        tintLength: Double = PanelTintLength.defaultValue,
        reduceTransparency: Bool
    ) -> AtticPanelSurfaceTreatment {
        AtticPanelSurfaceTreatment(
            theme: self,
            kind: reduceTransparency ? .solid : surface.treatmentKind,
            palette: palette(for: appearance, contrast: contrast),
            appearance: appearance,
            usesSystemOpaqueSurface: self == .original,
            tint: tint,
            tintLength: tintLength
        )
    }
}

extension PanelSurfaceStyle {
    var treatmentKind: AtticPanelSurfaceTreatment.Kind {
        switch self {
        case .solid: .solid
        case .glass: .glass
        case .frosted: .frosted
        }
    }

    init(_ kind: AtticPanelSurfaceTreatment.Kind) {
        switch kind {
        case .solid: self = .solid
        case .glass: self = .glass
        case .frosted: self = .frosted
        }
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

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.utf8.count == 6,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255,
                  blue: Double(rgb & 255) / 255)
    }

    var hexString: String {
        guard red.isFinite, green.isFinite, blue.isFinite else { return "" }
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

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

    var contrastingForeground: AtticThemeColor {
        let black = AtticThemeColor(red: 0, green: 0, blue: 0)
        let white = AtticThemeColor(red: 1, green: 1, blue: 1)
        return contrastRatio(with: black) >= contrastRatio(with: white) ? black : white
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
    /// Opacity of `surfaceTint` washed over the Frosted material. Glass
    /// and Solid never use it: their colour comes from the foundation and
    /// the fill.
    let frostedTintOpacity: Double
    let selectedFillOpacity: Double
    let selectedStrokeOpacity: Double

    var isValid: Bool {
        [accent, opaqueSurface, surfaceTint, edgeTint].allSatisfy(\.isValid)
            && [
                frostedTintOpacity,
                selectedFillOpacity,
                selectedStrokeOpacity
            ].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    var accentColor: Color { accent.swiftUIColor() }
    var opaqueSurfaceColor: Color { opaqueSurface.swiftUIColor() }
    // Explicit RGB foregrounds avoid multiplying the system secondary label's
    // already-reduced alpha by another local opacity.
    var primaryForeground: AtticThemeColor {
        let value = opaqueSurface.relativeLuminance < 0.5 ? 0.96 : 0.08
        return .init(red: value, green: value, blue: value)
    }
    var secondaryForeground: AtticThemeColor {
        // Keep hierarchy through size/weight rather than faint text: stronger
        // captions allow the glass beneath them to transmit more background.
        let value = opaqueSurface.relativeLuminance < 0.5 ? 0.90 : 0.12
        return .init(red: value, green: value, blue: value)
    }
    var primaryForegroundColor: Color { primaryForeground.swiftUIColor() }
    var secondaryForegroundColor: Color { secondaryForeground.swiftUIColor() }

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
            frostedTintOpacity: frostedTintOpacity,
            selectedFillOpacity: min(selectedFillOpacity + 0.04, 1),
            selectedStrokeOpacity: min(selectedStrokeOpacity + 0.14, 1)
        )
    }
}

struct AtticPanelSurfaceTreatment: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// The palette `opaqueSurface`, fully opaque.
        case solid
        /// Native Liquid Glass (`.regular`) under a calibrated foundation.
        case glass
        /// A material blur under the same foundation, with a palette wash.
        case frosted
    }

    let theme: AtticPanelTheme
    let kind: Kind
    let palette: AtticPanelThemePalette
    let appearance: AtticPanelThemeAppearance
    let usesSystemOpaqueSurface: Bool
    let foundationOpacity: Double
    let tintTopOpacity: Double
    /// True when the readability floor, not the chosen step, set the wash.
    /// It comes from whichever cell this treatment used (the generated
    /// table, or the pre-macOS-26 solve), so the Settings note follows it.
    let isTintClamped: Bool
    /// The Tint step: Original's neutral shade (`PanelNeutralShade`) or a
    /// custom palette's accent wash (`PanelTintCalibration`).
    let tint: PanelTintLevel
    /// How far down the panel the Tint reaches (`PanelTintLength`).
    let tintLength: Double

    /// The historical floor: a small buffer above 4.5:1. Solid, and every
    /// surface on the uncredited (pre-macOS-26) path, keep it.
    static let readableContrastTarget = 4.75

    /// The worst-case contrast floor each surface is solved to. On native
    /// Liquid Glass the owner chose the Siri panel's level of transparency:
    /// its lower third measures about 2.4-3:1 for white text over a white
    /// page, so Glass keeps 3:1 over the worst-case desktop (a pure white page
    /// behind Dark, pure black behind Light). Frosted stays the calmer,
    /// easier-to-read choice at 3.5:1. Typical desktops read far better than
    /// these extremes; see `Docs/Appearance-Model-2026-09.md` §2.
    static func readableContrastTarget(kind: Kind, creditsNativeSurface: Bool) -> Double {
        guard creditsNativeSurface else { return readableContrastTarget }
        switch kind {
        case .solid: return readableContrastTarget
        case .glass: return 3.0
        case .frosted: return 3.5
        }
    }

    init(theme: AtticPanelTheme, kind: Kind, palette: AtticPanelThemePalette,
         appearance: AtticPanelThemeAppearance, usesSystemOpaqueSurface: Bool,
         tint: PanelTintLevel = .off,
         tintLength: Double = PanelTintLength.defaultValue,
         creditsNativeSurface: Bool = AtticGlassControlTreatment.systemSupportsNativeGlass) {
        self.theme = theme
        self.kind = kind
        self.palette = palette
        self.appearance = appearance
        self.usesSystemOpaqueSurface = usesSystemOpaqueSurface
        self.tint = tint
        self.tintLength = PanelTintLength.clamped(tintLength)
        if theme.usesNeutralTint {
            // The neutral shade only moves the surface away from the text
            // colour, so it keeps the Tint-Off foundation and never clamps.
            foundationOpacity = kind == .solid ? 1 : Self.minimumReadableOpacity(
                palette: palette,
                appearance: appearance,
                kind: kind,
                creditsNativeSurface: creditsNativeSurface
            )
            tintTopOpacity = PanelNeutralShade.stops(level: tint, length: tintLength).first?.opacity ?? 0
            isTintClamped = false
            return
        }
        switch kind {
        case .solid:
            foundationOpacity = 1
            let cell = tint == .off
                ? nil
                : PanelTintCalibration.cell(
                    theme: theme,
                    appearance: appearance,
                    kind: kind,
                    level: tint
                )
            tintTopOpacity = cell?.topOpacity ?? 0
            isTintClamped = cell?.isClamped ?? false
        case .glass, .frosted:
            let plain = Self.minimumReadableOpacity(
                palette: palette,
                appearance: appearance,
                kind: kind,
                creditsNativeSurface: creditsNativeSurface
            )
            if tint == .off {
                foundationOpacity = plain
                tintTopOpacity = 0
                isTintClamped = false
            } else if creditsNativeSurface,
                      let cell = PanelTintCalibration.cell(
                          theme: theme,
                          appearance: appearance,
                          kind: kind,
                          level: tint
                      ) {
                foundationOpacity = cell.foundationOpacity
                tintTopOpacity = cell.topOpacity
                isTintClamped = cell.isClamped
            } else {
                let cell = PanelTintCalibration.solve(
                    theme: theme,
                    appearance: appearance,
                    kind: kind,
                    palette: palette,
                    level: tint,
                    minimumFoundationOpacity: plain,
                    creditsNativeSurface: false
                )
                foundationOpacity = cell?.foundationOpacity ?? plain
                tintTopOpacity = cell?.topOpacity ?? 0
                isTintClamped = cell?.isClamped ?? false
            }
        }
    }

    /// Solve once per treatment, not per gradient sample or drawing layer. On
    /// macOS 26+ the measured bare native surface is credited before the
    /// readable foundation is applied. Older material fallbacks keep the raw
    /// black/white worst case so their historical foundation is unchanged.
    static func minimumReadableOpacity(
        palette: AtticPanelThemePalette,
        appearance: AtticPanelThemeAppearance,
        kind: Kind,
        creditsNativeSurface: Bool
    ) -> Double {
        let backdrop = worstCaseUnderlay(
            kind: kind,
            appearance: appearance,
            creditsNativeSurface: creditsNativeSurface
        )
        let target = readableContrastTarget(kind: kind, creditsNativeSurface: creditsNativeSurface)
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<16 {
            let alpha = (lower + upper) / 2
            let surface = backdrop.mixed(with: palette.opaqueSurface, amount: alpha)
            let ratio = min(palette.primaryForeground.contrastRatio(with: surface),
                            palette.secondaryForeground.contrastRatio(with: surface))
            if ratio >= target { upper = alpha } else { lower = alpha }
        }
        // The first whole percentage point that clears the target.
        return min(ceil(upper * 100) / 100, 1)
    }

    /// Measured bare-surface rendering beneath the foundation. Values are
    /// neutral sRGB samples from macOS 26+/27 prototypes over white for Dark
    /// panels and black for Light panels; see the measurement table in
    /// `Docs/Appearance-Model-2026-09.md`.
    static func worstCaseUnderlay(
        kind: Kind,
        appearance: AtticPanelThemeAppearance,
        creditsNativeSurface: Bool = AtticGlassControlTreatment.systemSupportsNativeGlass
    ) -> AtticThemeColor {
        guard creditsNativeSurface else {
            let raw = appearance == .dark ? 1.0 : 0.0
            return AtticThemeColor(red: raw, green: raw, blue: raw)
        }

        let byte: Double
        switch (kind, appearance) {
        case (.glass, .dark): byte = 143
        case (.glass, .light): byte = 104
        case (.frosted, .dark): byte = 166
        case (.frosted, .light): byte = 89
        case (.solid, .dark): byte = 255
        case (.solid, .light): byte = 0
        }
        let value = byte / 255
        return AtticThemeColor(red: value, green: value, blue: value)
    }

    // MARK: Tint

    /// Whether this treatment's Tint is Original's neutral shade.
    var usesNeutralTint: Bool { theme.usesNeutralTint }

    /// The wash colour: black or white for the neutral shade, otherwise the
    /// palette accent's hue, saturated.
    var washColor: AtticThemeColor {
        usesNeutralTint
            ? PanelNeutralShade.color(for: appearance)
            : PanelTintCalibration.washColor(for: palette, appearance: appearance)
    }

    /// The drawn gradient, top to bottom. The neutral shade follows the
    /// crown profile; the accent wash fades linearly to nothing. Both end at
    /// `tintLength`, and past the last stop the gradient holds its value.
    var tintStops: [PanelTintStop] {
        guard tintTopOpacity > 0 else { return [] }
        if usesNeutralTint {
            return PanelNeutralShade.stops(level: tint, length: tintLength)
        }
        return [
            PanelTintStop(opacity: tintTopOpacity, location: 0),
            PanelTintStop(opacity: 0, location: tintLength)
        ]
    }

    /// The Tint's opacity at a normalised height, interpolated between
    /// `tintStops` exactly as the gradient draws it.
    func tintOpacity(at location: Double) -> Double {
        let stops = tintStops
        guard location.isFinite, let first = stops.first, let last = stops.last else { return 0 }
        let clamped = min(max(location, 0), 1)
        if clamped <= first.location { return first.opacity }
        if clamped >= last.location { return last.opacity }
        for (lower, upper) in zip(stops, stops.dropFirst()) where clamped <= upper.location {
            let span = upper.location - lower.location
            guard span > 0 else { return upper.opacity }
            return lower.opacity + (upper.opacity - lower.opacity) * (clamped - lower.location) / span
        }
        return last.opacity
    }

    // MARK: Composite model

    /// What a point of the surface looks like over a backdrop: foundation,
    /// then the Tint wash, in drawing order. Solid
    /// surfaces transmit nothing, so the backdrop is irrelevant there.
    /// Frosted's own `surfaceTint` wash (at most 0.045, drawn under the
    /// foundation) and the native material are deliberately not modelled:
    /// the model is a source-over bound, not a claim about the compositor.
    func compositedSurface(over backdrop: AtticThemeColor, location: Double = 1) -> AtticThemeColor {
        let color = backdrop.mixed(with: palette.opaqueSurface, amount: foundationOpacity)
        return color.mixed(with: washColor, amount: tintOpacity(at: location))
    }

    /// Opacity of `surfaceTint` over the Frosted material. Solid is filled
    /// with `opaqueSurface` and Glass carries its colour in the foundation,
    /// so both are zero and an accidental overlay use stays harmless.
    var materialTintOpacity: Double {
        switch kind {
        case .solid, .glass: 0
        case .frosted: palette.frostedTintOpacity
        }
    }

    // MARK: Frame

    /// One semantic hairline per palette family, the same strength on every
    /// surface kind and on every panel window. It reads as a boundary against
    /// a same-coloured backdrop without becoming a border; Increased Contrast
    /// adds one step. Original strokes `Color.primary`, custom palettes their
    /// `edgeTint`, so the numbers differ by family, never by surface.
    func surfaceEdgeOpacity(for contrast: ColorSchemeContrast) -> Double {
        let standardOpacity = usesSystemOpaqueSurface
            ? Self.originalEdgeOpacity
            : Self.customEdgeOpacity
        let increasedContrastAdjustment = usesSystemOpaqueSurface
            ? Self.originalIncreasedContrastEdgeStep
            : Self.customIncreasedContrastEdgeStep
        return contrast == .increased
            ? min(standardOpacity + increasedContrastAdjustment, 1)
            : standardOpacity
    }

    static let originalEdgeOpacity = 0.09
    static let customEdgeOpacity = 0.19
    static let originalIncreasedContrastEdgeStep = 0.10
    static let customIncreasedContrastEdgeStep = 0.14

    func surfaceEdgeLineWidth(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 1 : 0.75
    }

    /// Exterior elevation for the visible squircle, on every surface kind.
    /// The host draws it outside the shape only (`AtticPanelOutsideShadow`),
    /// so a translucent interior is never darkened by its own shadow.
    var surfaceElevation: AtticPanelSurfaceElevation {
        appearance == .dark ? .dark : .light
    }
}

/// A soft, broad, low-opacity shadow that follows the panel shape. The
/// AppKit window keeps its own shadow disabled so nothing rectangular stacks
/// beneath this treatment.
struct AtticPanelSurfaceElevation: Equatable, Sendable {
    let opacity: Double
    let radius: CGFloat
    let offsetY: CGFloat

    static let light = AtticPanelSurfaceElevation(opacity: 0.10, radius: 10, offsetY: 1)
    static let dark = AtticPanelSurfaceElevation(opacity: 0.30, radius: 10, offsetY: 1)

    /// Room the shadow needs beyond the visible surface before it fades out.
    var extent: CGFloat { radius * 2 + abs(offsetY) }
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
