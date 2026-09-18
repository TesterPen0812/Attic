import Foundation

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
        case .general: "gearshape"
        case .panel: "rectangle.on.rectangle"
        case .appearance: "circle.lefthalf.filled"
        case .agentAccess: "sparkles"
        case .about: "info.circle"
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
}
