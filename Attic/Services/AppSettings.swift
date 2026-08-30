import AppKit
import Combine
import Foundation

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

enum PanelGlassStyle: String, CaseIterable, Identifiable {
    case clear
    case frosted
    /// Keeps the earlier `stable` preference compatible while restoring the
    /// original live macOS material used by Attic.
    case glassmorphism = "stable"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear: return "Clear"
        case .frosted: return "Frosted"
        case .glassmorphism: return "Glassmorphism"
        }
    }

    var detail: String {
        switch self {
        case .clear:
            return "Maximum live transparency and native refraction."
        case .frosted:
            return "Native blur with stronger contrast."
        case .glassmorphism:
            return "Classic live macOS blur and vibrancy, matching Attic's original surface."
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
    case standard = 332
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
        static let isTranslucent = "isTranslucent"
        static let panelGlassStyle = "panelGlassStyle"
        static let appearance = "appearancePreference"
        static let isAgentAccessEnabled = "isAgentAccessEnabled"
        static let agentServerPort = "agentServerPort"
        static let hasAdoptedAgentAccessOptIn = "hasAdoptedAgentAccessOptIn"
        static let panelCornerSize = "panelCornerSize"
        static let panelContentSize = "panelContentSize"
        static let panelHeight = "panelHeight"
    }

    @Published var corner: ScreenCorner {
        didSet { defaults.set(corner.rawValue, forKey: Key.corner) }
    }

    @Published var isTranslucent: Bool {
        didSet { defaults.set(isTranslucent, forKey: Key.isTranslucent) }
    }

    @Published var panelGlassStyle: PanelGlassStyle {
        didSet { defaults.set(panelGlassStyle.rawValue, forKey: Key.panelGlassStyle) }
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
        isTranslucent = (defaults.object(forKey: Key.isTranslucent) as? Bool) ?? true
        let storedGlassStyle = defaults.string(forKey: Key.panelGlassStyle) ?? ""
        if storedGlassStyle == "liveStable" {
            panelGlassStyle = .glassmorphism
            defaults.set(PanelGlassStyle.glassmorphism.rawValue, forKey: Key.panelGlassStyle)
        } else {
            panelGlassStyle = PanelGlassStyle(rawValue: storedGlassStyle) ?? .clear
        }
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

    private static func clampMinimum(
        _ value: Double,
        minimum: Double,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return max(value, minimum)
    }
}
