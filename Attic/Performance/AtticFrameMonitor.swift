import AppKit
import QuartzCore
import CoreFoundation

#if DEBUG
/// Preview builds only (round 11): with `ATTIC_FRAME_MONITOR=1` a display
/// link on the main screen logs every frame the main thread saw to
/// standard output (`ATTIC_FRAME <uptime> <gap ms>`), so an on-screen run
/// driven by synthetic input can be judged frame by frame, before and
/// after a change, without Instruments' hitch template. A frame whose gap
/// is more than one refresh is a frame the main thread missed. Nothing
/// runs without the variable.
@MainActor
final class AtticFrameMonitor: NSObject {
    private static var shared: AtticFrameMonitor?
    private var link: CADisplayLink?
    private var last: CFTimeInterval?

    static func startIfRequested() {
        guard ProcessInfo.processInfo.environment["ATTIC_FRAME_MONITOR"] == "1", shared == nil,
              let screen = NSScreen.main else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let monitor = AtticFrameMonitor()
        let link = screen.displayLink(target: monitor, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        monitor.link = link
        shared = monitor
        print("ATTIC_FRAME_START \(CACurrentMediaTime()) refresh=\(screen.maximumFramesPerSecond)")
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        if let last {
            print(String(format: "ATTIC_FRAME %.4f %.2f", now, (now - last) * 1_000))
        }
        last = now
    }
}
#endif

#if DEBUG

/// CI-only evidence for the Dark Glass stationary-hover scroll hang. In normal
/// launches the only cost at a call site is checking the nil singleton.
/// The watchdog never reads SwiftUI or main-actor state from its queue.
///
/// Observe, never perturb: this type only reads clocks and run-loop phases,
/// formats details outside its lock, and writes files from its own queue.
final class AtticHangProbe: @unchecked Sendable {
    /// Test seam: a hosted test installs an instance to exercise the armed paths.
    nonisolated(unsafe) static var testInstance: AtticHangProbe?
    private static let environmentInstance: AtticHangProbe? = {
        let environment = ProcessInfo.processInfo.environment
        guard let url = outputURL(environment: environment, temporaryDirectory: NSTemporaryDirectory())
        else { return nil }
        return AtticHangProbe(outputURL: url)
    }()

    static var shared: AtticHangProbe? { testInstance ?? environmentInstance }

    static var isEnabled: Bool { shared != nil }

    /// `ATTIC_HANG_PROBE_PATH` is an absolute file path. A sandboxed (signed)
    /// app cannot write to the UI runner's temporary folder, so a UI test names
    /// only a leaf in `ATTIC_HANG_PROBE_FILE`: it lives in the app's own
    /// temporary folder, which the runner finds from the app's bundle
    /// identifier (the same pattern as AtticGrowTrace's log).
    static func outputURL(environment: [String: String], temporaryDirectory: String) -> URL? {
        if let path = environment["ATTIC_HANG_PROBE_PATH"], path.hasPrefix("/"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard let leaf = environment["ATTIC_HANG_PROBE_FILE"], !leaf.isEmpty, leaf.count <= 128,
              leaf.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }),
              !leaf.hasPrefix(".") else { return nil }
        return URL(fileURLWithPath: temporaryDirectory, isDirectory: true).appendingPathComponent(leaf)
    }

    static func startIfRequested() { shared?.start() }

    /// Fold rows pass this key even in production view construction. Defer
    /// UUID formatting until an opted-in CI probe actually needs it.
    static func key(_ value: @autoclosure () -> String) -> String {
        guard shared != nil else { return "" }
        return value()
    }

    /// Value and detail are evaluated only if a test opted in. Every distinct
    /// value is retained with its predecessor; identical hot-path calls are
    /// counted and sampled, preventing a measurement storm from burying flips.
    static func note(_ kind: String, key: @autoclosure () -> String,
                     value: @autoclosure () -> String,
                     detail: @autoclosure () -> String = "") {
        guard let shared else { return }
        shared.record(kind, key: key(), value: value(), detail: detail)
    }

    private struct Event {
        let millis: UInt64
        let description: String
    }

    private struct Snapshot {
        let trigger: String
        let now: UInt64
        let elapsed: UInt64
        let turns: UInt64
        let healthyWaits: UInt64
        let lastCompletedTurn: UInt64
        let lastRealWait: UInt64
        let events: [Event]
        let totals: [String: Int]
        let changes: [String: Int]
        let lastValues: [String: String]
    }

    /// A run loop that has not gone to sleep for this long is stalled.
    private let stallNanos: UInt64 = 3_000_000_000
    /// Upper bound for the wait that counts as meaningful sleep. The actual
    /// threshold also scales with work done in the preceding turn, so a 120 Hz
    /// frame with a genuine 0.7 ms wait cannot be mistaken for a busy loop.
    private let realWaitNanos: UInt64
    private let dumpIntervalNanos: UInt64 = 2_000_000_000

    private let outputURL: URL
    private let clock: @Sendable () -> UInt64
    private let lock = NSLock()
    private let startNanos: UInt64
    private var events: [Event?] = Array(repeating: nil, count: 16_384)
    private var nextEvent = 0
    private var eventCount = 0
    private var totals: [String: Int] = [:]
    private var changes: [String: Int] = [:]
    private var lastValues: [String: String] = [:]
    private var sleeping = false
    private var waitStarted: UInt64
    private var lastWake: UInt64?
    private var lastBusyNanos: UInt64?
    private var lastCompletedTurn: UInt64
    private var lastRealWait: UInt64
    private var turns: UInt64 = 0
    /// Counts real waits. It is written into every dump: a reader that sees it
    /// change knows the run loop slept in between, so the stall was not continuous.
    private var healthyWaits: UInt64 = 0
    private var lastDump: UInt64?
    private var lastDumpHealthyWaits: UInt64 = 0
    /// Only read on the watchdog's serial queue, never on the main run loop.
    private var savedFirstHang = false
    private var recoveredAfterFirstHang = false
    private var savedFollowingHang = false
    private var observer: CFRunLoopObserver?
    private var watchdog: DispatchSourceTimer?

    init(outputURL: URL,
         realWaitNanos: UInt64 = 1_000_000,
         clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.outputURL = outputURL
        self.clock = clock
        self.realWaitNanos = realWaitNanos
        let start = clock()
        startNanos = start
        waitStarted = start
        lastCompletedTurn = start
        lastRealWait = start
    }

    private func start() {
        precondition(Thread.isMainThread)
        guard observer == nil else { return }
        // Sleep and wake are `beforeWaiting` and `afterWaiting` only. AppKit
        // dispatches events between the loop's exit and its next entry, so a
        // spin inside event handling must still count as busy.
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        guard let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true,
                                                               CFIndex(Int32.max), { [weak self] _, activity in
            self?.runLoop(activity)
        }) else { return }
        self.observer = observer
        // `start` runs inside a main run-loop turn: awake, not waiting.
        lock.withLock {
            let now = clock()
            sleeping = false
            lastCompletedTurn = now
            lastRealWait = now
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)

        let queue = DispatchQueue(label: "attic.ci.hang-probe", qos: .utility)
        queue.async { [self] in write("ARMED: main-run-loop watchdog, 3s threshold\n") }
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + .seconds(1), repeating: .milliseconds(250))
        watchdog.setEventHandler { [weak self] in self?.checkForHang() }
        watchdog.resume()
        self.watchdog = watchdog
    }

    /// A non-negative age that never underflows, however the readings interleave.
    private static func age(_ now: UInt64, since earlier: UInt64) -> UInt64 {
        now >= earlier ? now - earlier : 0
    }

    func runLoop(_ activity: CFRunLoopActivity) {
        lock.withLock {
            // Read inside the lock, after the state compared against it.
            let now = clock()
            switch activity {
            case .afterWaiting:
                // Compare with the preceding busy interval, rather than a
                // fixed millisecond: a healthy shorter frame has shorter
                // sleeps as well. A near-immediate wake after a long busy
                // interval remains distinguishable from real idle time.
                let requiredWait = lastBusyNanos.map { min(realWaitNanos, max(1, $0 / 16)) }
                    ?? realWaitNanos
                if sleeping, Self.age(now, since: waitStarted) >= requiredWait {
                    lastRealWait = now
                    healthyWaits &+= 1
                }
                sleeping = false
                lastWake = now
                turns &+= 1
            case .beforeWaiting:
                if let lastWake { lastBusyNanos = Self.age(now, since: lastWake) }
                sleeping = true
                waitStarted = now
                lastCompletedTurn = now
            default: break
            }
        }
    }

    private func record(_ kind: String, key: String, value: String, detail: () -> String) {
        let identity = "\(kind)[\(key)]"
        let (previous, wantsEvent): (String?, Bool) = lock.withLock {
            let count = totals[identity, default: 0] + 1
            totals[identity] = count
            let previous = lastValues[identity]
            if previous != value {
                changes[identity, default: 0] += 1
                lastValues[identity] = value
            }
            return (previous, previous != value || count.isMultiple(of: 128))
        }
        guard wantsEvent else { return }
        // Format outside the lock: a slow detail must never lengthen the
        // transaction the run loop and the watchdog share.
        let description = "\(identity) \(previous ?? "<first>") -> \(value) \(detail())"
        lock.withLock {
            let now = clock()
            events[nextEvent] = Event(millis: Self.age(now, since: startNanos) / 1_000_000, description: description)
            nextEvent = (nextEvent + 1) % events.count
            eventCount = min(events.count, eventCount + 1)
        }
    }

    /// Test seam: whether the shared lock is free right now. A `detail` closure
    /// evaluated inside the lock sees `false` (NSLock is not recursive).
    var lockIsFree: Bool {
        guard lock.try() else { return false }
        lock.unlock()
        return true
    }

    /// Test seam: how often `note` was called for a kind and key.
    func callCount(kind: String, key: String) -> Int {
        lock.withLock { totals["\(kind)[\(key)]", default: 0] }
    }

    func checkForHang() {
        var recoveredWaits: UInt64?
        let snapshot: Snapshot? = lock.withLock {
            // Read inside the lock, after the run-loop state it is compared with.
            let now = clock()
            // Retire a published HANG as soon as a real wait is observed.
            // Otherwise a fresh, stale dump could bridge two separate bursts
            // while the second is still below the three-second dump threshold.
            if lastDump != nil,
               healthyWaits != lastDumpHealthyWaits ||
                (sleeping && Self.age(now, since: waitStarted) >= realWaitNanos) {
                recoveredWaits = healthyWaits
                lastDump = nil
            }
            // A sleeping run loop is healthy, however old its last turn.
            guard !sleeping else { return nil }
            let noTurn = Self.age(now, since: lastCompletedTurn) > stallNanos
            // Some layout livelocks finish individual turns but wake again
            // immediately. A genuine wait resets this second detector.
            let noRealWait = Self.age(now, since: lastRealWait) > stallNanos && turns > 1
            guard noTurn || noRealWait else { return nil }
            if let lastDump, Self.age(now, since: lastDump) <= dumpIntervalNanos { return nil }
            lastDump = now
            lastDumpHealthyWaits = healthyWaits
            let trigger = noTurn ? "unfinished-run-loop-turn" : "no-genuine-wait"
            let ordered = (0..<eventCount).compactMap { offset -> Event? in
                let index = (nextEvent - eventCount + offset + events.count) % events.count
                return events[index]
            }
            // Copy while holding the lock, then sort and format off-thread:
            // the diagnostic must never lengthen a hot layout transaction.
            return Snapshot(trigger: trigger, now: now, elapsed: Self.age(now, since: startNanos) / 1_000_000,
                            turns: turns, healthyWaits: healthyWaits, lastCompletedTurn: lastCompletedTurn,
                            lastRealWait: lastRealWait, events: ordered.suffix(4_000).map { $0 },
                            totals: totals, changes: changes, lastValues: lastValues)
        }
        if let recoveredWaits {
            if savedFirstHang { recoveredAfterFirstHang = true }
            write("HEALTHY: main run loop waited, healthy-waits=\(recoveredWaits)\n")
        }
        guard let snapshot else { return }
        let leaders = snapshot.totals.keys.sorted { left, right in
            let a = snapshot.changes[left, default: 0], b = snapshot.changes[right, default: 0]
            return a == b ? snapshot.totals[left, default: 0] > snapshot.totals[right, default: 0] : a > b
        }
        let turnAge = Self.age(snapshot.now, since: snapshot.lastCompletedTurn) / 1_000_000
        let waitAge = Self.age(snapshot.now, since: snapshot.lastRealWait) / 1_000_000
        var lines = ["HANG: \(snapshot.trigger), elapsed=\(snapshot.elapsed)ms, turns=\(snapshot.turns), healthy-waits=\(snapshot.healthyWaits)",
                     "last-turn=\(turnAge)ms ago; last-real-wait=\(waitAge)ms ago",
                     "METRICS (changes / calls / last value; \(leaders.count) keys):"]
        lines += leaders.prefix(300).map { "\(snapshot.changes[$0, default: 0]) / \(snapshot.totals[$0, default: 0]) \($0): \(snapshot.lastValues[$0] ?? "")" }
        lines += ["EVENTS (monotonic milliseconds, oldest first):"]
        lines += snapshot.events.map { "\($0.millis) \($0.description)" }
        let dump = lines.joined(separator: "\n") + "\n"
        // The first snapshot preserves the earliest flip; the main path is
        // refreshed with the latest state if the hang continues for minutes.
        if !savedFirstHang {
            write(dump, to: URL(fileURLWithPath: outputURL.path + ".first"))
            savedFirstHang = true
        } else if recoveredAfterFirstHang && !savedFollowingHang {
            // Preserve the first new onset after launch recovered, even when
            // thousands of later callbacks rotate out of the latest ring.
            write(dump, to: URL(fileURLWithPath: outputURL.path + ".after-first"))
            savedFollowingHang = true
        }
        write(dump)
    }

    private func write(_ content: String) {
        write(content, to: outputURL)
    }

    private func write(_ content: String, to url: URL) {
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            NSLog("Attic hang probe could not write diagnostic: %@", error.localizedDescription)
        }
    }
}
#endif
