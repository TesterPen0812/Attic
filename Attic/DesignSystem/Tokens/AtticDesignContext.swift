import SwiftUI

/// Everything that changes how the design system draws: Light or Dark, the
/// three customisation layers (palette, surface, tint) and the system
/// accessibility settings. Customisation changes only the background and
/// the accent; the base (controls, cards, text) depends only on `mode` and
/// the accessibility settings.
struct AtticDesignContext: Hashable, Sendable {
    enum Mode: String, CaseIterable, Hashable, Sendable {
        case light
        case dark

        var colorScheme: ColorScheme { self == .dark ? .dark : .light }
        var themeAppearance: AtticPanelThemeAppearance { self == .dark ? .dark : .light }
        var title: String { self == .dark ? "Dark" : "Light" }
    }

    var mode: Mode = .light
    var palette: AtticPanelTheme = .original
    /// The spec's default is Solid (§ Layers).
    var surface: PanelSurfaceStyle = .solid
    var tint: PanelTintLevel = .off
    var tintLength: Double = PanelTintLength.defaultValue
    var increaseContrast = false
    var reduceTransparency = false
    var reduceMotion = false
    var differentiateWithoutColor = false
    var hapticsEnabled = true
    /// How Glass and Frosted trade transparency for contrast. The quality
    /// bar's is the default; the gallery can show the alternative.
    var translucencyPolicy: AtticSurfaceModel.Policy = .fullContrast
    /// Options under review (the glass-and-tint decision sheet). Off by
    /// default: with the default variant every token is as committed.
    var variant = AtticDesignVariant()

    /// Reduce Transparency makes glass and blur solid.
    var effectiveSurface: AtticPanelSurfaceTreatment.Kind {
        reduceTransparency ? .solid : surface.treatmentKind
    }

    var isTranslucent: Bool { effectiveSurface != .solid }

    static let `default` = AtticDesignContext()

    /// The key the resolved tokens are cached under: `reduceMotion`,
    /// `differentiateWithoutColor` and haptics never change a colour.
    var colourKey: ColourKey {
        ColourKey(
            mode: mode,
            palette: palette,
            surface: effectiveSurface,
            tint: tint,
            tintLength: PanelTintLength.clamped(tintLength),
            increaseContrast: increaseContrast,
            policy: translucencyPolicy,
            variant: variant
        )
    }

    struct ColourKey: Hashable, Sendable {
        let mode: Mode
        let palette: AtticPanelTheme
        let surface: AtticPanelSurfaceTreatment.Kind
        let tint: PanelTintLevel
        let tintLength: Double
        let increaseContrast: Bool
        let policy: AtticSurfaceModel.Policy
        let variant: AtticDesignVariant
    }

    /// The resolved tokens for this context (cached).
    var tokens: AtticColorTokens { AtticColorTokens.resolve(self) }

    /// A one-line description for gallery captions and check reports.
    var caption: String {
        var parts = [mode.title, palette.title, PanelSurfaceStyle(effectiveSurface).title]
        if tint != .off { parts.append("\(tint.title) tint") }
        if tint != .off, PanelTintLength.clamped(tintLength) < 1 {
            parts.append("length \(Int((PanelTintLength.clamped(tintLength) * 100).rounded())) %")
        }
        if increaseContrast { parts.append("Increase contrast") }
        if reduceTransparency { parts.append("Reduce transparency") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Environment

private struct AtticDesignContextKey: EnvironmentKey {
    static let defaultValue = AtticDesignContext.default
}

extension EnvironmentValues {
    /// The design context every design-system component reads.
    var atticDesign: AtticDesignContext {
        get { self[AtticDesignContextKey.self] }
        set { self[AtticDesignContextKey.self] = newValue }
    }
}

extension View {
    /// Applies a design context and the matching colour scheme.
    func atticDesign(_ context: AtticDesignContext) -> some View {
        environment(\.atticDesign, context)
            .environment(\.colorScheme, context.mode.colorScheme)
    }

    /// Derives the context from the system (Light or Dark, Increase Contrast,
    /// Reduce Transparency, Reduce Motion, Differentiate Without Colour) plus
    /// the three customisation layers. Phase 1 feeds these from AppSettings.
    func atticDesignFromSystem(
        palette: AtticPanelTheme = .original,
        surface: PanelSurfaceStyle = .solid,
        tint: PanelTintLevel = .off,
        tintLength: Double = PanelTintLength.defaultValue,
        hapticsEnabled: Bool = true
    ) -> some View {
        modifier(AtticSystemDesignModifier(
            palette: palette,
            surface: surface,
            tint: tint,
            tintLength: tintLength,
            hapticsEnabled: hapticsEnabled
        ))
    }
}

private struct AtticSystemDesignModifier: ViewModifier {
    let palette: AtticPanelTheme
    let surface: PanelSurfaceStyle
    let tint: PanelTintLevel
    let tintLength: Double
    let hapticsEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    func body(content: Content) -> some View {
        content.environment(\.atticDesign, AtticDesignContext(
            mode: colorScheme == .dark ? .dark : .light,
            palette: palette,
            surface: surface,
            tint: tint,
            tintLength: tintLength,
            increaseContrast: contrast == .increased,
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion,
            differentiateWithoutColor: differentiateWithoutColor,
            hapticsEnabled: hapticsEnabled
        ))
    }
}

/// Design options the owner is choosing between. Neither is on by default.
struct AtticDesignVariant: Hashable, Sendable {
    /// On translucent or tinted surfaces only, text steps up one rung:
    /// helper (and placeholder) text takes the label colour, labels take
    /// the body colour. The surface's foundation is unchanged.
    var strongerTextOnTranslucentOrTint = false
    /// Draw the Tint at the strengths PR #5 designed (ΔE 3 / 7 / 12, or
    /// Original's neutral shade as drawn), not held back for readability.
    var designedTintStrength = false
}
