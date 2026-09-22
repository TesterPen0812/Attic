import Foundation

/// One-time, versioned migration of the appearance preferences from the
/// translucency toggle / glass-style picker / gradient model to Surface and
/// Tint. It runs on load, before any view reads settings, against
/// whatever `UserDefaults` `AppSettings` was given, and it is idempotent:
/// once `appearanceSchemaVersion` is current it does nothing.
///
/// The full mapping is recorded in `Docs/Appearance-Model-2026-09.md`.
enum AppearanceMigration {
    static let currentSchemaVersion = 2

    enum Key {
        static let schemaVersion = "appearanceSchemaVersion"
        static let surfaceStyle = "panelSurfaceStyle"
        static let staleDepth = "panelDepth"
        static let tint = "panelTint"
        static let tintLength = "panelTintLength"
        static let theme = "panelTheme"
        static let appearance = "appearancePreference"

        /// Keys of the retired model. They are read once and then removed.
        static let legacyTranslucent = "isTranslucent"
        static let legacyGlassStyle = "panelGlassStyle"
        static let legacyGradientCoverage = "panelGradientCoverage"
        static let legacyGradientColorHex = "panelGradientColorHex"
        static let obsolete = [legacyTranslucent, legacyGlassStyle, legacyGradientCoverage, legacyGradientColorHex]
    }

    /// The retired model's raw glass styles. `liveStable` was an even earlier
    /// spelling of `stable` that the old loader folded in.
    enum LegacyGlassStyle: String {
        case clear
        case frosted
        case stable
        case liveStable
    }

    /// What the retired preferences said, as stored.
    struct Legacy: Equatable {
        var isTranslucent: Bool?
        var glassStyle: LegacyGlassStyle?
        var gradientCoverage: Double?
        var gradientColorHex: String?
        var theme: AtticPanelTheme?
        var hasAppearancePreference = false

        /// No stored appearance at all: a fresh install, which gets the new
        /// defaults rather than a mapping of "nothing".
        var isFresh: Bool {
            isTranslucent == nil && glassStyle == nil && gradientCoverage == nil
                && gradientColorHex == nil && theme == nil && !hasAppearancePreference
        }
    }

    struct Resolved: Equatable {
        var surface: PanelSurfaceStyle
        var tint: PanelTintLevel
        var tintLength: Double = PanelTintLength.defaultValue
    }

    static let freshInstall = Resolved(surface: .glass, tint: .off)

    static func read(from defaults: UserDefaults) -> Legacy {
        var legacy = Legacy()
        legacy.isTranslucent = defaults.object(forKey: Key.legacyTranslucent) as? Bool
        if let raw = defaults.string(forKey: Key.legacyGlassStyle) {
            // An unknown spelling still means "this install existed"; the old
            // loader fell back to Clear for it, and so does the mapping.
            legacy.glassStyle = LegacyGlassStyle(rawValue: raw) ?? .clear
        }
        legacy.gradientCoverage = defaults.object(forKey: Key.legacyGradientCoverage) as? Double
        legacy.gradientColorHex = defaults.string(forKey: Key.legacyGradientColorHex)
        if let raw = defaults.string(forKey: Key.theme) {
            legacy.theme = AtticPanelTheme(rawValue: raw) ?? .defaultTheme
        }
        legacy.hasAppearancePreference = defaults.string(forKey: Key.appearance) != nil
        return legacy
    }

    /// The mapping itself. Pure, so the whole matrix is unit-testable.
    static func resolve(_ legacy: Legacy) -> Resolved {
        guard !legacy.isFresh else { return freshInstall }
        let theme = legacy.theme ?? .defaultTheme
        // The old loader defaulted a missing style to Clear.
        let glassStyle = legacy.glassStyle ?? .clear

        let surface: PanelSurfaceStyle
        if legacy.isTranslucent == false {
            surface = .solid
        } else {
            switch glassStyle {
            case .frosted:
                surface = .glass
            case .stable, .liveStable:
                surface = .frosted
            case .clear:
                surface = .glass
            }
        }

        let coverage = legacy.gradientCoverage ?? legacyDefaultGradientCoverage
        if theme.usesNeutralTint {
            // Original's old top gradient was a neutral pole (black in Dark,
            // white in Light) at 0.82 fading to the coverage, and the old
            // Clear surface drew the same crown over the full height. Both
            // are exactly Original's neutral Tint at Bold, so keep the look.
            if legacy.isTranslucent != false, glassStyle == .clear {
                return Resolved(surface: surface, tint: .bold, tintLength: 1)
            }
            guard coverage.isFinite, coverage > 0 else {
                return Resolved(surface: surface, tint: .off)
            }
            return Resolved(surface: surface, tint: .bold, tintLength: PanelTintLength.clamped(coverage))
        }

        let tint = legacyTintLevel(
            theme: theme,
            gradientCoverage: legacy.gradientCoverage,
            gradientColorHex: legacy.gradientColorHex
        )
        guard tint != .off else { return Resolved(surface: surface, tint: .off) }
        return Resolved(surface: surface, tint: tint, tintLength: PanelTintLength.clamped(coverage))
    }

    /// The old loader's gradient coverage when none was stored.
    static let legacyDefaultGradientCoverage = 0.55

    /// The Tint step matching what the old gradient actually showed: the
    /// old top-edge colour difference (the pole mixed with 12% of the tint,
    /// drawn at 0.82 over the surface) for the palette in Light, on the same
    /// ΔE76 scale the new steps are calibrated to. Coverage 0 was "off".
    static func legacyTintLevel(
        theme: AtticPanelTheme,
        gradientCoverage: Double?,
        gradientColorHex: String?
    ) -> PanelTintLevel {
        let coverage = gradientCoverage ?? legacyDefaultGradientCoverage
        guard coverage.isFinite, coverage > 0 else { return .off }
        let difference = legacyGradientColorDifference(theme: theme, gradientColorHex: gradientColorHex)
        return PanelTintLevel.level(forLegacyColorDifference: difference)
    }

    static let legacyGradientTintMix = 0.12
    static let legacyGradientTopOpacity = 0.82

    static func legacyGradientColorDifference(
        theme: AtticPanelTheme,
        gradientColorHex: String?
    ) -> Double {
        let palette = theme.palette(for: AtticPanelThemeAppearance.light)
        let tint = gradientColorHex.flatMap { AtticThemeColor(hex: $0) } ?? palette.surfaceTint
        let pole = AtticThemeColor(red: 1, green: 1, blue: 1)
        let gradientColor = pole.mixed(with: tint, amount: legacyGradientTintMix)
        let base = palette.opaqueSurface
        let top = base.mixed(with: gradientColor, amount: legacyGradientTopOpacity)
        return ColorDifference.deltaE76(base, top)
    }

    /// Runs the migration if it has not run yet. Returns what it wrote, or
    /// nil when the store was already current.
    @discardableResult
    static func migrateIfNeeded(_ defaults: UserDefaults) -> Resolved? {
        defaults.removeObject(forKey: Key.staleDepth)
        let storedVersion = defaults.object(forKey: Key.schemaVersion) as? Int ?? 0
        guard storedVersion < currentSchemaVersion else { return nil }
        let resolved = resolve(read(from: defaults))
        defaults.set(resolved.surface.rawValue, forKey: Key.surfaceStyle)
        defaults.set(resolved.tint.rawValue, forKey: Key.tint)
        defaults.set(resolved.tintLength, forKey: Key.tintLength)
        for key in Key.obsolete {
            defaults.removeObject(forKey: key)
        }
        defaults.set(currentSchemaVersion, forKey: Key.schemaVersion)
        return resolved
    }
}
