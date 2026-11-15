import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// ScrollEdgeUITests' hang (PR #11, CI runs 39860554817 and 39887675692):
/// with a draft in the composer, so the strip shows, the third scroll step
/// (−170, +11, +11) left the app's main thread busy for minutes. Hosted
/// here, on the invisible test host, with Reduce Motion as CI's runners
/// have it (on) and off; each step must return within 2 s.
@MainActor
final class ScrollEdgeHangTests: XCTestCase {
    func testHangProbeDoesNotFormatKeysOrEventValuesWhenDisabled() {
        #if DEBUG
        XCTAssertFalse(AtticHangProbe.isEnabled, "the ordinary unit host must not arm the CI probe")
        var formatted = 0
        func format() -> String {
            formatted += 1
            return UUID().uuidString
        }
        var unexpectedKeys = 0
        for _ in 0..<1_000 {
            if !AtticHangProbe.key(format()).isEmpty { unexpectedKeys += 1 }
            AtticHangProbe.note("fold.size", key: format(), value: format(), detail: format())
            if !TasksFoldBody.probeKey(for: UUID()).isEmpty { unexpectedKeys += 1 }
        }
        XCTAssertEqual(unexpectedKeys, 0, "an unarmed probe leaves every diagnostic row key empty")
        XCTAssertEqual(formatted, 0, "unarmed probe must perform zero string formatting evaluations")
        #endif
    }

    // MARK: - The probe's own logic (fake clock, no run loop, no app)

    #if DEBUG
    private final class FakeClock: @unchecked Sendable {
        var now: UInt64 = 0
        func advance(milliseconds: Double) { now += UInt64(milliseconds * 1_000_000) }
    }

    private func makeProbe(_ clock: FakeClock) -> (probe: AtticHangProbe, url: URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-hang-test-\(UUID().uuidString).txt")
        let probe = AtticHangProbe(outputURL: url, clock: { clock.now })
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".first"))
        }
        return (probe, url)
    }

    private func dump(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    /// Opus R-9: when another afterWaiting observer spins, the watchdog
    /// must have already marked the main run loop awake (earliest order).
    func testRunLoopWakeObserverRunsAtEarliestOrder() {
        let clock = FakeClock()
        let (probe, _) = makeProbe(clock)
        probe.start()
        defer { probe.stopForTesting() }
        XCTAssertEqual(probe.installedObserverOrders.wake, CFIndex(Int32.min))
        XCTAssertEqual(probe.installedObserverOrders.sleep, CFIndex(Int32.max))
    }

    /// Opus R-1 = Dot R-1 (P0). The watchdog read its clock before the lock, so
    /// run-loop state written in between could be newer than `now`, and the
    /// unsigned subtraction trapped: the app crashed mid-hang instead of dumping.
    func testTheWatchdogNeverTrapsWhenRunLoopStateIsNewerThanItsClockReading() {
        // lastCompletedTurn > now, with no genuine wait for 3 s.
        let clock = FakeClock()
        clock.now = 100_000_000
        let (probe, url) = makeProbe(clock)
        clock.now = 10_000_000_000
        probe.runLoop(.beforeWaiting)
        for _ in 0..<2 {
            clock.advance(milliseconds: 0.2)
            probe.runLoop(.afterWaiting)
            probe.runLoop(.beforeWaiting)
        }
        clock.advance(milliseconds: 0.2)
        probe.runLoop(.afterWaiting)
        clock.now = 5_000_000_000
        probe.checkForHang()
        XCTAssertEqual(dump(url)?.hasPrefix("HANG:"), true, "a dump is written, and nothing trapped")
        XCTAssertTrue(dump(url)?.contains("last-turn=0ms ago") == true, "an age that would be negative reads as zero")

        // lastRealWait > now, with an unfinished turn.
        let later = FakeClock()
        later.now = 1_000_000_000
        let (second, secondURL) = makeProbe(later)
        second.runLoop(.beforeWaiting)
        later.now = 20_000_000_000
        second.runLoop(.afterWaiting)
        later.now = 5_000_000_000
        second.checkForHang()
        XCTAssertEqual(dump(secondURL)?.hasPrefix("HANG:"), true, "a dump is written, and nothing trapped")
        XCTAssertTrue(dump(secondURL)?.contains("last-real-wait=0ms ago") == true)
    }

    /// Opus R-3 (a). AppKit dispatches events between the loop's exit and its next
    /// entry, so `.exit` is not sleep and `.entry` is not a wake.
    func testASpinInsideEventHandlingCountsAsBusy() {
        let clock = FakeClock()
        let (probe, url) = makeProbe(clock)
        clock.advance(milliseconds: 1_000)
        probe.runLoop(.beforeWaiting)
        clock.advance(milliseconds: 50)
        probe.runLoop(.afterWaiting)
        // The loop returns from its wait, then AppKit sends the scroll event.
        clock.advance(milliseconds: 10)
        probe.runLoop(.exit)
        clock.advance(milliseconds: 4_000)
        probe.checkForHang()
        XCTAssertTrue(dump(url)?.hasPrefix("HANG: unfinished-run-loop-turn") == true,
                      "a spin inside event handling is a busy run loop: \(dump(url) ?? "no dump")")
    }

    /// Opus R-3 (b). A long, healthy 120 Hz animation leaves ~1.3 ms of real
    /// sleep per 8.3 ms frame: it is not a stall. A loop that wakes at once is.
    func testAHealthy120HzAnimationIsNotAStallButAnImmediateWakeLoopIs() {
        func run(waitMilliseconds: Double) -> String? {
            let clock = FakeClock()
            let (probe, url) = makeProbe(clock)
            for frame in 0..<1_200 {
                clock.advance(milliseconds: waitMilliseconds)
                probe.runLoop(.afterWaiting)
                clock.advance(milliseconds: 7)
                if frame % 30 == 0 { probe.checkForHang() }
                probe.runLoop(.beforeWaiting)
            }
            return dump(url)
        }
        XCTAssertNil(run(waitMilliseconds: 1.3), "ten seconds of a healthy 120 Hz animation write no dump")
        XCTAssertTrue(run(waitMilliseconds: 0.1)?.hasPrefix("HANG: no-genuine-wait") == true,
                      "a loop that wakes again at once for ten seconds is the stall")
    }

    /// Dot R-1: 120 Hz frames can do 7.6 ms of work and sleep for just 0.7 ms.
    /// The watchdog samples during the busy portion, exactly 30 frames apart,
    /// without ever finding a 1 ms wait. Progress must not turn into a kill.
    func testAHealthy120HzPointSevenMillisecondWaitNeverLooksContinuous() {
        let clock = FakeClock()
        let (probe, url) = makeProbe(clock)
        for frame in 0..<3_600 {
            clock.advance(milliseconds: 0.7)
            probe.runLoop(.afterWaiting)
            clock.advance(milliseconds: 7.6)
            if frame.isMultiple(of: 30) { probe.checkForHang() }
            probe.runLoop(.beforeWaiting)
        }
        XCTAssertNil(dump(url), "30 s of healthy 120 Hz turns must not publish a false HANG")

        // Positive control: one genuinely stuck turn must still be detected.
        clock.advance(milliseconds: 3_100)
        probe.runLoop(.afterWaiting)
        clock.advance(milliseconds: 3_100)
        probe.checkForHang()
        XCTAssertTrue(dump(url)?.hasPrefix("HANG: unfinished-run-loop-turn") == true)
    }

    /// Dot R-6 (the probe's half). Every dump says how many real waits the loop
    /// has had, so a reader can tell a continuous stall from busy bursts.
    func testEveryDumpCarriesTheHealthyWaitCount() {
        let clock = FakeClock()
        let (probe, url) = makeProbe(clock)
        for _ in 0..<2 {
            clock.advance(milliseconds: 5)
            probe.runLoop(.afterWaiting)
            probe.runLoop(.beforeWaiting)
            clock.advance(milliseconds: 5)
        }
        probe.runLoop(.afterWaiting)
        clock.advance(milliseconds: 4_000)
        probe.checkForHang()
        XCTAssertTrue(dump(url)?.hasPrefix("HANG: unfinished-run-loop-turn") == true)
        XCTAssertTrue(dump(url)?.contains("healthy-waits=2") == true, "two real waits so far: \(dump(url) ?? "")")
        // The loop sleeps for real, then spins again: the count moves.
        probe.runLoop(.beforeWaiting)
        clock.advance(milliseconds: 5)
        probe.runLoop(.afterWaiting)
        clock.advance(milliseconds: 4_000)
        probe.checkForHang()
        XCTAssertTrue(dump(url)?.contains("healthy-waits=3") == true, "a real wait changes the count: \(dump(url) ?? "")")
    }

    /// Dot R-6: recovery must learn about a healthy wait even if the next
    /// busy burst has not yet lasted long enough to produce another HANG.
    func testAHealthyWaitReplacesAStaleHangBeforeTheNextBusyBurst() {
        let clock = FakeClock()
        let (probe, url) = makeProbe(clock)
        clock.advance(milliseconds: 4_000)
        probe.checkForHang()
        XCTAssertTrue(dump(url)?.hasPrefix("HANG:") == true)
        probe.runLoop(.beforeWaiting)
        clock.advance(milliseconds: 5)
        probe.runLoop(.afterWaiting)
        probe.checkForHang()
        XCTAssertTrue(dump(url)?.hasPrefix("HEALTHY:") == true,
                      "a recovered loop must not leave a fresh HANG for recovery to accumulate")
        XCTAssertTrue(dump(url)?.contains("healthy-waits=1") == true)
        XCTAssertTrue(dump(URL(fileURLWithPath: url.path + ".first"))?.hasPrefix("HANG:") == true,
                      "the original dump survives as evidence")
    }

    /// Dot R-3 / Opus R-1: a transient launch HANG must not consume the only
    /// snapshot of the later scroll freeze, even after its onset leaves the ring.
    func testLaunchAndFollowingScrollHangKeepSeparateOnsetSnapshots() {
        let clock = FakeClock()
        let (probe, url) = makeProbe(clock)
        let laterOnset = URL(fileURLWithPath: url.path + ".after-first")
        addTeardownBlock { try? FileManager.default.removeItem(at: laterOnset) }
        AtticHangProbe.testInstance = probe
        defer { AtticHangProbe.testInstance = nil }
        AtticHangProbe.note("phase", key: "onset", value: "launch")
        clock.advance(milliseconds: 4_000)
        probe.checkForHang()
        XCTAssertTrue(dump(URL(fileURLWithPath: url.path + ".first"))?.contains("launch") == true)

        probe.runLoop(.beforeWaiting)
        clock.advance(milliseconds: 5)
        probe.runLoop(.afterWaiting)
        probe.checkForHang()
        XCTAssertTrue(dump(url)?.hasPrefix("HEALTHY:") == true)

        AtticHangProbe.note("phase", key: "onset", value: "scroll-onset")
        clock.advance(milliseconds: 4_000)
        probe.checkForHang()
        XCTAssertTrue(dump(laterOnset)?.contains("scroll-onset") == true,
                      "first recovered scroll-hang onset must have its own permanent snapshot")
        for number in 0..<4_200 {
            AtticHangProbe.note("later", key: "event", value: String(number))
        }
        clock.advance(milliseconds: 2_250)
        probe.checkForHang()
        XCTAssertTrue(dump(laterOnset)?.contains("scroll-onset") == true,
                      "later snapshot rotation must not overwrite either onset")
        XCTAssertTrue(dump(URL(fileURLWithPath: url.path + ".first"))?.contains("launch") == true)
    }

    /// Opus R-2 (the app's half). A signed app is sandboxed: the test names a
    /// leaf, which resolves into the app's own temporary folder.
    func testProbeFilesResolveIntoTheAppsOwnTemporaryFolder() {
        let temporary = "/private/var/folders/xx/T/"
        func resolve(_ environment: [String: String]) -> String? {
            AtticHangProbe.outputURL(environment: environment, temporaryDirectory: temporary)?.path
        }
        XCTAssertEqual(resolve(["ATTIC_HANG_PROBE_FILE": "attic-hang-1A2B.txt"]), "/private/var/folders/xx/T/attic-hang-1A2B.txt")
        XCTAssertEqual(resolve(["ATTIC_HANG_PROBE_PATH": "/tmp/x/probe.txt"]), "/tmp/x/probe.txt")
        for unsafe in ["", "../escape.txt", "a/b.txt", ".hidden", "/abs.txt", "bad name.txt"] {
            XCTAssertNil(resolve(["ATTIC_HANG_PROBE_FILE": unsafe]), "\(unsafe) is not a leaf name")
        }
        XCTAssertNil(resolve(["ATTIC_HANG_PROBE_PATH": "relative.txt"]))
        XCTAssertNil(resolve([:]))
    }

    /// Opus R-5 / Dot R-5. `detail` can be slow; it must never run inside the
    /// lock the run loop and the watchdog share.
    func testDetailsAreFormattedOutsideTheGlobalLock() {
        let clock = FakeClock()
        let (probe, _) = makeProbe(clock)
        AtticHangProbe.testInstance = probe
        defer { AtticHangProbe.testInstance = nil }
        var lockWasFree: Bool?
        func detail() -> String {
            lockWasFree = probe.lockIsFree
            return "detail"
        }
        AtticHangProbe.note("kind", key: "key", value: "value", detail: detail())
        XCTAssertEqual(lockWasFree, true, "the lock is not held while a detail is formatted")
    }

    /// Opus R-4: identical geometry across many lazy layout passes must not
    /// stringify a CGRect on every call just to discover it was unchanged.
    func testArmedGeometryProbeFormatsOnlyChangedRawValues() {
        final class Counter { var renders = 0 }
        struct Geometry: Equatable, CustomStringConvertible {
            let frame: CGRect
            let counter: Counter
            static func == (lhs: Self, rhs: Self) -> Bool { lhs.frame == rhs.frame }
            var description: String {
                counter.renders += 1
                return "\(frame)"
            }
        }
        let clock = FakeClock()
        let (probe, _) = makeProbe(clock)
        AtticHangProbe.testInstance = probe
        defer { AtticHangProbe.testInstance = nil }
        let counter = Counter()
        let geometry = Geometry(frame: CGRect(x: 2, y: 20, width: 290, height: 45), counter: counter)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<5_000 { AtticHangProbe.noteRaw("row.slotFrame.transform", key: "row", value: geometry) }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000_000 / 5_000
        print("FZ_ARMED_GEOMETRY_US_PER_PASS=\(elapsed) rendered=\(counter.renders)")
        XCTAssertEqual(probe.callCount(kind: "row.slotFrame.transform", key: "row"), 5_000)
        XCTAssertEqual(counter.renders, 1,
                       "the same CGRect across 5,000 passes is formatted once, not once per pass")
        let changed = Geometry(frame: CGRect(x: 2, y: 21, width: 290, height: 45), counter: counter)
        AtticHangProbe.noteRaw("row.slotFrame.transform", key: "row", value: changed)
        AtticHangProbe.noteRaw("row.slotFrame.transform", key: "row", value: changed)
        XCTAssertEqual(counter.renders, 2, "a changed frame is formatted once, then cached for the next pass")
    }
    #endif

    // MARK: - Nothing runs or grows when the diagnostics are off

    /// Dot R-3 / R-4. With the hang probe unset and no hosted test opted in, a
    /// heavy list that lays out and is hovered row by row takes no layout lock
    /// and adds no entry to the per-row hover maps (a Local build runs for days).
    func testDisabledDiagnosticsTakeNoLockAndAddNoPerRowEntriesWhileAHeavyListLaysOutAndHovers() throws {
        #if DEBUG
        XCTAssertFalse(AtticHangProbe.isEnabled)
        TasksFoldLayoutProbe.shared.start()
        TasksFoldLayoutProbe.shared.stop()
        AtticTaskRow.stopHoverDiagnostics()
        TasksScrollKeeper.KeeperView.recordCalls = 0
        defer { AtticTaskRow.stopHoverDiagnostics() }
        let mounted = try mountLongList(extraRows: 300)
        defer { mounted.window.close() }
        var tracked: Set<ObjectIdentifier> = []
        for pass in 0..<3 {
            for fraction in stride(from: 0.2, through: 0.85, by: 0.05) {
                try Self.hover(window: mounted.window, at: CGPoint(x: 160, y: 464 * fraction), tracked: &tracked)
                mounted.frame()
            }
            // Reveal other rows, so many distinct rows are hovered.
            let list = mounted.list
            list.contentView.scroll(to: CGPoint(x: 0, y: list.contentView.bounds.minY + 160 * CGFloat(pass + 1)))
            list.reflectScrolledClipView(list.contentView)
            mounted.settle(0.3)
        }
        XCTAssertEqual(TasksScrollKeeper.KeeperView.recordCalls, 0, "the production scroll path counts nothing unless a test opts in")
        XCTAssertEqual(TasksFoldLayoutProbe.shared.lockEntries, 0, "no layout call reaches the probe's lock while it is off")
        XCTAssertTrue(AtticTaskRow.hoverEvents.isEmpty, "no per-row hover counts are kept while diagnostics are off")
        XCTAssertTrue(AtticTaskRow.hoverHistory.isEmpty, "no per-row hover history is kept while diagnostics are off")

        // Opted in, the same instruments still record.
        AtticTaskRow.recordsHoverDiagnostics = true
        TasksFoldLayoutProbe.shared.start()
        defer { TasksFoldLayoutProbe.shared.stop() }
        TasksFoldLayoutProbe.shared.measure(44)
        TasksFoldLayoutProbe.shared.place()
        XCTAssertEqual(TasksFoldLayoutProbe.shared.lockEntries, 2)
        XCTAssertEqual(TasksFoldLayoutProbe.shared.snapshot().measures, 1)
        for fraction in stride(from: 0.2, through: 0.85, by: 0.1) {
            try Self.hover(window: mounted.window, at: CGPoint(x: 160, y: 464 * fraction), tracked: &tracked)
            mounted.frame()
        }
        XCTAssertFalse(AtticTaskRow.hoverEvents.isEmpty, "opted in, hover delivery is recorded")
        AtticTaskRow.stopHoverDiagnostics()
        XCTAssertTrue(AtticTaskRow.hoverHistory.isEmpty, "stopping clears what was recorded")
        #endif
    }

    // MARK: - Observe, never perturb

    /// Opus R-5 / Dot R-5. Armed, the document-frame observer may only note
    /// geometry. A frame change with a clip offset the model has not recorded
    /// must write the same model state and run the same production paths as an
    /// unprobed run.
    func testTheArmedDocumentObserverNotesGeometryAndChangesNothing() throws {
        #if DEBUG
        struct Outcome: Equatable {
            var recordCalls: Int
            var offset: CGFloat?
            var postsFrames: Bool
        }
        func run(armed: Bool, postsFrames: Bool) throws -> (Outcome, notes: Int) {
            TasksScrollKeeper.KeeperView.recordsDiagnostics = true
            defer { TasksScrollKeeper.KeeperView.recordsDiagnostics = false }
            let probe = armed ? AtticHangProbe(outputURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("attic-hang-observer-\(UUID().uuidString).txt")) : nil
            AtticHangProbe.testInstance = probe
            defer { AtticHangProbe.testInstance = nil }
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            let store = TaskStore(container: container)
            let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices(chooseComposerFiles: {}))
            let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 320, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
            let document = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 2_000))
            let keeper = TasksScrollKeeper.KeeperView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            keeper.model = model
            keeper.tab = .now
            scroll.documentView = document
            window.contentView = scroll
            document.postsFrameChangedNotifications = postsFrames
            document.addSubview(keeper)
            defer { window.contentView = nil; window.close() }
            scroll.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            // A clip offset nobody has recorded: no bounds notification goes out.
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = false
            clip.scroll(to: CGPoint(x: 0, y: 300))
            clip.postsBoundsChangedNotifications = true
            TasksScrollKeeper.KeeperView.recordCalls = 0
            let beforeNotes = probe?.callCount(kind: "scroll.documentFrame", key: "now") ?? 0
            document.setFrameSize(CGSize(width: 300, height: 2_400))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            return (Outcome(recordCalls: TasksScrollKeeper.KeeperView.recordCalls, offset: model.scrollOffsets[.now],
                            postsFrames: document.postsFrameChangedNotifications),
                    (probe?.callCount(kind: "scroll.documentFrame", key: "now") ?? 0) - beforeNotes)
        }
        for postsFrames in [false, true] {
            let off = try run(armed: false, postsFrames: postsFrames)
            let on = try run(armed: true, postsFrames: postsFrames)
            XCTAssertEqual(on.0, off.0, "a document frame change writes the same model state and runs the same production paths probed or not")
            XCTAssertEqual(on.0.postsFrames, postsFrames, "arming never enables frame notifications")
            XCTAssertEqual(off.notes, 0)
            if postsFrames {
                XCTAssertGreaterThan(on.notes, 0, "an existing frame notification notes the new geometry")
            } else {
                XCTAssertEqual(on.notes, 0, "no extra notification is requested")
            }
        }
        #endif
    }

    private struct Mounted {
        let window: NSWindow
        let list: NSScrollView
        let frame: () -> Void
        let settle: (TimeInterval) -> Void
        let keepAlive: Any
    }

    /// The UI test's panel (320 x 464, dark glass) hosting the long Now list, off screen.
    private func mountLongList(extraRows: Int) throws -> Mounted {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container, long: true)
        for index in 0..<extraRows { container.mainContext.insert(TaskItem(title: "Dense row \(index)")) }
        if extraRows > 0 { try container.mainContext.save() }
        let store = TaskStore(container: container)
        var services = TasksPageServices(chooseComposerFiles: {})
        services.openTaskNote = { _ in }
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let size = CGSize(width: 320, height: 464)
        var focused = false
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                             addBarFocused: Binding(get: { focused }, set: { focused = $0 }), pointer: TasksPointer())
        let window = Panel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        let design = AtticDesignContext(mode: .dark, surface: .glass, reduceMotion: false)
        window.contentView = NSHostingView(rootView: page
            .background { AtticPanelStageSurface(cornerSize: 52) }
            .atticDesign(design)
            .environment(\.displayScale, 1)
            .frame(width: size.width, height: size.height))
        window.orderFront(nil)
        window.makeKey()
        func frame() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        func settle(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { frame() }
        }
        settle(1)
        let lists = window.contentView.map(Self.scrollViews) ?? []
        let list = try XCTUnwrap(lists.max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 })
        return Mounted(window: window, list: list, frame: frame, settle: settle, keepAlive: (container, model, store))
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var backingScaleFactor: CGFloat { 1 }
    }

    /// Ends a stalled run with a crash (so its report carries the main
    /// thread's stack) instead of hanging the suite.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var started: Date?
        private var label = ""
        private var stopped = false

        init() {
            Thread.detachNewThread { [self] in
                while true {
                    Thread.sleep(forTimeInterval: 0.25)
                    lock.lock()
                    let done = stopped, since = started, what = label
                    lock.unlock()
                    if done { return }
                    if let since, Date().timeIntervalSince(since) > 20 {
                        FileHandle.standardError.write(Data("ATTIC_SCROLL_HANG stalled in \(what)\n".utf8))
                        abort()
                    }
                }
            }
        }

        func run<T>(_ what: String, _ body: () throws -> T) rethrows -> (T, TimeInterval) {
            lock.lock(); started = Date(); label = what; lock.unlock()
            let start = Date()
            defer { lock.lock(); started = nil; lock.unlock() }
            let value = try body()
            return (value, Date().timeIntervalSince(start))
        }

        func stop() { lock.lock(); stopped = true; lock.unlock() }
    }

    override func tearDown() {
        #if DEBUG
        AtticMotionPreference.systemReduceMotionOverride = nil
        #endif
        super.tearDown()
    }

    func testScrollingUnderTheStripReturnsWithReduceMotion() throws {
        try check(reduceMotion: true)
    }

    func testScrollingUnderTheStripReturnsWithoutReduceMotion() throws {
        try check(reduceMotion: false)
    }

    /// The CI trace cycled at a 52 pt clip offset on its 1× display.
    /// Cross that prefetch boundary one pixel at a time, reading AX after
    /// every step instead of relying only on the original wheel sequence.
    func testOnePixelScrollsAcrossTheCIPrefetchBoundaryReturnWithAccessibilitySnapshots() throws {
        try check(reduceMotion: true, deltas: [-145] + Array(repeating: -1, count: 8) + Array(repeating: 1, count: 8))
    }

    func testLongDenseListsStillVirtualizeTheirRows() throws {
        try check(reduceMotion: true, deltas: [], extraRows: 500, enablesAccessibility: false)
    }

    /// CI's third pass: glass, dark, a stationary hovered row, and the
    /// same two scroll deltas. A quiet run must stop measuring and placing
    /// rows after the scroll and hover animations finish.
    func testDarkGlassHoveredRowStopsUpdatingAfterScroll() throws {
        try check(reduceMotion: false, deltas: [-140, 280], mode: .dark, surface: .glass, stationaryHover: true)
    }

    #if DEBUG
    /// Opus R-3: a hover from the pre-scroll settle must never satisfy the
    /// assertion intended to prove a row received hover after scrolling.
    func testPreScrollHoverHistoryIsEmptyBeforeTheFirstScroll() throws {
        var cleared: Bool?
        try check(reduceMotion: false, deltas: [], mode: .dark, surface: .glass,
                  stationaryHover: true, beforePreScrollHistoryReset: {
            AtticTaskRow.hoverHistory[UUID()] = [true]
        }, afterPreScrollSettle: {
            cleared = AtticTaskRow.hoverHistory.values.allSatisfy(\.isEmpty)
        })
        XCTAssertEqual(cleared, true, "pre-scroll hover must not be mistaken for post-scroll delivery")
    }

    /// Opus R-6: a throwing first hover must leave no global diagnostics
    /// enabled for the later hosted tests in the same process.
    func testThrowingInitialHoverCleansGlobalDiagnostics() throws {
        defer { AtticTaskRow.stopHoverDiagnostics() }
        XCTAssertThrowsError(try check(reduceMotion: false, deltas: [], stationaryHover: true,
                                       failInitialHover: true))
        XCTAssertFalse(AtticTaskRow.recordsHoverDiagnostics)
    }
    #endif

    private func check(reduceMotion: Bool, deltas: [CGFloat] = [-170, 11, 11, 340],
                       extraRows: Int = 0, enablesAccessibility: Bool = true,
                       mode: AtticDesignContext.Mode = .light, surface: PanelSurfaceStyle = .solid,
                       stationaryHover: Bool = false, beforePreScrollHistoryReset: (() -> Void)? = nil,
                       afterPreScrollSettle: (() -> Void)? = nil,
                       failInitialHover: Bool = false) throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(enablesAccessibility, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }

        #if DEBUG
        AtticMotionPreference.systemReduceMotionOverride = reduceMotion
        #endif
        let watchdog = Watchdog()
        defer { watchdog.stop() }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container, long: true)
        for index in 0..<extraRows { container.mainContext.insert(TaskItem(title: "Dense row \(index)")) }
        if extraRows > 0 { try container.mainContext.save() }
        let store = TaskStore(container: container)
        var services = TasksPageServices(chooseComposerFiles: {})
        if stationaryHover { services.openTaskNote = { _ in } }
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        // The UI test's panel: 320 × 464, solid, light.
        let size = CGSize(width: 320, height: 464)
        var focused = true
        let pointer = TasksPointer()
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                             addBarFocused: Binding(get: { focused }, set: { focused = $0 }), pointer: pointer)
        let window = Panel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        if mode == .dark { window.appearance = NSAppearance(named: .darkAqua) }
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let design = AtticDesignContext(mode: mode, surface: surface, reduceMotion: reduceMotion)
        window.contentView = NSHostingView(rootView: page
            .background {
                if stationaryHover { AtticPanelStageSurface(cornerSize: 52) }
            }
            .atticDesign(design)
            .environment(\.displayScale, 1)
            .frame(width: size.width, height: size.height))
        window.orderFront(nil)
        window.makeKey()
        func frame() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        func settle(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { frame() }
        }
        _ = watchdog.run("launch") { settle(1) }

        // The draft, as typed: the strip shows its Date, Tag and Priority.
        let draft = "Water plants tomorrow #home !!"
        let (_, typed) = watchdog.run("draft") {
            model.addBarState.text.text = draft
            model.addBarState.caret = (draft as NSString).length
            settle(1)
        }
        XCTAssertLessThan(typed, 2.5, "the draft settles")
        if !enablesAccessibility {
            let resident = pointer.frames.count
            print("ATTIC_SCROLL_HANG resident=\(resident) total=\(model.rows(for: .now).count)")
            XCTAssertGreaterThan(resident, 0, "real rows must be laid out")
            XCTAssertLessThan(resident, extraRows, "the loop fix must preserve virtualization")
            return
        }
        let stripShown = Self.axFind("composer-date", in: window.contentView as Any, depth: 0)
        XCTAssertTrue(stripShown, "the accessibility snapshot reaches the visible composer strip")
        XCTAssertTrue(Self.axFind("composer-files", in: window.contentView as Any, depth: 0),
                      "the fixture includes the app's fourth strip control")
        print("ATTIC_SCROLL_HANG strip_identified=\(stripShown) reduceMotion=\(reduceMotion)")

        let lists = window.contentView.map(Self.scrollViews) ?? []
        let list = try XCTUnwrap(lists.max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 },
                                 "the Now list")
        var tracked: Set<ObjectIdentifier> = []
        defer {
            if stationaryHover {
                TasksFoldLayoutProbe.shared.stop()
                AtticTaskRow.stopHoverDiagnostics()
            }
        }
        if stationaryHover {
            print("ATTIC_SCROLL_HOVER initial_frames=\(pointer.frames.values.sorted { $0.minY < $1.minY }.prefix(15)) clip=\(list.contentView.bounds) document=\(list.documentView?.frame ?? .zero)")
            AtticTaskRow.drawsOpen = [:]
            AtticTaskRow.stopHoverDiagnostics()
            AtticTaskRow.recordsHoverDiagnostics = true
            if failInitialHover { throw NSError(domain: "InjectedInitialHoverFailure", code: 1) }
            try Self.hover(window: window, at: CGPoint(x: size.width * 0.5, y: size.height * 0.55), tracked: &tracked)
            settle(0.7)
            print("ATTIC_SCROLL_HOVER before_scroll=\(AtticTaskRow.hoverHistory.values) open=\(AtticTaskRow.drawsOpen)")
            beforePreScrollHistoryReset?()
            AtticTaskRow.hoverHistory.removeAll()
            afterPreScrollSettle?()
            TasksFoldLayoutProbe.shared.start()
        }
        for (index, delta) in deltas.enumerated() {
            let (_, elapsed) = try watchdog.run("scroll \(index) by \(delta)") {
                // As the UI test's wheel: at the panel's middle, through the window.
                let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                  wheel1: Int32(delta), wheel2: 0, wheel3: 0))
                let point = window.convertPoint(toScreen: CGPoint(x: size.width * 0.5, y: size.height * 0.48))
                let primary = NSScreen.screens.first?.frame.height ?? 0
                event.location = CGPoint(x: point.x, y: primary - point.y)
                let before = list.contentView.bounds.minY
                window.sendEvent(try XCTUnwrap(NSEvent(cgEvent: event)))
                frame()
                if abs(list.contentView.bounds.minY - before) < 0.5 {
                    // An off-screen window may not route the wheel: move the
                    // clip view as the wheel would.
                    let target = min(max(before - delta, -list.contentView.contentInsets.top),
                                     max(-list.contentView.contentInsets.top,
                                         (list.documentView?.frame.height ?? 0) - list.contentView.bounds.height
                                             + list.contentView.contentInsets.bottom))
                    list.contentView.scroll(to: CGPoint(x: 0, y: target))
                    list.reflectScrolledClipView(list.contentView)
                }
                if stationaryHover {
                    try Self.hover(window: window, at: CGPoint(x: size.width * 0.5, y: size.height * 0.55), tracked: &tracked)
                }
                settle(1)
            }
            print("ATTIC_SCROLL_HANG step=\(index) delta=\(delta) seconds=\(elapsed) offset=\(list.contentView.bounds.minY)")
            XCTAssertLessThan(elapsed, 2, "scroll step \(index) (\(delta)) returns: reduceMotion \(reduceMotion)")
            // What failed on CI was XCUITest's snapshot after the step: the
            // whole accessibility tree, read on the main thread.
            let (count, snapshot) = watchdog.run("snapshot \(index)") { Self.axCount(window.contentView as Any, depth: 0) }
            print("ATTIC_SCROLL_HANG step=\(index) ax_elements=\(count) ax_seconds=\(snapshot)")
            XCTAssertGreaterThan(count, 20, "the snapshot must walk the real SwiftUI rows and controls")
            XCTAssertLessThan(snapshot, 2, "the accessibility snapshot after step \(index) returns: reduceMotion \(reduceMotion)")
            if stationaryHover {
                let first = TasksFoldLayoutProbe.shared.snapshot()
                let beforeHover = AtticTaskRow.hoverEvents.values.reduce(0, +)
                // Exercise repeated synthetic input while checking layout settles.
                // This off-screen host cannot establish whether AppKit itself
                // re-sends tracking events for a stationary physical pointer;
                // that claim belongs to the real UI runner on the Air.
                let hoverEnd = Date().addingTimeInterval(1)
                while Date() < hoverEnd {
                    try Self.hover(window: window, at: CGPoint(x: size.width * 0.5, y: size.height * 0.55), tracked: &tracked)
                    frame()
                }
                let last = TasksFoldLayoutProbe.shared.snapshot()
                let afterHover = AtticTaskRow.hoverEvents.values.reduce(0, +)
                print("ATTIC_SCROLL_HOVER step=\(index) sizes=\(last.heights.sorted { $0.value > $1.value }.prefix(10)) measure=\(first.measures)->\(last.measures) place=\(first.placements)->\(last.placements) hover=\(beforeHover)->\(afterHover) history=\(AtticTaskRow.hoverHistory.values.filter { !$0.isEmpty })")
                if index == 0 {
                    XCTAssertTrue(AtticTaskRow.hoverHistory.values.contains { $0.contains(true) },
                                  "the pointer reaches a real row after the list mounts tracking areas")
                    print("ATTIC_SCROLL_HOVER first opens=\(AtticTaskRow.drawsOpen) opener=\(model.services.openTaskNote != nil)")
                }
                XCTAssertLessThan(last.measures - first.measures, 100, "layout measurement must stop after scroll/hover settles")
                XCTAssertLessThan(last.placements - first.placements, 100, "row placement must stop after scroll/hover settles")
            }
        }
        if stationaryHover {
            // Positive control for the synthetic hover counters only.
            let beforeMoves = AtticTaskRow.hoverEvents.values.reduce(0, +)
            for move in 0..<12 {
                try Self.hover(window: window, at: CGPoint(x: size.width * 0.5, y: size.height * (move.isMultiple(of: 2) ? 0.35 : 0.75)),
                               tracked: &tracked)
                frame()
            }
            XCTAssertGreaterThan(AtticTaskRow.hoverEvents.values.reduce(0, +) - beforeMoves, 8,
                                 "positive control: crossing rows is counted as hover flips")
        }
    }

    /// The same tracking-area delivery used by TasksGoingInTests' hover
    /// regression. A hosted window is off screen; AppKit does not deliver
    /// physical mouse movement to it.
    private static func hover(window: NSWindow, at point: CGPoint, tracked: inout Set<ObjectIdentifier>) throws {
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let location = CGPoint(x: point.x, y: window.frame.height - point.y)
        let now = ProcessInfo.processInfo.systemUptime
        let windowNumber = window.windowNumber
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location,
            modifierFlags: [], timestamp: now, windowNumber: windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        for view in descendants(content) {
            for area in view.trackingAreas {
                guard let owner = area.owner as? NSResponder else { continue }
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                let inside = rect.contains(view.convert(location, from: nil))
                let key = ObjectIdentifier(area)
                func edge(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: now,
                        windowNumber: windowNumber, context: nil, eventNumber: 0,
                        trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil)
                }
                if inside, !tracked.contains(key), area.options.contains(.mouseEnteredAndExited), let event = edge(.mouseEntered) {
                    tracked.insert(key)
                    owner.mouseEntered(with: event)
                } else if !inside, tracked.contains(key), let event = edge(.mouseExited) {
                    tracked.remove(key)
                    owner.mouseExited(with: event)
                }
                if inside, area.options.contains(.mouseMoved) { owner.mouseMoved(with: moved) }
            }
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    /// Walks the accessibility tree as a snapshot does: every element's
    /// role, label, identifier, frame and children.
    private static func axCount(_ element: Any, depth: Int) -> Int {
        guard depth < 40 else { return 0 }
        let node = element as AnyObject
        _ = node.accessibilityRole?(); _ = node.accessibilityLabel?(); _ = node.accessibilityFrame?()
        _ = (node as? NSObject)?.perform(Selector(("accessibilityIdentifier")))
        return 1 + ((node.accessibilityChildren?() ?? nil) ?? []).reduce(0) { $0 + axCount($1, depth: depth + 1) }
    }

    private static func axFind(_ identifier: String, in element: Any, depth: Int) -> Bool {
        guard depth < 40 else { return false }
        let node = element as AnyObject
        if (node as? NSObject)?.perform(Selector(("accessibilityIdentifier")))?.takeUnretainedValue() as? String == identifier { return true }
        return ((node.accessibilityChildren?() ?? nil) ?? []).contains { axFind(identifier, in: $0, depth: depth + 1) }
    }
}
