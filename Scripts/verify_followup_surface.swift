// Air-only real-screen regression check. Run with verify_corner_glass.zsh.
import AppKit
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: check <preview executable> <evidence directory> [glass|solid]") }
let executable = args[1], output = args[2]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main!
let backdrop = NSWindow(contentRect: screen.frame.insetBy(dx: 60, dy: 60),
                        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
backdrop.title = "followup-backdrop"
backdrop.collectionBehavior = [.fullScreenPrimary]
backdrop.isReleasedWhenClosed = false
backdrop.setFrame(screen.frame, display: false)
final class Backdrop: NSView {
    var light = false { didSet { needsDisplay = true } }
    override func draw(_ rect: NSRect) {
        (light ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.06, alpha: 1)).setFill()
        bounds.fill()

    }
}
let view = Backdrop(frame: backdrop.contentLayoutRect)
backdrop.contentView = view
@MainActor func activateBackdrop() {
    backdrop.makeKeyAndOrderFront(nil)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
        // macOS may decline a programmatic activation by an inactive app.
        // A real HID click on our own backdrop is the user path instead.
        let point = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        // Never click a system alert or another app's window during setup.
        guard NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == backdrop.windowNumber else { return }
        let old = NSEvent.mouseLocation
        click(point,
              returning: CGPoint(x: old.x, y: screen.frame.maxY - old.y))
    }
    _ = NSRunningApplication.current.activate(options: [])
}
var preview: NSRunningApplication!
var failures = 0
func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
@MainActor func requireOwnForeground() throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard let front, front == getpid() || front == preview?.processIdentifier else {
        throw NSError(domain: "Air screen is in use by another app; stopped without input", code: 75)
    }
}
@MainActor func prepareBackdrop() async throws {
    try requireOwnForeground()
    for _ in 0..<5 {
        try requireOwnForeground()
        activateBackdrop()
        await pause(0.3)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { return }
    }
    throw NSError(domain: "test backdrop could not establish activation", code: 1)
}
func postInput(_ script: String) {
    let id = "// " + UUID().uuidString
    try! (id + "\n" + script).write(toFile: output + "/input-request", atomically: true, encoding: .utf8)
    for _ in 0..<250 {
        if (try? String(contentsOfFile: output + "/input-done", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == id { return }
        usleep(20_000)
    }
    record("ERROR input timeout"); failures += 1
}
func move(_ point: CGPoint) {
    // osascript is the Air's existing authorized automation host. This is
    // still a HID-level CGEvent, with no accessibility mouse-warp shortcut.
    postInput("ObjC.import('CoreGraphics'); $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventMouseMoved, $.CGPointMake(\(point.x),\(point.y)), $.kCGMouseButtonLeft));")
}
func click(_ point: CGPoint, returning: CGPoint? = nil) {
    let restore = returning.map { "$.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null,$.kCGEventMouseMoved,$.CGPointMake(\($0.x),\($0.y)),$.kCGMouseButtonLeft));" } ?? ""
    postInput("ObjC.import('CoreGraphics'); for (var t of [$.kCGEventLeftMouseDown,$.kCGEventLeftMouseUp]) { $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null,t,$.CGPointMake(\(point.x),\(point.y)),$.kCGMouseButtonLeft)); delay(0.04); } " + restore)
}
func islandPoint(_ index: Int) -> CGPoint? {
    for window in windows() {
        guard let b = window[kCGWindowBounds as String] as? [String: CGFloat],
              let width = b["Width"], width > 60, width < 100, (b["Height"] ?? 0) > 100 else { continue }
        return CGPoint(x: b["X"]! + 22 + 13.5, y: b["Y"]! + 22 + 13.5 + CGFloat(index) * 24)
    }
    return nil
}
func windows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]] ?? []).filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == preview.processIdentifier &&
        ($0[kCGWindowLayer as String] as? Int) == 3
    }
}
func record(_ text: String) { print(text); fflush(stdout) }
@MainActor func capture(_ name: String, checksPresence: Bool = false) async throws {
    try requireOwnForeground()
    let path = output + "/" + name + ".png"
    try "\(preview.processIdentifier)\n\(getpid())\n\(path)".write(toFile: output + "/capture-request", atomically: true, encoding: .utf8)
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: path + ".error") {
            record("FAIL \(name): \(try String(contentsOfFile: path + ".error", encoding: .utf8))")
            failures += 1
            return
        }
        if FileManager.default.fileExists(atPath: path) {
            let brightness = Double(try String(contentsOfFile: path + ".presence", encoding: .utf8)) ?? 0
            if checksPresence && brightness < 0.2 { failures += 1; record("FAIL \(name): window flags say visible but no light panel over the dark backdrop (\(brightness))") }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            if name.contains("inactive"), front != getpid() { failures += 1; record("FAIL \(name): backdrop does not own activation") }
            if name.contains("active-key"), front != preview.processIdentifier { failures += 1; record("FAIL \(name): preview does not own activation") }
            record("CAPTURE \(name) panelBrightness=\(brightness) front=\(front) driver=\(getpid()) target=\(preview.processIdentifier)")
            return
        }
        await pause(0.1)
    }
    throw NSError(domain: "capture timeout", code: 1)
}
@MainActor func shown(_ name: String) {
    let count = windows().count
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let pass = count >= 3 && front == getpid()
    if !pass { failures += 1 }
    record("\(pass ? "PASS" : "FAIL") \(name) windows=\(count) front=\(front ?? -1) expectedFront=\(getpid()) fullscreen=\(backdrop.styleMask.contains(.fullScreen)) pointer=\(NSEvent.mouseLocation)")
}
@MainActor func corner(_ name: String) async throws {
    try await prepareBackdrop()
    move(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
    await pause(2)
    record("HIDDEN \(name) windows=\(windows().count)")
    move(CGPoint(x: screen.frame.maxX - 1, y: 1))
    await pause(2)
    for attempt in 0..<3 {
        let actual = NSEvent.mouseLocation
        if abs(actual.x - (screen.frame.maxX - 1)) < 2 && abs(actual.y - (screen.frame.maxY - 1)) < 2 { break }
        record("HID retry \(attempt) actual=\(actual)")
        move(CGPoint(x: screen.frame.maxX - 1, y: 1))
        await pause(0.3)
    }
    guard abs(NSEvent.mouseLocation.x - (screen.frame.maxX - 1)) < 2,
          abs(NSEvent.mouseLocation.y - (screen.frame.maxY - 1)) < 2 else {
        record("ERROR HID event was blocked actual=\(NSEvent.mouseLocation)"); failures += 1; return
    }
    shown(name)
    try await capture(name, checksPresence: true)
}
Task { @MainActor in
    do {
        let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for mode in ["light", "dark"] {
            for surface in ["glass", "frosted", "solid"] {
                try requireOwnForeground()
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.createsNewApplicationInstance = true
                configuration.arguments = ["-selectedCorner", "topRight", "-panelIslandSpot", "screenSideCornerEnd",
                    "-hasShownWelcome", "YES", "-appearancePreference", mode, "-panelSurfaceStyle", surface]
                configuration.environment = ["ATTIC_PAGE_BENCH": "1"]
                preview = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
                await pause(4)
                try await prepareBackdrop()
                move(CGPoint(x: screen.frame.maxX - 1, y: 1))
                await pause(2)
                for light in [false, true] {
                    try requireOwnForeground()
                    view.light = light
                    kill(preview.processIdentifier, SIGWINCH)
                    await pause(0.25)
                    try await capture("\(mode)-\(surface)-\(light ? "light" : "dark")-backdrop")
                }
                preview.terminate()
                for _ in 0..<50 { if preview.isTerminated { break }; await pause(0.1) }
                guard preview.isTerminated else { throw NSError(domain: "preview did not quit", code: 1) }
                preview = nil
            }
        }
    } catch { record("ERROR \(error)"); failures += 1 }
    backdrop.close()
    if let preview, !preview.isTerminated { preview.terminate(); await pause(1) }
    record("RESULT failures=\(failures)")
    exit(failures == 0 ? 0 : 1)
}
app.run()
