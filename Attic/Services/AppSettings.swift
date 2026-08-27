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
        static let legacyIsTranslucent = "isTranslucent"
        static let appearance = "appearancePreference"
        static let isAgentAccessEnabled = "isAgentAccessEnabled"
        static let agentServerPort = "agentServerPort"
        static let hasAdoptedAgentAccessOptIn = "hasAdoptedAgentAccessOptIn"
        static let panelCornerSize = "panelCornerSize"
        static let panelContentSize = "panelContentSize"
        static let glassPerformancePreset = "glassPerformancePreset"
        static let glassTransparency = "glassTransparency"
        static let glassFrost = "glassFrost"
        static let glassRefraction = "glassRefraction"
        static let glassEdgeShine = "glassEdgeShine"
        static let glassTint = "glassTint"
        static let glassReadability = "glassReadability"
        static let glassInteractionResponse = "glassInteractionResponse"
    }

    @Published var corner: ScreenCorner {
        didSet { defaults.set(corner.rawValue, forKey: Key.corner) }
    }

    @Published var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    @Published var isAgentAccessEnabled: Bool {
        didSet { defaults.set(isAgentAccessEnabled, forKey: Key.isAgentAccessEnabled) }
    }

    @Published var panelCornerSize: Double {
        didSet {
            let clamped = Self.clamp(
                panelCornerSize,
                to: PanelCornerSize.min...PanelCornerSize.max,
                fallback: PanelCornerSize.defaultValue
            )
            if panelCornerSize != clamped {
                panelCornerSize = clamped
            }
            defaults.set(clamped, forKey: Key.panelCornerSize)
        }
    }

    @Published var panelContentSize: Double {
        didSet {
            let clamped = Self.clamp(
                panelContentSize,
                to: PanelContentSize.min...PanelContentSize.max,
                fallback: PanelContentSize.defaultValue
            )
            if panelContentSize != clamped {
                panelContentSize = clamped
            }
            defaults.set(clamped, forKey: Key.panelContentSize)
        }
    }

    @Published var glassPerformancePreset: OpticalPerformancePreset {
        didSet {
            defaults.set(glassPerformancePreset.rawValue, forKey: Key.glassPerformancePreset)
        }
    }

    @Published var glassTransparency: Double {
        didSet {
            let clamped = Self.opticalControl(
                glassTransparency,
                fallback: OpticalGlassControls.defaults.transparency
            )
            if glassTransparency != clamped {
                glassTransparency = clamped
            }
            defaults.set(clamped, forKey: Key.glassTransparency)
        }
    }

    @Published var glassFrost: Double {
        didSet {
            let clamped = Self.opticalControl(
                glassFrost,
                fallback: OpticalGlassControls.defaults.frost
            )
            if glassFrost != clamped {
                glassFrost = clamped
            }
            defaults.set(clamped, forKey: Key.glassFrost)
        }
    }

    @Published var glassRefraction: Double {
        didSet {
            let clamped = Self.opticalControl(
                glassRefraction,
                fallback: OpticalGlassControls.defaults.refraction
            )
            if glassRefraction != clamped {
                glassRefraction = clamped
            }
            defaults.set(clamped, forKey: Key.glassRefraction)
        }
    }

    @Published var glassEdgeShine: Double {
        didSet {
            let clamped = Self.opticalControl(
                glassEdgeShine,
                fallback: OpticalGlassControls.defaults.edgeShine
            )
            if glassEdgeShine != clamped {
                glassEdgeShine = clamped
            }
            defaults.set(clamped, forKey: Key.glassEdgeShine)
        }
    }

    @Published var glassTint: Double {
        didSet {
            let clamped = Self.opticalControl(
                glassTint,
                fallback: OpticalGlassControls.defaults.tint
            )
            if glassTint != clamped {
                glassTint = clamped
            }
            defaults.set(clamped, forKey: Key.glassTint)
        }
    }

    @Published var glassReadability: Double {
        didSet {
            let clamped = Self.opticalControl(
                glassReadability,
                fallback: OpticalGlassControls.defaults.readability
            )
            if glassReadability != clamped {
                glassReadability = clamped
            }
            defaults.set(clamped, forKey: Key.glassReadability)
        }
    }

    @Published var glassInteractionResponse: Double {
        didSet {
            let clamped = Self.opticalControl(
                glassInteractionResponse,
                fallback: OpticalGlassControls.defaults.interactionResponse
            )
            if glassInteractionResponse != clamped {
                glassInteractionResponse = clamped
            }
            defaults.set(clamped, forKey: Key.glassInteractionResponse)
        }
    }

    @Published private(set) var cloudSyncStartupErrorMessage: String?

    @Published var revealDelay: Double {
        didSet {
            let clamped = Self.clamp(revealDelay, to: 0.2...2.0, fallback: 0.2)
            if revealDelay != clamped {
                revealDelay = clamped
            }
            defaults.set(clamped, forKey: Key.revealDelay)
        }
    }

    @Published var hideDelay: Double {
        didSet {
            let clamped = Self.clamp(hideDelay, to: 0.1...2.0, fallback: 0.3)
            if hideDelay != clamped {
                hideDelay = clamped
            }
            defaults.set(clamped, forKey: Key.hideDelay)
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

        let opticalAxisKeys = [
            Key.glassTransparency,
            Key.glassFrost,
            Key.glassRefraction,
            Key.glassEdgeShine,
            Key.glassTint,
            Key.glassReadability,
            Key.glassInteractionResponse
        ]
        let hadStoredOpticalAxis = opticalAxisKeys.contains {
            defaults.object(forKey: $0) != nil
        }
        let storedPresetObject = defaults.object(forKey: Key.glassPerformancePreset)
        if let rawValue = storedPresetObject as? String,
           let storedPreset = OpticalPerformancePreset(rawValue: rawValue) {
            glassPerformancePreset = storedPreset
        } else if storedPresetObject == nil,
                  !hadStoredOpticalAxis,
                  defaults.object(forKey: Key.legacyIsTranslucent) as? Bool == false {
            glassPerformancePreset = .off
            defaults.set(OpticalPerformancePreset.off.rawValue, forKey: Key.glassPerformancePreset)
        } else {
            glassPerformancePreset = .balanced
            defaults.set(OpticalPerformancePreset.balanced.rawValue, forKey: Key.glassPerformancePreset)
        }

        let defaultsProfile = OpticalGlassControls.defaults
        let storedTransparency = defaults.object(forKey: Key.glassTransparency) as? Double
        if let storedTransparency {
            glassTransparency = Self.opticalControl(
                storedTransparency,
                fallback: defaultsProfile.transparency
            )
        } else if defaults.object(forKey: Key.legacyIsTranslucent) as? Bool == false {
            glassTransparency = 0
            defaults.set(0, forKey: Key.glassTransparency)
        } else {
            glassTransparency = defaultsProfile.transparency
        }
        glassFrost = Self.opticalControl(
            defaults.object(forKey: Key.glassFrost) as? Double ?? defaultsProfile.frost,
            fallback: defaultsProfile.frost
        )
        glassRefraction = Self.opticalControl(
            defaults.object(forKey: Key.glassRefraction) as? Double ?? defaultsProfile.refraction,
            fallback: defaultsProfile.refraction
        )
        glassEdgeShine = Self.opticalControl(
            defaults.object(forKey: Key.glassEdgeShine) as? Double ?? defaultsProfile.edgeShine,
            fallback: defaultsProfile.edgeShine
        )
        glassTint = Self.opticalControl(
            defaults.object(forKey: Key.glassTint) as? Double ?? defaultsProfile.tint,
            fallback: defaultsProfile.tint
        )
        glassReadability = Self.opticalControl(
            defaults.object(forKey: Key.glassReadability) as? Double ?? defaultsProfile.readability,
            fallback: defaultsProfile.readability
        )
        glassInteractionResponse = Self.opticalControl(
            defaults.object(forKey: Key.glassInteractionResponse) as? Double ?? defaultsProfile.interactionResponse,
            fallback: defaultsProfile.interactionResponse
        )
    }

    var opticalGlassControls: OpticalGlassControls {
        OpticalGlassControls(
            transparency: glassTransparency,
            frost: glassFrost,
            refraction: glassRefraction,
            edgeShine: glassEdgeShine,
            tint: glassTint,
            readability: glassReadability,
            interactionResponse: glassInteractionResponse
        )
    }

    /// Compatibility bridge for older call sites while the optical surface is
    /// owned by AppKit. It is intentionally not persisted independently.
    var isTranslucent: Bool {
        get { glassTransparency > 0 }
        set { glassTransparency = newValue ? OpticalGlassControls.defaults.transparency : 0 }
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

    private static func opticalControl(_ value: Double, fallback: Double) -> Double {
        clamp(value, to: 0...100, fallback: fallback)
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
