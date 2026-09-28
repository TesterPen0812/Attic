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

    static func cancelPageSwitch() {
        if let pageSwitch { signposter.endInterval("PageSwitch", pageSwitch) }
        pageSwitch = nil
        pageStart = nil
    }

    static func beginNoteKey() {
        guard noteKey == nil, noteStart == nil else { return }
        noteStart = started()
        if signposter.isEnabled { noteKey = signposter.beginInterval("NoteKeystrokeToDraw") }
    }

    static func noteDidDraw() {
        if let noteKey { signposter.endInterval("NoteKeystrokeToDraw", noteKey) }
        self.noteKey = nil
        record("NoteKeystrokeToDraw", from: noteStart)
        noteStart = nil
    }

    static func cancelNoteKey() {
        if let noteKey { signposter.endInterval("NoteKeystrokeToDraw", noteKey) }
        noteKey = nil
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
    private static var pageChoice: OSSignpostIntervalState?
    private static var pageBuild: OSSignpostIntervalState?
    private static var settle: OSSignpostIntervalState?

    /// A page chosen by a tab, a key, ⌘1–3, `show` or Search: ends at the
    /// first frame of its slide (after the page it shows is built).
    static func beginPageChoice() {
        guard signposter.isEnabled else { return }
        if let pageChoice { signposter.endInterval("PageChoiceToFirstFrame", pageChoice, "superseded") }
        pageChoice = signposter.beginInterval("PageChoiceToFirstFrame")
    }

    /// A page is built for a move (a slide or a swipe): ends at the next frame.
    static func beginPageBuild(_ pages: ClosedRange<Int>) {
        guard signposter.isEnabled, pageBuild == nil else { return }
        pageBuild = signposter.beginInterval("PageBuildToFrame", "pages \(pages.lowerBound)-\(pages.upperBound)")
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
        moveFrame()
        if let pageChoice { signposter.endInterval("PageChoiceToFirstFrame", pageChoice) }
        pageChoice = nil
    }

    /// The settle ended: how many frames it drew and how many it missed.
    static func pagerSettleEnded(frames: Int, late: Int, interrupted: Bool) {
        guard let settle else { return }
        signposter.endInterval("PagerSettle", settle, "frames=\(frames) late=\(late) interrupted=\(interrupted)")
        self.settle = nil
    }

    /// Counts the frames drawn (and missed) while something moves: a swipe,
    /// or `seconds` after an animation starts. Only with `framesEnabled`.
    @discardableResult
    static func watchFrames(_ name: StaticString, seconds: Double? = nil) -> AtticFrameWatch? {
        guard framesEnabled, signposter.isEnabled else { return nil }
        let watch = AtticFrameWatch(name: name, signposter: signposter)
        watch.start(seconds: seconds)
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

    func start(seconds: Double?) {
        guard let screen = NSScreen.main else { return }
        state = signposter.beginInterval(name)
        until = seconds.map { CACurrentMediaTime() + $0 }
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
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
        signposter.endInterval(name, state, "frames=\(frames) late=\(late) worstGapMs=\(worst)")
        self.state = nil
    }
}
