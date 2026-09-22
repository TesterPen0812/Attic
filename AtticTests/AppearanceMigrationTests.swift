import Foundation
import SwiftUI
import XCTest
@testable import Attic

/// The one-time move from translucency / glass style / gradient to Surface,
/// Depth and Tint: the whole matrix, idempotence, a fresh install, and the
/// obsolete keys being removed.
final class AppearanceMigrationTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "AppearanceMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private typealias Legacy = AppearanceMigration.Legacy
    private typealias Resolved = AppearanceMigration.Resolved

    // MARK: Pure mapping

    func testFreshInstallGetsGlassWithDepthAndNoTint() {
        XCTAssertEqual(AppearanceMigration.resolve(Legacy()), AppearanceMigration.freshInstall)
        XCTAssertEqual(AppearanceMigration.freshInstall, Resolved(surface: .glass, depth: true, tint: .off))
    }

    func testAnyStoredAppearanceKeyMeansAnExistingInstall() {
        // Old builds wrote the gradient keys back on every launch, so any
        // launched install has them; a theme or appearance preference alone
        // still counts. None of these may receive the fresh-install crown.
        let variants: [Legacy] = [
            Legacy(isTranslucent: true),
            Legacy(glassStyle: .frosted),
            Legacy(gradientCoverage: 0.55),
            Legacy(gradientColorHex: ""),
            Legacy(theme: .original),
            Legacy(hasAppearancePreference: true)
        ]
        for legacy in variants {
            XCTAssertFalse(legacy.isFresh, "\(legacy)")
        }
        // Theme Original with a missing style resolved to Clear before, so
        // that one user did see the crown; everyone else did not.
        XCTAssertEqual(AppearanceMigration.resolve(Legacy(gradientCoverage: 0.55)).depth, true)
        XCTAssertEqual(AppearanceMigration.resolve(Legacy(gradientCoverage: 0.55, theme: .seaGlass)).depth, false)
        XCTAssertEqual(AppearanceMigration.resolve(Legacy(glassStyle: .frosted)).depth, false)
    }

    func testTranslucencyOffAlwaysBecomesSolidAndKeepsDepthOff() {
        for style in [AppearanceMigration.LegacyGlassStyle.clear, .frosted, .stable, .liveStable] {
            for theme in AtticPanelTheme.allCases {
                let resolved = AppearanceMigration.resolve(
                    Legacy(isTranslucent: false, glassStyle: style, gradientCoverage: 0.55, theme: theme)
                )
                XCTAssertEqual(resolved.surface, .solid, "\(theme.rawValue) \(style)")
                XCTAssertFalse(resolved.depth, "\(theme.rawValue) \(style)")
            }
        }
    }

    func testGlassStylesMapToTheirRenderingPaths() {
        for theme in AtticPanelTheme.allCases {
            let frosted = AppearanceMigration.resolve(Legacy(isTranslucent: true, glassStyle: .frosted, theme: theme))
            XCTAssertEqual(frosted.surface, .glass, theme.rawValue)
            XCTAssertFalse(frosted.depth, theme.rawValue)
            for stable in [AppearanceMigration.LegacyGlassStyle.stable, .liveStable] {
                let resolved = AppearanceMigration.resolve(Legacy(isTranslucent: true, glassStyle: stable, theme: theme))
                XCTAssertEqual(resolved.surface, .frosted, "\(theme.rawValue) \(stable)")
                XCTAssertFalse(resolved.depth, "\(theme.rawValue) \(stable)")
            }
            let clear = AppearanceMigration.resolve(Legacy(isTranslucent: true, glassStyle: .clear, theme: theme))
            XCTAssertEqual(clear.surface, .glass, theme.rawValue)
            XCTAssertEqual(clear.depth, theme == .original, theme.rawValue)
        }
    }

    func testGradientCoverageZeroIsTintOff() {
        for theme in AtticPanelTheme.allCases {
            let resolved = AppearanceMigration.resolve(
                Legacy(isTranslucent: true, glassStyle: .frosted, gradientCoverage: 0,
                       gradientColorHex: "FF0000", theme: theme)
            )
            XCTAssertEqual(resolved.tint, .off, theme.rawValue)
        }
    }

    func testThemeGradientsMapToTheStepTheyActuallyShowed() {
        // The 12% pole mix at 0.82 barely moved most palettes' own surface,
        // which is why the gradient looked invisible: those users keep Tint
        // off. Electric Blue's saturated surface tint was the one theme
        // colour that visibly showed in Light (ΔE about 5.6), so its users
        // keep a Vivid wash rather than losing what they saw.
        for theme in AtticPanelTheme.allCases {
            let difference = AppearanceMigration.legacyGradientColorDifference(theme: theme, gradientColorHex: nil)
            let expected: PanelTintLevel = theme == .electricBlue ? .vivid : .off
            if theme == .electricBlue {
                XCTAssertEqual(difference, 5.6, accuracy: 0.3, "\(theme.rawValue) ΔE \(difference)")
            } else {
                XCTAssertLessThan(difference, 3, "\(theme.rawValue) ΔE \(difference)")
            }
            XCTAssertEqual(AppearanceMigration.legacyTintLevel(theme: theme, gradientCoverage: 0.55,
                                                              gradientColorHex: ""), expected, theme.rawValue)
            // A missing coverage key meant the old default of 0.55.
            XCTAssertEqual(AppearanceMigration.legacyTintLevel(theme: theme, gradientCoverage: nil,
                                                              gradientColorHex: nil), expected, theme.rawValue)
        }
    }

    func testCustomGradientColoursMapToTheStepTheyLookedLike() {
        // A saturated custom colour did show: pure red over the white
        // Original surface is a clearly visible wash, a near-white one is not.
        XCTAssertEqual(AppearanceMigration.legacyTintLevel(theme: .original, gradientCoverage: 0.55,
                                                          gradientColorHex: "FAFAFF"), .off)
        let red = AppearanceMigration.legacyGradientColorDifference(theme: .original, gradientColorHex: "FF0000")
        XCTAssertGreaterThanOrEqual(red, 3)
        XCTAssertEqual(AppearanceMigration.legacyTintLevel(theme: .original, gradientCoverage: 1,
                                                          gradientColorHex: "FF0000"),
                       PanelTintLevel.level(forLegacyColorDifference: red))
        // Black, the other extreme, also showed clearly.
        let black = AppearanceMigration.legacyGradientColorDifference(theme: .original, gradientColorHex: "000000")
        XCTAssertGreaterThanOrEqual(black, 5)
        // The thresholds are the documented ones.
        XCTAssertEqual(PanelTintLevel.level(forLegacyColorDifference: 2.99), .off)
        XCTAssertEqual(PanelTintLevel.level(forLegacyColorDifference: 3), .subtle)
        XCTAssertEqual(PanelTintLevel.level(forLegacyColorDifference: 4.99), .subtle)
        XCTAssertEqual(PanelTintLevel.level(forLegacyColorDifference: 5), .vivid)
        XCTAssertEqual(PanelTintLevel.level(forLegacyColorDifference: 9.49), .vivid)
        XCTAssertEqual(PanelTintLevel.level(forLegacyColorDifference: 9.5), .bold)
        XCTAssertEqual(PanelTintLevel.level(forLegacyColorDifference: .nan), .off)
        // An unparseable custom colour falls back to the theme colour.
        XCTAssertEqual(AppearanceMigration.legacyTintLevel(theme: .amethyst, gradientCoverage: 0.55,
                                                          gradientColorHex: "not-a-colour"), .off)
    }

    // MARK: Against UserDefaults

    func testMigrationWritesEveryNewKeyAndRemovesEveryOldOne() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "isTranslucent")
        defaults.set("clear", forKey: "panelGlassStyle")
        defaults.set(0.55, forKey: "panelGradientCoverage")
        defaults.set("", forKey: "panelGradientColorHex")
        defaults.set("original", forKey: "panelTheme")
        defaults.set("dark", forKey: "appearancePreference")

        let written = AppearanceMigration.migrateIfNeeded(defaults)
        XCTAssertEqual(written, Resolved(surface: .glass, depth: true, tint: .off))
        XCTAssertEqual(defaults.string(forKey: "panelSurfaceStyle"), "glass")
        XCTAssertEqual(defaults.object(forKey: "panelDepth") as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: "panelTint"), "off")
        XCTAssertEqual(defaults.integer(forKey: "appearanceSchemaVersion"), 2)
        for key in ["isTranslucent", "panelGlassStyle", "panelGradientCoverage", "panelGradientColorHex"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        // Untouched: the theme and the mode.
        XCTAssertEqual(defaults.string(forKey: "panelTheme"), "original")
        XCTAssertEqual(defaults.string(forKey: "appearancePreference"), "dark")
    }

    func testMigrationIsIdempotent() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "isTranslucent")
        defaults.set("seaGlass", forKey: "panelTheme")
        XCTAssertNotNil(AppearanceMigration.migrateIfNeeded(defaults))
        // The user then changes their mind; a second run must not undo it.
        defaults.set("frosted", forKey: "panelSurfaceStyle")
        defaults.set(true, forKey: "panelDepth")
        defaults.set("bold", forKey: "panelTint")
        // Even if an old key somehow reappears.
        defaults.set("clear", forKey: "panelGlassStyle")
        let snapshot = defaults.dictionaryRepresentation()
        XCTAssertNil(AppearanceMigration.migrateIfNeeded(defaults))
        XCTAssertNil(AppearanceMigration.migrateIfNeeded(defaults))
        let after = defaults.dictionaryRepresentation()
        XCTAssertEqual(after["panelSurfaceStyle"] as? String, "frosted")
        XCTAssertEqual(after["panelDepth"] as? Bool, true)
        XCTAssertEqual(after["panelTint"] as? String, "bold")
        XCTAssertEqual(after["appearanceSchemaVersion"] as? Int, 2)
        XCTAssertEqual(NSDictionary(dictionary: after), NSDictionary(dictionary: snapshot))
    }

    func testFreshInstallThroughAppSettingsStartsOnGlassWithDepth() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = try MainActor.assumeIsolated { AppSettings(defaults: defaults) }
        MainActor.assumeIsolated {
            XCTAssertEqual(settings.panelTheme, .original)
            XCTAssertEqual(settings.appearance, .system)
            XCTAssertEqual(settings.panelSurfaceStyle, .glass)
            XCTAssertTrue(settings.panelDepthEnabled)
            XCTAssertEqual(settings.panelTint, .off)
        }
        XCTAssertEqual(defaults.integer(forKey: "appearanceSchemaVersion"), 2)
        XCTAssertNil(defaults.object(forKey: "panelTheme"), "the theme default is still not written")
        // A relaunch is still the same install.
        let relaunched = try MainActor.assumeIsolated { AppSettings(defaults: defaults) }
        MainActor.assumeIsolated {
            XCTAssertTrue(relaunched.panelDepthEnabled)
            XCTAssertEqual(relaunched.panelSurfaceStyle, .glass)
        }
    }

    func testTheWholeLegacyMatrixThroughAppSettings() throws {
        struct Case {
            let translucent: Bool?
            let style: String?
            let theme: AtticPanelTheme
            let expected: Resolved
        }
        let cases: [Case] = [
            Case(translucent: false, style: "clear", theme: .original, expected: Resolved(surface: .solid, depth: false, tint: .off)),
            Case(translucent: false, style: "frosted", theme: .amethyst, expected: Resolved(surface: .solid, depth: false, tint: .off)),
            Case(translucent: true, style: "frosted", theme: .original, expected: Resolved(surface: .glass, depth: false, tint: .off)),
            Case(translucent: true, style: "stable", theme: .original, expected: Resolved(surface: .frosted, depth: false, tint: .off)),
            Case(translucent: true, style: "liveStable", theme: .midnightCobalt, expected: Resolved(surface: .frosted, depth: false, tint: .off)),
            Case(translucent: true, style: "clear", theme: .original, expected: Resolved(surface: .glass, depth: true, tint: .off)),
            // Electric Blue's theme gradient was the one that visibly showed.
            Case(translucent: true, style: "clear", theme: .electricBlue, expected: Resolved(surface: .glass, depth: false, tint: .vivid)),
            Case(translucent: nil, style: nil, theme: .original, expected: Resolved(surface: .glass, depth: true, tint: .off)),
            Case(translucent: nil, style: "unknown-style", theme: .seaGlass, expected: Resolved(surface: .glass, depth: false, tint: .off))
        ]
        for testCase in cases {
            let (defaults, suite) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            if let translucent = testCase.translucent { defaults.set(translucent, forKey: "isTranslucent") }
            if let style = testCase.style { defaults.set(style, forKey: "panelGlassStyle") }
            defaults.set(0.55, forKey: "panelGradientCoverage")
            defaults.set(testCase.theme.rawValue, forKey: "panelTheme")
            let settings = try MainActor.assumeIsolated { AppSettings(defaults: defaults) }
            let context = "\(String(describing: testCase.translucent)) \(String(describing: testCase.style)) \(testCase.theme.rawValue)"
            MainActor.assumeIsolated {
                XCTAssertEqual(settings.panelSurfaceStyle, testCase.expected.surface, context)
                XCTAssertEqual(settings.panelDepthEnabled, testCase.expected.depth, context)
                XCTAssertEqual(settings.panelTint, testCase.expected.tint, context)
                XCTAssertEqual(settings.panelTheme, testCase.theme, context)
            }
            XCTAssertNil(defaults.object(forKey: "isTranslucent"), context)
            XCTAssertNil(defaults.object(forKey: "panelGlassStyle"), context)
            XCTAssertNil(defaults.object(forKey: "panelGradientCoverage"), context)
        }
    }

    func testCustomGradientColourBecomesATintStepAndIsThenDiscarded() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "isTranslucent")
        defaults.set("frosted", forKey: "panelGlassStyle")
        defaults.set(0.8, forKey: "panelGradientCoverage")
        defaults.set("000000", forKey: "panelGradientColorHex")
        defaults.set("original", forKey: "panelTheme")
        let settings = try MainActor.assumeIsolated { AppSettings(defaults: defaults) }
        let expected = AppearanceMigration.legacyTintLevel(theme: .original, gradientCoverage: 0.8, gradientColorHex: "000000")
        XCTAssertNotEqual(expected, .off)
        MainActor.assumeIsolated {
            XCTAssertEqual(settings.panelTint, expected)
        }
        XCTAssertNil(defaults.object(forKey: "panelGradientColorHex"))
    }

    func testNewPreferencesRoundTripAndFallBackSafely() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = try MainActor.assumeIsolated { AppSettings(defaults: defaults) }
        MainActor.assumeIsolated {
            for surface in PanelSurfaceStyle.allCases {
                settings.panelSurfaceStyle = surface
                XCTAssertEqual(defaults.string(forKey: "panelSurfaceStyle"), surface.rawValue)
                XCTAssertEqual(AppSettings(defaults: defaults).panelSurfaceStyle, surface)
            }
            for level in PanelTintLevel.allCases {
                settings.panelTint = level
                XCTAssertEqual(defaults.string(forKey: "panelTint"), level.rawValue)
                XCTAssertEqual(AppSettings(defaults: defaults).panelTint, level)
            }
            settings.panelDepthEnabled = false
            XCTAssertEqual(defaults.object(forKey: "panelDepth") as? Bool, false)
            XCTAssertFalse(AppSettings(defaults: defaults).panelDepthEnabled)
        }
        defaults.set("future-surface", forKey: "panelSurfaceStyle")
        defaults.set("future-tint", forKey: "panelTint")
        MainActor.assumeIsolated {
            let restored = AppSettings(defaults: defaults)
            XCTAssertEqual(restored.panelSurfaceStyle, .glass)
            XCTAssertEqual(restored.panelTint, .off)
        }
        XCTAssertEqual(defaults.string(forKey: "panelSurfaceStyle"), "future-surface",
                       "an unknown value from a newer build is not destroyed")
    }

    func testRawValuesAreStableProductWords() {
        XCTAssertEqual(PanelSurfaceStyle.allCases.map(\.rawValue), ["solid", "glass", "frosted"])
        XCTAssertEqual(PanelSurfaceStyle.allCases.map(\.title), ["Solid", "Glass", "Frosted"])
        XCTAssertEqual(PanelTintLevel.allCases.map(\.rawValue), ["off", "subtle", "vivid", "bold"])
        XCTAssertEqual(PanelTintLevel.allCases.map(\.title), ["Off", "Subtle", "Vivid", "Bold"])
        XCTAssertEqual(PanelTintLevel.allCases.map(\.targetColorDifference), [nil, 3, 7, 12])
        XCTAssertEqual(PanelSurfaceStyle.defaultStyle, .glass)
        XCTAssertEqual(PanelTintLevel.defaultLevel, .off)
        XCTAssertEqual(AppearanceMigration.currentSchemaVersion, 2)
        for style in PanelSurfaceStyle.allCases {
            XCTAssertFalse(style.detail.isEmpty)
            XCTAssertFalse(style.detail.localizedCaseInsensitiveContains("glassmorphism"))
        }
    }
}
