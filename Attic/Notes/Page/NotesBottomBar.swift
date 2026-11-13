import SwiftUI

/// The Notes page's bottom bar (the owner's Notes Page v2, accepted
/// 2026-10-27/28): the Tasks footer's squircle controls. All notes shows
/// the tag bar (All and the coloured #tags, scrolling sideways) and the
/// compose button; an open note shows Back on the left and Aa on the right.
/// The design is drawn at 2×: each value is half its px.
enum NotesBarMetrics {
    /// One size (Accepted 2026-10-30): every bottom-bar control is 27 pt
    /// (it was the 30.5 pt add field).
    static let control: CGFloat = AtticControlSize.addBarHeight
    /// Curve 1.4: a capsule, half the height.
    static let radius: CGFloat = AtticShape.controlRadius(height: control)
    /// 10 px between the controls.
    static let gap: CGFloat = AtticPanelChromeMetrics.footerGap
    /// The tag bar's inner padding (6 px) and its tags (One size: 21 pt
    /// tall, capsules; 15 px padding, 2 px apart, 21 px text).
    static let tagBarPadding: CGFloat = AtticPageButtonMetrics.inset
    static let pillHeight: CGFloat = AtticPageButtonMetrics.segment
    static let pillPaddingX: CGFloat = 7.5
    static let pillRadius: CGFloat = AtticShape.controlRadius(height: pillHeight)
    static let pillGap: CGFloat = 1
    static let pillFontSize: CGFloat = 10.5
    /// The tag bar fades out over its last 28 px.
    static let endFade: CGFloat = 14
    /// The chosen pill's fill and the hover's, over the bar's glass: the
    /// one selection marker.
    static let selectedFill: Double = AtticSelectionMarker.fillAlpha
    static let hoverFill: Double = AtticSelectionMarker.hoverAlpha

    static var size: CGSize { CGSize(width: control, height: control) }
    /// The bar ends with "+", as on Tasks (Accepted 2026-10-30, "Top row
    /// and bottom bar"), not the compose glyph.
    static let newNoteSymbol = "plus"
    /// An open note's way back to All notes (owner, 13 Nov): the gallery's
    /// icon, which is Notes' own symbol in the island's page switch, the
    /// ••• menu and the menu bar's Open ▸ (the gallery shows none itself).
    static var allNotesSymbol: String { PanelPage.notes.systemName }
}

/// The tag bar's cut-off edges: the leading one once it has scrolled from
/// the start, the trailing one while more tags lie beyond (each fades over
/// `NotesBarMetrics.endFade`, the HTML's 28 px).
struct NotesTagBarCutOff: Equatable {
    var leading = false
    var trailing = false

    init(leading: Bool = false, trailing: Bool = false) {
        self.leading = leading
        self.trailing = trailing
    }

    init(offset: CGFloat, visible: CGFloat, content: CGFloat) {
        leading = offset > 0.5
        trailing = offset + visible < content - 0.5
    }
}

/// One pill: its tag's colour (All in the primary ink), 600 when chosen
/// and 500 otherwise.
struct NotesTagBarPill: View {
    let title: String
    let tag: String?
    let selected: Bool
    /// The bar draws the marker and the hover chip under its pills.
    var onHover: (Bool) -> Void = { _ in }
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticTagColouring) private var colouring

    var body: some View {
        let m = NotesBarMetrics.self
        let tokens = design.tokens
        let shape = Squircle(cornerRadius: m.pillRadius, exponent: AtticControlShape.designExponent)
        let ink = tag.map {
            AtticSurfaceInk.colouredTagText(colouring.hue(for: $0), dark: design.mode == .dark, tokens: tokens).color
        } ?? tokens.color(.heading)
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: m.pillFontSize, weight: selected ? .semibold : .medium))
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, m.pillPaddingX)
                .frame(height: m.pillHeight)
                .contentShape(shape)
        }
        .buttonStyle(AtticPressButtonStyle())
        .focusEffectDisabled()
        .onHover(perform: onHover)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A pill in the tag bar: All (no tag) or a tag.
struct NotesTagBarPillID: Hashable {
    let tag: String?
}

/// Where the tag bar's pills are, for the chips under them.
struct NotesTagBarPillBounds: PreferenceKey {
    static let defaultValue: [NotesTagBarPillID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [NotesTagBarPillID: Anchor<CGRect>], nextValue: () -> [NotesTagBarPillID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
