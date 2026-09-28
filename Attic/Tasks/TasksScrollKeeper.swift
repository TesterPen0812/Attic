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

    func makeNSView(context: Context) -> KeeperView {
        let view = KeeperView()
        view.model = model
        view.tab = tab
        view.proxies = proxies
        return view
    }

    func updateNSView(_ view: KeeperView, context: Context) {
        view.model = model
        view.tab = tab
        view.proxies = proxies
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

    final class KeeperView: NSView {
        weak var model: TasksPageModel?
        var tab: TasksTab = .now
        weak var proxies: TasksListProxies?
        private weak var observedClip: NSClipView?
        private var observer: NSObjectProtocol?
        /// Until the remembered place is back, the list's own first layout
        /// (at the top) is not recorded over it.
        private var restoring = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                stopObserving()
                return
            }
            guard let scroll = enclosingScrollView else { return }
            proxies?.scrollViews[tab] = scroll
            observe(scroll.contentView)
            restoring = true
            // Once the list has laid out its rows (the next turn).
            DispatchQueue.main.async { [weak self] in self?.restore() }
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
        }

        private func record() {
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
