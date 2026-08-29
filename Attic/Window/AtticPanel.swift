import AppKit
import SwiftUI

final class AtticPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The window server still treats a transparent borderless panel as a
/// rectangle. Keep AppKit's responder hit test aligned with the visible
/// squircle so transparent corner pixels cannot obstruct the app behind it.
final class AtticPanelHostingView: NSHostingView<AtticPanelView> {
    var panelCornerRadius: CGFloat

    init(rootView: AtticPanelView, panelCornerRadius: CGFloat) {
        self.panelCornerRadius = panelCornerRadius
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: AtticPanelView) {
        fatalError("Use init(rootView:panelCornerRadius:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard Squircle.contains(
            point,
            in: bounds,
            cornerRadius: panelCornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        ) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
