import AppKit
import SwiftUI
import XCTest
@testable import Attic

final class SettingsPresentationTests: XCTestCase {
    func testClearIsAvailableOnlyForOriginalAndEffectiveDarkAppearance() {
        for theme in AtticPanelTheme.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let expected: PanelGlassStyle = theme == .original && scheme == .dark ? .clear : .frosted
                XCTAssertEqual(PanelGlassStyle.clear.resolved(for: theme, colorScheme: scheme), expected)
                XCTAssertEqual(PanelGlassStyle.frosted.resolved(for: theme, colorScheme: scheme), .frosted)
                XCTAssertEqual(PanelGlassStyle.glassmorphism.resolved(for: theme, colorScheme: scheme), .glassmorphism)
            }
        }
    }

    @MainActor
    func testUnavailableClearChoiceSurvivesThemeAppearanceChangesAndRelaunch() throws {
        try withSettingsDefaults { defaults in
            defaults.set("clear", forKey: "panelGlassStyle")
            let settings = AppSettings(defaults: defaults)
            settings.appearance = .system
            settings.panelTheme = .original
            // The resolver consumes the effective environment, including a
            // System appearance changing between Light and Dark.
            XCTAssertEqual(settings.panelGlassStyle.resolved(for: settings.panelTheme, colorScheme: .light), .frosted)
            XCTAssertEqual(settings.panelGlassStyle.resolved(for: settings.panelTheme, colorScheme: .dark), .clear)
            settings.panelTheme = .seaGlass
            XCTAssertEqual(settings.panelGlassStyle.resolved(for: settings.panelTheme, colorScheme: .dark), .frosted)
            XCTAssertEqual(settings.panelGlassStyle, .clear)
            XCTAssertEqual(defaults.string(forKey: "panelGlassStyle"), "clear")
            let restored = AppSettings(defaults: defaults)
            restored.panelTheme = .original
            XCTAssertEqual(restored.panelGlassStyle.resolved(for: restored.panelTheme, colorScheme: .dark), .clear)
        }
    }

    @MainActor
    func testGlassDefaultsAndLegacyStableMigrationRemainCompatible() throws {
        try withSettingsDefaults { defaults in
            XCTAssertEqual(AppSettings(defaults: defaults).panelGlassStyle, .clear)
            for raw in ["stable", "liveStable"] {
                defaults.set(raw, forKey: "panelGlassStyle")
                XCTAssertEqual(AppSettings(defaults: defaults).panelGlassStyle, .glassmorphism)
                XCTAssertEqual(defaults.string(forKey: "panelGlassStyle"), "stable")
            }
        }
    }

    @MainActor
    func testGradientPreferencesNormalizeLoadAndPersistCorrectedValues() throws {
        try withSettingsDefaults { defaults in
            XCTAssertEqual(AppSettings(defaults: defaults).panelGradientCoverage, 0.55)
            XCTAssertEqual(AppSettings(defaults: defaults).panelGradientColorHex, "")
            let cases: [(Double, Double)] = [(-2, 0), (2, 1), (.nan, 0.55), (.infinity, 0.55), (0.37, 0.37)]
            for (stored, expected) in cases {
                defaults.set(stored, forKey: "panelGradientCoverage")
                let settings = AppSettings(defaults: defaults)
                XCTAssertEqual(settings.panelGradientCoverage, expected)
                XCTAssertEqual(defaults.double(forKey: "panelGradientCoverage"), expected)
            }
            defaults.set("not a number", forKey: "panelGradientCoverage")
            defaults.set(" \n#a1b2c3 ", forKey: "panelGradientColorHex")
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.panelGradientCoverage, 0.55)
            XCTAssertEqual(settings.panelGradientColorHex, "A1B2C3")
            XCTAssertEqual(defaults.string(forKey: "panelGradientColorHex"), "A1B2C3")
            for invalid in ["#123", "GG1234", "11223344"] {
                defaults.set(invalid, forKey: "panelGradientColorHex")
                XCTAssertEqual(AppSettings(defaults: defaults).panelGradientColorHex, "")
                XCTAssertEqual(defaults.string(forKey: "panelGradientColorHex"), "")
            }
        }
    }

    @MainActor
    func testGradientAssignmentsAndAutomaticResetSurviveRelaunchWithoutChangingTheme() throws {
        try withSettingsDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.panelTheme = .amethyst
            settings.appearance = .light
            for (value, expected) in [(-1.0, 0.0), (5, 1), (.infinity, 0.55)] {
                settings.panelGradientCoverage = value
                XCTAssertEqual(settings.panelGradientCoverage, expected)
                XCTAssertEqual(AppSettings(defaults: defaults).panelGradientCoverage, expected)
            }
            settings.panelGradientCoverage = 0.73
            settings.panelGradientColorHex = " #abcdef "
            let restored = AppSettings(defaults: defaults)
            XCTAssertEqual(restored.panelGradientCoverage, 0.73)
            XCTAssertEqual(restored.panelGradientColorHex, "ABCDEF")
            XCTAssertEqual(restored.panelTheme, .amethyst)
            XCTAssertEqual(restored.appearance, .light)
            settings.panelGradientColorHex = "invalid"
            XCTAssertEqual(AppSettings(defaults: defaults).panelGradientColorHex, "")
            settings.panelGradientColorHex = "123456"
            settings.panelGradientColorHex = ""
            XCTAssertEqual(AppSettings(defaults: defaults).panelGradientColorHex, "")
        }
    }

    @MainActor
    private func withSettingsDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "SettingsPresentationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @MainActor
    func testGradientColorPickerPersistsOpaqueSRGBWithoutAlpha() throws {
        let color = Color(.sRGB, red: 17.0 / 255, green: 128.0 / 255,
                          blue: 238.0 / 255, opacity: 0.2)
        let hex = try XCTUnwrap(AppearanceSettingsPresentation.gradientColorHex(from: color))
        XCTAssertEqual(hex, "1180EE")
        let restored = try XCTUnwrap(AtticThemeColor(hex: hex))
        XCTAssertEqual(restored.red, 17.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(restored.green, 128.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(restored.blue, 238.0 / 255, accuracy: 0.0001)
    }

    @MainActor
    func testGradientColorPickerConvertsNativeGrayscaleAndExtendedRGB() {
        XCTAssertEqual(
            AppearanceSettingsPresentation.gradientColorHex(from: Color(nsColor: NSColor(white: 1, alpha: 1))),
            "FFFFFF"
        )
        XCTAssertEqual(
            AppearanceSettingsPresentation.gradientColorHex(from: Color(nsColor: NSColor(white: 0, alpha: 1))),
            "000000"
        )
        XCTAssertEqual(
            AppearanceSettingsPresentation.gradientColorHex(from: Color(nsColor:
                NSColor(srgbRed: 1.2, green: -0.1, blue: 0, alpha: 1))),
            "FF0000"
        )
    }

    func testPanelThemeChooserHasStablePresentationOrderAndIdentifiers() {
        XCTAssertEqual(
            AppearanceSettingsPresentation.themeChooserAccessibilityIdentifier,
            "setting-panel-theme"
        )
        XCTAssertEqual(
            AppearanceSettingsPresentation.orderedThemeAccessibilityIdentifiers,
            [
                "setting-panel-theme-original",
                "setting-panel-theme-midnightCobalt",
                "setting-panel-theme-porcelainVapor",
                "setting-panel-theme-smokedUmber",
                "setting-panel-theme-electricBlue",
                "setting-panel-theme-seaGlass",
                "setting-panel-theme-amethyst"
            ]
        )
        XCTAssertEqual(
            Set(AppearanceSettingsPresentation.orderedThemeAccessibilityIdentifiers).count,
            AtticPanelTheme.allCases.count
        )
        XCTAssertTrue(AtticPanelTheme.allCases.allSatisfy { !$0.detail.isEmpty })
    }

    func testPanelThemeChooserReservesTwoLinesAndStrengthensHighContrastBoundaries() {
        XCTAssertEqual(AppearanceSettingsPresentation.themeTitleLineLimit, 2)
        XCTAssertGreaterThanOrEqual(AppearanceSettingsPresentation.themeChoiceHeight, 74)
        XCTAssertGreaterThan(
            AppearanceSettingsPresentation.nonselectedThemeBoundaryOpacity(for: .increased),
            AppearanceSettingsPresentation.nonselectedThemeBoundaryOpacity(for: .standard)
        )
        XCTAssertGreaterThan(
            AppearanceSettingsPresentation.nonselectedThemeBoundaryLineWidth(for: .increased),
            AppearanceSettingsPresentation.nonselectedThemeBoundaryLineWidth(for: .standard)
        )
    }

    @MainActor
    func testSystemAccentEnvironmentDefaultsToOriginalBehavior() {
        XCTAssertTrue(EnvironmentValues().atticPanelUsesSystemAccent)
    }

    func testSettingsSectionsHaveStableLocalOnlyOrderAndIdentifiers() {
        XCTAssertEqual(
            SettingsSection.allCases,
            [.general, .panel, .appearance, .agentAccess, .about]
        )
        XCTAssertEqual(SettingsSection.restored(from: "panel"), .panel)
        XCTAssertEqual(SettingsSection.restored(from: "sync"), .general)
        XCTAssertEqual(SettingsSection.restored(from: "unknown"), .general)
        XCTAssertEqual(
            SettingsSection.allCases.map(\.accessibilityIdentifier),
            [
                "settings-nav-general",
                "settings-nav-panel",
                "settings-nav-appearance",
                "settings-nav-agentAccess",
                "settings-nav-about"
            ]
        )
    }

    func testAuthorizationSummaryNeverContainsSensitiveToken() {
        let token = "private-token-that-must-not-be-rendered"
        let prompt = AgentSetupPrompt.make(
            endpoint: "http://127.0.0.1:7335/mcp",
            bearerToken: token
        )

        XCTAssertTrue(prompt.contains(token), "The explicit clipboard setup action still needs the token.")
        XCTAssertFalse(AgentSetupPrompt.authorizationSummary.contains(token))
        XCTAssertFalse(AgentSetupPrompt.authorizationSummary.localizedCaseInsensitiveContains("bearer"))
    }

    func testConditionalSettingsRowsFollowTheirRealState() {
        XCTAssertFalse(SettingsVisibility.showsLoginApproval(requiresApproval: false))
        XCTAssertTrue(SettingsVisibility.showsLoginApproval(requiresApproval: true))

        XCTAssertFalse(SettingsVisibility.showsAgentConnection(isEnabled: false))
        XCTAssertTrue(SettingsVisibility.showsAgentConnection(isEnabled: true))
    }

    func testWindowUsesPreferredSizeWhenScreenHasRoom() {
        let size = SettingsWindowLayout.fittedContentSize(
            to: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(size.width, SettingsWindowLayout.preferredContentSize.width)
        XCTAssertEqual(size.height, SettingsWindowLayout.preferredContentSize.height)
    }

    func testWindowFitsCompactVisibleFrameWithoutDroppingBelowMinimum() {
        let size = SettingsWindowLayout.fittedContentSize(
            to: NSRect(x: 0, y: 0, width: 680, height: 520)
        )

        XCTAssertEqual(size.width, SettingsWindowLayout.minimumContentSize.width)
        XCTAssertEqual(size.height, 472)
    }
}
