import Foundation
@preconcurrency import ImageIO
import CoreText
import UniformTypeIdentifiers

enum CanvasImageImportError: LocalizedError, Equatable {
    case inputTooLarge
    case unsupportedOrCorrupt
    case invalidDimensions
    case outputTooLarge
    case unableToReadFile
    case unableToEncode

    var errorDescription: String? {
        switch self {
        case .inputTooLarge:
            "The image is too large to import safely."
        case .unsupportedOrCorrupt:
            "The dropped item is not a supported image or is corrupt."
        case .invalidDimensions:
            "The image has invalid dimensions."
        case .outputTooLarge:
            "The image remains too large after optimisation."
        case .unableToReadFile:
            "Attic could not read the dropped image."
        case .unableToEncode:
            "Attic could not prepare the image for the canvas."
        }
    }
}

struct CanvasImageImportPolicy: Equatable, Sendable {
    let maximumInputBytes: Int
    let maximumEncodedBytes: Int
    let maximumPixelDimension: Int

    static let standard = CanvasImageImportPolicy(
        maximumInputBytes: 64 * 1_024 * 1_024,
        maximumEncodedBytes: 8 * 1_024 * 1_024,
        maximumPixelDimension: 4_096
    )

    init(
        maximumInputBytes: Int,
        maximumEncodedBytes: Int,
        maximumPixelDimension: Int
    ) {
        self.maximumInputBytes = max(maximumInputBytes, 1)
        self.maximumEncodedBytes = max(maximumEncodedBytes, 1)
        self.maximumPixelDimension = max(maximumPixelDimension, 64)
    }
}

enum CanvasImageImporter {
    static func prepare(
        url: URL,
        policy: CanvasImageImportPolicy = .standard
    ) async throws -> CanvasPreparedImage {
        let data = try await readBytes(url: url, policy: policy)
        return try await prepare(data: data, policy: policy)
    }

    static func prepare(
        data: Data,
        policy: CanvasImageImportPolicy = .standard
    ) async throws -> CanvasPreparedImage {
        guard data.count <= policy.maximumInputBytes else {
            throw CanvasImageImportError.inputTooLarge
        }

        return try await Task.detached(priority: .userInitiated) {
            try process(data: data, policy: policy)
        }.value
    }

    private static func readBytes(
        url: URL,
        policy: CanvasImageImportPolicy
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let accessedScope = url.startAccessingSecurityScopedResource()
            defer {
                if accessedScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey
                ])
                guard values.isRegularFile != false else {
                    throw CanvasImageImportError.unableToReadFile
                }
                if let fileSize = values.fileSize,
                   fileSize > policy.maximumInputBytes {
                    throw CanvasImageImportError.inputTooLarge
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count <= policy.maximumInputBytes else {
                    throw CanvasImageImportError.inputTooLarge
                }
                return data
            } catch let error as CanvasImageImportError {
                throw error
            } catch {
                throw CanvasImageImportError.unableToReadFile
            }
        }.value
    }

    private static func process(
        data: Data,
        policy: CanvasImageImportPolicy
    ) throws -> CanvasPreparedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw CanvasImageImportError.unsupportedOrCorrupt
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let sourceWidth = integerProperty(
            properties?[kCGImagePropertyPixelWidth]
        )
        let sourceHeight = integerProperty(
            properties?[kCGImagePropertyPixelHeight]
        )
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw CanvasImageImportError.invalidDimensions
        }

        // Always process at least one thumbnail. A small icon can have a
        // maximum dimension below 64 px; the old `while targetDimension >=
        // 64` loop skipped those valid images and reported them as too large.
        var targetDimension = max(1, min(
            policy.maximumPixelDimension,
            max(sourceWidth, sourceHeight)
        ))
        var lastPrepared: CanvasPreparedImage?

        while true {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: targetDimension
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                throw CanvasImageImportError.unsupportedOrCorrupt
            }

            let contentType = hasAlpha(thumbnail)
                ? UTType.png.identifier
                : UTType.jpeg.identifier
            let encoded = try encode(
                thumbnail,
                contentType: contentType
            )
            let prepared = CanvasPreparedImage(
                encodedData: encoded,
                contentType: contentType,
                pixelWidth: thumbnail.width,
                pixelHeight: thumbnail.height
            )
            lastPrepared = prepared
            if encoded.count <= policy.maximumEncodedBytes {
                return prepared
            }

            guard targetDimension > 64 else { break }
            let nextDimension = Int(Double(targetDimension) * 0.75)
            if nextDimension >= targetDimension {
                break
            }
            targetDimension = nextDimension
        }

        if let lastPrepared,
           lastPrepared.encodedData.count <= policy.maximumEncodedBytes {
            return lastPrepared
        }
        throw CanvasImageImportError.outputTooLarge
    }

    private static func encode(
        _ image: CGImage,
        contentType: String
    ) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            contentType as CFString,
            1,
            nil
        ) else {
            throw CanvasImageImportError.unableToEncode
        }

        let options: [CFString: Any]
        if contentType == UTType.jpeg.identifier {
            options = [kCGImageDestinationLossyCompressionQuality: 0.86]
        } else {
            options = [:]
        }
        CGImageDestinationAddImage(
            destination,
            image,
            options as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CanvasImageImportError.unableToEncode
        }
        return output as Data
    }

    private static func integerProperty(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let integer = value as? Int {
            return integer
        }
        return 0
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .premultipliedLast,
             .premultipliedFirst,
             .last,
             .first,
             .alphaOnly:
            true
        case .none,
             .noneSkipLast,
             .noneSkipFirst:
            false
        @unknown default:
            true
        }
    }
}

enum CanvasTextRenderError: LocalizedError, Equatable {
    case emptyText
    case unableToRender

    var errorDescription: String? {
        switch self {
        case .emptyText:
            "Enter some text before adding it to the canvas."
        case .unableToRender:
            "Attic could not render that text on the canvas."
        }
    }
}

enum CanvasTextRenderer {
    static func prepare(
        text: String,
        color: CanvasInkColor,
        prefersDarkSurface: Bool
    ) async throws -> CanvasPreparedImage {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(160)
        guard !trimmed.isEmpty else {
            throw CanvasTextRenderError.emptyText
        }
        let value = String(trimmed)
        return try await Task.detached(priority: .userInitiated) {
            try render(
                text: value,
                color: color,
                prefersDarkSurface: prefersDarkSurface
            )
        }.value
    }

    nonisolated private static func render(
        text: String,
        color: CanvasInkColor,
        prefersDarkSurface: Bool
    ) throws -> CanvasPreparedImage {
        let font = CTFontCreateWithName("SF Pro Rounded" as CFString, 30, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    cgColor(for: color, prefersDarkSurface: prefersDarkSurface)
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent = CGFloat.zero
        var descent = CGFloat.zero
        var leading = CGFloat.zero
        let typographicWidth = CGFloat(
            CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            )
        )
        let padding = CGFloat(12)
        let pixelWidth = max(Int(ceil(typographicWidth + padding * 2)), 1)
        let pixelHeight = max(Int(ceil(ascent + descent + leading + padding * 2)), 1)

        guard pixelWidth <= 4_096,
              pixelHeight <= 4_096,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CanvasTextRenderError.unableToRender
        }

        context.textMatrix = .identity
        context.textPosition = CGPoint(x: padding, y: padding + descent)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else {
            throw CanvasTextRenderError.unableToRender
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CanvasTextRenderError.unableToRender
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CanvasTextRenderError.unableToRender
        }
        return CanvasPreparedImage(
            encodedData: output as Data,
            contentType: UTType.png.identifier,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    nonisolated private static func cgColor(
        for color: CanvasInkColor,
        prefersDarkSurface: Bool
    ) -> CGColor {
        let components: [CGFloat]
        switch color {
        case .ink:
            components = prefersDarkSurface
                ? [0.96, 0.96, 0.98, 1]
                : [0.08, 0.08, 0.10, 1]
        case .blue:
            components = [0.02, 0.48, 1.0, 1]
        case .red:
            components = [0.94, 0.18, 0.23, 1]
        case .green:
            components = [0.16, 0.70, 0.32, 1]
        case .orange:
            components = [1.0, 0.50, 0.08, 1]
        }
        return CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: components
        ) ?? CGColor(gray: prefersDarkSurface ? 0.96 : 0.08, alpha: 1)
    }
}
