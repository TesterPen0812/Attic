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
        view.drawn = drawn
        return view
    }

    func updateNSView(_ view: KeeperView, context: Context) {
        view.model = model
        view.tab = tab
        view.proxies = proxies
        view.drawn = drawn
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
