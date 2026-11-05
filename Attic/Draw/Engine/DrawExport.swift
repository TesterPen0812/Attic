import CoreGraphics
import Foundation
import ImageIO

enum DrawExportFormat: Sendable { case png, pdf }

/// Export… and Copy as Image: the content's bounds plus a margin, on the
/// board's colour, without dots. PNG at 2×; PDF as vectors from the same
/// drawing code, with images at full resolution. Runs off the main thread.
enum DrawExport {
    static let margin: CGFloat = 16
    static let pngScale: CGFloat = 2
    private static let maxPNGSide = 16_384
    private static let maxPNGPixelCount = 16_777_216

    /// Validate before floating-point to integer conversion or bitmap allocation.
    static func pngPixelSize(for bounds: CGRect) -> CGSize? {
        guard [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY,
               bounds.width, bounds.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0 else { return nil }
        let width = (bounds.width * pngScale).rounded(.up)
        let height = (bounds.height * pngScale).rounded(.up)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= CGFloat(maxPNGSide), height <= CGFloat(maxPNGSide),
              width * height <= CGFloat(maxPNGPixelCount) else { return nil }
        return CGSize(width: Int(width), height: Int(height))
    }

    /// What an export covers: the content's bounds plus the margin.
    static func bounds(_ objects: [DrawObject]) -> CGRect? {
        DrawGeometry.union(objects)?.insetBy(dx: -margin, dy: -margin)
    }

    static func render(_ objects: [DrawObject], format: DrawExportFormat, dark: Bool) -> Data? {
        guard let bounds = bounds(objects) else { return nil }
        switch format {
        case .png:
            guard let pixels = pngPixelSize(for: bounds),
                  let image = DrawBitmap.render(objects, pixels: pixels, dark: dark,
                                                place: { context in
                context.scaleBy(x: pngScale, y: pngScale)
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
            }) else { return nil }
            return DrawBitmap.png(image)
        case .pdf:
            let data = NSMutableData()
            var box = CGRect(origin: .zero, size: bounds.size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
            context.beginPDFPage(nil)
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            DrawBitmap.paint(objects, in: context, background: bounds, dark: dark, fullResolution: true)
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }
    }
}

/// The library's thumbnails: rendered off the main thread from a snapshot,
/// sharp at the menu's 22 × 16.5 pt and in Search's results.
enum DrawThumbnail {
    static let pixelSize = CGSize(width: 88, height: 66)

    /// The content fitted into the card with a small margin; nil while the
    /// canvas is empty (the empty card shows).
    static func render(_ objects: [DrawObject], dark: Bool) -> Data? {
        guard let content = DrawGeometry.union(objects) else { return nil }
        let inset: CGFloat = 4
        let room = CGSize(width: pixelSize.width - inset * 2, height: pixelSize.height - inset * 2)
        let scale = min(room.width / max(content.width, 1), room.height / max(content.height, 1), 2)
        guard let image = DrawBitmap.render(objects, pixels: pixelSize, dark: dark, place: { context in
            context.translateBy(x: (pixelSize.width - content.width * scale) / 2, y: (pixelSize.height - content.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -content.minX, y: -content.minY)
        }) else { return nil }
        return DrawBitmap.png(image)
    }
}

/// An opaque bitmap of objects on the board colour (exports, copies and
/// thumbnails), y down like the world.
enum DrawBitmap {
    static func render(_ objects: [DrawObject], pixels: CGSize, dark: Bool, place: (CGContext) -> Void) -> CGImage? {
        let width = Int(pixels.width), height = Int(pixels.height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(DrawPalette(dark: dark).board)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        place(context)
        paint(objects, in: context, background: nil, dark: dark, fullResolution: false)
        return context.makeImage()
    }

    static func paint(_ objects: [DrawObject], in context: CGContext, background: CGRect?, dark: Bool, fullResolution: Bool) {
        let palette = DrawPalette(dark: dark)
        if let background {
            context.setFillColor(palette.board)
            context.fill(background)
        }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for object in objects where object.deletedAt == nil {
            DrawRaster.draw(object, in: context, palette: palette, fullResolution: fullResolution)
        }
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Test seam (no stalls): counts image decodes, and how many ran on the
/// main thread, where none may, and the largest decoded side.
enum DrawImageDecodeProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts = (all: 0, main: 0, largest: 0)

    static var decodes: Int { lock.lock(); defer { lock.unlock() }; return counts.all }
    static var mainThreadDecodes: Int { lock.lock(); defer { lock.unlock() }; return counts.main }
    static var largestPixelSide: Int { lock.lock(); defer { lock.unlock() }; return counts.largest }

    static func record(pixelSide: Int) {
        let main = Thread.isMainThread
        lock.lock()
        counts.all += 1
        if main { counts.main += 1 }
        counts.largest = max(counts.largest, pixelSide)
        lock.unlock()
    }

    static func reset() { lock.lock(); counts = (0, 0, 0); lock.unlock() }
}

extension DrawPalette {
    /// The board's colour (the drawing's white card; a near-black board in
    /// dark mode, where Ink turns light): exports, copies and thumbnails sit on it.
    var boardComponents: (red: Double, green: Double, blue: Double) {
        dark ? (28 / 255, 28 / 255, 30 / 255) : (1, 1, 1)
    }

    var board: CGColor {
        let c = boardComponents
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}
