// Run only on the Air while holding /tmp/attic-air-screen.lockdir.
// Recorded gestures post at the session tap; ordinary mouse/key/wheel input
// uses the HID tap. This driver never calls an app event handler.
import AppKit
import ApplicationServices
import CryptoKit

setvbuf(stdout, nil, _IOLBF, 0)
func abort(_ message: String) -> Never { print("BLOCK: \(message)"); exit(2) }
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { abort("usage: draw-hid-check <zoombase|zoomfix> <state|reveal|move|click|key|replay|wheel|activate> [arguments]") }
guard ["zoombase", "zoomfix"].contains(args[0]) else { abort("preview identity required") }
guard Host.current().localizedName?.contains("Air") == true else { abort("Air only") }
guard (try? String(contentsOfFile: "/tmp/attic-air-screen.lockdir/owner", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "zoom-for-good" else { abort("screen lock required") }
guard AXIsProcessTrusted() else { abort("Accessibility permission missing; do not answer a prompt") }
guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { abort("no graphical login session") }
guard session["CGSSessionScreenIsLocked"] as? Bool != true else { abort("screen locked") }
guard session["kCGSSessionOnConsoleKey"] as? Bool == true,
      session["kCGSessionLoginDoneKey"] as? Bool == true else { abort("console login is not ready") }
let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
func checkFlags() { guard CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).isEmpty else { abort("modifier flags are held") } }
checkFlags()
let bid = "com.taha.Attic.preview.\(args[0])"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { abort("preview is not running") }
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 1)
var recordedTimes: Set<UInt64> = []
var deliveries: [String: Int] = [:]
let diagnosticTap: CFMachPort? = CGPreflightListenEventAccess() ? CGEvent.tapCreate(
    tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
    eventsOfInterest: (1 << 29) | (1 << CGEventType.scrollWheel.rawValue),
    callback: { _, type, event, _ in
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) || recordedTimes.contains(event.timestamp) {
            let key = "type=\(type.rawValue) hid=\(event.getIntegerValueField(CGEventField(rawValue: 110)!)) targetPID=\(event.getIntegerValueField(.eventTargetUnixProcessID))"
            deliveries[key, default: 0] += 1
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil) : nil
if let diagnosticTap {
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, diagnosticTap, 0), .commonModes)
}
func pause(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(e, key as CFString, &value)
    return value
}
func string(_ e: AXUIElement, _ key: String) -> String { attr(e, key).map { String(describing: $0) } ?? "" }
func hasKeyboardFocus() -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bid ||
    (attr(root, "AXWindows") as? [AXUIElement] ?? []).contains { string($0, "AXFocused") == "1" }
}
func nodes() -> [AXUIElement] {
    var result: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ depth: Int) {
        guard depth < 30, result.count < 4000 else { return }
        result.append(e)
        guard string(e, "AXRole") != "AXMenuBar" else { return }
        for child in attr(e, "AXChildren") as? [AXUIElement] ?? [] { walk(child, depth + 1) }
    }
    walk(root, 0)
    return result
}
func rect(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, "AXPosition"), let s = attr(e, "AXSize"),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero; var size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}
func find(_ identifier: String) -> AXUIElement {
    guard let e = nodes().first(where: { string($0, "AXIdentifier") == identifier || string($0, "AXDescription") == identifier }) else { abort("missing \(identifier)") }
    return e
}
func zoom() -> Int? {
    let expression = try! NSRegularExpression(pattern: "([0-9]+)\\s*%")
    for e in nodes() where string(e, "AXIdentifier") == "draw-zoom-pill" || string(e, "AXDescription") == "Drawing board" {
        let value = string(e, "AXValue") as NSString
        if let match = expression.firstMatch(in: value as String, range: NSRange(location: 0, length: value.length)) {
            return Int(value.substring(with: match.range(at: 1)))
        }
    }
    return nil
}
func ownPoint(_ point: CGPoint) {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
    for w in windows {
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        if layer >= 1000 || [24, 25].contains(layer) || (owner == "Dock" && layer == 20) || owner == "Window Server" { continue }
        guard (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
              let bounds = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bounds), r.contains(point) else { continue }
        guard (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier else { abort("foreign window at target: \(owner)") }
        return
    }
    abort("no preview window at target")
}
func move(_ point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!
    e.flags = []; e.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.15)
}
func point(_ start: Int = 2) -> CGPoint {
    if args.count > start + 1, let x = Double(args[start]), let y = Double(args[start+1]) { return CGPoint(x: x, y: y) }
    let r = rect(find(args.count > start ? args[start] : "Drawing board")) ?? .zero
    guard !r.isEmpty else { abort("target has no geometry") }
    return CGPoint(x: r.midX, y: r.midY)
}
func click(_ p: CGPoint) {
    ownPoint(p); move(p)
    for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
        e.flags = []; e.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.06)
    }
}
func state() {
    print("active=\(app.isActive) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none") RM=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) RT=\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)")
    for e in nodes() {
        let id = string(e, "AXIdentifier"), role = string(e, "AXRole"), label = string(e, "AXDescription")
        if !id.isEmpty || label == "Drawing board" || role == "AXWindow" {
            print("\(role) id=\(id) label=\(label) value=\(string(e,"AXValue")) selected=\(string(e,"AXSelected")) focused=\(string(e,"AXFocused")) frame=\(rect(e).map { String(describing:$0) } ?? "-")")
        }
    }
    if let cursor = NSCursor.currentSystem, let bytes = cursor.image.tiffRepresentation {
        print("systemCursor size=\(cursor.image.size) hotspot=\(cursor.hotSpot) hash=\(SHA256.hash(data:bytes))")
    }
}
switch args[1] {
case "state": state()
case "snapshot":
    let board = find("Drawing board")
    let windows = attr(root, "AXWindows") as? [AXUIElement] ?? []
    var result: [String: Any] = ["active": NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bid,
                               "key": windows.contains { string($0, "AXFocused") == "1" },
                               "board": string(board, "AXValue")]
    if let zoom = zoom() { result["zoom"] = zoom }
    if let cursor = NSCursor.currentSystem, let bytes = cursor.image.tiffRepresentation {
        result["cursor"] = ["width": cursor.image.size.width, "height": cursor.image.size.height,
                            "hotX": cursor.hotSpot.x, "hotY": cursor.hotSpot.y,
                            "sha256": SHA256.hash(data: bytes).description] as [String: Any]
    }
    print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
case "close-settings":
    for window in attr(root, "AXWindows") as? [AXUIElement] ?? [] {
        if let r = rect(window), r.width > 600, let button = attr(window, "AXCloseButton"), CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, "AXPress" as CFString)
        }
    }
case "reveal":
    move(CGPoint(x: 1918, y: 2)); Thread.sleep(forTimeInterval: 1); state()
case "move": move(point())
case "click": click(point()); Thread.sleep(forTimeInterval: 0.4); state()
case "stroke":
    let p = point(); ownPoint(p); move(p)
    for i in 0...20 {
        let q = CGPoint(x: p.x + Double(i) * 2, y: p.y + sin(Double(i) / 4) * 12)
        ownPoint(q)
        let e = CGEvent(mouseEventSource: nil, mouseType: i == 0 ? .leftMouseDown : i == 20 ? .leftMouseUp : .leftMouseDragged,
                        mouseCursorPosition: q, mouseButton: .left)!
        e.flags = []; e.post(tap: .cghidEventTap); pause(0.015)
    }
    pause(0.3); state()
case "type":
    guard args.count > 2 else { abort("text required") }
    guard hasKeyboardFocus() else { abort("preview has no keyboard focus") }
    for char in args[2] {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
            let utf = Array(String(char).utf16)
            e.keyboardSetUnicodeString(stringLength: utf.count, unicodeString: utf)
            e.flags = []; e.post(tap: .cghidEventTap); pause(0.015)
        }
    }
    state()
case "activate": app.activate(options: []); Thread.sleep(forTimeInterval: 0.3); state()
case "key":
    guard args.count > 2, let code = CGKeyCode(args[2]) else { abort("key code required") }
    guard hasKeyboardFocus() else { abort("preview has no keyboard focus") }
    let flags: CGEventFlags = args.count > 3 && args[3] == "shift" ? .maskShift : args.count > 3 && args[3] == "command" ? .maskCommand : []
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = flags; e.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.05)
    }
    // Synthetic key flags can survive key-up; release only this driver's modifier.
    if !flags.isEmpty {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: flags == .maskShift ? 56 : 55, keyDown: false)!
        e.flags = []; e.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.15); state()
case "replay", "check":
    guard args.count >= 3,
          ["pinch-out", "pinch-in", "command-scroll-out", "command-scroll-in"].contains(args[2]) else {
        abort("recorded fixture required")
    }
    struct Sample: Decodable { let t: UInt64; let type: UInt32; let data: String }
    let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("AtticTests/Fixtures/DrawTrackpad/\(args[2]).jsonl")
    let samples = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(Sample.self, from: Data($0.utf8))
    }
    guard let first = samples.first else { abort("empty recording") }
    let events = samples.map { sample -> CGEvent in
        guard [22, 29].contains(sample.type), let data = Data(base64Encoded: sample.data),
              let event = CGEvent(withDataAllocator: nil, data: data as CFData),
              event.type.rawValue == sample.type else { abort("invalid recorded event") }
        return event
    }
    let p = point(3), origin = events[0].location
    // Preflight the entire translated path before posting any of it.
    for e in events {
        e.location = CGPoint(x: p.x + e.location.x - origin.x, y: p.y + e.location.y - origin.y)
        ownPoint(e.location)
    }
    let before = zoom()
    if args[1] == "check", before == nil { abort("zoom is not available through accessibility") }
    move(p)
    let started = DispatchTime.now().uptimeNanoseconds
    for (sample, event) in zip(samples, events) {
        let relative = sample.t >= first.t ? sample.t - first.t : 0
        let deadline = started + relative
        let now = DispatchTime.now().uptimeNanoseconds
        if deadline > now { pause(Double(deadline - now) / 1_000_000_000) }
        // Rebase time only; keep the recorded order, payload, flags and
        // relative motion. Session posting is intentional: no fabricated
        // touch data and no re-entry into HID gesture annotation.
        event.timestamp = deadline
        recordedTimes.insert(deadline)
        event.post(tap: .cgSessionEventTap)
    }
    pause(0.15)
    // The recorded scroll slice contains Command on every sample, but not
    // the later physical key-up. Session replay updates combined flags too.
    // Release only the modifier this stream introduced, with an ordinary
    // key-up; never fabricate a gesture or clear somebody else's modifiers.
    if events.contains(where: { $0.flags.contains(.maskCommand) }),
       CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask) == .maskCommand {
        let release = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false)!
        release.flags = []
        release.post(tap: .cgSessionEventTap)
        pause(0.1)
    }
    if args[1] == "check", let before {
        guard let after = zoom() else { abort("zoom disappeared from accessibility") }
        let increasing = args[2].hasSuffix("out")
        let passed = increasing ? (after > before || before == 400 && after == 400)
                                : (after < before || before == 10 && after == 10)
        print("\(passed ? "PASS" : "FAIL") \(args[2]): \(before)% → \(after)%")
        for (key, count) in deliveries.sorted(by: { $0.key < $1.key }) { print("DELIVERY \(key) count=\(count)") }
        checkFlags()
        if !passed { exit(1) }
    } else { state() }
case "wheel":
    let p = point(3); ownPoint(p); move(p)
    guard args.count > 2, let amount = Int32(args[2]) else { abort("wheel notch count required") }
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)!
    e.location = p; e.flags = .maskCommand; e.post(tap: .cghidEventTap)
    pause(0.15); state()
default: abort("unknown command")
}
Thread.sleep(forTimeInterval: 0.1)
checkFlags()
