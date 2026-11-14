import AppKit
import CoreGraphics
import Darwin
import Foundation

// Pure decisions behind the CI hang recovery of ScrollEdgeUITests, kept apart
// from XCUIApplication so HangRecoverySupportTests can drive them with a fake
// clock, fake window lists and injected failures. Nothing here touches the app.

/// Where the launched app's probe file is. A signed (sandboxed) app cannot
/// write to the UI runner's temporary folder, so the test names only a leaf
/// (`ATTIC_HANG_PROBE_FILE`). The app writes it into its own temporary folder:
/// `~/Library/Containers/<bundle id>/Data/tmp` when sandboxed, the user's
/// temporary folder (shared with this runner) when not, as in CI's unsigned lane.
struct HangProbeLocation {
    let leaf: String

    init(leaf: String = "attic-hang-\(UUID().uuidString).txt") { self.leaf = leaf }

    func candidates(bundleIdentifier: String?, homeDirectory: String, temporaryDirectory: URL) -> [URL] {
        var urls: [URL] = []
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            urls.append(URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/tmp/\(leaf)"))
        }
        urls.append(temporaryDirectory.appendingPathComponent(leaf))
        return urls
    }

    /// The first candidate the app has already written.
    func armedURL(bundleIdentifier: String?, homeDirectory: String = HangProbeLocation.homeDirectory(),
                  temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                  fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        candidates(bundleIdentifier: bundleIdentifier, homeDirectory: homeDirectory,
                   temporaryDirectory: temporaryDirectory).first { fileExists($0.path) }
    }

    static func homeDirectory() -> String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }
}

/// What the app's last probe write said.
struct HangProbeReading: Equatable {
    var isHang: Bool
    /// The app's count of real run-loop waits when it wrote the dump. A change
    /// between two dumps proves the loop slept in between.
    var healthyWaits: Int?
    /// Seconds since the file was written.
    var ageSeconds: Double

    init(isHang: Bool, healthyWaits: Int?, ageSeconds: Double) {
        self.isHang = isHang
        self.healthyWaits = healthyWaits
        self.ageSeconds = ageSeconds
    }

    init(contents: String, ageSeconds: Double) {
        isHang = contents.hasPrefix("HANG:")
        let first = contents.prefix { $0 != "\n" }
        healthyWaits = first.range(of: "healthy-waits=").flatMap { range in
            Int(first[range.upperBound...].prefix { $0.isNumber })
        }
        self.ageSeconds = ageSeconds
    }
}

/// When to give up on a launched app. A hang is a *continuous* stall: dumps keep
/// arriving with the same healthy-wait count. Busy bursts separated by real waits
/// change that count and restart the interval, so they never add up to a kill.
/// The fallback measures time since the test last made progress, not since
/// launch, so a slow but advancing test is never killed for being slow.
struct HangRecoveryPolicy {
    enum Decision: Equatable { case sustainedHang, noProgress }

    static let sustainedNanos: UInt64 = 20_000_000_000
    static let progressDeadlineNanos: UInt64 = 60_000_000_000
    static let freshSeconds = 4.5

    private(set) var sustainedSince: UInt64?
    private var generation: Int?
    private var lastProgress: UInt64

    init(startedAt: UInt64) { lastProgress = startedAt }

    mutating func noteProgress(at now: UInt64) { lastProgress = max(lastProgress, now) }

    mutating func evaluate(now: UInt64, reading: HangProbeReading?) -> Decision? {
        if let reading, reading.isHang, reading.ageSeconds < Self.freshSeconds {
            if sustainedSince == nil || reading.healthyWaits != generation {
                sustainedSince = now
                generation = reading.healthyWaits
            }
            if now &- (sustainedSince ?? now) >= Self.sustainedNanos { return .sustainedHang }
        } else {
            sustainedSince = nil
            generation = nil
        }
        return now &- lastProgress > Self.progressDeadlineNanos ? .noProgress : nil
    }
}

/// A pass needs its recovery (a launched PID and an armed probe) before any
/// risky hover or scroll. Without either, the pass ends with a clear failure.
enum HangPassGuard {
    enum Outcome: Equatable {
        case proceed(pid: Int32, probe: URL)
        case skip(reason: String)
    }

    static func evaluate(pid: Int32, armedProbe: URL?) -> Outcome {
        guard pid > 0 else { return .skip(reason: "launched app PID is unavailable for recovery") }
        guard let armedProbe else { return .skip(reason: "the app-side hang probe never wrote its file") }
        return .proceed(pid: pid, probe: armedProbe)
    }

    /// Runs `risky` only when the recovery can be armed. Returns the reason when it did not run.
    static func run(pid: Int32, armedProbe: URL?, risky: (Int32, URL) -> Void) -> String? {
        switch evaluate(pid: pid, armedProbe: armedProbe) {
        case let .proceed(pid, probe):
            risky(pid, probe)
            return nil
        case let .skip(reason):
            return reason
        }
    }
}

/// What a pass attaches after a hang, a recovery or an abandoned XCUI call.
/// It follows the recovery's status and which files exist, never only the
/// latest dump's prefix (the fallback can fire while the file still says ARMED).
enum HangEvidencePlan {
    enum Item: Equatable { case probeLatest, probeFirst, screenshot, screenshotUnavailableNote, sample, recoveryLog }

    static func items(recovered: Bool, probeText: String?, probeFirstExists: Bool,
                      screenshotExists: Bool, sampleExists: Bool, recoveryLogExists: Bool = false) -> [Item] {
        var items: [Item] = []
        if recovered || probeText?.hasPrefix("HANG:") == true {
            if probeText != nil { items.append(.probeLatest) }
            if probeFirstExists { items.append(.probeFirst) }
        }
        guard recovered else { return items }
        items.append(screenshotExists ? .screenshot : .screenshotUnavailableNote)
        if sampleExists { items.append(.sample) }
        if recoveryLogExists { items.append(.recoveryLog) }
        return items
    }
}

/// The recovery's picture is of the launched app's own window only, found from
/// its PID in the window server's list (no AX request, which can block on a
/// hung app). Never the whole display: other apps' windows and notifications
/// must not end up in a result bundle.
enum HangWindowCapture {
    static func windowID(forPID pid: Int32, in windows: [[String: Any]]) -> CGWindowID? {
        func area(_ window: [String: Any]) -> Double {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return 0 }
            return width * height
        }
        let own = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && area($0) > 0 }
        let onScreen = own.filter { ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true }
        let pool = onScreen.isEmpty ? own : onScreen
        return pool.max { area($0) < area($1) }
            .flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    /// `screencapture` arguments for one window, or nil when the app has none.
    static func arguments(windowID: CGWindowID?, path: String) -> [String]? {
        guard let windowID else { return nil }
        return ["-x", "-o", "-l", String(windowID), "-t", "png", path]
    }

    static func currentWindows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    }
}

/// Runs a short-lived tool with a hard time limit and says what happened
/// (launch failure, timeout, exit status and the start of its error output),
/// so a recovery that could not take a picture or a stack can say why.
@discardableResult
func runHangTool(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = errors
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return "could not start: \(error)" }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        return "timed out after \(Int(timeout)) s and was terminated"
    }
    let output = String(decoding: errors.fileHandleForReading.availableData.prefix(400), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return "exited \(process.terminationStatus)" + (output.isEmpty ? "" : ": \(output)")
}
