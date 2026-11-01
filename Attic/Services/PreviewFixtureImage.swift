import AppKit

/// Synthetic pixels shared by explicit preview and crash-test fixtures.
@MainActor
enum PreviewFixtureImage {
    /// A small palette image (four soft swatches).
    static func png() throws -> Data {
        let size = 320
        guard let context = CGContext(data: nil, width: size, height: size / 2, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let swatches: [(CGFloat, CGFloat, CGFloat)] = [(0.93, 0.91, 0.88), (0.80, 0.77, 0.73), (0.55, 0.53, 0.50), (0.85, 0.45, 0.30)]
        for (index, colour) in swatches.enumerated() {
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fill(CGRect(x: index * size / 4, y: 0, width: size / 4, height: size / 2))
        }
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
