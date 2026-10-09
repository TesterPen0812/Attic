import AppKit

/// Document editor scrollers remain overlays regardless of the system setting.
final class NoteDocumentScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}
