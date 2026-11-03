import SwiftUI

/// The pages the header switches between (Tasks, Notes, Calendar, then
/// Canvas). Backlog is part of the
/// Tasks page, so both task sections belong to `.tasks`.
enum PanelPage: String, CaseIterable, Hashable, Identifiable {
    case tasks
    case notes
    case calendar
    case canvas

    var id: String { rawValue }

    init(_ section: PanelSection) {
        switch section {
        case .tasks, .backlog: self = .tasks
        case .notes: self = .notes
        case .calendar: self = .calendar
        case .canvas: self = .canvas
        }
    }

    /// The section a page opens on. Tasks always opens on Now.
    var section: PanelSection {
        switch self {
        case .tasks: .tasks
        case .notes: .notes
        case .calendar: .calendar
        case .canvas: .canvas
        }
    }

    var title: String {
        switch self {
        case .tasks: String(localized: "Tasks")
        case .notes: String(localized: "Notes")
        case .calendar: String(localized: "Calendar")
        // Draw while the new page has Canvas's place (`AtticDraw.enabled`).
        case .canvas: AtticDraw.isEnabled ? String(localized: "Draw") : String(localized: "Canvas")
        }
    }

    var systemName: String {
        switch self {
        case .tasks: "checkmark.circle"
        case .notes: "doc.text"
        case .calendar: "calendar"
        case .canvas: "pencil.and.scribble"
        }
    }

    /// ⌘1 to ⌘4 in the switch's order (spec § Accessibility and keyboard).
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .tasks: "1"
        case .notes: "2"
        case .calendar: "3"
        case .canvas: "4"
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

    /// Computed, so the Canvas item's title follows the Draw switch.
    static var switchItems: [AtticPageButton<PanelPage>.Item] { allCases.map(\.switchItem) }

    /// Which side of `other` this page sits on in the switch's order
    /// (Tasks, Notes, Calendar, Canvas): -1 before it, 1 after it, 0 if it is `other`.
    func side(from other: PanelPage) -> CGFloat {
        let all = Self.allCases
        guard let mine = all.firstIndex(of: self), let theirs = all.firstIndex(of: other) else { return 0 }
        return mine == theirs ? 0 : (mine < theirs ? -1 : 1)
    }
}

/// How the shell moves between pages: "Motion: page switch and hide",
/// option A (Accepted 2026-11-02), replacing A20's full-width slide. Every
/// switch, by every route and between every pair, uses it: the old page
/// fades out in place, then the new page fades in while it moves about
/// 30 pt in from its side in the page order, on the feel's navigation
/// spring (`AtticMotionPreset.pageSwitch`). Two pages never show at once,
/// so neither their scroll bars nor their bottom bars cross. Reduce Motion
/// and Animations: Reduced switch at once.
///
/// A20 carried the pages the panel's full width (352 pt) on the spring
/// while they crossfaded: 70 % of the travel by 100 ms and both pages
/// through each other for about 100 ms (the owner's recording, 2 Nov).
struct PanelPageMotion: Equatable {
    /// The spring, or nil for an instant switch.
    let spring: AtticMotionSpring?

    static let instant = PanelPageMotion(spring: nil)

    /// How far the new page moves in.
    static let travel: CGFloat = 30
    /// The old page's fade out.
    static let fadeOut: TimeInterval = 0.09
    /// The new page starts once the old one has gone…
    static let fadeInDelay: TimeInterval = fadeOut
    /// …and fades in over this.
    static let fadeIn: TimeInterval = 0.16

    /// The motion for a switch now, in the current feel.
    static func current(reduceMotion: Bool, tuning: AtticMotionTuning = .current) -> PanelPageMotion {
        reduceMotion ? .instant : PanelPageMotion(spring: AtticMotionPreset.pageSwitch.spring(in: tuning))
    }

    /// Whether the pages move at all (they do whenever the switch animates).
    var travels: Bool { spring != nil }

    /// Where a page rests out of view on `side` (-1 left, 1 right) of the
    /// current one.
    func restingOffset(side: CGFloat) -> CGFloat { travels ? side * Self.travel : 0 }

    /// The switch's transaction, which moves the pages (and the top row's
    /// counter-move with them): the spring, once the old page has gone.
    var animation: Animation? {
        spring.map { Animation.spring(duration: $0.response, bounce: $0.bounce).delay(Self.fadeInDelay) }
    }

    /// A page's own fade: out at once, or in once the old page has gone.
    func opacityAnimation(incoming: Bool) -> Animation? {
        guard travels else { return nil }
        return incoming ? .easeOut(duration: Self.fadeIn).delay(Self.fadeInDelay) : .easeIn(duration: Self.fadeOut)
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

    /// What a scrolled-away header title keeps clear of on the right,
    /// besides the search button: ••• (Settings). The page switch moved to
    /// the bottom bar (Accepted 2026-10-29/30), so it no longer takes room
    /// on the top row of a page without its own switch (an open note).
    static let pageSwitchWidth: CGFloat = AtticControlSize.headerControl

    /// The bottom of the header, measured from the panel's top edge.
    static func bottom(chromeInsets: EdgeInsets) -> CGFloat {
        chromeInsets.top + height
    }
}
