import AppKit
import Combine
import SwiftUI

/// The panel's top row on every page (Accepted 2026-10-29/30, "Top row and
/// bottom bar"): Pin alone on the left (the shell draws it), a page's own
/// leading text after it (Calendar's month), and on the right the page's
/// own switch, then ••• (the page's options, Accepted 2026-11-05; Settings
/// is the island's), then Search at the far right.
///
/// While the search is open, Pin, the leading text, the switch and •••
/// fold away and the field fills the row, with the chrome inset on both
/// sides. Escape brings them back.
///
/// Each page draws this row over its own content, so its leading text, its
/// switch and its open field travel with their page. The pin, ••• and the
/// search button are the shell's (`PanelSharedChrome`), drawn once, so a
/// page switch never moves them: here they are clear stand-ins that keep
/// the row's places, and they fold with the current page's search through
/// `PanelTopRowState`.
enum PanelTopRowLayout {
    /// Between ••• and Search (Accepted 2026-11-05, "Header spacing": the
    /// bottom bar's gap, was 3).
    static let gap: CGFloat = AtticPanelChromeMetrics.headerGap
    /// Between the page's own switch and the top row's icons: twice that,
    /// so what navigates reads apart from what acts.
    static let switchGap: CGFloat = 2 * gap
    /// From the pin to the page's leading text (16 px).
    static let leadingGap: CGFloat = 8
    static var control: CGFloat { AtticControlSize.headerControl }

    /// Where the page's leading slot starts, from the panel's left edge.
    static func leading(_ layout: PanelPageLayout) -> CGFloat {
        layout.chromeInsets.leading + control + leadingGap
    }

    /// The pin's frame, from the panel's top-left corner.
    static func pinFrame(_ layout: PanelPageLayout) -> CGRect {
        CGRect(x: layout.chromeInsets.leading, y: layout.chromeInsets.top, width: control, height: control)
    }

    /// The search button's frame: the row's far right.
    static func searchButtonFrame(_ layout: PanelPageLayout) -> CGRect {
        CGRect(x: layout.panelSize.width - layout.chromeInsets.trailing - control, y: layout.chromeInsets.top,
               width: control, height: control)
    }

    /// •••'s frame: one gap before Search.
    static func moreButtonFrame(_ layout: PanelPageLayout) -> CGRect {
        searchButtonFrame(layout).offsetBy(dx: -(control + gap), dy: 0)
    }

    /// The page switch's frame for a switch `width` wide: `switchGap` before •••.
    static func switchFrame(_ layout: PanelPageLayout, width: CGFloat) -> CGRect {
        let more = moreButtonFrame(layout)
        return CGRect(x: more.minX - switchGap - width, y: more.minY, width: width, height: control)
    }

    /// The open field: the whole row, the chrome inset on both sides.
    static func fieldFrame(_ layout: PanelPageLayout) -> CGRect {
        CGRect(x: layout.chromeInsets.leading, y: layout.chromeInsets.top,
               width: max(0, layout.panelSize.width - layout.chromeInsets.leading - layout.chromeInsets.trailing),
               height: control)
    }

    /// The right-hand controls' width: the switch (if any), •••, Search.
    static func trailingWidth(switchWidth: CGFloat) -> CGFloat {
        (switchWidth > 0 ? switchWidth + switchGap : 0) + control + gap + control
    }

    /// The search's open and close, as on Tasks: the design's ease (240 ms)
    /// in, a quick fade out; Reduce Motion a short ease.
    static func searchAnimation(shown: Bool, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : (shown ? AtticPanelChromeMetrics.curve(0.24) : .easeOut(duration: 0.12))
    }

    /// The field grows from the button's place; the button fades.
    static var fieldTransition: AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.2, anchor: .trailing).combined(with: .opacity), removal: .opacity)
    }
}

/// What the shell needs from the current page's top row: whether its search
/// is open (the pin folds with it) and how much of the row its controls
/// take (AppKit's drag lane keeps clear of them). One per panel, in the
/// environment; pages write to it, never while laying out.
@MainActor
final class PanelTopRowState: ObservableObject {
    /// The pages whose search is open.
    @Published private(set) var searchingPages: Set<PanelPage> = []
    /// The floating chat is open over the panel: the top row's controls fold
    /// away, so they don't show through its blur as dead buttons beside the
    /// chat's own (Accepted 2026-11-06: the panel blurs, controls float on it).
    @Published var chatOver = false

    /// Each page's controls, from the panel's left and right edges.
    struct Footprint: Equatable {
        /// From the panel's left edge to the end of the leading controls.
        var leading: CGFloat
        /// From the start of the right-hand controls to the panel's right edge.
        var trailing: CGFloat
    }

    private(set) var footprints: [PanelPage: Footprint] = [:]
    /// AppKit's hit testing follows the footprint (not observable).
    var onFootprintChange: (() -> Void)?

    /// Each page's open search's own end (Escape's), keyed by the field
    /// that registered it: a field replaced mid-transition never clears
    /// its successor's. Not observable.
    private var searchEnders: [PanelPage: (field: UUID, end: () -> Void)] = [:]

    func setSearchEnder(_ end: @escaping () -> Void, field: UUID, on page: PanelPage) {
        searchEnders[page] = (field, end)
    }

    func clearSearchEnder(field: UUID, on page: PanelPage) {
        if searchEnders[page]?.field == field { searchEnders[page] = nil }
    }

    /// A click on the page's empty space while its search is open: the
    /// search ends, as Escape ends it (owner, 2026-10-31).
    func endSearch(on page: PanelPage) {
        guard isSearching(page) else { return }
        searchEnders[page]?.end()
    }

    func setSearching(_ searching: Bool, on page: PanelPage) {
        if searching, !searchingPages.contains(page) { searchingPages.insert(page) }
        if !searching, searchingPages.contains(page) { searchingPages.remove(page) }
        onFootprintChange?()
    }

    func setLeading(_ leading: CGFloat, for page: PanelPage) {
        var footprint = footprints[page] ?? Footprint(leading: 0, trailing: 0)
        footprint.leading = leading
        set(footprint, for: page)
    }

    func setTrailing(_ trailing: CGFloat, for page: PanelPage) {
        var footprint = footprints[page] ?? Footprint(leading: 0, trailing: 0)
        footprint.trailing = trailing
        set(footprint, for: page)
    }

    private func set(_ footprint: Footprint, for page: PanelPage) {
        guard footprints[page] != footprint else { return }
        footprints[page] = footprint
        onFootprintChange?()
    }

    func isSearching(_ page: PanelPage) -> Bool { searchingPages.contains(page) }

    /// The page's top-row controls are folded away: by its search or the chat.
    func isAway(_ page: PanelPage) -> Bool { isSearching(page) || chatOver }

    /// The pages whose top row is dimmed (Draw's D6: during a stroke the
    /// shell's Pin, ••• and Search dim with the page's own controls).
    @Published private(set) var dimmedPages: Set<PanelPage> = []

    func setDimmed(_ dimmed: Bool, on page: PanelPage) {
        if dimmed, !dimmedPages.contains(page) { dimmedPages.insert(page) }
        if !dimmed, dimmedPages.contains(page) { dimmedPages.remove(page) }
    }
}

/// The shell's header dimmed with the current page's top row (D6). Only this
/// observes the state, so the header itself isn't re-evaluated.
struct PanelHeaderDim: ViewModifier {
    @ObservedObject var state: PanelTopRowState
    let page: PanelPage
    @Environment(\.atticDesign) private var design

    func body(content: Content) -> some View {
        let dimmed = state.dimmedPages.contains(page)
        content
            .opacity(dimmed ? 0.35 : 1)
            .animation(design.reduceMotion ? nil : AtticMotionScale.easeOut(AtticMotionScale.fast), value: dimmed)
    }
}

private struct PanelTopRowStateKey: EnvironmentKey {
    static let defaultValue: PanelTopRowState? = nil
}

private struct PanelTopRowPageKey: EnvironmentKey {
    static let defaultValue: PanelPage? = nil
}

private struct PanelPageTravelKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct PanelPageMotionKey: EnvironmentKey {
    static let defaultValue: PanelPageMotion = .instant
}

/// The two native editor hosts follow transit directly, without publishing
/// through their page models or rebuilding TextKit on each slide boundary.
@MainActor
final class PanelNativeScrollIndicators {
    private weak var scroll: NSScrollView?
    private weak var transit: PanelPageTransit?
    private weak var vertical: NSScroller?
    private weak var horizontal: NSScroller?
    private var subscription: AnyCancellable?
    private var original: (verticalAlpha: CGFloat, horizontalAlpha: CGFloat)?

    func bind(_ scroll: NSScrollView, transit: PanelPageTransit?) {
        guard self.scroll !== scroll || self.transit !== transit
                || vertical !== scroll.verticalScroller || horizontal !== scroll.horizontalScroller else { return }
        stop()
        self.scroll = scroll
        self.transit = transit
        vertical = scroll.verticalScroller
        horizontal = scroll.horizontalScroller
        subscription = transit?.$sliding.removeDuplicates().sink { [weak self] sliding in
            MainActor.assumeIsolated { self?.apply(sliding) }
        }
    }

    func stop() {
        subscription = nil
        apply(false)
        original = nil
        vertical = nil
        horizontal = nil
        scroll = nil
        transit = nil
    }

    private func apply(_ sliding: Bool) {
        // Removing a legacy scroller also removes its gutter and rewraps
        // the document. Keep native geometry and hide only its drawing.
        if sliding {
            if original == nil {
                original = (vertical?.alphaValue ?? 1, horizontal?.alphaValue ?? 1)
            }
            vertical?.alphaValue = 0
            horizontal?.alphaValue = 0
        } else if let original {
            vertical?.alphaValue = original.verticalAlpha
            horizontal?.alphaValue = original.horizontalAlpha
            self.original = nil
        }
    }
}

private struct PanelPageTransitKey: EnvironmentKey {
    static let defaultValue: PanelPageTransit? = nil
}

private struct PanelNativePageSlideKey: EnvironmentKey {
    static let defaultValue: PanelNativePageSlide? = nil
}

/// Whether a page switch's slide is running (`PanelUIState.switchPage`).
@MainActor
final class PanelPageTransit: ObservableObject {
    @Published var sliding = false
    /// The page whose contents are still travelling out. A retained page
    /// may stop accepting input immediately but must keep painting until
    /// its slide finishes.
    @Published var departingPage: PanelPage?
}

extension EnvironmentValues {
    var panelNativePageSlide: PanelNativePageSlide? {
        get { self[PanelNativePageSlideKey.self] }
        set { self[PanelNativePageSlideKey.self] = newValue }
    }
    /// How far the shell has moved this page sideways for a page switch
    /// (0 at rest). The top row moves back by as much, in the same
    /// transaction, so it changes in place while the page travels.
    var panelPageTravel: CGFloat {
        get { self[PanelPageTravelKey.self] }
        set { self[PanelPageTravelKey.self] = newValue }
    }

    /// The last page switch's motion, for what changes in place.
    var panelPageMotion: PanelPageMotion {
        get { self[PanelPageMotionKey.self] }
        set { self[PanelPageMotionKey.self] = newValue }
    }

    /// The page switch's slide state: scroll bars stay hidden while it runs.
    var panelPageTransit: PanelPageTransit? {
        get { self[PanelPageTransitKey.self] }
        set { self[PanelPageTransitKey.self] = newValue }
    }

    /// The page whose top row this is (nil outside a top row).
    var panelTopRowPage: PanelPage? {
        get { self[PanelTopRowPageKey.self] }
        set { self[PanelTopRowPageKey.self] = newValue }
    }

    /// The shell's top row state (nil in the gallery, captures and tests
    /// that host a page alone).
    var panelTopRowState: PanelTopRowState? {
        get { self[PanelTopRowStateKey.self] }
        set { self[PanelTopRowStateKey.self] = newValue }
    }
}

/// Keeps a view in the top row in place while the shell moves its page for
/// a switch, as `PanelTopRow` does (an open note's scrolled-away title).
struct PanelChangesInPlace: ViewModifier {
    @Environment(\.panelPageTravel) private var travel

    func body(content: Content) -> some View {
        content.offset(x: -travel).modifier(PanelInPlaceFade(away: travel != 0))
    }
}

/// What changes in place on a page switch takes turns (Accepted
/// 2026-11-04: one state at a time): the old page's fades out at once,
/// then the new page's fades in, never both drawn over each other. A page
/// away from the current one (moved for a switch) is the old.
struct PanelInPlaceFade: ViewModifier {
    let away: Bool
    @Environment(\.panelPageMotion) private var motion

    func body(content: Content) -> some View {
        content.animation(motion.inPlaceOpacityAnimation(incoming: !away)) { $0.opacity(away ? 0 : 1) }
    }
}

/// Two states of one place take turns (Accepted 2026-11-04, "one state at
/// a time"): the old leaves at once on a quick fade and the new comes in
/// once it has gone, so their texts are never drawn over each other (the
/// owner's recording: "#eeJul 20Pin", "NoneJul 2027", "All #ee" under
/// "6 Nov"). Reduce Motion: at once.
enum PanelTakeTurns {
    static let out: TimeInterval = PanelPageMotion.fadeOut
    static let `in`: TimeInterval = PanelPageMotion.fadeIn

    static func transition(reduceMotion: Bool, after delay: TimeInterval = out) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(insertion: .opacity.animation(.easeOut(duration: Self.in).delay(delay)),
                           removal: .opacity.animation(.easeIn(duration: out)))
    }
}

/// A page's scroll bars: hidden while a page switch slides, so the new
/// page's never flashes or crosses the panel.
struct PanelTransitScrollIndicators: ViewModifier {
    @Environment(\.panelPageTransit) private var transit

    func body(content: Content) -> some View {
        if let transit {
            content.modifier(Observing(transit: transit))
        } else {
            content
        }
    }

    private struct Observing: ViewModifier {
        @ObservedObject var transit: PanelPageTransit

        func body(content: Content) -> some View {
            content.scrollIndicators(transit.sliding ? .never : .automatic)
                // A page travelling past another page's edge must keep its
                // scroll content visible until the outer glass rim clips it.
                // The native scroll viewport otherwise cuts text on the
                // internal seam even when its page-level clip is widened.
                .scrollClipDisabled(transit.sliding)
        }
    }
}

extension View {
    func panelChangesInPlace() -> some View { modifier(PanelChangesInPlace()) }
}

/// The top row. `leading` is the page's text after the pin (Calendar's
/// month; empty elsewhere); `pageSwitch` the page's own switch (Now · Later
/// · Done, Calendar's ‹ ›; the slot Notes' board | list fills on the notes
/// list); `search` the search button, or the open field.
struct PanelTopRow<Leading: View, Switch: View, Search: View>: View {
    let page: PanelPage
    let layout: PanelPageLayout
    /// The search field is open: everything else folds away.
    var searchOpen = false
    /// What ••• offers on this page, read when it opens.
    var moreCommands: () -> [AtticMenuCommand] = { [] }
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var pageSwitch: () -> Switch
    @ViewBuilder var search: () -> Search

    @Environment(\.panelTopRowState) private var state
    @Environment(\.panelSharedChrome) private var chrome
    @Environment(\.panelPageTravel) private var travel
    @Environment(\.panelNativePageSlide) private var nativeSlide

    @ViewBuilder var body: some View {
        Group {
            if let nativeSlide {
                // The page travels in its own native layer; this independent
                // header layer receives the inverse travel in the handler.
                PanelNativeChromeHost(page: page, selected: page, kind: .topRow,
                                      driver: nativeSlide, content: AnyView(row))
                    .frame(height: PanelTopRowLayout.control + layout.chromeInsets.top)
            } else {
                row.offset(x: -travel).modifier(PanelInPlaceFade(away: travel != 0))
            }
        }
        .onChange(of: searchOpen, initial: true) { _, open in state?.setSearching(open, on: page) }
        .onAppear { chrome?.setTopRowShown(true, for: page) }
        .onDisappear {
            state?.setSearching(false, on: page)
            chrome?.removeTopRow(for: page)
        }
    }

    private var row: some View {
        let control = PanelTopRowLayout.control
        let gap = PanelTopRowLayout.gap
        return ZStack(alignment: .trailing) {
            // Folded away (not just faded) while searching, so VoiceOver
            // and the keyboard only reach the field.
            if !searchOpen {
                HStack(spacing: 0) {
                    leading()
                        .padding(.leading, control + PanelTopRowLayout.leadingGap)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: PanelPageLayout.coordinateSpace).maxX } action: {
                            report(leading: $0)
                        }
                    Spacer(minLength: gap)
                    HStack(spacing: PanelTopRowLayout.switchGap) {
                        pageSwitch()
                        PanelTopRowMoreButton(page: page, commands: moreCommands)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: PanelPageLayout.coordinateSpace).minX } action: {
                        report(trailingStart: $0)
                    }
                    .padding(.trailing, control + gap)
                }
                .transition(.opacity)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                search()
                    .environment(\.panelTopRowPage, page)
            }
        }
        .modifier(PanelChatFold(state: state, page: page))
        .frame(height: control)
        .padding(.top, layout.chromeInsets.top)
        .padding(.leading, layout.chromeInsets.leading)
        .padding(.trailing, layout.chromeInsets.trailing)
        .frame(maxWidth: .infinity, alignment: .top)
        // Owner, 2026-10-31: the row stays in place through a page switch;
        // only what differs (the page's switch and leading text) changes:
        // the old fades out, then the new fades in (Accepted 2026-11-04).
    }

    private func report(leading maxX: CGFloat) {
        state?.setLeading(max(layout.chromeInsets.leading + PanelTopRowLayout.control, maxX), for: page)
    }

    private func report(trailingStart minX: CGFloat) {
        state?.setTrailing(max(0, layout.panelSize.width - minX), for: page)
    }
}

extension PanelTopRow where Leading == EmptyView {
    init(page: PanelPage, layout: PanelPageLayout, searchOpen: Bool = false,
         moreCommands: @escaping () -> [AtticMenuCommand] = { [] },
         @ViewBuilder pageSwitch: @escaping () -> Switch, @ViewBuilder search: @escaping () -> Search) {
        self.init(page: page, layout: layout, searchOpen: searchOpen, moreCommands: moreCommands, leading: { EmptyView() },
                  pageSwitch: pageSwitch, search: search)
    }
}

extension PanelTopRow where Leading == EmptyView, Switch == EmptyView {
    init(page: PanelPage, layout: PanelPageLayout, searchOpen: Bool = false,
         moreCommands: @escaping () -> [AtticMenuCommand] = { [] },
         @ViewBuilder search: @escaping () -> Search) {
        self.init(page: page, layout: layout, searchOpen: searchOpen, moreCommands: moreCommands, leading: { EmptyView() },
                  pageSwitch: { EmptyView() }, search: search)
    }
}

/// The top row's search button: the header's 27 pt control, as the pin,
/// with the magnifier. In the panel the shell draws it (`shared`), so it
/// stays still while pages switch: a page's own is a clear stand-in that
/// lends the shell its words and its action.
struct PanelTopRowSearchButton: View {
    let label: String
    var identifier: String
    /// The shell's own button (drawn), not a page's stand-in.
    var shared = false
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.panelSharedChrome) private var chrome
    @Environment(\.panelTopRowPage) private var page

    init(label: String.LocalizationValue, identifier: String, action: @escaping () -> Void) {
        self.init(label: String(localized: label), identifier: identifier, shared: false, action: action)
    }

    init(label: String, identifier: String, shared: Bool, action: @escaping () -> Void) {
        self.label = label
        self.identifier = identifier
        self.shared = shared
        self.action = action
    }

    var body: some View {
        let side = AtticControlSize.headerControl
        if !shared, let chrome, let page {
            Color.clear
                .frame(width: side, height: side)
                .accessibilityHidden(true)
                .onChange(of: "\(identifier)|\(label)", initial: true) { _, _ in
                    chrome.setSearch(label: label, identifier: identifier, action: action, for: page)
                }
        } else {
            AtticRaisedButton(systemName: "magnifyingglass", label: String.LocalizationValue(stringLiteral: label),
                              size: CGSize(width: side, height: side),
                              emphasisedGlyph: true, flat: design.effectiveControls != .liquidGlass,
                              cornerRadius: AtticRadius.header, action: action)
                .atticDesignCorners()
                .accessibilityIdentifier(identifier)
        }
    }
}

/// ••• on the top row: the current page's options, in the app's solid menu
/// (Accepted 2026-11-05, "Page-specific options"). `commands` is read when
/// it opens, so ticks are current. In the panel the shell draws it
/// (`shared`); a page's own is a clear stand-in that lends the shell what
/// the page offers.
struct PanelTopRowMoreButton: View {
    var shared = false
    let page: PanelPage
    let commands: () -> [AtticMenuCommand]

    @Environment(\.atticDesign) private var design
    @Environment(\.panelSharedChrome) private var chrome
    @State private var anchor = AtticMenuAnchor.Holder()

    var body: some View {
        let side = AtticControlSize.headerControl
        if !shared, let chrome {
            Color.clear
                .frame(width: side, height: side)
                .accessibilityHidden(true)
                .onAppear { chrome.setMore(commands, for: page) }
        } else {
            AtticRaisedButton(systemName: "ellipsis.circle", label: "Options", size: CGSize(width: side, height: side),
                              help: String(localized: "Options"), emphasisedGlyph: true,
                              flat: design.effectiveControls != .liquidGlass, cornerRadius: AtticRadius.header) {
                guard let view = anchor.view else { return }
                AtticNativeMenu.popUp(commands(), in: view)
            }
            .atticDesignCorners()
            .background(AtticMenuAnchor(holder: anchor).allowsHitTesting(false).accessibilityHidden(true))
            .accessibilityHint(String(localized: "Opens a menu"))
            .accessibilityIdentifier("panel-more-button")
        }
    }
}

/// A page's top row folds away while the chat floats over the panel, and so
/// does any other control a page floats over its content (Draw's title,
/// tools and pills): under the chat's blur, a bright control would still
/// show through as a patch. Only this observes the chat, so the control's
/// own body gains no work.
struct PanelChatFold: ViewModifier {
    let state: PanelTopRowState?
    let page: PanelPage

    func body(content: Content) -> some View {
        if let state {
            Observer(state: state, page: page) { content }
        } else {
            content
        }
    }

    private struct Observer<Row: View>: View {
        @ObservedObject var state: PanelTopRowState
        let page: PanelPage
        @ViewBuilder var row: () -> Row

        var body: some View {
            PanelControlFold(folded: state.chatOver, preservesUnfoldedAccessibility: page == .canvas, content: row)
        }
    }
}

/// A page while its search is open: a click on the page's empty space
/// (not a row, card or control, whose own gestures take their clicks first)
/// ends the search, as Escape does (owner, 2026-10-31). The tap sits on the
/// page itself, so it also hears clicks on a list's bare scroll space, and
/// it is off while the search is closed. Observes the top row alone, so
/// opening a search redraws only this.
struct PanelSearchDismissOnEmptyClick: ViewModifier {
    @ObservedObject var state: PanelTopRowState
    let page: PanelPage

    func body(content: Content) -> some View {
        content.gesture(TapGesture().onEnded { state.endSearch(on: page) },
                        including: state.isSearching(page) ? .all : .subviews)
    }
}
