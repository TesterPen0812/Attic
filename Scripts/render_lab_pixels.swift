// Standalone Air-only tool. Build with swiftc; NOT part of the app target.
// Adapted click/occlusion checks from ~/AtticReview/uxaudit/kit/drive.swift.
// Captures only the render-lab app's window; never a whole display.
import AppKit
import ApplicationServices
import CoreMedia
import QuartzCore
import ScreenCaptureKit

private let bundleID = ProcessInfo.processInfo.environment["ATTIC_LAB_CONTROL"] == "1"
    ? "com.taha.renderlab.control"
    : "com.taha.Attic.preview.renderlab"

private func fail(_ reason: String) -> Never {
    fputs("RENDER_LAB_ERROR \(reason)\n", stderr)
    exit(3)
}

private struct Frame {
    let arrival: Double
    let display: Double
    let rgb: [UInt8]
}

/// Samples RGB from 64×64 points across the window. Do not include the cursor.
/// A material pixel must change by >=12 levels at >=6 sampled locations to
/// count. The spread of results is kept in CSV; the threshold is deliberately
/// conservative against minor glass/material noise.
private final class WindowFrames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Frame] = []
    private let tick: Double
    private var errors: [String] = []

    override init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        tick = Double(info.numer) / Double(info.denom) / 1_000_000_000
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); errors.append(String(describing: error)); lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]])?.first,
              let status = attachments[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let display = attachments[.displayTime] as? UInt64,
              let buffer = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var data = [UInt8]()
        data.reserveCapacity(64 * 64 * 3)
        for y in 0..<64 {
            let row = min(height - 1, ((2 * y + 1) * height) / 128)
            for x in 0..<64 {
                let column = min(width - 1, ((2 * x + 1) * width) / 128)
                let index = row * stride + column * 4
                data.append(bytes[index])
                data.append(bytes[index + 1])
                data.append(bytes[index + 2])
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        let frame = Frame(arrival: CACurrentMediaTime(), display: Double(display) * tick, rgb: data)
        lock.lock()
        samples.append(frame)
        lock.unlock()
    }

    func snapshot() -> [Frame] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    func error() -> String? {
        lock.lock(); defer { lock.unlock() }
        return errors.first
    }

    static func changed(_ old: [UInt8], _ new: [UInt8], rows: ClosedRange<Int> = 0...63) -> Int {
        guard old.count == new.count else { return 0 }
        var changed = 0
        for y in rows {
            for x in 0..<64 {
                let i = (y * 64 + x) * 3
                let gap = abs(Int(old[i]) - Int(new[i])) +
                    abs(Int(old[i + 1]) - Int(new[i + 1])) +
                    abs(Int(old[i + 2]) - Int(new[i + 2]))
                if gap >= 36 { changed += 1 }
            }
        }
        return changed
    }
}

@MainActor
private func run() async throws {
    let a = CommandLine.arguments
    guard (a.count == 6 || a.count == 7 || a.count == 8), ["--run", "--scroll", "--toggle", "--dismiss"].contains(a[1]),
          let idle = Double(a[4]), idle >= 0 && idle <= 60,
          let rounds = Int(a[5]), rounds >= 1 && rounds <= 12,
          AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
        fail("usage: --run|--scroll|--toggle|--dismiss target-id warm-id idle-s rounds [out.csv] [setup-page-id]; needs prior AX and recording permission")
    }
    let scrollMode = a[1] == "--scroll"
    let toggleMode = a[1] == "--toggle"
    let dismissMode = a[1] == "--dismiss"
    let targetID = a[2], warmID = a[3]
    let output = a.count >= 7 ? a[6] : "/tmp/render-lab-pixels.csv"
    let setupPage = a.count == 8 ? a[7] : nil
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    guard session["CGSSessionScreenIsLocked"] as? Bool != true else { fail("screen locked") }
    let mods: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
    guard CGEventSource.flagsState(.combinedSessionState).intersection(mods).isEmpty else { fail("modifier down") }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
          app.bundleIdentifier == bundleID else { fail("render-lab identity not running") }
    let pid = app.processIdentifier
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 1)

    func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(node, key as CFString, &v)
        return v
    }
    func string(_ node: AXUIElement, _ key: String) -> String {
        attribute(node, key).map { String(describing: $0) } ?? ""
    }
    func descendants() -> [AXUIElement] {
        var nodes = [AXUIElement]()
        func walk(_ node: AXUIElement, _ depth: Int) {
            guard depth <= 28, nodes.count < 4000 else { return }
            nodes.append(node)
            if string(node, "AXRole") == "AXMenuBar" { return }
            for child in attribute(node, "AXChildren") as? [AXUIElement] ?? [] { walk(child, depth + 1) }
        }
        walk(ax, 0)
        return nodes
    }
    func rectangle(_ node: AXUIElement) -> CGRect? {
        guard let p = attribute(node, "AXPosition"), let s = attribute(node, "AXSize"),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pos),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }
    func point(_ id: String) -> CGPoint {
        let nodes = descendants()
        let node = id.hasPrefix("label:")
            ? nodes.first(where: { string($0, "AXLabel") == String(id.dropFirst(6)) })
            : nodes.first(where: { string($0, "AXIdentifier") == id })
        guard let node,
              let rect = rectangle(node), rect.width > 1 && rect.height > 1 else { fail("AX id unavailable: \(id)") }
        return CGPoint(x: rect.midX, y: rect.midY)
    }
    func windows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
    }
    func bounds(_ window: [String: Any]) -> CGRect? {
        guard let b = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"] else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    func check(_ p: CGPoint) {
        guard let window = windows().first(where: {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
            (bounds($0)?.width ?? 0) > 200 && (bounds($0)?.height ?? 0) > 200
        }), bounds(window)?.contains(p) == true else { fail("point outside own panel") }
        for w in windows() {
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if alpha <= 0.01 || layer >= 1000 || [24, 25].contains(layer) ||
                (owner == "Dock" && layer == 20) || owner == "Notification Center" { continue }
            if bounds(w)?.contains(p) == true {
                guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { fail("covered by another app") }
                return
            }
        }
        fail("own window missing under target")
    }
    func move(_ p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!
        e.flags = []
        e.post(tap: .cghidEventTap)
    }
    func click(_ p: CGPoint, alreadyPositioned: Bool = false) async -> (Double, Double) {
        check(p)
        if !alreadyPositioned {
            move(p)
            try? await Task.sleep(for: .milliseconds(180)) // let hover settle before the baseline frame
        }
        let down = CACurrentMediaTime()
        for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
            e.flags = []
            e.post(tap: .cghidEventTap)
            if type == .leftMouseDown { try? await Task.sleep(for: .milliseconds(35)) }
        }
        return (down, CACurrentMediaTime())
    }

    func wheel(_ p: CGPoint) async -> (Double, Double) {
        check(p)
        let down = CACurrentMediaTime()
        for n in 0..<22 {
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: n == 0 ? 0 : -15, wheel2: 0, wheel3: 0)!
            e.flags = []
            e.location = p
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: n == 0 ? 1 : 2)
            e.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(10))
        }
        let end = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                          wheel1: 0, wheel2: 0, wheel3: 0)!
        end.flags = []
        end.location = p
        end.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        end.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        end.post(tap: .cghidEventTap)
        return (down, down) // scroll latency starts at the first synthetic wheel event
    }

    func escape() async -> (Double, Double) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            fail("own render-lab app is not active before Escape")
        }
        let down = CACurrentMediaTime()
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(53), keyDown: keyDown) else {
                fail("failed to build Escape event")
            }
            event.flags = []
            event.post(tap: .cghidEventTap)
            if keyDown { try? await Task.sleep(for: .milliseconds(35)) }
        }
        return (down, CACurrentMediaTime())
    }

    if targetID == "--dump" || targetID == "--dump-all" {
        if let setupPage {
            _ = await click(point(setupPage))
            try await Task.sleep(for: .milliseconds(800))
        }
        for n in descendants() {
            let id = string(n, "AXIdentifier")
            let role = string(n, "AXRole")
            if !id.isEmpty || (targetID == "--dump-all" &&
                (role == "AXStaticText" || role == "AXButton" || role == "AXGroup")) {
                let label = string(n, "AXLabel")
                let title = string(n, "AXTitle")
                print("AX \(id) role=\(role) label=\(label.prefix(110)) title=\(title.prefix(60)) frame=\(rectangle(n)?.debugDescription ?? "none")")
            }
        }
        return
    }
    guard let window = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        .windows.filter({ $0.owningApplication?.processID == pid && $0.frame.width > 200 && $0.frame.height > 200 })
        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { fail("own window unavailable for capture") }
    let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
    let scale = screen?.backingScaleFactor ?? 2
    let config = SCStreamConfiguration()
    config.width = max(1, Int(window.frame.width * scale))
    config.height = max(1, Int(window.frame.height * scale))
    config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    config.queueDepth = 6
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    config.pixelFormat = kCVPixelFormatType_32BGRA
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let watcher = WindowFrames()
    let outputQueue = DispatchQueue(label: "com.taha.render-lab.pixels")
    let stream = SCStream(filter: filter, configuration: config, delegate: watcher)
    try stream.addStreamOutput(watcher, type: .screen, sampleHandlerQueue: outputQueue)
    try await stream.startCapture()
    print("STREAM_READY pid=\(pid) window=\(window.windowID) pixels=\(config.width)x\(config.height) refresh=\(screen?.maximumFramesPerSecond ?? 0)")
    print("trial,kind,click_down_s,release_s,first_display_ms,first_callback_ms,capture_bias_ms,changed_cells,frames,frame_gap_p90_ms,frame_gap_max_ms,top_row_ms,bottom_row_ms,any_4_ms,any_8_ms,top_settled_ms,bottom_settled_ms")

    let outURL = URL(fileURLWithPath: output)
    var csv = "trial,kind,click_down_s,release_s,first_display_ms,first_callback_ms,capture_bias_ms,changed_cells,frames,frame_gap_p90_ms,frame_gap_max_ms,top_row_ms,bottom_row_ms,any_4_ms,any_8_ms,top_settled_ms,bottom_settled_ms\n"
    if let setupPage {
        _ = await click(point(setupPage))
        try await Task.sleep(for: .milliseconds(800))
    }
    for trial in 1...rounds {
        if let error = watcher.error() { fail(error) }
        if !scrollMode && !toggleMode && !dismissMode { _ = await click(point(warmID)) } // reset selection before tab/action trials
        try await Task.sleep(for: .milliseconds(600))
        let target = point(targetID)
        if dismissMode {
            _ = await click(target)
            try await Task.sleep(for: .milliseconds(650))
        }
        move(target)
        try await Task.sleep(for: .milliseconds(300))
        try await Task.sleep(for: .seconds(idle))
        for kind in ["cold", "repeat"] {
            if kind == "repeat" {
                if dismissMode {
                    _ = await click(point(targetID))
                    try await Task.sleep(for: .milliseconds(650))
                    move(target)
                    try await Task.sleep(for: .milliseconds(250))
                } else if toggleMode {
                    _ = await escape()
                    try await Task.sleep(for: .milliseconds(650))
                    move(point(targetID))
                    try await Task.sleep(for: .milliseconds(250))
                } else if !scrollMode {
                    _ = await click(point(warmID))
                    try await Task.sleep(for: .milliseconds(300))
                    move(point(targetID))
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            let p = dismissMode ? target : point(targetID)
            let before = watcher.snapshot()
            let eventTimes: (Double, Double)
            if scrollMode { eventTimes = await wheel(p) }
            else if dismissMode { eventTimes = await escape() }
            else { eventTimes = await click(p, alreadyPositioned: true) }
            let (down, release) = eventTimes
            try await Task.sleep(for: .milliseconds(900))
            let after = watcher.snapshot()
            guard let original = before.last(where: { $0.arrival < down }) else { fail("no baseline frame") }
            let visible = after.filter { $0.arrival >= release - 0.03 && $0.arrival < release + 0.9 }
            let first = visible.first { $0.display >= down && WindowFrames.changed(original.rgb, $0.rgb) >= 16 }
            let first4 = visible.first { $0.display >= down && WindowFrames.changed(original.rgb, $0.rgb) >= 4 }
            let first8 = visible.first { $0.display >= down && WindowFrames.changed(original.rgb, $0.rgb) >= 8 }
            // The top row and bottom controls occupy narrow strips of the
            // panel. These are auxiliary timings, not substitutes for the
            // first material change across the whole captured window.
            let top = visible.first { $0.display >= down && WindowFrames.changed(original.rgb, $0.rgb, rows: 4...12) >= 4 }
            let bottom = visible.first { $0.display >= down && WindowFrames.changed(original.rgb, $0.rgb, rows: 50...58) >= 4 }
            // Approximate visual settling against the last captured frame.
            // This measures a distinct question from first visible movement;
            // report only where the measured strip genuinely reaches a stable
            // final image within the 900-ms capture interval.
            func settled(in rows: ClosedRange<Int>) -> Frame? {
                guard let final = visible.last else { return nil }
                let total = WindowFrames.changed(original.rgb, final.rgb, rows: rows)
                guard total >= 4 else { return nil }
                let tolerance = max(2, Int(Double(total) * 0.1))
                return visible.first {
                    $0.display >= down && WindowFrames.changed($0.rgb, final.rgb, rows: rows) <= tolerance
                }
            }
            let topSettled = settled(in: 4...12)
            let bottomSettled = settled(in: 50...58)
            let gaps = zip(visible, visible.dropFirst()).map { ($1.display - $0.display) * 1000 }.sorted()
            let p90 = gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.9))]
            let maxGap = gaps.last ?? 0
            let changed = first.map { WindowFrames.changed(original.rgb, $0.rgb) } ?? 0
            func ms(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "NA" }
            let row = "\(trial),\(kind),\(ms(down)),\(ms(release)),\(ms(first.map { ($0.display - release) * 1000 })),\(ms(first.map { ($0.arrival - release) * 1000 })),\(ms(first.map { ($0.arrival - $0.display) * 1000 })),\(changed),\(visible.count),\(ms(p90)),\(ms(maxGap)),\(ms(top.map { ($0.display - release) * 1000 })),\(ms(bottom.map { ($0.display - release) * 1000 })),\(ms(first4.map { ($0.display - release) * 1000 })),\(ms(first8.map { ($0.display - release) * 1000 })),\(ms(topSettled.map { ($0.display - release) * 1000 })),\(ms(bottomSettled.map { ($0.display - release) * 1000 }))"
            print(row)
            csv += row + "\n"
        }
    }
    try await stream.stopCapture()
    try csv.write(to: outURL, atomically: true, encoding: .utf8)
    print("OUTPUT \(outURL.path) frames=\(watcher.snapshot().count)")
}

Task { @MainActor in
    do { try await run(); exit(0) }
    catch { fail(String(describing: error)) }
}
RunLoop.main.run()
