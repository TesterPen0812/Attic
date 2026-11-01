import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// One worker, one replaceable pending request (ported from the lab's
/// `LatestRenderer`, `CanvasLab/Core/LabCore.swift`, which Attic doesn't
/// link). The latest request wins; delivery checks the generation again on
/// the main queue, so a finished but stale result is dropped too.
final class DrawLatestRenderer<Request: Sendable, Output: Sendable>: @unchecked Sendable {
    typealias Work = @Sendable (Request, @escaping @Sendable () -> Bool) -> Output?
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "attic.draw.raster", qos: .userInitiated)
    private var generation = 0
    private var pending: (Int, Request)?
    private var running = false
    private let work: Work
    private let install: @MainActor (Request, Output) -> Void

    init(work: @escaping Work, install: @escaping @MainActor (Request, Output) -> Void) {
        self.work = work
        self.install = install
    }

    func request(_ request: Request) {
        lock.lock()
        generation += 1
        pending = (generation, request)
        let start = !running
        running = true
        lock.unlock()
        if start { worker.async { self.drain() } }
    }

    /// Drops whatever is queued or running (the board went away).
    func cancel() {
        lock.lock()
        generation += 1
        pending = nil
        lock.unlock()
    }

    private func current(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (token, request) = pending else { running = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            guard let output = work(request, { !self.current(token) }) else { continue }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.current(token) else { return }
                    self.install(request, output)
                }
            }
        }
    }
}

/// Everything a committed raster depends on. An installed raster whose key
/// differs from the board's current key is stale and never shown.
struct DrawRasterKey: Equatable, Sendable {
    /// The page's content revision (every applied change advances it).
    var revision = 0
    var viewport = DrawViewport()
    var size = CGSize.zero
    var scale: CGFloat = 2
    var dark = false
    /// What the raster leaves out (the text box being edited, strokes the
    /// eraser is crossing) and what it draws moved (a selection being dragged).
    var hidden: Set<UUID> = []
    var moved: Set<UUID> = []
    var offset = CGPoint.zero
    /// Objects drawn in their live geometry (a handle drag), by frame.
    var replaced: [UUID: DrawFrame] = [:]
}

struct DrawRasterRequest: Sendable {
    let key: DrawRasterKey
    /// The page's ordered objects (an immutable copy-on-write value; never
    /// rebuilt for the request).
    let objects: [DrawObject]
    /// The live geometry `key.replaced` names.
    var replacements: [UUID: DrawObject] = [:]
}

struct DrawRasterImage: @unchecked Sendable { let image: CGImage }

/// Test seam (the no-stall rule, restart plan §2): counts committed rasters,
/// and how many ran on the main thread, where none may.
enum DrawRasterProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts = (all: 0, main: 0)

    static var rasters: Int { lock.lock(); defer { lock.unlock() }; return counts.all }
    static var mainThreadRasters: Int { lock.lock(); defer { lock.unlock() }; return counts.main }

    static func record() {
        let main = Thread.isMainThread
        lock.lock()
        counts.all += 1
        if main { counts.main += 1 }
        lock.unlock()
    }

    static func reset() { lock.lock(); counts = (0, 0); lock.unlock() }
}

/// The committed board: every object at the request's viewport, on a clear
/// background (the dots are their own layer). Runs on the renderer's worker.
enum DrawRaster {
    private static let imageCache = NSCache<NSString, CGImage>()

    static func render(_ request: DrawRasterRequest, cancelled: () -> Bool = { false }) -> DrawRasterImage? {
        DrawRasterProbe.record()
        let key = request.key
        let width = Int((key.size.width * key.scale).rounded(.up)), height = Int((key.size.height * key.scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // y down, as the world and the screen points are.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: key.scale, y: -key.scale)
        context.concatenate(key.viewport.transform)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let palette = DrawPalette(dark: key.dark)
        let visible = CGRect(origin: .zero, size: key.size)
        for (index, original) in request.objects.enumerated() {
            if index % 32 == 0, cancelled() { return nil }
            guard !key.hidden.contains(original.id) else { continue }
            let object = request.replacements[original.id] ?? (key.moved.contains(original.id)
                ? original.translated(by: DrawPoint(x: key.offset.x, y: key.offset.y), id: original.id) : original)
            // Off-screen objects cost nothing.
            let reach = DrawGeometry.bounds(object).insetBy(dx: -8, dy: -8)
            guard key.viewport.screen(reach).intersects(visible) else { continue }
            draw(object, in: context, palette: palette)
        }
        guard !cancelled(), let image = context.makeImage() else { return nil }
        return DrawRasterImage(image: image)
    }

    static func draw(_ object: DrawObject, in context: CGContext, palette: DrawPalette, fullResolution: Bool = false) {
        let colour = palette.cgColor(object.style.colour)
        switch object.content {
        case .stroke, .shape:
            guard let path = DrawGeometry.path(object) else { return }
            context.addPath(path)
            context.setStrokeColor(colour)
            context.setLineWidth(DrawGeometry.strokeWidth(object))
            context.strokePath()
        case .text(let text):
            let scale = CGFloat(object.textScale ?? 1)
            if scale != 1, scale > 0 {
                // Laid out at the style's size and drawn scaled: the same lines.
                context.saveGState()
                context.translateBy(x: object.frame.x, y: object.frame.y)
                context.scaleBy(x: scale, y: scale)
                drawText(text, at: .zero, size: object.style.size.textSize,
                         width: object.textWidth.map { CGFloat($0) / scale }, colour: colour, in: context)
                context.restoreGState()
            } else {
                drawText(text, at: CGPoint(x: object.frame.x, y: object.frame.y), size: object.style.size.textSize,
                         width: object.textWidth.map { CGFloat($0) }, colour: colour, in: context)
            }
        case .image(let image):
            drawImage(image, id: object.id, in: DrawGeometry.frame(object.frame), context: context, dark: palette.dark,
                      fullResolution: fullResolution)
        }
    }

    static func drawText(_ text: String, at origin: CGPoint, size: Double, width: CGFloat? = nil, colour: CGColor, in context: CGContext) {
        let fontSize = CGFloat(size)
        for (index, line) in DrawText.lines(text, size: fontSize, width: width).enumerated() where !line.isEmpty {
            let ctLine = DrawText.line(line, size: fontSize, colour: colour)
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y + fontSize * DrawText.baseline + CGFloat(index) * fontSize * DrawText.lineHeight)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    /// An image drawn from a copy decoded at the size it covers on the
    /// device (in steps, cached), never the 6000 px original, on a quiet
    /// tile if it can't be read. Exports to PDF draw the full resolution.
    static func drawImage(_ image: DrawImage, id: UUID, in rect: CGRect, context: CGContext, dark: Bool,
                          fullResolution: Bool = false) {
        let clip = CGPath(roundedRect: rect, cornerWidth: min(8, rect.width / 2), cornerHeight: min(8, rect.height / 2), transform: nil)
        context.saveGState()
        context.addPath(clip)
        context.clip()
        let full = max(image.pixelWidth, image.pixelHeight, 1)
        let side: Int
        if fullResolution {
            side = full
        } else {
            let device = rect.applying(context.userSpaceToDeviceSpaceTransform)
            let wanted = Int(max(abs(device.width), abs(device.height)).rounded(.up))
            // Power-of-two steps, so a zoom or a resize reuses the copy.
            var step = 64
            while step < wanted { step *= 2 }
            side = min(step, full)
        }
        if let decoded = decoded(image, id: id, side: side) {
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(decoded, in: CGRect(origin: .zero, size: rect.size))
        } else {
            context.setFillColor(CGColor(gray: dark ? 0.25 : 0.88, alpha: 1))
            context.fill(rect)
        }
        context.restoreGState()
    }

    /// The image decoded with its longest side at most `side` pixels.
    static func decoded(_ image: DrawImage, id: UUID, side: Int) -> CGImage? {
        let cacheKey = "\(id.uuidString)-\(image.original.count)-\(side)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        guard let source = CGImageSourceCreateWithData(image.original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        guard let made = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        DrawImageDecodeProbe.record(pixelSide: max(made.width, made.height))
        // A full-resolution export copy isn't kept.
        if made.width * made.height <= 4096 * 4096 { imageCache.setObject(made, forKey: cacheKey) }
        return made
    }
}
