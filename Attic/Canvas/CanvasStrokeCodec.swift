import Foundation

enum CanvasStrokeCodecError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidWidth
    case emptyPoints
    case nonFinitePoint
    case tooManyPoints
    case archiveTooLarge
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "Canvas stroke format version \(version) is not supported."
        case .invalidWidth:
            "The canvas stroke width is invalid."
        case .emptyPoints:
            "A canvas stroke must contain at least one point."
        case .nonFinitePoint:
            "A canvas stroke contains a non-finite coordinate."
        case .tooManyPoints:
            "The canvas stroke contains too many points."
        case .archiveTooLarge:
            "The canvas stroke archive exceeds the supported size."
        case .invalidArchive:
            "The canvas stroke archive is malformed."
        }
    }
}

enum CanvasStrokeCodec {
    static let currentVersion = 1
    static let maximumArchiveBytes = 900 * 1_024
    private static let maximumEncodedWidth = 64.0

    private struct Archive: Codable {
        let version: Int
        let color: CanvasInkColor
        let width: Double
        let points: [CanvasPoint]
    }

    static func encode(
        color: CanvasInkColor,
        width: Double,
        points: [CanvasPoint]
    ) throws -> Data {
        try validate(width: width, points: points)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Archive(
            version: currentVersion,
            color: color,
            width: width,
            points: points
        ))
        guard data.count <= maximumArchiveBytes else {
            throw CanvasStrokeCodecError.archiveTooLarge
        }
        return data
    }

    static func decode(
        _ data: Data,
        expectedVersion: Int
    ) throws -> CanvasStrokeGeometry {
        guard data.count <= maximumArchiveBytes else {
            throw CanvasStrokeCodecError.archiveTooLarge
        }

        let archive: Archive
        do {
            archive = try JSONDecoder().decode(Archive.self, from: data)
        } catch {
            throw CanvasStrokeCodecError.invalidArchive
        }

        guard archive.version == expectedVersion,
              archive.version == currentVersion else {
            throw CanvasStrokeCodecError.unsupportedVersion(archive.version)
        }
        try validate(width: archive.width, points: archive.points)
        return CanvasStrokeGeometry(
            color: archive.color,
            width: archive.width,
            points: archive.points
        )
    }

    private static func validate(
        width: Double,
        points: [CanvasPoint]
    ) throws {
        guard width.isFinite, width > 0, width <= maximumEncodedWidth else {
            throw CanvasStrokeCodecError.invalidWidth
        }
        guard !points.isEmpty else {
            throw CanvasStrokeCodecError.emptyPoints
        }
        guard points.count <= CanvasInputStateMachine.maximumBufferedPointCount else {
            throw CanvasStrokeCodecError.tooManyPoints
        }
        guard points.allSatisfy(\.isFinite) else {
            throw CanvasStrokeCodecError.nonFinitePoint
        }
    }
}
