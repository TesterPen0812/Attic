// Standalone macOS sandbox probe. Does not depend on, or modify, Attic.
// Privacy: never inspect kCGWindowName or read/capture content of any other app.
// Never request Screen Recording or Accessibility permission.

import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO

func milliseconds(_ body: () -> Void) -> Double {
    let started = CFAbsoluteTimeGetCurrent()
    body()
    return (CFAbsoluteTimeGetCurrent() - started) * 1_000
}

func timings(_ rounds: Int, _ body: () -> Void) -> [String: Any] {
    var durations: [Double] = []
    for _ in 0..<rounds { durations.append(milliseconds(body)) }
    durations.sort()
    return ["iterations": rounds,
            "median_ms": Double((durations[rounds / 2] * 1_000).rounded()) / 1_000,
            "p95_ms": Double((durations[min(rounds - 1, Int(Double(rounds) * 0.95))] * 1_000).rounded()) / 1_000]
}

func bitmapLuma(_ view: NSView) -> Double? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let bytes = rep.bitmapData, rep.samplesPerPixel >= 3 else { return nil }
    let rowBytes = rep.bytesPerRow
    let pixelStride = rep.bitsPerPixel / 8
    guard rowBytes > 0, pixelStride >= 3 else { return nil }
    var total = 0.0
    var count = 0
    for y in Swift.stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 16)) {
        for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 16)) {
            let p = bytes + y * rowBytes + x * pixelStride
            total += (0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2])) / 255
            count += 1
        }
    }
    return count == 0 ? nil : (total / Double(count) * 1_000).rounded() / 1_000
}

func imageLuma(_ image: CGImage) -> Double? {
    let w = 24, h = 24
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let worked = rgba.withUnsafeMutableBytes { bytes -> Double? in
        guard let base = bytes.baseAddress,
              let context = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        for p in stride(from: 0, to: w * h * 4, by: 4) {
            sum += (0.2126 * Double(pixels[p]) + 0.7152 * Double(pixels[p + 1]) + 0.0722 * Double(pixels[p + 2])) / 255
        }
        return (sum / Double(w * h) * 1_000).rounded() / 1_000
    }
    return worked
}

final class BackdropProbe: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var backing: NSWindow!
    var glass: NSVisualEffectView!
    var result: [String: Any] = [:]
    var cases: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            finish(error: "no screen")
            return
        }
        let area = screen.visibleFrame
        let rect = CGRect(x: area.maxX - 166, y: area.maxY - 176, width: 140, height: 140)
        backing = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        backing.level = .floating
        backing.hasShadow = false
        backing.isOpaque = true
        backing.ignoresMouseEvents = true
        backing.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backing.orderOut(nil)

        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        glass = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 140, height: 140))
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        panel.contentView = glass
        panel.orderFrontRegardless()

        result["system"] = ["macos": ProcessInfo.processInfo.operatingSystemVersionString,
                            "compile_flag": "ATTIC_LOCAL_ONLY",
                            "sandbox_env": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
                            "screen_capture_preflight": CGPreflightScreenCaptureAccess(),
                            "accessibility_trusted": AXIsProcessTrusted(),
                            "display_count": NSScreen.screens.count,
                            "screen_scale": screen.backingScaleFactor,
                            "frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
                            "appearance": NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown",
                            "accent_rgba": String(describing: NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .clear)]
        result["wallpaper"] = wallpaper()
        result["wallpaper_url_cost"] = timings(30) {
            for s in NSScreen.screens { _ = NSWorkspace.shared.desktopImageURL(for: s) }
        }
        result["window_list_cost"] = timings(30) {
            _ = CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow, .excludeDesktopElements],
                                           CGWindowID(panel.windowNumber))
        }
        result["appearance_cost"] = timings(200) {
            _ = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            _ = NSColor.controlAccentColor
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.measureCase("baseline", back: nil) }
    }

    func wallpaper() -> [[String: Any]] {
        NSScreen.screens.enumerated().map { index, screen in
            let started = CFAbsoluteTimeGetCurrent()
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
                return ["screen": index, "url_available": false]
            }
            var record: [String: Any] = ["screen": index,
                                         "url_available": true,
                                         "extension": url.pathExtension.lowercased(),
                                         "system_path": url.path.hasPrefix("/System/Library/"),
                                         "file_scheme": url.isFileURL]
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let count = CGImageSourceGetCount(source)
                record["image_readable"] = true
                record["image_count"] = count
                if count > 0 {
                    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                 kCGImageSourceThumbnailMaxPixelSize: 32]
                    if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
                        record["first_frame_luma"] = imageLuma(thumbnail) ?? -1
                    }
                }
            } else {
                record["image_readable"] = false
            }
            record["read_and_sample_ms"] = (Double(((CFAbsoluteTimeGetCurrent() - started) * 1_000_000).rounded()) / 1_000)
            return record
        }
    }

    func measureCase(_ name: String, back: NSColor?) {
        if let back {
            backing.appearance = NSAppearance(named: name == "own_dark_window" ? .darkAqua : .aqua)
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 140, height: 140))
            view.wantsLayer = true
            view.layer?.backgroundColor = back.cgColor
            backing.contentView = view
            backing.orderFrontRegardless()
            panel.orderFrontRegardless()
        } else {
            backing.orderOut(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.glass.displayIfNeeded()
            let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                  kCGNullWindowID) as? [[String: Any]] ?? []
            let below = CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow, .excludeDesktopElements],
                                                    CGWindowID(self.panel.windowNumber)) as? [[String: Any]] ?? []
            let ownID = self.backing.windowNumber
            let panelInfo = all.first { ($0[kCGWindowNumber as String] as? Int) == self.panel.windowNumber }
            let panelBounds = self.rect(panelInfo)
            let overlaps = below.filter { item in
                guard let rect = self.rect(item), let panelBounds else { return false }
                let layer = item[kCGWindowLayer as String] as? Int ?? 0
                let alpha = item[kCGWindowAlpha as String] as? Double ?? 1
                return rect.intersects(panelBounds) && layer >= 0 && alpha > 0.01
            }
            let ownBackingVisible = below.contains { ($0[kCGWindowNumber as String] as? Int) == ownID }
            var ownCacheLuma: Double = -1
            let ownCacheMs = milliseconds { ownCacheLuma = bitmapLuma(self.glass) ?? -1 }
            let caseData: [String: Any] = ["case": name,
                            "panel_in_onscreen_list": panelInfo != nil,
                            "panel_bounds": self.boundsArray(panelBounds),
                            "all_window_count": all.count,
                            "below_count": below.count,
                            "overlap_count": overlaps.count,
                            "own_backing_in_below": ownBackingVisible,
                            "own_backing_appearance": self.backing.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown",
                            "overlaps": overlaps.prefix(6).map { self.safeInfo($0) },
                            "own_glass_view_cache_luma": ownCacheLuma,
                            "own_glass_view_cache_ms": (ownCacheMs * 1_000).rounded() / 1_000]
            self.cases.append(caseData)
            switch name {
            case "baseline": self.measureCase("own_dark_window", back: .black)
            case "own_dark_window": self.measureCase("own_light_window", back: .white)
            case "own_light_window": self.measureCase("after_hide", back: nil)
            default: self.finish(error: nil)
            }
        }
    }

    func rect(_ item: [String: Any]?) -> CGRect? {
        guard let dict = item?[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    func boundsArray(_ rect: CGRect?) -> [Int] {
        guard let rect else { return [] }
        return [Int(rect.minX.rounded()), Int(rect.minY.rounded()),
                Int(rect.width.rounded()), Int(rect.height.rounded())]
    }

    func safeInfo(_ item: [String: Any]) -> [String: Any] {
        let pid = item[kCGWindowOwnerPID as String] as? pid_t ?? -1
        return ["bounds": boundsArray(rect(item)),
                "layer": item[kCGWindowLayer as String] as? Int ?? -999,
                "alpha": item[kCGWindowAlpha as String] as? Double ?? -1,
                "owner_bundle_id": NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"]
    }

    func finish(error: String?) {
        result["cases"] = cases
        result["notes"] = ["CGWindowName deliberately never inspected",
                           "No AX permission requests, ScreenCaptureKit captures, or CGWindow pixel captures performed",
                           "Only own glass NSView cached (not a WindowServer screenshot)"]
        if let error { result["error"] = error }
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            if let json = String(data: data, encoding: .utf8) {
                print("EVIDENCE_JSON=" + json)
                fflush(stdout)
            }
            let ownSandboxOutput = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("backdrop-spike-observations.json")
            do {
                try data.write(to: ownSandboxOutput, options: .atomic)
                print("OWN_SANDBOX_EVIDENCE=written")
            } catch {
                print("OWN_SANDBOX_EVIDENCE=unavailable")
            }
        } catch {
            fputs("Could not serialize JSON evidence\n", stderr)
        }
        NSApplication.shared.terminate(nil)
    }
}

let delegate = BackdropProbe()
let app = NSApplication.shared
app.delegate = delegate
app.run()
