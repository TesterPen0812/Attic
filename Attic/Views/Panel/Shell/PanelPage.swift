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

    var switchItem: AtticPageButton<PanelPage>.Item {
        AtticPageButton.Item(
            page: self,
            systemName: systemName,
            title: title,
            shortcut: "⌘\(keyEquivalent.character)",
            keyEquivalent: keyEquivalent,
            accessibilityIdentifier: accessibilityIdentifier
        )
    }

    static let switchItems = allCases.map(\.switchItem)

    /// Which side of `other` this page sits on in the switch's order
    /// (Tasks, Notes, Canvas): -1 before it, 1 after it, 0 if it is `other`.
    func side(from other: PanelPage) -> CGFloat {
        let all = Self.allCases
        guard let mine = all.firstIndex(of: self), let theirs = all.firstIndex(of: other) else { return 0 }
        return mine == theirs ? 0 : (mine < theirs ? -1 : 1)
    }
}

/// How the shell moves between pages (A20). Every switch, by every route
/// and between every pair, uses the same motion: the Animations feel's
/// navigation spring (`AtticMotionPreset.pageSwitch`) carrying the pages
/// sideways in their order as they crossfade, as Notes slides between a
/// note and All notes. Reduce Motion and Animations: Reduced switch at once.
///
/// Before A20 the shell crossfaded for 180 ms whatever the feel, and only
/// the first visit to Notes looked sprung: the Notes editor's own springy
/// slide (`.animation(value: controller.active?.id)`) ran because its
/// session started on that first appearance; later visits kept the session,
/// so only the plain crossfade showed.
struct PanelPageMotion: Equatable {
    /// The spring, or nil for an instant switch.
    let spring: AtticMotionSpring?

    static let instant = PanelPageMotion(spring: nil)

    /// The motion for a switch now, in the current feel.
    static func current(reduceMotion: Bool, tuning: AtticMotionTuning = .current) -> PanelPageMotion {
        reduceMotion ? .instant : PanelPageMotion(spring: AtticMotionPreset.pageSwitch.spring(in: tuning))
    }

    /// Whether the pages travel sideways (they do whenever the switch animates).
    var travels: Bool { spring != nil }

    var animation: Animation? {
        spring.map { .spring(duration: $0.response, bounce: $0.bounce) }
    }
}

/// One page switch, as the shell made it: the pages' transitions read it
/// while they run, and tests read what each switch used.
struct PanelPageSwitch: Equatable {
    let from: PanelPage
    let to: PanelPage
    let motion: PanelPageMotion

    /// Where `page` rests out of view, in page widths: the page coming in
    /// starts on its side of the page left, the page going ends on its side
    /// of the new one. 0 when the switch does not travel.
    func restingSide(of page: PanelPage) -> CGFloat {
        guard motion.travels else { return 0 }
        return page == to ? to.side(from: from) : page.side(from: to)
    }
}

/// The header's geometry, shared by the SwiftUI header and AppKit's hit
/// testing (which must know where the controls are before SwiftUI does).
enum PanelHeaderLayout {
    /// The header's controls are one row, 36 tall.
    static let height = AtticControlSize.headerControl
    static let pinSize = AtticControlSize.panelButton

    /// The page button's width when open (the region its controls may
    /// take; shut it is the pin's width).
    static let pageSwitchWidth: CGFloat = AtticPageButton<PanelPage>.width(open: true, count: PanelPage.allCases.count)

    /// The bottom of the header, measured from the panel's top edge.
    static func bottom(chromeInsets: EdgeInsets) -> CGFloat {
        chromeInsets.top + height
    }
}
