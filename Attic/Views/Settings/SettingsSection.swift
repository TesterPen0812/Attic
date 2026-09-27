import SwiftUI

/// The Settings pages, in sidebar order. Raw values are persisted (the
/// remembered page) and name the UI-test identifiers.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case panel
    case appearance
    case recentlyDeleted
    case agentAccess
    case about

    /// The sidebar's groups (spec § Settings): App, then Connections with
    /// its quiet hint; About sits alone at the bottom, apart by space.
    enum Group: CaseIterable {
        case app
        case connections

        var title: String {
            switch self {
            case .app: String(localized: "App")
            case .connections: String(localized: "Connections")
            }
        }

        /// The quiet italic hint under the group, when it has one.
        var hint: String? {
            switch self {
            case .app: nil
            case .connections: String(localized: "Let agents read and add tasks")
            }
        }

        var sections: [SettingsSection] {
            SettingsSection.allCases.filter { $0.group == self }
        }
    }

    static let selectionStorageKey = "AtticSettings.selectedSection"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .panel: String(localized: "Panel")
        case .appearance: String(localized: "Appearance")
        case .recentlyDeleted: String(localized: "Recently Deleted")
        case .agentAccess: String(localized: "Agent Access")
        case .about: String(localized: "About")
        }
    }

    /// Outline SF Symbols, lighter than the text (spec § Settings).
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .panel: "sidebar.right"
        case .appearance: "circle.lefthalf.filled"
        case .recentlyDeleted: "trash"
        case .agentAccess: "sparkles"
        case .about: "info.circle"
        }
    }

    /// Nil for About, which sits at the bottom of the sidebar.
    var group: Group? {
        switch self {
        case .general, .panel, .appearance, .recentlyDeleted: .app
        case .agentAccess: .connections
        case .about: nil
        }
    }

    var accessibilityIdentifier: String {
        "settings-nav-\(rawValue)"
    }

    var pageIdentifier: String {
        "settings-page-\(rawValue)"
    }

    static func restored(from rawValue: String) -> SettingsSection {
        SettingsSection(rawValue: rawValue) ?? .general
    }
}

/// Where Settings is and where it has been: the sidebar picks a page, and
/// the header's back button (⌘[) returns to the one before, the way the
/// back button in System Settings does. The history lives for the window's
/// session; the current page is remembered across launches.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published private(set) var selection: SettingsSection
    @Published private(set) var history: [SettingsSection] = []

    /// A generous bound: nobody walks back further than this.
    static let historyLimit = 50

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = SettingsSection.restored(
            from: defaults.string(forKey: SettingsSection.selectionStorageKey) ?? ""
        )
    }

    var canGoBack: Bool { !history.isEmpty }

    func select(_ section: SettingsSection) {
        guard section != selection else { return }
        history.append(selection)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        show(section)
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        show(previous)
    }

    /// The page above or below the current one in sidebar order (↑ ↓ in
    /// the sidebar), or nil at either end.
    func neighbour(offset: Int) -> SettingsSection? {
        let all = SettingsSection.allCases
        guard let index = all.firstIndex(of: selection) else { return nil }
        let target = index + offset
        return all.indices.contains(target) ? all[target] : nil
    }

    private func show(_ section: SettingsSection) {
        selection = section
        defaults.set(section.rawValue, forKey: SettingsSection.selectionStorageKey)
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
