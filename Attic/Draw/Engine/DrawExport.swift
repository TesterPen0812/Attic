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

    static func bounds(_ objects: [DrawObject]) -> CGRect? { nil }
    static func render(_ objects: [DrawObject], format: DrawExportFormat, dark: Bool) -> Data? { nil }
}

/// The library's thumbnails: rendered off the main thread from a snapshot,
/// sharp at the menu's 22 × 16.5 pt and in Search's results.
enum DrawThumbnail {
    static let pixelSize = CGSize(width: 88, height: 66)
    static func render(_ objects: [DrawObject], dark: Bool) -> Data? { nil }
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
