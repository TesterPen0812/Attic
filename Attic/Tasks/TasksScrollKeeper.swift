import AppKit
import SwiftUI

/// Keeps a Tasks list's scroll position while its page is not built (round
/// 10, Astra's round 9 check: pages off screen are let go, and a list built
/// again started at the top). Placed inside the list's scroll content, it
/// finds its own `NSScrollView`, records where it is scrolled as it moves,
/// and puts it back there when the page is built again. Nothing redraws:
/// the position lives in the model, unpublished.
struct TasksScrollKeeper: NSViewRepresentable {
    let model: TasksPageModel
    let tab: TasksTab
    /// Where the page finds this list's scroll view (a `show`'s reveal).
    var proxies: TasksListProxies?
    var pointer: TasksPointer?
    var focusSelection: (UUID?) -> Void = { _ in }
    /// False while the page is kept built but not drawn (round 11): the
    /// list's scroll view is hidden, so it draws nothing, takes no event
    /// and VoiceOver does not read it (SwiftUI's own hiding did not reach
    /// into a list's scroll view, round 9).
    var drawn = true

    func makeNSView(context: Context) -> KeeperView {
        let view = KeeperView()
        view.model = model
        view.tab = tab
        view.proxies = proxies
        view.pointer = pointer
        view.focusSelection = focusSelection
        view.drawn = drawn
        return view
    }

    func updateNSView(_ view: KeeperView, context: Context) {
        view.model = model
        view.tab = tab
        view.proxies = proxies
        view.pointer = pointer
        view.focusSelection = focusSelection
        view.drawn = drawn
    }

    /// `y` kept within what the list can scroll: from the top inset to the
    /// content's end past the bottom inset.
    @MainActor
    static func clampedOriginY(_ y: CGFloat, in scroll: NSScrollView) -> CGFloat {
        let clip = scroll.contentView
        let insets = clip.contentInsets
        let content = scroll.documentView?.frame.height ?? 0
        let upper = max(-insets.top, content - clip.bounds.height + insets.bottom)
        return min(max(y, -insets.top), upper)
    }

    /// Scrolls `scroll` so the content from `place.top` for `place.height`
    /// sits in the middle of what its insets leave visible (clamped to the
    /// content).
    @MainActor
    static func centre(_ place: (top: CGFloat, height: CGFloat), in scroll: NSScrollView) {
        scroll.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let insets = clip.contentInsets
        let visible = clip.bounds.height - insets.top - insets.bottom
        let content = scroll.documentView?.frame.height ?? 0
        let wanted = place.top + place.height / 2 - insets.top - visible / 2
        let upper = max(-insets.top, content - clip.bounds.height + insets.bottom)
        var origin = clip.bounds.origin
        origin.y = min(max(wanted, -insets.top), upper)
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// Scrolls `scroll` to its top, where the first row rests.
    @MainActor
    static func scrollToTop(_ scroll: NSScrollView) {
        scroll.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.y = -clip.contentInsets.top
        guard abs(origin.y - clip.bounds.origin.y) > 0.5 else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    static func dismantleNSView(_ view: KeeperView, coordinator: ()) {
        view.stopObserving()
    }

    /// Thin overlay scrollers whatever the system's "Show scroll bars"
    /// setting (owner, 2026-10-01): AppKit shows them only while the list
    /// scrolls. `hidden` while a page swipe may be under way.
    /// (A preview's `ATTIC_UI_TEST_SCROLLERS=system` leaves them to the
    /// system, round 13's way: an A/B switch.)
    @MainActor
    static func styleScrollers(of scroll: NSScrollView, hidden: Bool,
                               overrides: AtticPreviewOverrides = .current) {
        guard overrides.stylesScrollers else { return }
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        guard let scroller = scroll.verticalScroller else { return }
        if scroller.controlSize != .small { scroller.controlSize = .small }
        if scroller.isHidden != hidden { scroller.isHidden = hidden }
    }

    final class KeeperView: NSView {
        weak var model: TasksPageModel?
        var tab: TasksTab = .now
        weak var proxies: TasksListProxies?
        weak var pointer: TasksPointer?
        var focusSelection: (UUID?) -> Void = { _ in }
        private var marquee: TasksMarqueeSelection?
        private weak var observedClip: NSClipView?
        private var observer: NSObjectProtocol?
        /// Until the remembered place is back, the list's own first layout
        /// (at the top) is not recorded over it.
        private var restoring = false
        var drawn = true {
            didSet { if drawn != oldValue { applyDrawn() } }
        }

        private func applyDrawn() {
            guard let scroll = enclosingScrollView, scroll.isHidden == drawn else { return }
            scroll.isHidden = !drawn
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                stopObserving()
                return
            }
            guard let scroll = enclosingScrollView else { return }
            applyDrawn()
            proxies?.scrollViews[tab] = scroll
            observe(scroll.contentView)
            if let model, let pointer {
                marquee = TasksMarqueeSelection(scroll: scroll, model: model, pointer: pointer, tab: tab,
                    focusSelection: { [weak self] id in self?.focusSelection(id) })
            }
            // After `observe`, which starts from a clean slate.
            keepOverlayScrollers(scroll)
            restoring = true
            // Once the list has laid out its rows (the next turn).
            DispatchQueue.main.async { [weak self] in self?.restore() }
        }

        private var styleObserver: NSObjectProtocol?

        /// Overlay scrollers now, when the system sets them back (AppKit
        /// restyles every scroll view when the "Show scroll bars" setting
        /// changes), and as the list scrolls (`record`).
        private func keepOverlayScrollers(_ scroll: NSScrollView) {
            TasksScrollKeeper.styleScrollers(of: scroll, hidden: proxies?.scrollersHidden ?? false)
            if styleObserver == nil {
                styleObserver = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    // After AppKit's own restyling, which it may defer.
                    for delay in [0.0, 0.25] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            MainActor.assumeIsolated {
                                guard let self, let scroll = self.enclosingScrollView else { return }
                                TasksScrollKeeper.styleScrollers(of: scroll, hidden: self.proxies?.scrollersHidden ?? false)
                            }
                        }
                    }
                }
            }
        }

        private func observe(_ clip: NSClipView) {
            guard observedClip !== clip else { return }
            stopObserving()
            observedClip = clip
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.record() }
            }
        }

        func stopObserving() {
            marquee = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            observedClip = nil
            if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
            styleObserver = nil
        }

        private func record() {
            if let scroll = enclosingScrollView, scroll.scrollerStyle != .overlay {
                TasksScrollKeeper.styleScrollers(of: scroll, hidden: proxies?.scrollersHidden ?? false)
            }
            guard !restoring, let clip = observedClip, let model else { return }
            model.scrollOffsets[tab] = clip.bounds.origin.y
        }

        private func restore() {
            defer { restoring = false }
            guard let clip = observedClip, let scroll = enclosingScrollView,
                  let saved = model?.scrollOffsets[tab] else { return }
            scroll.layoutSubtreeIfNeeded()
            let maxY = max(-clip.contentInsets.top, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            var origin = clip.bounds.origin
            origin.y = min(max(saved, -clip.contentInsets.top), maxY)
            guard abs(origin.y - clip.bounds.origin.y) > 0.5 else { return }
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}

/// A list's animated reveal (a task just added, a row the keyboard moved
/// to), run by AppKit's clip view on the settle spring.
///
/// The list hang (2026-10-28, first bad `b338bd91`): SwiftUI's animated
/// `ScrollViewProxy.scrollTo` into the lazy list, met by a scroll gesture
/// while it ran, left SwiftUI re-placing the list's rows without end
/// (`LazySubviewPlacements` anchor translation and item phases, the main
/// thread never back to its events) once rows of different heights (tagged
/// two-line rows) were still estimated. The same reveal unanimated, or no
/// reveal, never hung (Terra pass 8: 0/10 each, the head build 8/10). Here
/// the list only ever sees its clip view move, as under a scroll gesture,
/// and a gesture (or anything else moving the list) takes over at once.
@MainActor
final class TasksScrollGlide: NSObject {
    private weak var scroll: NSScrollView?
    private var link: CADisplayLink?
    private var spring = Spring(duration: 0.4, bounce: 0)
    private var from: Double = 0
    private var to: Double = 0
    /// Where the glide last put the clip (after AppKit's own rounding).
    private var placed: CGFloat = 0
    private var began: CFTimeInterval?

    var isRunning: Bool { link != nil }

    /// Moves the list by `delta` points (positive: its content moves up),
    /// clamped to what the list can scroll.
    func run(by delta: CGFloat, in scroll: NSScrollView, spring: Spring) {
        stop()
        scroll.layoutSubtreeIfNeeded()
        let origin = scroll.contentView.bounds.origin.y
        let goal = TasksScrollKeeper.clampedOriginY(origin + delta, in: scroll)
        guard abs(goal - origin) > 0.5 else { return }
        self.scroll = scroll
        self.spring = spring
        from = Double(origin)
        to = Double(goal)
        placed = origin
        began = nil
        let link = scroll.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        scroll = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let time = now - (began ?? link.timestamp)
        if began == nil { began = link.timestamp }
        advance(to: time)
    }

    /// One step of the glide, `time` seconds in (tests drive it directly).
    func advance(to time: TimeInterval) {
        guard let scroll else { return stop() }
        let clip = scroll.contentView
        // Someone else moved the list (a scroll gesture, another reveal):
        // it is theirs from here.
        guard abs(clip.bounds.origin.y - placed) <= 0.5 else { return stop() }
        let done = time >= spring.settlingDuration
        let value = done ? to : spring.value(fromValue: from, toValue: to, initialVelocity: 0, time: time)
        var origin = clip.bounds.origin
        origin.y = TasksScrollKeeper.clampedOriginY(CGFloat(value), in: scroll)
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        placed = clip.bounds.origin.y
        if done { stop() }
    }
}

/// Rows fade out just before the tag chip row (owner, 2026-10-28): while
/// the chips show, the list is masked from the chips' bottom edge up, over
/// a short fade, so chip text never sits on a task. The mask moves with
/// the row as it opens and closes, and exists only while the chips show:
/// with them shut the rows run under the header as before (its 0.5 pt
/// blur), with no mask to composite while scrolling.
@MainActor
enum TasksChipFade {
    /// The fade under the chip row's bottom edge. At rest the first group
    /// header's text starts 11 below that edge, clear of it.
    static let fade: CGFloat = 8
    /// Once the row has closed, the rows under the header come back over
    /// this (they would otherwise cross the leaving search and chips).
    static let reveal: CFTimeInterval = 0.15
    private static let name = "tasks-chip-fade"
    private static let closingKey = "tasksChipFadeClosing"

    /// Shows the fade with its edge at `top` (the chip row's bottom, down
    /// from the scroll view's top), sliding from where it is (or from
    /// `from`, a new mask's start) in the row's motion.
    static func show(_ scroll: NSScrollView, top: CGFloat, from: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        scroll.wantsLayer = true
        guard let layer = scroll.layer else { return }
        let mask: CALayer
        if let existing = layer.mask, existing.name == name {
            mask = existing
        } else {
            mask = CALayer()
            mask.name = name
            let band = CALayer()
            band.addSublayer(CAGradientLayer())
            band.addSublayer(CALayer())
            mask.addSublayer(band)
            let cover = CALayer()
            cover.backgroundColor = NSColor.black.cgColor
            mask.addSublayer(cover)
            // New: the rows above `from` start shown and fade with the
            // row's motion, so nothing under the header goes at once.
            withoutActions {
                mask.frame = layer.bounds
                place(band, in: scroll, top: from)
                cover.frame = coverFrame(in: scroll, top: from)
                cover.opacity = duration > 0 ? 1 : 0
            }
            layer.mask = mask
        }
        guard let band = mask.sublayers?.first, let cover = mask.sublayers?.last else { return }
        withoutActions {
            mask.frame = layer.bounds
            mask.setValue(false, forKey: closingKey)
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timing)
        place(band, in: scroll, top: top)
        cover.opacity = 0
        CATransaction.commit()
    }

    /// Takes the fade away: its edge goes up with the closing row to
    /// `to` (the header's bottom), then the rows above it come back over
    /// `reveal`, and the mask goes. With no duration it goes at once.
    static func hide(_ scroll: NSScrollView, to: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        guard let layer = scroll.layer, let mask = layer.mask, mask.name == name,
              let band = mask.sublayers?.first, let cover = mask.sublayers?.last else { return }
        guard duration > 0 else {
            layer.mask = nil
            return
        }
        withoutActions { mask.setValue(true, forKey: closingKey) }
        func stillClosing() -> Bool { layer.mask === mask && (mask.value(forKey: closingKey) as? Bool) == true }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard stillClosing() else { return }
                // Everything above the band, shown again over `reveal`.
                withoutActions { cover.frame = coverFrame(in: scroll, top: to) }
                CATransaction.begin()
                CATransaction.setAnimationDuration(reveal)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                CATransaction.setCompletionBlock {
                    MainActor.assumeIsolated { if stillClosing() { layer.mask = nil } }
                }
                cover.opacity = 1
                CATransaction.commit()
            }
        }
        place(band, in: scroll, top: to)
        CATransaction.commit()
    }

    /// Whether the fade is on (tests).
    static func isOn(_ scroll: NSScrollView) -> Bool { scroll.layer?.mask?.name == name }

    private static func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// The band (the fade, then opaque far past the bottom) with its top
    /// edge at `top`, in the layer's own coordinates, and whether those run
    /// upwards. Its size never changes, so only its position animates.
    private static func bandFrame(in scroll: NSScrollView, top: CGFloat) -> (frame: CGRect, upwards: Bool) {
        let span: CGFloat = 4_000
        func layerY(_ fromTop: CGFloat) -> CGFloat {
            scroll.convertToLayer(NSPoint(x: 0, y: scroll.isFlipped ? fromTop : scroll.bounds.height - fromTop)).y
        }
        let start = layerY(top)
        let upwards = layerY(top + 1) < start
        return (CGRect(x: 0, y: upwards ? start - span : start, width: scroll.bounds.width, height: span), upwards)
    }

    /// Everything above `top`, the fade's band included.
    private static func coverFrame(in scroll: NSScrollView, top: CGFloat) -> CGRect {
        let (band, upwards) = bandFrame(in: scroll, top: top)
        return upwards ? CGRect(x: 0, y: band.maxY - fade, width: band.width, height: 4_000)
            : CGRect(x: 0, y: band.minY - 4_000 + fade, width: band.width, height: 4_000)
    }

    private static func place(_ band: CALayer, in scroll: NSScrollView, top: CGFloat) {
        let (frame, upwards) = bandFrame(in: scroll, top: top)
        band.frame = frame
        guard let gradient = band.sublayers?.first as? CAGradientLayer, let solid = band.sublayers?.last else { return }
        let clear = NSColor.clear.cgColor, black = NSColor.black.cgColor
        withoutActions {
            // A gradient's colours run from its bounds' origin.
            gradient.colors = upwards ? [black, clear] : [clear, black]
            gradient.frame = CGRect(x: 0, y: upwards ? frame.height - fade : 0, width: frame.width, height: fade)
            solid.backgroundColor = black
            solid.frame = CGRect(x: 0, y: upwards ? 0 : fade, width: frame.width, height: max(0, frame.height - fade))
        }
    }
}
