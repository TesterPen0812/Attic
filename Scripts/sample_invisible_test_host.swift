// Build with: xcrun swiftc Scripts/sample_invisible_test_host.swift -o /tmp/attic-host-sampler
// Run: /tmp/attic-host-sampler OUTPUT.jsonl STOP_FILE
// Independent 20 Hz WindowServer / workspace / Accessibility observation.
import AppKit
import ApplicationServices

let output = CommandLine.arguments[1]
let stop = CommandLine.arguments[2]
FileManager.default.createFile(atPath: output, contents: nil)
let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
let system = AXUIElementCreateSystemWide()
let baseline = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
let start = ProcessInfo.processInfo.systemUptime
var nextSample = start
var unknownKeyOwnerSamples = 0
var samples = 0, hostSamples = 0, displayed = 0, activation = 0, focus = 0, frontChanges = 0
func focusedPID(_ attribute: String) -> pid_t {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return -1 }
    var pid: pid_t = -1
    AXUIElementGetPid(unsafeBitCast(value, to: AXUIElement.self), &pid)
    return pid
}
func write(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    handle.write(data); handle.write(Data([10]))
}
write(["kind": "start", "hz": 20, "baselineFrontmostPID": baseline, "accessibilityTrusted": AXIsProcessTrusted()])
while !FileManager.default.fileExists(atPath: stop) {
    autoreleasepool {
        let hosts = NSWorkspace.shared.runningApplications.filter { $0.executableURL?.lastPathComponent == "AtticUnitTestHost" }
        let pids = Set(hosts.map(\.processIdentifier))
        let front = NSWorkspace.shared.frontmostApplication
        let keyOwner = focusedPID(kAXFocusedApplicationAttribute)
        let keyboardOwner = focusedPID(kAXFocusedUIElementAttribute)
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
            if keyOwner == -1 { unknownKeyOwnerSamples += 1 }
            if front?.processIdentifier != baseline { frontChanges += 1 }
        }
        displayed += onscreen.count
        if hosts.contains(where: \.isActive) { activation += 1 }
        if pids.contains(keyOwner) || pids.contains(keyboardOwner) { focus += 1 }
        write(["kind": "sample", "seconds": ProcessInfo.processInfo.systemUptime - start,
               "hostPIDs": Array(pids), "onscreen": onscreen,
               "frontmostPID": front?.processIdentifier ?? -1, "frontmostBundle": front?.bundleIdentifier ?? "",
               "keyWindowOwnerPID": keyOwner, "keyboardElementOwnerPID": keyboardOwner])
    }
    nextSample += 0.05
    RunLoop.current.run(until: Date().addingTimeInterval(max(0, nextSample - ProcessInfo.processInfo.systemUptime)))
}
write(["kind": "summary", "samples": samples, "hostSamples": hostSamples, "onscreenWindows": displayed,
       "unknownKeyOwnerSamples": unknownKeyOwnerSamples, "hostActiveSamples": activation, "hostKeyboardSamples": focus, "frontmostChangedDuringHostSamples": frontChanges,
       "elapsed": ProcessInfo.processInfo.systemUptime - start])
try handle.close()
