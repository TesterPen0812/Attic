import AppKit
import CoreGraphics
import QuartzCore

let args = Array(CommandLine.arguments.dropFirst())
func value(_ key: String) -> String? {
    guard let i = args.firstIndex(of:key), i+1 < args.count else { return nil }; return args[i+1]
}
func refuse(_ message: String) -> Never { fputs("REFUSED \(message)\n",stderr); exit(3) }
// Quit path uses Launch Services' owned-app API, avoiding Apple Events/TCC prompts.
if args.contains("--quit-owned") {
    guard let pidText = value("--pid"),let pid = Int32(pidText),let path = value("--app"),
          let bundle = Bundle(path:path),let identity = bundle.bundleIdentifier,
          identity.hasPrefix("com.taha.Attic.lab.canvas-"),let expected = bundle.executableURL,
          let running = NSRunningApplication.runningApplications(withBundleIdentifier:identity).first(where: { $0.processIdentifier == pid }) else { refuse("quit ownership") }
    var bytes = [CChar](repeating:0,count:4096)
    guard proc_pidpath(pid,&bytes,UInt32(bytes.count)) > 0,
          URL(fileURLWithPath:String(cString:bytes)).resolvingSymlinksInPath() == expected.resolvingSymlinksInPath(),
          running.terminate() else { refuse("quit executable/termination") }
    let deadline = CACurrentMediaTime()+5
    while !running.isTerminated && CACurrentMediaTime()<deadline { Thread.sleep(forTimeInterval:0.01) }
    guard running.isTerminated else { refuse("quit timeout; leave process for inspection") }
    exit(0)
}
guard args.contains("--allow-post"), let pidText = value("--pid"), let pid = Int32(pidText),
      let appPath = value("--app"), let output = value("--output"),
      let duration = Double(value("--seconds") ?? "10"), duration >= 1, duration <= 35,
      let bundle = Bundle(path:appPath), let bundleID = bundle.bundleIdentifier,
      bundleID.hasPrefix("com.taha.Attic.lab.canvas-"), let expectedExecutable = bundle.executableURL else {
    refuse("requires --allow-post --pid PID --app EXACT_LAB_APP --output FILE [--seconds 10]")
}
func guardWindow() -> CGRect {
    var bytes = [CChar](repeating:0,count:4096)
    guard proc_pidpath(pid,&bytes,UInt32(bytes.count)) > 0,
          URL(fileURLWithPath:String(cString:bytes)).resolvingSymlinksInPath() == expectedExecutable.resolvingSymlinksInPath(),
          NSRunningApplication(processIdentifier:pid)?.bundleIdentifier == bundleID,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { refuse("exact lab is not frontmost/owned") }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
    let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    guard owned.count == 1, let bounds = owned[0][kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation:bounds), rect.width == 320, rect.height == 520 else { refuse("expected one compact lab window") }
    for row in windows {
        if (row[kCGWindowNumber as String] as? Int) == (owned[0][kCGWindowNumber as String] as? Int) { break }
        guard (row[kCGWindowOwnerPID as String] as? Int32) != pid,
              (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              (row[kCGWindowLayer as String] as? Int ?? -1) >= 0,
              let b = row[kCGWindowBounds as String] as? NSDictionary, let other = CGRect(dictionaryRepresentation:b) else { continue }
        if other.intersects(rect) { refuse("another window overlaps the lab; leave it untouched") }
    }
    return rect
}
guard CGPreflightPostEventAccess() else { refuse("pre-existing Accessibility permission is required") }
let frame = guardWindow()
FileManager.default.createFile(atPath:output,contents:Data("sequence,type,event_monotonic_s,post_s,x,y,phase\n".utf8))
let log = try FileHandle(forWritingTo:URL(fileURLWithPath:output)); try log.seekToEnd()
var sequence: Int64 = 0
@MainActor func post(_ event: CGEvent, point: CGPoint, phase: String) {
    let current = guardWindow() // recheck before EVERY event; never activates another app
    guard current == frame, current.contains(point) else { refuse("window geometry changed or target outside lab") }
    sequence += 1
    event.setIntegerValueField(.eventSourceUserData,value:sequence)
    event.timestamp = LabClock.eventTimestamp()
    let eventTime = LabClock.seconds(eventTimestamp:event.timestamp), now = CACurrentMediaTime()
    event.post(tap:.cghidEventTap)
    log.write(Data("\(sequence),\(event.type.rawValue),\(eventTime),\(now),\(point.x),\(point.y),\(phase)\n".utf8))
}
@MainActor func ink(seconds: Double, phase: String) {
    let count = Int(seconds*120), start = CACurrentMediaTime()
    var last = CGPoint.zero
    for i in 0...count {
        let deadline = start + Double(i)/120
        let delay = deadline-CACurrentMediaTime(); if delay > 0 { Thread.sleep(forTimeInterval:delay) }
        // Progressive zigzag, including sharp turns, deterministic across modes.
        let t = Double(i)/Double(count), row = t*26, fraction = row-floor(row)
        let x = Int(row)%2 == 0 ? fraction : 1-fraction
        last = CGPoint(x:frame.minX+22+x*276,y:frame.minY+75+t*365)
        let type: CGEventType = i == 0 ? .leftMouseDown : .leftMouseDragged
        guard let e = CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:last,mouseButton:.left) else { refuse("event allocation") }
        e.flags = []; post(e,point:last,phase:phase)
    }
    let up = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:last,mouseButton:.left)!
    up.flags = []; post(up,point:last,phase:phase)
}
if args.contains("--transitions") {
    for (i, offset) in [0.0,0.002,0.008,0.020].enumerated() {
        let point = CGPoint(x:frame.midX,y:frame.midY)
        let scroll = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:8,wheel2:4,wheel3:0)!
        scroll.location = point; scroll.flags = i%2 == 0 ? [] : .maskCommand
        post(scroll,point:point,phase:"transition_\(i)")
        if offset > 0 { Thread.sleep(forTimeInterval:offset) }
        ink(seconds:1,phase:"after_transition_\(i)")
    }
} else { ink(seconds:duration,phase:"ink") }
try log.close()
