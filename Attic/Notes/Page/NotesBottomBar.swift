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

/// The tag bar on every page that has tags (Notes, and Tasks since
/// 2026-10-30).
typealias PanelTagBar = NotesTagBar

/// All and every tag in use, coloured; the chosen one on a quiet fill.
/// Choosing one filters the list; more than the bar holds scrolls sideways,
/// without a scroller.
///
/// The bar is only as wide as All and its tags (the user's addition to T6,
/// Accepted 2026-11-01 "Adaptive picks"), from its place at the panel's
/// left; with more tags than fit it stops at the room it is given. It hides
/// while no tags exist at all, so "+" stands alone until the first one,
/// which grows the bar out from the left. Width changes take the expand
/// motion; Reduce Motion is instant.
struct NotesTagBar: View {
    let tags: [String]
    let selection: String?
    /// The accessibility identifiers' stem ("notes-tag-bar", "tasks-tag-bar").
    var idPrefix = "notes-tag-bar"
    let onSelect: (String?) -> Void

    @Environment(\.atticDesign) private var design
    /// Which edges have tags cut off (owner, 2026-10-31): each fades only then.
    @State private var cutOff = NotesTagBarCutOff()
    /// The pill under the pointer.
    @State private var pointed: NotesTagBarPillID?

    private var allID: String { "\(idPrefix)-all" }

    var body: some View {
        let m = NotesBarMetrics.self
        let motion = design.reduceMotion ? AtticMotionScale.reducedChange : AtticPanelChromeMetrics.curve(0.26)
        let collapsed = tags.isEmpty
        PanelTagBarWidth(collapsed: collapsed) {
            // Sizes the bar: All and the tags at their own widths.
            NotesTagBarSizer(tags: tags, selection: selection)
                .hidden()
                .accessibilityHidden(true)
            // Built only while tags exist (no empty element for VoiceOver);
            // the first tag grows it out from the left.
            if !collapsed {
                scroller(motion: motion)
                    .transition(.modifier(active: NotesTagBarGrow(progress: 0), identity: NotesTagBarGrow(progress: 1)))
            }
        }
        .frame(height: m.control)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Self.widthAnimation(reduceMotion: design.reduceMotion), value: tags)
        .animation(Self.widthAnimation(reduceMotion: design.reduceMotion), value: selection)
    }

    /// The width's motion as tags come and go (the app's expand preset;
    /// Reduce Motion: instant).
    static func widthAnimation(reduceMotion: Bool) -> Animation? {
        AtticMotionPreset.expand.animation(reduceMotion: reduceMotion)
    }

    private func point(at tag: String?, inside: Bool) {
        let pill = NotesTagBarPillID(tag: tag)
        if inside { pointed = pill } else if pointed == pill { pointed = nil }
    }

    private func chips(chosen: CGRect?, pointed frame: CGRect?) -> some View {
        let radius = NotesBarMetrics.pillRadius
        return ZStack(alignment: .topLeading) {
            if let chosen {
                AtticSelectionMarker(cornerRadius: radius)
                    .frame(width: chosen.width, height: chosen.height)
                    .offset(x: chosen.minX, y: chosen.minY)
                    .animation(AtticSelectionMarker.travel(reduceMotion: design.reduceMotion), value: chosen)
            }
            AtticHoverChip(frame: frame, shown: pointed != NotesTagBarPillID(tag: selection), cornerRadius: radius)
        }
    }

    private func scroller(motion: Animation?) -> some View {
        let m = NotesBarMetrics.self
        let shape = Squircle(cornerRadius: m.radius, exponent: AtticControlShape.designExponent)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: m.pillGap) {
                    NotesTagBarPill(title: String(localized: "All"), tag: nil, selected: selection == nil,
                                    onHover: { point(at: nil, inside: $0) }) { onSelect(nil) }
                        .anchorPreference(key: NotesTagBarPillBounds.self, value: .bounds) { [NotesTagBarPillID(tag: nil): $0] }
                        .id(allID)
                        .accessibilityIdentifier(allID)
                    ForEach(tags, id: \.self) { tag in
                        NotesTagBarPill(title: TasksPanelDesign.tagChipTitle(tag), tag: tag, selected: selection == tag,
                                        onHover: { point(at: tag, inside: $0) }) {
                            onSelect(tag)
                        }
                        .anchorPreference(key: NotesTagBarPillBounds.self, value: .bounds) { [NotesTagBarPillID(tag: tag): $0] }
                        .id(tag)
                        .accessibilityLabel(tag)
                        .accessibilityIdentifier("\(idPrefix)-\(tag)")
                    }
                }
                // One marker and one hover chip under the pills, travelling
                // between them, in the scrolled content so they scroll with
                // the pills (Accepted 2026-11-05, "Animated selection").
                .backgroundPreferenceValue(NotesTagBarPillBounds.self) { pills in
                    GeometryReader { proxy in
                        chips(chosen: pills[NotesTagBarPillID(tag: selection)].map { proxy[$0] },
                              pointed: pointed.flatMap { pills[$0] }.map { proxy[$0] })
                    }
                }
                .padding(.horizontal, m.tagBarPadding)
                .frame(height: m.control)
            }
            .onScrollGeometryChange(for: NotesTagBarCutOff.self) { geometry in
                NotesTagBarCutOff(offset: geometry.contentOffset.x, visible: geometry.containerSize.width,
                                  content: geometry.contentSize.width)
            } action: { _, edges in
                cutOff = edges
            }
            // The chosen tag comes into view.
            .onChange(of: selection) { _, chosen in
                withAnimation(motion) { proxy.scrollTo(chosen ?? allID, anchor: .center) }
            }
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(cutOff.leading ? 0 : 1), .black],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: m.endFade)
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(cutOff.trailing ? 0 : 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: m.endFade)
            }
        }
        .clipShape(shape)
        .frame(height: m.control)
        // The glass behind the pills, never over them.
        .background(Color.clear.atticRaisedMaterial(cornerRadius: m.radius, interactive: false, edgeLight: true))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tags"))
        .accessibilityIdentifier(idPrefix)
    }
}

/// The tag bar's width: its sizer's (All and the tags at their own
/// widths), never more than the room proposed (it stops before "+"), and
/// none while collapsed. The second subview, the bar itself, takes it.
struct PanelTagBarWidth: Layout {
    var collapsed: Bool

    static func width(ideal: CGFloat, room: CGFloat?, collapsed: Bool) -> CGFloat {
        collapsed ? 0 : min(ideal, room ?? ideal)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let sizer = subviews.first else { return .zero }
        let ideal = sizer.sizeThatFits(.unspecified)
        return CGSize(width: Self.width(ideal: ideal.width, room: proposal.width, collapsed: collapsed),
                      height: proposal.height ?? ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: .unspecified)
        guard subviews.count > 1 else { return }
        subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The first tag's bar growing out from the left (and the last one's
/// folding back into it).
private struct NotesTagBarGrow: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: max(progress, 0.001), y: 1, anchor: .leading)
            .opacity(progress)
    }
}

/// The pills' widths, without buttons: All and each tag in the pill's font
/// and padding (semibold when chosen), as the bar lays them out.
private struct NotesTagBarSizer: View {
    let tags: [String]
    let selection: String?

    var body: some View {
        let m = NotesBarMetrics.self
        HStack(spacing: m.pillGap) {
            pill(String(localized: "All"), selected: selection == nil)
            ForEach(tags, id: \.self) { tag in pill(TasksPanelDesign.tagChipTitle(tag), selected: selection == tag) }
        }
        .padding(.horizontal, m.tagBarPadding)
        .frame(height: m.control)
    }

    private func pill(_ title: String, selected: Bool) -> some View {
        Text(verbatim: title)
            .font(.system(size: NotesBarMetrics.pillFontSize, weight: selected ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, NotesBarMetrics.pillPaddingX)
    }
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
private struct NotesTagBarPillBounds: PreferenceKey {
    static let defaultValue: [NotesTagBarPillID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [NotesTagBarPillID: Anchor<CGRect>], nextValue: () -> [NotesTagBarPillID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
