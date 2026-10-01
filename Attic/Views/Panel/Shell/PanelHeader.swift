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
    /// ⇧⌘N and ⇧⌘F (round 10).
    var onNewNote: () -> Void = { AppCoordinator.shared.showNewNote() }
    var onSearch: () -> Void = { AppCoordinator.shared.showSearch() }

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
                    // L3: one flat fill and one hairline.
                    flat: true,
                    action: onTogglePin
                )
                // B (owner, 2026-10-01): content passing under the header's
                // buttons is softened behind them only.
                .atticControlBackdrop(cornerRadius: PanelHeaderLayout.controlCorner)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .accessibilityIdentifier("panel-pin-button")
                // The menu bar menu's New note and Search Done Tasks keys,
                // answered wherever the panel has the keyboard (round 10).
                .background {
                    Group {
                        Button("New note", action: onNewNote).keyboardShortcut(MenuBarCommands.newNoteShortcut)
                        Button("Search Done Tasks", action: onSearch).keyboardShortcut(MenuBarCommands.searchShortcut)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                Spacer(minLength: AtticSpacing.betweenControls)
                AtticPageButton(
                    items: PanelPage.switchItems,
                    selection: Binding(get: { page }, set: onSelectPage),
                    onApproach: onApproachPageSwitch,
                    flat: true
                )
                .atticControlBackdrop(cornerRadius: PanelHeaderLayout.controlCorner)
                .accessibilityIdentifier("panel-section-picker")
            }
        }
        .frame(height: PanelHeaderLayout.height)
    }
}
