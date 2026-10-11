// Reproducible screen evidence driver: only the permitted Phase X preview.
import AppKit
import CoreGraphics
let bundle = "com.taha.Attic.preview.phasex"
let expectedApp = "/Users/taha/Developer/attic-px-notes/.build/dd-preview/Build/Products/Local/AtticPhaseX.app"
let args = Array(CommandLine.arguments.dropFirst())
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        .first(where: { $0.bundleURL?.standardizedFileURL.path == expectedApp }),
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let panel = windows.filter({ ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier })
        .filter({ (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 200 })
        .max(by: { (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) < (($1[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) }),
      let b = panel[kCGWindowBounds as String] as? [String: CGFloat],
      let id = panel[kCGWindowNumber as String] as? Int else { fatalError("Phase X preview panel is not visible") }
let rect = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
func capture(_ path: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", String(id), path]
    try! p.run(); p.waitUntilExit(); precondition(p.terminationStatus == 0)
}
if args.first == "bounds" { print("window=\(id) x=\(rect.minX) y=\(rect.minY) width=\(rect.width) height=\(rect.height)"); exit(0) }
if args.first == "capture" { capture(args[1]); exit(0) }
precondition(args.first == "drag" && args.count >= 6)
let numbers = args[1...5].map { Double($0)! }
let start = CGPoint(x: rect.minX + numbers[0], y: rect.minY + numbers[1])
let end = CGPoint(x: rect.minX + numbers[2], y: rect.minY + numbers[3])
let duration = numbers[4]
precondition(rect.contains(start) && rect.contains(end))
let flags: CGEventFlags = args.contains("shift") ? .maskShift : []
func post(_ type: CGEventType, at point: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
    e.flags = flags; e.setIntegerValueField(.mouseEventClickState, value: 1)
    e.post(tap: .cghidEventTap)
}
app.activate()
Thread.sleep(forTimeInterval: 0.2)
post(.mouseMoved, at: start); Thread.sleep(forTimeInterval: 0.1)
post(.leftMouseDown, at: start)
let count = max(1, Int(duration * 120))
for index in 1...count {
    let t = CGFloat(index) / CGFloat(count)
    post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
    Thread.sleep(forTimeInterval: duration / Double(count))
}
if let at = args.firstIndex(of: "capture"), args.count > at + 1 {
    Thread.sleep(forTimeInterval: 0.1); capture(args[at + 1])
}
post(.leftMouseUp, at: end)
