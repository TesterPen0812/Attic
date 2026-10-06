import AppKit

/// The one coordinate mapper of a note's text (UX plan § 9.1): text view ↔
/// the scroll view's document ↔ window ↔ screen, and the part of the shared
/// clip view a reader can see. The plain Notes page (the text view is the
/// document view) and the composed task-note host (the text view is one of
/// the stacked views in the document) answer through the same code, so caret
/// visibility, the selection bar, Find, object controls, drop lines and
/// accessibility frames agree wherever the text sits.
@MainActor
final class NoteCoordinateMapper {
    private(set) weak var textView: NSTextView?
    private(set) weak var scrollView: NSScrollView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
    }

    private var clip: NSClipView? { scrollView?.contentView }

    // MARK: Conversions

    /// A rectangle in the text view, in the scroll view's document.
    func documentRect(fromText rect: NSRect) -> NSRect {
        guard let textView, let document = scrollView?.documentView else { return rect }
        return document.convert(rect, from: textView)
    }

    /// A rectangle in the scroll view's document, in the text view.
    func textRect(fromDocument rect: NSRect) -> NSRect {
        guard let textView, let document = scrollView?.documentView else { return rect }
        return textView.convert(rect, from: document)
    }

    func windowRect(fromText rect: NSRect) -> NSRect {
        textView?.convert(rect, to: nil) ?? rect
    }

    func screenRect(fromText rect: NSRect) -> NSRect {
        guard let window = textView?.window else { return .zero }
        return window.convertToScreen(windowRect(fromText: rect))
    }

    func textPoint(fromWindow point: NSPoint) -> NSPoint {
        textView?.convert(point, from: nil) ?? point
    }

    func textPoint(fromScreen point: NSPoint) -> NSPoint {
        guard let window = textView?.window else { return point }
        return textPoint(fromWindow: window.convertPoint(fromScreen: point))
    }

    /// A rectangle in the text view, in `view`'s coordinates (an overlay's
    /// parent).
    func rect(fromText rect: NSRect, to view: NSView) -> NSRect {
        guard let textView else { return rect }
        return view.convert(rect, from: textView)
    }

    // MARK: The visible part

    /// The clip view's bounds minus the scroll view's content insets (what
    /// the header and the bottom row do not cover), in text-view
    /// coordinates. It may reach above or below the text view: the head and
    /// the blocks share the clip in a task's note.
    func unobscuredRect(topInsetReduction: CGFloat = 0, bottomInset: CGFloat? = nil) -> NSRect {
        guard let clip, let scrollView, let textView else { return .zero }
        let insets = scrollView.contentInsets
        var visible = clip.bounds
        let top = max(0, insets.top - topInsetReduction)
        let bottom = bottomInset ?? insets.bottom
        visible.origin.y += top
        visible.size.height = max(0, visible.height - top - bottom)
        return textView.convert(visible, from: clip)
    }

    /// The text that is on screen and not under the header or the bottom
    /// row: `unobscuredRect` clipped to the text view.
    func visibleTextRect(topInsetReduction: CGFloat = 0, bottomInset: CGFloat? = nil) -> NSRect {
        guard let textView else { return .zero }
        return unobscuredRect(topInsetReduction: topInsetReduction, bottomInset: bottomInset)
            .intersection(textView.bounds)
    }

    // MARK: Ranges

    /// The rectangle of `range` in text-view coordinates (a caret's line for
    /// an empty range). Lays out only the fragments the range touches.
    func textRect(for range: NSRange) -> NSRect? {
        guard let textView, let layoutManager = textView.textLayoutManager,
              let content = layoutManager.textContentManager else { return nil }
        let length = (textView.string as NSString).length
        let clamped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
        guard let start = content.location(content.documentRange.location, offsetBy: clamped.location),
              let end = content.location(start, offsetBy: clamped.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        var rect: NSRect?
        let type: NSTextLayoutManager.SegmentType = clamped.length == 0 ? .standard : .selection
        layoutManager.enumerateTextSegments(in: textRange, type: type, options: [.rangeNotRequired]) { _, frame, _, _ in
            rect = rect.map { $0.union(frame) } ?? frame
            return true
        }
        guard var found = rect else { return nil }
        if found.height < 1 { found.size.height = max(found.height, NoteTextStyle.titleLineHeight) }
        if found.width < 1 { found.size.width = 1 }
        let origin = textView.textContainerOrigin
        return found.offsetBy(dx: origin.x, dy: origin.y)
    }

    // MARK: Scrolling the shared view

    /// Scrolls the shared clip view by the least amount that brings `rect`
    /// (text-view coordinates) inside the unobscured area, with `margin`
    /// above and below. Returns whether it scrolled.
    @discardableResult
    func reveal(_ rect: NSRect, margin: CGFloat = 0) -> Bool {
        guard let clip, let scrollView, let textView else { return false }
        let visible = unobscuredRect()
        let target = rect.insetBy(dx: 0, dy: -margin)
        var delta: CGFloat = 0
        if target.height > visible.height || target.minY < visible.minY {
            delta = target.minY - visible.minY
        } else if target.maxY > visible.maxY {
            delta = target.maxY - visible.maxY
        }
        guard abs(delta) >= 0.5 else { return false }
        // Text and clip are both flipped (top-down), so a positive delta
        // scrolls down in both.
        let clipDelta = textView.convert(NSSize(width: 0, height: delta), to: clip).height
        var origin = clip.bounds.origin
        origin.y += clipDelta
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard abs(constrained.y - clip.bounds.origin.y) >= 0.5 else { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: constrained.y))
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    /// Keeps the caret (or the end of the selection) in view.
    ///
    /// TextKit 2 places fragments it has not laid out yet by estimate; laying
    /// out the new viewport can move the range a little. So: scroll, lay out
    /// the viewport (only it), measure again, at most three times.
    @discardableResult
    func revealRange(_ range: NSRange, margin: CGFloat = 0) -> Bool {
        var scrolled = false
        for _ in 0..<3 {
            guard let rect = textRect(for: range), reveal(rect, margin: margin) else { break }
            scrolled = true
            textView?.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        return scrolled
    }
}
