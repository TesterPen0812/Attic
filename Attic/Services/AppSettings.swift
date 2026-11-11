import AppKit
import Combine
import Foundation
import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

}

enum PanelDismissMode: String, CaseIterable, Identifiable {
    case moveCursorAway
    case clickAway

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moveCursorAway: String(localized: "Move cursor away")
        case .clickAway: String(localized: "Click away")
        }
    }
}

/// User-adjustable corner radius of the panel squircle, in points.
enum PanelCornerSize: Double, CaseIterable, Identifiable {
    case small = 10
    case standard = 18
    case large = 28
    case extraLarge = 40
    case huge = 80
    case enormous = 110
    case maximum = 140

    var id: Double { rawValue }


    static let min = PanelCornerSize.small.rawValue
    static let max = PanelCornerSize.maximum.rawValue
    /// Fresh installs start at 52, about Craft's floating-panel corner
    /// (spec § Appearance: "The panel's corner"). A size someone already
    /// chose is stored and kept; only an unset value takes this default.
    static let defaultValue: Double = 52
}

/// User-adjustable and live-resizable width of the panel, in points.
enum PanelContentSize: Double, CaseIterable, Identifiable {
    case standard = 320
    case large = 360
    case extraLarge = 380

    var id: Double { rawValue }


    static let min = PanelContentSize.standard.rawValue
    static let max = Double(PanelPageLayout.readingWidth)
    static let defaultValue = PanelContentSize.standard.rawValue
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let corner = "selectedCorner"
        static let revealDelay = "revealDelay"
        static let hideDelay = "hideDelay"
        static let panelDismissMode = "panelDismissMode"
        static let hasAdoptedFasterReveal = "hasAdoptedFasterReveal"
        static let hasAdoptedQuickerReveal = "hasAdoptedQuickerRevealV2"
        static let hasAdoptedInstantReveal = "hasAdoptedInstantRevealV3"
        static let hasShownWelcome = "hasShownWelcome"
        static let panelTheme = AppearanceMigration.Key.theme
        static let panelSurfaceStyle = AppearanceMigration.Key.surfaceStyle
        static let panelTint = AppearanceMigration.Key.tint
        static let panelTintLength = AppearanceMigration.Key.tintLength
        static let appearance = AppearanceMigration.Key.appearance
        static let isAgentAccessEnabled = "isAgentAccessEnabled"
        static let inAppAgentBackend = "inAppAgentBackend"
        static let inAppAgentClaudeModel = "inAppAgentClaudeModel"
        static let inAppAgentClaudeEffort = "inAppAgentClaudeEffort"
        static let inAppAgentCodexModel = "inAppAgentCodexModel"
        static let inAppAgentCodexEffort = "inAppAgentCodexEffort"
        static let agentServerPort = "agentServerPort"
        static let hasAdoptedAgentAccessOptIn = "hasAdoptedAgentAccessOptIn"
        static let panelCornerSize = "panelCornerSize"
        static let panelContentSize = "panelContentSize"
        static let panelHeight = "panelHeight"
        static let hapticsEnabled = "hapticsEnabled"
        static let soundsEnabled = "soundsEnabled"
        static let nextEventInNow = "nextEventInNow"
        static let animations = "animations"
        static let reducedMotionStyle = "reducedMotionStyle"
        static let hideAnimation = "panelHideAnimation"
        static let islandSpot = "panelIslandSpot"
        static let hideSpeedLab = "motionLabHideSpeeds"
        static let motionLabTuning = "motionLabTuning"
        static let quickCaptureEnabled = "quickCaptureEnabled"
        static let quickCaptureKeyCode = "quickCaptureKeyCode"
        static let quickCaptureModifiers = "quickCaptureModifiers"
        static let revealOnHover = "revealOnHover"
        static let revealModifier = "revealModifier"
        static let revealDisplays = "revealDisplays"
        static let revealDisplayIDs = "revealDisplayIDs"
    }

    /// Hovering in the corner reveals the panel (control audit item 10).
    /// On by default; off, the panel opens only explicitly (the menu bar
    /// icon, quick capture, New Note).
    @Published var revealOnHover: Bool {
        didSet { defaults.set(revealOnHover, forKey: Key.revealOnHover) }
    }

    /// A key that must be held as the pointer arrives in the corner.
    @Published var revealModifier: RevealModifier {
        didSet { defaults.set(revealModifier.rawValue, forKey: Key.revealModifier) }
    }

    /// Every display's corner, or only the chosen displays'.
    @Published var revealDisplays: RevealDisplays {
        didSet { defaults.set(revealDisplays.rawValue, forKey: Key.revealDisplays) }
    }

    /// The chosen displays (`AtticDisplay.id`), sorted. A display that is
    /// not connected keeps its place, so it answers again when it returns.
    @Published var revealDisplayIDs: [String] {
        didSet {
            let normalized = Array(Set(revealDisplayIDs.filter { !$0.isEmpty })).sorted()
            if normalized != revealDisplayIDs {
                revealDisplayIDs = normalized
            } else {
                defaults.set(revealDisplayIDs, forKey: Key.revealDisplayIDs)
            }
        }
    }

    /// The hover rule the corner monitor applies.
    var cornerRevealPolicy: CornerRevealPolicy {
        CornerRevealPolicy(revealsOnHover: revealOnHover, modifier: revealModifier, displays: revealDisplays,
                           selectedDisplayIDs: Set(revealDisplayIDs))
    }

    /// The global quick capture shortcut is claimed (round 10: Settings ›
    /// General › Quick Capture). On by default.
    @Published var quickCaptureEnabled: Bool {
        didSet { defaults.set(quickCaptureEnabled, forKey: Key.quickCaptureEnabled) }
    }

    /// Its combination: ⌃⌥Space unless the person recorded another.
    @Published var quickCaptureShortcut: GlobalHotKeyCombination {
        didSet {
            if quickCaptureShortcut == .newTask {
                defaults.removeObject(forKey: Key.quickCaptureKeyCode)
                defaults.removeObject(forKey: Key.quickCaptureModifiers)
            } else {
                defaults.set(Int(quickCaptureShortcut.keyCode), forKey: Key.quickCaptureKeyCode)
                defaults.set(Int(quickCaptureShortcut.modifiers), forKey: Key.quickCaptureModifiers)
            }
        }
    }

    @Published var corner: ScreenCorner {
        didSet { defaults.set(corner.rawValue, forKey: Key.corner) }
    }

    @Published var panelTheme: AtticPanelTheme {
        didSet { defaults.set(panelTheme.rawValue, forKey: Key.panelTheme) }
    }

    /// Solid, Glass or Frosted. Reduce Transparency renders Solid without
    /// changing this choice.
    @Published var panelSurfaceStyle: PanelSurfaceStyle {
        didSet { defaults.set(panelSurfaceStyle.rawValue, forKey: Key.panelSurfaceStyle) }
    }

    /// The Tint across the top of the panel: Original's neutral shade or a
    /// custom palette's accent wash.
    @Published var panelTint: PanelTintLevel {
        didSet { defaults.set(panelTint.rawValue, forKey: Key.panelTint) }
    }

    /// How far down the panel the Tint reaches (`PanelTintLength.range`).
    @Published var panelTintLength: Double {
        didSet {
            // Assigning inside the observer does not re-run it, so the
            // clamped value is stored here rather than by a second didSet.
            let clamped = PanelTintLength.clamped(panelTintLength)
            if clamped != panelTintLength { panelTintLength = clamped }
            defaults.set(clamped, forKey: Key.panelTintLength)
        }
    }

    @Published var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    @Published var isAgentAccessEnabled: Bool {
        didSet { defaults.set(isAgentAccessEnabled, forKey: Key.isAgentAccessEnabled) }
    }

    @Published var inAppAgentBackend: AgentBackend {
        didSet { defaults.set(inAppAgentBackend.rawValue, forKey: Key.inAppAgentBackend) }
    }

    /// Each agent keeps its own model and thinking level (2026-11-10), always
    /// one Attic lists. A run reads it when it starts, so a change applies
    /// from the next message.
    @Published private(set) var inAppAgentChoices: [AgentBackend: AgentRunChoice]

    func inAppAgentChoice(for backend: AgentBackend) -> AgentRunChoice {
        inAppAgentChoices[backend] ?? AgentModelCatalog.defaultChoice(for: backend)
    }

    func setInAppAgentChoice(_ choice: AgentRunChoice, for backend: AgentBackend) {
        let listed = AgentModelCatalog.normalized(choice, for: backend)
        inAppAgentChoices[backend] = listed
        let keys = Self.choiceKeys(for: backend)
        defaults.set(listed.model, forKey: keys.model)
        if let effort = listed.effort { defaults.set(effort, forKey: keys.effort) }
        else { defaults.removeObject(forKey: keys.effort) }
    }

    private static func choiceKeys(for backend: AgentBackend) -> (model: String, effort: String) {
        backend == .claude ? (Key.inAppAgentClaudeModel, Key.inAppAgentClaudeEffort)
            : (Key.inAppAgentCodexModel, Key.inAppAgentCodexEffort)
    }

    private static func storedChoices(_ defaults: UserDefaults) -> [AgentBackend: AgentRunChoice] {
        var choices: [AgentBackend: AgentRunChoice] = [:]
        for backend in AgentBackend.allCases {
            let keys = choiceKeys(for: backend)
            let stored = defaults.string(forKey: keys.model).map {
                AgentRunChoice(model: $0, effort: defaults.string(forKey: keys.effort))
            }
            choices[backend] = AgentModelCatalog.normalized(stored, for: backend)
        }
        return choices
    }

    /// The light haptic tick when a task is completed or a dragged item
    /// snaps into place (spec § Touch and sound). On by default.
    @Published var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) }
    }

    /// Short, quiet sounds when something lands (Accepted 2026-11-10,
    /// "Sounds"; `AtticSounds`). On by default.
    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: Key.soundsEnabled) }
    }

    /// "Next event in Now" (Accepted 2026-10-29): today's next event at the
    /// top of Now's Today, once Calendar access has been granted. On by
    /// default, as the design's switch is.
    @Published var nextEventInNow: Bool {
        didSet { defaults.set(nextEventInNow, forKey: Key.nextEventInNow) }
    }

    /// Lively (the default) or Subtle springs, or Reduced motion (round 9,
    /// owner item 26; owner 2026-10-01). Reduced, like macOS Reduce Motion
    /// (which forces it whatever is chosen), turns every movement into a
    /// crossfade or an instant change. Changing levels restores its spring recipe.
    @Published var animations: AtticAnimationLevel {
        didSet {
            defaults.set(animations.rawValue, forKey: Key.animations)
            AtticMotionPreference.level = animations
            guard oldValue != animations else { return }
            applyAnimationLevel()
        }
    }

    /// When motion is reduced (Animations: Reduced, or macOS Reduce
    /// Motion): Instant (the default) or Fade (Accepted 2026-11-10).
    @Published var reducedMotionStyle: AtticReducedMotionStyle {
        didSet {
            defaults.set(reducedMotionStyle.rawValue, forKey: Key.reducedMotionStyle)
            AtticReducedMotionStyle.current = reducedMotionStyle
        }
    }

    /// Animations owns the spring recipe; the preview experiment only changes native popovers.
    var motionFeel: AtticMotionFeel { animations.feel }

    @Published var motionTuning: AtticMotionTuning {
        didSet {
            AtticMotionTuning.current = motionTuning
            guard motionLabAvailable, !appliesLevelTuning,
                  let data = try? JSONEncoder().encode(motionTuning) else { return }
            defaults.set(data, forKey: Key.motionLabTuning)
        }
    }

    private var appliesLevelTuning = false

    private func applyAnimationLevel() {
        if motionLabAvailable { defaults.removeObject(forKey: Key.motionLabTuning) }
        appliesLevelTuning = true
        defer { appliesLevelTuning = false }
        motionTuning = animations.feel.tuning
    }

    let motionLabAvailable: Bool

    /// How the panel hides and reveals (Settings › General › Behaviour).
    @Published var hideAnimation: PanelHideAnimation {
        didSet { defaults.set(hideAnimation.rawValue, forKey: Key.hideAnimation) }
    }

    /// Where the island sits around the docked panel (Settings › Panel;
    /// Accepted 2026-11-01 "Island position"). Stored relative to the
    /// corner, so moving the panel keeps it.
    @Published var islandSpot: PanelIslandSpot {
        didSet { defaults.set(islandSpot.rawValue, forKey: Key.islandSpot) }
    }

    /// The preview-only speed lab's hide and reveal durations. Under the
    /// release identity it is never read or stored, so every animation runs
    /// at its own default.
    @Published var hideSpeedLab: PanelHideSpeedLab {
        didSet {
            guard motionLabAvailable else {
                if hideSpeedLab != PanelHideSpeedLab() { hideSpeedLab = PanelHideSpeedLab() }
                return
            }
            if hideSpeedLab.isDefault {
                defaults.removeObject(forKey: Key.hideSpeedLab)
            } else if let data = try? JSONEncoder().encode(hideSpeedLab) {
                defaults.set(data, forKey: Key.hideSpeedLab)
            }
        }
    }

    /// How long `mode` hides (or reveals): the lab's value in previews, the
    /// animation's own default otherwise.
    func hideMotionDuration(_ mode: PanelHideAnimation, hiding: Bool) -> TimeInterval {
        motionLabAvailable ? hideSpeedLab.duration(mode, hiding: hiding)
            : hiding ? mode.defaultHideDuration : mode.defaultRevealDuration
    }

    @Published var panelCornerSize: Double {
        didSet {
            let clamped = Self.clamp(panelCornerSize, to: PanelCornerSize.min...PanelCornerSize.max, fallback: PanelCornerSize.defaultValue)
            if panelCornerSize != clamped {
                panelCornerSize = clamped
            } else {
                defaults.set(panelCornerSize, forKey: Key.panelCornerSize)
            }
        }
    }

    @Published var panelContentSize: Double {
        didSet {
            let clamped = Self.clampWidth(panelContentSize)
            if panelContentSize != clamped {
                panelContentSize = clamped
            } else {
                defaults.set(panelContentSize, forKey: Key.panelContentSize)
            }
        }
    }

    @Published private(set) var panelHeight: Double {
        didSet {
            let clamped = Self.clampMinimum(
                panelHeight,
                minimum: PanelGeometry.minimumHeight,
                fallback: PanelGeometry.defaultPanelSize.height
            )
            if panelHeight != clamped {
                panelHeight = clamped
            } else {
                defaults.set(panelHeight, forKey: Key.panelHeight)
            }
        }
    }

    @Published private(set) var cloudSyncStartupErrorMessage: String?

    @Published var revealDelay: Double {
        didSet {
            let clamped = Self.clamp(revealDelay, to: 0.2...2.0, fallback: 0.2)
            if revealDelay != clamped {
                revealDelay = clamped
            } else {
                defaults.set(revealDelay, forKey: Key.revealDelay)
            }
        }
    }

    @Published var hideDelay: Double {
        didSet {
            let clamped = Self.clamp(hideDelay, to: 0.1...2.0, fallback: 0.3)
            if hideDelay != clamped {
                hideDelay = clamped
            } else {
                defaults.set(hideDelay, forKey: Key.hideDelay)
            }
        }
    }

    @Published var panelDismissMode: PanelDismissMode {
        didSet { defaults.set(panelDismissMode.rawValue, forKey: Key.panelDismissMode) }
    }

    private let defaults: UserDefaults
    /// The defaults these settings live in (the "+" card keeps its draft beside them).
    var userDefaults: UserDefaults { defaults }

    init(defaults: UserDefaults = .standard, motionLabAvailable: Bool = AtticMotionLab.isAvailable) {
        self.defaults = defaults
        self.motionLabAvailable = motionLabAvailable
        cloudSyncStartupErrorMessage = nil
        corner = ScreenCorner(rawValue: defaults.string(forKey: Key.corner) ?? "") ?? .topRight
        let storedDelay = defaults.object(forKey: Key.revealDelay) as? Double
        var resolvedDelay = storedDelay ?? 0.2
        if !defaults.bool(forKey: Key.hasAdoptedFasterReveal) {
            if abs(resolvedDelay - 0.5) < 0.001 {
                resolvedDelay = 0.4
                defaults.set(resolvedDelay, forKey: Key.revealDelay)
            }
            defaults.set(true, forKey: Key.hasAdoptedFasterReveal)
        }
        if !defaults.bool(forKey: Key.hasAdoptedQuickerReveal) {
            if storedDelay == nil || abs(resolvedDelay - 0.4) < 0.001 || abs(resolvedDelay - 0.5) < 0.001 {
                resolvedDelay = 0.3
                defaults.set(resolvedDelay, forKey: Key.revealDelay)
            }
            defaults.set(true, forKey: Key.hasAdoptedQuickerReveal)
        }
        if !defaults.bool(forKey: Key.hasAdoptedInstantReveal) {
            if storedDelay == nil || abs(resolvedDelay - 0.3) < 0.001 {
                resolvedDelay = 0.2
                defaults.set(resolvedDelay, forKey: Key.revealDelay)
            }
            defaults.set(true, forKey: Key.hasAdoptedInstantReveal)
        }
        revealDelay = Self.clamp(resolvedDelay, to: 0.2...2.0, fallback: 0.2)
        let storedHideDelay = defaults.object(forKey: Key.hideDelay) as? Double
        hideDelay = Self.clamp(storedHideDelay ?? 0.3, to: 0.1...2.0, fallback: 0.3)
        panelDismissMode = PanelDismissMode(rawValue: defaults.string(forKey: Key.panelDismissMode) ?? "") ?? .clickAway
        // Before any appearance key is read: the retired translucency /
        // glass-style / gradient preferences become Surface and Tint
        // exactly once, and a fresh install receives the new defaults.
        AppearanceMigration.migrateIfNeeded(defaults)
        panelTheme = AtticPanelTheme(
            rawValue: defaults.string(forKey: Key.panelTheme) ?? ""
        ) ?? .defaultTheme
        panelSurfaceStyle = PanelSurfaceStyle(
            rawValue: defaults.string(forKey: Key.panelSurfaceStyle) ?? ""
        ) ?? .defaultStyle
        panelTint = PanelTintLevel(
            rawValue: defaults.string(forKey: Key.panelTint) ?? ""
        ) ?? .defaultLevel
        panelTintLength = PanelTintLength.clamped(
            defaults.object(forKey: Key.panelTintLength) as? Double ?? PanelTintLength.defaultValue
        )
        appearance = AppearancePreference(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        if !defaults.bool(forKey: Key.hasAdoptedAgentAccessOptIn) {
            // Earlier MCP builds enabled the mutating local server implicitly.
            // Require one explicit opt-in from every existing installation.
            defaults.set(false, forKey: Key.isAgentAccessEnabled)
            defaults.set(true, forKey: Key.hasAdoptedAgentAccessOptIn)
        }
        isAgentAccessEnabled = (defaults.object(forKey: Key.isAgentAccessEnabled) as? Bool) ?? false
        inAppAgentBackend = AgentBackend(rawValue: defaults.string(forKey: Key.inAppAgentBackend) ?? "") ?? .claude
        inAppAgentChoices = Self.storedChoices(defaults)
        hapticsEnabled = (defaults.object(forKey: Key.hapticsEnabled) as? Bool) ?? true
        soundsEnabled = (defaults.object(forKey: Key.soundsEnabled) as? Bool) ?? true
        nextEventInNow = (defaults.object(forKey: Key.nextEventInNow) as? Bool) ?? true
        quickCaptureEnabled = (defaults.object(forKey: Key.quickCaptureEnabled) as? Bool) ?? true
        revealOnHover = (defaults.object(forKey: Key.revealOnHover) as? Bool) ?? true
        revealModifier = RevealModifier(rawValue: defaults.string(forKey: Key.revealModifier) ?? "") ?? .none
        revealDisplays = RevealDisplays(rawValue: defaults.string(forKey: Key.revealDisplays) ?? "") ?? .all
        revealDisplayIDs = Array(Set((defaults.stringArray(forKey: Key.revealDisplayIDs) ?? []).filter { !$0.isEmpty })).sorted()
        if let code = defaults.object(forKey: Key.quickCaptureKeyCode) as? Int,
           let mask = defaults.object(forKey: Key.quickCaptureModifiers) as? Int, code >= 0, mask >= 0 {
            let stored = GlobalHotKeyCombination(keyCode: UInt32(code), modifiers: UInt32(mask))
            // A stored value Attic can't claim safely falls back to the default.
            quickCaptureShortcut = stored.recordingProblem == nil ? stored : .newTask
        } else {
            quickCaptureShortcut = .newTask
        }
        // An earlier build stored "full" (now Lively) or "reduced".
        let storedAnimations = AtticAnimationLevel.migrated(from: defaults.string(forKey: Key.animations))
        if defaults.string(forKey: Key.animations) == "full" {
            defaults.set(storedAnimations.rawValue, forKey: Key.animations)
        }
        animations = storedAnimations
        AtticMotionPreference.level = storedAnimations
        let storedReduced = defaults.string(forKey: Key.reducedMotionStyle).flatMap(AtticReducedMotionStyle.init(rawValue:)) ?? .default
        reducedMotionStyle = storedReduced
        AtticReducedMotionStyle.current = storedReduced
        // Preserve the native-popover experiment from older lab data, ignoring retired tuning choices.
        let storedTuning = motionLabAvailable
            ? defaults.data(forKey: Key.motionLabTuning).flatMap { try? JSONDecoder().decode(AtticMotionTuning.self, from: $0) }
            : nil
        var tuning = storedAnimations.feel.tuning
        tuning.popsNativePopovers = storedTuning?.popsNativePopovers ?? false
        motionTuning = tuning
        AtticMotionTuning.current = tuning
        hideAnimation = defaults.string(forKey: Key.hideAnimation)
            .flatMap(PanelHideAnimation.init(storedValue:)) ?? .defaultValue
        islandSpot = defaults.string(forKey: Key.islandSpot).flatMap(PanelIslandSpot.init(rawValue:)) ?? .defaultSpot
        // Genie Classic (dropped 2026-10-21) is stored as Genie from now on.
        if defaults.string(forKey: Key.hideAnimation) == "genie" {
            defaults.set(PanelHideAnimation.genieLiveGlass.rawValue, forKey: Key.hideAnimation)
        }
        hideSpeedLab = motionLabAvailable
            ? defaults.data(forKey: Key.hideSpeedLab).flatMap { try? JSONDecoder().decode(PanelHideSpeedLab.self, from: $0) }
                ?? PanelHideSpeedLab()
            : PanelHideSpeedLab()
        panelCornerSize = Self.clamp(
            defaults.object(forKey: Key.panelCornerSize) as? Double ?? PanelCornerSize.defaultValue,
            to: PanelCornerSize.min...PanelCornerSize.max,
            fallback: PanelCornerSize.defaultValue
        )
        let resolvedPanelWidth = Self.clampWidth(
            defaults.object(forKey: Key.panelContentSize) as? Double ?? PanelContentSize.defaultValue
        )
        panelContentSize = resolvedPanelWidth
        panelHeight = Self.clampMinimum(
            defaults.object(forKey: Key.panelHeight) as? Double
                ?? PanelGeometry.preferredWorkspaceHeight(contentWidth: resolvedPanelWidth),
            minimum: PanelGeometry.minimumHeight,
            fallback: PanelGeometry.defaultPanelSize.height
        )
    }

    /// The one place the appearance settings become a drawable surface. The
    /// main panel and its surfaces call this, so they can only ever render
    /// the same treatment.
    func panelSurfaceTreatment(
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast,
        reduceTransparency: Bool
    ) -> AtticPanelSurfaceTreatment {
        panelTheme.surfaceTreatment(
            colorScheme: colorScheme,
            contrast: contrast,
            surface: panelSurfaceStyle,
            tint: panelTint,
            tintLength: panelTintLength,
            reduceTransparency: reduceTransparency
        )
    }

    var agentServerPort: UInt16 {
        guard let stored = defaults.object(forKey: Key.agentServerPort) as? Int,
              (1024...65_535).contains(stored) else {
            return AgentServer.defaultPort
        }
        return UInt16(stored)
    }

    var hasShownWelcome: Bool {
        defaults.bool(forKey: Key.hasShownWelcome)
    }

    func markWelcomeShown() {
        defaults.set(true, forKey: Key.hasShownWelcome)
    }

    func reportCloudSyncStartupFailure(_ message: String) {
        cloudSyncStartupErrorMessage = message
    }

    /// Called once after AppKit finishes a manual live resize. Keeping this
    /// separate from live layout updates avoids continuously writing defaults
    /// while the pointer is moving.
    /// The pages pulled out into their own panels, with their frames and
    /// pins (`PanelPullOutState`), restored at the next launch.
    var floatingPanelsData: Data? {
        get { defaults.data(forKey: "panelFloatingPages") }
        set { defaults.set(newValue, forKey: "panelFloatingPages") }
    }

    func persistPanelSize(_ size: CGSize) {
        let clamped = PanelGeometry.clampedPanelSize(size)
        if panelContentSize != clamped.width {
            panelContentSize = clamped.width
        }
        if panelHeight != clamped.height {
            panelHeight = clamped.height
        }
    }

    private static func clamp(
        _ value: Double,
        to range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Height remains independent of the attached display; width is capped
    /// at the reading width above.
    /// A value beyond any display's plausible size is a corrupt preference
    /// rather than a choice, though, and previously survived validation as a
    /// finite magnitude that layout and numeric formatting could not use.
    static let maximumRestorableDimension: Double = 50_000

    private static func clampWidth(_ value: Double) -> Double {
        min(PanelContentSize.max, clampMinimum(value, minimum: PanelContentSize.min,
                                              fallback: PanelContentSize.defaultValue))
    }

    private static func clampMinimum(
        _ value: Double,
        minimum: Double,
        fallback: Double
    ) -> Double {
        guard value.isFinite, value <= maximumRestorableDimension else { return fallback }
        return max(value, minimum)
    }

}
