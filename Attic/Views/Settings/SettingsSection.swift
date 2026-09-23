import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case panel
    case appearance
    case agentAccess
    case about

    static let selectionStorageKey = "AtticSettings.selectedSection"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .panel: "Panel"
        case .appearance: "Appearance"
        case .agentAccess: "Agent Access"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .panel: "rectangle.inset.topright.filled"
        case .appearance: "paintpalette.fill"
        case .agentAccess: "sparkles"
        case .about: "info"
        }
    }

    /// The sidebar tile colour, one per section, in the System Settings idiom.
    var tint: Color {
        switch self {
        case .general: .gray
        case .panel: .blue
        case .appearance: .purple
        case .agentAccess: .orange
        case .about: .teal
        }
    }

    var accessibilityIdentifier: String {
        "settings-nav-\(rawValue)"
    }

    static func restored(from rawValue: String) -> SettingsSection {
        SettingsSection(rawValue: rawValue) ?? .general
    }
}

enum SettingsVisibility {
    static func showsLoginApproval(requiresApproval: Bool) -> Bool {
        requiresApproval
    }

    static func showsAgentConnection(isEnabled: Bool) -> Bool {
        isEnabled
    }

    /// The refused global shortcut Settings must explain, or nil while the
    /// shortcut is working or has not been attempted yet.
    static func globalShortcutFailure(_ registration: GlobalHotKeyRegistration) -> GlobalHotKeyFailure? {
        registration.failure
    }
}
