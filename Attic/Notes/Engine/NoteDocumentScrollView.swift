import AppKit

/// Document editor scrollers remain overlays regardless of the system setting.
final class NoteDocumentScrollView: NSScrollView {
    /// O14-01: one click on a panel that is not key both makes it key and
    /// acts here (`AtticPanel.acceptsEveryFirstMouse`).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        AtticPanel.acceptsEveryFirstMouse(in: window) || super.acceptsFirstMouse(for: event)
    }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}
