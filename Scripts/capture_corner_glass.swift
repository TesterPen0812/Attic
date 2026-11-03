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
        let back = content.windows.filter { $0.owningApplication?.processID == backdrop && $0.title == "bugs2-backdrop" }
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
        let center = CGPoint(x: panel.frame.midX - crop.minX, y: panel.frame.midY - crop.minY)
        var brightness = 0.0, samples = 0.0
        for dx in stride(from: -40, through: 40, by: 10) {
            for dy in stride(from: -40, through: 40, by: 10) {
                if let color = bitmap.colorAt(x: Int(center.x) + dx, y: Int(center.y) + dy)?.usingColorSpace(.deviceRGB) {
                    brightness += Double(color.redComponent + color.greenComponent + color.blueComponent) / 3
                    samples += 1
                }
            }
        }
        try String(brightness / max(1, samples)).write(toFile: path + ".presence", atomically: true, encoding: .utf8)
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
