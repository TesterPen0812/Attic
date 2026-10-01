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
    /// Appearance, compact (Astra 26, kept by the owner in round 6).
    static let settingsBelowHeaderCompact: CGFloat = 24
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
    /// Kept by the owner on 2026-09-27 after comparing fully round controls.
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
    /// (14.5 − 4 = 10.5 on the 34 pt capsule).
    static var nestedChip: CGFloat { control(height: AtticControlSize.capsuleHeight) - AtticControlSize.capsuleInset }
    /// The subtask checkbox is a true squircle: a superellipse of this
    /// exponent across the whole 14 pt box (owner, 2026-09-26).
    static let subtaskCheckboxExponent: CGFloat = 4

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
    /// The panel's raised buttons (pin, All notes, New note): the header's
    /// 36 pt square, radius 15 by the 42 % rule.
    static let panelButton = CGSize(width: headerControl, height: headerControl)
    /// The header's controls (Phase 0's qualities, 2026-09-26): the pin and
    /// the page button are equal 36 pt squares, radius 15 by the 42 % rule.
    static let headerControl: CGFloat = 36
    static let settingsBackButton = CGSize(width: 38, height: 34)
    /// The page switch: 32 tall (visual A), chips 24 inside a 4 pt inset.
    static let capsuleHeight: CGFloat = 32
    static let capsuleInset: CGFloat = 4
    static let chipHeight: CGFloat = capsuleHeight - 2 * capsuleInset
    /// An icon-only chip, 24 tall and 1.15 × as wide (28).
    static let chipIconWidth: CGFloat = (chipHeight * 1.15).rounded()
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
    /// 16 pt (Phase 0's confident circles; the hit area stays 28).
    static let statusCircle: CGFloat = 16
    static let subtaskCheckbox: CGFloat = 14
    static let glyph: CGFloat = 14
    /// Icon-only raised buttons: the page switch's icon size (v9), so the
    /// pin and the switch read as one row.
    static let raisedGlyph: CGFloat = 13
}

/// Row and panel layout (spec § Proportions and spacing).
enum AtticLayout {
    static let panelSize = CGSize(width: 320, height: 520)
    /// Rows are 36 pt, 52 with a details line (visual A, "Calm"): the
    /// highlight is 2 pt shorter than the pitch (1 pt inset top and bottom).
    /// Owner, 2026-09-26 (compact round, then tighter): 34 pt, 48 with a
    /// second line; highlights 30 / 44, 2 pt clear above and below.
    static let rowPitch: CGFloat = 34
    static let rowHighlightHeight: CGFloat = 30
    static let detailRowPitch: CGFloat = 48
    static let detailRowHighlightHeight: CGFloat = 44
    /// The panel's lines (v9): row highlights 12 from the panel's edges,
    /// status circles (and the page title) at 20, task titles at 46, and
    /// the right-hand meta 20 from the right edge.
    /// Owner, 2026-09-26: the page title lines up with the pin's left edge
    /// (12) and the tasks sit 4 pt in from it: circles at 16, task titles
    /// at 42, highlights 8 from the panel's edges.
    /// Visual A ("Calm"): the page sits 8 inside the panel's 20 pt line, so
    /// highlights are 16 from the panel's edges, circles' visible edge at
    /// 24 (centre 31) and titles at 48: the 20 → 24 → 48 lines.
    static let rowHighlightInset: CGFloat = 8
    /// Owner, 2026-09-26: tasks sit under the page tabs' text — circles at
    /// 31 from the panel edge (23 in the page), titles at 55 (47).
    /// Phase 0's room (2026-09-26, supersedes the two above): the page sits
    /// 12 inside the panel's 24 pt margin, so circles' left edge is at 28
    /// (16 in the page, centre 36) and titles at 56 (44); highlights 20
    /// from the panel's edges; dates 28 from the right.
    static let circleX: CGFloat = 16
    static let textX: CGFloat = 44
    /// Settings' sidebar keeps its own highlight inset.
    static let sidebarHighlightInset: CGFloat = 8
    static let subtaskPitch: CGFloat = 28
    /// Subtask text column: checkbox at the row's text column, text after it.
    static let subtaskTextX: CGFloat = textX + 14 + 8

    /// Direction A's page tabs ("Now · Later · Done") in place of the
    /// title: the chip row on the panel's 18 pt line (12 inside the page),
    /// 14 below the header, the list 10 below the chips.
    /// The "Now" label starts on the circles' line (Phase 0's qualities).
    static let pageTabsX: CGFloat = circleX
    /// Visual A: 20 below the header; the list 14 below the tabs (owner, 2026-09-26; the review had 8).
    static let pageTabsTop: CGFloat = 20
    /// The quiet label row's line box (Phase 0's qualities).
    static let pageTabsHeight: CGFloat = 16
    static let pageTabsToList: CGFloat = 14
    /// The least room between the list's last content and the add bar.
    static let contentToAddBar: CGFloat = 16

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

    // MARK: Floating controls (owner, 2026-10-01: B)

    /// Content toward the panel's edge, past the controls, stays this
    /// visible at the very edge (the owner's mockup B: about 35 %).
    static let edgeVisible: Double = 0.35
}

// MARK: - Type

/// Every text style in the design system. Hierarchy comes from weight and
/// colour more than size (spec § Proportions: two densities, one rhythm).
enum AtticTextStyle: String, CaseIterable, Sendable {
    // Panel
    case noteTitle, panelHeading, body, noteBody, rowTitle, rowMeta, helper, hint
    // Direction A: page tabs, today's date, the priority mark, the
    // "Completed today" line.
    case pageTab, pageTabSelected, rowMetaEmphasis, priorityMark, sectionToggle
    // Phase 0's qualities: an in-progress title (medium) and the list's own
    // 13 pt text (empty states, the add bar, subtasks, the Done search).
    case rowTitleActive, listBody
    case controlLabel, chipLabel, menuRow, shortcut, toast, tag, count, dropLabel
    // Settings
    case pageTitle, sectionHeading, sidebarHeading, sidebarRow, groupLabel, groupValue
    case settingsHelper, settingsHint, tileLabel, tileLabelSelected, rowSingle

    struct Spec: Equatable {
        let size: CGFloat
        let weight: Font.Weight
        let italic: Bool
        let monospacedDigits: Bool
        /// SF Pro Rounded (Phase 0's task list, owner 2026-09-26).
        var rounded = false
    }

    /// The task list's text is SF Pro Rounded, like Phase 0's: titles, the
    /// second line, dates, the page labels, "Completed today", empty
    /// states and the add bar. The header and Settings stay SF Pro.
    var isListText: Bool {
        switch self {
        case .rowTitle, .rowTitleActive, .rowMeta, .rowMetaEmphasis, .count, .priorityMark,
             .pageTab, .pageTabSelected, .sectionToggle, .listBody: true
        default: false
        }
    }

    var spec: Spec {
        let base = baseSpec
        return Spec(size: base.size, weight: base.weight, italic: base.italic, monospacedDigits: base.monospacedDigits, rounded: isListText)
    }

    private var baseSpec: Spec {
        switch self {
        case .noteTitle: Spec(size: 17, weight: .bold, italic: false, monospacedDigits: false)
        case .panelHeading: Spec(size: 13, weight: .semibold, italic: false, monospacedDigits: false)
        case .body, .rowTitle, .listBody, .menuRow, .toast, .sidebarRow: Spec(size: 13, weight: .regular, italic: false, monospacedDigits: false)
        case .rowTitleActive: Spec(size: 13, weight: .medium, italic: false, monospacedDigits: false)
        case .noteBody: Spec(size: 14, weight: .regular, italic: false, monospacedDigits: false)
        case .rowMeta, .helper: Spec(size: 11.5, weight: .regular, italic: false, monospacedDigits: false)
        case .count: Spec(size: 11.5, weight: .regular, italic: false, monospacedDigits: true)
        case .rowMetaEmphasis: Spec(size: 11.5, weight: .medium, italic: false, monospacedDigits: false)
        case .priorityMark: Spec(size: 11, weight: .semibold, italic: false, monospacedDigits: false)
        // Quiet labels, 11.5 medium; the selected page semibold, so the
        // selection reads on glass where the two greys are close (owner,
        // 2026-09-27).
        case .pageTab: Spec(size: 11.5, weight: .medium, italic: false, monospacedDigits: false)
        case .sectionToggle: Spec(size: 11.5, weight: .regular, italic: false, monospacedDigits: false)
        case .pageTabSelected: Spec(size: 11.5, weight: .semibold, italic: false, monospacedDigits: false)
        case .hint: Spec(size: 12.5, weight: .regular, italic: true, monospacedDigits: false)
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
        var font = Font.system(size: spec.size, weight: spec.weight, design: spec.rounded ? .rounded : .default)
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
        if spec.rounded, let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: rounded, size: spec.size) ?? font
        }
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
/// Only transforms (position, scale) and opacity animate; `reduceMotion`
/// swaps in the fallback.
///
/// Round 9 (owner item 26) made motion springy; round 11 made it crisp
/// (about a quarter of a second, no bounce on navigation). The Motion Lab
/// (owner, 2026-09-30: "I much more prefer the bounciness, even if it's
/// slight") keeps every value in one `AtticMotionTuning`, chosen by a feel
/// (`AtticMotionFeel`): Calm is round 11, Lively (the default) springs
/// things in from their anchor and tucks them away, Playful is round 9.
/// The feels are data: every preset reads its response and bounce from
/// the current tuning, and nothing else branches on the feel.
/// Settings › General › Animations (`AtticAnimationLevel.reduced`) and
/// macOS Reduce Motion both set `design.reduceMotion`, which swaps every
/// preset for its fallback, whatever the feel.
enum AtticMotionPreset: String, CaseIterable, Sendable {
    /// Switch page: 180 ms crossfade. Reduce Motion: instant.
    case pageSwitch
    /// Now, Backlog and Done; note and All notes: a firm slide. RM: crossfade.
    case slide
    /// Task done: the wedge sweeps to a full disc, then the check draws
    /// (springs, so they reverse smoothly). RM: fade.
    case complete
    /// The done row slides to the done group after about a second.
    case doneSlide
    /// Card or quick-look expand. RM: instant.
    case expand
    /// Menus, selection bar, pop-overs, the strip, the Done search: they
    /// spring in from their anchor (or fade and rise, in the fade style).
    /// RM: fade.
    case popover
    /// Undo toast: springs up. RM: fade.
    case toast
    /// A dropped item settles into place; rows added, moved or completed.
    case settle
    /// A failed drop animates back to where it came from.
    case failReturn
    /// Hover and press feedback.
    case hover

    /// The spring this preset uses under `tuning`. A crossfade and hover
    /// feedback are the same in every feel.
    func spring(in tuning: AtticMotionTuning) -> AtticMotionSpring {
        switch self {
        case .pageSwitch: AtticMotionSpring(response: 0.18, bounce: 0)
        case .hover: AtticMotionSpring(response: 0.10, bounce: 0)
        case .slide: tuning.slide
        case .expand: tuning.expand
        case .doneSlide: tuning.doneSlide
        case .popover: tuning.popover
        case .toast: tuning.toast
        case .complete: tuning.complete
        case .settle: tuning.settle
        case .failReturn: tuning.failReturn
        }
    }

    /// Duration of the spring's main motion (SwiftUI's perceptual
    /// duration), in seconds, in the current feel.
    var duration: Double { spring(in: .current).response }

    /// How much the spring bounces (SwiftUI's `bounce`: 0 is critically
    /// damped, 0.3 is `.bouncy`), in the current feel.
    var bounce: Double { spring(in: .current).bounce }

    enum ReducedMotion: Equatable { case instant, fade }

    var reducedMotion: ReducedMotion {
        switch self {
        case .pageSwitch, .expand: .instant
        default: .fade
        }
    }

    /// Rise distance for fade-and-rise presets (a row added or removed
    /// rises into or out of its place by `settle`'s).
    var rise: CGFloat {
        switch self {
        case .popover: 6
        case .toast: 12
        case .settle: 6
        default: 0
        }
    }

    /// How much of the feel's appear and leave scale this preset takes:
    /// all of it for the things that pop in (pop-overs, the strip, bars,
    /// the toast), a part for rows and the quick look (a row's text should
    /// not visibly zoom). Whole pages never scale: they hold the lists'
    /// AppKit scroll views, which a SwiftUI transform does not carry (the
    /// round 9 lesson), so a page switch stays a crossfade. The slides
    /// never scale either.
    var scaleWeight: Double {
        switch self {
        case .popover, .toast, .complete: 1
        case .expand: 0.5
        case .settle: 0.4
        case .pageSwitch, .slide, .doneSlide, .failReturn, .hover: 0
        }
    }

    /// The animation to use, or nil for an instant change.
    func animation(reduceMotion: Bool) -> Animation? {
        if reduceMotion { return reducedAnimation }
        let spring = spring(in: .current)
        return .spring(duration: spring.response, bounce: spring.bounce)
    }

    /// Reduce Motion's fallback: the same in every feel (Calm's timings),
    /// so the feel never reaches Reduced motion.
    private var reducedAnimation: Animation? {
        switch reducedMotion {
        case .instant: nil
        case .fade: .easeOut(duration: min(spring(in: .calm).response, 0.18))
        }
    }

    /// Something leaving: in the spring leave style a quick critically
    /// damped tuck (`leaveResponse`), else the preset's own animation (as
    /// before the Motion Lab). Reduce Motion: the fallback.
    func leaveAnimation(reduceMotion: Bool) -> Animation? {
        if reduceMotion { return reducedAnimation }
        let tuning = AtticMotionTuning.current
        guard tuning.leave == .spring else { return animation(reduceMotion: false) }
        return .spring(duration: tuning.leaveResponse, bounce: 0)
    }

    /// `animation` while something shows, `leaveAnimation` while it goes.
    func animation(reduceMotion: Bool, showing: Bool) -> Animation? {
        showing ? animation(reduceMotion: reduceMotion) : leaveAnimation(reduceMotion: reduceMotion)
    }

    /// Leaving at once (a search field that ends must let the keyboard go
    /// at once, not linger while a spring settles): a short fade-out, or
    /// the spring leave style's quick tuck, which has no bounce either.
    /// Reduce Motion: the same fade, or instant for the instant presets.
    func exit(reduceMotion: Bool) -> Animation? {
        if reduceMotion {
            return reducedMotion == .instant ? nil : .easeOut(duration: min(spring(in: .calm).response, 0.12))
        }
        let tuning = AtticMotionTuning.current
        if tuning.leave == .spring { return .spring(duration: tuning.leaveResponse, bounce: 0) }
        return .easeOut(duration: min(duration, 0.12))
    }

    /// The insertion/removal transition.
    ///
    /// - Fade style (Calm), and always under Reduce Motion: opacity plus,
    ///   unless Reduce Motion is on, a short move (from below for
    ///   `.bottom`, above for `.top`, the side for `.leading` and
    ///   `.trailing`; none for a nil edge).
    /// - Spring appear style: the same move plus a scale-up from the
    ///   feel's `appearScale`, anchored where the thing comes from
    ///   (`anchor`, else the edge it rises from), so a spring's bounce is
    ///   seen as a small pop rather than a fade.
    /// - Spring leave style: it tucks toward its anchor (`leaveScale`) as
    ///   it fades, with half the move.
    func transition(reduceMotion: Bool, edge: Edge? = .bottom, anchor: UnitPoint? = nil) -> AnyTransition {
        if reduceMotion { return .opacity }
        let fade = move(edge, by: rise)
        let tuning = AtticMotionTuning.current
        guard scaleWeight > 0, tuning.appear == .spring || tuning.leave == .spring else { return fade }
        let anchor = anchor ?? edge.map(Self.anchor(for:)) ?? .center
        let insertion = tuning.appear == .spring
            ? fade.combined(with: .scale(scale: scale(from: tuning.appearScale), anchor: anchor))
            : fade
        let removal = tuning.leave == .spring
            ? move(edge, by: rise / 2).combined(with: .scale(scale: scale(from: tuning.leaveScale), anchor: anchor))
            : fade
        return .asymmetric(insertion: insertion, removal: removal)
    }

    /// The scale something shown and hidden in place (not inserted: the
    /// strip, the add bar's send button) takes while hidden: the appear
    /// scale in the spring style, else 1 (none).
    func hiddenScale(reduceMotion: Bool) -> CGFloat {
        let tuning = AtticMotionTuning.current
        guard !reduceMotion, tuning.appear == .spring else { return 1 }
        return scale(from: tuning.appearScale)
    }

    /// The feel's scale, weighted for this preset.
    private func scale(from feelScale: Double) -> CGFloat {
        CGFloat(1 - (1 - feelScale) * scaleWeight)
    }

    private func move(_ edge: Edge?, by distance: CGFloat) -> AnyTransition {
        guard let edge, distance > 0 else { return .opacity }
        switch edge {
        case .bottom: return .opacity.combined(with: .offset(y: distance))
        case .top: return .opacity.combined(with: .offset(y: -distance))
        case .leading: return .opacity.combined(with: .offset(x: -distance * 2))
        case .trailing: return .opacity.combined(with: .offset(x: distance * 2))
        }
    }

    /// Where something that comes from `edge` grows from.
    static func anchor(for edge: Edge) -> UnitPoint {
        switch edge {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    /// How long the finished state holds before `doneSlide` (spec: about 1 s).
    static let doneHold: Double = 1.0
    /// How long the Undo toast stays (spec: 6 s).
    static let toastHold: Double = 6.0
}

/// One spring: SwiftUI's perceptual duration (`response`, seconds) and
/// `bounce` (0 critically damped, 0.3 `.bouncy`).
struct AtticMotionSpring: Hashable, Codable, Sendable {
    var response: Double
    var bounce: Double
}

/// Appear and Leave: spring in with a small scale-up (spring back with a
/// quick tuck), or today's fade.
enum AtticMotionStyle: String, CaseIterable, Codable, Sendable {
    case spring
    case fade

    /// The Motion Lab's words (a preview-only tool: not localized).
    var title: String {
        switch self {
        case .spring: "Spring"
        case .fade: "Fade"
        }
    }
}

/// Every value the motion is made of (the Motion Lab, owner 2026-09-30).
/// A feel is one of these; the lab edits a copy. Navigation is the slide
/// (and the Tasks pager's own settle), the quick look and the done row's
/// slide; the things that appear are the pop-overs, the strip, the bars,
/// the Done search, the toast, a completion and the rows that settle.
struct AtticMotionTuning: Hashable, Codable, Sendable {
    // Navigation.
    var slide: AtticMotionSpring
    var expand: AtticMotionSpring
    var doneSlide: AtticMotionSpring
    // Things that appear.
    var popover: AtticMotionSpring
    var toast: AtticMotionSpring
    var complete: AtticMotionSpring
    var settle: AtticMotionSpring
    var failReturn: AtticMotionSpring
    /// The scale the things that appear start from (1: none).
    var appearScale: Double
    /// The leave style's tuck: its response and the scale it tucks to.
    var leaveResponse: Double
    var leaveScale: Double
    var appear: AtticMotionStyle
    var leave: AtticMotionStyle
    /// Native pop-overs (the pickers, the date and tag pop-overs) spring
    /// in from their arrow as well as the system's own fade. Experimental:
    /// off in every feel until the owner has seen it.
    var popsNativePopovers = false

    /// The current tuning. Written only on the main thread, by
    /// `AppSettings` (a feel, or the Motion Lab's values); read wherever
    /// an animation is made, off the main actor too, like the presets.
    nonisolated(unsafe) static var current: AtticMotionTuning = AtticMotionFeel.recommended.tuning

    static let navigation: [WritableKeyPath<AtticMotionTuning, AtticMotionSpring>] = [\.slide, \.expand, \.doneSlide]
    static let appearing: [WritableKeyPath<AtticMotionTuning, AtticMotionSpring>] = [\.popover, \.toast, \.complete, \.settle, \.failReturn]

    static let responseRange: ClosedRange<Double> = 0.10...0.50
    static let bounceRange: ClosedRange<Double> = 0...0.45
    static let scaleRange: ClosedRange<Double> = 0.80...1
    static let leaveRange: ClosedRange<Double> = 0.08...0.30

    /// The group's knobs (the lab's sliders): the first spring of the
    /// group stands for it, and moving a knob shifts every spring in the
    /// group by the same amount, so their differences are kept.
    var navigationResponse: Double {
        get { slide.response }
        set { shift(Self.navigation, \.response, by: newValue - slide.response, in: Self.responseRange) }
    }
    var navigationBounce: Double {
        get { slide.bounce }
        set { shift(Self.navigation, \.bounce, by: newValue - slide.bounce, in: Self.bounceRange) }
    }
    var appearResponse: Double {
        get { popover.response }
        set { shift(Self.appearing, \.response, by: newValue - popover.response, in: Self.responseRange) }
    }
    var appearBounce: Double {
        get { popover.bounce }
        set { shift(Self.appearing, \.bounce, by: newValue - popover.bounce, in: Self.bounceRange) }
    }

    private mutating func shift(_ springs: [WritableKeyPath<AtticMotionTuning, AtticMotionSpring>],
                                _ value: WritableKeyPath<AtticMotionSpring, Double>, by delta: Double,
                                in range: ClosedRange<Double>) {
        for spring in springs {
            let moved = self[keyPath: spring][keyPath: value] + delta
            self[keyPath: spring][keyPath: value] = min(max((moved * 1000).rounded() / 1000, range.lowerBound), range.upperBound)
        }
    }

    /// The Motion Lab's "Copy values": readable, then as Swift to bake in.
    func copyText(feel: AtticMotionFeel) -> String {
        func pair(_ spring: AtticMotionSpring) -> String { String(format: "%.2f s / %.2f", spring.response, spring.bounce) }
        func swift(_ spring: AtticMotionSpring) -> String {
            String(format: ".init(response: %.3f, bounce: %.3f)", spring.response, spring.bounce)
        }
        let edited = self == feel.tuning ? "" : " (edited)"
        return """
        Attic motion: \(feel.title)\(edited)
        Navigation: slide \(pair(slide)), expand \(pair(expand)), done slide \(pair(doneSlide))
        Appear: pop-over \(pair(popover)), toast \(pair(toast)), complete \(pair(complete)), settle \(pair(settle)), fail return \(pair(failReturn))
        Appear style \(appear.rawValue), scale \(String(format: "%.2f", appearScale)); leave style \(leave.rawValue), \(String(format: "%.2f s", leaveResponse)), scale \(String(format: "%.2f", leaveScale)); native pop-overs \(popsNativePopovers ? "spring" : "system")

        AtticMotionTuning(
            slide: \(swift(slide)), expand: \(swift(expand)), doneSlide: \(swift(doneSlide)),
            popover: \(swift(popover)), toast: \(swift(toast)), complete: \(swift(complete)),
            settle: \(swift(settle)), failReturn: \(swift(failReturn)),
            appearScale: \(String(format: "%.3f", appearScale)), leaveResponse: \(String(format: "%.3f", leaveResponse)), leaveScale: \(String(format: "%.3f", leaveScale)),
            appear: .\(appear.rawValue), leave: .\(leave.rawValue), popsNativePopovers: \(popsNativePopovers)
        )
        """
    }
}

/// The feels the Motion Lab offers. Each is only data (`tuning`). The user
/// setting (`AtticAnimationLevel`) offers two of them, Lively and Subtle.
enum AtticMotionFeel: String, CaseIterable, Codable, Sendable {
    /// Round 11: crisp, no bounce on navigation, a light one on small
    /// things that appear; things fade in and out.
    case calm
    /// The quiet spring feel (Settings › General › Animations › Subtle):
    /// Calm's timings with a small bounce, springing in and tucking away
    /// from close to full size. No plain fades.
    case subtle
    /// The default (Settings › General › Animations › Lively): navigation lands in about the same time as Calm's
    /// with a hint of bounce; things that appear spring in from about
    /// 0.92 of their size, from where they come from, and tuck away
    /// quickly. No plain fades.
    case lively
    /// Round 9's springs, with a bigger pop and tuck.
    case playful

    /// What every build starts with.
    static let recommended: AtticMotionFeel = .lively

    /// The Motion Lab's words (a preview-only tool: not localized).
    var title: String {
        switch self {
        case .calm: "Calm"
        case .subtle: "Subtle"
        case .lively: "Lively"
        case .playful: "Playful"
        }
    }

    var tuning: AtticMotionTuning {
        switch self {
        case .calm: .calm
        case .subtle: .subtle
        case .lively: .lively
        case .playful: .playful
        }
    }
}

extension AtticMotionTuning {
    /// Round 11's values (the CHANGELOG, "Phase 1 round 11"), with its fades.
    static let calm = AtticMotionTuning(
        slide: .init(response: 0.25, bounce: 0), expand: .init(response: 0.22, bounce: 0),
        doneSlide: .init(response: 0.25, bounce: 0),
        popover: .init(response: 0.22, bounce: 0.15), toast: .init(response: 0.24, bounce: 0.12),
        complete: .init(response: 0.22, bounce: 0.15), settle: .init(response: 0.24, bounce: 0.08),
        failReturn: .init(response: 0.28, bounce: 0.1),
        appearScale: 1, leaveResponse: 0.12, leaveScale: 1, appear: .fade, leave: .fade
    )

    /// Calm's timings with a small bounce (navigation 0.04, things that
    /// appear about 0.10), springing in from 0.96 of their size and tucking
    /// away to 0.98 in 0.12 s. Quieter than Lively, but never a plain fade.
    static let subtle = AtticMotionTuning(
        slide: .init(response: 0.25, bounce: 0.04), expand: .init(response: 0.22, bounce: 0.04),
        doneSlide: .init(response: 0.25, bounce: 0.04),
        popover: .init(response: 0.22, bounce: 0.10), toast: .init(response: 0.24, bounce: 0.10),
        complete: .init(response: 0.22, bounce: 0.10), settle: .init(response: 0.24, bounce: 0.08),
        failReturn: .init(response: 0.28, bounce: 0.08),
        appearScale: 0.96, leaveResponse: 0.12, leaveScale: 0.98, appear: .spring, leave: .spring
    )

    /// Navigation about 0.3 s with bounce 0.12, things that appear about
    /// 0.27 s with bounce 0.22 from 0.92 of their size, leaving in a 0.14 s
    /// tuck to 0.96. Each spring was chosen to reach 95 % of its way within
    /// a frame of Calm's (measured: `MotionLabTests`), so the bounce adds
    /// no delay: a bouncier spring starts faster.
    static let lively = AtticMotionTuning(
        slide: .init(response: 0.30, bounce: 0.12), expand: .init(response: 0.26, bounce: 0.12),
        doneSlide: .init(response: 0.30, bounce: 0.12),
        popover: .init(response: 0.26, bounce: 0.22), toast: .init(response: 0.28, bounce: 0.22),
        complete: .init(response: 0.26, bounce: 0.22), settle: .init(response: 0.27, bounce: 0.16),
        failReturn: .init(response: 0.30, bounce: 0.15),
        appearScale: 0.92, leaveResponse: 0.14, leaveScale: 0.96, appear: .spring, leave: .spring
    )

    /// Round 9's values (the CHANGELOG, "Phase 1 round 9" and round 11's
    /// "was" values), popping from 0.88 and tucking to 0.94.
    static let playful = AtticMotionTuning(
        slide: .init(response: 0.32, bounce: 0.15), expand: .init(response: 0.30, bounce: 0.2),
        doneSlide: .init(response: 0.34, bounce: 0.2),
        popover: .init(response: 0.26, bounce: 0.3), toast: .init(response: 0.32, bounce: 0.25),
        complete: .init(response: 0.26, bounce: 0.3), settle: .init(response: 0.30, bounce: 0.25),
        failReturn: .init(response: 0.34, bounce: 0.15),
        appearScale: 0.88, leaveResponse: 0.20, leaveScale: 0.94, appear: .spring, leave: .spring
    )
}

/// The Motion Lab (preview builds only): whether this process may show it
/// and use a stored feel. Never under the release identity.
enum AtticMotionLab {
    static let officialBundleIdentifier = "com.taha.Attic"
    static let previewPrefix = "com.taha.Attic.preview."
    static let argument = "--attic-motion-lab"

    /// A `com.taha.Attic.preview.*` build, or another non-release Attic
    /// identity launched with `--attic-motion-lab`.
    static func isAvailable(bundleIdentifier: String?, arguments: [String]) -> Bool {
        guard let bundleIdentifier, bundleIdentifier != officialBundleIdentifier else { return false }
        if bundleIdentifier.hasPrefix(previewPrefix), bundleIdentifier.count > previewPrefix.count { return true }
        return bundleIdentifier.hasPrefix(officialBundleIdentifier + ".") && arguments.contains(argument)
    }

    static let isAvailable = isAvailable(bundleIdentifier: Bundle.main.bundleIdentifier,
                                         arguments: ProcessInfo.processInfo.arguments)
}

/// Settings › General › Animations: Lively (the default), Subtle, or
/// Reduced, every preset's Reduce Motion fallback (crossfades or instant
/// changes, no travel), as macOS Reduce Motion gives. macOS Reduce Motion
/// forces Reduced whatever is chosen.
enum AtticAnimationLevel: String, CaseIterable, Sendable {
    case lively
    case subtle
    case reduced

    var title: String {
        switch self {
        case .lively: String(localized: "Lively")
        case .subtle: String(localized: "Subtle")
        case .reduced: String(localized: "Reduced")
        }
    }

    /// The spring values this level uses. Reduced never reads them (every
    /// preset takes its fallback), so it carries Subtle's.
    var feel: AtticMotionFeel {
        switch self {
        case .lively: .lively
        case .subtle, .reduced: .subtle
        }
    }

    /// Whether motion is reduced: this level is Reduced, or macOS Reduce
    /// Motion is on, which forces Reduced whatever is chosen.
    func reducesMotion(systemReduceMotion: Bool) -> Bool {
        systemReduceMotion || self == .reduced
    }

    /// The level stored by an earlier build: "full" (the springs) is now
    /// Lively, and "reduced" is still Reduced. Anything else is the default.
    static func migrated(from stored: String?) -> AtticAnimationLevel {
        guard let stored else { return .lively }
        if stored == "full" { return .lively }
        return AtticAnimationLevel(rawValue: stored) ?? .lively
    }
}

/// The Animations choice for code that runs outside a view (a model's
/// `withAnimation`, the panel's AppKit motion) and so cannot read
/// `design.reduceMotion`. `AppSettings` keeps `level` current.
@MainActor
enum AtticMotionPreference {
    static var level: AtticAnimationLevel = .lively

    /// Reduced in Settings, or Reduce Motion on in macOS.
    static var reducesMotion: Bool {
        level.reducesMotion(systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
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
        case .backlog: String(localized: "later")
        }
    }
}

/// Priority is a mark after the title (Direction A): High "!!" in the
/// orange mark ink, Medium "!" in the secondary grey, Low and None nothing;
/// every open ring is the same grey. VoiceOver reads it with the task.
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
