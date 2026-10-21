#if DEBUG
import AppKit
import QuartzCore

/// The hide-animation bench: a UI-testing seam that hides and reveals the
/// panel on a signal, so window-only captures and the smoothness runs can
/// drive the hide animations hands-off. Debug builds of preview identities
/// only; never compiled into Release.
///
/// - `ATTIC_MOTION_BENCH=1`: SIGUSR1 toggles (hide when shown, reveal when
///   hidden); SIGUSR2 interrupts (starts the toggle, then reverses it after
///   `ATTIC_MOTION_BENCH_INTERRUPT_MS`, default 100 ms).
/// - `ATTIC_MOTION_BENCH_PREPARE=1`: each toggle first announces itself as a
///   timed hide or reveal does (the pointer has left, or rests in the
///   corner), then runs `ATTIC_MOTION_BENCH_PREPARE_MS` later (default 300).
/// - SIGURG records a swipe (driven from outside by synthetic trackpad
///   events): 1.4 s of frames, and what starting the animation cost.
/// - `ATTIC_MOTION_BENCH_MODE=slide|swoop|genieLiveGlass|genie` picks the
///   animation at launch (`AppCoordinator`).
/// Each motion appends one JSON line to `<container tmp>/motion-bench.jsonl`:
/// the main-thread display-link frame gaps over the motion's window, and
/// when the motion reported completion.
@MainActor
final class PanelHideMotionBench: NSObject {
    private let isVisible: () -> Bool
    private let hide: (@escaping () -> Void) -> Void
    private let reveal: () -> Void
    private let mode: () -> String
    private let prepare: ((Bool, TimeInterval) -> Void)?
    var acceptsInput: () -> Bool = { false }
    /// The last animation start's cost (snapshot and live-material set-up, ms).
    var beginCost: () -> Double = { 0 }
    /// SIGINFO: a one-off probe's result, written as its own line.
    var info: () -> [String: Any] = { [:] }
    /// Anything else worth a line (the snapshot's own costs).
    var trace: () -> [String: Any] = { [:] }
    private var window: CFTimeInterval = 0.6
    private var sources: [any DispatchSourceSignal] = []
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var record: [String: Any] = [:]
    private var started: CFTimeInterval = 0
    private let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("motion-bench.jsonl")

    private init(isVisible: @escaping () -> Bool, hide: @escaping (@escaping () -> Void) -> Void,
                 reveal: @escaping () -> Void, mode: @escaping () -> String,
                 prepare: ((Bool, TimeInterval) -> Void)?) {
        self.isVisible = isVisible
        self.hide = hide
        self.reveal = reveal
        self.mode = mode
        self.prepare = prepare
        super.init()
    }

    static func installIfRequested(
        isVisible: @escaping () -> Bool, hide: @escaping (@escaping () -> Void) -> Void,
        reveal: @escaping () -> Void, mode: @escaping () -> String,
        prepare: ((Bool, TimeInterval) -> Void)? = nil
    ) -> PanelHideMotionBench? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ATTIC_MOTION_BENCH"] == "1",
              Bundle.main.bundleIdentifier?.hasPrefix("com.taha.Attic.preview.") == true else { return nil }
        let prepares = environment["ATTIC_MOTION_BENCH_PREPARE"] == "1"
        let bench = PanelHideMotionBench(isVisible: isVisible, hide: hide, reveal: reveal, mode: mode,
                                         prepare: prepares ? prepare : nil)
        bench.listen(SIGUSR1) { bench.toggle(interrupt: false) }
        bench.listen(SIGUSR2) { bench.toggle(interrupt: true) }
        bench.listen(SIGURG) { bench.begin(kind: "swipe", window: 1.4) }
        bench.listen(SIGINFO) { bench.writeInfo() }
        return bench
    }

    private func listen(_ number: Int32, _ handler: @escaping @MainActor () -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.resume()
        sources.append(source)
    }

    private func toggle(interrupt: Bool) {
        let hiding = isVisible()
        guard let prepare else { run(hiding: hiding, interrupt: interrupt); return }
        let delay = (Double(ProcessInfo.processInfo.environment["ATTIC_MOTION_BENCH_PREPARE_MS"] ?? "300") ?? 300) / 1000
        prepare(hiding, delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.run(hiding: hiding, interrupt: interrupt)
        }
    }

    private func run(hiding: Bool, interrupt: Bool) {
        begin(kind: (hiding ? "hide" : "show") + (interrupt ? "_interrupted" : ""))
        record["prepared"] = prepare != nil
        if hiding {
            hide { [weak self] in self?.mark("hide_completed") }
        } else {
            reveal()
            // Input from the reveal's first frames (Slide waits for its end).
            for ms in [20.0, 60.0, 120.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { [weak self] in
                    guard let self else { return }
                    self.record["accepts_input_\(Int(ms))ms"] = self.acceptsInput()
                }
            }
        }
        guard interrupt else { return }
        let delay = Double(ProcessInfo.processInfo.environment["ATTIC_MOTION_BENCH_INTERRUPT_MS"] ?? "100") ?? 100
        DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000) { [weak self] in
            guard let self else { return }
            self.mark("reversed")
            if hiding { self.reveal() } else { self.hide { [weak self] in self?.mark("hide_completed") } }
        }
    }

    private func writeInfo() {
        finish()
        record = info()
        record["kind"] = "info"
        stamps = []
        link = nil
        append()
    }

    private func begin(kind: String, window: CFTimeInterval = 0.6) {
        finish()
        self.window = window
        started = CACurrentMediaTime()
        stamps = []
        record = ["kind": kind, "mode": mode(), "wall": Date().timeIntervalSince1970]
        guard let screen = NSScreen.main else { return }
        let made = screen.displayLink(target: self, selector: #selector(tick(_:)))
        made.add(to: .main, forMode: .common)
        link = made
    }

    private func mark(_ name: String) {
        record[name + "_ms"] = (CACurrentMediaTime() - started) * 1000
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        if CACurrentMediaTime() - started > window { finish() }
    }

    private func finish() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        record["gaps_ms"] = gaps.map { ($0 * 100).rounded() / 100 }
        record["visible_after"] = isVisible()
        record["begin_ms"] = beginCost()
        for (key, value) in trace() { record[key] = value }
        append()
    }

    private func append() {
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: output) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: output)
        }
    }
}
#endif

#if DEBUG
/// A probe: can the app read its own panel window's composited pixels
/// (glass, in-window blurs and all) from the window server without Screen
/// Recording? `CGWindowListCreateImage` is out of the SDK but still exported.
@MainActor
enum PanelWindowCaptureProbe {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func run(window: NSWindow) -> [String: Any] {
        var result: [String: Any] = ["preflight": CGPreflightScreenCaptureAccess()]
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else {
            result["symbol"] = false
            return result
        }
        result["symbol"] = true
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow = 8; image options: bounds
        // ignore framing (1) | best resolution (8).
        for (name, options) in [("best", UInt32(1 | 8)), ("nominal", UInt32(1 | 16))] {
            let began = CACurrentMediaTime()
            let image = create(.null, 8, UInt32(window.windowNumber), options)?.takeRetainedValue()
            result["\(name)_ms"] = (CACurrentMediaTime() - began) * 1000
            guard let image else { result["\(name)"] = "nil"; continue }
            result["\(name)"] = "\(image.width)x\(image.height)"
            // How much of it is lit (an empty or desktop-only image is not).
            if let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
                let count = CFDataGetLength(data), stride = max(4, image.bitsPerPixel / 8)
                var lit = 0, total = 0
                var offset = 0
                while offset + stride <= count { if bytes[offset + 3] > 10 { lit += 1 }; total += 1; offset += stride * 97 }
                result["\(name)_lit"] = Double(lit) / Double(max(1, total))
            }
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capture-\(name).png")
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        return result
    }
}
#endif
