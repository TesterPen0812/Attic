// Build as a standalone executable; --sentinel runs it in a separate .app.
// Usage: sampler OUTPUT.jsonl STOP_FILE [--sentinel]
// The sentinel establishes a known independent key-window owner before tests.
import AppKit
import ApplicationServices

let output = CommandLine.arguments[1]
let stop = CommandLine.arguments[2]
let useSentinel = CommandLine.arguments.contains("--sentinel")
FileManager.default.createFile(atPath: output, contents: nil)
let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
let system = AXUIElementCreateSystemWide()
AXUIElementSetMessagingTimeout(system, 0.005)
var baseline: pid_t = -1
var start = ProcessInfo.processInfo.systemUptime
var started = false
var samples = 0, hostSamples = 0, displayed = 0, activation = 0, focus = 0, frontChanges = 0
var unknownKeyOwnerSamples = 0, sentinelNotKeySamples = 0, sentinelKeyLosses = 0
var lastHostPIDs: Set<pid_t> = []
var sentinel: NSWindow?
var keyObserver: NSObjectProtocol?

func focusedPID(_ attribute: String) -> (pid: pid_t, error: Int32) {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(system, attribute as CFString, &value)
    guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (-1, result.rawValue) }
    var pid: pid_t = -1
    let error = AXUIElementGetPid(unsafeBitCast(value, to: AXUIElement.self), &pid)
    return (pid, error.rawValue)
}
func write(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    handle.write(data); handle.write(Data([10]))
}
func begin() {
    started = true
    start = ProcessInfo.processInfo.systemUptime
    baseline = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    write(["kind": "start", "hz": 20, "baselineFrontmostPID": baseline,
           "accessibilityTrusted": AXIsProcessTrusted(), "sentinel": useSentinel])
    FileManager.default.createFile(atPath: output + ".ready", contents: nil)
}
func sample() {
    autoreleasepool {
        let hosts = NSWorkspace.shared.runningApplications.filter { $0.executableURL?.lastPathComponent == "AtticUnitTestHost" }
        let pids = Set(hosts.map(\.processIdentifier))
        lastHostPIDs = pids
        let front = NSWorkspace.shared.frontmostApplication
        let systemOwner = focusedPID(kAXFocusedApplicationAttribute)
        let keyboardOwner = focusedPID(kAXFocusedUIElementAttribute)
        let sentinelIsKey = sentinel.map { $0.isKeyWindow && NSApp.keyWindow === $0 } ?? false
        // This process receives real resign-key notifications even when a
        // nonactivating panel takes the keyboard without changing frontmost.
        // It does not depend on another process servicing an AX request.
        let keyOwner = sentinelIsKey ? ProcessInfo.processInfo.processIdentifier : systemOwner.pid
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let displays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        var onscreen: [[String: Any]] = []
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  window[kCGWindowIsOnscreen as String] as? Bool == true,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  displays.contains(where: { $0.intersects(frame) }) else { continue }
            onscreen.append(["pid": pid, "number": window[kCGWindowNumber as String] ?? -1,
                             "frame": NSStringFromRect(frame), "layer": window[kCGWindowLayer as String] ?? -1])
        }
        samples += 1
        if !hosts.isEmpty {
            hostSamples += 1
            if keyOwner < 0 { unknownKeyOwnerSamples += 1 }
            if front?.processIdentifier != baseline { frontChanges += 1 }
            if useSentinel && !sentinelIsKey { sentinelNotKeySamples += 1 }
        }
        displayed += onscreen.count
        if hosts.contains(where: \.isActive) { activation += 1 }
        if pids.contains(keyOwner) || pids.contains(keyboardOwner.pid) { focus += 1 }
        write(["kind": "sample", "seconds": ProcessInfo.processInfo.systemUptime - start,
               "hostPIDs": Array(pids), "onscreen": onscreen,
               "frontmostPID": front?.processIdentifier ?? -1, "frontmostBundle": front?.bundleIdentifier ?? "",
               "keyWindowOwnerPID": keyOwner, "keyWindowOwnerSource": sentinelIsKey ? "sentinelKeyWindow" : "systemFocusedApplication",
               "sentinelIsKey": sentinelIsKey, "systemFocusedApplicationError": systemOwner.error,
               "keyboardElementOwnerPID": keyboardOwner.pid, "keyboardElementError": keyboardOwner.error])
    }
}
func finish() {
    write(["kind": "summary", "samples": samples, "hostSamples": hostSamples, "onscreenWindows": displayed,
           "unknownKeyOwnerSamples": unknownKeyOwnerSamples, "hostActiveSamples": activation,
           "hostKeyboardSamples": focus, "frontmostChangedDuringHostSamples": frontChanges,
           "sentinelNotKeySamples": sentinelNotKeySamples, "sentinelKeyLossesDuringHost": sentinelKeyLosses,
           "elapsed": ProcessInfo.processInfo.systemUptime - start])
    try! handle.close()
}

final class SentinelDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        sentinel?.makeKeyAndOrderFront(nil)
    }
}
let delegate = SentinelDelegate()
if useSentinel {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    let area = NSScreen.main!.visibleFrame
    let window = NSWindow(contentRect: CGRect(x: area.midX - 180, y: area.midY - 60, width: 360, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "FG keyboard sentinel"
    let label = NSTextField(labelWithString: "This separate process must keep the keyboard\nthroughout Attic's invisible unit-test run.")
    label.frame = CGRect(x: 20, y: 35, width: 320, height: 50)
    window.contentView?.addSubview(label)
    sentinel = window
    keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
        if !lastHostPIDs.isEmpty {
            sentinelKeyLosses += 1
            write(["kind": "sentinelResignedKey", "seconds": ProcessInfo.processInfo.systemUptime - start,
                   "hostPIDs": Array(lastHostPIDs)])
        }
    }
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
        if FileManager.default.fileExists(atPath: stop) {
            timer.invalidate(); finish(); app.terminate(nil)
        } else if !started {
            if window.isKeyWindow && app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { begin() }
        } else { sample() }
    }
    app.run()
} else {
    begin()
    var nextSample = start
    while !FileManager.default.fileExists(atPath: stop) {
        sample()
        nextSample += 0.05
        RunLoop.current.run(until: Date().addingTimeInterval(max(0, nextSample - ProcessInfo.processInfo.systemUptime)))
    }
    finish()
}
