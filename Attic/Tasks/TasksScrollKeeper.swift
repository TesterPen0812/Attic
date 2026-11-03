import AppKit
import Combine
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
    /// The "+" card's room (P4): a list resting at its end follows the card.
    @Environment(\.panelComposerRoom) private var composerRoom

    func makeNSView(context: Context) -> KeeperView {
        let view = KeeperView()
        view.model = model
        view.tab = tab
        view.proxies = proxies
        view.pointer = pointer
        view.focusSelection = focusSelection
        view.drawn = drawn
        view.composerRoom = composerRoom
        return view
    }

    func updateNSView(_ view: KeeperView, context: Context) {
        view.model = model
        view.tab = tab
        view.proxies = proxies
        view.pointer = pointer
        view.focusSelection = focusSelection
        view.drawn = drawn
        view.composerRoom = composerRoom
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
        /// The "+" card taking the bar's row (P4): the list makes room, and
        /// one resting at its end scrolls up with the card so its last rows
        /// are not covered, and back down as it folds.
        weak var composerRoom: PanelComposerRoom? {
            didSet { if composerRoom !== oldValue { observeComposerRoom() } }
        }
        private var roomObserver: AnyCancellable?
        private let roomGlide = TasksScrollGlide()
        /// How far the list scrolled up for the open card.
        private var roomLift: CGFloat = 0

        private func observeComposerRoom() {
            roomObserver = composerRoom?.$isOpen.removeDuplicates().dropFirst()
                .sink { [weak self] open in MainActor.assumeIsolated { self?.composerRoomChanged(open: open) } }
        }

        private func composerRoomChanged(open: Bool) {
            guard drawn, let scroll = enclosingScrollView else { return }
            let atEnd = scroll.contentView.bounds.origin.y >= TasksScrollKeeper.clampedOriginY(.greatestFiniteMagnitude, in: scroll) - 1
            if open {
                roomLift = 0
                guard atEnd else { return }
                // Once the list has its new end room (the same turn's update).
                DispatchQueue.main.async { [weak self] in
                    guard let self, let scroll = self.enclosingScrollView, self.composerRoom?.isOpen == true else { return }
                    scroll.layoutSubtreeIfNeeded()
                    let origin = scroll.contentView.bounds.origin.y
                    let lift = TasksScrollKeeper.clampedOriginY(.greatestFiniteMagnitude, in: scroll) - origin
                    guard lift > 0.5 else { return }
                    self.roomLift = lift
                    self.moveForRoom(by: lift, in: scroll)
                }
            } else {
                let lift = roomLift
                roomLift = 0
                guard atEnd, lift > 0.5 else { return }
                moveForRoom(by: -lift, in: scroll)
            }
        }

        private func moveForRoom(by delta: CGFloat, in scroll: NSScrollView) {
            if AtticMotionPreference.reducesMotion {
                let clip = scroll.contentView
                var origin = clip.bounds.origin
                origin.y = TasksScrollKeeper.clampedOriginY(origin.y + delta, in: scroll)
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
                return
            }
            let spring = AtticMotionPreset.expand.spring(in: .current)
            roomGlide.run(by: delta, in: scroll, spring: Spring(duration: spring.response, bounce: spring.bounce))
        }
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

/// A page's native scroll offset survives releasing its view and relaunching.
/// Like TasksScrollKeeper, restoration happens after layout and never publishes
/// view state from a bounds notification.
private struct PanelResumeDefaultsKey: EnvironmentKey {
    static let defaultValue: UserDefaults? = nil
}

extension EnvironmentValues {
    var panelResumeDefaults: UserDefaults? {
        get { self[PanelResumeDefaultsKey.self] }
        set { self[PanelResumeDefaultsKey.self] = newValue }
    }
}

struct PanelResumeScrollKeeper: NSViewRepresentable {
    let key: String
    var ready = true
    var navigationID = ""
    @Environment(\.panelResumeDefaults) private var defaults

    func makeNSView(context: Context) -> KeeperView {
        KeeperView(defaults: defaults, key: key, ready: ready, navigationID: navigationID)
    }
    func updateNSView(_ view: KeeperView, context: Context) {
        view.update(ready: ready, navigationID: navigationID)
    }

    final class KeeperView: NSView {
        private let defaults: UserDefaults?
        private let key: String
        private var observers: [NSObjectProtocol] = []
        private var wheelMonitor: Any?
        private weak var clip: NSClipView?
        private var restoring = true
        private var ready: Bool
        private var navigationID: String

        init(defaults: UserDefaults?, key: String, ready: Bool = true, navigationID: String = "") {
            self.defaults = defaults
            self.key = "AtticPanel.scroll." + key
            self.ready = ready
            self.navigationID = navigationID
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(ready: Bool, navigationID: String) {
            if self.navigationID != navigationID { restoring = false }
            self.navigationID = navigationID
            self.ready = ready
            if ready && restoring { scheduleRestore() }
        }

        private func scheduleRestore() {
            DispatchQueue.main.async { [weak self] in self?.restore() }
        }

        private func restore() {
            guard restoring, ready, window != nil, let scroll = enclosingScrollView else { return }
            // Content reads have finished and the view has had a layout turn.
            // A shorter final list finishes at its end; no latent jump remains.
            scroll.layoutSubtreeIfNeeded()
            defer { restoring = false }
            guard let y = defaults?.object(forKey: key) as? Double, y.isFinite else { return }
            var origin = scroll.contentView.bounds.origin
            origin.y = TasksScrollKeeper.clampedOriginY(CGFloat(y), in: scroll)
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil, defaults != nil, let scroll = enclosingScrollView else { return }
            clip = scroll.contentView
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.restoring, let y = self.clip?.bounds.origin.y,
                          y.isFinite, abs(y) < 10_000_000 else { return }
                    if self.defaults?.double(forKey: self.key) != Double(y) {
                        self.defaults?.set(Double(y), forKey: self.key)
                    }
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoring = false }
            })
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self, weak scroll] event in
                MainActor.assumeIsolated {
                    if let self, let scroll, event.window === scroll.window,
                       scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) {
                        self.restoring = false
                    }
                    return event
                }
            }
            scheduleRestore()
        }

        private func stopObserving() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        }
    }
}
