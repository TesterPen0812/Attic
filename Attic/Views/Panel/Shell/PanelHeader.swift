import SwiftUI

/// The panel's header: the pin on the top row's left and the shared ••• and
/// Search on its right (Accepted 2026-10-29/30 and 2026-10-31,
/// "Top row and bottom bar"; the page switch moved to the pages' bottom
/// bars, `PanelPageSwitch`). ⌘1–⌘4 select a page and ⇧⌘P pins.
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
                // The owner's panel design (2026-10-27): the filled pin,
                // leaning 30° until pinned, upright once pinned; round.
                // Top row (Accepted 2026-10-29/30): Pin alone on the left;
                // it folds away while the page's search is open.
                PanelPinFold(page: page) {
                    AtticRaisedButton(
                        systemName: "pin.fill",
                        label: isPinned ? "Unpin panel" : "Pin panel",
                        help: isPinned ? String(localized: "Unpin (⇧⌘P)") : String(localized: "Pin (⇧⌘P)"),
                        isSelected: isPinned,
                        glyphOffsetY: AtticRaisedButtonMetrics.pinGlyphOffsetY,
                        emphasisedGlyph: true,
                        flat: flat,
                        selectedSystemName: "pin.fill",
                        cornerRadius: AtticRadius.header,
                        glyphRotation: isPinned ? 0 : 30,
                        action: onTogglePin
                    )
                    .atticMaterialProbe("panel-pin")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .accessibilityIdentifier("panel-pin-button")
                // The menu bar menu's New note and Search Done Tasks keys,
                // and ⌘1–⌘4 (the page switch is the Tall island, outside the
                // panel, Accepted 2026-10-31), answered
                // wherever the panel has the keyboard (round 10).
                .background {
                    Group {
                        Button("New note", action: onNewNote).keyboardShortcut(MenuBarCommands.newNoteShortcut)
                        Button("Search Done Tasks", action: onSearch).keyboardShortcut(MenuBarCommands.searchShortcut)
                        ForEach(PanelPage.allCases) { target in
                            Button(target.title) { onSelectPage(target) }
                                .keyboardShortcut(target.keyEquivalent, modifiers: .command)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                // ••• and Search, drawn once for every page (owner,
                // 2026-10-31): a page switch never moves or fades them.
                PanelSharedTopControls(page: page)
            }
        }
        // The owner's panel design: the pin in the design's superellipse(1.4)
        // corner, a whole superellipse.
        .atticDesignCorners()
        .frame(height: PanelHeaderLayout.height)
    }
}

/// The pin, folded away while the current page's search is open (the
/// field takes the whole row). Only this wrapper watches the search, so the
/// header itself never re-evaluates when it opens.
private struct PanelPinFold<Content: View>: View {
    let page: PanelPage
    @ViewBuilder var content: () -> Content

    @Environment(\.panelTopRowState) private var state

    var body: some View {
        if let state {
            PanelPinFoldObserver(state: state, page: page, content: content)
        } else {
            content()
        }
    }
}

private struct PanelPinFoldObserver<Content: View>: View {
    @ObservedObject var state: PanelTopRowState
    let page: PanelPage
    @ViewBuilder var content: () -> Content

    @Environment(\.atticDesign) private var design
    /// The pin sits in the header's glass group, which ignores an opacity
    /// set on its members from outside, so its glass folds with the switch
    /// and ••• through `atticControlAway` (faded in the search's motion)
    /// and then `atticControlGone` (no glass left once the fade is over).
    @State private var away = false
    @State private var gone = false

    var body: some View {
        let searching = state.isSearching(page)
        content()
            .environment(\.atticControlAway, away)
            .environment(\.atticControlGone, gone)
            // The drawn controls (not glass) fade by opacity.
            .opacity(searching ? 0 : 1)
            .allowsHitTesting(!searching)
            .accessibilityHidden(searching)
            .animation(animation(searching), value: searching)
            .onChange(of: searching, initial: true) { _, now in fold(now) }
    }

    private func animation(_ searching: Bool) -> Animation {
        PanelTopRowLayout.searchAnimation(shown: searching, reduceMotion: design.reduceMotion)
    }

    private func fold(_ searching: Bool) {
        guard searching != away else { return }
        if searching {
            withAnimation(animation(true)) { away = true } completion: {
                if state.isSearching(page) { gone = true }
            }
        } else {
            // Glass first (without animation), then it fades back in.
            gone = false
            withAnimation(animation(false)) { away = false }
        }
    }
}

