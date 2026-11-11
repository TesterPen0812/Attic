import AppKit
import QuartzCore

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

/// Preview-only first incoming-frame boundary. The timestamp is the first
/// main-screen display-link callback after the new page reports its hosted
/// view ready, with Core Animation flushed on that tick. It measures a
/// committed frame opportunity; it does not claim display scan-out.
@MainActor
final class PanelColdFirstFrameProbe: NSObject {
    private static var active: PanelColdFirstFrameProbe?
    private static let enabled = ProcessInfo.processInfo.environment["ATTIC_COLD_PAINT_PROBE"] == "1"

    private let destination: PanelPage
    private let trigger: CFTimeInterval
    private var ready: CFTimeInterval?
    private var link: CADisplayLink?

    private init(destination: PanelPage, trigger: CFTimeInterval) {
        self.destination = destination
        self.trigger = trigger
    }

    static func switchTriggered(to destination: PanelPage) {
        guard enabled else { return }
        active?.link?.invalidate()
        active = PanelColdFirstFrameProbe(destination: destination, trigger: CACurrentMediaTime())
    }

    static func pageReady(_ page: PanelPage) {
        guard let active, active.destination == page, active.ready == nil,
              let screen = NSScreen.main else { return }
        active.ready = CACurrentMediaTime()
        let link = screen.displayLink(target: active, selector: #selector(frame(_:)))
        active.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let ready else { return }
        CATransaction.flush()
        let tick = CACurrentMediaTime()
        print(String(format: "ATTIC_COLD_FIRST_FRAME %@ %.6f %.3f %.3f",
                     destination.rawValue, tick, (tick - trigger) * 1_000, (tick - ready) * 1_000))
        link.invalidate()
        self.link = nil
        Self.active = nil
    }
}
#endif
