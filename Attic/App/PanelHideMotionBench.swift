import AppKit
import QuartzCore

/// Experimental (phase-x/genie): a UI-testing seam that hides and reveals
/// the panel on a signal, so window-only captures and the smoothness runs
/// can drive the three hide animations hands-off. Preview identities only.
///
/// - `ATTIC_GENIE_SIGNALS=1`: SIGUSR1 toggles (hide when shown, reveal when
///   hidden); SIGUSR2 interrupts (starts the toggle, then reverses it after
///   `ATTIC_GENIE_INTERRUPT_MS`, default 100 ms).
/// - SIGURG records a swipe (driven from outside by synthetic trackpad
///   events): 1.4 s of frames, and what starting the draft cost.
/// - `ATTIC_GENIE_MODE=slide|genie|swoop|genieLiveGlass` picks the animation at launch.
/// Each motion appends one JSON line to `<container tmp>/genie-bench.jsonl`:
/// the main-thread display-link frame gaps over the motion's window, and
/// when the motion reported completion.
@MainActor
final class PanelHideMotionBench: NSObject {
    private let isVisible: () -> Bool
    private let hide: (@escaping () -> Void) -> Void
    private let reveal: () -> Void
    private let mode: () -> String
    var acceptsInput: () -> Bool = { false }
    /// The last draft start's cost (snapshot and live-glass set-up, ms).
    var beginCost: () -> Double = { 0 }
    private var window: CFTimeInterval = 0.6
    private var sources: [any DispatchSourceSignal] = []
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var record: [String: Any] = [:]
    private var started: CFTimeInterval = 0
    private let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("genie-bench.jsonl")

    init(isVisible: @escaping () -> Bool, hide: @escaping (@escaping () -> Void) -> Void,
         reveal: @escaping () -> Void, mode: @escaping () -> String) {
        self.isVisible = isVisible
        self.hide = hide
        self.reveal = reveal
        self.mode = mode
        super.init()
    }

    static func installIfRequested(
        isVisible: @escaping () -> Bool, hide: @escaping (@escaping () -> Void) -> Void,
        reveal: @escaping () -> Void, mode: @escaping () -> String
    ) -> PanelHideMotionBench? {
        guard ProcessInfo.processInfo.environment["ATTIC_GENIE_SIGNALS"] == "1",
              Bundle.main.bundleIdentifier?.hasPrefix("com.taha.Attic.preview.") == true else { return nil }
        let bench = PanelHideMotionBench(isVisible: isVisible, hide: hide, reveal: reveal, mode: mode)
        bench.listen(SIGUSR1) { bench.toggle(interrupt: false) }
        bench.listen(SIGUSR2) { bench.toggle(interrupt: true) }
        bench.listen(SIGURG) { bench.begin(kind: "swipe", window: 1.4) }
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
        begin(kind: (hiding ? "hide" : "show") + (interrupt ? "_interrupted" : ""))
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
        let delay = Double(ProcessInfo.processInfo.environment["ATTIC_GENIE_INTERRUPT_MS"] ?? "100") ?? 100
        DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000) { [weak self] in
            guard let self else { return }
            self.mark("reversed")
            if hiding { self.reveal() } else { self.hide { [weak self] in self?.mark("hide_completed") } }
        }
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
        if let mode = (record["mode"] as? String).flatMap(PanelHideAnimation.init(rawValue:)), mode.usesGenieMesh {
            record["snapshot_ms"] = PanelGenieView.lastSnapshotMilliseconds
            record["mask_us"] = PanelGenieLiveGlassView.lastMaskMicroseconds
            record["material_layers"] = PanelGenieView.lastMaterialLayers
            record["glass_standins"] = PanelGenieView.lastGlassStandIns
            record["glass_left_out"] = PanelGenieView.lastGlassLeftOut
        }
        record["begin_ms"] = beginCost()
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
