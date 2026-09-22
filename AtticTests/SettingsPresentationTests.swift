import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Attic

final class SettingsPresentationTests: XCTestCase {
    @MainActor
    private func withSettingsDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "SettingsPresentationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
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

    func testAppearancePreviewIsARealMiniatureWithADescriptiveLabel() {
        XCTAssertEqual(AppearancePreviewLayout.scale, 0.46)
        XCTAssertEqual(AppearancePreviewLayout.panelSize.width,
                       (PanelGeometry.defaultPanelSize.width * 0.46).rounded())
        XCTAssertEqual(AppearancePreviewLayout.panelSize.height,
                       (PanelGeometry.defaultPanelSize.height * 0.46).rounded())
        // Room for the miniature and its outside shadow above and below.
        XCTAssertGreaterThanOrEqual(
            AppearancePreviewLayout.cardHeight,
            AppearancePreviewLayout.panelSize.height + AtticPanelSurfaceElevation.dark.extent * 2
        )
        XCTAssertEqual(AppearancePreviewLayout.cornerRadius(forPanelCornerSize: 80), 80 * 0.46)
        XCTAssertEqual(AppearancePreviewLayout.cornerRadius(forPanelCornerSize: 0), 4)
        XCTAssertEqual(AppearancePreviewLayout.cornerRadius(forPanelCornerSize: .nan),
                       AtticStyle.panelCornerRadius * 0.46)
        XCTAssertEqual(
            AppearancePreviewLayout.accessibilityLabel(
                theme: .seaGlass, surface: .glass, tint: .vivid,
                appearance: .dark, reduceTransparency: false),
            "Panel preview: Sea Glass palette, Glass surface, Tint Vivid, Dark appearance."
        )
        XCTAssertEqual(
            AppearancePreviewLayout.accessibilityLabel(
                theme: .original, surface: .frosted, tint: .off,
                appearance: .light, reduceTransparency: true),
            "Panel preview: Original palette, Solid (Reduce Transparency) surface, Tint Off, Light appearance."
        )
    }

    func testTintFloorNoteIsAbsentWhenGeneratedTableHasNoClamps() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for surface in PanelSurfaceStyle.allCases {
                    for tint in PanelTintLevel.allCases {
                        let treatment = theme.surfaceTreatment(
                            appearance: appearance, surface: surface, tint: tint, reduceTransparency: false
                        )
                        XCTAssertNil(AppearanceSettingsPresentation.tintFloorNote(for: treatment))
                    }
                }
            }
        }
    }

    func testSettingsDesignTokensStrengthenInIncreasedContrast() {
        XCTAssertGreaterThan(SettingsDesign.selectionLineWidth(for: .increased), SettingsDesign.selectionLineWidth(for: .standard))
        XCTAssertGreaterThan(SettingsDesign.tileBoundaryOpacity(for: .increased), SettingsDesign.tileBoundaryOpacity(for: .standard))
        XCTAssertGreaterThan(SettingsDesign.tileBoundaryLineWidth(for: .increased), SettingsDesign.tileBoundaryLineWidth(for: .standard))
        XCTAssertEqual(SettingsDesign.iconSize, 24)
        XCTAssertEqual(SettingsDesign.titleSize, 22)
        for section in SettingsSection.allCases {
            XCTAssertFalse(section.systemImage.isEmpty)
            XCTAssertNotEqual(section.tint, Color.clear)
        }
        // New control identifiers, on the elements that play those roles.
        XCTAssertEqual(PanelSurfaceStyle.allCases.map(\.accessibilityIdentifier),
                       ["setting-panel-surface-solid", "setting-panel-surface-glass", "setting-panel-surface-frosted"])
        XCTAssertEqual(PanelTintLevel.allCases.map(\.accessibilityIdentifier),
                       ["setting-panel-tint-off", "setting-panel-tint-subtle", "setting-panel-tint-vivid", "setting-panel-tint-bold"])
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

    /// A refused global shortcut used to be swallowed while the menu kept
    /// advertising ⌃⌥Space. Settings stays silent for a working shortcut and
    /// explains a refusal, distinguishing a resolvable conflict from a plain
    /// failure, without putting an OSStatus in front of the user.
    func testSettingsExplainsOnlyARefusedGlobalShortcut() {
        XCTAssertNil(SettingsVisibility.globalShortcutFailure(.notRegistered))
        XCTAssertNil(SettingsVisibility.globalShortcutFailure(.registered))

        let conflict = GlobalHotKeyFailure(stage: .hotKey,
                                           status: OSStatus(eventHotKeyExistsErr),
                                           combination: .newTask)
        let shown = try? XCTUnwrap(SettingsVisibility.globalShortcutFailure(.failed(conflict)))
        XCTAssertEqual(shown, conflict)
        XCTAssertTrue(conflict.isConflict)
        XCTAssertTrue(conflict.settingsMessage.contains("Another app"))
        XCTAssertTrue(conflict.settingsMessage.contains("menu bar"),
                      "the message must say Attic is still reachable")
        XCTAssertFalse(conflict.settingsMessage.contains("\(eventHotKeyExistsErr)"),
                       "status codes belong in the log, not in Settings")
        XCTAssertTrue(conflict.logDescription.contains("RegisterEventHotKey"))
        XCTAssertTrue(conflict.logDescription.contains("\(eventHotKeyExistsErr)"))

        let refused = GlobalHotKeyFailure(stage: .eventHandler, status: -50,
                                          combination: .newTask)
        XCTAssertFalse(refused.isConflict)
        XCTAssertTrue(refused.settingsMessage.contains("macOS refused"))
        XCTAssertTrue(refused.settingsMessage.contains("menu bar"))
        XCTAssertTrue(refused.logDescription.contains("InstallEventHandler"))
        XCTAssertTrue(refused.logDescription.contains("-50"))
        XCTAssertNotEqual(refused.settingsMessage, conflict.settingsMessage)
    }

    /// The copy used to name ⌃⌥Space in a literal while the type it belonged
    /// to was parameterised by key code and modifiers, so a failure for any
    /// other combination described the wrong one. The failure now carries the
    /// combination it was refused for, and says nothing it cannot say
    /// correctly.
    func testRefusalCopyNamesTheCombinationThatWasActuallyRefused() throws {
        XCTAssertEqual(GlobalHotKeyCombination.newTask.displayName, "⌃⌥Space")

        let newTask = GlobalHotKeyFailure(stage: .hotKey,
                                          status: OSStatus(eventHotKeyExistsErr),
                                          combination: .newTask)
        XCTAssertTrue(newTask.settingsMessage.contains("⌃⌥Space"))

        // A different combination: the copy must follow it rather than repeat
        // the one that happens to be shipped.
        let other = GlobalHotKeyCombination(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        XCTAssertEqual(other.displayName, "⌃⌥⇧⌘Space", "Apple's modifier order")
        for stage in [GlobalHotKeyFailure.Stage.hotKey, .eventHandler] {
            let failure = GlobalHotKeyFailure(stage: stage, status: -50, combination: other)
            XCTAssertTrue(failure.settingsMessage.contains("⌃⌥⇧⌘Space"),
                          "\(stage) copy must name the refused combination")
            XCTAssertFalse(failure.settingsMessage.contains("⌃⌥Space,"),
                           "and must not name the shipped one instead")
            XCTAssertTrue(failure.logDescription.contains("⌃⌥⇧⌘Space"))
        }

        // A key this app has no name for is never guessed at: the sentence
        // omits the combination and still reads, and the log keeps the raw
        // values so the refusal is still diagnosable.
        let unnamed = GlobalHotKeyCombination(keyCode: 999, modifiers: UInt32(controlKey))
        XCTAssertNil(unnamed.displayName)
        let vague = GlobalHotKeyFailure(stage: .hotKey, status: -50, combination: unnamed)
        XCTAssertFalse(vague.settingsMessage.contains("Space"))
        XCTAssertTrue(vague.settingsMessage.contains("menu bar"))
        XCTAssertTrue(vague.logDescription.contains("999"))
        XCTAssertTrue(vague.logDescription.contains("\(UInt32(controlKey))"))
    }

    /// The menu bar item is the only place the global combination is
    /// advertised, and it advertised it unconditionally — including after
    /// Carbon refused the registration, when nothing outside an open menu
    /// would answer that shortcut. The advertised equivalent now follows the
    /// registration, and comes from the same combination the hot key claims so
    /// the two cannot drift apart.
    func testTheMenuAdvertisesTheGlobalShortcutOnlyWhileItIsRegistered() throws {
        XCTAssertFalse(GlobalHotKeyRegistration.notRegistered.isActive)
        XCTAssertTrue(GlobalHotKeyRegistration.registered.isActive)
        XCTAssertFalse(GlobalHotKeyRegistration.failed(
            GlobalHotKeyFailure(stage: .hotKey, status: -50, combination: .newTask)
        ).isActive)

        // The equivalent the menu would show is the claimed combination, not a
        // literal written beside it.
        let shortcut = try XCTUnwrap(GlobalHotKeyCombination.newTask.keyboardShortcut)
        XCTAssertEqual(shortcut.key, KeyEquivalent.space)
        XCTAssertEqual(shortcut.modifiers, [.control, .option])

        let unnamed = GlobalHotKeyCombination(keyCode: 999, modifiers: UInt32(controlKey))
        XCTAssertNil(unnamed.keyboardShortcut,
                     "a key Attic never binds must show no equivalent rather than a wrong one")
    }

    /// Whatever the system answers, `register()` must leave a state the UI can
    /// read: success, or a failure carrying the refusing stage and status.
    /// Silently staying `notRegistered` is what hid the old defect.
    @MainActor
    func testHotKeyRegistrationAlwaysRecordsATerminalOutcome() {
        // F13 with four modifiers: an unlikely combination for another app to
        // own, so this exercises the success path without fighting for a
        // shortcut the user may actually be using.
        let hotKey = GlobalHotKey(combination: GlobalHotKeyCombination(
            keyCode: UInt32(kVK_F13),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        ))
        defer { hotKey.unregister() }
        XCTAssertEqual(hotKey.registration, .notRegistered)

        let outcome = hotKey.register()
        XCTAssertEqual(outcome, hotKey.registration)
        switch outcome {
        case .registered:
            XCTAssertNil(hotKey.registration.failure)
            // A second call is idempotent and never downgrades the state.
            XCTAssertEqual(hotKey.register(), .registered)
        case let .failed(failure):
            XCTAssertNotEqual(failure.status, noErr)
            XCTAssertFalse(failure.settingsMessage.isEmpty)
        case .notRegistered:
            XCTFail("register() must never leave the shortcut state unresolved")
        }

        hotKey.unregister()
        XCTAssertEqual(hotKey.registration, .notRegistered)
    }

    /// Point readouts are rendered straight from the stored model value, so the
    /// formatting has to be total: `Int(value.rounded())` trapped on a finite
    /// but unrepresentable magnitude and crashed Settings instead of showing a
    /// number.
    func testPointReadoutsAreTotalOverEveryStoredValue() {
        XCTAssertEqual(SettingsPointFormat.rounded(320), 320)
        XCTAssertEqual(SettingsPointFormat.rounded(319.6), 320)
        XCTAssertEqual(SettingsPointFormat.rounded(-0.4), 0)
        XCTAssertEqual(SettingsPointFormat.rounded(1e30), Int.max)
        XCTAssertEqual(SettingsPointFormat.rounded(-1e30), Int.min)
        XCTAssertEqual(SettingsPointFormat.rounded(.greatestFiniteMagnitude), Int.max)
        XCTAssertEqual(SettingsPointFormat.rounded(.infinity), 0)
        XCTAssertEqual(SettingsPointFormat.rounded(-.infinity), 0)
        XCTAssertEqual(SettingsPointFormat.rounded(.nan), 0)
    }

    /// A width larger than the attached displays is a legitimate choice made on
    /// another monitor and must survive. A magnitude no display could justify
    /// is corruption and must not reach layout or the readout.
    @MainActor
    func testPanelDimensionRestorationKeepsLargeChoicesAndRejectsCorruptMagnitudes() throws {
        let suite = "AppSettingsRestoration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let oversizedButPlausible = PanelContentSize.max + 400
        defaults.set(oversizedButPlausible, forKey: "panelContentSize")
        XCTAssertEqual(AppSettings(defaults: defaults).panelContentSize, oversizedButPlausible,
                       "a width chosen on a bigger display must not be rewritten")

        for corrupt in [1e30, AppSettings.maximumRestorableDimension + 1, Double.infinity, Double.nan] {
            defaults.set(corrupt, forKey: "panelContentSize")
            defaults.set(corrupt, forKey: "panelHeight")
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.panelContentSize, PanelContentSize.defaultValue)
            XCTAssertEqual(settings.panelHeight, PanelGeometry.defaultPanelSize.height)
            // The readout the malformed value used to trap on is now total.
            XCTAssertEqual(SettingsPointFormat.rounded(settings.panelContentSize),
                           Int(PanelContentSize.defaultValue))
        }
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

    func testTintLengthAndNeutralTintCopy() {
        XCTAssertEqual(AppearanceSettingsPresentation.tintLengthDescription(1), "Full height")
        XCTAssertEqual(AppearanceSettingsPresentation.tintLengthDescription(0.5), "50 percent of the panel")
        XCTAssertEqual(AppearanceSettingsPresentation.tintLengthDescription(0.01), "30 percent of the panel")
        for level in PanelTintLevel.allCases {
            let neutral = level.detail(neutral: true)
            let coloured = level.detail(neutral: false)
            XCTAssertFalse(neutral.isEmpty)
            XCTAssertFalse(coloured.isEmpty)
            if level == .off {
                XCTAssertEqual(neutral, coloured)
            } else {
                XCTAssertNotEqual(neutral, coloured, level.rawValue)
                XCTAssertFalse(neutral.localizedCaseInsensitiveContains("accent"), level.rawValue)
                XCTAssertFalse(neutral.localizedCaseInsensitiveContains("colour"), level.rawValue)
            }
        }
        XCTAssertTrue(AtticPanelTheme.original.usesNeutralTint)
        XCTAssertTrue(AtticPanelTheme.allCases.dropFirst().allSatisfy { !$0.usesNeutralTint })
    }
}
