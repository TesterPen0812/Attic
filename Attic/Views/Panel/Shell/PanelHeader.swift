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
/// according to the effective control material.
///
/// Cost: the rows scroll under the header, so the glass samples moving
/// content. The window server does that sampling; the header's own view
/// graph depends only on the pin, the page and the design context, so scrolling and swiping never re-evaluate it (checked by
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
    /// List Style: New on Tasks (pick 1A): the pin and the page switch sit
    /// on Tasks' one 28 pt line, the switch's Tasks glyph is `checklist`,
    /// and a pinned pin takes an accent tint.
    var oneLine = false

    @Environment(\.atticDesign) private var design

    #if DEBUG
    /// Test seam: how many times the header's body has run
    /// (`CornerGlassTests`: scrolling and swiping must not run it).
    static var bodyEvaluations = 0
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.bodyEvaluations += 1
        #endif
        let flat = design.effectiveControls != .liquidGlass
        AtticControlGroup {
            HStack(alignment: .top, spacing: 0) {
                // O14-05 (owner, 2026-10-14): the outline pin, filled when
                // pinned, and under the pointer a pinned pin shows what a
                // click does (the pin with a slash), cross-faded. No chip:
                // the fill says "on". At the switch's icon size.
                AtticRaisedButton(
                    systemName: "pin",
                    label: isPinned ? "Unpin panel" : "Pin panel",
                    size: oneLine ? CGSize(width: PanelHeaderLayout.oneLineHeight, height: PanelHeaderLayout.oneLineHeight)
                                  : PanelHeaderLayout.pinSize,
                    help: isPinned ? String(localized: "Unpin (⇧⌘P)") : String(localized: "Pin (⇧⌘P)"),
                    isSelected: isPinned,
                    glyphOffsetY: AtticRaisedButtonMetrics.pinGlyphOffsetY,
                    emphasisedGlyph: true,
                    flat: flat,
                    selectedSystemName: AtticRaisedButtonMetrics.pinnedSymbol,
                    selectedHoverSystemName: AtticRaisedButtonMetrics.unpinSymbol,
                    action: onTogglePin
                )
                .modifier(OneLinePin(oneLine: oneLine, isPinned: isPinned))
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
                    items: oneLine ? PanelPage.oneLineSwitchItems : PanelPage.switchItems,
                    selection: Binding(get: { page }, set: onSelectPage),
                    onApproach: onApproachPageSwitch,
                    flat: flat
                )
                .accessibilityIdentifier("panel-section-picker")
                // 28 pt in the one-line header: the switch keeps its own
                // proportions (the glass, the chips), drawn at 28/30.
                .scaleEffect(oneLine ? PanelHeaderLayout.oneLineHeight / PanelHeaderLayout.height : 1, anchor: .topTrailing)
            }
        }
        .frame(height: oneLine ? PanelHeaderLayout.oneLineHeight : PanelHeaderLayout.height, alignment: .top)
    }
}

/// The one-line header's pin (pick 1A): 28 pt, and an accent tint while
/// pinned (FINAL § 2.10).
private struct OneLinePin: ViewModifier {
    let oneLine: Bool
    let isPinned: Bool

    func body(content: Content) -> some View {
        if oneLine {
            content
                .overlay {
                    if isPinned {
                        Circle().fill(TasksNewInk.pinTint).allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }
}
