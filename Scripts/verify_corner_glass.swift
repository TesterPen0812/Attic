// Air-only real-screen regression check. Run with verify_corner_glass.zsh.
import AppKit
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else { fatalError("usage: check <preview executable> <evidence directory> [glass]") }
let executable = args[1], output = args[2]
guard executable.contains("AtticBugsTwo.app/Contents/MacOS/AtticBugsTwo") else { fatalError("test identity only") }
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main!
let backdrop = NSWindow(contentRect: screen.frame.insetBy(dx: 60, dy: 60),
                        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
backdrop.title = "bugs2-backdrop"
backdrop.collectionBehavior = [.fullScreenPrimary]
backdrop.isReleasedWhenClosed = false
backdrop.setFrame(screen.frame, display: false)
final class Backdrop: NSView {
    var light = false { didSet { needsDisplay = true } }
    override func draw(_ rect: NSRect) {
        (light ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.06, alpha: 1)).setFill()
        bounds.fill()
        for x in stride(from: 0.0, to: bounds.width, by: 80) {
            NSColor.systemBlue.withAlphaComponent(0.22).setFill()
            CGRect(x: x, y: 0, width: 20, height: bounds.height).fill()
        }
    }
}
let view = Backdrop(frame: backdrop.contentLayoutRect)
backdrop.contentView = view
@MainActor func activateBackdrop() {
    backdrop.makeKeyAndOrderFront(nil)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
        // macOS may decline a programmatic activation by an inactive app.
        // A real HID click on our own backdrop is the user path instead.
        let old = NSEvent.mouseLocation
        click(CGPoint(x: screen.frame.midX, y: screen.frame.midY),
              returning: CGPoint(x: old.x, y: screen.frame.maxY - old.y))
    }
    _ = NSRunningApplication.current.activate(options: [])
}
var preview: NSRunningApplication!
var failures = 0
func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
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
func capture(_ name: String, checksPresence: Bool = false) async throws {
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
    activateBackdrop()
    await pause(0.3)
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
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-selectedCorner", "topRight", "-panelIslandSpot", "screenSideCornerEnd", "-hasShownWelcome", "YES", "-appearancePreference", "light", "-panelSurfaceStyle", "glass"]
        configuration.environment = ["ATTIC_PAGE_BENCH": "1"]
        let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        preview = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        guard preview.processIdentifier > 0 else { throw NSError(domain: "invalid preview pid", code: 1) }
        record("SCREEN \(screen.frame) target=\(preview.processIdentifier)")
        record("BUNDLE \(preview.bundleURL?.path ?? "unknown")")
        record("PERMISSIONS post=\(CGPreflightPostEventAccess()) capture=\(CGPreflightScreenCaptureAccess())")
        await pause(4)
        activateBackdrop()
        await pause(1)
        try await corner("desktop-first")
        if args.count < 4 || args[3] != "glass" {
        backdrop.toggleFullScreen(nil)
        await pause(3)
        shown("fullscreen-pointer-held-at-corner")
        try await capture("fullscreen-pointer-held-at-corner", checksPresence: true)
        backdrop.toggleFullScreen(nil)
        await pause(3)
        shown("desktop-pointer-held-at-corner")
        try await capture("desktop-pointer-held-at-corner", checksPresence: true)
        move(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        await pause(2)
        backdrop.toggleFullScreen(nil)
        await pause(0.05)
        move(CGPoint(x: screen.frame.maxX - 1, y: 1))
        await pause(3)
        shown("corner-during-fullscreen-entry")
        try await capture("during-fullscreen-entry", checksPresence: true)
        backdrop.toggleFullScreen(nil)
        await pause(3)
        for lap in 1...2 {
            move(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            await pause(2)
            backdrop.toggleFullScreen(nil)
            await pause(3)
            try await corner("fullscreen-first-\(lap)")
            try await corner("fullscreen-repeat-\(lap)")
            if windows().count >= 3 { try await capture("fullscreen-\(lap)") }
            backdrop.toggleFullScreen(nil)
            await pause(3)
            try await corner("desktop-return-\(lap)")
        }
        // Launch for the first time in a full-screen Space, after a hide
        // and reveal on the desktop in a different Space.
        backdrop.toggleFullScreen(nil)
        await pause(3)
        _ = preview.terminate()
        for _ in 0..<50 { if preview.isTerminated { break }; await pause(0.1) }
        preview = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        guard preview.processIdentifier > 0 else { throw NSError(domain: "invalid relaunched pid", code: 1) }
        await pause(4)
        try await corner("launched-in-fullscreen")
        backdrop.toggleFullScreen(nil)
        await pause(3)
        try await corner("desktop-after-fullscreen-relaunch")
        }
        try await capture("dark-inactive-rest")
        if let point = islandPoint(0) { move(point) }
        await pause(0.4)
        try await capture("dark-inactive-awake")
        view.light = true
        await pause(0.5)
        try await capture("light-inactive-awake")
        if let point = islandPoint(1) { move(point); await pause(0.2); click(point) }
        await pause(2)
        try await capture("light-active-key")
        view.light = false
        await pause(0.5)
        try await capture("dark-active-key")
        activateBackdrop()
        await pause(0.5)
        try await capture("dark-after-page-switch-inactive")
        view.light = true
        await pause(0.5)
        try await capture("light-after-page-switch-inactive")
    } catch { record("ERROR \(error)"); failures += 1 }
    // Only the process and window created by this check are closed.
    if backdrop.styleMask.contains(.fullScreen) { backdrop.toggleFullScreen(nil); await pause(2) }
    move(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
    backdrop.close()
    if let preview, !preview.isTerminated { preview.terminate(); await pause(1) }
    record("RESULT failures=\(failures)")
    exit(failures == 0 ? 0 : 1)
}
app.run()
