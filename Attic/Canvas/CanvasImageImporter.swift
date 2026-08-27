import Foundation
@preconcurrency import ImageIO
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

        var targetDimension = min(
            policy.maximumPixelDimension,
            max(sourceWidth, sourceHeight)
        )
        var lastPrepared: CanvasPreparedImage?

        while targetDimension >= 64 {
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
