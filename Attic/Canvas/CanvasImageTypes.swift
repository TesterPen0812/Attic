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
    let canvasID: UUID
    let renderToken: UUID
    /// Ephemeral identity for the immutable encoded bytes. Transform-only
    /// mutations keep this token so decoded bitmaps are reused without
    /// comparing multi-megabyte Data values on the main actor.
    let contentToken: UUID
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
        canvasID: UUID = CanvasBoardItem.logicalBoardID,
        renderToken: UUID = UUID(),
        contentToken: UUID = UUID(),
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
        self.canvasID = canvasID
        self.renderToken = renderToken
        self.contentToken = contentToken
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
            && lhs.canvasID == rhs.canvasID
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
        let minX = center.x - width / 2
        let minY = center.y - height / 2
        let maxX = center.x + width / 2
        let maxY = center.y + height / 2
        guard minX.isFinite,
              minY.isFinite,
              maxX.isFinite,
              maxY.isFinite,
              maxX >= minX,
              maxY >= minY else {
            return .null
        }
        let result = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        guard result.width.isFinite, result.height.isFinite else {
            return .null
        }
        return result
    }

    var renderKey: CanvasImageRenderKey {
        CanvasImageRenderKey(id: id, token: renderToken)
    }

    func replacingTransform(_ transform: CanvasImageTransform) -> CanvasPlacedImage {
        CanvasPlacedImage(
            id: id,
            canvasID: canvasID,
            renderToken: renderToken,
            contentToken: contentToken,
            encodedData: encodedData,
            contentType: contentType,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            transform: transform,
            boardGeneration: boardGeneration,
            mutationVersion: mutationVersion,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct CanvasImageRenderKey: Equatable, Hashable, Sendable {
    let id: UUID
    let token: UUID
}

struct CanvasImageDisplaySignature: Equatable {
    let renderKey: CanvasImageRenderKey
    let transform: CanvasImageTransform
    let boardGeneration: Int64
    let mutationVersion: Int64

    init(_ image: CanvasPlacedImage) {
        renderKey = image.renderKey
        transform = image.transform
        boardGeneration = image.boardGeneration
        mutationVersion = image.mutationVersion
    }
}

enum CanvasImageResizeHandle: CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

enum CanvasImagePlacement {
    static let defaultMaximumDimension = 360.0
    static let minimumDimension = 48.0
    static let selectionHandleRadius = 6.0

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
        let sourceMaximum = max(sourceWidth, sourceHeight)
        // Keep a custom maximum from producing a placement smaller than the
        // interaction minimum. This matters for compact import previews.
        let safeMaximumDimension = max(maximumDimension, minimumDimension)
        let displayedMaximum = min(
            max(sourceMaximum, minimumDimension),
            safeMaximumDimension
        )
        let scale = displayedMaximum / sourceMaximum
        return CGSize(
            width: sourceWidth * scale,
            height: sourceHeight * scale
        )
    }

    static func aspectPreservingSize(
        from original: CanvasImageTransform,
        proposedWidth: Double,
        proposedHeight: Double
    ) -> CGSize {
        guard original.isValid,
              proposedWidth.isFinite,
              proposedHeight.isFinite else {
            return CGSize(width: original.width, height: original.height)
        }

        let aspectRatio = original.width / original.height
        guard aspectRatio.isFinite, aspectRatio > 0 else {
            return CGSize(
                width: max(proposedWidth, minimumDimension),
                height: max(proposedHeight, minimumDimension)
            )
        }

        let safeProposedWidth = max(proposedWidth, minimumDimension)
        let safeProposedHeight = max(proposedHeight, minimumDimension)
        let widthDrivenHeight = safeProposedWidth / aspectRatio
        let heightDrivenWidth = safeProposedHeight * aspectRatio
        guard widthDrivenHeight.isFinite, heightDrivenWidth.isFinite else {
            return CGSize(width: safeProposedWidth, height: safeProposedHeight)
        }
        let widthDelta = abs(widthDrivenHeight - safeProposedHeight)
        let heightDelta = abs(heightDrivenWidth - safeProposedWidth)
        if widthDelta <= heightDelta {
            return CGSize(
                width: safeProposedWidth,
                height: max(widthDrivenHeight, minimumDimension / aspectRatio)
            )
        }
        return CGSize(
            width: max(heightDrivenWidth, minimumDimension * aspectRatio),
            height: safeProposedHeight
        )
    }

    static func topmostImage(
        at worldPoint: CanvasPoint,
        images: [CanvasPlacedImage]
    ) -> CanvasPlacedImage? {
        images
            .sorted(by: imageIsInFront)
            .first { $0.worldRect.contains(worldPoint.cgPoint) }
    }

    static func resizeHandle(
        at viewPoint: CGPoint,
        image: CanvasPlacedImage,
        viewport: CanvasViewport,
        viewportSize: CGSize,
        radius: Double = selectionHandleRadius
    ) -> CanvasImageResizeHandle? {
        guard radius.isFinite, radius > 0 else { return nil }
        for handle in CanvasImageResizeHandle.allCases {
            let point = viewport.viewPoint(
                for: worldPoint(for: handle, in: image.worldRect),
                in: viewportSize
            )
            let dx = Double(viewPoint.x - point.x)
            let dy = Double(viewPoint.y - point.y)
            if dx * dx + dy * dy <= radius * radius {
                return handle
            }
        }
        return nil
    }

    static func resizedTransform(
        from original: CanvasImageTransform,
        handle: CanvasImageResizeHandle,
        to worldPoint: CanvasPoint,
        preserveAspectRatio: Bool = true
    ) -> CanvasImageTransform {
        guard original.isValid, worldPoint.isFinite else { return original }
        let rect = CGRect(
            x: original.center.x - original.width / 2,
            y: original.center.y - original.height / 2,
            width: original.width,
            height: original.height
        )
        let opposite = oppositeWorldPoint(for: handle, in: rect)
        let signs = handleSigns(handle)
        let proposedWidth = max(abs(worldPoint.x - opposite.x), minimumDimension)
        let proposedHeight = max(abs(worldPoint.y - opposite.y), minimumDimension)
        guard proposedWidth.isFinite, proposedHeight.isFinite else {
            return original
        }
        let size: CGSize
        if preserveAspectRatio {
            size = aspectPreservingSize(
                from: original,
                proposedWidth: proposedWidth,
                proposedHeight: proposedHeight
            )
        } else {
            size = CGSize(width: proposedWidth, height: proposedHeight)
        }
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return original
        }
        let corner = CanvasPoint(
            x: opposite.x + signs.x * Double(size.width),
            y: opposite.y + signs.y * Double(size.height)
        )
        let result = CanvasImageTransform(
            center: CanvasPoint(
                x: (opposite.x + corner.x) / 2,
                y: (opposite.y + corner.y) / 2
            ),
            width: Double(size.width),
            height: Double(size.height),
            zIndex: original.zIndex
        )
        // A finite pointer and finite dimensions can still overflow while
        // reconstructing the opposite corner near Double's limit. Never hand
        // an invalid preview transform to the renderer or persistence layer.
        return result.isValid ? result : original
    }

    static func movedTransform(
        from original: CanvasImageTransform,
        by delta: CanvasPoint
    ) -> CanvasImageTransform {
        guard original.isValid, delta.isFinite else { return original }
        let movedCenter = CanvasPoint(
            x: original.center.x + delta.x,
            y: original.center.y + delta.y
        )
        guard movedCenter.isFinite else { return original }
        return CanvasImageTransform(
            center: movedCenter,
            width: original.width,
            height: original.height,
            zIndex: original.zIndex
        )
    }

    static func worldPoint(
        for handle: CanvasImageResizeHandle,
        in rect: CGRect
    ) -> CanvasPoint {
        switch handle {
        case .topLeft:
            CanvasPoint(x: rect.minX, y: rect.minY)
        case .topRight:
            CanvasPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:
            CanvasPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight:
            CanvasPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private static func oppositeWorldPoint(
        for handle: CanvasImageResizeHandle,
        in rect: CGRect
    ) -> CanvasPoint {
        switch handle {
        case .topLeft:
            CanvasPoint(x: rect.maxX, y: rect.maxY)
        case .topRight:
            CanvasPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft:
            CanvasPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight:
            CanvasPoint(x: rect.minX, y: rect.minY)
        }
    }

    private static func handleSigns(
        _ handle: CanvasImageResizeHandle
    ) -> (x: Double, y: Double) {
        switch handle {
        case .topLeft: (-1, -1)
        case .topRight: (1, -1)
        case .bottomLeft: (-1, 1)
        case .bottomRight: (1, 1)
        }
    }

    private static func imageIsInFront(
        _ lhs: CanvasPlacedImage,
        _ rhs: CanvasPlacedImage
    ) -> Bool {
        if lhs.zIndex != rhs.zIndex { return lhs.zIndex > rhs.zIndex }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}
