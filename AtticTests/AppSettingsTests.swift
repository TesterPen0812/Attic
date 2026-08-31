import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Attic

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testUnitTestRuntimeUsesIsolatedDefaultsAndDisablesInteractiveShell() {
        let isolatedSuite = "AppRuntimeTests.\(UUID().uuidString)"
        let standardSuite = "AppRuntimeStandardSentinel.\(UUID().uuidString)"
        let simulatedStandard = UserDefaults(suiteName: standardSuite)!
        defer {
            simulatedStandard.removePersistentDomain(forName: standardSuite)
            UserDefaults(suiteName: isolatedSuite)?
                .removePersistentDomain(forName: isolatedSuite)
        }
        simulatedStandard.set("untouched", forKey: "sentinel")
        let runtime = AppRuntimeEnvironment(
            environment: [
                "ATTIC_TESTING": "1",
                "ATTIC_TEST_DEFAULTS_SUITE": isolatedSuite
            ],
            processIdentifier: 42
        )

        XCTAssertTrue(runtime.isRunningTests)
        XCTAssertTrue(runtime.isUnitTestHost)
        XCTAssertFalse(runtime.shouldStartInteractiveShellServices)
        let resolved = runtime.makeSettingsDefaults(standard: simulatedStandard)
        XCTAssertFalse(resolved === simulatedStandard)
        _ = AppSettings(defaults: resolved)

        XCTAssertEqual(simulatedStandard.string(forKey: "sentinel"), "untouched")
        XCTAssertNil(simulatedStandard.object(forKey: "hasAdoptedInstantRevealV3"))
        XCTAssertTrue(resolved.bool(forKey: "hasAdoptedInstantRevealV3"))
    }

    func testUIRuntimeKeepsInteractiveServicesAndItsBundleDefaults() {
        let standardSuite = "AppRuntimeUI.\(UUID().uuidString)"
        let simulatedStandard = UserDefaults(suiteName: standardSuite)!
        defer { simulatedStandard.removePersistentDomain(forName: standardSuite) }
        let runtime = AppRuntimeEnvironment(
            environment: [
                "ATTIC_TESTING": "1",
                "ATTIC_UI_TESTING": "1"
            ],
            processIdentifier: 43
        )

        XCTAssertTrue(runtime.isUITesting)
        XCTAssertFalse(runtime.isUnitTestHost)
        XCTAssertTrue(runtime.shouldStartInteractiveShellServices)
        XCTAssertTrue(runtime.makeSettingsDefaults(standard: simulatedStandard) === simulatedStandard)
    }

    @MainActor
    func testTestHostAttachmentEnvironmentCannotReconcileOutsideItsTempRoot() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppRuntimeAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let outsideRoot = parent.appendingPathComponent("outside", isDirectory: true)
        let isolatedRoot = parent.appendingPathComponent("isolated", isDirectory: true)
        let ownerToken = UUID().uuidString
        let sentinel = outsideRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("deadbeef", isDirectory: true)
            .appendingPathComponent("sentinel.txt")
        try FileManager.default.createDirectory(
            at: sentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sentinelData = Data("must survive hosted unit startup".utf8)
        try sentinelData.write(to: sentinel)
        try FileManager.default.createDirectory(
            at: isolatedRoot,
            withIntermediateDirectories: true
        )
        try Data(ownerToken.utf8).write(
            to: isolatedRoot.appendingPathComponent(
                AppRuntimeEnvironment.testAttachmentRootOwnerMarkerName
            )
        )

        let runtime = AppRuntimeEnvironment(
            environment: [
                "ATTIC_TESTING": "1",
                "ATTIC_TEST_ATTACHMENT_ROOT": isolatedRoot.path,
                "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN": ownerToken
            ],
            processIdentifier: 44,
            testRunIdentifier: "sentinel"
        )
        XCTAssertEqual(runtime.attachmentRootURL(), isolatedRoot.standardizedFileURL)
        let container = try PersistenceController.makeContainer(
            inMemory: true,
            cloudSyncEnabled: false
        )
        let store = NoteStore(
            container: container,
            attachmentFileStore: try XCTUnwrap(runtime.makeAttachmentFileStore())
        )
        XCTAssertTrue(store.notes.isEmpty)

        let stagingRoot = isolatedRoot.appendingPathComponent(".staging", isDirectory: true)
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: stagingRoot.path),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingRoot.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outsideRoot.appendingPathComponent(".staging").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outsideRoot.appendingPathComponent("Thumbnails").path
        ))
    }

    func testTestHostRejectsUnownedExplicitAttachmentRoot() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppRuntimeUnownedAttachmentTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let unowned = parent.appendingPathComponent("unowned", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unowned,
            withIntermediateDirectories: true
        )

        let runtime = AppRuntimeEnvironment(
            environment: [
                "ATTIC_TESTING": "1",
                "ATTIC_TEST_ATTACHMENT_ROOT": unowned.path,
                "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN": "missing-marker"
            ],
            processIdentifier: 45,
            testRunIdentifier: "fallback"
        )
        XCTAssertNil(runtime.attachmentRootURL())
    }

    private struct QuantizedColor: Hashable, CustomStringConvertible {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        var description: String { "\(red)/\(green)/\(blue)" }
    }

    private struct QuantizedThemeSignature: Hashable, CustomStringConvertible {
        let surface: QuantizedColor
        let accent: QuantizedColor

        var description: String { "surface \(surface), accent \(accent)" }
    }

    func testPanelThemeCatalogHasStableOrderTitlesAndRawValues() {
        XCTAssertEqual(AtticPanelTheme.allCases, [
            .original,
            .midnightCobalt,
            .porcelainVapor,
            .smokedUmber,
            .electricBlue,
            .seaGlass,
            .amethyst
        ])
        XCTAssertEqual(AtticPanelTheme.allCases.map(\.title), [
            "Original",
            "Midnight Cobalt",
            "Porcelain Vapor",
            "Smoked Umber",
            "Electric Blue",
            "Sea Glass",
            "Amethyst"
        ])
        XCTAssertEqual(AtticPanelTheme.allCases.map(\.rawValue), [
            "original",
            "midnightCobalt",
            "porcelainVapor",
            "smokedUmber",
            "electricBlue",
            "seaGlass",
            "amethyst"
        ])
        XCTAssertEqual(
            Set(AtticPanelTheme.allCases.map(\.rawValue)).count,
            AtticPanelTheme.allCases.count
        )
        XCTAssertEqual(AtticPanelTheme.defaultTheme, .original)
    }

    @MainActor
    func testPanelThemeDefaultsToOriginalWithoutWritingAMigration() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: "panelTheme"))

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.panelTheme, .original)
        XCTAssertNil(defaults.object(forKey: "panelTheme"))
    }

    @MainActor
    func testEveryPanelThemeRoundTripsThroughUserDefaults() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        for theme in AtticPanelTheme.allCases {
            settings.panelTheme = theme

            XCTAssertEqual(defaults.string(forKey: "panelTheme"), theme.rawValue)
            XCTAssertEqual(AppSettings(defaults: defaults).panelTheme, theme)
        }
    }

    @MainActor
    func testInvalidPanelThemeFallsBackWithoutDestroyingStoredValue() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("future-theme-from-a-newer-build", forKey: "panelTheme")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.panelTheme, .original)
        XCTAssertEqual(
            defaults.string(forKey: "panelTheme"),
            "future-theme-from-a-newer-build"
        )
    }

    @MainActor
    func testPanelThemeIsIndependentFromAppearanceAndGlassPreferences() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearancePreference.dark.rawValue, forKey: "appearancePreference")
        defaults.set(PanelGlassStyle.frosted.rawValue, forKey: "panelGlassStyle")
        defaults.set(false, forKey: "isTranslucent")

        let settings = AppSettings(defaults: defaults)
        settings.panelTheme = .seaGlass

        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(settings.panelGlassStyle, .frosted)
        XCTAssertFalse(settings.isTranslucent)
        XCTAssertEqual(defaults.string(forKey: "appearancePreference"), "dark")
        XCTAssertEqual(defaults.string(forKey: "panelGlassStyle"), "frosted")
        XCTAssertEqual(defaults.object(forKey: "isTranslucent") as? Bool, false)

        settings.appearance = .light
        settings.panelGlassStyle = .glassmorphism
        settings.isTranslucent = true

        XCTAssertEqual(settings.panelTheme, .seaGlass)
        XCTAssertEqual(defaults.string(forKey: "panelTheme"), "seaGlass")
    }

    func testPanelThemeTokensAreFiniteInRangeAndRestrained() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for contrast in colorSchemeContrasts {
                    let palette = theme.palette(
                        for: appearance,
                        contrast: contrast
                    )
                    let context = themeContext(theme, appearance, contrast)

                    XCTAssertTrue(palette.isValid, context)
                    XCTAssertLessThanOrEqual(palette.clearTintOpacity, 0.08, context)
                    XCTAssertLessThanOrEqual(palette.frostedTintOpacity, 0.24, context)
                    XCTAssertLessThanOrEqual(palette.glassmorphismTintOpacity, 0.045, context)

                    // The accent forms graphical control boundaries and needs
                    // 3:1 against opaque surfaces; it is not a text color.
                    XCTAssertGreaterThanOrEqual(
                        palette.accent.contrastRatio(with: palette.opaqueSurface),
                        3,
                        context
                    )
                }
            }
        }
    }

    func testIncreasedContrastStrengthensOnlyLocalEdgesAndSelection() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                let standard = theme.palette(for: appearance, contrast: .standard)
                let increased = theme.palette(for: appearance, contrast: .increased)
                let context = "\(theme.rawValue) \(appearance.rawValue)"

                XCTAssertEqual(increased.accent, standard.accent, context)
                XCTAssertEqual(increased.opaqueSurface, standard.opaqueSurface, context)
                XCTAssertEqual(increased.surfaceTint, standard.surfaceTint, context)
                XCTAssertEqual(increased.clearTintOpacity, standard.clearTintOpacity, context)
                XCTAssertEqual(increased.frostedTintOpacity, standard.frostedTintOpacity, context)
                XCTAssertEqual(
                    increased.glassmorphismTintOpacity,
                    standard.glassmorphismTintOpacity,
                    context
                )
                XCTAssertGreaterThan(increased.selectedFillOpacity, standard.selectedFillOpacity, context)
                XCTAssertGreaterThan(increased.selectedStrokeOpacity, standard.selectedStrokeOpacity, context)
                XCTAssertGreaterThanOrEqual(
                    increased.edgeTint.contrastRatio(with: increased.opaqueSurface),
                    standard.edgeTint.contrastRatio(with: standard.opaqueSurface),
                    context
                )
            }
        }
    }

    func testAlphaCompositedSurfaceBoundariesStrengthenInIncreasedContrast() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in AtticPanelSurfaceTreatment.Kind.allCases {
                    let standard = treatment(
                        for: theme,
                        appearance: appearance,
                        contrast: .standard,
                        kind: kind
                    )
                    let increased = treatment(
                        for: theme,
                        appearance: appearance,
                        contrast: .increased,
                        kind: kind
                    )
                    let standardSurface = visibleSurface(
                        for: standard,
                        appearance: appearance
                    )
                    let increasedSurface = visibleSurface(
                        for: increased,
                        appearance: appearance
                    )
                    let standardBoundary = composite(
                        standard.palette.edgeTint,
                        opacity: standard.surfaceEdgeOpacity(for: .standard),
                        over: standardSurface
                    )
                    let increasedBoundary = composite(
                        increased.palette.edgeTint,
                        opacity: increased.surfaceEdgeOpacity(for: .increased),
                        over: increasedSurface
                    )
                    let standardRatio = standardBoundary.contrastRatio(with: standardSurface)
                    let increasedRatio = increasedBoundary.contrastRatio(with: increasedSurface)
                    let context = "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue)"

                    XCTAssertEqual(increasedSurface, standardSurface, context)
                    XCTAssertGreaterThan(increasedRatio, standardRatio, context)
                    XCTAssertGreaterThanOrEqual(increasedRatio, standardRatio + 0.02, context)
                }
            }
        }
    }

    func testSurfaceEdgeMetricsPreserveExistingProductionConstants() {
        let original = treatment(
            for: .original,
            appearance: .light,
            contrast: .standard,
            kind: .opaque
        )
        XCTAssertEqual(original.surfaceEdgeOpacity(for: .standard), 0.11)
        XCTAssertEqual(
            original.surfaceEdgeOpacity(for: .increased),
            0.21,
            accuracy: 0.000_000_001
        )

        let originalGlassmorphism = treatment(
            for: .original,
            appearance: .light,
            contrast: .standard,
            kind: .glassmorphism
        )
        XCTAssertEqual(
            originalGlassmorphism.surfaceEdgeOpacity(for: .standard),
            0.055
        )
        XCTAssertEqual(
            originalGlassmorphism.surfaceEdgeOpacity(for: .increased),
            0.155,
            accuracy: 0.000_000_001
        )

        let expectedCustomOpacities: [AtticPanelSurfaceTreatment.Kind: Double] = [
            .opaque: 0.18,
            .clearGlass: 0.22,
            .frostedGlass: 0.20,
            .glassmorphism: 0.17
        ]
        for (kind, expectedOpacity) in expectedCustomOpacities {
            let custom = treatment(
                for: .midnightCobalt,
                appearance: .dark,
                contrast: .standard,
                kind: kind
            )
            XCTAssertEqual(
                custom.surfaceEdgeOpacity(for: .standard),
                expectedOpacity,
                kind.rawValue
            )
            XCTAssertEqual(
                custom.surfaceEdgeOpacity(for: .increased),
                expectedOpacity + 0.14,
                accuracy: 0.000_000_001,
                kind.rawValue
            )
        }

        XCTAssertEqual(original.surfaceEdgeLineWidth(for: .standard), 0.75)
        XCTAssertEqual(original.surfaceEdgeLineWidth(for: .increased), 1)
    }

    func testOriginalThemeKeepsTheExistingAccentAndSurfaceContract() {
        let expectedAccent = AtticThemeColor(red: 0.116, green: 0.478, blue: 0.980)
        let light = AtticPanelTheme.original.palette(
            for: AtticPanelThemeAppearance.light
        )
        let dark = AtticPanelTheme.original.palette(
            for: AtticPanelThemeAppearance.dark
        )

        XCTAssertTrue(AtticPanelTheme.original.usesSystemAccent)
        XCTAssertTrue(AtticPanelTheme.allCases.dropFirst().allSatisfy {
            !$0.usesSystemAccent
        })
        XCTAssertEqual(light.accent, expectedAccent)
        XCTAssertEqual(dark.accent, expectedAccent)
        XCTAssertEqual(light.surfaceTint, AtticThemeColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(dark.surfaceTint, AtticThemeColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(light.clearTintOpacity, 0.08)
        XCTAssertEqual(dark.clearTintOpacity, 0.06)
        XCTAssertEqual(light.frostedTintOpacity, 0.24)
        XCTAssertEqual(dark.frostedTintOpacity, 0.22)
        XCTAssertEqual(light.glassmorphismTintOpacity, 0)
        XCTAssertEqual(dark.glassmorphismTintOpacity, 0)
    }

    func testPanelThemesAdaptToEffectiveColorScheme() {
        for theme in AtticPanelTheme.allCases {
            let light = theme.palette(for: AtticPanelThemeAppearance.light)
            let dark = theme.palette(for: AtticPanelThemeAppearance.dark)

            XCTAssertEqual(theme.palette(for: ColorScheme.light), light)
            XCTAssertEqual(theme.palette(for: ColorScheme.dark), dark)
            XCTAssertEqual(
                theme.palette(for: ColorScheme.light, contrast: .standard),
                light
            )
            XCTAssertEqual(
                theme.palette(for: ColorScheme.dark, contrast: .standard),
                dark
            )
            XCTAssertNotEqual(light, dark, theme.rawValue)
            XCTAssertGreaterThan(
                light.opaqueSurface.relativeLuminance,
                dark.opaqueSurface.relativeLuminance,
                theme.rawValue
            )
        }
    }

    func testPanelThemeIdentityIsQuantizedDistinctInEveryVisibleSurfaceState() {
        for contrast in colorSchemeContrasts {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in AtticPanelSurfaceTreatment.Kind.allCases {
                    let entries = AtticPanelTheme.allCases.map { theme in
                        let treatment = treatment(
                            for: theme,
                            appearance: appearance,
                            contrast: contrast,
                            kind: kind
                        )
                        return (
                            theme,
                            QuantizedThemeSignature(
                                surface: quantized(
                                    visibleSurface(
                                        for: treatment,
                                        appearance: appearance
                                    )
                                ),
                                accent: quantized(treatment.palette.accent)
                            )
                        )
                    }
                    let signatures = Set(entries.map(\.1))
                    let context = entries.map { "\($0.0.rawValue)=\($0.1)" }.joined(separator: ", ")

                    XCTAssertEqual(
                        signatures.count,
                        AtticPanelTheme.allCases.count,
                        "Theme identity collision in \(appearance.rawValue) \(kind.rawValue) "
                            + "\(contrastName(contrast)): \(context)"
                    )
                }
            }
        }
    }

    func testCustomThemeSurfacesAreQuantizedDistinctInEveryVisibleSurfaceState() {
        let customThemes = AtticPanelTheme.allCases.filter { $0 != .original }

        for contrast in colorSchemeContrasts {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in AtticPanelSurfaceTreatment.Kind.allCases {
                    let entries = customThemes.map { theme in
                        let surface = visibleSurface(
                            for: treatment(
                                for: theme,
                                appearance: appearance,
                                contrast: contrast,
                                kind: kind
                            ),
                            appearance: appearance
                        )
                        return (theme, quantized(surface))
                    }
                    let surfaces = Set(entries.map(\.1))
                    let context = entries.map { "\($0.0.rawValue)=\($0.1)" }.joined(separator: ", ")

                    XCTAssertEqual(
                        surfaces.count,
                        customThemes.count,
                        "Custom surface collision in \(appearance.rawValue) \(kind.rawValue) "
                            + "\(contrastName(contrast)): \(context)"
                    )
                }
            }
        }
    }

    func testMidnightElectricAndPorcelainFamiliesKeepTheirVisualRoles() {
        let midnightDark = AtticPanelTheme.midnightCobalt.palette(
            for: AtticPanelThemeAppearance.dark
        )
        let midnightLight = AtticPanelTheme.midnightCobalt.palette(
            for: AtticPanelThemeAppearance.light
        )
        let electricDark = AtticPanelTheme.electricBlue.palette(
            for: AtticPanelThemeAppearance.dark
        )
        let electricLight = AtticPanelTheme.electricBlue.palette(
            for: AtticPanelThemeAppearance.light
        )
        let porcelainLight = AtticPanelTheme.porcelainVapor.palette(
            for: AtticPanelThemeAppearance.light
        )

        XCTAssertGreaterThan(
            midnightDark.opaqueSurface.blue
                - max(midnightDark.opaqueSurface.red, midnightDark.opaqueSurface.green),
            0.08
        )
        XCTAssertGreaterThan(
            midnightLight.opaqueSurface.blue - midnightLight.opaqueSurface.red,
            0.04
        )
        XCTAssertLessThan(channelSpread(electricDark.opaqueSurface), 0.03)
        XCTAssertLessThan(channelSpread(electricLight.opaqueSurface), 0.02)
        XCTAssertLessThan(channelSpread(porcelainLight.opaqueSurface), 0.02)
        XCTAssertGreaterThan(
            porcelainLight.surfaceTint.blue - porcelainLight.surfaceTint.red,
            0.08
        )
    }

    func testSmokedUmberAccentDoesNotReuseMediumPrioritySystemOrangeHue() throws {
        let systemOrange = try XCTUnwrap(NSColor.systemOrange.usingColorSpace(.sRGB))
        let mediumPriorityHue = hue(
            of: AtticThemeColor(
                red: systemOrange.redComponent,
                green: systemOrange.greenComponent,
                blue: systemOrange.blueComponent
            )
        )

        for appearance in AtticPanelThemeAppearance.allCases {
            let smokedUmberHue = hue(
                of: AtticPanelTheme.smokedUmber.palette(for: appearance).accent
            )
            XCTAssertGreaterThanOrEqual(
                circularHueDistance(smokedUmberHue, mediumPriorityHue),
                0.025,
                "Smoked Umber reuses medium-priority orange in \(appearance.rawValue)"
            )
        }
    }

    func testPanelSurfaceTreatmentCoversEveryStateCombination() {
        var combinationCount = 0
        let schemes: [(ColorScheme, AtticPanelThemeAppearance)] = [
            (.light, .light),
            (.dark, .dark)
        ]

        for theme in AtticPanelTheme.allCases {
            for (colorScheme, appearance) in schemes {
                for contrast in colorSchemeContrasts {
                    for isTranslucent in [false, true] {
                        for style in PanelGlassStyle.allCases {
                            for reduceTransparency in [false, true] {
                                combinationCount += 1
                                let treatment = theme.surfaceTreatment(
                                    colorScheme: colorScheme,
                                    contrast: contrast,
                                    glassStyle: style,
                                    isTranslucent: isTranslucent,
                                    reduceTransparency: reduceTransparency
                                )
                                let expectedKind: AtticPanelSurfaceTreatment.Kind
                                if !isTranslucent || reduceTransparency {
                                    expectedKind = .opaque
                                } else {
                                    switch style {
                                    case .clear: expectedKind = .clearGlass
                                    case .frosted: expectedKind = .frostedGlass
                                    case .glassmorphism: expectedKind = .glassmorphism
                                    }
                                }

                                XCTAssertEqual(treatment.kind, expectedKind)
                                XCTAssertEqual(
                                    treatment.palette,
                                    theme.palette(for: appearance, contrast: contrast)
                                )
                                XCTAssertEqual(
                                    treatment.usesSystemOpaqueSurface,
                                    theme == .original
                                )
                                XCTAssertTrue(treatment.tintOpacity.isFinite)
                                XCTAssertTrue((0...1).contains(treatment.tintOpacity))
                                if expectedKind == .opaque {
                                    XCTAssertEqual(treatment.tintOpacity, 0)
                                }
                            }
                        }
                    }
                }
            }
        }

        XCTAssertEqual(
            combinationCount,
            AtticPanelTheme.allCases.count
                * AtticPanelThemeAppearance.allCases.count
                * 2
                * colorSchemeContrasts.count
                * PanelGlassStyle.allCases.count
                * 2
        )
    }

    func testOpaqueAndReducedTransparencyTreatmentsIgnoreGlassStyle() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for contrast in colorSchemeContrasts {
                    let opaqueTreatments = PanelGlassStyle.allCases.map { style in
                        theme.surfaceTreatment(
                            appearance: appearance,
                            contrast: contrast,
                            glassStyle: style,
                            isTranslucent: false,
                            reduceTransparency: false
                        )
                    }
                    let reducedTreatments = PanelGlassStyle.allCases.map { style in
                        theme.surfaceTreatment(
                            appearance: appearance,
                            contrast: contrast,
                            glassStyle: style,
                            isTranslucent: true,
                            reduceTransparency: true
                        )
                    }

                    XCTAssertTrue(opaqueTreatments.dropFirst().allSatisfy {
                        $0 == opaqueTreatments[0]
                    })
                    XCTAssertTrue(reducedTreatments.dropFirst().allSatisfy {
                        $0 == reducedTreatments[0]
                    })
                    XCTAssertEqual(opaqueTreatments[0], reducedTreatments[0])

                    let opaqueEdgeOpacities = opaqueTreatments.map {
                        $0.surfaceEdgeOpacity(for: contrast)
                    }
                    let reducedEdgeOpacities = reducedTreatments.map {
                        $0.surfaceEdgeOpacity(for: contrast)
                    }
                    XCTAssertTrue(opaqueEdgeOpacities.dropFirst().allSatisfy {
                        $0 == opaqueEdgeOpacities[0]
                    })
                    XCTAssertTrue(reducedEdgeOpacities.dropFirst().allSatisfy {
                        $0 == reducedEdgeOpacities[0]
                    })
                    XCTAssertEqual(opaqueEdgeOpacities, reducedEdgeOpacities)
                }
            }
        }
    }

    func testClearGlassReadabilityUsesEffectiveSurfaceState() {
        XCTAssertTrue(AtticClearGlassReadabilityPolicy.isEnabled(
            isTranslucent: true,
            isClearStyle: true,
            reduceTransparency: false
        ))
        XCTAssertFalse(AtticClearGlassReadabilityPolicy.isEnabled(
            isTranslucent: false,
            isClearStyle: true,
            reduceTransparency: false
        ))
        XCTAssertFalse(AtticClearGlassReadabilityPolicy.isEnabled(
            isTranslucent: true,
            isClearStyle: false,
            reduceTransparency: false
        ))
        XCTAssertFalse(AtticClearGlassReadabilityPolicy.isEnabled(
            isTranslucent: true,
            isClearStyle: true,
            reduceTransparency: true
        ))
    }

    @MainActor
    func testGlassStyleDefaultsToClearAndPersists() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppSettings(defaults: defaults)
        XCTAssertEqual(initial.panelGlassStyle, .clear)

        for style in PanelGlassStyle.allCases {
            initial.panelGlassStyle = style
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertEqual(reloaded.panelGlassStyle, style)
        }
    }

    func testGlassStylesAreUniqueAndUseProductNames() {
        XCTAssertEqual(PanelGlassStyle.allCases.map(\.title), [
            "Clear",
            "Frosted",
            "Glassmorphism"
        ])
        XCTAssertEqual(Set(PanelGlassStyle.allCases.map(\.rawValue)).count, 3)
        XCTAssertEqual(PanelGlassStyle.glassmorphism.rawValue, "stable")
    }

    @MainActor
    func testLegacyLiveStablePreferenceMigratesToGlassmorphism() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("liveStable", forKey: "panelGlassStyle")
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.panelGlassStyle, .glassmorphism)
        XCTAssertEqual(defaults.string(forKey: "panelGlassStyle"), "stable")
    }

    @MainActor
    func testInvalidGlassStyleFallsBackToClear() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("unknown-style", forKey: "panelGlassStyle")
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.panelGlassStyle, .clear)
    }

    @MainActor
    func testNonFiniteStoredDelaysUseSafeFallbacks() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        markDelayMigrationsComplete(in: defaults)
        defaults.set(Double.nan, forKey: "revealDelay")
        defaults.set(Double.infinity, forKey: "hideDelay")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.revealDelay, 0.2)
        XCTAssertEqual(settings.hideDelay, 0.3)
        XCTAssertTrue(settings.revealDelay.isFinite)
        XCTAssertTrue(settings.hideDelay.isFinite)
    }

    @MainActor
    func testNonFiniteAssignedDelaysAreSanitizedAndPersisted() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        markDelayMigrationsComplete(in: defaults)
        let settings = AppSettings(defaults: defaults)

        settings.revealDelay = .infinity
        settings.hideDelay = .nan

        XCTAssertEqual(settings.revealDelay, 0.2)
        XCTAssertEqual(settings.hideDelay, 0.3)
        XCTAssertEqual(defaults.double(forKey: "revealDelay"), 0.2)
        XCTAssertEqual(defaults.double(forKey: "hideDelay"), 0.3)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func markDelayMigrationsComplete(in defaults: UserDefaults) {
        defaults.set(true, forKey: "hasAdoptedFasterReveal")
        defaults.set(true, forKey: "hasAdoptedQuickerRevealV2")
        defaults.set(true, forKey: "hasAdoptedInstantRevealV3")
    }

    private func channelSpread(_ color: AtticThemeColor) -> Double {
        let channels = [color.red, color.green, color.blue]
        return (channels.max() ?? 0) - (channels.min() ?? 0)
    }

    private var colorSchemeContrasts: [ColorSchemeContrast] {
        [.standard, .increased]
    }

    private func treatment(
        for theme: AtticPanelTheme,
        appearance: AtticPanelThemeAppearance,
        contrast: ColorSchemeContrast,
        kind: AtticPanelSurfaceTreatment.Kind
    ) -> AtticPanelSurfaceTreatment {
        let style: PanelGlassStyle
        let isTranslucent: Bool
        switch kind {
        case .opaque:
            style = .clear
            isTranslucent = false
        case .clearGlass:
            style = .clear
            isTranslucent = true
        case .frostedGlass:
            style = .frosted
            isTranslucent = true
        case .glassmorphism:
            style = .glassmorphism
            isTranslucent = true
        }

        return theme.surfaceTreatment(
            appearance: appearance,
            contrast: contrast,
            glassStyle: style,
            isTranslucent: isTranslucent,
            reduceTransparency: false
        )
    }

    private func visibleSurface(
        for treatment: AtticPanelSurfaceTreatment,
        appearance: AtticPanelThemeAppearance
    ) -> AtticThemeColor {
        if treatment.kind == .opaque {
            return treatment.palette.opaqueSurface
        }
        return composite(
            treatment.palette.surfaceTint,
            opacity: treatment.tintOpacity,
            over: representativeBackdrop(for: appearance)
        )
    }

    private func representativeBackdrop(
        for appearance: AtticPanelThemeAppearance
    ) -> AtticThemeColor {
        appearance == .dark
            ? AtticThemeColor(red: 0.18, green: 0.18, blue: 0.18)
            : AtticThemeColor(red: 0.82, green: 0.82, blue: 0.82)
    }

    private func composite(
        _ foreground: AtticThemeColor,
        opacity: Double,
        over background: AtticThemeColor
    ) -> AtticThemeColor {
        background.mixed(with: foreground, amount: opacity)
    }

    private func quantized(_ color: AtticThemeColor) -> QuantizedColor {
        QuantizedColor(
            red: quantized(color.red),
            green: quantized(color.green),
            blue: quantized(color.blue)
        )
    }

    private func quantized(_ component: Double) -> UInt8 {
        UInt8((min(max(component, 0), 1) * 255).rounded())
    }

    private func hue(of color: AtticThemeColor) -> Double {
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        let delta = maximum - minimum
        guard delta > 0 else { return 0 }

        let hueSector: Double
        if maximum == color.red {
            hueSector = ((color.green - color.blue) / delta)
                .truncatingRemainder(dividingBy: 6)
        } else if maximum == color.green {
            hueSector = ((color.blue - color.red) / delta) + 2
        } else {
            hueSector = ((color.red - color.green) / delta) + 4
        }

        let normalizedHue = hueSector / 6
        return normalizedHue < 0 ? normalizedHue + 1 : normalizedHue
    }

    private func circularHueDistance(_ first: Double, _ second: Double) -> Double {
        let directDistance = abs(first - second)
        return min(directDistance, 1 - directDistance)
    }

    private func contrastName(_ contrast: ColorSchemeContrast) -> String {
        contrast == .increased ? "increased" : "standard"
    }

    private func themeContext(
        _ theme: AtticPanelTheme,
        _ appearance: AtticPanelThemeAppearance,
        _ contrast: ColorSchemeContrast
    ) -> String {
        "\(theme.rawValue) \(appearance.rawValue) \(contrastName(contrast))"
    }
}
