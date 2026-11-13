import AppKit
import Foundation
import SwiftUI
import SwiftData
import XCTest
@testable import Attic

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testR8QuitDrainsAllMatchingModelsVetoesFailureAndLeavesOtherStoresAlone() async throws {
        struct Rejected: Error {}
        let root = ownedTemporaryDirectory(prefix: "Catchup1QuitFailure")
        let suite = "Catchup1QuitFailure.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let runtime = AppRuntimeEnvironment(environment: ["ATTIC_TESTING": "1", "ATTIC_TEST_DEFAULTS_SUITE": suite],
                                            arguments: [], applicationSupportURL: root)
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let coordinator = try AppCoordinator(runtime: runtime, openStore: { container })
        defer { coordinator.stop() }
        var reject = false
        let failingStore = TaskStore(container: container, persist: { context in
            if reject { throw Rejected() }
            try context.save()
        })
        let normal = TasksPageModel(library: coordinator.library)
        let failing = TasksPageModel(library: AtticLibrary(tasks: failingStore))
        let unrelatedStore = try makeTestStore()
        let unrelated = TasksPageModel(library: AtticLibrary(tasks: unrelatedStore))
        let deleted = try XCTUnwrap(coordinator.store.commit([TaskDraft(title: "Delete")])?.first)
        let ticked = try XCTUnwrap(failingStore.commit([TaskDraft(title: "Complete")])?.first)
        let untouched = try XCTUnwrap(unrelatedStore.commit([TaskDraft(title: "Other store")])?.first)
        var callbacks = 0, unrelatedCallbacks = 0
        normal.deleteAcknowledged([deleted.id]) { outcome in
            XCTAssertTrue(outcome.isApplied)
            callbacks += 1
        }
        failing.completeAcknowledged(ticked.id) { outcome in
            XCTAssertFalse(outcome.isApplied)
            callbacks += 1
        }
        unrelated.deleteAcknowledged([untouched.id]) { _ in unrelatedCallbacks += 1 }
        reject = true
        let ready = await coordinator.prepareForTerminationDurably()
        XCTAssertFalse(ready, "a failed acknowledged save must veto quit")
        XCTAssertEqual(callbacks, 2, "every model over the quitting store is drained")
        XCTAssertEqual(unrelatedCallbacks, 0, "quitting one container must not drain another")
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertNotNil(saved.first { $0.id == deleted.id }?.deletedAt)
        XCTAssertEqual(saved.first { $0.id == ticked.id }?.status, .todo, "the failed tick rolls back")
        XCTAssertNotNil(unrelatedStore.listedTask(withID: untouched.id))
        unrelated.settlePendingCompletionAcknowledgements()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callbacks, 2, "the old scheduled tasks must not replay settled commands")
        XCTAssertEqual(unrelatedCallbacks, 1)
    }

    @MainActor
    func testR8QuitSavesAcknowledgedTaskDeletionBeforeApproving() async throws {
        let root = ownedTemporaryDirectory(prefix: "Catchup1Quit")
        let suite = "Catchup1Quit.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let runtime = AppRuntimeEnvironment(environment: ["ATTIC_TESTING": "1", "ATTIC_TEST_DEFAULTS_SUITE": suite],
                                            arguments: [], applicationSupportURL: root)
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let coordinator = try AppCoordinator(runtime: runtime, openStore: { container })
        defer { coordinator.stop() }
        let page = TasksPageModel(library: coordinator.library)
        for durable in [false, true] {
            let task = try XCTUnwrap(coordinator.store.commit([TaskDraft(title: "Quit immediately")])?.first)
            var settled: CommandOutcome?
            page.deleteAcknowledged([task.id]) { settled = $0 }
            XCTAssertFalse(page.rows(for: .now).contains { $0.id == task.id }, "the deletion is already visible")
            XCTAssertNil(settled, "the save has not run yet")
            let ready = durable ? await coordinator.prepareForTerminationDurably() : coordinator.prepareForTermination()
            XCTAssertTrue(ready)
            let replicas = try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).filter { $0.id == task.id }
            XCTAssertTrue(replicas.allSatisfy { $0.deletedAt != nil }, "quit must save the deletion before approval (durable=\(durable))")
            XCTAssertEqual(settled?.isApplied, true, "the acknowledged command settles before approval")
            page.settlePendingCompletionAcknowledgements()
        }
        print("CATCHUP_R8 pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    @MainActor
    func testFix18RepeatedQuitCommandDoesNotBypassPendingPreparation() throws {
        var terminationCalls = 0
        let commands = MenuBarCommands.commands(
            advertisedNewTaskShortcut: nil,
            showPanel: {}, newTask: {}, newNote: {}, search: {}, openSettings: {},
            quit: { terminationCalls += 1 }
        )
        let quit = try XCTUnwrap(commands.first(where: { $0.title == "Quit Attic" }))

        quit.action()
        quit.action()

        XCTAssertEqual(terminationCalls, 1,
                       "a repeated Quit while durable preparation is pending must not call NSApplication.terminate again")
    }

    @MainActor
    func testFix18RefusedQuitAllowsASecondDurabilityAttempt() {
        let gate = AppQuitRequestGate()
        var calls = 0
        gate.request { calls += 1 }
        XCTAssertTrue(gate.beginPreparation())
        XCTAssertFalse(gate.beginPreparation(), "reentry must not start another durability preparation")
        gate.finishPreparation(approved: false)
        gate.request { calls += 1 }
        XCTAssertTrue(gate.beginPreparation())
        XCTAssertEqual(calls, 2, "a refused Quit must allow a later retry")
    }

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
        let parent = ownedTemporaryDirectory(prefix: "AppRuntimeAttachmentTests")

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
        let store = trackAttachmentReconciliation(of: NoteStore(
            container: container,
            attachmentFileStore: try XCTUnwrap(runtime.makeAttachmentFileStore())
        ))
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
        let parent = ownedTemporaryDirectory(prefix: "AppRuntimeUnownedAttachmentTests")

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
        // Visual A: black 10 % / 24 %, y 4, radius 12, and a contact shadow
        // of 3 % / 8 % at y 0.5, radius 1. Broad, soft, low opacity.
        XCTAssertEqual(light, AtticPanelSurfaceElevation(opacity: 0.10, radius: 12, offsetY: 4, contactOpacity: 0.03, contactRadius: 1, contactOffsetY: 0.5))
        XCTAssertEqual(dark, AtticPanelSurfaceElevation(opacity: 0.24, radius: 12, offsetY: 4, contactOpacity: 0.08, contactRadius: 1, contactOffsetY: 0.5))
        XCTAssertLessThan(light.opacity, dark.opacity)
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

    @MainActor
    func testSettingsHuntClampedChoicesRemainSavedAfterReload() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, motionLabAvailable: false)

        // The first valid edit ensures a stale stored value exists before
        // each user-controlled setting is clamped by the property observer.
        settings.panelCornerSize = 28
        settings.panelCornerSize = 200
        XCTAssertEqual(settings.panelCornerSize, PanelCornerSize.max)
        XCTAssertEqual(defaults.double(forKey: "panelCornerSize"), PanelCornerSize.max)

        settings.panelContentSize = 360
        settings.panelContentSize = 1_000
        XCTAssertEqual(settings.panelContentSize, PanelContentSize.max)
        XCTAssertEqual(defaults.double(forKey: "panelContentSize"), PanelContentSize.max)

        settings.revealDelay = 1.5
        settings.revealDelay = .infinity
        XCTAssertEqual(settings.revealDelay, 0.2)
        XCTAssertEqual(defaults.double(forKey: "revealDelay"), 0.2)

        settings.hideDelay = 1.5
        settings.hideDelay = .nan
        XCTAssertEqual(settings.hideDelay, 0.3)
        XCTAssertEqual(defaults.double(forKey: "hideDelay"), 0.3)

        let restored = AppSettings(defaults: defaults, motionLabAvailable: false)
        XCTAssertEqual(restored.panelCornerSize, settings.panelCornerSize)
        XCTAssertEqual(restored.panelContentSize, settings.panelContentSize)
        XCTAssertEqual(restored.revealDelay, settings.revealDelay)
        XCTAssertEqual(restored.hideDelay, settings.hideDelay)
    }

    @MainActor
    func testSettingsHuntUnsortedDisplayEditsPersistTheNormalizedSelection() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, motionLabAvailable: false)

        settings.revealDisplayIDs = ["screen-z"]
        settings.revealDisplayIDs.append("screen-a")
        XCTAssertEqual(settings.revealDisplayIDs, ["screen-a", "screen-z"])
        XCTAssertEqual(defaults.stringArray(forKey: "revealDisplayIDs"), ["screen-a", "screen-z"])
        XCTAssertEqual(AppSettings(defaults: defaults, motionLabAvailable: false).revealDisplayIDs,
                       ["screen-a", "screen-z"])
    }

    /// A reproducible Settings action hunt. Each input is checked against an
    /// independent expected state, then against a fresh reader of the same
    /// scratch suite. Recreating the reader after each step also exercises
    /// changes made while the panel is hidden or another page is being edited.
    @MainActor
    func testSettingsHuntSeededPreferenceSequencesRoundTripEveryStep() {
        for seed: UInt64 in [0x51A711, 0xCA1E42, 0xA11CE5, 0xD0C0DE] {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            var random = SettingsHuntRandom(state: seed)
            var settings = AppSettings(defaults: defaults, motionLabAvailable: false)
            let fresh = SettingsHuntState(settings)
            var expected = fresh
            var navigation = SettingsNavigation(defaults: defaults)
            var expectedPage = SettingsSection.general

            XCTAssertEqual(fresh.theme, .original)
            XCTAssertEqual(fresh.surface, .glass)
            XCTAssertEqual(fresh.tint, .off)
            XCTAssertEqual(fresh.appearance, .system)
            XCTAssertFalse(fresh.brightenGlass)
            XCTAssertTrue(fresh.soundsEnabled)
            XCTAssertEqual(fresh.animations, .lively)
            XCTAssertEqual(fresh.reducedStyle, .instant)
            XCTAssertEqual(fresh.dismissMode, .clickAway)
            XCTAssertFalse(fresh.agentAccess)
            XCTAssertEqual(fresh.claudeChoice, AgentRunChoice(model: "sonnet", effort: "medium"))
            XCTAssertEqual(fresh.codexChoice, AgentRunChoice(model: "gpt-6.1-sol", effort: "medium"))

            for step in 0..<420 {
                switch random.next(31) {
                case 0:
                    let choice = AtticPanelTheme.allCases[random.next(AtticPanelTheme.allCases.count)]
                    settings.panelTheme = choice; expected.theme = choice
                case 1:
                    let choice = PanelSurfaceStyle.allCases[random.next(PanelSurfaceStyle.allCases.count)]
                    settings.panelSurfaceStyle = choice; expected.surface = choice
                case 2:
                    let choice = PanelTintLevel.allCases[random.next(PanelTintLevel.allCases.count)]
                    settings.panelTint = choice; expected.tint = choice
                case 3:
                    let choice = AppearancePreference.allCases[random.next(AppearancePreference.allCases.count)]
                    settings.appearance = choice; expected.appearance = choice
                case 4:
                    let input = [0.01, 0.3, 0.65, 0.95, 2.0][random.next(5)]
                    settings.panelTintLength = input
                    expected.tintLength = min(1, max(PanelTintLength.range.lowerBound, input))
                case 5:
                    settings.brightenGlass.toggle(); expected.brightenGlass.toggle()
                case 6:
                    settings.soundsEnabled.toggle(); expected.soundsEnabled.toggle()
                case 7:
                    settings.hapticsEnabled.toggle(); expected.hapticsEnabled.toggle()
                case 8:
                    let choice = AtticAnimationLevel.allCases[random.next(AtticAnimationLevel.allCases.count)]
                    settings.animations = choice; expected.animations = choice
                case 9:
                    let choice = AtticReducedMotionStyle.allCases[random.next(AtticReducedMotionStyle.allCases.count)]
                    settings.reducedMotionStyle = choice; expected.reducedStyle = choice
                case 10:
                    settings.nextEventInNow.toggle(); expected.nextEventInNow.toggle()
                case 11:
                    settings.isAgentAccessEnabled.toggle(); expected.agentAccess.toggle()
                case 12:
                    let choice = AgentBackend.allCases[random.next(AgentBackend.allCases.count)]
                    settings.inAppAgentBackend = choice; expected.backend = choice
                case 13, 14:
                    let backend: AgentBackend = step % 2 == 0 ? .claude : .codex
                    let options = AgentModelCatalog.models(for: backend)
                    let model = options[random.next(options.count)]
                    let choice = AgentRunChoice(model: model.id, effort: model.efforts.first)
                    settings.setInAppAgentChoice(choice, for: backend)
                    if backend == .claude { expected.claudeChoice = choice }
                    else { expected.codexChoice = choice }
                case 15:
                    let choice = ScreenCorner.allCases[random.next(ScreenCorner.allCases.count)]
                    settings.corner = choice; expected.corner = choice
                case 16:
                    let choice = PanelIslandSpot.allCases[random.next(PanelIslandSpot.allCases.count)]
                    settings.islandSpot = choice; expected.islandSpot = choice
                case 17:
                    let choice = PanelDismissMode.allCases[random.next(PanelDismissMode.allCases.count)]
                    settings.panelDismissMode = choice; expected.dismissMode = choice
                case 18:
                    let input = [-1.0, 0.2, 0.8, 2.0, .infinity][random.next(5)]
                    settings.revealDelay = input
                    expected.revealDelay = input.isFinite ? min(2, max(0.2, input)) : 0.2
                case 19:
                    let input = [-1.0, 0.1, 0.9, 2.0, .nan][random.next(5)]
                    settings.hideDelay = input
                    expected.hideDelay = input.isFinite ? min(2, max(0.1, input)) : 0.3
                case 20:
                    let input = [-1.0, 10, 52, 140, 900, .nan][random.next(6)]
                    settings.panelCornerSize = input
                    expected.cornerSize = input.isFinite ? min(PanelCornerSize.max, max(PanelCornerSize.min, input)) : PanelCornerSize.defaultValue
                case 21:
                    let input = [-1.0, 320, 365, 2_000, .infinity][random.next(5)]
                    settings.panelContentSize = input
                    expected.panelWidth = input.isFinite ? min(PanelContentSize.max, max(PanelContentSize.min, input)) : PanelContentSize.defaultValue
                case 22:
                    settings.quickCaptureEnabled.toggle(); expected.quickCaptureEnabled.toggle()
                case 23:
                    let choice = [GlobalHotKeyCombination.newTask,
                                  GlobalHotKeyCombination(keyCode: 0, modifiers: GlobalHotKeyCombination.newTask.modifiers),
                                  GlobalHotKeyCombination(keyCode: 1, modifiers: GlobalHotKeyCombination.newTask.modifiers)][random.next(3)]
                    XCTAssertNil(choice.recordingProblem)
                    settings.quickCaptureShortcut = choice; expected.shortcut = choice
                case 24:
                    settings.revealOnHover.toggle(); expected.revealOnHover.toggle()
                case 25:
                    let choice = RevealModifier.allCases[random.next(RevealModifier.allCases.count)]
                    settings.revealModifier = choice; expected.revealModifier = choice
                case 26:
                    let choice = RevealDisplays.allCases[random.next(RevealDisplays.allCases.count)]
                    settings.revealDisplays = choice; expected.revealDisplays = choice
                case 27:
                    let choices = ["screen-z", "screen-a", "screen-b", "screen-z", ""]
                    let list = (0...random.next(5)).map { _ in choices[random.next(choices.count)] }
                    settings.revealDisplayIDs = list
                    expected.revealDisplayIDs = Array(Set(list.filter { !$0.isEmpty })).sorted()
                case 28:
                    let choice = PanelHideAnimation.allCases[random.next(PanelHideAnimation.allCases.count)]
                    settings.hideAnimation = choice; expected.hideAnimation = choice
                case 29:
                    let choice = SettingsSection.allCases[random.next(SettingsSection.allCases.count)]
                    navigation.select(choice); expectedPage = choice
                default:
                    defaults.removePersistentDomain(forName: suiteName)
                    settings = AppSettings(defaults: defaults, motionLabAvailable: false)
                    navigation = SettingsNavigation(defaults: defaults)
                    expected = fresh
                    expectedPage = .general
                }

                let label = "seed=\(String(seed, radix: 16)) step=\(step)"
                XCTAssertEqual(SettingsHuntState(settings), expected, "live state: \(label)")
                XCTAssertEqual(SettingsHuntState(AppSettings(defaults: defaults, motionLabAvailable: false)),
                               expected, "relaunch state: \(label)")
                XCTAssertEqual(navigation.selection, expectedPage, "navigation: \(label)")
                XCTAssertEqual(SettingsNavigation(defaults: defaults).selection, expectedPage,
                               "relaunch navigation: \(label)")

                // The panel, its miniature and the island use one surface
                // treatment model even when contrast/transparency changes.
                let reduceTransparency = step % 2 == 0
                let contrast: ColorSchemeContrast = step % 3 == 0 ? .increased : .standard
                let scheme: ColorScheme = step % 2 == 0 ? .light : .dark
                XCTAssertEqual(settings.panelSurfaceTreatment(colorScheme: scheme, contrast: contrast,
                                                               reduceTransparency: reduceTransparency),
                               expected.theme.surfaceTreatment(colorScheme: scheme, contrast: contrast,
                                                               surface: expected.surface, tint: expected.tint,
                                                               tintLength: expected.tintLength,
                                                               reduceTransparency: reduceTransparency),
                               "panel appearance: \(label)")
            }
            print("SETTINGS_HUNT seed=\(String(seed, radix: 16)) steps=420")
        }
    }

    private struct SettingsHuntRandom {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
    }

    private struct SettingsHuntState: Equatable {
        var theme: AtticPanelTheme
        var surface: PanelSurfaceStyle
        var tint: PanelTintLevel
        var tintLength: Double
        var appearance: AppearancePreference
        var brightenGlass: Bool
        var soundsEnabled: Bool
        var hapticsEnabled: Bool
        var animations: AtticAnimationLevel
        var reducedStyle: AtticReducedMotionStyle
        var nextEventInNow: Bool
        var agentAccess: Bool
        var backend: AgentBackend
        var claudeChoice: AgentRunChoice
        var codexChoice: AgentRunChoice
        var corner: ScreenCorner
        var islandSpot: PanelIslandSpot
        var dismissMode: PanelDismissMode
        var revealDelay: Double
        var hideDelay: Double
        var cornerSize: Double
        var panelWidth: Double
        var quickCaptureEnabled: Bool
        var shortcut: GlobalHotKeyCombination
        var revealOnHover: Bool
        var revealModifier: RevealModifier
        var revealDisplays: RevealDisplays
        var revealDisplayIDs: [String]
        var hideAnimation: PanelHideAnimation

        @MainActor
        init(_ settings: AppSettings) {
            theme = settings.panelTheme
            surface = settings.panelSurfaceStyle
            tint = settings.panelTint
            tintLength = settings.panelTintLength
            appearance = settings.appearance
            brightenGlass = settings.brightenGlass
            soundsEnabled = settings.soundsEnabled
            hapticsEnabled = settings.hapticsEnabled
            animations = settings.animations
            reducedStyle = settings.reducedMotionStyle
            nextEventInNow = settings.nextEventInNow
            agentAccess = settings.isAgentAccessEnabled
            backend = settings.inAppAgentBackend
            claudeChoice = settings.inAppAgentChoice(for: .claude)
            codexChoice = settings.inAppAgentChoice(for: .codex)
            corner = settings.corner
            islandSpot = settings.islandSpot
            dismissMode = settings.panelDismissMode
            revealDelay = settings.revealDelay
            hideDelay = settings.hideDelay
            cornerSize = settings.panelCornerSize
            panelWidth = settings.panelContentSize
            quickCaptureEnabled = settings.quickCaptureEnabled
            shortcut = settings.quickCaptureShortcut
            revealOnHover = settings.revealOnHover
            revealModifier = settings.revealModifier
            revealDisplays = settings.revealDisplays
            revealDisplayIDs = settings.revealDisplayIDs
            hideAnimation = settings.hideAnimation
        }
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
