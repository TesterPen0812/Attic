// Runs from the Air's authorized terminal session, separate from the UI driver.
import AppKit
import ScreenCaptureKit
let request = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n").map(String.init)
let pid = Int32(request[0])!, backdrop = Int32(request[1])!, path = request[2]
final class Frame: NSObject, SCStreamOutput {
    var image: CGImage?
    let context = CIContext()
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sample.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        image = context.createCGImage(ci, from: ci.extent)
    }
}
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.windows.filter { $0.owningApplication?.processID == pid }
        let back = content.windows.filter { $0.owningApplication?.processID == backdrop && $0.title == "followup-backdrop" }
        guard let display = content.displays.first, let first = own.first, back.count == 1 else {
            throw NSError(domain: "missing preview/backdrop windows", code: 1)
        }
        let crop = own.reduce(first.frame) { $0.union($1.frame) }.intersection(display.frame)
        let filter = SCContentFilter(display: display, including: own + back)
        let config = SCStreamConfiguration()
        config.sourceRect = crop
        config.width = Int(crop.width); config.height = Int(crop.height)
        config.showsCursor = false
        let frames = Frame()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: .main)
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: 500_000_000)
        try await stream.stopCapture()
        guard let image = frames.image else { throw NSError(domain: "no SCK frame", code: 1) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let panel = own.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }!
        let island = try own.first { $0.frame.width < 100 && $0.frame.height > 100 }.unwrap("missing standing island")
        func average(_ point: CGPoint) -> [Double] {
            var rgb = [Double](repeating: 0, count: 3)
            for dx in -1...1 { for dy in -1...1 {
                let color = bitmap.colorAt(x: Int(point.x - crop.minX) + dx, y: Int(point.y - crop.minY) + dy)!.usingColorSpace(.deviceRGB)!
                for (i, channel) in [color.redComponent, color.greenComponent, color.blueComponent].enumerated() { rgb[i] += Double(channel) * 255 / 9 }
            } }
            return rgb
        }
        // No glyph or selected chip here: the gap between the middle items.
        let islandPoint = CGPoint(x: island.frame.minX + 22 + 13, y: island.frame.minY + 22 + 49)
        // Same relative position through the tint; away from page controls/text.
        let panelPoint = CGPoint(x: panel.frame.midX, y: panel.frame.minY + 40 + (panel.frame.height - 80) * 49 / 99)
        let panelRGB = average(panelPoint), islandRGB = average(islandPoint)
        let difference = zip(panelRGB, islandRGB).map { abs($0 - $1) }
        let result: [String: Any] = ["panelRGB": panelRGB, "islandRGB": islandRGB,
            "absoluteDifference": difference, "panelPoint": [panelPoint.x, panelPoint.y],
            "islandPoint": [islandPoint.x, islandPoint.y], "crop": [crop.minX, crop.minY, crop.width, crop.height],
            "passes": difference.max()! <= 12]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path + ".json"))
        try String(panelRGB.reduce(0,+) / 765).write(toFile: path + ".presence", atomically: true, encoding: .utf8)
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: path))
        print("SCK \(path) previewWindows=\(own.count) backdrop=\(back.count) crop=\(crop)")
        exit(0)
    } catch {
        try? String(describing: error).write(toFile: path + ".error", atomically: true, encoding: .utf8)
        print(error); exit(1)
    }
}
RunLoop.main.run()

extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw NSError(domain: message, code: 1) }; return value
    }
}
