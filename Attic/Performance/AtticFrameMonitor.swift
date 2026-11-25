import AppKit
import QuartzCore

#if DEBUG || ATTIC_MEASURE
/// SCRATCH stamps and knockouts (scroll takeover; page host P-cal, 25 Nov). RZK = comma list: who, nocons, noroot,
/// nohidden / nohcal / nohnotes / nohcanvas / nohtasks (that hidden page unmounted), nopcal (Calendar not in its own host: arm B).
enum RZS {
    nonisolated(unsafe) static var sw = 0, hl = 0, kl = 0, ku = 0, ev = 0, sb = 0, pl = 0, pu = 0, pg = 0
    nonisolated(unsafe) static var plNs: UInt64 = 0
    static func hides(_ page: String) -> Bool { k.contains("nohidden") || k.contains("noh" + (page == "calendar" ? "cal" : page)) }
    static let noPageHost = k.contains("nopcal")
    /// The page that became current, when, and who held the keyboard then (the switch driver's positive check).
    @MainActor static func pageStamp(_ page: String) {
        let fr = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nokey"
        print(String(format: "RZPAGE %.4f ", CACurrentMediaTime()) + "\(page) fr=\(fr)")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) {
            MainActor.assumeIsolated {
                let window = NSApp.keyWindow
                let responder = window?.firstResponder
                var host = "none"
                if let view = responder as? NSView,
                   let kept = (view as? KeptContentHostingView) ?? KeptContentHostingView.enclosing(view) {
                    host = (kept.rzPageHost ? "page" : "tab") + "(interactive=\(kept.isInteractive))"
                }
                let fr = responder.map { String(describing: type(of: $0)) } ?? "nil"
                print(String(format: "RZKB %.4f ", CACurrentMediaTime()) + "\(page) key=\(window != nil) fr=\(fr) host=\(host)")
            }
        }
    }
    static let hiddenChangeMs = Int(ProcessInfo.processInfo.environment["RZ_HIDDEN_CHANGE_MS"] ?? "")
    nonisolated(unsafe) static var hiddenChanges = 0
    @MainActor static func calendarHidden(_ store: TaskStore) {
        guard let ms = hiddenChangeMs else { return }
        hiddenChanges += 1
        let n = hiddenChanges
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak store] in
            MainActor.assumeIsolated {
                let draft = TaskDraft(title: "rzprobe \(n)", dueDay: DueDay(date: Date(), calendar: .current))
                let ok = store?.commandLibrary?.createTasks([draft]) != nil
                print(String(format: "RZCHANGE %.4f ", CACurrentMediaTime()) + "n=\(n) ok=\(ok)")
            }
        }
    }
    nonisolated(unsafe) static var hlNs: UInt64 = 0, klNs: UInt64 = 0, evNs: UInt64 = 0
    nonisolated(unsafe) static var last = ""
    nonisolated(unsafe) static var hi = 0, hiNs: UInt64 = 0
    static let k = Set((ProcessInfo.processInfo.environment["RZK"] ?? "").split(separator: ",").map(String.init))
    @inline(__always) static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    nonisolated(unsafe) static var who: [String: Int] = [:], nl = 0, idle = 0, lastEv = 0
    static let wantsWho = k.contains("who"), noCons = k.contains("nocons"), noRoot = k.contains("noroot")
    nonisolated(unsafe) static var inKept = 0, inRoot = 0, sc = 0, kn = 0, dropped = 0
    static func noteInvalidate(_ host: String) {
        if host == "root" { nl += 1 } else { kn += 1 }
        guard wantsWho else { return }
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(34).map { s -> String in
            let parts = s.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            return parts.count > 3 ? (parts[3].components(separatedBy: " + ").first ?? "").replacingOccurrences(of: "|", with: "/") : s
        }.joined(separator: "|")
        who[host + (inKept > 0 ? "@keptlayout" : inRoot > 0 ? "@rootlayout" : "@outside") + " :: " + stack, default: 0] += 1
    }
    static func flush(_ t: CFTimeInterval) {
        if wantsWho {
            if sc == lastEv { idle += 1 } else { idle = 0; lastEv = sc }
            if idle == 60, !who.isEmpty {
                for (key, n) in who.sorted(by: { $0.value > $1.value }).prefix(24) { print("RZWHO \(n) \(key)") }
                who = [:]
            }
        }
        let line = "ev=\(ev) sw=\(sw) sb=\(sb) hl=\(hl) kl=\(kl) ku=\(ku) evms=\(evNs / 1_000_000) hlms=\(hlNs / 1_000_000) klms=\(klNs / 1_000_000) hi=\(hi) hims=\(hiNs / 1_000_000) nl=\(nl) sc=\(sc) kn=\(kn) drop=\(dropped) pl=\(pl) plms=\(plNs / 1_000_000) pu=\(pu) pg=\(pg) pcal=\(noPageHost ? 0 : 1)"
        guard line != last else { return }
        last = line
        print(String(format: "RZS %.4f ", t) + line)
    }
}
/// Preview and measure builds only (round 11): with `ATTIC_FRAME_MONITOR=1` a display
/// link on the main screen logs every frame the main thread saw to
/// standard output (`ATTIC_FRAME <uptime> <gap ms>`), so an on-screen run
/// driven by synthetic input can be judged frame by frame, before and
/// after a change, without Instruments' hitch template. A frame whose gap
/// is more than one refresh is a frame the main thread missed. Nothing
/// runs without the variable, which is read only in `startIfRequested`.
@MainActor
final class AtticFrameMonitor: NSObject {
    private static var shared: AtticFrameMonitor?
    private var link: CADisplayLink?
    private var last: CFTimeInterval?

    static var isRunning: Bool { shared != nil }

    static func startIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["ATTIC_FRAME_MONITOR"] == "1", shared == nil,
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
        RZS.flush(now)
    }
}
#endif
