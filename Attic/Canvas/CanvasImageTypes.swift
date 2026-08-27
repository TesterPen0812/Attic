import Foundation

struct CanvasPreparedImage: Equatable, Sendable {
    let encodedData: Data
    let contentType: String
    let pixelWidth: Int
    let pixelHeight: Int

    init(
        encodedData: Data,
        contentType: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.encodedData = encodedData
        self.contentType = contentType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

struct CanvasImageTransform: Equatable, Sendable {
    var center: CanvasPoint
    var width: Double
    var height: Double
    var zIndex: Int64

    var isValid: Bool {
        center.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
    }
}

struct CanvasPlacedImage: Identifiable, Equatable {
    let id: UUID
    let renderToken: UUID
    let encodedData: Data
    let contentType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let transform: CanvasImageTransform
    let boardGeneration: Int64
    let mutationVersion: Int64
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        renderToken: UUID = UUID(),
        encodedData: Data,
        contentType: String,
        pixelWidth: Int,
        pixelHeight: Int,
        transform: CanvasImageTransform,
        boardGeneration: Int64 = 0,
        mutationVersion: Int64 = 1,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.renderToken = renderToken
        self.encodedData = encodedData
        self.contentType = contentType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.transform = transform
        self.boardGeneration = boardGeneration
        self.mutationVersion = mutationVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    static func == (lhs: CanvasPlacedImage, rhs: CanvasPlacedImage) -> Bool {
        lhs.id == rhs.id
            && lhs.encodedData == rhs.encodedData
            && lhs.contentType == rhs.contentType
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && lhs.transform == rhs.transform
            && lhs.boardGeneration == rhs.boardGeneration
            && lhs.mutationVersion == rhs.mutationVersion
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }

    var center: CanvasPoint { transform.center }
    var width: Double { transform.width }
    var height: Double { transform.height }
    var zIndex: Int64 { transform.zIndex }

    var worldRect: CGRect {
        CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
    }

    var renderKey: CanvasImageRenderKey {
        CanvasImageRenderKey(id: id, token: renderToken)
    }
}

struct CanvasImageRenderKey: Equatable, Hashable, Sendable {
    let id: UUID
    let token: UUID
}

enum CanvasImagePlacement {
    static let defaultMaximumDimension = 360.0
    static let minimumDimension = 48.0

    static func defaultSize(
        pixelWidth: Int,
        pixelHeight: Int,
        maximumDimension: Double = defaultMaximumDimension
    ) -> CGSize {
        guard pixelWidth > 0,
              pixelHeight > 0,
              maximumDimension.isFinite,
              maximumDimension > 0 else {
            return CGSize(width: minimumDimension, height: minimumDimension)
        }

        let sourceWidth = Double(pixelWidth)
        let sourceHeight = Double(pixelHeight)
        let scale = min(
            maximumDimension / max(sourceWidth, sourceHeight),
            1
        )
        return CGSize(
            width: max(sourceWidth * scale, minimumDimension),
            height: max(sourceHeight * scale, minimumDimension)
        )
    }

    static func aspectPreservingSize(
        from original: CanvasImageTransform,
        proposedWidth: Double,
        proposedHeight: Double
    ) -> CGSize {
        guard original.width > 0,
              original.height > 0,
              proposedWidth.isFinite,
              proposedHeight.isFinite else {
            return CGSize(width: original.width, height: original.height)
        }

        let aspectRatio = original.width / original.height
        let widthDrivenHeight = proposedWidth / aspectRatio
        let heightDrivenWidth = proposedHeight * aspectRatio
        let widthDelta = abs(widthDrivenHeight - proposedHeight)
        let heightDelta = abs(heightDrivenWidth - proposedWidth)
        if widthDelta <= heightDelta {
            return CGSize(
                width: max(proposedWidth, minimumDimension),
                height: max(widthDrivenHeight, minimumDimension / aspectRatio)
            )
        }
        return CGSize(
            width: max(heightDrivenWidth, minimumDimension * aspectRatio),
            height: max(proposedHeight, minimumDimension)
        )
    }
}
