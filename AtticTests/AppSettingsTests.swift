import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Attic

final class AppSettingsTests: XCTestCase {
    func testTerminationVetoPreservesCanvasWork() {
        var events: [String] = []

        let canTerminate = AppTerminationPreparation.prepare(
            flushNoteDraft: {
                events.append("note-flush")
                return false
            },
            commitCanvasTermination: {
                events.append("canvas-termination")
            }
        )

        XCTAssertFalse(canTerminate)
        XCTAssertEqual(events, ["note-flush"])
    }

    func testSuccessfulTerminationCommitsCanvasAfterNoteFlush() {
        var events: [String] = []

        let canTerminate = AppTerminationPreparation.prepare(
            flushNoteDraft: {
                events.append("note-flush")
                return true
            },
            commitCanvasTermination: {
                events.append("canvas-termination")
            }
        )

        XCTAssertTrue(canTerminate)
        XCTAssertEqual(events, ["note-flush", "canvas-termination"])
    }

    func testUIHostsUseEphemeralAgentCredentialsWithoutXCTestEnvironmentKeys() {
        XCTAssertTrue(AppRuntimeEnvironment(environment: ["ATTIC_UI_TESTING": "1"]).usesEphemeralAgentCredential)
        XCTAssertTrue(AppRuntimeEnvironment(environment: ["ATTIC_TESTING": "1"]).usesEphemeralAgentCredential)
        XCTAssertTrue(AppRuntimeEnvironment(environment: ["XCTestBundlePath": "/test"]).usesEphemeralAgentCredential)
        XCTAssertFalse(AppRuntimeEnvironment(environment: [:]).usesEphemeralAgentCredential)
    }
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
        XCTAssertNil(runtime.noteRecoveryURL)
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
        XCTAssertNil(runtime.noteRecoveryURL)
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
                    XCTAssertLessThanOrEqual(palette.frostedTintOpacity, 0.045, context)

                    // The accent forms graphical control boundaries and needs
                    // 3:1 against opaque surfaces; it is not a text color.
                    XCTAssertGreaterThanOrEqual(
                        palette.accent.contrastRatio(with: palette.opaqueSurface),
                        3,
                        context
                    )
                    XCTAssertGreaterThanOrEqual(
                        palette.accent.contrastingForeground.contrastRatio(with: palette.accent),
                        4.5,
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
                XCTAssertEqual(increased.frostedTintOpacity, standard.frostedTintOpacity, context)
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

    func testSurfaceEdgeIsOneHairlinePerPaletteFamilyOnEverySurface() {
        // One semantic hairline per family: Original strokes `Color.primary`
        // at one strength, custom palettes stroke `edgeTint` at another, and
        // the number never changes with the surface kind, the appearance or
        // the host window. Increased Contrast adds exactly one step.
        for appearance in AtticPanelThemeAppearance.allCases {
            for kind in AtticPanelSurfaceTreatment.Kind.allCases {
                let original = treatment(for: .original, appearance: appearance, contrast: .standard, kind: kind)
                XCTAssertEqual(original.surfaceEdgeOpacity(for: .standard),
                               AtticPanelSurfaceTreatment.originalEdgeOpacity, kind.rawValue)
                XCTAssertEqual(original.surfaceEdgeOpacity(for: .increased),
                               AtticPanelSurfaceTreatment.originalEdgeOpacity
                                   + AtticPanelSurfaceTreatment.originalIncreasedContrastEdgeStep,
                               accuracy: 0.000_000_001, kind.rawValue)
                for theme in AtticPanelTheme.allCases where theme != .original {
                    let custom = treatment(for: theme, appearance: appearance, contrast: .standard, kind: kind)
                    XCTAssertEqual(custom.surfaceEdgeOpacity(for: .standard),
                                   AtticPanelSurfaceTreatment.customEdgeOpacity, "\(theme.rawValue) \(kind.rawValue)")
                    XCTAssertEqual(custom.surfaceEdgeOpacity(for: .increased),
                                   AtticPanelSurfaceTreatment.customEdgeOpacity
                                       + AtticPanelSurfaceTreatment.customIncreasedContrastEdgeStep,
                                   accuracy: 0.000_000_001, "\(theme.rawValue) \(kind.rawValue)")
                }
            }
        }
        XCTAssertEqual(AtticPanelSurfaceTreatment.originalEdgeOpacity, 0.09)
        XCTAssertEqual(AtticPanelSurfaceTreatment.customEdgeOpacity, 0.19)
        XCTAssertEqual(AtticPanelSurfaceTreatment.originalIncreasedContrastEdgeStep, 0.10)
        XCTAssertEqual(AtticPanelSurfaceTreatment.customIncreasedContrastEdgeStep, 0.14)

        let original = treatment(for: .original, appearance: .light, contrast: .standard, kind: .solid)
        XCTAssertEqual(original.surfaceEdgeLineWidth(for: .standard), 0.75)
        XCTAssertEqual(original.surfaceEdgeLineWidth(for: .increased), 1)
    }

    func testEverySurfaceReceivesTheSameShapeElevation() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for contrast in colorSchemeContrasts {
                    for kind in AtticPanelSurfaceTreatment.Kind.allCases {
                        let surface = treatment(for: theme, appearance: appearance, contrast: contrast, kind: kind)
                        XCTAssertEqual(
                            surface.surfaceElevation,
                            appearance == .dark ? .dark : .light,
                            "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue)"
                        )
                    }
                }
            }
        }

        let light = AtticPanelSurfaceElevation.light
        let dark = AtticPanelSurfaceElevation.dark
        // Broad, soft, low opacity, nearly no offset, no dark halo.
        XCTAssertLessThanOrEqual(light.opacity, 0.12)
        XCTAssertLessThan(light.opacity, dark.opacity)
        XCTAssertLessThanOrEqual(dark.opacity, 0.35)
        XCTAssertGreaterThanOrEqual(light.radius, 8)
        XCTAssertEqual(light.radius, dark.radius)
        XCTAssertLessThanOrEqual(abs(light.offsetY), 2)
        XCTAssertLessThanOrEqual(abs(dark.offsetY), 2)
        // The native window must leave room for the shadow to fade out.
        XCTAssertGreaterThanOrEqual(AtticStyle.panelElevationMargin, light.extent)
        XCTAssertGreaterThanOrEqual(AtticStyle.panelElevationMargin, dark.extent)
        XCTAssertGreaterThan(AtticStyle.panelElevationMargin, AtticPanelResizePolicy.outsideGripThickness)
        XCTAssertFalse(AtticStyle.panelUsesSystemShadow, "The AppKit shadow would stack under the shape shadow")
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
        // Original's Frosted surface carries no palette wash at all.
        XCTAssertEqual(light.frostedTintOpacity, 0)
        XCTAssertEqual(dark.frostedTintOpacity, 0)
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
                    // Light Glass and Frosted carry only a few percent of the
                    // near-white Light surfaces (the owner's Siri-level
                    // transparency), so there the palettes are told apart by
                    // accent, edge and Tint, not by the fill; that identity is
                    // covered by testPanelThemeIdentityIsQuantizedDistinct...
                    if appearance == .light && kind != .solid { continue }
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
        kind: AtticPanelSurfaceTreatment.Kind,
        tint: PanelTintLevel = .off
    ) -> AtticPanelSurfaceTreatment {
        theme.surfaceTreatment(
            appearance: appearance,
            contrast: contrast,
            surface: PanelSurfaceStyle(kind),
            tint: tint,
            reduceTransparency: false
        )
    }

    private func visibleSurface(
        for treatment: AtticPanelSurfaceTreatment,
        appearance: AtticPanelThemeAppearance
    ) -> AtticThemeColor {
        treatment.compositedSurface(over: representativeBackdrop(for: appearance))
    }

    private func composite(
        _ foreground: AtticThemeColor,
        opacity: Double,
        over background: AtticThemeColor
    ) -> AtticThemeColor {
        background.mixed(with: foreground, amount: opacity)
    }

    private func representativeBackdrop(
        for appearance: AtticPanelThemeAppearance
    ) -> AtticThemeColor {
        appearance == .dark
            ? AtticThemeColor(red: 0.18, green: 0.18, blue: 0.18)
            : AtticThemeColor(red: 0.82, green: 0.82, blue: 0.82)
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
