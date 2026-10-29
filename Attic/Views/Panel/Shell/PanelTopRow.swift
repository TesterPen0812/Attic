import SwiftUI

/// The panel's top row between the shell's pin and page switch (the owner's
/// panel design, 2026-10-27/28): a page's own controls in the middle slot
/// after the pin, then the search on the right, beside the page switch.
/// Tasks, Notes and Calendar share these places, so a page switch never
/// moves the search.
///
/// The shell draws the pin and the switch (`PanelHeader`); each page draws
/// this row over its own content, so the row travels with its page.
enum PanelTopRowLayout {
    /// The row's start: the pin's width and the design's 10 px gap after it.
    static func leading(_ layout: PanelPageLayout) -> CGFloat {
        layout.chromeInsets.leading + AtticControlSize.headerControl + TasksDesignMetrics.searchFromPin
    }

    /// The row's end: the shut page switch and the gap before it.
    static func trailing(_ layout: PanelPageLayout) -> CGFloat {
        layout.chromeInsets.trailing + AtticPageButton<PanelPage>.width(open: false, count: PanelPage.allCases.count)
            + TasksDesignMetrics.headerGap
    }

    /// The search button's frame, from the panel's top-left corner.
    static func searchButtonFrame(_ layout: PanelPageLayout) -> CGRect {
        let side = AtticControlSize.headerControl
        return CGRect(x: layout.panelSize.width - trailing(layout) - side, y: layout.chromeInsets.top,
                      width: side, height: side)
    }

    /// The middle slot's room, from the panel's left edge: from the row's
    /// start to the design's gap before the search button.
    static func middleSlot(_ layout: PanelPageLayout) -> ClosedRange<CGFloat> {
        let start = leading(layout)
        return start...max(start, searchButtonFrame(layout).minX - TasksDesignMetrics.searchFromPin)
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

/// The top row. `middle` is the page's own slot (Calendar's month controls;
/// empty on Tasks and Notes); `search` is the search button, or the open
/// field, which takes the whole row while the middle fades out.
struct PanelTopRow<Middle: View, Search: View>: View {
    let layout: PanelPageLayout
    /// The search field is open: the middle slot gives it the row.
    var searchOpen = false
    @ViewBuilder var middle: () -> Middle
    @ViewBuilder var search: () -> Search

    var body: some View {
        ZStack(alignment: .trailing) {
            middle()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, AtticControlSize.headerControl + TasksDesignMetrics.searchFromPin)
                .opacity(searchOpen ? 0 : 1)
                .allowsHitTesting(!searchOpen)
                .accessibilityHidden(searchOpen)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                search()
            }
        }
        .frame(height: AtticControlSize.headerControl)
        .padding(.top, layout.chromeInsets.top)
        .padding(.leading, PanelTopRowLayout.leading(layout))
        .padding(.trailing, PanelTopRowLayout.trailing(layout))
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension PanelTopRow where Middle == EmptyView {
    init(layout: PanelPageLayout, searchOpen: Bool = false, @ViewBuilder search: @escaping () -> Search) {
        self.init(layout: layout, searchOpen: searchOpen, middle: { EmptyView() }, search: search)
    }
}

/// The top row's search button: the header's 27 pt squircle, as the pin and
/// the switch, with the magnifier.
struct PanelTopRowSearchButton: View {
    let label: String.LocalizationValue
    let action: () -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        let side = AtticControlSize.headerControl
        AtticRaisedButton(systemName: "magnifyingglass", label: label, size: CGSize(width: side, height: side),
                          emphasisedGlyph: true, flat: design.effectiveControls != .liquidGlass,
                          cornerRadius: AtticRadius.header, action: action)
    }
}
