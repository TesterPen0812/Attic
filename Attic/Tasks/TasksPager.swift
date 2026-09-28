import AppKit
import QuartzCore
import SwiftUI

// MARK: - The pager owns its gesture (round 9, owner items 24 and 25)
//
// Rounds 5 to 8 paged with SwiftUI's paging `ScrollView` and a
// `ScrollTargetBehavior`. On a real trackpad that failed twice: the target
// behaviour only moves where a scroll *lands*, while the fingers and the
// momentum still carried the content through all three pages before it
// sprang back, and the tab could only change once the scroll settled.
//
// Now the pager is three pages side by side whose offset the page drives
// itself (`TasksPagerMotion.position`, in pages), and the pager reads the
// scroll events directly (a local monitor in `TasksPage`, before AppKit
// hands them to a list or to the panel):
//
// - A trackpad gesture's axis is decided on its first movement. Vertical:
//   every event of that gesture, and its momentum, goes to the list as
//   before. Horizontal: the pager takes the gesture; no list sees it.
// - The page follows the fingers 1:1 up to the neighbour, with a firm
//   rubber band beyond it (at most a tenth of a page), so the fingers can
//   never carry it to a second page.
// - The tab follows the page live: it changes as the page crosses halfway.
// - Momentum is ignored. On release the page goes to the neighbour if it
//   travelled more than a quarter of a page or was flicked, else back; a
//   critically damped spring starting at the fingers' speed takes it there
//   (`AtticMotionPreset.release`), so it never passes the page.
// - A mouse wheel (or anything without trackpad phases) turns one page per
//   burst of horizontal scrolling, however long the burst.
// - A tab, a key, ⌘1–3, `show`, Search and a reveal go straight to their
//   page; one chosen during a swipe ends the swipe (the rest of that
//   gesture is ignored).
// - Reduced motion (Settings › Animations, or the Mac's Reduce Motion): no
//   page travels. A swipe past a quarter of a page crossfades to the
//   neighbour.

/// The pages that exist in the view: the one shown, plus, only while a
/// swipe or a slide shows them, the pages it passes (round 9, CI run 2).
/// A page off screen is not built at all, so VoiceOver never reads it and
/// never keeps a stale "hidden" on it (hiding a built page did not reach
/// the rows inside its list, and once hidden, a list's rows stayed hidden
/// after it was shown). Observed only by the pages' container: it changes
/// when a gesture or a slide starts and ends, never while it moves.
@MainActor
final class TasksPagerSpan: ObservableObject {
    @Published var pages: ClosedRange<Int> = 0...0
}

/// Where the pager shows its pages: `position` is in pages (0 is Now, 1
/// Later, 2 Done), fractional while a swipe moves. Observed only by the
/// pages' placement (`TasksPagerSlot`), so a swipe redraws their offsets,
/// never their rows.
@MainActor
final class TasksPagerMotion: ObservableObject {
    @Published private(set) var position: CGFloat = 0
    /// Reduced motion's crossfade: the page fading out stays in place over
    /// the new one until `fade` reaches 1.
    @Published private(set) var fadingOut: Int?
    @Published private(set) var fade: CGFloat = 1
    /// What the UI tests read (DEBUG, `ATTIC_UI_TEST_PAGER_TRACE`).
    @Published private(set) var trace = "reach=0.00 lead=-1.00 page=0"

    /// The settle in progress (the pager's own spring, see `show`), stepped
    /// on the display's refresh (round 11: a 120 Hz timer drifted against
    /// the display and juddered).
    private let driver = TasksDisplayClock()
    /// The page's own view, whose display steps the settle.
    var clockView: () -> NSView? = { nil }
    private var generation = 0
    /// The pages drawn (the swipe owns it and gives it here).
    weak var span: TasksPagerSpan?
    var count = 3

    /// Draws the pages from `lower` to `upper` (clamped), if they are not
    /// drawn already.
    private func setSpan(_ lower: Int, _ upper: Int) {
        guard let span else { return }
        let range = max(0, min(lower, upper))...min(max(count - 1, 0), max(lower, upper))
        guard span.pages != range else { return }
        if range.lowerBound < span.pages.lowerBound || range.upperBound > span.pages.upperBound {
            PerformanceSignposts.beginPageBuild(range)
        } else {
            PerformanceSignposts.pagesReleased(range)
        }
        span.pages = range
    }

    /// A swipe from `page` may show either neighbour.
    func draw(around page: Int) {
        guard let span else { return }
        setSpan(min(span.pages.lowerBound, page - 1), max(span.pages.upperBound, page + 1))
    }

    /// Settled on `page`: only it stays drawn, unless something newer
    /// (`ticket`) moves the pages meanwhile.
    private func rest(on page: Int, ticket: Int, now: Bool = false) {
        guard ticket == generation else { return }
        if now {
            setSpan(page, page)
            return
        }
        // A moment later, once the move is surely drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restDelay) { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.setSpan(page, page)
        }
    }

    /// How long after a move ends the pages it passed are let go.
    static let restDelay: TimeInterval = 0.3

    /// The furthest the last gesture took the page from where it started
    /// (pages), and when its tab changed and its page came to rest, for the
    /// trace.
    private var gestureStart: CGFloat = 0
    private(set) var reach: CGFloat = 0
    private var switchedAt: TimeInterval?
    private var settledAt: TimeInterval?

    static let tracing: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["ATTIC_UI_TEST_PAGER_TRACE"] == "1"
        #else
        false
        #endif
    }()

    /// A settle is moving the page.
    var isSettling: Bool { driver.isRunning }

    /// Where the page is heading (its position once a settle ends).
    private(set) var destination: CGFloat = 0

    /// Stops a settle where it is (a new swipe takes the page from there).
    func stop() {
        driver.stop()
        PerformanceSignposts.pagerSettleEnded(frames: 0, late: 0, interrupted: true)
        generation &+= 1
    }

    /// A gesture (a swipe or a wheel burst) starts.
    func beginGesture() {
        gestureStart = position
        reach = 0
        switchedAt = nil
        settledAt = nil
    }

    /// The gesture's tab changed (live, before its page comes to rest).
    func tabSwitched() {
        if switchedAt == nil { switchedAt = ProcessInfo.processInfo.systemUptime }
    }

    /// The page follows the fingers: a plain assignment (see `show`). A
    /// settle still moving stops where it is; the swipe takes the page from
    /// there (`TasksPagerSwipe` starts its travel at the page's place).
    func follow(_ target: CGFloat) {
        if driver.isRunning { stop() }
        generation &+= 1
        reach = max(reach, abs(target - gestureStart))
        position = target
        destination = target
    }

    /// Shows `page`: at once (`animated` false, or no width yet), with a
    /// crossfade (`reduced`), with the release spring (`velocity`, points
    /// per second toward the page), or with the slide.
    func show(_ page: Int, width: CGFloat, velocity: CGFloat = 0, reduced: Bool, animated: Bool = true) {
        let target = CGFloat(page)
        if driver.isRunning, destination == target, animated, !reduced { return }
        if driver.isRunning { PerformanceSignposts.pagerSettleEnded(frames: 0, late: 0, interrupted: true) }
        driver.stop()
        destination = target
        guard target != position || fadingOut != nil else {
            generation &+= 1
            rest(on: page, ticket: generation, now: !animated)
            if animated { settled() }
            return
        }
        generation &+= 1
        let ticket = generation
        // Every page the move passes is drawn until it ends.
        // (A sliver under a tenth of a page, a rubber band's, needs none.)
        setSpan(min(Int((position + 0.15).rounded(.down)), page), max(Int((position - 0.15).rounded(.up)), page))
        // Building a page can reach back here (its lists' changes): a newer
        // call has then taken the move over, and this one leaves it alone.
        guard ticket == generation else { return }
        reach = max(reach, abs(target - gestureStart))
        // Changes without an animation are plain assignments: under a
        // `disablesAnimations` transaction SwiftUI moved what it draws but
        // left the lists' AppKit scroll views where they were, and the next
        // animated move never reached them (CI runs 2 and 3).
        guard animated, width > 0 else {
            position = target
            fadingOut = nil
            fade = 1
            rest(on: page, ticket: ticket, now: true)
            settled()
            return
        }
        if reduced {
            let from = Int(position.rounded())
            position = target
            fadingOut = from != page ? from : nil
            fade = 0
            guard let crossfade = Self.settleOverride.map({ Animation.linear(duration: $0) })
                    ?? AtticMotionPreset.slide.animation(reduceMotion: true) else {
                fadingOut = nil
                fade = 1
                rest(on: page, ticket: ticket)
                settled()
                return
            }
            // The next turn: the old page is drawn over the new one first.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == ticket else { return }
                withAnimation(crossfade, completionCriteria: .removed) { self.fade = 1 } completion: { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    self.fadingOut = nil
                    self.rest(on: page, ticket: ticket)
                    self.settled()
                }
            }
            return
        }
        // The slide: the pager's own critically damped spring, stepped on
        // the display's refresh with plain assignments (SwiftUI's animations
        // moved what it draws but not the lists' AppKit scroll views: the
        // page shown was left where the fingers had it, CI runs 2 and 3).
        // It starts at the fingers' speed, capped so it never passes the
        // page. Its clock starts at the first frame after this change is
        // drawn (round 11): a page built for the move is built before the
        // move begins, so the build never eats the slide's first frames.
        fadingOut = nil
        fade = 1
        let duration = Self.settleOverride ?? AtticMotionPreset.slide.duration
        let spring = TasksPagerSpring(from: position, to: target, speed: width > 0 ? velocity / width : 0,
                                      duration: duration)
        var start: CFTimeInterval?
        var last: CFTimeInterval?
        var frames = 0
        var late = 0
        PerformanceSignposts.pagerSettleBegan()
        driver.start(on: clockView()) { [weak self] now, display, interval in
            guard let self, self.generation == ticket else { return false }
            if start == nil {
                start = now
                PerformanceSignposts.pagerFirstFrame()
            }
            if let last, interval > 0 { late += max(0, Int(((now - last) / interval).rounded()) - 1) }
            last = now
            frames += 1
            if let value = spring.value(at: display - (start ?? now)) {
                self.position = value
                return true
            }
            self.position = target
            PerformanceSignposts.pagerSettleEnded(frames: frames, late: late, interrupted: false)
            self.rest(on: page, ticket: ticket)
            self.settled()
            return false
        }
    }

    private func settled() {
        guard Self.tracing else { return }
        settledAt = ProcessInfo.processInfo.systemUptime
        let lead = switchedAt.flatMap { switched in settledAt.map { $0 - switched } } ?? -1
        trace = String(format: "reach=%.2f lead=%.2f page=%.0f", reach, lead, position)
    }

    /// UI tests may slow the settle to watch it (DEBUG only).
    static let settleOverride: Double? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["ATTIC_UI_TEST_PAGER_SETTLE"].flatMap(Double.init)
        #else
        nil
        #endif
    }()
}

/// A critically damped spring from `from` to `to` (pages) over about
/// `duration`, starting at `speed` pages per second toward `to`, capped
/// below the speed that would carry it past `to`: it never overshoots.
struct TasksPagerSpring: Equatable {
    let from: CGFloat
    let to: CGFloat
    let omega: CGFloat
    let velocity: CGFloat

    init(from: CGFloat, to: CGFloat, speed: CGFloat, duration: Double) {
        self.from = from
        self.to = to
        omega = 2 * .pi / CGFloat(max(duration, 0.01))
        let offset = from - to
        // Toward `to` is against the offset; at most 0.9 ω |offset|, where
        // a critically damped spring would start to pass its target.
        let limit = 0.9 * omega * abs(offset)
        let toward = min(max(speed.isFinite ? speed : 0, 0), limit)
        velocity = offset == 0 ? 0 : (offset > 0 ? -toward : toward)
    }

    /// The position `time` seconds in, or nil once it has come to rest.
    func value(at time: TimeInterval) -> CGFloat? {
        let t = CGFloat(max(time, 0))
        let offset = from - to
        let x = (offset + (velocity + omega * offset) * t) * exp(-omega * t)
        return abs(x) < 0.0005 && t > 0 ? nil : to + x
    }
}

/// Steps an animation on the display's refresh (round 11): a display link
/// from the page's own view, so each step is computed for the frame it is
/// shown in; a 120 Hz timer only where that view is on no screen (tests
/// host the page in windows off screen). It runs only while something
/// moves: `tick` returns false when done, and the link is let go.
@MainActor
final class TasksDisplayClock: NSObject {
    /// One frame: when it began (the last refresh), when it will be shown,
    /// and the refresh interval. Returns false when the motion is done.
    typealias Tick = (_ now: CFTimeInterval, _ display: CFTimeInterval, _ interval: CFTimeInterval) -> Bool

    private var tick: Tick?
    private var link: CADisplayLink?
    private var timer: Timer?
    /// Which start the running tick belongs to (a tick may start another).
    private var runs = 0

    var isRunning: Bool { tick != nil }

    func start(on view: NSView?, _ tick: @escaping Tick) {
        stop()
        runs &+= 1
        self.tick = tick
        if let view, view.window?.screen != nil {
            let link = view.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.timerFired() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        tick = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        run(now: link.timestamp, display: link.targetTimestamp, interval: link.targetTimestamp - link.timestamp)
    }

    private func timerFired() {
        let now = CACurrentMediaTime()
        run(now: now, display: now + 1.0 / 120, interval: 1.0 / 120)
    }

    private func run(now: CFTimeInterval, display: CFTimeInterval, interval: CFTimeInterval) {
        guard let tick else {
            stop()
            return
        }
        let current = runs
        if !tick(now, display, interval), runs == current { stop() }
    }
}

/// The pager's pages: those in the span (and always the one shown), each
/// placed by `TasksPagerSlot`; the rest are not built.
struct TasksPagerPages<Page: View>: View {
    @ObservedObject var span: TasksPagerSpan
    /// What the pages show (round 10): observed here, so a change the lists
    /// react to (a `show`'s scroll request, a new row) rebuilds the pages'
    /// content; SwiftUI did not rebuild it from the page's closure alone,
    /// and a `show` never scrolled its list.
    @ObservedObject var model: TasksPageModel
    @ObservedObject var store: TaskStore
    let motion: TasksPagerMotion
    let count: Int
    let shown: Int
    let size: CGSize
    let page: (Int) -> Page

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Every slot stays (removing one left its neighbour's list
            // drawn where the last swipe had it); only its content comes
            // and goes.
            ForEach(0..<count, id: \.self) { index in
                Group {
                    if index == shown || span.pages.contains(index) {
                        page(index)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: size.width, height: size.height)
                .modifier(TasksPagerSlot(motion: motion, index: index, width: size.width))
                // Only the page shown takes clicks and is read.
                .allowsHitTesting(index == shown)
                .accessibilityHidden(index != shown)
            }
        }
    }
}

/// One page's place: beside the page shown, by `position`; while reduced
/// motion crossfades, the page fading out stays where it was.
struct TasksPagerSlot: ViewModifier {
    @ObservedObject var motion: TasksPagerMotion
    let index: Int
    let width: CGFloat

    func body(content: Content) -> some View {
        let fadingOut = motion.fadingOut == index
        let fadingIn = motion.fadingOut != nil && CGFloat(index) == motion.position
        content
            .offset(x: fadingOut ? 0 : (CGFloat(index) - motion.position) * width)
            .opacity(fadingOut ? 1 - motion.fade : fadingIn ? motion.fade : 1)
    }
}

/// The pager's trace for the UI tests (DEBUG, `ATTIC_UI_TEST_PAGER_TRACE`):
/// how far the last gesture took the page and how long before its page
/// came to rest its tab changed.
struct TasksPagerTrace: View {
    @ObservedObject var motion: TasksPagerMotion

    var body: some View {
        Text(verbatim: motion.trace)
            .font(.system(size: 1))
            .opacity(0.01)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityIdentifier("tasks-pager-trace")
            .accessibilityValue(motion.trace)
    }
}

/// Where the pager takes scroll events: from `top` (the tabs' band ends)
/// to the bottom stack's band (`TasksBottomBand`), across the page.
struct TasksPagerBand: Equatable {
    var top: CGFloat = 0
    var bottomInset: CGFloat = 0

    func contains(_ point: CGPoint, height: CGFloat, stackHeight: CGFloat) -> Bool {
        point.y >= top && point.y <= height - TasksBottomBand.height(stack: stackHeight, bottomInset: bottomInset)
    }
}

/// A person's swipe between the pages: which scroll events are the
/// pager's, and what each does. Pure decisions (tested directly); the
/// model applies them (`TasksPageModel.pagerScrolled`).
@MainActor
final class TasksPagerSwipe {
    /// A scroll event, as the pager reads it.
    struct Sample: Equatable {
        enum Phase: Equatable { case none, mayBegin, began, changed, ended, cancelled }

        var phase: Phase
        /// Part of a trackpad gesture's momentum.
        var momentum = false
        /// `scrollingDeltaX` and `scrollingDeltaY` as AppKit reports them
        /// (the Mac's scroll direction already applied).
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        /// The event's timestamp, in seconds.
        var time: TimeInterval
        /// Points (a trackpad, a Magic Mouse), not lines (a wheel).
        var precise = true
    }

    enum Motion: Equatable {
        case none
        /// The page follows the fingers to `position` (pages).
        case follow(CGFloat)
        /// Released: the page goes to the model's tab, at `velocity`
        /// (points per second toward it; 0 for the plain slide).
        case settle(velocity: CGFloat)
    }

    struct Output: Equatable {
        /// The event is the pager's: no list and not the panel sees it.
        var consumes: Bool
        /// The page the tab must show now (the live tab), if any.
        var page: Int?
        var motion: Motion = .none

        static let pass = Output(consumes: false, page: nil)
        static let consume = Output(consumes: true, page: nil)
    }

    /// What the current trackpad gesture is.
    enum Axis: Equatable {
        /// Begun here, no movement yet.
        case undecided
        /// The pager's swipe.
        case horizontal
        /// A reduced-motion swipe that has already turned its page.
        case turned
        /// Another way chose a page mid-swipe: the rest is ignored.
        case cancelled
        /// The list's scroll.
        case vertical
        /// Not the pager's (begun elsewhere, during a drag, or on another
        /// page of the shell).
        case foreign
    }

    /// A swipe turns the page past a quarter of a page (the brief: ~25 %).
    static let turnFraction: CGFloat = 0.25
    /// Or when released at least this fast (points per second).
    static let flickSpeed: CGFloat = 300
    /// The velocity is read over the last tenth of a second.
    static let velocityWindow: TimeInterval = 0.1
    /// Beyond the neighbour, or before the first page or past the last,
    /// the page gives at most this much (pages), however far the fingers go.
    static let rubberBand: CGFloat = 0.1
    /// A wheel turns one page per burst: events closer together than this
    /// are one burst.
    static let wheelBurstGap: TimeInterval = 0.45
    /// A burst turns the page once it has scrolled this far (points; a
    /// line-based wheel's first notch is enough).
    static let wheelTurnPoints: CGFloat = 12
    static let wheelTurnLines: CGFloat = 0.5

    let count: Int
    let motion = TasksPagerMotion()
    /// The page width (the view keeps it current).
    var width: CGFloat = 0
    /// Reduced motion (the view keeps it current).
    var reduced = false
    /// A row is being dragged: no swipe starts.
    var dragActive = false
    /// Where the pager takes events (the view keeps it current).
    var band = TasksPagerBand()
    /// Called when another way chooses a page during a swipe or a burst
    /// (the page is then brought to the model's tab).
    var onCancel: (() -> Void)?

    private(set) var axis: Axis?
    /// The page the swipe started on.
    private(set) var origin: Int?
    /// How far the fingers have moved, in points toward the next page.
    private(set) var travel: CGFloat = 0
    private var recent: [(time: TimeInterval, delta: CGFloat)] = []
    /// The last swipe was the pager's: its momentum is ignored too.
    private(set) var ownsMomentum = false
    private var wheelTravel: CGFloat = 0
    /// The swipe's frame count (only with frame signposts on).
    private var frameWatch: AtticFrameWatch?
    private var wheelLast: TimeInterval = -.infinity
    private var wheelBurstUntil: TimeInterval = -.infinity
    init(count: Int) {
        self.count = count
        motion.span = span
        motion.count = count
    }

    /// The pages drawn (see `TasksPagerSpan`).
    let span = TasksPagerSpan()

    /// A swipe is moving the page (fingers down).
    var isTracking: Bool { axis == .horizontal || axis == .turned }

    /// A scroll event reached the page. `shown` is the model's page;
    /// `allowed` says whether it is over the pager's lists, on the page the
    /// shell shows (it decides only where a gesture or wheel event starts).
    func handle(_ sample: Sample, shown: Int, allowed: Bool) -> Output {
        if sample.momentum {
            return ownsMomentum ? .consume : .pass
        }
        switch sample.phase {
        case .none:
            return wheel(sample, shown: shown, allowed: allowed)
        case .mayBegin:
            return .pass
        case .began:
            begin(allowed: allowed)
            // AppKit usually begins with a still event, which goes on so the
            // list (and the panel) see a whole gesture. One that already
            // moves decides the axis now: sideways, not even the panel's
            // own swipe-to-hide sees it.
            guard sample.dx != 0 || sample.dy != 0 else { return .pass }
            return changed(sample, shown: shown)
        case .changed:
            if axis == nil { begin(allowed: allowed) }
            return changed(sample, shown: shown)
        case .ended, .cancelled:
            return end(sample)
        }
    }

    /// Another way chose a page (a tab, a key, `show`, Search, a reveal):
    /// the swipe in progress no longer moves the page, and the rest of its
    /// gesture (and momentum) is ignored; a wheel burst starts over.
    func cancel() {
        // Undecided too (round 10, Astra's round 9 check): a gesture that
        // began before the explicit choice and moves only after it never
        // starts paging from the newly chosen tab.
        if axis == .horizontal || axis == .turned || axis == .undecided {
            axis = .cancelled
            ownsMomentum = true
        }
        origin = nil
        travel = 0
        recent = []
        wheelTravel = 0
        frameWatch?.stop()
        frameWatch = nil
        onCancel?()
    }

    /// The Tasks page stopped being the one shown (another shell page, or
    /// the panel hid): whatever gesture, momentum or wheel burst it owned
    /// is dropped and a settle in progress stops, so nothing hidden keeps
    /// taking scroll events or stepping a spring (round 10, Astra's round 9
    /// check). The page is placed back on its tab without travel by the
    /// caller.
    func suspend() {
        axis = nil
        origin = nil
        travel = 0
        recent = []
        ownsMomentum = false
        wheelTravel = 0
        wheelLast = -.infinity
        wheelBurstUntil = -.infinity
        frameWatch?.stop()
        frameWatch = nil
        motion.stop()
    }

    // MARK: Trackpad

    private func begin(allowed: Bool) {
        axis = allowed && !dragActive && width > 0 ? .undecided : .foreign
        origin = nil
        travel = 0
        recent = []
        ownsMomentum = false
    }

    private func changed(_ sample: Sample, shown: Int) -> Output {
        switch axis {
        case .undecided?:
            guard sample.dx != 0 || sample.dy != 0 else { return .pass }
            guard abs(sample.dx) > abs(sample.dy) else {
                axis = .vertical
                return .pass
            }
            axis = .horizontal
            origin = shown
            // A settle still moving: the swipe takes the page from where it
            // is, not from where it was heading.
            travel = width > 0 ? (motion.position - CGFloat(shown)) * width : 0
            motion.stop()
            motion.beginGesture()
            frameWatch?.stop()
            frameWatch = PerformanceSignposts.watchFrames("SwipeFrames")
            motion.draw(around: shown)
            return move(sample)
        case .horizontal?:
            return move(sample)
        case .turned?, .cancelled?:
            return .consume
        case .vertical?, .foreign?, nil:
            return .pass
        }
    }

    private func move(_ sample: Sample) -> Output {
        guard let origin, width > 0 else { return .consume }
        travel -= sample.dx
        recent.append((sample.time, -sample.dx))
        recent.removeAll { sample.time - $0.time > Self.velocityWindow }
        let pages = travel / width
        if reduced {
            // No travel: past a quarter of a page, the page turns (a
            // crossfade) and the rest of the gesture is ignored.
            guard abs(pages) >= Self.turnFraction else { return .consume }
            axis = .turned
            let page = Self.clamped(origin + (pages > 0 ? 1 : -1), count: count)
            guard page != origin else { return .consume }
            return Output(consumes: true, page: page, motion: .settle(velocity: 0))
        }
        return Output(consumes: true, page: Self.livePage(origin: origin, travel: pages, count: count),
                      motion: .follow(Self.position(origin: origin, travel: pages, count: count)))
    }

    private func end(_ sample: Sample) -> Output {
        defer {
            frameWatch?.stop()
            frameWatch = nil
            axis = nil
            origin = nil
            travel = 0
            recent = []
        }
        switch axis {
        case .horizontal?:
            ownsMomentum = true
            guard let origin else { return .pass }
            let velocity = sample.phase == .cancelled ? 0 : velocity(at: sample.time)
            let page = Self.target(origin: origin, travel: travel, velocity: velocity, width: width, count: count)
            let toward = page > origin ? velocity : page < origin ? -velocity : 0
            // The ended event itself goes on, so the list sees its gesture
            // end (it carries no movement).
            return Output(consumes: false, page: page, motion: .settle(velocity: max(0, toward)))
        case .turned?, .cancelled?:
            ownsMomentum = true
            return .pass
        case .undecided?, .vertical?, .foreign?, nil:
            ownsMomentum = false
            return .pass
        }
    }

    /// The fingers' speed at `time`, points per second toward the next
    /// page, over the last tenth of a second (0 once they stopped).
    private func velocity(at time: TimeInterval) -> CGFloat {
        let window = recent.filter { time - $0.time <= Self.velocityWindow }
        guard let first = window.first else { return 0 }
        let span = max(time - first.time, 1 / 120)
        return window.reduce(0) { $0 + $1.delta } / CGFloat(span)
    }

    // MARK: Wheel

    /// A wheel's horizontal scroll (or anything with no trackpad phases):
    /// one page per burst. Vertical wheel scrolling is the list's.
    private func wheel(_ sample: Sample, shown: Int, allowed: Bool) -> Output {
        guard sample.dx != 0, abs(sample.dx) > abs(sample.dy) else { return .pass }
        guard allowed, !dragActive, width > 0 else { return .pass }
        if sample.time < wheelBurstUntil {
            wheelBurstUntil = sample.time + Self.wheelBurstGap
            return .consume
        }
        if sample.time - wheelLast > Self.wheelBurstGap { wheelTravel = 0 }
        wheelLast = sample.time
        wheelTravel -= sample.dx
        guard abs(wheelTravel) >= (sample.precise ? Self.wheelTurnPoints : Self.wheelTurnLines) else { return .consume }
        let page = Self.clamped(shown + (wheelTravel > 0 ? 1 : -1), count: count)
        wheelTravel = 0
        wheelBurstUntil = sample.time + Self.wheelBurstGap
        guard page != shown else { return .consume }
        motion.beginGesture()
        return Output(consumes: true, page: page, motion: .settle(velocity: 0))
    }

    // MARK: Decisions (pure)

    static func clamped(_ page: Int, count: Int) -> Int {
        min(max(page, 0), max(count - 1, 0))
    }

    /// The pages a swipe from `origin` may reach, relative to it: one
    /// either way, within the pages there are.
    static func reach(origin: Int, count: Int) -> ClosedRange<CGFloat> {
        CGFloat(max(-1, -origin))...CGFloat(max(0, min(1, count - 1 - origin)))
    }

    /// Where the page is drawn for `travel` (pages, toward the next): 1:1
    /// within reach, then a firm rubber band that never gives more than
    /// `rubberBand`.
    static func position(origin: Int, travel: CGFloat, count: Int) -> CGFloat {
        let bounds = reach(origin: origin, count: count)
        let relative: CGFloat
        if travel > bounds.upperBound {
            relative = bounds.upperBound + rubber(travel - bounds.upperBound)
        } else if travel < bounds.lowerBound {
            relative = bounds.lowerBound - rubber(bounds.lowerBound - travel)
        } else {
            relative = travel
        }
        return CGFloat(origin) + relative
    }

    /// UIKit's rubber band (x · c / d + 1 in the denominator, c = 0.55),
    /// scaled so it tends to `rubberBand` of a page.
    static func rubber(_ excess: CGFloat) -> CGFloat {
        guard excess > 0 else { return 0 }
        return (1 - 1 / (excess * 0.55 / rubberBand + 1)) * rubberBand
    }

    /// The tab while the fingers move: the page nearest to where the page
    /// is, so it changes as the page crosses halfway.
    static func livePage(origin: Int, travel: CGFloat, count: Int) -> Int {
        let bounds = reach(origin: origin, count: count)
        let relative = min(max(travel, bounds.lowerBound), bounds.upperBound)
        return clamped(origin + Int(relative.rounded()), count: count)
    }

    /// The page a released swipe goes to: the neighbour when it was flicked
    /// that way, or (slower) when it travelled more than a quarter of a
    /// page; a flick back returns it; never more than one page from
    /// `origin`. `travel` in points, `velocity` in points per second, both
    /// toward the next page.
    static func target(origin: Int, travel: CGFloat, velocity: CGFloat, width: CGFloat, count: Int) -> Int {
        guard width > 0 else { return origin }
        var step = 0
        if abs(velocity) >= flickSpeed {
            let direction = velocity > 0 ? 1 : -1
            if travel == 0 || (travel > 0) == (direction > 0) { step = direction }
        } else if abs(travel) >= width * turnFraction {
            step = travel > 0 ? 1 : -1
        }
        return clamped(origin + step, count: count)
    }
}

extension TasksPagerSwipe.Sample {
    /// The pager's reading of a scroll event.
    init(_ event: NSEvent) {
        let phase: Phase
        if event.phase.contains(.began) {
            phase = .began
        } else if event.phase.contains(.ended) {
            phase = .ended
        } else if event.phase.contains(.cancelled) {
            phase = .cancelled
        } else if event.phase.contains(.changed) || event.phase.contains(.stationary) {
            phase = .changed
        } else if event.phase.contains(.mayBegin) {
            phase = .mayBegin
        } else {
            phase = .none
        }
        self.init(phase: phase, momentum: !event.momentumPhase.isEmpty,
                  dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                  time: event.timestamp, precise: event.hasPreciseScrollingDeltas)
    }
}

extension TasksPageModel {
    /// A scroll event reached the Tasks page (`allowed`: over its lists, on
    /// the page the shell shows, no drag). The tab follows the swipe live;
    /// the page follows the fingers, then settles on the model's tab (the
    /// neighbour, or back when an edit that can't be saved held the tab).
    /// Returns whether the pager took the event.
    func pagerScrolled(_ sample: TasksPagerSwipe.Sample, allowed: Bool) -> Bool {
        // Only the page the shell shows reads scroll events at all: a
        // gesture it owned before it was left is not continued behind
        // Notes or Canvas, or while the panel is hidden (round 10).
        guard isPageShown, !isHidden else { return false }
        let swipe = pagerSwipe
        let shown = TasksTab.allCases.firstIndex(of: tab) ?? 0
        let output = swipe.handle(sample, shown: shown, allowed: allowed)
        if let page = output.page, page != shown, TasksTab.allCases.indices.contains(page) {
            select(tab: TasksTab.allCases[page], bySwipe: true)
            if tab == TasksTab.allCases[page] { swipe.motion.tabSwitched() }
        }
        switch output.motion {
        case .none:
            break
        case let .follow(position):
            swipe.motion.follow(position)
        case let .settle(velocity):
            showPagerPage(velocity: velocity)
        }
        return output.consumes
    }

    /// Brings the pager to the model's tab (a tab, a key, `show`, Search,
    /// the end of a swipe). `animated` false: at once (a reveal).
    /// Leaving the Tasks page or hiding the panel: the pager lets go of
    /// its gesture and settle, and rests on the model's tab at once.
    func suspendPager() {
        pagerSwipe.suspend()
        showPagerPage(animated: false)
    }

    func showPagerPage(velocity: CGFloat = 0, animated: Bool = true) {
        let swipe = pagerSwipe
        swipe.motion.show(TasksTab.allCases.firstIndex(of: tab) ?? 0, width: swipe.width, velocity: velocity,
                          reduced: swipe.reduced, animated: animated)
    }
}
