import SwiftUI

/// The panel's header (Phase 0's qualities, 2026-09-26): a symmetrical
/// top, the pin on the left and the page button on the right, equal 36 pt
/// squares. The page button shows the current page's icon and opens into
/// all three under the pointer or keyboard focus. Both are raised Liquid
/// Glass controls sharing one glass container (the drawn material while
/// the panel is not key); ⌘1, ⌘2 and ⌘3 select a page and ⇧⌘P pins.
struct PanelHeader: View {
    let isPinned: Bool
    let page: PanelPage
    let onTogglePin: () -> Void
    let onSelectPage: (PanelPage) -> Void
    /// The pointer rests on the page switch: the pages it leads to are
    /// built behind the current one, so the click only shows them.
    var onApproachPageSwitch: () -> Void = {}

    var body: some View {
        AtticControlGroup {
            HStack(alignment: .top, spacing: 0) {
                // An outline pin in both states, at the switch's icon size;
                // pinned shows as the button's selected chip (v9).
                AtticRaisedButton(
                    systemName: "pin",
                    label: isPinned ? "Unpin panel" : "Pin panel",
                    help: isPinned ? String(localized: "Unpin (⇧⌘P)") : String(localized: "Pin (⇧⌘P)"),
                    isSelected: isPinned,
                    glyphOffsetY: AtticRaisedButtonMetrics.pinGlyphOffsetY,
                    emphasisedGlyph: true,
                    action: onTogglePin
                )
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .accessibilityIdentifier("panel-pin-button")
                Spacer(minLength: AtticSpacing.betweenControls)
                AtticPageButton(
                    items: PanelPage.switchItems,
                    selection: Binding(get: { page }, set: onSelectPage),
                    onApproach: onApproachPageSwitch
                )
                .accessibilityIdentifier("panel-section-picker")
            }
        }
        .frame(height: PanelHeaderLayout.height)
    }
}
