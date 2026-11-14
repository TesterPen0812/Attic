import AppKit
import Combine
import SwiftUI

// MARK: - The tag bar, collapsed by default (Accepted 2026-11-13)

/// The tag bar on every page that has tags (Notes, and Tasks since
/// 2026-10-30).
typealias PanelTagBar = NotesTagBar

/// A stop the keyboard can be on in the open tag bar: All, a tag, or a side
/// of the Any · All switch.
enum PanelTagBarStop: Hashable {
    case all
    case tag(String)
    case match(TagPicks.Match)

    /// The bar's stops, left to right: All, the tags, then Any and All
    /// while the switch shows.
    static func stops(tags: [String], picks: TagPicks) -> [PanelTagBarStop] {
        [.all] + tags.map(PanelTagBarStop.tag) + (picks.showsMatch ? [.match(.any), .match(.all)] : [])
    }

    /// Where ⌥⌘T (or Space on "#") puts the keyboard: the first tag.
    static func first(tags: [String]) -> PanelTagBarStop {
        tags.first.map(PanelTagBarStop.tag) ?? .all
    }
}

/// Whether the tag bar is open and where its keyboard is, kept outside the
/// bar so the shell (a page switch, the panel opening), ⌥⌘T and the page's
/// Tab order reach it. The bar starts collapsed each time the panel opens
/// (1A); the picked tags are the page's and stay (Accepted 2026-11-13,
/// "Remembered").
@MainActor
final class PanelTagBarState: ObservableObject {
    @Published private(set) var isOpen = false
    /// The keyboard's stop while it moves in the open bar (⌥⌘T, Space on
    /// "#"); nil while the pointer drives it.
    @Published private(set) var cursor: PanelTagBarStop?
    /// The "#" key has the keyboard (Tab, ⌥⌘T).
    @Published private(set) var keyFocused = false
    /// Bumped to give "#" the keyboard.
    @Published private(set) var keyFocusRequest: UInt64 = 0

    private static let live = NSHashTable<PanelTagBarState>.weakObjects()

    init() { Self.live.add(self) }

    /// A tag bar is open: Esc is its until it closes.
    static var ownsEscape: Bool { live.allObjects.contains(where: \.isOpen) }
    /// A tag bar has the keyboard: the page's arrows, Space and Return wait.
    static var ownsKeys: Bool { live.allObjects.contains(where: \.hasKeyboard) }

    var hasKeyboard: Bool { keyFocused || cursor != nil }

    func open(cursor: PanelTagBarStop? = nil) {
        if !isOpen { isOpen = true }
        if self.cursor != cursor { self.cursor = cursor }
    }

    func close() {
        if isOpen { isOpen = false }
        if cursor != nil { cursor = nil }
    }

    func toggle() { isOpen ? close() : open() }

    func setCursor(_ stop: PanelTagBarStop?) {
        if cursor != stop { cursor = stop }
    }

    /// ← → in the open bar: the next stop, stopping at the ends.
    func moveCursor(by step: Int, in stops: [PanelTagBarStop]) {
        guard !stops.isEmpty else { return }
        guard let cursor, let index = stops.firstIndex(of: cursor) else {
            setCursor(step < 0 ? stops.last : stops.first)
            return
        }
        setCursor(stops[min(max(index + step, 0), stops.count - 1)])
    }

    func requestKeyFocus() { keyFocusRequest &+= 1 }

    func noteKeyFocus(_ focused: Bool, closeWhenLeaving: Bool = true) {
        guard keyFocused != focused else { return }
        keyFocused = focused
        // The keyboard left the bar (Tab on, a click on a row): a bar it
        // opened closes with it.
        if !focused, closeWhenLeaving, cursor != nil { close() }
    }
}

/// "#" as a stop in a page's Tab order (`TasksTabStop.tagKey`).
struct PanelTagKeyFocusID: Hashable {}

/// The tag bar (Accepted 2026-11-13, 1A + 2B, drawn in
/// `tasks-filters-drafts.html`). Collapsed it is a "#" key the size of
/// "+"; a click grows it in place, to the right, into "#", All and every
/// tag; Esc, a click elsewhere or "#" again folds it back. With tags picked
/// the collapsed bar names them ("#work or #home") with ✕ to clear. Clicks
/// add and remove tags; with two or more an Any · All switch grows at the
/// bar's end.
///
/// The bar is only as wide as what it shows, from its place at the panel's
/// left, and never more than the room before "+": the tags scroll sideways.
/// It hides while no tags exist at all. Width changes take the expand
/// motion; Reduce Motion is instant.
struct NotesTagBar: View {
    let tags: [String]
    let picks: TagPicks
    /// The accessibility identifiers' stem ("notes-tag-bar", "tasks-tag-bar").
    var idPrefix = "notes-tag-bar"
    @ObservedObject var state: PanelTagBarState
    /// Whether the bar is on screen: the selection bar (T2) or the "+"
    /// card can take its place, and it comes back closed.
    var shown = true
    /// The page orders Tab itself, reaching "#" before "+" through its
    /// focus requests (Tasks); on the other pages AppKit's key loop does.
    var managesOwnTabOrder = false
    /// The page's Tab order, which reaches "#" before "+".
    var focusRequests: AtticFocusRequests? = nil
    let onSelect: (String?) -> Void
    var onMatch: (TagPicks.Match) -> Void = { _ in }

    @Environment(\.atticDesign) private var design
    /// Which edges have tags cut off (owner, 2026-10-31): each fades only then.
    @State private var cutOff = NotesTagBarCutOff()
    /// The pill under the pointer.
    @State private var pointed: NotesTagBarPillID?
    @StateObject private var keys = PanelTagBarKeys()

    private var allID: String { "\(idPrefix)-all" }

    var body: some View {
        let m = NotesBarMetrics.self
        let hidden = tags.isEmpty
        let open = state.isOpen && !hidden
        let motion = Self.widthAnimation(reduceMotion: design.reduceMotion)
        PanelTagBarWidth(collapsed: hidden) {
            // Sizes the bar: what it shows, at its own widths.
            PanelTagBarContent(tags: tags, picks: picks, open: open)
                .hidden()
                .accessibilityHidden(true)
            // Built only while tags exist (no empty element for VoiceOver);
            // the first tag grows it out from the left.
            if !hidden {
                card(open: open)
                    .transition(.modifier(active: NotesTagBarGrow(progress: 0), identity: NotesTagBarGrow(progress: 1)))
            }
        }
        .frame(height: m.control)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(motion, value: tags)
        .animation(motion, value: picks)
        .animation(motion, value: open)
        .background {
            PanelTagBarAnchor(keys: keys, context: PanelTagBarKeys.Context(
                tags: tags, picks: picks, enabled: shown && !hidden, state: state,
                select: onSelect, match: onMatch))
        }
        .onChange(of: shown) { _, now in if !now { state.close() } }
        .onChange(of: hidden) { _, now in if now { state.close() } }
    }

    /// The width's motion as the bar grows, shrinks and tags come and go
    /// (the app's expand preset; Reduce Motion: instant).
    static func widthAnimation(reduceMotion: Bool) -> Animation? {
        AtticMotionPreset.expand.animation(reduceMotion: reduceMotion)
    }

    private func card(open: Bool) -> some View {
        let m = NotesBarMetrics.self
        let shape = Squircle(cornerRadius: m.radius, exponent: AtticControlShape.designExponent)
        return HStack(spacing: 0) {
            if open || picks.isEmpty {
                key(on: open)
            }
            if open {
                PanelTagBarDivider()
                    .transition(.opacity)
                scroller
                    .transition(.opacity)
                if picks.showsMatch {
                    matchSwitch
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
            } else if !picks.isEmpty {
                summary
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, m.tagBarPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: m.control)
        .clipShape(shape)
        // The glass behind the pills, never over them.
        .background(Color.clear.atticRaisedMaterial(cornerRadius: m.radius, interactive: false, edgeLight: true))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tags"))
        .accessibilityIdentifier(idPrefix)
    }

    // MARK: "#"

    private func key(on: Bool) -> some View {
        let m = NotesBarMetrics.self
        let tokens = design.tokens
        let shape = Squircle(cornerRadius: m.pillRadius, exponent: AtticControlShape.designExponent)
        return Button {
            state.isOpen ? state.close() : state.open()
        } label: {
            Text(verbatim: "#")
                .font(.system(size: PanelTagBarMetrics.keyFontSize, weight: .semibold))
                .foregroundStyle(on ? tokens.color(.heading) : tokens.color(.body))
                .frame(width: m.pillHeight, height: m.pillHeight)
                .background { if on { AtticSelectionMarker(cornerRadius: m.pillRadius) } }
                .contentShape(shape)
        }
        .buttonStyle(AtticPressButtonStyle())
        .focusEffectDisabled()
        .modifier(PanelTagKeyFocus(state: state, requests: focusRequests, seam: idPrefix, managed: managesOwnTabOrder, reachable: shown))
        .atticFocusRing(state.keyFocused && state.cursor == nil, cornerRadius: m.pillRadius)
        .help(String(localized: "Tags (⌥⌘T)"))
        .accessibilityLabel(String(localized: "Tags"))
        .accessibilityValue(picks.isEmpty ? String(localized: "All") : picks.spokenPhrase)
        .accessibilityHint(state.isOpen ? String(localized: "Closes the tag bar") : String(localized: "Opens the tag bar"))
        .accessibilityAddTraits(state.isOpen ? .isSelected : [])
        .accessibilityIdentifier("\(idPrefix)-key")
    }

    // MARK: Collapsed with tags picked

    /// "#work or #home ✕": a click opens the bar, ✕ clears the pick.
    private var summary: some View {
        let m = NotesBarMetrics.self
        let shape = Squircle(cornerRadius: m.pillRadius, exponent: AtticControlShape.designExponent)
        return HStack(spacing: 0) {
            Button { state.open() } label: {
                PanelTagPhraseText(parts: picks.phraseParts, size: m.pillFontSize, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, m.pillPaddingX)
                    .frame(height: m.pillHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AtticPressButtonStyle())
            .focusEffectDisabled()
            .layoutPriority(-1)
            .accessibilityLabel(String(localized: "Tags"))
            .accessibilityValue(picks.spokenPhrase)
            .accessibilityHint(String(localized: "Opens the tag bar"))
            .accessibilityIdentifier("\(idPrefix)-picked")
            Button { onSelect(nil) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: PanelTagBarMetrics.clearGlyph, weight: .semibold))
                    .foregroundStyle(design.tokens.color(.helper))
                    .frame(width: PanelTagBarMetrics.clearWidth, height: m.pillHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AtticPressButtonStyle())
            .focusEffectDisabled()
            .help(String(localized: "Show all tags"))
            .accessibilityLabel(String(localized: "Clear tags"))
            .accessibilityIdentifier("\(idPrefix)-clear")
        }
        .background(AtticSelectionMarker(cornerRadius: m.pillRadius))
        .clipShape(shape)
        .atticFocusRing(state.keyFocused && !state.isOpen, cornerRadius: m.pillRadius)
        .modifier(PanelTagKeyFocus(state: state, requests: focusRequests, seam: idPrefix, managed: managesOwnTabOrder, reachable: shown))
    }

    // MARK: Open: All and the tags

    private func point(at tag: String?, inside: Bool) {
        let pill = NotesTagBarPillID(tag: tag)
        if inside { pointed = pill } else if pointed == pill { pointed = nil }
    }

    private func markers(_ chosen: [CGRect], pointed frame: CGRect?, pointedPicked: Bool) -> some View {
        let radius = NotesBarMetrics.pillRadius
        return ZStack(alignment: .topLeading) {
            // By place in the pick: one tag picked instead of another (or
            // All) travels there, as the one marker did (Accepted
            // 2026-11-05, "Animated selection"); a second tag adds one.
            ForEach(Array(chosen.enumerated()), id: \.offset) { _, rect in
                AtticSelectionMarker(cornerRadius: radius)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .transition(AtticSelectionMarker.transition)
            }
            .animation(AtticSelectionMarker.travel(reduceMotion: design.reduceMotion), value: chosen)
            AtticHoverChip(frame: frame, shown: !pointedPicked, cornerRadius: radius)
        }
    }

    private var scroller: some View {
        let m = NotesBarMetrics.self
        let motion = Self.widthAnimation(reduceMotion: design.reduceMotion)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: m.pillGap) {
                    NotesTagBarPill(title: String(localized: "All"), tag: nil, selected: picks.isEmpty,
                                    onHover: { point(at: nil, inside: $0) }) { onSelect(nil) }
                        .anchorPreference(key: NotesTagBarPillBounds.self, value: .bounds) { [NotesTagBarPillID(tag: nil): $0] }
                        .atticFocusRing(state.cursor == .all, cornerRadius: m.pillRadius)
                        .id(allID)
                        .accessibilityHint(String(localized: "Shows every tag"))
                        .accessibilityIdentifier(allID)
                    ForEach(tags, id: \.self) { tag in
                        NotesTagBarPill(title: TasksPanelDesign.tagChipTitle(tag), tag: tag, selected: picks.contains(tag),
                                        onHover: { point(at: tag, inside: $0) }) {
                            onSelect(tag)
                        }
                        .anchorPreference(key: NotesTagBarPillBounds.self, value: .bounds) { [NotesTagBarPillID(tag: tag): $0] }
                        .atticFocusRing(state.cursor == .tag(tag), cornerRadius: m.pillRadius)
                        .id(tag)
                        .accessibilityLabel(tag)
                        .accessibilityIdentifier("\(idPrefix)-\(tag)")
                    }
                }
                // The markers and the hover chip under the pills, in the
                // scrolled content so they scroll with the pills (Accepted
                // 2026-11-05, "Animated selection"): one per picked tag.
                .backgroundPreferenceValue(NotesTagBarPillBounds.self) { pills in
                    GeometryReader { geometry in
                        let picked: [NotesTagBarPillID] = picks.isEmpty
                            ? [NotesTagBarPillID(tag: nil)] : picks.tags.map(NotesTagBarPillID.init(tag:))
                        markers(picked.compactMap { pills[$0] }.map { geometry[$0] },
                                pointed: pointed.flatMap { pills[$0] }.map { geometry[$0] },
                                pointedPicked: pointed.map { picked.contains($0) } ?? false)
                    }
                }
                .padding(.horizontal, PanelTagBarMetrics.focusRoom)
                .frame(height: m.control)
            }
            .onScrollGeometryChange(for: NotesTagBarCutOff.self) { geometry in
                NotesTagBarCutOff(offset: geometry.contentOffset.x, visible: geometry.containerSize.width,
                                  content: geometry.contentSize.width)
            } action: { _, edges in
                cutOff = edges
            }
            // The keyboard's stop, and a tag just picked, come into view.
            .onChange(of: state.cursor) { _, stop in
                switch stop {
                case .all: withAnimation(motion) { proxy.scrollTo(allID, anchor: .center) }
                case let .tag(tag): withAnimation(motion) { proxy.scrollTo(tag, anchor: .center) }
                default: break
                }
            }
            .onAppear {
                if let first = picks.tags.first { proxy.scrollTo(first, anchor: .center) }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: m.control)
    }

    // MARK: Any · All

    private var matchSwitch: some View {
        let m = PanelTagBarMetrics.self
        let tokens = design.tokens
        let track = Squircle(cornerRadius: NotesBarMetrics.pillRadius, exponent: AtticControlShape.designExponent)
        return HStack(spacing: m.segmentGap) {
            segment(.any, title: String(localized: "Any", comment: "Tag bar: tasks with any picked tag"))
            segment(.all, title: String(localized: "All", comment: "Tag bar: tasks with every picked tag"))
        }
        .padding(m.trackPadding)
        .frame(height: NotesBarMetrics.pillHeight)
        .background(track.fill(tokens.ink(.heading).withAlpha(design.increaseContrast ? 0.1 : m.trackAlpha).color))
        .overlay {
            if design.increaseContrast { track.strokeBorder(tokens.ink(.heading).withAlpha(0.35).color, lineWidth: 0.5) }
        }
        .padding(.leading, m.switchGap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Match"))
        .accessibilityIdentifier("\(idPrefix)-match")
    }

    private func segment(_ match: TagPicks.Match, title: String) -> some View {
        let m = PanelTagBarMetrics.self
        let tokens = design.tokens
        let on = picks.match == match
        let shape = Squircle(cornerRadius: m.segmentRadius, exponent: AtticControlShape.designExponent)
        let dark = design.mode == .dark
        return Button { onMatch(match) } label: {
            Text(verbatim: title)
                .font(.system(size: m.segmentFontSize, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? tokens.color(.heading) : tokens.color(.body))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, m.segmentPaddingX)
                .frame(height: m.segmentHeight)
                .background {
                    if on {
                        shape.fill(dark ? Color.white.opacity(0.18) : Color.white)
                            .shadow(color: .black.opacity(dark ? 0 : 0.15), radius: 0.75, y: 0.5)
                            .overlay {
                                if design.increaseContrast { shape.strokeBorder(tokens.ink(.heading).withAlpha(0.5).color, lineWidth: 0.5) }
                            }
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(AtticPressButtonStyle())
        .focusEffectDisabled()
        .atticFocusRing(state.cursor == .match(match), cornerRadius: m.segmentRadius)
        .animation(AtticSelectionMarker.animation(reduceMotion: design.reduceMotion), value: on)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(match == .any ? String(localized: "Shows tasks with any picked tag")
                                         : String(localized: "Shows tasks with every picked tag"))
        .accessibilityIdentifier("\(idPrefix)-match-\(match.rawValue)")
    }
}

/// The bar's measures beyond the pills' (the drawing's 2× px, halved).
enum PanelTagBarMetrics {
    /// "#": 12 px semibold in a 21 pt key.
    static let keyFontSize: CGFloat = 12
    /// The divider after "#": a hairline 13 tall, 3 each side.
    static let dividerHeight: CGFloat = 13
    static let dividerGap: CGFloat = 3
    /// ✕ on the collapsed bar.
    static let clearGlyph: CGFloat = 7
    static let clearWidth: CGFloat = 17
    /// Room for the keyboard's focus ring around the first and last pill.
    static let focusRoom: CGFloat = 0
    /// Any · All: a 21 pt track, 2 pt inside, 17 pt segments 6 pt either
    /// side of 10 px text, 3 pt after the last tag.
    static let trackPadding: CGFloat = 2
    static let trackAlpha: Double = 0.05
    static let segmentGap: CGFloat = 1
    static let segmentHeight: CGFloat = 17
    static let segmentPaddingX: CGFloat = 6
    static let segmentFontSize: CGFloat = 10
    static let segmentRadius: CGFloat = AtticShape.controlRadius(height: 17)
    static let switchGap: CGFloat = 3
}

/// The hairline between "#" and All.
private struct PanelTagBarDivider: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        Rectangle()
            .fill(design.tokens.ink(.heading).withAlpha(design.increaseContrast ? 0.35 : 0.16).color)
            .frame(width: AtticHairline.width, height: PanelTagBarMetrics.dividerHeight)
            .padding(.horizontal, PanelTagBarMetrics.dividerGap)
            .accessibilityHidden(true)
    }
}

/// Picked tags in words, each tag in its own colour: "#work or #home".
struct PanelTagPhraseText: View {
    let parts: [TagPhrasePart]
    var size: CGFloat = NotesBarMetrics.pillFontSize
    var weight: Font.Weight = .semibold
    /// The words between the tags.
    var ink: AtticInk = .heading

    @Environment(\.atticDesign) private var design
    @Environment(\.atticTagColouring) private var colouring

    var body: some View {
        let tokens = design.tokens
        parts.reduce(Text(verbatim: "")) { text, part in
            switch part {
            case let .text(words):
                text + Text(verbatim: words).foregroundColor(tokens.color(ink)).fontWeight(.regular)
            case let .tag(tag):
                text + Text(verbatim: "#" + tag)
                    .foregroundColor(AtticSurfaceInk.colouredTagText(colouring.hue(for: tag), dark: design.mode == .dark, tokens: tokens).color)
            }
        }
        .font(.system(size: size, weight: weight))
    }
}

/// What the bar measures itself by, without buttons: the same pieces at
/// their own widths (semibold where picked).
private struct PanelTagBarContent: View {
    let tags: [String]
    let picks: TagPicks
    let open: Bool

    var body: some View {
        let m = NotesBarMetrics.self
        HStack(spacing: 0) {
            if open || picks.isEmpty {
                Color.clear.frame(width: m.pillHeight, height: m.pillHeight)
            }
            if open {
                PanelTagBarDivider()
                HStack(spacing: m.pillGap) {
                    pill(String(localized: "All"), selected: picks.isEmpty)
                    ForEach(tags, id: \.self) { tag in pill(TasksPanelDesign.tagChipTitle(tag), selected: picks.contains(tag)) }
                }
                .padding(.horizontal, PanelTagBarMetrics.focusRoom)
                if picks.showsMatch {
                    let s = PanelTagBarMetrics.self
                    HStack(spacing: s.segmentGap) {
                        segment(String(localized: "Any"), on: picks.match == .any)
                        segment(String(localized: "All"), on: picks.match == .all)
                    }
                    .padding(s.trackPadding)
                    .padding(.leading, s.switchGap)
                }
            } else if !picks.isEmpty {
                HStack(spacing: 0) {
                    PanelTagPhraseText(parts: picks.phraseParts)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, m.pillPaddingX)
                    Color.clear.frame(width: PanelTagBarMetrics.clearWidth, height: 1)
                }
            }
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

    private func segment(_ title: String, on: Bool) -> some View {
        let s = PanelTagBarMetrics.self
        return Text(verbatim: title)
            .font(.system(size: s.segmentFontSize, weight: on ? .semibold : .regular))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, s.segmentPaddingX)
    }
}

/// The tag bar's width: its sizer's (what it shows at its own widths),
/// never more than the room proposed (it stops before "+"), and none
/// while collapsed. The second subview, the bar itself, takes it.
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

/// "#" (or the collapsed bar's picked tags) as a keyboard stop. On Tasks,
/// which orders Tab itself, it is focusable once the page's Tab or ⌥⌘T asks;
/// on the other pages it is a plain stop in AppKit's key loop while the bar
/// shows. A hidden bar is no stop.
private struct PanelTagKeyFocus: ViewModifier {
    @ObservedObject var state: PanelTagBarState
    let requests: AtticFocusRequests?
    /// The bar's accessibility stem, for the test seam.
    let seam: String
    /// Tasks orders Tab itself and arms "#" by request; on the other pages
    /// it is a plain stop in AppKit's key loop (round 1 review R-6: BG-67's
    /// class), while the bar shows.
    let managed: Bool
    let reachable: Bool
    @FocusState private var focused: Bool
    @State private var armed = false

    func body(content: Content) -> some View {
        // Tasks keeps its own Tab order exactly as before (the page asks for
        // "#" itself, whatever the bar shows); the other pages' key loop
        // walks it only while the bar shows.
        let focusable = managed ? armed : reachable
        #if DEBUG
        let _ = PanelKeyStopSeam.tagKey[seam] = focusable
        #endif
        content
            .focusable(focusable, interactions: .activate)
            .focused($focused)
            .onChange(of: state.keyFocusRequest) { _, _ in arm() }
            .onReceive(requests?.requests.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { asked in
                guard asked == AnyHashable(PanelTagKeyFocusID()) else { return }
                arm()
            }
            .onChange(of: focused) { _, now in
                state.noteKeyFocus(now)
                requests?.note(PanelTagKeyFocusID(), focused: now)
                if !now { armed = false }
            }
            // Hidden, or on another kind of page, "#" gives the keyboard up.
            .onChange(of: reachable) { _, now in if !now, !managed { release() } }
            .onChange(of: managed) { _, _ in release() }
            .onDisappear {
                // The key and summary replace one another. Release native
                // ownership, preserving a cursor deliberately opening the bar.
                state.noteKeyFocus(false, closeWhenLeaving: false)
                requests?.note(PanelTagKeyFocusID(), focused: false)
            }
    }

    private func release() {
        armed = false
        if focused { focused = false }
    }

    private func arm() {
        guard reachable || managed else { return }
        armed = true
        DispatchQueue.main.async { focused = true }
    }
}

// MARK: - Keys and clicks elsewhere

/// The tag bar's keys and its click-elsewhere, in its own window only:
/// ⌥⌘T opens it on the first tag (or closes it); while open Esc closes it;
/// while it has the keyboard ← → move, Space picks or unpicks (or opens),
/// Return closes. The page's own Esc, arrows, Space and Return wait while
/// it holds them (`PanelTagBarState.ownsEscape`, `.ownsKeys`).
@MainActor
final class PanelTagBarKeys: ObservableObject {
    struct Context {
        var tags: [String]
        var picks: TagPicks
        var enabled: Bool
        var state: PanelTagBarState
        var select: (String?) -> Void
        var match: (TagPicks.Match) -> Void
    }

    weak var view: NSView?
    var context: Context?
    private var monitors: [Any] = []

    func install() {
        guard monitors.isEmpty else { return }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) == true ? nil : event }
        }) { monitors.append(keys) }
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleClick(event) }
            return event
        }) { monitors.append(clicks) }
    }

    func remove() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    /// What a key does to the bar (pure enough to test through `act`).
    enum Action: Equatable {
        case none, toggle, close, move(Int), activate, openOnFirst
    }

    static func action(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                       isOpen: Bool, hasKeyboard: Bool, hasCursor: Bool) -> Action {
        if AtticTaskShortcut.matches(AtticTaskShortcut.tagBar, characters: characters, keyCode: keyCode, modifiers: modifiers) {
            return .toggle
        }
        guard modifiers.intersection([.command, .shift, .option, .control]).isEmpty else { return .none }
        switch keyCode {
        case 53: return isOpen ? .close : .none
        case 123: return isOpen && hasKeyboard ? .move(-1) : .none
        case 124: return isOpen && hasKeyboard ? .move(1) : .none
        case 49:
            guard hasKeyboard else { return .none }
            return isOpen && hasCursor ? .activate : .openOnFirst
        case 36, 76:
            guard hasKeyboard else { return .none }
            return isOpen ? .close : .openOnFirst
        default: return .none
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let context, context.enabled, let window = view?.window, event.window === window, window.isKeyWindow,
              !AtticTextInput.isPopoverOpen else { return false }
        let state = context.state
        let action = Self.action(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                 modifiers: event.modifierFlags, isOpen: state.isOpen,
                                 hasKeyboard: state.hasKeyboard, hasCursor: state.cursor != nil)
        let stops = PanelTagBarStop.stops(tags: context.tags, picks: context.picks)
        switch action {
        case .none:
            return false
        case .toggle:
            if state.isOpen {
                state.close()
            } else {
                state.open(cursor: PanelTagBarStop.first(tags: context.tags))
            }
            state.requestKeyFocus()
        case .close:
            let keyboard = state.hasKeyboard
            state.close()
            // The keyboard stays on "#", where it was.
            if keyboard { state.requestKeyFocus() }
        case let .move(step):
            state.moveCursor(by: step, in: stops)
            announce(state.cursor, picks: context.picks)
        case .openOnFirst:
            state.open(cursor: PanelTagBarStop.first(tags: context.tags))
        case .activate:
            switch state.cursor {
            case .all: context.select(nil)
            case let .tag(tag): context.select(tag)
            case let .match(match): context.match(match)
            case nil: break
            }
        }
        return true
    }

    /// VoiceOver hears where the keyboard moved: "#work, picked".
    private func announce(_ stop: PanelTagBarStop?, picks: TagPicks) {
        let words: String
        switch stop {
        case .all: words = picks.isEmpty ? String(localized: "All, picked") : String(localized: "All")
        case let .tag(tag): words = picks.contains(tag) ? String(localized: "\(tag), picked") : tag
        case let .match(match):
            let title = match == .any ? String(localized: "Any") : String(localized: "All")
            words = picks.match == match ? String(localized: "\(title), selected") : title
        case nil: return
        }
        AccessibilityNotification.Announcement(words).post()
    }

    /// A click anywhere else in the bar's window closes it (1A).
    private func handleClick(_ event: NSEvent) {
        guard let context, context.state.isOpen, let view, let window = view.window, event.window === window else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        if !view.bounds.contains(point) { context.state.close() }
    }
}

/// The bar's place in its window, for the keys and clicks above.
private struct PanelTagBarAnchor: NSViewRepresentable {
    let keys: PanelTagBarKeys
    let context: PanelTagBarKeys.Context

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        view.keys = keys
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        keys.context = self.context
        keys.view = view
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? AnchorView)?.keys?.remove()
    }

    private final class AnchorView: NSView {
        weak var keys: PanelTagBarKeys?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated {
                if window == nil { keys?.remove() } else { keys?.view = self; keys?.install() }
            }
        }
    }
}
