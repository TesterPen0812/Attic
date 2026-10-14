import AppKit

/// Fits the text caret to the text (F-03, owner 2026-10-10; O14-10,
/// 2026-10-14): centred on the line's letters and as tall as they are,
/// capitals to descenders (`caretReach`).
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
    private var suppressed: [ObjectIdentifier: NSTextInsertionIndicator.DisplayMode] = [:]
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
            suppressed[key] = nil
        }
        guard let textView, textView.textLayoutManager != nil else { return }
        for indicator in Self.indicators(in: textView) {
            watch(indicator)
            fit(indicator)
        }
    }

    /// The caret's frame for text on `baseline` in `font`, keeping the
    /// system's horizontal placement.
    nonisolated static func fittedFrame(current: CGRect, baseline: CGFloat, font: NSFont) -> CGRect {
        let reach = caretReach(font)
        return CGRect(x: current.minX, y: baseline - reach.above, width: current.width, height: reach.above + reach.below)
    }

    /// How far the caret reaches above and below the baseline (O14-10,
    /// owner 2026-10-14: centred on the text and sized to it).
    ///
    /// The platform's insertion point spans the line fragment's typographic
    /// bounds without its paragraph spacing or extra line height: the
    /// font's ascender to its descender (`NSTextInsertionIndicator` is
    /// framed to that box). On SF the ascender keeps accent room well over
    /// the capitals, so that caret stood 3.4 pt over a capital and only a
    /// hair under a "y" at 13 pt: high on the letters, as the owner saw it,
    /// and too tall beside "mmn" (F-03c). Attic keeps the platform's
    /// measure (the font's own metrics, nothing from the paragraph) and
    /// centres it on the letters themselves: from the cap height to the
    /// descenders' drawn depth, with the same hairline at each end (the
    /// room the platform's descender leaves under a "p", 3.5 % of the
    /// size).
    nonisolated static func caretReach(_ font: NSFont) -> (above: CGFloat, below: CGFloat) {
        let margin = font.pointSize * caretMargin
        return (font.capHeight + margin, inkDescent(font) + margin)
    }

    /// The hairline past the capitals and the descenders, as a share of the
    /// font's size.
    nonisolated static let caretMargin: CGFloat = 0.035

    /// How far the font's descenders reach under the baseline: the deeper
    /// of "p" and "y" as drawn (most of the descender when a font has none).
    nonisolated static func inkDescent(_ font: NSFont) -> CGFloat {
        let ctFont = font as CTFont
        var characters: [UniChar] = Array("py".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, characters.count), !glyphs.contains(0) else {
            return -font.descender * 0.85
        }
        var bounds = [CGRect](repeating: .zero, count: glyphs.count)
        CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, glyphs, &bounds, glyphs.count)
        return max(0, -(bounds.map(\.minY).min() ?? 0))
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

    /// Where the letters' baseline is drawn: text is set on whole device
    /// pixels, a line between two of them on the lower one (measured on
    /// screen, O14-10: a heading whose line ends 0.12 pt past a pixel has
    /// its letters drawn 0.38 pt lower, and the caret stood 0.7 px high on
    /// them at 2x). The caret is centred on the letters as drawn.
    static func drawnBaseline(_ baseline: CGFloat, in view: NSView) -> CGFloat {
        guard view.window != nil else { return baseline }
        let backing = view.convertToBacking(NSPoint(x: 0, y: baseline))
        let below = view.convertToBacking(NSPoint(x: 0, y: baseline + 1))
        let lower = below.y > backing.y ? (backing.y - 0.001).rounded(.up) : (backing.y + 0.001).rounded(.down)
        return view.convertFromBacking(NSPoint(x: backing.x, y: lower)).y
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
        if let indicator = indicator as? NSTextInsertionIndicator {
            let key = ObjectIdentifier(indicator)
            if (textView as? NoteEditorTextView)?.marquee?.isEmpty == false {
                // TextKit 2's modern caret is a subview: suppressing the
                // legacy insertion-point drawing alone does not hide it.
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
        guard !fitting, let textView, textView.selectedRange().length == 0,
              let superview = indicator.superview, let font = Self.font(of: textView) else { return false }
        let current = textView.convert(indicator.frame, from: superview)
        guard let line = Self.line(at: current, in: textView) else { return false }
        // A line of its own (an image, a file) is not text: the system's
        // full-height caret stays. After a table it is a body-height caret
        // centred on the last row (D-24: the full-height one read as a tall
        // bright bar on the table's edge).
        let glyphHeight = font.ascender - font.descender
        let fitted: CGRect
        if line.boxHeight <= glyphHeight + 8 {
            fitted = Self.fittedFrame(current: current, baseline: Self.drawnBaseline(line.baseline, in: textView), font: font)
        } else if let table = Self.table(before: textView.selectedRange().location, in: textView) {
            fitted = Self.caretAfterTable(current: current, lastRow: table.lastRowHeight, font: font)
        } else {
            return false
        }
        guard abs(fitted.minY - current.minY) > 0.01 || abs(fitted.height - current.height) > 0.01 else { return false }
        fitting = true
        indicator.frame = superview.convert(fitted, from: textView)
        fitting = false
        return true
    }

    /// The caret after a table: the glyph box's height, centred on the
    /// table's last row (the line box's bottom `lastRow`).
    nonisolated static func caretAfterTable(current: CGRect, lastRow: CGFloat?, font: NSFont) -> CGRect {
        let reach = caretReach(font)
        let height = reach.above + reach.below
        let row = min(current.height, max(height, lastRow ?? height))
        return CGRect(x: current.minX, y: current.maxY - row / 2 - height / 2, width: current.width, height: height)
    }

    private static func table(before location: Int, in textView: NSTextView) -> NoteTableAttachment? {
        guard let storage = textView.textStorage, location > 0, location <= storage.length else { return nil }
        return storage.attribute(.attachment, at: location - 1, effectiveRange: nil) as? NoteTableAttachment
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
