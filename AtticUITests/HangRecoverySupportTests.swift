import CoreGraphics
import XCTest

/// The decisions behind ScrollEdgeUITests' hang recovery, with a fake clock,
/// fake window lists and injected failures. No app is launched and nothing is
/// scrolled, so these run in any UI lane in a fraction of a second.
final class HangRecoverySupportTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    private func hang(waits: Int?, age: Double = 1) -> HangProbeReading {
        HangProbeReading(isHang: true, healthyWaits: waits, ageSeconds: age)
    }

    // MARK: Dot R-6: only a continuous stall is killed

    func testBurstsSeparatedByHealthyWaitsNeverAddUpToAKill() {
        var policy = HangRecoveryPolicy(startedAt: 0)
        // Two minutes: a busy stretch of 3 s or more every 5 s, a real wait between,
        // so the app keeps refreshing a fresh HANG dump with a new wait count.
        for tick in 1...120 {
            let now = UInt64(tick) * second
            policy.noteProgress(at: now)
            XCTAssertNil(policy.evaluate(now: now, reading: hang(waits: tick / 5)), "tick \(tick)")
        }
    }

    func testAContinuousStallIsKilledAfterTwentySeconds() {
        var policy = HangRecoveryPolicy(startedAt: 0)
        var firedAt: Int?
        for tick in 1...40 {
            let now = UInt64(tick) * second
            policy.noteProgress(at: now)
            if policy.evaluate(now: now, reading: hang(waits: 7)) == .sustainedHang { firedAt = tick; break }
        }
        XCTAssertEqual(firedAt, 21, "first seen at 1 s, sustained for 20 s")
    }

    func testALaunchTimeDumpThatEndsByItselfNeverCounts() {
        var policy = HangRecoveryPolicy(startedAt: 0)
        // A slow runner's first layout: about 4 s of busy, then the loop sleeps and the file goes stale.
        for tick in 1...4 { XCTAssertNil(policy.evaluate(now: UInt64(tick) * second, reading: hang(waits: 0))) }
        for tick in 5...40 {
            let now = UInt64(tick) * second
            policy.noteProgress(at: now)
            XCTAssertNil(policy.evaluate(now: now, reading: hang(waits: 0, age: 6)), "tick \(tick)")
        }
        XCTAssertNil(policy.sustainedSince)
    }

    func testTheFallbackMeasuresProgressNotTimeSinceLaunch() {
        var policy = HangRecoveryPolicy(startedAt: 0)
        // A slow but advancing test (each XCUI step takes 10 s) is never killed for being slow.
        for tick in stride(from: 10, through: 300, by: 10) {
            let now = UInt64(tick) * second
            policy.noteProgress(at: now)
            XCTAssertNil(policy.evaluate(now: now, reading: nil), "tick \(tick)")
        }
        // The XCUI call stops returning.
        XCTAssertNil(policy.evaluate(now: 359 * second, reading: nil))
        XCTAssertEqual(policy.evaluate(now: 361 * second, reading: nil), .noProgress)
    }

    func testTheProbeReadingParsesTheHealthyWaitCount() {
        let dump = "HANG: no-genuine-wait, elapsed=4250ms, turns=3, healthy-waits=12\nlast-turn=0ms ago\n"
        XCTAssertEqual(HangProbeReading(contents: dump, ageSeconds: 1),
                       HangProbeReading(isHang: true, healthyWaits: 12, ageSeconds: 1))
        XCTAssertEqual(HangProbeReading(contents: "ARMED: main-run-loop watchdog, 3s threshold\n", ageSeconds: 2),
                       HangProbeReading(isHang: false, healthyWaits: nil, ageSeconds: 2))
    }

    // MARK: Dot R-2: no risky scroll without its recovery

    func testNothingRiskyRunsWithoutAPIDOrAnArmedProbe() {
        var runs = 0
        let probe = URL(fileURLWithPath: "/tmp/attic-hang-probe.txt")
        XCTAssertNotNil(HangPassGuard.run(pid: 0, armedProbe: probe) { _, _ in runs += 1 }, "no PID: the pass ends with a reason")
        XCTAssertNotNil(HangPassGuard.run(pid: -1, armedProbe: probe) { _, _ in runs += 1 })
        XCTAssertNotNil(HangPassGuard.run(pid: 4242, armedProbe: nil) { _, _ in runs += 1 }, "unarmed probe: the pass ends with a reason")
        XCTAssertNotNil(HangPassGuard.run(pid: 0, armedProbe: nil) { _, _ in runs += 1 })
        XCTAssertEqual(runs, 0, "the scroll is never invoked without a recovery")
        var ran: (Int32, URL)?
        XCTAssertNil(HangPassGuard.run(pid: 4242, armedProbe: probe) { ran = ($0, $1) })
        XCTAssertEqual(ran?.0, 4242)
        XCTAssertEqual(ran?.1, probe)
    }

    // MARK: Opus R-4, R-2: where the app wrote its probe, and what counts as armed

    func testTheProbeIsFoundInTheAppsOwnContainerOrTheSharedTemporaryFolder() {
        let location = HangProbeLocation(leaf: "attic-hang-X.txt")
        let temporary = URL(fileURLWithPath: "/var/folders/t/T/", isDirectory: true)
        let candidates = location.candidates(bundleIdentifier: "com.taha.Attic.ui.abc", homeDirectory: "/Users/me",
                                             temporaryDirectory: temporary)
        XCTAssertEqual(candidates.map(\.path), ["/Users/me/Library/Containers/com.taha.Attic.ui.abc/Data/tmp/attic-hang-X.txt",
                                                "/var/folders/t/T/attic-hang-X.txt"])
        // A signed app wrote into its container; CI's unsigned app into the shared folder.
        XCTAssertEqual(location.armedURL(bundleIdentifier: "com.taha.Attic.ui.abc", homeDirectory: "/Users/me",
                                         temporaryDirectory: temporary) { $0.hasPrefix("/Users/me/Library/Containers") }?.path,
                       candidates[0].path)
        XCTAssertEqual(location.armedURL(bundleIdentifier: "com.taha.Attic.ui.abc", homeDirectory: "/Users/me",
                                         temporaryDirectory: temporary) { $0.hasPrefix("/var/folders") }?.path,
                       candidates[1].path)
        XCTAssertNil(location.armedURL(bundleIdentifier: nil, homeDirectory: "/Users/me", temporaryDirectory: temporary) { _ in false })
        XCTAssertEqual(location.candidates(bundleIdentifier: nil, homeDirectory: "/Users/me", temporaryDirectory: temporary).count, 1)
    }

    // MARK: Dot R-7: evidence survives teardown

    func testEvidenceFollowsTheRecoveryStatusNotTheLatestDumpPrefix() {
        // The fallback fired while the file still said ARMED.
        let items = HangEvidencePlan.items(recovered: true, probeText: "ARMED: main-run-loop watchdog\n",
                                           probeFirstExists: false, screenshotExists: true, sampleExists: true)
        XCTAssertEqual(items, [.probeLatest, .screenshot, .sample])
        XCTAssertEqual(HangEvidencePlan.items(recovered: true, probeText: "ARMED\n", probeFirstExists: false,
                                              screenshotExists: false, sampleExists: false, recoveryLogExists: true),
                       [.probeLatest, .screenshotUnavailableNote, .recoveryLog],
                       "the recovery's own log says why a picture or a stack is missing")
        XCTAssertEqual(HangEvidencePlan.items(recovered: true, probeText: "ARMED\n", probeFirstExists: false,
                                              screenshotExists: false, sampleExists: false),
                       [.probeLatest, .screenshotUnavailableNote])
        // A launch-time dump of a pass that recovered by itself is kept as evidence, and nothing else.
        XCTAssertEqual(HangEvidencePlan.items(recovered: false, probeText: "HANG: x\n", probeFirstExists: true,
                                              screenshotExists: true, sampleExists: true),
                       [.probeLatest, .probeFirst])
        XCTAssertEqual(HangEvidencePlan.items(recovered: false, probeText: "ARMED\n", probeFirstExists: false,
                                              screenshotExists: false, sampleExists: false), [])
    }

    // MARK: Opus R-6 = Dot R-8: the window only, never the display

    private func window(pid: Int32, number: UInt32, width: Double, height: Double, onScreen: Bool = true) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowNumber as String: NSNumber(value: number),
         kCGWindowIsOnscreen as String: NSNumber(value: onScreen),
         kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": width, "Height": height] as [String: Any]]
    }

    func testTheCaptureTargetsOnlyTheLaunchedAppsOwnWindow() {
        let windows = [window(pid: 1, number: 10, width: 3_000, height: 2_000),     // another app, bigger
                       window(pid: 4242, number: 20, width: 24, height: 24),        // the status item
                       window(pid: 4242, number: 21, width: 320, height: 464),      // the panel
                       window(pid: 4242, number: 22, width: 900, height: 900, onScreen: false)]
        XCTAssertEqual(HangWindowCapture.windowID(forPID: 4242, in: windows), 21)
        let arguments = HangWindowCapture.arguments(windowID: 21, path: "/tmp/p.png")
        XCTAssertEqual(arguments, ["-x", "-o", "-l", "21", "-t", "png", "/tmp/p.png"])
        XCTAssertTrue(arguments?.contains("-l") == true, "window capture, never the whole display")
    }

    func testWithoutAWindowThereIsNoPictureAtAll() {
        let windows = [window(pid: 1, number: 10, width: 3_000, height: 2_000)]
        let id = HangWindowCapture.windowID(forPID: 4242, in: windows)
        XCTAssertNil(id)
        XCTAssertNil(HangWindowCapture.arguments(windowID: id, path: "/tmp/p.png"), "no window: no capture command to run")
        XCTAssertNil(HangWindowCapture.windowID(forPID: 4242, in: []))
    }
}
