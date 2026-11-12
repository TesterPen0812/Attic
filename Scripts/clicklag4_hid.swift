// Air-only, isolated-preview click driver. Never approaches the reveal corner.
// Usage: swift Scripts/clicklag4_hid.swift inspect
//        swift Scripts/clicklag4_hid.swift inspect-all
//        swift Scripts/clicklag4_hid.swift tap <AX identifier or prefix> [count]
//        swift Scripts/clicklag4_hid.swift tap-label <AX label or prefix> [count]
//        swift Scripts/clicklag4_hid.swift tap-point <x> <y> [count] (visually verified only)
//        swift Scripts/clicklag4_hid.swift scroll <x> <y> <wheel lines> (verified window only)
//        swift Scripts/clicklag4_hid.swift type <safe short text>
//        swift Scripts/clicklag4_hid.swift return [count]
//        swift Scripts/clicklag4_hid.swift position <x> <y>
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
func fail(_ reason: String) -> Never { print("BLOCK: \(reason)"); exit(2) }
let bundle = "com.taha.Attic.preview.clicklag4"
guard Host.current().localizedName?.contains("Air") == true else { fail("Air only") }
guard AXIsProcessTrusted() else { fail("Accessibility permission missing") }
guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
      session["CGSSessionScreenIsLocked"] as? Bool != true,
      session["kCGSSessionOnConsoleKey"] as? Bool == true else { fail("no unlocked local console") }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first(where: { !$0.isTerminated }) else {
    fail("isolated preview not running")
}
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 2)
let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { fail("inspect|tap|return required") }

func get(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success ? value : nil
}
func string(_ node: AXUIElement, _ name: String) -> String {
    guard let value = get(node, name) else { return "" }
    return String(describing: value)
}
func bounds(_ node: AXUIElement) -> CGRect? {
    guard let origin = get(node, "AXPosition"), let size = get(node, "AXSize"),
          CFGetTypeID(origin) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(origin as! AXValue, .cgPoint, &p),
          AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}
func nodes() -> [AXUIElement] {
    var result: [AXUIElement] = []
    func walk(_ node: AXUIElement, _ depth: Int) {
        guard depth < 30, result.count < 4000 else { return }
        result.append(node)
        guard string(node, "AXRole") != "AXMenuBar" else { return }
        for child in get(node, "AXChildren") as? [AXUIElement] ?? [] { walk(child, depth + 1) }
    }
    walk(root, 0)
    return result
}

func verify(_ p: CGPoint) {
    let display = CGDisplayBounds(CGMainDisplayID())
    guard display.insetBy(dx: 60, dy: 60).contains(p) else { fail("near a display edge \(p)") }
    for corner in [CGPoint(x: display.minX, y: display.minY), CGPoint(x: display.maxX, y: display.minY),
                   CGPoint(x: display.minX, y: display.maxY), CGPoint(x: display.maxX, y: display.maxY)] {
        guard hypot(p.x - corner.x, p.y - corner.y) > 200 else { fail("near reveal corner \(p)") }
    }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var found = false
    for item in windows {
        let layer = item[kCGWindowLayer as String] as? Int ?? 0
        guard layer < 1000, layer != 24, layer != 25,
              (item[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
              let box = item[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: box), frame.contains(p) else { continue }
        // The Dock has full-screen, non-interactive system layers above the
        // panel (18 and 20 on the Air). They are visible in the window list
        // but never cover the panel's pixels or take its mouse input.
        if (item[kCGWindowOwnerName as String] as? String) == "Dock",
           (layer == 18 || layer == 20), frame == display { continue }
        guard (item[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier else {
            fail("another app overlaps the click position")
        }
        found = true
        break
    }
    guard found else { fail("no preview window under \(p)") }
}

func find(_ query: String) -> (String, CGPoint) {
    let matches = nodes().compactMap { node -> (String, CGPoint)? in
        let identifier = string(node, "AXIdentifier")
        guard identifier == query || identifier.hasPrefix(query) else { return nil }
        guard let rectangle = bounds(node), rectangle.width >= 8, rectangle.height >= 8 else { return nil }
        return (identifier, CGPoint(x: rectangle.midX, y: rectangle.midY))
    }
    guard let match = matches.sorted(by: { $0.0.count < $1.0.count }).first else {
        fail("no onscreen accessibility target: \(query)")
    }
    verify(match.1)
    return match
}

func findLabel(_ query: String) -> (String, CGPoint) {
    let matches = nodes().compactMap { node -> (String, CGPoint)? in
        let label = string(node, "AXDescription")
        let title = string(node, "AXTitle")
        guard label.hasPrefix(query) || title.hasPrefix(query) else { return nil }
        guard let rectangle = bounds(node), rectangle.width >= 8, rectangle.height >= 8 else { return nil }
        return (label.isEmpty ? title : label, CGPoint(x: rectangle.midX, y: rectangle.midY))
    }
    guard let match = matches.first else { fail("no onscreen accessibility label: \(query)") }
    verify(match.1)
    return match
}

func postMouse(_ type: CGEventType, _ point: CGPoint) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
        fail("unable to create HID mouse event")
    }
    event.flags = []
    event.post(tap: .cghidEventTap)
}

func keepPreviewInSafeArea() {
    let display = CGDisplayBounds(CGMainDisplayID())
    let windows = get(root, "AXWindows") as? [AXUIElement] ?? []
    let pin = nodes().first(where: { string($0, "AXIdentifier") == "panel-pin-button" })
    guard let pinFrame = pin.flatMap(bounds),
          let panel = windows.first(where: { bounds($0)?.contains(CGPoint(x: pinFrame.midX, y: pinFrame.midY)) == true }),
          let rect = bounds(panel) else { fail("isolated preview panel unavailable") }
    guard rect.minY < display.minY + 180 || rect.maxX > display.maxX - 220 else { return }
    let destination = CGPoint(x: 1200, y: 210)
    guard rect.width <= 400, rect.height <= 600,
          display.insetBy(dx: 300, dy: 200).contains(destination),
          destination.x + rect.width < display.maxX - 220,
          destination.y + rect.height < display.maxY - 160 else {
        fail("preview cannot move safely inward")
    }
    var p = destination
    guard let value = AXValueCreate(.cgPoint, &p),
          AXUIElementSetAttributeValue(panel, kAXPositionAttribute as CFString, value) == .success else {
        fail("preview refused inward position")
    }
    Thread.sleep(forTimeInterval: 0.35)
    print("SAFE_PREVIEW_POSITION \(rect.origin) -> \(destination)")
}

switch verb {
case "inspect":
    for node in nodes() {
        let id = string(node, "AXIdentifier")
        guard !id.isEmpty, let box = bounds(node), box.width > 6, box.height > 6 else { continue }
        print("\(id) | \(string(node, "AXRole")) | \(string(node, "AXDescription")) | \(box)")
    }
case "inspect-all":
    for node in nodes() {
        guard let box = bounds(node), box.width > 6, box.height > 6 else { continue }
        let role = string(node, "AXRole"), id = string(node, "AXIdentifier")
        let title = string(node, "AXTitle"), label = string(node, "AXDescription")
        guard !id.isEmpty || (!title.isEmpty || !label.isEmpty) && role.contains("Button") else { continue }
        print("\(role) | id=\(id) | title=\(title) | label=\(label) | \(box)")
    }
case "windows":
    let windows = get(root, "AXWindows") as? [AXUIElement] ?? []
    print("WINDOW_COUNT \(windows.count)")
    for (index, window) in windows.enumerated() {
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable)
        print("WINDOW \(index) \(string(window, "AXRole")) \(string(window, "AXTitle")) \(String(describing: bounds(window))) position_settable=\(status == .success && settable.boolValue)")
    }
case "stack":
    guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else {
        fail("stack requires x and y")
    }
    let point = CGPoint(x: x, y: y)
    for item in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
        guard let box = item[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: box), frame.contains(point) else { continue }
        print("STACK owner=\(item[kCGWindowOwnerName as String] ?? "?") pid=\(item[kCGWindowOwnerPID as String] ?? "?") layer=\(item[kCGWindowLayer as String] ?? "?") alpha=\(item[kCGWindowAlpha as String] ?? "?") bounds=\(frame)")
    }
case "position":
    guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]),
          x.isFinite, y.isFinite else { fail("position requires x and y") }
    let display = CGDisplayBounds(CGMainDisplayID())
    guard display.insetBy(dx: 300, dy: 200).contains(CGPoint(x: x, y: y)) else {
        fail("new position too close to screen edges")
    }
    let windows = get(root, "AXWindows") as? [AXUIElement] ?? []
    let pin = nodes().first(where: { string($0, "AXIdentifier") == "panel-pin-button" })
    let pinCenter = pin.flatMap(bounds).map { CGPoint(x: $0.midX, y: $0.midY) }
    let matches = windows.filter { window in
        guard let box = bounds(window), let pinCenter else { return false }
        return box.contains(pinCenter)
    }
    guard matches.count == 1, let window = matches.first, let prior = bounds(window) else {
        fail("expected one window containing the isolated preview pin; windows=\(windows.count) matching=\(matches.count)")
    }
    guard x + prior.width < display.maxX - 220, y + prior.height < display.maxY - 160 else {
        fail("new window extent too close to screen edges")
    }
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success,
          settable.boolValue else { fail("isolated preview window position is not settable") }
    var position = CGPoint(x: x, y: y)
    guard let axValue = AXValueCreate(.cgPoint, &position),
          AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axValue) == .success else {
        fail("isolated preview window refused position change")
    }
    print("POSITION \(prior) -> \(String(describing: bounds(window)))")
case "tap", "tap-label", "tap-point":
    guard args.count >= 2 else { fail("target identifier required") }
    let isPoint = verb == "tap-point"
    let count = args.count >= (isPoint ? 4 : 3) ? Int(args[isPoint ? 3 : 2]) ?? 0 : 1
    guard (1...40).contains(count) else { fail("count 1...40") }
    var fixedPoint: CGPoint?
    if isPoint {
        guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]),
              x.isFinite, y.isFinite else { fail("tap-point requires x and y") }
        fixedPoint = CGPoint(x: x, y: y)
    }
    for attempt in 1...count {
        keepPreviewInSafeArea()
        let target: (String, CGPoint)
        if let fixedPoint {
            verify(fixedPoint)
            target = ("verified-point", fixedPoint)
        } else {
            target = verb == "tap" ? find(args[1]) : findLabel(args[1])
        }
        let (id, point) = target
        CGWarpMouseCursorPosition(point)
        postMouse(.mouseMoved, point)
        Thread.sleep(forTimeInterval: 0.13)
        postMouse(.leftMouseDown, point)
        Thread.sleep(forTimeInterval: 0.07)
        postMouse(.leftMouseUp, point)
        print("TAP \(attempt)/\(count) \(id) \(point)")
        Thread.sleep(forTimeInterval: 1.27)
    }
case "scroll":
    guard args.count == 4, let x = Double(args[1]), let y = Double(args[2]),
          let delta = Int32(args[3]), delta != 0, abs(delta) <= 80 else {
        fail("scroll requires x y and -80...-1 or 1...80 lines")
    }
    let point = CGPoint(x: x, y: y)
    keepPreviewInSafeArea()
    verify(point)
    CGWarpMouseCursorPosition(point)
    postMouse(.mouseMoved, point)
    Thread.sleep(forTimeInterval: 0.15)
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                              wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else {
        fail("scroll wheel event creation")
    }
    event.location = point
    event.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 1.0)
    print("SCROLL \(delta) lines at \(point)")
case "type":
    guard args.count == 2, (1...90).contains(args[1].utf16.count),
          args[1].unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value <= 0x7E }) else {
        fail("type requires 1...90 printable ASCII characters")
    }
    // Delivers keyboard events through the same HID route as the measured
    // clicks. The text must be a disposable demo input; never passwords.
    for character in args[1].utf16 {
        var unit = character
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
                fail("keyboard event creation")
            }
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.018)
        }
    }
    print("TYPED \(args[1].utf16.count) characters")
case "return":
    let count = args.count >= 2 ? Int(args[1]) ?? 0 : 1
    guard (1...40).contains(count) else { fail("count 1...40") }
    for attempt in 1...count {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down) else { fail("keyboard event creation") }
            event.flags = []
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.04)
        }
        print("RETURN \(attempt)/\(count)")
        Thread.sleep(forTimeInterval: 1.27)
    }
default: fail("unknown command \(verb)")
}
