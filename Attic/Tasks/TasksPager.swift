import AppKit
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
    @Published private(set) var trace = ""

    /// A settle is (probably) still moving: a new swipe then catches the
    /// page with a short spring instead of jumping from where it is heading.
    private var settlesUntil: TimeInterval = 0
    private var generation = 0

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

    var isSettling: Bool { ProcessInfo.processInfo.systemUptime < settlesUntil }

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

    /// The page follows the fingers: no animation, unless a settle is still
    /// moving (then a short spring catches it where it is).
    func follow(_ target: CGFloat) {
        generation &+= 1
        reach = max(reach, abs(target - gestureStart))
        if isSettling {
            withAnimation(.interactiveSpring(response: 0.12, dampingFraction: 1)) { position = target }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { position = target }
        }
    }

    /// Shows `page`: at once (`animated` false, or no width yet), with a
    /// crossfade (`reduced`), with the release spring (`velocity`, points
    /// per second toward the page), or with the slide.
    func show(_ page: Int, width: CGFloat, velocity: CGFloat = 0, reduced: Bool, animated: Bool = true) {
        let target = CGFloat(page)
        guard target != position || fadingOut != nil else {
            if animated { settled() }
            return
        }
        generation &+= 1
        let ticket = generation
        reach = max(reach, abs(target - gestureStart))
        var instant = Transaction()
        instant.disablesAnimations = true
        guard animated, width > 0 else {
            withTransaction(instant) {
                position = target
                fadingOut = nil
                fade = 1
            }
            settlesUntil = 0
            settled()
            return
        }
        if reduced {
            let from = Int(position.rounded())
            withTransaction(instant) {
                position = target
                fadingOut = from != page ? from : nil
                fade = 0
            }
            guard let crossfade = Self.settleOverride.map({ Animation.linear(duration: $0) })
                    ?? AtticMotionPreset.slide.animation(reduceMotion: true) else {
                withTransaction(instant) {
                    fadingOut = nil
                    fade = 1
                }
                settled()
                return
            }
            // The next turn: the old page is drawn over the new one first.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == ticket else { return }
                withAnimation(crossfade) { self.fade = 1 } completion: { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    withTransaction(instant) { self.fadingOut = nil }
                    self.settled()
                }
            }
            return
        }
        let distance = abs(target - position) * width
        let animation = Self.settleOverride.map { Animation.linear(duration: $0) }
            ?? (velocity > 0
                ? AtticMotionPreset.release(velocity: velocity, distance: distance, reduceMotion: false)
                : AtticMotionPreset.slide.animation(reduceMotion: false))
        settlesUntil = ProcessInfo.processInfo.systemUptime + (Self.settleOverride ?? AtticMotionPreset.slide.duration) + 0.05
        withAnimation(animation) {
            position = target
            if fadingOut != nil {
                fadingOut = nil
                fade = 1
            }
        } completion: { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.settled()
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
    private var wheelLast: TimeInterval = -.infinity
    private var wheelBurstUntil: TimeInterval = -.infinity
    /// The pages built so far: the one shown and its neighbours, kept once
    /// built (their lists keep their place).
    private(set) var built: Set<Int> = []

    init(count: Int) {
        self.count = count
    }

    /// A swipe is moving the page (fingers down).
    var isTracking: Bool { axis == .horizontal || axis == .turned }

    /// Records that `page` and its neighbours are built; returns every
    /// page built so far.
    func build(around page: Int) -> Set<Int> {
        for candidate in (page - 1)...(page + 1) where (0..<count).contains(candidate) {
            built.insert(candidate)
        }
        return built
    }

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
            return .pass
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
        if axis == .horizontal || axis == .turned {
            axis = .cancelled
            ownsMomentum = true
        }
        origin = nil
        travel = 0
        recent = []
        wheelTravel = 0
        onCancel?()
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
            motion.beginGesture()
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
    func showPagerPage(velocity: CGFloat = 0, animated: Bool = true) {
        let swipe = pagerSwipe
        swipe.motion.show(TasksTab.allCases.firstIndex(of: tab) ?? 0, width: swipe.width, velocity: velocity,
                          reduced: swipe.reduced, animated: animated)
    }
}
