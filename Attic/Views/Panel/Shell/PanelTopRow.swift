import SwiftUI

/// The panel's top row on every page (Accepted 2026-10-29/30, "Top row and
/// bottom bar"): Pin alone on the left (the shell draws it), a page's own
/// leading text after it (Calendar's month), and on the right the page's
/// own switch, then ••• (Settings), then Search at the far right.
///
/// While the search is open, Pin, the leading text, the switch and •••
/// fold away and the field fills the row, with the chrome inset on both
/// sides. Escape brings them back.
///
/// Each page draws this row over its own content, so its switch and search
/// travel with their page; the shell's pin reads `PanelTopRowState` to fold
/// with the current page's search.
enum PanelTopRowLayout {
    /// Between the switch, ••• and Search (6 px).
    static let gap: CGFloat = TasksDesignMetrics.headerGap
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

    /// The page switch's frame for a switch `width` wide: one gap before •••.
    static func switchFrame(_ layout: PanelPageLayout, width: CGFloat) -> CGRect {
        let more = moreButtonFrame(layout)
        return CGRect(x: more.minX - gap - width, y: more.minY, width: width, height: control)
    }

    /// The open field: the whole row, the chrome inset on both sides.
    static func fieldFrame(_ layout: PanelPageLayout) -> CGRect {
        CGRect(x: layout.chromeInsets.leading, y: layout.chromeInsets.top,
               width: max(0, layout.panelSize.width - layout.chromeInsets.leading - layout.chromeInsets.trailing),
               height: control)
    }

    /// The right-hand controls' width: the switch (if any), •••, Search.
    static func trailingWidth(switchWidth: CGFloat) -> CGFloat {
        (switchWidth > 0 ? switchWidth + gap : 0) + control + gap + control
    }

    /// The search's open and close, as on Tasks: the design's ease (240 ms)
    /// in, a quick fade out; Reduce Motion a short ease.
    static func searchAnimation(shown: Bool, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : (shown ? TasksDesignMetrics.curve(0.24) : .easeOut(duration: 0.12))
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
}

private struct PanelTopRowStateKey: EnvironmentKey {
    static let defaultValue: PanelTopRowState? = nil
}

extension EnvironmentValues {
    /// The shell's top row state (nil in the gallery, captures and tests
    /// that host a page alone).
    var panelTopRowState: PanelTopRowState? {
        get { self[PanelTopRowStateKey.self] }
        set { self[PanelTopRowStateKey.self] = newValue }
    }
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
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var pageSwitch: () -> Switch
    @ViewBuilder var search: () -> Search

    @Environment(\.panelTopRowState) private var state

    var body: some View {
        let control = PanelTopRowLayout.control
        let gap = PanelTopRowLayout.gap
        ZStack(alignment: .trailing) {
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
                    HStack(spacing: gap) {
                        pageSwitch()
                        PanelTopRowMoreButton()
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
            }
        }
        .frame(height: control)
        .padding(.top, layout.chromeInsets.top)
        .padding(.leading, layout.chromeInsets.leading)
        .padding(.trailing, layout.chromeInsets.trailing)
        .frame(maxWidth: .infinity, alignment: .top)
        .onChange(of: searchOpen, initial: true) { _, open in state?.setSearching(open, on: page) }
        .onDisappear { state?.setSearching(false, on: page) }
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
         @ViewBuilder pageSwitch: @escaping () -> Switch, @ViewBuilder search: @escaping () -> Search) {
        self.init(page: page, layout: layout, searchOpen: searchOpen, leading: { EmptyView() },
                  pageSwitch: pageSwitch, search: search)
    }
}

extension PanelTopRow where Leading == EmptyView, Switch == EmptyView {
    init(page: PanelPage, layout: PanelPageLayout, searchOpen: Bool = false,
         @ViewBuilder search: @escaping () -> Search) {
        self.init(page: page, layout: layout, searchOpen: searchOpen, leading: { EmptyView() },
                  pageSwitch: { EmptyView() }, search: search)
    }
}

/// The top row's search button: the header's 27 pt control, as the pin,
/// with the magnifier.
struct PanelTopRowSearchButton: View {
    let label: String.LocalizationValue
    let action: () -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        let side = AtticControlSize.headerControl
        AtticRaisedButton(systemName: "magnifyingglass", label: label, size: CGSize(width: side, height: side),
                          emphasisedGlyph: true, flat: design.effectiveControls != .liquidGlass,
                          cornerRadius: AtticRadius.header, action: action)
            .atticDesignCorners()
    }
}

/// ••• on the top row: Settings, in place of the gear (Accepted
/// 2026-10-29/30). It opens the Settings window.
struct PanelTopRowMoreButton: View {
    var action: () -> Void = { AppCoordinator.shared?.openSettings() }

    @Environment(\.atticDesign) private var design

    var body: some View {
        let side = AtticControlSize.headerControl
        AtticRaisedButton(systemName: "ellipsis.circle", label: "Settings", size: CGSize(width: side, height: side),
                          help: String(localized: "Settings (⌘,)"), emphasisedGlyph: true,
                          flat: design.effectiveControls != .liquidGlass, cornerRadius: AtticRadius.header,
                          action: action)
            .atticDesignCorners()
            .accessibilityIdentifier("panel-settings-button")
    }
}
