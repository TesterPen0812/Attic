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

struct CanvasDecodedImage: @unchecked Sendable {
    let image: CGImage?
}

enum CanvasImageDecodeState: Equatable {
    case idle
    case queued
    case decoding
    case ready
    case failed
}

/// Decodes canonical Canvas image bytes away from the main actor. The bounded
/// NSCache prevents a canvas containing many large screenshots from retaining
/// every decompressed bitmap simultaneously.
@MainActor
final class CanvasImageDecodeCache {
    typealias DecodeOperation = @Sendable (Data) async -> CanvasDecodedImage

    private struct DecodeRequest {
        let data: Data
    }

    private struct ActiveDecode {
        let attemptID: UUID
        let task: Task<Void, Never>
    }

    var onImageReady: (() -> Void)?

    private let cache = NSCache<NSString, CanvasCGImageBox>()
    private let maximumConcurrentDecodes: Int
    private let decodeOperation: DecodeOperation
    private let failedDecodeLimit: Int
    private var visibleKeys: Set<UUID> = []
    private var queued: [UUID: DecodeRequest] = [:]
    private var queuedOrder: [UUID] = []
    private var queueHead = 0
    private var active: [UUID: ActiveDecode] = [:]
    private var failed: Set<UUID> = []
    private var failedOrder: [UUID] = []

    init(
        totalCostLimit: Int = 256 * 1_024 * 1_024,
        countLimit: Int = 48,
        maximumConcurrentDecodes: Int = 3,
        failedDecodeLimit: Int = 512,
        decode: DecodeOperation? = nil
    ) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = countLimit
        self.maximumConcurrentDecodes = max(maximumConcurrentDecodes, 1)
        self.failedDecodeLimit = max(failedDecodeLimit, 1)
        decodeOperation = decode ?? { data in
            await CanvasImageDecodeCache.decodeOffMain(data)
        }
    }

    deinit {
        active.values.forEach { $0.task.cancel() }
    }

    func prepare(for images: [CanvasPlacedImage]) {
        visibleKeys = Set(images.map(\.contentToken))
        trimFailureHistory()

        queued = queued.filter { visibleKeys.contains($0.key) }
        for (key, decode) in active where !visibleKeys.contains(key) {
            decode.task.cancel()
        }

        rebuildQueueOrder(prioritizing: images)
        for image in images {
            enqueueIfNeeded(image)
        }
        rebuildQueueOrder(prioritizing: images)
        startQueuedDecodesIfPossible()
    }

    func image(for image: CanvasPlacedImage) -> CGImage? {
        if let cached = cachedImage(for: image) {
            return cached
        }
        guard failed.contains(image.contentToken) else { return nil }
        return Self.failedDecodePlaceholder?.image
    }

    func state(for image: CanvasPlacedImage) -> CanvasImageDecodeState {
        let key = image.contentToken
        if cachedImage(for: image) != nil { return .ready }
        if failed.contains(key) { return .failed }
        if queued[key] != nil { return .queued }
        if let active = active[key], !active.task.isCancelled { return .decoding }
        return .idle
    }

    func retryDecode(for image: CanvasPlacedImage) {
        let key = image.contentToken
        guard visibleKeys.contains(key), failed.remove(key) != nil else { return }
        failedOrder.removeAll { $0 == key }
        enqueueIfNeeded(image)
        startQueuedDecodesIfPossible()
    }

    func removeAll() {
        visibleKeys.removeAll()
        queued.removeAll()
        queuedOrder.removeAll()
        queueHead = 0
        active.values.forEach { $0.task.cancel() }
        failed.removeAll()
        failedOrder.removeAll()
        cache.removeAllObjects()
    }

    private func cachedImage(for image: CanvasPlacedImage) -> CGImage? {
        cache.object(forKey: cacheKey(image.contentToken))?.image
    }

    private func enqueueIfNeeded(_ image: CanvasPlacedImage) {
        let key = image.contentToken
        guard cachedImage(for: image) == nil,
              !failed.contains(key),
              queued[key] == nil else {
            return
        }

        if let active = active[key], !active.task.isCancelled { return }
        queued[key] = DecodeRequest(data: image.encodedData)
        queuedOrder.append(key)
    }

    private func rebuildQueueOrder(prioritizing images: [CanvasPlacedImage]) {
        var ordered: [UUID] = []
        ordered.reserveCapacity(queued.count)
        var inserted: Set<UUID> = []
        inserted.reserveCapacity(queued.count)

        for image in images {
            let key = image.contentToken
            guard queued[key] != nil, inserted.insert(key).inserted else { continue }
            ordered.append(key)
        }
        for key in queuedOrder.dropFirst(min(queueHead, queuedOrder.count)) {
            guard queued[key] != nil, inserted.insert(key).inserted else { continue }
            ordered.append(key)
        }
        queuedOrder = ordered
        queueHead = 0
    }

    private func startQueuedDecodesIfPossible() {
        while active.count < maximumConcurrentDecodes,
              let (key, request) = dequeueNext() {
            let attemptID = UUID()
            let operation = decodeOperation
            let task = Task { @MainActor [weak self] in
                let decoded = await operation(request.data)
                guard let self else { return }
                finishDecode(key: key, attemptID: attemptID, decoded: decoded)
            }
            active[key] = ActiveDecode(attemptID: attemptID, task: task)
        }
    }

    private func dequeueNext() -> (UUID, DecodeRequest)? {
        let candidateCount = queuedOrder.count - queueHead
        var examined = 0
        while examined < candidateCount, queueHead < queuedOrder.count {
            let key = queuedOrder[queueHead]
            queueHead += 1
            examined += 1
            guard let request = queued[key] else { continue }
            guard active[key] == nil else {
                queuedOrder.append(key)
                continue
            }
            queued[key] = nil
            compactQueueIfNeeded()
            return (key, request)
        }
        compactQueueIfNeeded(force: true)
        return nil
    }

    private func compactQueueIfNeeded(force: Bool = false) {
        if queueHead >= queuedOrder.count {
            queuedOrder.removeAll(keepingCapacity: true)
            queueHead = 0
        } else if force || (queueHead > 64 && queueHead * 2 >= queuedOrder.count) {
            queuedOrder = Array(queuedOrder[queueHead...])
            queueHead = 0
        }
    }

    private func finishDecode(
        key: UUID,
        attemptID: UUID,
        decoded: CanvasDecodedImage
    ) {
        guard active[key]?.attemptID == attemptID else { return }
        active[key] = nil
        defer { startQueuedDecodesIfPossible() }

        guard !Task.isCancelled, visibleKeys.contains(key) else { return }
        guard let decodedImage = decoded.image else {
            rememberFailure(key)
            onImageReady?()
            return
        }

        clearFailure(key)
        cache.setObject(
            CanvasCGImageBox(decodedImage),
            forKey: cacheKey(key),
            cost: Self.decodedCost(decodedImage)
        )
        onImageReady?()
    }

    private func rememberFailure(_ key: UUID) {
        guard failed.insert(key).inserted else { return }
        failedOrder.append(key)
        trimFailureHistory()
    }

    private func trimFailureHistory() {
        var index = 0
        while failedOrder.count > failedDecodeLimit, index < failedOrder.count {
            let key = failedOrder[index]
            if visibleKeys.contains(key) {
                index += 1
            } else {
                failedOrder.remove(at: index)
                failed.remove(key)
            }
        }
    }

    private func clearFailure(_ key: UUID) {
        guard failed.remove(key) != nil else { return }
        failedOrder.removeAll { $0 == key }
    }

    private static func decodedCost(_ image: CGImage) -> Int {
        let rawCost = image.bytesPerRow.multipliedReportingOverflow(
            by: image.height
        )
        let cost = rawCost.overflow ? Int.max : rawCost.partialValue
        return max(cost, 1)
    }

    nonisolated private static func decodeOffMain(
        _ data: Data
    ) async -> CanvasDecodedImage {
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return CanvasDecodedImage(image: nil) }
            let decoded = decode(data)
            guard !Task.isCancelled else { return CanvasDecodedImage(image: nil) }
            return CanvasDecodedImage(image: decoded)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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

    private static let failedDecodePlaceholder: CanvasCGImageBox? = {
        let size = 64
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(CGColor(gray: 0.78, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(gray: 0.68, alpha: 1))
        let tile = CGFloat(size / 4)
        for row in 0..<4 {
            for column in 0..<4 where (row + column).isMultiple(of: 2) {
                context.fill(
                    CGRect(
                        x: CGFloat(column) * tile,
                        y: CGFloat(row) * tile,
                        width: tile,
                        height: tile
                    )
                )
            }
        }
        context.setStrokeColor(CGColor(gray: 0.25, alpha: 0.9))
        context.setLineWidth(5)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 17, y: 17))
        context.addLine(to: CGPoint(x: 47, y: 47))
        context.move(to: CGPoint(x: 47, y: 17))
        context.addLine(to: CGPoint(x: 17, y: 47))
        context.strokePath()

        guard let image = context.makeImage() else { return nil }
        return CanvasCGImageBox(image)
    }()
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
    imageSelectionColor: CGColor? = nil,
    shapePreview: CanvasStrokeGeometry? = nil,
    strokeReadabilityShadowColor: CGColor? = nil
) {
    context.saveGState()
    context.clear(bounds)
    if backgroundColor.alpha > 0 {
        context.setFillColor(backgroundColor)
        context.fill(bounds)
    }
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
    func strokePath(color: CGColor, width: CGFloat) {
        if let strokeReadabilityShadowColor {
            context.setShadow(
                offset: CGSize(width: 0, height: 0.35),
                blur: 0.7,
                color: strokeReadabilityShadowColor
            )
        }
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.strokePath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }
    for stroke in interaction.strokes {
        guard stroke.bounds?.intersects(cullingRect) != false else {
            continue
        }
        context.addPath(pathCache.path(for: stroke))
        strokePath(color: strokeColor(stroke.color), width: CGFloat(stroke.width))
    }

    if let activePath = interaction.activePath {
        context.addPath(activePath)
        strokePath(
            color: strokeColor(interaction.activeStrokeColor),
            width: CGFloat(interaction.activeStrokeWidth)
        )
    }
    if let shapePreview, !shapePreview.points.isEmpty {
        context.addPath(canvasPath(points: shapePreview.points))
        strokePath(
            color: strokeColor(shapePreview.color),
            width: CGFloat(shapePreview.width)
        )
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

private func canvasPath(points: [CanvasPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    path.move(to: first.cgPoint)
    for point in points.dropFirst() {
        path.addLine(to: point.cgPoint)
    }
    return path
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
