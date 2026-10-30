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
    static let gap: CGFloat = TasksDesignMetrics.footerGap
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
}

/// The tag bar on every page that has tags (Notes, and Tasks since
/// 2026-10-30).
typealias PanelTagBar = NotesTagBar

/// All and every tag in use, coloured; the chosen one on a quiet fill.
/// Choosing one filters the list; more than the bar holds scrolls sideways,
/// without a scroller.
struct NotesTagBar: View {
    let tags: [String]
    let selection: String?
    /// The accessibility identifiers' stem ("notes-tag-bar", "tasks-tag-bar").
    var idPrefix = "notes-tag-bar"
    let onSelect: (String?) -> Void

    @Environment(\.atticDesign) private var design

    private var allID: String { "\(idPrefix)-all" }

    var body: some View {
        let m = NotesBarMetrics.self
        let shape = Squircle(cornerRadius: m.radius, exponent: TasksDesignMetrics.cornerExponent)
        let motion = design.reduceMotion ? nil : TasksDesignMetrics.curve(0.26)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: m.pillGap) {
                    NotesTagBarPill(title: String(localized: "All"), tag: nil, selected: selection == nil) { onSelect(nil) }
                        .id(allID)
                        .accessibilityIdentifier(allID)
                    ForEach(tags, id: \.self) { tag in
                        NotesTagBarPill(title: TasksPanelDesign.tagChipTitle(tag), tag: tag, selected: selection == tag) {
                            onSelect(tag)
                        }
                        .id(tag)
                        .accessibilityLabel(tag)
                        .accessibilityIdentifier("\(idPrefix)-\(tag)")
                    }
                }
                .padding(.horizontal, m.tagBarPadding)
                .frame(height: m.control)
            }
            // The chosen tag comes into view.
            .onChange(of: selection) { _, chosen in
                withAnimation(motion) { proxy.scrollTo(chosen ?? allID, anchor: .center) }
            }
        }
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: m.endFade)
            }
        }
        .clipShape(shape)
        .frame(maxWidth: .infinity)
        .frame(height: m.control)
        // The glass behind the pills, never over them.
        .background(Color.clear.atticRaisedMaterial(cornerRadius: m.radius, interactive: false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tags"))
        .accessibilityIdentifier(idPrefix)
    }
}

/// One pill: its tag's colour (All in the primary ink), 600 when chosen
/// and 500 otherwise.
struct NotesTagBarPill: View {
    let title: String
    let tag: String?
    let selected: Bool
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticTagColouring) private var colouring
    @State private var hovered = false

    var body: some View {
        let m = NotesBarMetrics.self
        let tokens = design.tokens
        let shape = Squircle(cornerRadius: m.pillRadius, exponent: TasksDesignMetrics.cornerExponent)
        let ink = tag.map {
            TasksPanelDesign.vivid(TasksPanelDesign.tagColours(hue: TasksPanelDesign.oklchHue(for: colouring.hue(for: $0)),
                                                               dark: design.mode == .dark).text, tokens: tokens).color
        } ?? tokens.color(.heading)
        let fill = selected ? m.selectedFill : (hovered ? m.hoverFill : 0)
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: m.pillFontSize, weight: selected ? .semibold : .medium))
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, m.pillPaddingX)
                .frame(height: m.pillHeight)
                .background(shape.fill(tokens.ink(.heading).withAlpha(fill).color))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
