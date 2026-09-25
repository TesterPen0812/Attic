import SwiftUI

/// The panel's header: Pin on the left, the page switch (Tasks · Notes ·
/// Canvas, icons with the current page's label) on the right. Both are
/// raised Liquid Glass controls sharing one glass container. The switch
/// always says which page you are on; ⌘1, ⌘2 and ⌘3 select a page and
/// ⇧⌘P pins.
struct PanelHeader: View {
    let isPinned: Bool
    let page: PanelPage
    let onTogglePin: () -> Void
    let onSelectPage: (PanelPage) -> Void

    var body: some View {
        AtticControlGroup {
            HStack(alignment: .top, spacing: 0) {
                AtticRaisedButton(
                    systemName: isPinned ? "pin.fill" : "pin",
                    label: isPinned ? "Unpin panel" : "Pin panel",
                    help: isPinned ? String(localized: "Unpin (⇧⌘P)") : String(localized: "Pin (⇧⌘P)"),
                    action: onTogglePin
                )
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .accessibilityAddTraits(isPinned ? .isSelected : [])
                .accessibilityIdentifier("panel-pin-button")
                Spacer(minLength: AtticSpacing.betweenControls)
                AtticPageSwitch(
                    items: PanelPage.switchItems,
                    selection: Binding(get: { page }, set: onSelectPage)
                )
                .accessibilityIdentifier("panel-section-picker")
            }
        }
        .frame(height: PanelHeaderLayout.height)
    }
}
