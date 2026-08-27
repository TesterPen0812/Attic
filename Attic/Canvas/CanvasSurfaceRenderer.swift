import CoreGraphics
import Foundation
@preconcurrency import ImageIO

final class CanvasPathCache {
    private struct Entry {
        let renderToken: UUID
        let path: CGPath
    }

    private var entries: [UUID: Entry] = [:]
    private var preparedKeys: [CanvasStrokeRenderKey] = []

    var cachedPathCount: Int { entries.count }

    func prepare(for strokes: [CanvasStroke]) {
        if preparedKeys.count == strokes.count {
            var unchanged = true
            for index in strokes.indices where preparedKeys[index] != strokes[index].renderKey {
                unchanged = false
                break
            }
            if unchanged { return }
        }

        let keys = strokes.map(\.renderKey)
        preparedKeys = keys
        let visibleIDs = Set(keys.map(\.id))
        entries = entries.filter { visibleIDs.contains($0.key) }
    }

    func path(for stroke: CanvasStroke) -> CGPath {
        if let entry = entries[stroke.id],
           entry.renderToken == stroke.renderToken {
            return entry.path
        }

        let path = Self.makePath(points: stroke.points)
        entries[stroke.id] = Entry(
            renderToken: stroke.renderToken,
            path: path
        )
        return path
    }

    private static func makePath(points: [CanvasPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }

        path.move(to: first.cgPoint)
        if points.count == 1 {
            path.addLine(to: first.cgPoint)
        } else {
            for point in points.dropFirst() {
                path.addLine(to: point.cgPoint)
            }
        }
        return path
    }
}

private final class CanvasCGImageBox: NSObject {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

private struct CanvasDecodedImage: @unchecked Sendable {
    let image: CGImage?
}

/// Decodes canonical Canvas image bytes away from the main actor. The bounded
/// NSCache prevents a canvas containing many large screenshots from retaining
/// every decompressed bitmap simultaneously.
@MainActor
final class CanvasImageDecodeCache {
    var onImageReady: (() -> Void)?

    private let cache = NSCache<NSString, CanvasCGImageBox>()
    private var pending: [UUID: Task<Void, Never>] = [:]

    init(totalCostLimit: Int = 256 * 1_024 * 1_024, countLimit: Int = 48) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = countLimit
    }

    deinit {
        pending.values.forEach { $0.cancel() }
    }

    func prepare(for images: [CanvasPlacedImage]) {
        let visibleKeys = Set(images.map(\.contentToken))
        for (key, task) in pending where !visibleKeys.contains(key) {
            task.cancel()
            pending[key] = nil
        }

        for image in images where cachedImage(for: image) == nil {
            requestDecode(for: image)
        }
    }

    func image(for image: CanvasPlacedImage) -> CGImage? {
        cachedImage(for: image)
    }

    func removeAll() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        cache.removeAllObjects()
    }

    private func cachedImage(for image: CanvasPlacedImage) -> CGImage? {
        cache.object(forKey: cacheKey(image.contentToken))?.image
    }

    private func requestDecode(for image: CanvasPlacedImage) {
        let key = image.contentToken
        guard pending[key] == nil else { return }
        let data = image.encodedData
        let cacheIdentifier = cacheKey(key)

        pending[key] = Task { @MainActor [weak self] in
            let decoded = await Task.detached(priority: .utility) {
                CanvasDecodedImage(image: Self.decode(data))
            }.value
            guard let self, !Task.isCancelled else { return }
            pending[key] = nil
            guard let decodedImage = decoded.image else { return }
            cache.setObject(
                CanvasCGImageBox(decodedImage),
                forKey: cacheIdentifier,
                cost: Self.decodedCost(decodedImage)
            )
            onImageReady?()
        }
    }


    private static func decodedCost(_ image: CGImage) -> Int {
        let rawCost = image.bytesPerRow.multipliedReportingOverflow(
            by: image.height
        )
        let cost = rawCost.overflow ? Int.max : rawCost.partialValue
        return max(cost, 1)
    }

    nonisolated private static func decode(_ data: Data) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            return CGImageSourceCreateImageAtIndex(
                source,
                0,
                options as CFDictionary
            )
        }
    }

    private func cacheKey(_ key: UUID) -> NSString {
        key.uuidString as NSString
    }
}

func drawCanvas(
    in context: CGContext,
    bounds: CGRect,
    interaction: CanvasInteractionController,
    pathCache: CanvasPathCache,
    backgroundColor: CGColor,
    strokeColor: (CanvasInkColor) -> CGColor,
    eraserOutlineColor: CGColor,
    images: [CanvasPlacedImage] = [],
    selectedImageID: UUID? = nil,
    imageProvider: (CanvasPlacedImage) -> CGImage? = { _ in nil },
    imageSelectionColor: CGColor? = nil
) {
    context.saveGState()
    context.setFillColor(backgroundColor)
    context.fill(bounds)
    context.clip(to: bounds)

    pathCache.prepare(for: interaction.strokes)

    let worldViewport = interaction.viewport.worldRect(
        for: bounds,
        in: bounds.size
    )
    let cullingMargin = CGFloat(64 / interaction.viewport.scale)
    let cullingRect = worldViewport.insetBy(
        dx: -cullingMargin,
        dy: -cullingMargin
    )

    context.saveGState()
    context.translateBy(x: bounds.midX, y: bounds.midY)
    context.scaleBy(
        x: CGFloat(interaction.viewport.scale),
        y: CGFloat(interaction.viewport.scale)
    )
    context.translateBy(
        x: -CGFloat(interaction.viewport.center.x),
        y: -CGFloat(interaction.viewport.center.y)
    )

    context.interpolationQuality = .high
    for image in images.sorted(by: imageComesBefore) {
        let rect = image.worldRect
        guard rect.intersects(cullingRect),
              let decoded = imageProvider(image) else {
            continue
        }
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(
            decoded,
            in: CGRect(origin: .zero, size: rect.size)
        )
        context.restoreGState()
    }

    context.setLineCap(.round)
    context.setLineJoin(.round)
    for stroke in interaction.strokes {
        guard stroke.bounds?.intersects(cullingRect) != false else {
            continue
        }
        context.addPath(pathCache.path(for: stroke))
        context.setStrokeColor(strokeColor(stroke.color))
        context.setLineWidth(CGFloat(stroke.width))
        context.strokePath()
    }

    if let activePath = interaction.activePath {
        context.addPath(activePath)
        context.setStrokeColor(strokeColor(interaction.activeStrokeColor))
        context.setLineWidth(CGFloat(interaction.activeStrokeWidth))
        context.strokePath()
    }
    context.restoreGState()

    if let selectedImageID,
       let selected = images.first(where: { $0.id == selectedImageID }) {
        drawImageSelection(
            selected,
            context: context,
            viewport: interaction.viewport,
            viewportSize: bounds.size,
            color: imageSelectionColor ?? eraserOutlineColor
        )
    }

    if let eraserWorldPoint = interaction.eraserWorldPoint {
        let viewPoint = interaction.viewport.viewPoint(
            for: eraserWorldPoint,
            in: bounds.size
        )
        let radius = CGFloat(
            interaction.eraserRadiusWorld * interaction.viewport.scale
        )
        context.setStrokeColor(eraserOutlineColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: CGRect(
            x: viewPoint.x - radius,
            y: viewPoint.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    context.restoreGState()
}

private func imageComesBefore(
    _ lhs: CanvasPlacedImage,
    _ rhs: CanvasPlacedImage
) -> Bool {
    if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id.uuidString < rhs.id.uuidString
}

private func drawImageSelection(
    _ image: CanvasPlacedImage,
    context: CGContext,
    viewport: CanvasViewport,
    viewportSize: CGSize,
    color: CGColor
) {
    let rect = image.worldRect
    let topLeft = viewport.viewPoint(
        for: CanvasPoint(x: rect.minX, y: rect.minY),
        in: viewportSize
    )
    let bottomRight = viewport.viewPoint(
        for: CanvasPoint(x: rect.maxX, y: rect.maxY),
        in: viewportSize
    )
    let viewRect = CGRect(
        x: min(topLeft.x, bottomRight.x),
        y: min(topLeft.y, bottomRight.y),
        width: abs(bottomRight.x - topLeft.x),
        height: abs(bottomRight.y - topLeft.y)
    )

    context.saveGState()
    context.setStrokeColor(color.copy(alpha: 0.84) ?? color)
    context.setLineWidth(1.25)
    context.stroke(viewRect.insetBy(dx: -0.5, dy: -0.5))

    let handleRadius = CGFloat(CanvasImagePlacement.selectionHandleRadius)
    context.setFillColor(CGColor(gray: 1, alpha: 0.96))
    context.setStrokeColor(color)
    context.setLineWidth(1.1)
    for handle in CanvasImageResizeHandle.allCases {
        let point = viewport.viewPoint(
            for: CanvasImagePlacement.worldPoint(for: handle, in: rect),
            in: viewportSize
        )
        let handleRect = CGRect(
            x: point.x - handleRadius,
            y: point.y - handleRadius,
            width: handleRadius * 2,
            height: handleRadius * 2
        )
        context.fillEllipse(in: handleRect)
        context.strokeEllipse(in: handleRect)
    }
    context.restoreGState()
}
