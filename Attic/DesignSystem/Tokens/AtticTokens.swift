import AppKit
import SwiftUI

// The design system's measurements in one place. Every value cites the spec
// (§ "Appearance and design system") or says why it exists. Components use
// these names, never literals, and the appearance check compares rendered
// frames against them.

/// The 4 pt spacing scale. `inset14` and `gap10` are the two fine steps the
/// spec measures for text insets (grouped rows, row text) and control gaps.
enum AtticSpacing {
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32

    /// Grouped-row text inset in Settings (spec: "text inset 14").
    static let inset14: CGFloat = 14
    /// Circle to title in a task row: 16 + 16 + 10 = the 42 pt text column.
    static let gap10: CGFloat = 10

    /// Inside a group (spec: 8–12 pt). Between groups: 20–24 pt.
    static let insideGroup: CGFloat = 8
    static let betweenGroups: CGFloat = 24
    /// Separate controls in a bar (spec: "separate controls sit 12 pt apart").
    static let betweenControls: CGFloat = 12

    /// Panel margin (spec: 320 × 520, margin 12).
    static let panelMargin: CGFloat = 12
    /// Settings: below the page header (spec: 52) and between sections (34).
    static let settingsBelowHeader: CGFloat = 52
    static let settingsBetweenSections: CGFloat = 34
    /// Settings content card inset from the sidebar and window edges.
    static let settingsCardInset: CGFloat = 8
    /// Group card inset inside the content card.
    static let settingsGroupInset: CGFloat = 16
    /// Section heading to its card.
    static let settingsHeadingToCard: CGFloat = 10

    static let scale: [CGFloat] = [4, 8, 12, 16, 20, 24, 32]
}

/// Corner radii. Controls follow `control(height:)`; surfaces keep a fixed
/// radius by kind whatever their size (spec § Corner rules).
enum AtticRadius {
    /// Controls: Apple's continuous corner at about 42 % of the height
    /// (owner's decision, 2026-09-25, spec rev 175: the rounder corner,
    /// chosen over Craft's 32 % on the full panel), rounded to the half
    /// point: 13.5 on 32, 14.5 on 34, 15 on 36, 12 on 28, 7.5 on 18.
    static let controlFraction: CGFloat = 0.42

    static func control(height: CGFloat) -> CGFloat {
        (height * controlFraction * 2).rounded() / 2
    }

    static let menu: CGFloat = 20
    static let popover: CGFloat = 20
    static let groupCard: CGFloat = 17
    static let contentCard: CGFloat = 10
    static let tile: CGFloat = 10
    static let image: CGFloat = 8
    /// Hover, selection and pressed highlights on rows (always 10).
    static let highlight: CGFloat = 10
    /// A chip nested in a capsule: outer radius minus the inset
    /// (13.5 − 4 = 9.5 on the 32 pt capsule).
    static let nestedChip: CGFloat = control(height: AtticControlSize.capsuleHeight) - AtticControlSize.capsuleInset
    /// Rounded-square subtask checkbox: a fixed glyph radius (a glyph, not
    /// a control, so it keeps its square look beside the round circles).
    static let subtaskCheckbox: CGFloat = 4.5

    /// Nested radius, used only when the gap is 6 pt or less (spec rule 3).
    static func nested(outer: CGFloat, gap: CGFloat) -> CGFloat? {
        gap <= 6 ? max(outer - gap, 0) : nil
    }

    /// A ring drawn outside a shape: the shape's radius plus the ring's offset.
    static func ring(around radius: CGFloat, offset: CGFloat) -> CGFloat { radius + offset }
}

/// Control sizes (spec § Raised controls). Controls are slightly wider than
/// tall (about 1.15 : 1).
enum AtticControlSize {
    static let panelButton = CGSize(width: 36, height: 32)
    static let settingsBackButton = CGSize(width: 38, height: 34)
    static let capsuleHeight: CGFloat = 32
    static let capsuleInset: CGFloat = 4
    static let chipHeight: CGFloat = 24
    /// An icon-only chip, 24 tall and 1.15 × as wide.
    static let chipIconWidth: CGFloat = 28
    static let addBarHeight: CGFloat = 36
    /// The send button: 28 × 28, radius 11, **inside** the add bar.
    ///
    /// The spec's Raised controls table says "send 36 × 36"; that size came
    /// from mockups where the button sat beside the bar. The owner's polish
    /// rule outranks it: "the send button lives inside the add bar and
    /// appears only when there is text". Inside the 36 pt bar it is nested
    /// `sendInset` (4 pt) from the top, bottom and trailing edges, so it is
    /// 36 − 2 × 4 = 28 pt square, with the nested radius 15 − 4 = 11
    /// (corner rule 3: nesting for gaps of 6 pt or less). Kept at 28 × 28
    /// by the owner on 2026-09-24; a test holds the arithmetic.
    static let sendButton = CGSize(width: addBarHeight - 2 * sendInset, height: addBarHeight - 2 * sendInset)
    static let sendInset: CGFloat = 4
    static let smallHeight: CGFloat = 28
    static let smallMinWidth: CGFloat = 32
    static let toastHeight: CGFloat = 36
    static let tagHeight: CGFloat = 18
    /// Minimum hit target for any control (glyphs can be smaller).
    static let minimumHitTarget: CGFloat = 28
    static let statusCircle: CGFloat = 16
    static let subtaskCheckbox: CGFloat = 14
    static let glyph: CGFloat = 14
}

/// Row and panel layout (spec § Proportions and spacing).
enum AtticLayout {
    static let panelSize = CGSize(width: 320, height: 520)
    static let rowPitch: CGFloat = 32
    static let rowHighlightHeight: CGFloat = 30
    static let detailRowPitch: CGFloat = 44
    static let detailRowHighlightHeight: CGFloat = 42
    static let rowHighlightInset: CGFloat = 8
    static let circleX: CGFloat = 16
    static let textX: CGFloat = 42
    static let subtaskPitch: CGFloat = 28
    /// Subtask text column: checkbox at the row's text column, text after it.
    static let subtaskTextX: CGFloat = 42 + 14 + 8

    static let statusTabsGap: CGFloat = 14
    static let statusTabsTop: CGFloat = 12
    static let statusTabsToList: CGFloat = 8

    static let settingsSidebarWidth: CGFloat = 232
    static let sidebarRowPitch: CGFloat = 32
    static let sidebarHighlightHeight: CGFloat = 30
    static let sidebarIconX: CGFloat = 18
    static let sidebarTextX: CGFloat = 42
    static let groupedRowTall: CGFloat = 57
    static let groupedRowSingle: CGFloat = 40
    static let groupedRowTextInset: CGFloat = 14
    static let chevronTrailingCentre: CGFloat = 24
}

/// Content that scrolls under a floating control or an edge blurs
/// progressively under a veil of the surface (spec § Edge blur).
enum AtticEdgeBlur {
    static let panelTop: CGFloat = 56
    static let panelBottom: CGFloat = 60
    static let settingsBottom: CGFloat = 58
    static let maximumBlur: CGFloat = 6
    static let maximumVeil: Double = 0.65
    /// The veil's ramp from the open edge of the zone (0) to the bar (1):
    /// eased, so the fade has no visible start line.
    static let veilStops: [(location: Double, opacity: Double)] = [
        (0.00, 0.00), (0.30, 0.10), (0.55, 0.30), (0.80, 0.52), (1.00, 0.65)
    ]

    /// The veil's opacity at `depth` into the zone (0 open edge, 1 the bar).
    static func veil(at depth: Double) -> Double {
        let y = min(max(depth, 0), 1)
        for (lower, upper) in zip(veilStops, veilStops.dropFirst()) where y <= upper.location {
            let span = upper.location - lower.location
            return lower.opacity + (upper.opacity - lower.opacity) * (span > 0 ? (y - lower.location) / span : 1)
        }
        return veilStops.last?.opacity ?? 0
    }
}

// MARK: - Type

/// Every text style in the design system. Hierarchy comes from weight and
/// colour more than size (spec § Proportions: two densities, one rhythm).
enum AtticTextStyle: String, CaseIterable, Sendable {
    // Panel
    case noteTitle, panelHeading, body, noteBody, rowTitle, rowMeta, helper, hint
    case statusTab, statusTabSelected, statusCount
    case controlLabel, chipLabel, menuRow, shortcut, toast, tag, count, dropLabel
    // Settings
    case pageTitle, sectionHeading, sidebarHeading, sidebarRow, groupLabel, groupValue
    case settingsHelper, settingsHint, tileLabel, tileLabelSelected, rowSingle

    struct Spec: Equatable {
        let size: CGFloat
        let weight: Font.Weight
        let italic: Bool
        let monospacedDigits: Bool
    }

    var spec: Spec {
        switch self {
        case .noteTitle: Spec(size: 17, weight: .bold, italic: false, monospacedDigits: false)
        case .panelHeading: Spec(size: 13, weight: .semibold, italic: false, monospacedDigits: false)
        case .body, .rowTitle, .menuRow, .toast, .sidebarRow: Spec(size: 13, weight: .regular, italic: false, monospacedDigits: false)
        case .noteBody: Spec(size: 14, weight: .regular, italic: false, monospacedDigits: false)
        case .rowMeta, .helper: Spec(size: 11.5, weight: .regular, italic: false, monospacedDigits: false)
        case .count: Spec(size: 11.5, weight: .regular, italic: false, monospacedDigits: true)
        case .hint: Spec(size: 12.5, weight: .regular, italic: true, monospacedDigits: false)
        case .statusTab: Spec(size: 13, weight: .regular, italic: false, monospacedDigits: false)
        case .statusTabSelected: Spec(size: 13, weight: .medium, italic: false, monospacedDigits: false)
        case .statusCount: Spec(size: 13, weight: .regular, italic: false, monospacedDigits: true)
        case .controlLabel: Spec(size: 12.5, weight: .medium, italic: false, monospacedDigits: false)
        case .chipLabel: Spec(size: 12, weight: .medium, italic: false, monospacedDigits: false)
        case .shortcut: Spec(size: 12, weight: .regular, italic: false, monospacedDigits: false)
        case .tag: Spec(size: 11.5, weight: .medium, italic: false, monospacedDigits: false)
        case .dropLabel: Spec(size: 11.5, weight: .medium, italic: false, monospacedDigits: false)
        case .pageTitle: Spec(size: 16, weight: .bold, italic: false, monospacedDigits: false)
        case .sectionHeading: Spec(size: 14, weight: .bold, italic: false, monospacedDigits: false)
        case .sidebarHeading: Spec(size: 13.5, weight: .bold, italic: false, monospacedDigits: false)
        case .groupLabel: Spec(size: 12, weight: .medium, italic: false, monospacedDigits: false)
        case .groupValue: Spec(size: 13.5, weight: .regular, italic: false, monospacedDigits: false)
        case .rowSingle: Spec(size: 13.5, weight: .regular, italic: false, monospacedDigits: false)
        case .settingsHelper: Spec(size: 12.5, weight: .regular, italic: false, monospacedDigits: false)
        case .settingsHint: Spec(size: 12.5, weight: .regular, italic: true, monospacedDigits: false)
        case .tileLabel: Spec(size: 13, weight: .regular, italic: false, monospacedDigits: false)
        case .tileLabelSelected: Spec(size: 13, weight: .medium, italic: false, monospacedDigits: false)
        }
    }

    var font: Font {
        var font = Font.system(size: spec.size, weight: spec.weight)
        if spec.italic { font = font.italic() }
        if spec.monospacedDigits { font = font.monospacedDigit() }
        return font
    }

    /// The AppKit font this style draws with (for measuring text).
    var nsFont: NSFont {
        let weight: NSFont.Weight = switch spec.weight {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        default: .regular
        }
        var font = NSFont.systemFont(ofSize: spec.size, weight: weight)
        if spec.italic {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: spec.size) ?? font
        }
        return font
    }

    /// The width a single line of `string` takes in this style, rounded up
    /// to the whole point (layout that reserves room for text uses it).
    func measuredWidth(_ string: String) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: nsFont]).width.rounded(.up)
    }

    /// Text on the rows of this style is a label, which never wraps. Only
    /// Settings helper text may wrap (to at most three lines).
    var mayWrap: Bool { self == .settingsHelper }
}

// MARK: - Motion

/// The small set of interruptible springs every animation comes from
/// (spec § Motion). A SwiftUI spring retargets from its current value and
/// velocity when it is interrupted, so each one reverses from where it is.
/// Only position and opacity animate; `reduceMotion` swaps in the fallback.
enum AtticMotionPreset: String, CaseIterable, Sendable {
    /// Switch page: 180 ms crossfade. Reduce Motion: instant.
    case pageSwitch
    /// Now, Backlog and Done; note and All notes: 250 ms slide. RM: crossfade.
    case slide
    /// Task done: the wedge sweeps to a full disc, then the check draws
    /// (200 ms each, springs, so they reverse smoothly). RM: fade.
    case complete
    /// The done row slides to the done group after about a second (250 ms).
    case doneSlide
    /// Card or quick-look expand: 220 ms. RM: instant.
    case expand
    /// Menus, selection bar, pop-overs: 120 ms fade and 4 pt rise. RM: fade.
    case popover
    /// Undo toast: slides up in 200 ms. RM: fade.
    case toast
    /// A dropped item settles into place.
    case settle
    /// A failed drop animates back to where it came from.
    case failReturn
    /// Hover and press feedback.
    case hover

    /// Duration of the spring's main motion, in seconds (spec values).
    var duration: Double {
        switch self {
        case .pageSwitch: 0.18
        case .slide: 0.25
        case .complete: 0.20
        case .doneSlide: 0.25
        case .expand: 0.22
        case .popover: 0.12
        case .toast: 0.20
        case .settle: 0.22
        case .failReturn: 0.30
        case .hover: 0.10
        }
    }

    /// No bounce on everyday actions (spec: calm).
    var bounce: Double { 0 }

    enum ReducedMotion: Equatable { case instant, fade }

    var reducedMotion: ReducedMotion {
        switch self {
        case .pageSwitch, .expand: .instant
        default: .fade
        }
    }

    /// Rise distance for fade-and-rise presets.
    var rise: CGFloat { self == .popover ? 4 : self == .toast ? 12 : 0 }

    /// The animation to use, or nil for an instant change.
    func animation(reduceMotion: Bool) -> Animation? {
        if reduceMotion {
            switch reducedMotion {
            case .instant: return nil
            case .fade: return .easeOut(duration: min(duration, 0.18))
            }
        }
        return .spring(duration: duration, bounce: bounce)
    }

    /// The insertion/removal transition: opacity plus, unless Reduce Motion
    /// is on, a short move. Never scale or blur.
    func transition(reduceMotion: Bool, edge: Edge = .bottom) -> AnyTransition {
        if reduceMotion || rise == 0 { return .opacity }
        let dy: CGFloat = edge == .bottom ? rise : -rise
        return .opacity.combined(with: .offset(y: dy))
    }

    /// How long the finished state holds before `doneSlide` (spec: about 1 s).
    static let doneHold: Double = 1.0
    /// How long the Undo toast stays (spec: 6 s).
    static let toastHold: Double = 6.0
}

// MARK: - Touch

/// The haptic tick: a light tap when a task is completed and when a dragged
/// item snaps into place. Nothing else plays haptics, and nothing plays sound.
enum AtticHaptics {
    @MainActor
    static func tick(enabled: Bool = true) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - Task vocabulary

/// The four states the status circle shows (spec § The status circle). The
/// design system keeps its own small types so it never depends on how the
/// store models tasks; Phase 1 maps `TaskStatus` onto these.
enum AtticTaskState: String, CaseIterable, Sendable {
    case todo, inProgress, done, backlog

    var spokenName: String {
        switch self {
        case .todo: String(localized: "to do")
        case .inProgress: String(localized: "in progress")
        case .done: String(localized: "done")
        case .backlog: String(localized: "backlog")
        }
    }
}

/// Priority is shown only by the status ring: its weight and a grey that
/// deepens with it, with High alone in red (and heavier still under
/// Differentiate Without Colour, so it never relies on the red).
enum AtticPriority: String, CaseIterable, Sendable {
    case none, low, medium, high

    var spokenName: String? {
        switch self {
        case .none: nil
        case .low: String(localized: "low priority")
        case .medium: String(localized: "medium priority")
        case .high: String(localized: "high priority")
        }
    }
}
