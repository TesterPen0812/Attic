import AppKit
import QuartzCore
import os

/// One Instruments stream: subsystem `com.taha.Attic`, category `Performance`.
/// All intervals are omitted when signposting is disabled. The UI intervals
/// mark AppKit/SwiftUI readiness boundaries, not display scan-out latency.
@MainActor
enum PerformanceSignposts {
    private static let signposter = OSSignposter(subsystem: "com.taha.Attic", category: "Performance")
    private static let captureRoot = PerformanceProbe.validatedRoot(
        environment: ProcessInfo.processInfo.environment
    )
    private static var launch: OSSignpostIntervalState?
    private static var reveal: OSSignpostIntervalState?
    private static var pageSwitch: OSSignpostIntervalState?
    private static var noteKey: OSSignpostIntervalState?
    /// Phase 2 editor: keystroke to the TextKit 2 viewport layout that
    /// shows it (the TextKit 2 counterpart of the Phase 0 draw callback).
    private static var noteLayout: OSSignpostIntervalState?
    private static var canvasDrag: OSSignpostIntervalState?
    private static var launchStart: UInt64?
    private static var revealStart: UInt64?
    private static var pageStart: UInt64?
    private static var noteStart: UInt64?
    private static var canvasStart: UInt64?
    static var hasPendingPageSwitch: Bool { pageSwitch != nil || pageStart != nil }
    /// The probe's optional extra phases (`--extra`) label the timings they
    /// cause ("warm.PanelRevealToOrderedFront"), so the standard names keep
    /// meaning exactly what Baselines A and B measured.
    static var timingLabel: String?

    private static func started() -> UInt64? {
        captureRoot == nil ? nil : DispatchTime.now().uptimeNanoseconds
    }

    private static func record(_ name: String, from start: UInt64?) {
        guard let start, let captureRoot else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        PerformanceProbe.writeTiming(timingLabel.map { "\($0).\(name)" } ?? name, milliseconds: elapsed, root: captureRoot)
    }

    /// A duration the probe measured itself (the extra phases' keystrokes).
    static func recordProbeTiming(_ name: String, milliseconds: Double) {
        guard let captureRoot else { return }
        PerformanceProbe.writeTiming(timingLabel.map { "\($0).\(name)" } ?? name, milliseconds: milliseconds, root: captureRoot)
    }

    static func beginLaunch() {
        launchStart = started()
        if signposter.isEnabled { launch = signposter.beginInterval("CoordinatorInitToMenuStarted") }
    }

    static func menuReady() {
        if let launch { signposter.endInterval("CoordinatorInitToMenuStarted", launch) }
        self.launch = nil
        record("CoordinatorInitToMenuStarted", from: launchStart)
        launchStart = nil
    }

    static func beginReveal() {
        guard reveal == nil, revealStart == nil else { return }
        revealStart = started()
        if signposter.isEnabled { reveal = signposter.beginInterval("PanelRevealToOrderedFront") }
    }

    static func panelOrderedFront() {
        if let reveal { signposter.endInterval("PanelRevealToOrderedFront", reveal) }
        self.reveal = nil
        record("PanelRevealToOrderedFront", from: revealStart)
        revealStart = nil
    }

    static func cancelReveal() {
        if let reveal { signposter.endInterval("PanelRevealToOrderedFront", reveal) }
        reveal = nil
        revealStart = nil
    }

    static func beginPageSwitch() {
        guard pageSwitch == nil, pageStart == nil else { return }
        pageStart = started()
        if signposter.isEnabled { pageSwitch = signposter.beginInterval("PageSwitch") }
    }

    static func pageLaidOut() {
        if let pageSwitch { signposter.endInterval("PageSwitch", pageSwitch) }
        self.pageSwitch = nil
        record("PageSwitch", from: pageStart)
        pageStart = nil
    }

    // MARK: Phase 3: a task's page, from the request to its first drawn frame

    private static var taskPage: OSSignpostIntervalState?
    private static var taskPageStart: UInt64?

    static func beginTaskPageOpen() {
        guard taskPage == nil, taskPageStart == nil else { return }
        taskPageStart = started()
        if signposter.isEnabled { taskPage = signposter.beginInterval("TaskPageOpenToDraw") }
    }

    static func taskPageDidDraw() {
        if let taskPage { signposter.endInterval("TaskPageOpenToDraw", taskPage) }
        taskPage = nil
        record("TaskPageOpenToDraw", from: taskPageStart)
        taskPageStart = nil
    }

    static func cancelPageSwitch() {
        if let pageSwitch { signposter.endInterval("PageSwitch", pageSwitch) }
        pageSwitch = nil
        pageStart = nil
    }

    /// Detailed phases are opt-in so ordinary latency cohorts carry only
    /// the original draw/layout markers, matching their reference build.
    private static let noteWorkPhasesEnabled = ProcessInfo.processInfo.environment["ATTIC_NOTE_WORK_PHASES"] == "1"

    /// Static phase names only: traces never include document text or IDs.
    static func beginNoteWork(_ name: StaticString) -> OSSignpostIntervalState? {
        noteWorkPhasesEnabled && signposter.isEnabled ? signposter.beginInterval(name) : nil
    }

    static func endNoteWork(_ name: StaticString, _ state: OSSignpostIntervalState?) {
        if let state { signposter.endInterval(name, state) }
    }

    static func beginNoteKey() {
        guard noteKey == nil, noteStart == nil else { return }
        noteStart = started()
        if signposter.isEnabled {
            noteKey = signposter.beginInterval("NoteKeystrokeToDraw")
            noteLayout = signposter.beginInterval("NoteKeystrokeToLayout")
        }
    }

    static func noteDidLayout() {
        if let noteLayout { signposter.endInterval("NoteKeystrokeToLayout", noteLayout) }
        noteLayout = nil
    }

    static func noteDidDraw() {
        if let noteKey { signposter.endInterval("NoteKeystrokeToDraw", noteKey) }
        self.noteKey = nil
        record("NoteKeystrokeToDraw", from: noteStart)
        noteStart = nil
    }


    static func beginCanvasDrag() {
        guard canvasDrag == nil, canvasStart == nil else { return }
        canvasStart = started()
        if signposter.isEnabled { canvasDrag = signposter.beginInterval("CanvasDragToDraw") }
    }

    static func canvasDidDraw() {
        if let canvasDrag { signposter.endInterval("CanvasDragToDraw", canvasDrag) }
        self.canvasDrag = nil
        record("CanvasDragToDraw", from: canvasStart)
        canvasStart = nil
    }

    static func cancelCanvasDrag() {
        if let canvasDrag { signposter.endInterval("CanvasDragToDraw", canvasDrag) }
        canvasDrag = nil
        canvasStart = nil
    }

    // MARK: Frames (round 11)

    /// Per-frame signposts (the swipe's frames, animation watches): on only
    /// when asked for, at launch (`ATTIC_FRAME_SIGNPOSTS=1`, or the
    /// `AtticFrameSignposts` default), so a normal run adds no display link.
    /// The pager's settle and page choices are signposted always (their
    /// clock runs anyway).
    static let framesEnabled: Bool = {
        ProcessInfo.processInfo.environment["ATTIC_FRAME_SIGNPOSTS"] == "1"
            || UserDefaults.standard.bool(forKey: "AtticFrameSignposts")
    }()
    /// With the preview's frame monitor on (`ATTIC_FRAME_MONITOR=1`), the
    /// pager's moments are printed beside its frames, so an on-screen run
    /// can check what each synthetic input did.
    private static let echoes = ProcessInfo.processInfo.environment["ATTIC_FRAME_MONITOR"] == "1"
    private static func echo(_ text: @autoclosure () -> String) {
        guard echoes else { return }
        print(String(format: "ATTIC_EVENT %.4f ", CACurrentMediaTime()) + text())
    }
    /// An input the on-screen performance gate drove (`Scripts/perf_onscreen.zsh`):
    /// printed beside the frames, so the gate can check that its synthetic
    /// input reached the app. Nothing without the frame monitor.
    static func noteInput(_ text: @autoclosure () -> String) {
        echo(text())
    }
    private static var pageChoice: OSSignpostIntervalState?
    private static var pageBuild: OSSignpostIntervalState?
    private static var settle: OSSignpostIntervalState?

    /// A page chosen by a tab, a key, ⌘1–3, `show` or Search: ends at the
    /// first frame of its slide (after the page it shows is built).
    static func beginPageChoice() {
        echo("page-choice")
        guard signposter.isEnabled else { return }
        if let pageChoice { signposter.endInterval("PageChoiceToFirstFrame", pageChoice, "superseded") }
        pageChoice = signposter.beginInterval("PageChoiceToFirstFrame")
    }

    /// A page is built for a move (a slide or a swipe): ends at the next frame.
    static func beginPageBuild(_ pages: ClosedRange<Int>) {
        echo("page-build \(pages.lowerBound)-\(pages.upperBound)")
        guard signposter.isEnabled, pageBuild == nil else { return }
        pageBuild = signposter.beginInterval("PageBuildToFrame", "pages \(pages.lowerBound)-\(pages.upperBound)")
    }

    /// A page built beside the one shown while idle (not waiting for a frame).
    static func pageWarmed(_ pages: ClosedRange<Int>) {
        echo("page-warm \(pages.lowerBound)-\(pages.upperBound)")
        guard signposter.isEnabled else { return }
        signposter.emitEvent("PageWarm", "pages \(pages.lowerBound)-\(pages.upperBound)")
    }

    /// The pages a finished move passed are let go.
    static func pagesReleased(_ pages: ClosedRange<Int>) {
        echo("page-release to \(pages.lowerBound)-\(pages.upperBound)")
    }

    /// A frame of a move was shown: whatever was waiting for one ends.
    static func moveFrame() {
        if let pageBuild { signposter.endInterval("PageBuildToFrame", pageBuild) }
        pageBuild = nil
    }

    static func pagerSettleBegan() {
        guard signposter.isEnabled else { return }
        if let settle { signposter.endInterval("PagerSettle", settle, "superseded") }
        settle = signposter.beginInterval("PagerSettle")
    }

    /// The settle's first frame: the chosen page starts to show.
    static func pagerFirstFrame() {
        echo("settle-first-frame")
        moveFrame()
        if let pageChoice { signposter.endInterval("PageChoiceToFirstFrame", pageChoice) }
        pageChoice = nil
    }

    /// The settle ended: how many frames it drew and how many it missed.
    static func pagerSettleEnded(frames: Int, late: Int, interrupted: Bool) {
        if !interrupted { echo("settle-end frames=\(frames) late=\(late)") }
        guard let settle else { return }
        signposter.endInterval("PagerSettle", settle, "frames=\(frames) late=\(late) interrupted=\(interrupted)")
        self.settle = nil
    }

    /// Counts the frames drawn (and missed) while something moves: a swipe,
    /// or `seconds` after an animation starts. Only with `framesEnabled`.
    @discardableResult
    static func watchFrames(_ name: StaticString, seconds: Double? = nil, view: NSView? = nil) -> AtticFrameWatch? {
        guard framesEnabled, signposter.isEnabled else { return nil }
        let watch = AtticFrameWatch(name: name, signposter: signposter)
        watch.start(seconds: seconds, view: view)
        return watch
    }

    static func storeOpen<T>(_ operation: () throws -> T) rethrows -> T {
        let state = signposter.isEnabled ? signposter.beginInterval("StoreOpen") : nil
        let start = started()
        defer {
            if let state { signposter.endInterval("StoreOpen", state) }
            record("StoreOpen", from: start)
        }
        return try operation()
    }

    static func storeSave<T>(_ operation: () throws -> T) rethrows -> T {
        let state = signposter.isEnabled ? signposter.beginInterval("StoreSave") : nil
        let start = started()
        defer {
            if let state { signposter.endInterval("StoreSave", state) }
            record("StoreSave", from: start)
        }
        return try operation()
    }
}

/// Sparse diagnostic points for the first interaction after idle and its
/// immediate repeat. `notice` persists in the unified log in optimized builds.
/// No item IDs, titles, typed text, or item dates enter this stream.
@MainActor
enum IdleLatencyTrace {
    struct Context {
        let page: PanelSection
        let released: Bool
        let snapshot: Bool
        let mode: PanelHideAnimation
        let activity: Bool
    }

    private static let log = Logger(subsystem: "com.taha.Attic", category: "IdleLatency")
    private static var serial = 0
    private static var current: (id: Int, origin: TimeInterval, started: TimeInterval)?
    private static var hiddenAt: TimeInterval?
    private static var cleanupStart: TimeInterval?
    private static var lastCleanup: (start: TimeInterval, end: TimeInterval)?
    private static var firstFrameWatch: IdleLatencyFirstFrameWatch?

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func hidden() { hiddenAt = now }

    static func cleanupBegan() {
        cleanupStart = now
        log.notice("cleanup_begin uptime=\(now, privacy: .public)")
    }

    static func cleanupEnded() {
        let end = now
        if let start = cleanupStart { lastCleanup = (start, end) }
        cleanupStart = nil
        log.notice("cleanup_end uptime=\(end, privacy: .public)")
    }

    static func begin(_ kind: String, original: TimeInterval?, context: Context) {
        let entry = now
        let origin = original.flatMap { $0 > 0 && $0 <= entry ? $0 : nil } ?? entry
        serial &+= 1
        current = (serial, origin, entry)
        firstFrameWatch?.stop()
        firstFrameWatch = nil
        let hiddenFor = hiddenAt.map { max(0, entry - $0) } ?? -1
        let overlapping = cleanupStart.map { $0 <= entry } == true
            || lastCleanup.map { $0.start <= entry && $0.end >= origin } == true
        let page = String(describing: context.page)
        let mode = String(describing: context.mode)
        log.notice("input id=\(serial, privacy: .public) kind=\(kind, privacy: .public) origin=\(origin, privacy: .public) callback=\(entry, privacy: .public) delivery_ms=\((entry - origin) * 1000, privacy: .public) page=\(page, privacy: .public) hidden_s=\(hiddenFor, privacy: .public) released=\(context.released, privacy: .public) snapshot=\(context.snapshot, privacy: .public) hide_mode=\(mode, privacy: .public) activity=\(context.activity, privacy: .public) cleanup_overlap=\(overlapping, privacy: .public)")
    }

    static func point(_ phase: String) {
        guard let trace = current, now - trace.started < 8 else { return }
        log.notice("point id=\(trace.id, privacy: .public) phase=\(phase, privacy: .public) from_input_ms=\((now - trace.origin) * 1000, privacy: .public)")
    }

    static func span<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
        let start = now
        defer {
            if let trace = current, start >= trace.started, now - start < 8 {
                log.notice("span id=\(trace.id, privacy: .public) phase=\(phase, privacy: .public) start_ms=\((start - trace.origin) * 1000, privacy: .public) elapsed_ms=\((now - start) * 1000, privacy: .public)")
            }
        }
        return try body()
    }

    static func followUpScheduled(at deadline: TimeInterval) {
        guard let trace = current, now - trace.started < 8 else { return }
        log.notice("followup_schedule id=\(trace.id, privacy: .public) due=\(deadline, privacy: .public)")
    }

    static func followUpFired(scheduled: TimeInterval) {
        guard let trace = current, now - trace.started < 8 else { return }
        log.notice("followup_fire id=\(trace.id, privacy: .public) due=\(scheduled, privacy: .public) actual=\(now, privacy: .public) late_ms=\((now - scheduled) * 1000, privacy: .public)")
    }

    /// A display-link tick following a committed transaction is the first
    /// *eligible* changed frame, not proof of compositor scan-out pixels.
    static func firstFrameOpportunity(in view: NSView?) {
        guard let trace = current, now - trace.started < 8, let view else { return }
        firstFrameWatch?.stop()
        let watch = IdleLatencyFirstFrameWatch(id: trace.id, origin: trace.origin)
        firstFrameWatch = watch
        watch.start(in: view)
    }

    fileprivate static func frameObserved(id: Int, origin: TimeInterval, timestamp: TimeInterval) {
        guard current?.id == id else { return }
        log.notice("first_frame_candidate id=\(id, privacy: .public) since_input_ms=\((timestamp - origin) * 1000, privacy: .public)")
        firstFrameWatch = nil
    }
}

/// Only installed for one frame after an input/flush. No idle display link.
@MainActor
private final class IdleLatencyFirstFrameWatch: NSObject {
    let id: Int
    let origin: TimeInterval
    private var link: CADisplayLink?

    init(id: Int, origin: TimeInterval) { self.id = id; self.origin = origin }

    func start(in view: NSView) {
        guard view.window?.screen != nil else { return }
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func frame(_ link: CADisplayLink) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        stop()
        IdleLatencyTrace.frameObserved(id: id, origin: origin, timestamp: timestamp)
    }

    func stop() { link?.invalidate(); link = nil }
}

/// A frame count over a motion (round 11): a display link on the main
/// screen counts each frame and the refreshes it missed, and the interval
/// ends with both ("frames=… late=…"). Instruments reads it with the
/// Points of Interest / os_signpost instrument; no hitch template needed.
@MainActor
final class AtticFrameWatch: NSObject {
    private let name: StaticString
    private let signposter: OSSignposter
    private var state: OSSignpostIntervalState?
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var until: CFTimeInterval?
    private var frames = 0
    private var late = 0
    private var worst: CFTimeInterval = 0

    init(name: StaticString, signposter: OSSignposter) {
        self.name = name
        self.signposter = signposter
    }

    func start(seconds: Double?, view: NSView? = nil) {
        guard let screen = NSScreen.main else { return }
        state = signposter.beginInterval(name)
        until = seconds.map { CACurrentMediaTime() + $0 }
        let link = view?.displayLink(target: self, selector: #selector(frame(_:)))
            ?? screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        PerformanceSignposts.moveFrame()
        let interval = link.targetTimestamp - link.timestamp
        if let last, interval > 0 {
            let gap = link.timestamp - last
            worst = max(worst, gap)
            late += max(0, Int((gap / interval).rounded()) - 1)
        }
        last = link.timestamp
        frames += 1
        if let until, link.timestamp >= until { stop() }
    }

    func stop() {
        link?.invalidate()
        link = nil
        guard let state else { return }
        let frames = frames, late = late, worst = Int(worst * 1_000)
        PerformanceSignposts.noteInput("\(name) frames=\(frames) late=\(late) worstGapMs=\(worst)")
        signposter.endInterval(name, state, "frames=\(frames) late=\(late) worstGapMs=\(worst)")
        self.state = nil
    }
}
