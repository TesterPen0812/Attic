import AppKit

/// The text caret is AppKit's own (O18-03, owner 2026-10-17: "native, like
/// TextEdit"). TextKit 2 shows it as the system's `NSTextInsertionIndicator`,
/// framed by AppKit to the line's box; Attic never sets that frame. The
/// natural caret height comes from the line geometry itself
/// (`NoteTextStyle.setLines`): each line is the font's own box, with the
/// rest of the pitch as line spacing above it, which the caret never spans.
/// This supersedes the fitted caret of F-03 / O14-10 (2026-10-10, 10-14).
///
/// What remains here is visibility only: while blocks are marquee-selected
/// the caret hides (suppressing the legacy insertion-point drawing alone does
/// not hide the modern indicator subview), and it comes back in its own mode
/// when the marquee clears.
@MainActor
final class NoteCaretVisibility {
    private weak var textView: NSTextView?
    private var watched: [ObjectIdentifier: (indicator: Weak, token: NSObjectProtocol)] = [:]
    private var suppressed: [ObjectIdentifier: NSTextInsertionIndicator.DisplayMode] = [:]
    private let notifications: NotificationCenter

    private final class Weak {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    init(textView: NSTextView, notifications: NotificationCenter = .default) {
        self.textView = textView
        self.notifications = notifications
    }

    isolated deinit {
        watched.values.forEach { notifications.removeObserver($0.token) }
    }

    /// Finds the text view's insertion indicators and applies the marquee's
    /// visibility to each. Cheap when there is none.
    func refresh() {
        // NotificationCenter owns block observers even after their weak
        // indicator dies. Unregister before discarding the token.
        let retired = watched.filter { $0.value.indicator.view == nil }
        for (key, observation) in retired {
            notifications.removeObserver(observation.token)
            watched[key] = nil
            suppressed[key] = nil
        }
        guard let textView, textView.textLayoutManager != nil else { return }
        for indicator in Self.indicators(in: textView) {
            watch(indicator)
            apply(to: indicator)
        }
    }

    private var hidesCaret: Bool { (textView as? NoteEditorTextView)?.marquee?.isEmpty == false }

    private func watch(_ indicator: NSTextInsertionIndicator) {
        let key = ObjectIdentifier(indicator)
        guard watched[key] == nil else { return }
        // AppKit re-frames (and may re-show) the indicator as the caret
        // moves; the marquee's hiding is re-applied then. The frame itself
        // is never touched.
        indicator.postsFrameChangedNotifications = true
        let token = notifications.addObserver(forName: NSView.frameDidChangeNotification, object: indicator,
                                              queue: .main) { [weak self, weak indicator] _ in
            MainActor.assumeIsolated {
                guard let self, let indicator else { return }
                self.apply(to: indicator)
            }
        }
        watched[key] = (Weak(indicator), token)
    }

    /// Hides or restores one indicator; never changes its geometry.
    func apply(to indicator: NSTextInsertionIndicator) {
        let key = ObjectIdentifier(indicator)
        if hidesCaret {
            if suppressed[key] == nil {
                // AppKit can report a private blink state (100), even
                // immediately after setting .automatic in an unshown
                // window. Restore the public mode, not that transient
                // implementation value.
                switch indicator.displayMode {
                case .hidden: suppressed[key] = .hidden
                case .visible: suppressed[key] = .visible
                default: suppressed[key] = .automatic
                }
            }
            if indicator.displayMode != .hidden { indicator.displayMode = .hidden }
        } else if let mode = suppressed.removeValue(forKey: key) {
            indicator.displayMode = mode
        }
    }

    static func indicators(in view: NSView) -> [NSTextInsertionIndicator] {
        var found: [NSTextInsertionIndicator] = []
        for subview in view.subviews {
            if let indicator = subview as? NSTextInsertionIndicator {
                found.append(indicator)
            } else if !String(describing: type(of: subview)).contains("Content") {
                found += indicators(in: subview)
            }
        }
        return found
    }
}

/// Where TextKit put a line: read from the real layout, never estimated.
enum NoteLineGeometry {
    /// The device pixel row TextKit draws a line's glyphs on for `baseline`
    /// (view coordinates): the baseline itself on a pixel boundary, else
    /// the pixel boundary below it.
    @MainActor
    static func drawnBaseline(_ baseline: CGFloat, in view: NSView) -> CGFloat {
        guard view.window != nil else { return baseline }
        let backing = view.convertToBacking(NSPoint(x: 0, y: baseline))
        let below = view.convertToBacking(NSPoint(x: 0, y: baseline + 1))
        let lower = below.y > backing.y ? (backing.y - 0.001).rounded(.up) : (backing.y + 0.001).rounded(.down)
        return view.convertFromBacking(NSPoint(x: backing.x, y: lower)).y
    }

    /// The baseline (text view coordinates) of the line nearest `frame`'s
    /// middle (text view coordinates), and that line's box height; nil when
    /// there is no line there.
    @MainActor
    static func line(at frame: CGRect, in textView: NSTextView) -> (baseline: CGFloat, boxHeight: CGFloat)? {
        guard let layout = textView.textLayoutManager else { return nil }
        let origin = textView.textContainerOrigin
        let y = frame.midY - origin.y
        guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return nil }
        let top = fragment.layoutFragmentFrame.minY
        var best: (line: NSTextLineFragment, distance: CGFloat)?
        for line in fragment.textLineFragments {
            let box = line.typographicBounds
            let distance = y < top + box.minY ? top + box.minY - y : (y > top + box.maxY ? y - (top + box.maxY) : 0)
            if best == nil || distance < best!.distance { best = (line, distance) }
        }
        guard let line = best?.line else { return nil }
        return (top + line.typographicBounds.minY + line.glyphOrigin.y + origin.y, line.typographicBounds.height)
    }
}
