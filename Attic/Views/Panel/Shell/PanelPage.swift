import SwiftUI

/// The three pages the header switches between. Backlog is part of the
/// Tasks page, so both task sections belong to `.tasks`.
enum PanelPage: String, CaseIterable, Hashable, Identifiable {
    case tasks
    case notes
    case canvas

    var id: String { rawValue }

    init(_ section: PanelSection) {
        switch section {
        case .tasks, .backlog: self = .tasks
        case .notes: self = .notes
        case .canvas: self = .canvas
        }
    }

    /// The section a page opens on. Tasks always opens on Now.
    var section: PanelSection {
        switch self {
        case .tasks: .tasks
        case .notes: .notes
        case .canvas: .canvas
        }
    }

    var title: String {
        switch self {
        case .tasks: String(localized: "Tasks")
        case .notes: String(localized: "Notes")
        case .canvas: String(localized: "Canvas")
        }
    }

    var systemName: String {
        switch self {
        case .tasks: "checkmark.circle"
        case .notes: "note.text"
        case .canvas: "scribble.variable"
        }
    }

    /// ⌘1, ⌘2, ⌘3 (spec § Accessibility and keyboard).
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .tasks: "1"
        case .notes: "2"
        case .canvas: "3"
        }
    }

    var accessibilityIdentifier: String { "panel-section-\(rawValue)" }

    var switchItem: AtticPageSwitch<PanelPage>.Item {
        AtticPageSwitch.Item(
            page: self,
            systemName: systemName,
            title: title,
            shortcut: "⌘\(keyEquivalent.character)",
            keyEquivalent: keyEquivalent,
            accessibilityIdentifier: accessibilityIdentifier
        )
    }

    static let switchItems = allCases.map(\.switchItem)
}

/// The header's geometry, shared by the SwiftUI header and AppKit's hit
/// testing (which must know where the controls are before SwiftUI does).
enum PanelHeaderLayout {
    /// The header's controls are one row, 32 tall.
    static let height = AtticControlSize.capsuleHeight
    static let pinSize = AtticControlSize.panelButton

    /// The page switch's width: fixed whichever page is selected.
    static let pageSwitchWidth: CGFloat = {
        let geometry = AtticPageSwitch<PanelPage>.Geometry(titles: PanelPage.allCases.map(\.title))
        return geometry.innerWidth + AtticControlSize.capsuleInset * 2
    }()

    /// The bottom of the header, measured from the panel's top edge.
    static func bottom(chromeInsets: EdgeInsets) -> CGFloat {
        chromeInsets.top + height
    }
}
