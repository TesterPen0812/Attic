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

/// The inexpensive preview-only trace. Each touch yields NDJSON records on a
/// utility writer queue; main records monotonic clocks at existing boundaries.
/// A display-link callback is a *frame candidate*, never proof of scan-out.
@MainActor
enum IdleLatencyTrace {
    struct Context {
        let page: PanelSection
        let released: Bool
        let snapshot: Bool
        let mode: PanelHideAnimation
        let activity: Bool
    }

    #if ATTIC_FIRST_TOUCH_LOG && ATTIC_LOCAL_ONLY && arch(arm64)
    private static var serial = 0
    private static var current: (id: Int, begunNS: UInt64, kind: String, downOriginNS: UInt64)?
    private static var hiddenNS: UInt64?
    private static var lastInputNS = DispatchTime.now().uptimeNanoseconds
    private static var isPrimed = false
    private static var lastPanelPressNS: UInt64?
    private static var recordedMouseUpID: Int?
    static private(set) var lastClassificationForTesting: (first: Bool, idleMS: Double)?
    private static var frameWatch: IdleLatencyFirstFrameWatch?
    private static func validPhase(_ phase: String) -> Bool {
        switch phase {
        case "reveal_decision", "hotspot_entered", "page_change_decision", "mouse_down_returned",
             "sendEvent_dispatched", "island_sendEvent_dispatched", "handler_entered",
             "view_dispatch_done", "commit_handoff", "transaction_flushed",
             "cleanup_begin", "cleanup_end", "followup_scheduled", "followup_fired": return true
        default: return false
        }
    }

    private static func validSpan(_ phase: String) -> Bool {
        switch phase {
        case "show_build_layout", "page_build", "page_layout", "snapshot_capture",
             "snapshot_prepare", "transaction_flush": return true
        default: return false
        }
    }
    private static var timestamp: UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func emit(_ record: FirstTouchLogRecord) {
        FirstTouchLogWriter.shared.submit(record)
    }

    /// Prime the clock and queue during startup, so a genuinely idle first
    /// touch is classified correctly and does not initialize a writer on input.
    static func startMonitoring() {
        guard !isPrimed else { return }
        isPrimed = true
        lastInputNS = timestamp
        _ = FirstTouchLogWriter.shared
    }

    static func hidden() { hiddenNS = timestamp }
    static func revealed() { hiddenNS = nil }
    static var shouldTracePanelPress: Bool {
        let at = timestamp
        return lastPanelPressNS.map { at >= $0 && at - $0 >= 1_000_000_000 } ?? true
    }
    static func panelPressBegan(original: TimeInterval, context: Context) {
        lastPanelPressNS = timestamp
        begin("panel_control", original: original, context: context)
    }
    static func untracedInput() {
        lastInputNS = timestamp
        // Do not attach a subsequent, untraced press's handler to a touch
        // whose frame has already been observed (or which was superseded).
        current = nil
        frameWatch?.stop()
        frameWatch = nil
    }
    static func cleanupBegan() { point("cleanup_begin") }
    static func cleanupEnded() { point("cleanup_end") }

    static func begin(_ kind: String, original: TimeInterval?, context: Context,
                      receivedNS: UInt64? = nil) {
        // Never use data from an event's payload. Only a small fixed kind set
        // can enter a persistent log, including through this internal API.
        guard ["corner_approach", "island_action", "island_wake", "panel_control",
               "explicit_reveal"].contains(kind) else { return }
        let entered = timestamp
        let received = min(receivedNS ?? entered, entered)
        let eventNS = original.flatMap { value -> UInt64? in
            guard value.isFinite, value > 0, value < Double(received) / 1e9 else { return nil }
            return UInt64(value * 1e9)
        } ?? received
        let idle = received >= lastInputNS ? received - lastInputNS : 0
        lastInputNS = received
        serial &+= 1
        current = (serial, received, kind, eventNS)
        frameWatch?.stop()
        frameWatch = nil

        var record = FirstTouchLogRecord(id: serial, event: "input", atNS: received)
        record.kind = kind
        record.originNS = eventNS
        record.idleMS = Double(idle) / 1e6
        record.firstAfterIdle = idle >= 20_000_000_000
        lastClassificationForTesting = (record.firstAfterIdle == true, record.idleMS ?? 0)
        record.hiddenMS = hiddenNS.map { Double(received >= $0 ? received - $0 : 0) / 1e6 }
        record.page = context.page.rawValue
        record.released = context.released
        record.snapshot = context.snapshot
        record.hideMode = context.mode.rawValue
        record.napActivity = context.activity  // Activity request; actual App Nap state requires Energy Log.
        emit(record)
    }

    static func point(_ phase: String) {
        guard validPhase(phase), let trace = current else { return }
        let at = timestamp
        guard at >= trace.begunNS, at - trace.begunNS <= 8_000_000_000 else { return }
        var record = FirstTouchLogRecord(id: trace.id, event: "stage", atNS: at)
        record.stage = phase
        emit(record)
    }

    /// Timestamp the physical release separately from the mouse-down trace.
    /// AppKit can consume mouse-up in a native tracking loop, so both the
    /// window's sendEvent and nextEvent paths report it (once per touch).
    static func mouseUp(original: TimeInterval) {
        guard let trace = current, ["panel_control", "island_action"].contains(trace.kind),
              recordedMouseUpID != trace.id else { return }
        let received = timestamp
        guard received >= trace.begunNS, received - trace.begunNS <= 8_000_000_000 else { return }
        let origin = original.isFinite && original > 0 && original < Double(received) / 1e9
            ? UInt64(original * 1e9) : received
        recordedMouseUpID = trace.id
        var record = FirstTouchLogRecord(id: trace.id, event: "mouse_up", atNS: received)
        record.originNS = max(trace.downOriginNS, origin)
        emit(record)
    }

    static func cornerHotspotEntered(revealDelay: TimeInterval) {
        guard let trace = current, trace.kind == "corner_approach" else { return }
        let at = timestamp
        guard at >= trace.begunNS, at - trace.begunNS <= 8_000_000_000 else { return }
        var record = FirstTouchLogRecord(id: trace.id, event: "stage", atNS: at)
        record.stage = "hotspot_entered"
        record.revealDelayMS = revealDelay * 1_000
        emit(record)
    }

    static func span<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
        guard validSpan(phase), let trace = current else { return try body() }
        let before = timestamp
        defer {
            let after = timestamp
            if after >= before, after >= trace.begunNS,
               after - trace.begunNS <= 8_000_000_000 {
                var record = FirstTouchLogRecord(id: trace.id, event: "span", atNS: after)
                record.spanStartNS = before
                record.stage = phase
                emit(record)
            }
        }
        return try body()
    }

    static func followUpScheduled(at deadline: TimeInterval) {
        followup("followup_scheduled", due: deadline)
    }
    static func followUpFired(scheduled: TimeInterval) {
        followup("followup_fired", due: scheduled)
    }
    private static func followup(_ name: String, due: TimeInterval) {
        guard let trace = current else { return }
        let at = timestamp
        guard at >= trace.begunNS, at - trace.begunNS <= 8_000_000_000 else { return }
        var record = FirstTouchLogRecord(id: trace.id, event: "stage", atNS: at)
        record.stage = name
        record.dueNS = due.isFinite && due > 0 ? UInt64(due * 1e9) : nil
        emit(record)
    }

    static func firstFrameOpportunity(in view: NSView?) {
        guard let trace = current, let view else { return }
        let at = timestamp
        guard at >= trace.begunNS, at - trace.begunNS <= 8_000_000_000 else { return }
        frameWatch?.stop()
        // This marks the next run-loop handoff to CA; commit and WindowServer
        // presentation must be inspected independently in Instruments.
        DispatchQueue.main.async {
            guard current?.id == trace.id else { return }
            point("commit_handoff")
        }
        let watch = IdleLatencyFirstFrameWatch(id: trace.id)
        frameWatch = watch
        watch.start(in: view)
    }

    fileprivate static func frameObserved(id: Int) {
        guard current?.id == id else { return }
        frameWatch = nil
        emit(FirstTouchLogRecord(id: id, event: "frame_candidate", atNS: timestamp))
        current = nil
    }
    #else
    static func startMonitoring() {}
    static func hidden() {}
    static func revealed() {}
    static var shouldTracePanelPress: Bool { false }
    static func panelPressBegan(original: TimeInterval, context: Context) {}
    static func untracedInput() {}
    static func mouseUp(original: TimeInterval) {}
    static func cornerHotspotEntered(revealDelay: TimeInterval) {}
    static func cleanupBegan() {}
    static func cleanupEnded() {}
    static func begin(_ kind: String, original: TimeInterval?, context: Context,
                      receivedNS: UInt64? = nil) {}
    static func point(_ phase: String) {}
    static func span<T>(_ phase: String, _ body: () throws -> T) rethrows -> T { try body() }
    static func followUpScheduled(at deadline: TimeInterval) {}
    static func followUpFired(scheduled: TimeInterval) {}
    static func firstFrameOpportunity(in view: NSView?) {}
    #endif
}

#if ATTIC_FIRST_TOUCH_LOG && ATTIC_LOCAL_ONLY && arch(arm64)
/// Installs a display link for only the next opportunity after a touch.
@MainActor
private final class IdleLatencyFirstFrameWatch: NSObject {
    let id: Int
    private var link: CADisplayLink?
    init(id: Int) { self.id = id }
    func start(in view: NSView) {
        guard view.window?.screen != nil else { return }
        let display = view.displayLink(target: self, selector: #selector(frame(_:)))
        link = display
        display.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ link: CADisplayLink) {
        stop()
        IdleLatencyTrace.frameObserved(id: id)
    }
    func stop() { link?.invalidate(); link = nil }
}
#endif

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
