import SwiftUI

/// What a page's bottom bar needs to draw the page switch: the current
/// page and the shell's way to change it. The shell puts it in the
/// environment; a page hosted alone (gallery, captures, tests) has none and
/// draws a switch that only shows its own page.
struct PanelPageSwitchContext {
    let page: PanelPage
    let select: (PanelPage) -> Void
    /// The pointer rests on the switch: the shell builds the other pages.
    var approach: () -> Void = {}
}

private struct PanelPageSwitchContextKey: EnvironmentKey {
    static let defaultValue: PanelPageSwitchContext? = nil
}

extension EnvironmentValues {
    var panelPageSwitch: PanelPageSwitchContext? {
        get { self[PanelPageSwitchContextKey.self] }
        set { self[PanelPageSwitchContextKey.self] = newValue }
    }
}

/// The page switch at the bottom bar's left, on every page (Accepted
/// 2026-10-29/30, "Top row and bottom bar"): the header's page button,
/// moved. Shut it shows the current page and a small chevron; it opens on
/// hover and pushes the rest of the bar along, the current page on the
/// flat grey marker. ⌘1–⌘4 live on the shell (`PanelHeader`), so a page
/// whose bar has no switch (an open note) still answers them.
struct PanelPageSwitcher: View {
    /// The page whose bar this is: the switch shows it as current.
    let page: PanelPage

    @Environment(\.panelPageSwitch) private var context
    @Environment(\.atticDesign) private var design

    /// The switch's items without key equivalents: the shell owns ⌘1–⌘4.
    static let items: [AtticPageButton<PanelPage>.Item] = PanelPage.allCases.map { page in
        var item = page.switchItem
        item.keyEquivalent = nil
        return item
    }

    var body: some View {
        AtticPageButton(
            items: Self.items,
            selection: Binding(get: { page }, set: { context?.select($0) }),
            onApproach: { context?.approach() },
            flat: design.effectiveControls != .liquidGlass
        )
        .atticDesignCorners()
        .accessibilityIdentifier("panel-section-picker")
        #if DEBUG
        .onAppear { Self.liveCount += 1 }
        .onDisappear { Self.liveCount -= 1 }
        #endif
    }

    #if DEBUG
    /// Test seam: how many switches are on screen. The shell draws one for
    /// every page, so a page switch keeps it (and its open state).
    static var liveCount = 0
    #endif

    /// Its width shut and open.
    static func width(open: Bool) -> CGFloat {
        AtticPageButton<PanelPage>.width(open: open, count: PanelPage.allCases.count)
    }
}
