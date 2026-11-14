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
final class AtticHangProbe: @unchecked Sendable {
    static let shared: AtticHangProbe? = {
        guard let path = ProcessInfo.processInfo.environment["ATTIC_HANG_PROBE_PATH"],
              path.hasPrefix("/"), !path.isEmpty else { return nil }
        return AtticHangProbe(outputURL: URL(fileURLWithPath: path))
    }()

    static var isEnabled: Bool { shared != nil }

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
        let elapsed: UInt64
        let turns: UInt64
        let lastCompletedTurn: UInt64
        let lastRealWait: UInt64
        let events: [Event]
        let totals: [String: Int]
        let changes: [String: Int]
        let lastValues: [String: String]
    }

    private let outputURL: URL
    private let lock = NSLock()
    private let startNanos = DispatchTime.now().uptimeNanoseconds
    private var events: [Event?] = Array(repeating: nil, count: 16_384)
    private var nextEvent = 0
    private var eventCount = 0
    private var totals: [String: Int] = [:]
    private var changes: [String: Int] = [:]
    private var lastValues: [String: String] = [:]
    private var sleeping = true
    private var waitStarted: UInt64
    private var lastCompletedTurn: UInt64
    private var lastRealWait: UInt64
    private var turns: UInt64 = 0
    private var lastDump: UInt64 = 0
    /// Only read on the watchdog's serial queue, never on the main run loop.
    private var savedFirstHang = false
    private var observer: CFRunLoopObserver?
    private var watchdog: DispatchSourceTimer?

    init(outputURL: URL) {
        self.outputURL = outputURL
        waitStarted = startNanos
        lastCompletedTurn = startNanos
        lastRealWait = startNanos
    }

    private func start() {
        precondition(Thread.isMainThread)
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        guard let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true,
                                                               CFIndex(Int32.max), { [weak self] _, activity in
            self?.runLoop(activity)
        }) else { return }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)

        let queue = DispatchQueue(label: "attic.ci.hang-probe", qos: .utility)
        queue.async { [self] in write("ARMED: main-run-loop watchdog, 3s threshold\n") }
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + .seconds(1), repeating: .milliseconds(250))
        watchdog.setEventHandler { [weak self] in self?.checkForHang() }
        watchdog.resume()
        self.watchdog = watchdog
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            switch activity {
            case .afterWaiting, .entry:
                if sleeping, now >= waitStarted + 8_000_000 { lastRealWait = now }
                sleeping = false
                turns &+= 1
            case .beforeWaiting, .exit:
                sleeping = true
                waitStarted = now
                lastCompletedTurn = now
            default: break
            }
        }
    }

    private func record(_ kind: String, key: String, value: String, detail: () -> String) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            let identity = "\(kind)[\(key)]"
            let count = totals[identity, default: 0] + 1
            totals[identity] = count
            let previous = lastValues[identity]
            if previous != value {
                changes[identity, default: 0] += 1
                lastValues[identity] = value
            }
            guard previous != value || count.isMultiple(of: 128) else { return }
            events[nextEvent] = Event(millis: (now - startNanos) / 1_000_000,
                                      description: "\(identity) \(previous ?? "<first>") -> \(value) \(detail())")
            nextEvent = (nextEvent + 1) % events.count
            eventCount = min(events.count, eventCount + 1)
        }
    }

    private func checkForHang() {
        let now = DispatchTime.now().uptimeNanoseconds
        let snapshot: Snapshot? = lock.withLock {
            // A sleeping run loop is healthy, however old its last turn.
            guard !sleeping else { return nil }
            let noTurn = now > lastCompletedTurn + 3_000_000_000
            // Some layout livelocks finish individual turns but wake again
            // immediately. A genuine >=8ms wait resets this second detector.
            let noRealWait = now > lastRealWait + 3_000_000_000 && turns > 1
            guard noTurn || noRealWait, now > lastDump + 2_000_000_000 else { return nil }
            lastDump = now
            let trigger = noTurn ? "unfinished-run-loop-turn" : "no-genuine-wait"
            let ordered = (0..<eventCount).compactMap { offset -> Event? in
                let index = (nextEvent - eventCount + offset + events.count) % events.count
                return events[index]
            }
            // Copy while holding the lock, then sort and format off-thread:
            // the diagnostic must never lengthen a hot layout transaction.
            return Snapshot(trigger: trigger, elapsed: (now - startNanos) / 1_000_000,
                            turns: turns, lastCompletedTurn: lastCompletedTurn,
                            lastRealWait: lastRealWait, events: ordered.suffix(4_000).map { $0 },
                            totals: totals, changes: changes, lastValues: lastValues)
        }
        guard let snapshot else { return }
        let leaders = snapshot.totals.keys.sorted { left, right in
            let a = snapshot.changes[left, default: 0], b = snapshot.changes[right, default: 0]
            return a == b ? snapshot.totals[left, default: 0] > snapshot.totals[right, default: 0] : a > b
        }
        var lines = ["HANG: \(snapshot.trigger), elapsed=\(snapshot.elapsed)ms, turns=\(snapshot.turns)",
                     "last-turn=\((now - snapshot.lastCompletedTurn) / 1_000_000)ms ago; last-real-wait=\((now - snapshot.lastRealWait) / 1_000_000)ms ago",
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
