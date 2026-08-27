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

enum PanelGlassMaterialPreference: String, CaseIterable, Identifiable, Hashable {
    case regular
    case clear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regular: return "Regular"
        case .clear: return "Clear"
        }
    }
}

enum PanelGlassTintPreference: String, CaseIterable, Identifiable, Hashable {
    case none
    case accent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .accent: return "Accent"
        }
    }
}

enum PanelGlassResponsePreference: String, CaseIterable, Identifiable, Hashable {
    case `static`
    case interactive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .static: return "Static"
        case .interactive: return "Interactive"
        }
    }
}

/// The independent user choices Apple exposes for a custom Glass surface.
struct PanelGlassPreferences: Equatable {
    let material: PanelGlassMaterialPreference
    let tint: PanelGlassTintPreference
    let response: PanelGlassResponsePreference
}

/// Every application-owned input to panel appearance resolution.
///
/// Window focus is deliberately absent. AppKit and SwiftUI may adapt system
/// rendering internally, but Attic never supplies a different profile when the
/// panel becomes key, resigns key, or the app deactivates.
struct PanelGlassResolutionInputs: Equatable {
    let preferences: PanelGlassPreferences
    let supportsNativeGlass: Bool
    let reduceTransparency: Bool
}

enum PanelGlassSurface: Equatable {
    case native(PanelGlassMaterialPreference)
    case legacyMaterial
    case opaque
}

struct PanelGlassProfile: Equatable {
    let surface: PanelGlassSurface
    let tint: PanelGlassTintPreference
    let response: PanelGlassResponsePreference

    static func resolve(_ inputs: PanelGlassResolutionInputs) -> PanelGlassProfile {
        if inputs.reduceTransparency {
            return PanelGlassProfile(
                surface: .opaque,
                tint: .none,
                response: .static
            )
        }

        guard inputs.supportsNativeGlass else {
            return PanelGlassProfile(
                surface: .legacyMaterial,
                tint: .none,
                response: .static
            )
        }

        return PanelGlassProfile(
            surface: .native(inputs.preferences.material),
            tint: inputs.preferences.tint,
            response: inputs.preferences.response
        )
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
    static let defaultValue = PanelCornerSize.standard.rawValue
}

/// User-adjustable content width of the panel, in points.
enum PanelContentSize: Double, CaseIterable, Identifiable {
    case compact = 300
    case standard = 332
    case large = 360
    case extraLarge = 380

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Default"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    static let min = PanelContentSize.compact.rawValue
    static let max = PanelContentSize.extraLarge.rawValue
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
        static let legacyTranslucency = "isTranslucent"
        static let legacyConsistentAppearance = "consistentAppearance"
        static let panelGlassMaterial = "panelGlassMaterial"
        static let panelGlassTint = "panelGlassTint"
        static let panelGlassResponse = "panelGlassResponse"
        static let hasMigratedToNativeGlassProfile = "hasMigratedToNativeGlassProfileV1"
        static let appearance = "appearancePreference"
        static let isAgentAccessEnabled = "isAgentAccessEnabled"
        static let agentServerPort = "agentServerPort"
        static let hasAdoptedAgentAccessOptIn = "hasAdoptedAgentAccessOptIn"
        static let panelCornerSize = "panelCornerSize"
        static let panelContentSize = "panelContentSize"
    }

    @Published var corner: ScreenCorner {
        didSet { defaults.set(corner.rawValue, forKey: Key.corner) }
    }

    /// Temporary source compatibility while the panel and Settings view move
    /// to the discrete native profile. It intentionally does not persist.
    @Published var isTranslucent = true

    @Published var panelGlassMaterial: PanelGlassMaterialPreference {
        didSet { defaults.set(panelGlassMaterial.rawValue, forKey: Key.panelGlassMaterial) }
    }

    @Published var panelGlassTint: PanelGlassTintPreference {
        didSet { defaults.set(panelGlassTint.rawValue, forKey: Key.panelGlassTint) }
    }

    @Published var panelGlassResponse: PanelGlassResponsePreference {
        didSet { defaults.set(panelGlassResponse.rawValue, forKey: Key.panelGlassResponse) }
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
            let clamped = Self.clamp(panelContentSize, to: PanelContentSize.min...PanelContentSize.max, fallback: PanelContentSize.defaultValue)
            if panelContentSize != clamped {
                panelContentSize = clamped
            } else {
                defaults.set(panelContentSize, forKey: Key.panelContentSize)
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

        let glassPreferences = Self.resolvePanelGlassPreferences(defaults: defaults)
        panelGlassMaterial = glassPreferences.material
        panelGlassTint = glassPreferences.tint
        panelGlassResponse = glassPreferences.response

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
        panelContentSize = Self.clamp(
            defaults.object(forKey: Key.panelContentSize) as? Double ?? PanelContentSize.defaultValue,
            to: PanelContentSize.min...PanelContentSize.max,
            fallback: PanelContentSize.defaultValue
        )
    }

    var panelGlassPreferences: PanelGlassPreferences {
        PanelGlassPreferences(
            material: panelGlassMaterial,
            tint: panelGlassTint,
            response: panelGlassResponse
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

    private static func resolvePanelGlassPreferences(defaults: UserDefaults) -> PanelGlassPreferences {
        let material = PanelGlassMaterialPreference(
            rawValue: defaults.string(forKey: Key.panelGlassMaterial) ?? ""
        ) ?? .regular
        let tint = PanelGlassTintPreference(
            rawValue: defaults.string(forKey: Key.panelGlassTint) ?? ""
        ) ?? .none
        let response = PanelGlassResponsePreference(
            rawValue: defaults.string(forKey: Key.panelGlassResponse) ?? ""
        ) ?? .interactive

        let preferences = PanelGlassPreferences(
            material: material,
            tint: tint,
            response: response
        )

        // The former translucency and focus-consistency controls do not map to
        // independent native Glass capabilities. Normalize once to the honest
        // native profile, persist it, and remove the obsolete inputs.
        defaults.set(preferences.material.rawValue, forKey: Key.panelGlassMaterial)
        defaults.set(preferences.tint.rawValue, forKey: Key.panelGlassTint)
        defaults.set(preferences.response.rawValue, forKey: Key.panelGlassResponse)
        defaults.set(true, forKey: Key.hasMigratedToNativeGlassProfile)
        defaults.removeObject(forKey: Key.legacyTranslucency)
        defaults.removeObject(forKey: Key.legacyConsistentAppearance)

        return preferences
    }

    private static func clamp(
        _ value: Double,
        to range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
