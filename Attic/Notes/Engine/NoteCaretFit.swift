import AppKit

/// Fits the text caret to the text (F-03, owner 2026-10-10): centred on the
/// line's glyphs and no taller than they are, the font's ascender to its
/// descender.
///
/// TextKit 2 shows the caret as the system's `NSTextInsertionIndicator`,
/// laid over the text view and framed to the line's box. Every Attic line has
/// a fixed height (17.5 for the body, 19.5 for a quote, 21 in a table cell)
/// and TextKit sets the glyphs on the box's floor, so the box is taller than
/// the text and the glyphs sit low in it: the caret stood 2 to 3 pt taller
/// than the letters and about 1 pt higher than their middle. This fitter
/// reframes the indicator to the glyph box (vertically only: the system still
/// owns its x, width, colour, blink and motion) every time the system frames
/// it, so a move, a layout pass or a blink restart never brings the box back.
@MainActor
final class NoteCaretFitter {
    private weak var textView: NSTextView?
    private var watched: [ObjectIdentifier: (indicator: Weak, token: NSObjectProtocol)] = [:]
    private var fitting = false
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

    /// Finds the text view's insertion indicators and fits each one. Cheap
    /// when there is none (the view is not first responder).
    func refresh() {
        // NotificationCenter owns block observers even after their weak
        // indicator dies. Unregister before discarding the token, including
        // the last indicator (when there is no replacement to watch).
        let retired = watched.filter { $0.value.indicator.view == nil }
        for (key, observation) in retired {
            notifications.removeObserver(observation.token)
            watched[key] = nil
        }
        guard let textView, textView.textLayoutManager != nil else { return }
        for indicator in Self.indicators(in: textView) {
            watch(indicator)
            fit(indicator)
        }
    }

    /// The caret's frame for text on `baseline` in `font`, keeping the
    /// system's horizontal placement. The glyph box: ascender above the
    /// baseline, descender below it.
    nonisolated static func fittedFrame(current: CGRect, baseline: CGFloat, font: NSFont) -> CGRect {
        CGRect(x: current.minX, y: baseline - font.ascender, width: current.width, height: font.ascender - font.descender)
    }

    /// The line's baseline in the text view's coordinates, for the line the
    /// caret `frame` (text view coordinates) is on, and that line's box
    /// height; nil when there is no line there.
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

    /// The font the caret is sized to: what the next typed letter takes.
    static func font(of textView: NSTextView) -> NSFont? {
        (textView.typingAttributes[.font] as? NSFont) ?? textView.font
    }

    private func watch(_ indicator: NSView) {
        let key = ObjectIdentifier(indicator)
        guard watched[key] == nil else { return }
        indicator.postsFrameChangedNotifications = true
        let token = notifications.addObserver(forName: NSView.frameDidChangeNotification, object: indicator,
                                                           queue: .main) { [weak self, weak indicator] _ in
            MainActor.assumeIsolated {
                guard let self, let indicator else { return }
                self.fit(indicator)
            }
        }
        watched[key] = (Weak(indicator), token)
    }

    /// Reframes one indicator; true when the frame changed.
    @discardableResult
    func fit(_ indicator: NSView) -> Bool {
        guard !fitting, let textView, textView.selectedRange().length == 0,
              let superview = indicator.superview, let font = Self.font(of: textView) else { return false }
        let current = textView.convert(indicator.frame, from: superview)
        guard let line = Self.line(at: current, in: textView) else { return false }
        // A line of its own (an image, a file, a table) is not text: the
        // system's full-height caret stays.
        let glyphHeight = font.ascender - font.descender
        guard line.boxHeight <= glyphHeight + 8 else { return false }
        let fitted = Self.fittedFrame(current: current, baseline: line.baseline, font: font)
        guard abs(fitted.minY - current.minY) > 0.01 || abs(fitted.height - current.height) > 0.01 else { return false }
        fitting = true
        indicator.frame = superview.convert(fitted, from: textView)
        fitting = false
        return true
    }

    private static func indicators(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        for subview in view.subviews {
            if subview is NSTextInsertionIndicator {
                found.append(subview)
            } else if !String(describing: type(of: subview)).contains("Content") {
                found += indicators(in: subview)
            }
        }
        return found
    }
}
