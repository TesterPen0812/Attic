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
#endif
