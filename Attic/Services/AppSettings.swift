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

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
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

    var title: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Default"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        case .huge: return "Huge"
        case .enormous: return "Enormous"
        case .maximum: return "Maximum"
        }
    }

    static let min = PanelCornerSize.small.rawValue
    static let max = PanelCornerSize.maximum.rawValue
    static let defaultValue = PanelCornerSize.huge.rawValue
}

/// User-adjustable and live-resizable width of the panel, in points.
enum PanelContentSize: Double, CaseIterable, Identifiable {
    case standard = 320
    case large = 360
    case extraLarge = 380

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    static let min = PanelContentSize.standard.rawValue
    static var max: Double {
        NSScreen.screens
            .map { Swift.max(min, $0.visibleFrame.width - (PanelGeometry.screenInset * 2)) }
            .max() ?? min
    }
    static let defaultValue = PanelContentSize.standard.rawValue
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let corner = "selectedCorner"
        static let revealDelay = "revealDelay"
        static let hideDelay = "hideDelay"
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
        static let agentServerPort = "agentServerPort"
        static let hasAdoptedAgentAccessOptIn = "hasAdoptedAgentAccessOptIn"
        static let panelCornerSize = "panelCornerSize"
        static let panelContentSize = "panelContentSize"
        static let panelHeight = "panelHeight"
        static let pinnedSubtaskWindowFrame = "pinnedSubtaskWindowFrame"
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
            let clamped = Self.clampMinimum(
                panelContentSize,
                minimum: PanelContentSize.min,
                fallback: PanelContentSize.defaultValue
            )
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

    /// Last on-screen frame of the pinned subtask mini-window. Persisted as
    /// a rect string so reopening restores position; invalid or stale values
    /// fall back to anchored placement beside the main panel.
    ///
    /// The size is bounded the same way a restored panel dimension is. A
    /// width of `.infinity` passes `>= 1`, and a finite `1e30` passes as well;
    /// either one then reaches window placement and numeric formatting, which
    /// cannot use it. A frame the user really chose on a display that is not
    /// attached right now is far inside these limits, so it still restores.
    var pinnedSubtaskWindowFrame: CGRect? {
        get {
            guard let stored = defaults.string(forKey: Key.pinnedSubtaskWindowFrame),
                  !stored.isEmpty else { return nil }
            let rect = NSRectFromString(stored)
            guard Self.isRestorableFrame(rect) else { return nil }
            return rect
        }
        set {
            if let newValue {
                defaults.set(NSStringFromRect(newValue), forKey: Key.pinnedSubtaskWindowFrame)
            } else {
                defaults.removeObject(forKey: Key.pinnedSubtaskWindowFrame)
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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        panelCornerSize = Self.clamp(
            defaults.object(forKey: Key.panelCornerSize) as? Double ?? PanelCornerSize.defaultValue,
            to: PanelCornerSize.min...PanelCornerSize.max,
            fallback: PanelCornerSize.defaultValue
        )
        let resolvedPanelWidth = Self.clampMinimum(
            defaults.object(forKey: Key.panelContentSize) as? Double ?? PanelContentSize.defaultValue,
            minimum: PanelContentSize.min,
            fallback: PanelContentSize.defaultValue
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
    /// main panel and the subtask checklist windows both call this, so they
    /// can only ever render the same treatment.
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

    /// Panel width and height have no fixed upper bound: the user may have
    /// sized the panel on a display that is not attached right now, and
    /// shrinking a valid preference to fit the current screen would lose it.
    /// A value beyond any display's plausible size is a corrupt preference
    /// rather than a choice, though, and previously survived validation as a
    /// finite magnitude that layout and numeric formatting could not use.
    static let maximumRestorableDimension: Double = 50_000

    private static func clampMinimum(
        _ value: Double,
        minimum: Double,
        fallback: Double
    ) -> Double {
        guard value.isFinite, value <= maximumRestorableDimension else { return fallback }
        return max(value, minimum)
    }

    /// A stored window frame Attic is willing to restore: a usable size, and
    /// every component finite and within the magnitude a display could
    /// justify. An origin may be negative — a window on a display left of or
    /// below the main one — so only its magnitude is bounded.
    static func isRestorableFrame(_ rect: CGRect) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return false }
        guard rect.width >= 1, rect.height >= 1,
              rect.width <= maximumRestorableDimension,
              rect.height <= maximumRestorableDimension else { return false }
        return abs(rect.origin.x) <= maximumRestorableDimension
            && abs(rect.origin.y) <= maximumRestorableDimension
    }
}
