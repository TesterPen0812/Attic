import SwiftUI

/// The panel's header (Phase 0's qualities, 2026-09-26): a symmetrical
/// top, the pin on the left and the page button on the right, equal 36 pt
/// squares. The page button shows the current page's icon and opens into
/// all three under the pointer or keyboard focus. ⌘1, ⌘2 and ⌘3 select a
/// page and ⇧⌘P pins.
///
/// The corner buttons are the system's interactive Liquid Glass (owner,
/// 2026-10-02, replacing L3's flat surface), both in one shared
/// `GlassEffectContainer` (`AtticControlGroup`). Wherever the controls are
/// not live glass (Reduce Transparency, the Craft style, a Solid panel that
/// is not key) they keep L3's opaque flat surface
/// (`AtticCornerButtonStyle.drawsFlat`).
///
/// Cost: the rows scroll under the header, so the glass samples moving
/// content. The window server does that sampling; the header's own view
/// graph depends only on the pin, the page, the design context and the
/// corner lab, so scrolling and swiping never re-evaluate it (checked by
/// `CornerGlassTests`). The glass at rest is the same material whether it is
/// interactive or not; the press response runs only while it is pressed.
struct PanelHeader: View {
    let isPinned: Bool
    let page: PanelPage
    let onTogglePin: () -> Void
    let onSelectPage: (PanelPage) -> Void
    /// The pointer rests on the page switch: the pages it leads to are
    /// built behind the current one, so the click only shows them.
    var onApproachPageSwitch: () -> Void = {}
    /// ⇧⌘N and ⇧⌘F (round 10).
    var onNewNote: () -> Void = { AppCoordinator.shared?.showNewNote() }
    var onSearch: () -> Void = { AppCoordinator.shared?.showSearch() }

    @Environment(\.atticDesign) private var design
    @ObservedObject private var cornerButtons = AtticCornerButtonsLab.shared

    #if DEBUG
    /// Test seam: how many times the header's body has run
    /// (`CornerGlassTests`: scrolling and swiping must not run it).
    static var bodyEvaluations = 0
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.bodyEvaluations += 1
        #endif
        let flat = cornerButtons.style.drawsFlat(in: design)
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
                    flat: flat,
                    action: onTogglePin
                )
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
                    flat: flat
                )
                .accessibilityIdentifier("panel-section-picker")
            }
        }
        .frame(height: PanelHeaderLayout.height)
    }
}
