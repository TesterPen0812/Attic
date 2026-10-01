import AppKit
import CoreGraphics
import QuartzCore

// The on-screen performance gate's driver (`Scripts/perf_onscreen.zsh`),
// compiled by the gate. Every command targets one app by its bundle
// identifier, never by name or path:
//
//   perf_onscreen_drive pid <bundle-id>            the running instance's pid
//   perf_onscreen_drive drive <bundle-id> [sign] [hid|pid]
//   perf_onscreen_drive quit <bundle-id>           quit it (force after 5 s)
//
// `drive` posts phased trackpad scrolls (vertical, with momentum) and page
// swipes (next, next, back, back: never past the first page, so the panel
// never swipe-closes) over the app's panel window, printing MARK lines on the
// CACurrentMediaTime timebase the app's frame monitor uses. Before every
// gesture it checks that the frontmost window under the point is the app's
// (`hid`, the default, posts through the HID tap, as a trackpad does), or
// posts to the app's process only (`pid`). It stops, posting nothing more,
// if the app's window moved, went away or was covered.

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments

func fail(_ message: String, _ code: Int32) -> Never {
    print(message)
    exit(code)
}

guard arguments.count >= 3 else {
    fail("usage: perf_onscreen_drive pid|drive|quit <bundle-id> [sign] [hid|pid]", 2)
}
let command = arguments[1]
let bundleID = arguments[2]
guard bundleID != "com.taha.Attic" else { fail("REFUSED: the release identity is never driven", 2) }

func running() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
}

switch command {
case "pid":
    guard let app = running() else { fail("NONE", 1) }
    print(app.processIdentifier)
    exit(0)
case "quit":
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
        app.terminate()
        let deadline = Date().addingTimeInterval(5)
        while !app.isTerminated, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if !app.isTerminated { app.forceTerminate() }
    }
    print("QUIT")
    exit(0)
case "drive":
    break
default:
    fail("unknown command \(command)", 2)
}

guard let app = running() else { fail("NO_APP", 3) }
let pid = app.processIdentifier
let swipeSign: Int32 = arguments.count > 3 ? Int32(arguments[3]) ?? 1 : 1
let toProcessOnly = arguments.count > 4 && arguments[4] == "pid"

/// The app's largest on-screen window (the panel), in global coordinates
/// (top-left origin).
func panelBounds() -> CGRect? {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var best: CGRect?
    for window in info where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
        guard let b = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { continue }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        if rect.width < 200 || rect.height < 200 { continue }
        if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
    }
    return best
}

/// Whether the frontmost visible window under `point` is the app's (the
/// window list is front to back; the menu bar, the Dock and the cursor are
/// skipped by their layer).
func appIsFrontmost(at point: CGPoint) -> Bool {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in info {
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
        guard alpha > 0.01, layer < 1_000, layer != 24, layer != 25,
              let b = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
              CGRect(x: x, y: y, width: w, height: h).contains(point) else { continue }
        return (window[kCGWindowOwnerPID as String] as? Int32) == pid
    }
    return false
}

guard let bounds = panelBounds() else { fail("NO_WINDOW", 3) }
let point = CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.55)
print("WINDOW \(bounds) point=\(point) post=\(toProcessOnly ? "pid" : "hid")")
guard appIsFrontmost(at: point) else { fail("ABORT: another window covers the panel at \(point)", 4) }
if !toProcessOnly {
    CGWarpMouseCursorPosition(point)
}
usleep(400_000)

/// Stops the run, posting nothing more, if the panel moved or is covered.
func guardTarget() {
    guard let now = panelBounds(), now == bounds else { fail("ABORT: the panel moved or went away", 4) }
    guard appIsFrontmost(at: point) else { fail("ABORT: another window covers the panel", 4) }
}

func post(dx: Int32, dy: Int32, phase: Int64, momentum: Int64 = 0) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    event.location = point
    if toProcessOnly {
        event.postToPid(pid)
    } else {
        event.post(tap: .cghidEventTap)
    }
}

func mark(_ name: String) {
    // The app's frames are on the media timebase; the GPU and CPU samples
    // on the wall clock.
    print(String(format: "MARK %@ %.4f %.3f", name, CACurrentMediaTime(), Date().timeIntervalSince1970))
}

/// A trackpad gesture: began, changes every 8 ms, ended, then a decaying
/// momentum tail.
func gesture(dx: Int32, dy: Int32, steps: Int, momentumSteps: Int) {
    guardTarget()
    post(dx: 0, dy: 0, phase: 1)
    for _ in 0..<steps { usleep(8_000); post(dx: dx, dy: dy, phase: 2) }
    usleep(8_000); post(dx: 0, dy: 0, phase: 4)
    guard momentumSteps > 0 else { return }
    for step in 0..<momentumSteps {
        usleep(16_000)
        let fade = 1.0 - Double(step) / Double(momentumSteps)
        post(dx: Int32(Double(dx) * 2 * fade), dy: Int32(Double(dy) * 2 * fade), phase: 0, momentum: step == 0 ? 1 : 2)
    }
    usleep(16_000); post(dx: 0, dy: 0, phase: 0, momentum: 3)
}

usleep(600_000)
mark("scroll_start")
for direction: Int32 in [-1, -1, -1, 1, 1, 1, -1, 1] {
    gesture(dx: 0, dy: 10 * direction, steps: 30, momentumSteps: 45)
    usleep(250_000)
}
mark("scroll_end")
usleep(800_000)
mark("swipe_start")
// Next, next, back, back: never past the first page, so no swipe-to-close.
for direction: Int32 in [1, 1, -1, -1, 1, 1, -1, -1] {
    gesture(dx: 24 * direction * swipeSign, dy: 0, steps: 18, momentumSteps: 0)
    usleep(700_000)
}
mark("swipe_end")
print("DONE")
