#if os(macOS)
@preconcurrency import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CanvasImageDecodeCandidatePolicy {
    /// Keep the next short pan already decoded without allowing a large board
    /// to continuously cycle every offscreen image through the bounded cache.
    static let prefetchMarginInViewPoints: CGFloat = 192

    static func candidates(
        in images: [CanvasPlacedImage],
        viewport: CanvasViewport,
        viewportSize: CGSize
    ) -> [CanvasPlacedImage] {
        guard viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return []
        }
        let viewportRect = CGRect(origin: .zero, size: viewportSize)
        let worldViewport = viewport.worldRect(
            for: viewportRect,
            in: viewportSize
        )
        guard !worldViewport.isNull,
              !worldViewport.isInfinite,
              viewport.scale.isFinite,
              viewport.scale > 0 else {
            return []
        }
        let margin = prefetchMarginInViewPoints / CGFloat(viewport.scale)
        let decodeRect = worldViewport.insetBy(dx: -margin, dy: -margin)
        let visible = images.filter { $0.worldRect.intersects(worldViewport) }
        let prefetchOnly = images.filter {
            !$0.worldRect.intersects(worldViewport)
                && $0.worldRect.intersects(decodeRect)
        }
        return visible + prefetchOnly
    }
}

/// Caches the displayed image array and its z-order between changes.
///
/// `imagesForDisplay` is read by drawing, decode scheduling, accessibility,
/// cursor hit-testing and selection lookup — several times per pass — and it
/// rebuilt the whole array on every access while an image was being moved or
/// resized (CANVAS-018/PERF-10). The cache is keyed on the canvas content
/// revision plus the live preview, which is exactly what the array depends on.
@MainActor
final class CanvasImageDisplayCache {
    private struct Key: Equatable {
        let contentRevision: UInt64
        let previewID: UUID?
        let previewTransform: CanvasImageTransform?
    }

    private var key: Key?
    private var cachedImages: [CanvasPlacedImage] = []
    private var cachedOrder: CanvasImageHitTestOrder?
    private var baseOrderRevision: UInt64?
    private var baseOrder: CanvasImageHitTestOrder?

    func images(
        base: [CanvasPlacedImage],
        previewID: UUID?,
        previewTransform: CanvasImageTransform?,
        contentRevision: UInt64
    ) -> [CanvasPlacedImage] {
        refreshIfNeeded(
            base: base,
            previewID: previewID,
            previewTransform: previewTransform,
            contentRevision: contentRevision
        )
        return cachedImages
    }

    func order(
        base: [CanvasPlacedImage],
        previewID: UUID?,
        previewTransform: CanvasImageTransform?,
        contentRevision: UInt64
    ) -> CanvasImageHitTestOrder {
        refreshIfNeeded(
            base: base,
            previewID: previewID,
            previewTransform: previewTransform,
            contentRevision: contentRevision
        )
        if let cachedOrder { return cachedOrder }
        // Sort once per content change. A live preview reuses that order,
        // because moving or resizing an image never changes its z-position.
        if baseOrderRevision != contentRevision || baseOrder == nil {
            baseOrder = CanvasImageHitTestOrder(images: base)
            baseOrderRevision = contentRevision
        }
        let resolvedBase = baseOrder ?? CanvasImageHitTestOrder(images: base)
        let order: CanvasImageHitTestOrder
        if let id = key?.previewID, let transform = key?.previewTransform {
            order = resolvedBase.applyingPreview(id: id, transform: transform)
        } else {
            order = resolvedBase
        }
        cachedOrder = order
        return order
    }

    private func refreshIfNeeded(
        base: [CanvasPlacedImage],
        previewID: UUID?,
        previewTransform: CanvasImageTransform?,
        contentRevision: UInt64
    ) {
        let nextKey = Key(
            contentRevision: contentRevision,
            previewID: previewTransform == nil ? nil : previewID,
            previewTransform: previewID == nil ? nil : previewTransform
        )
        guard key != nextKey else { return }
        key = nextKey
        cachedOrder = nil
        guard let id = nextKey.previewID, let transform = nextKey.previewTransform else {
            cachedImages = base
            return
        }
        cachedImages = base.map {
            $0.id == id ? $0.replacingTransform(transform) : $0
        }
    }
}

enum CanvasAccessibilityObjectKind: Hashable {
    case stroke
    case image
    case semantic
}

struct CanvasAccessibilityObjectKey: Hashable {
    let kind: CanvasAccessibilityObjectKind
    let id: UUID
}

enum CanvasAccessibilityAction: Equatable {
    case select
    case editText
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case makeSmaller
    case makeLarger
    case sendBackward
    case bringForward
    case retryDecode
    case delete

    var title: String {
        switch self {
        case .select: "Select"
        case .editText: "Edit text"
        case .moveLeft: "Move left"
        case .moveRight: "Move right"
        case .moveUp: "Move up"
        case .moveDown: "Move down"
        case .makeSmaller: "Make smaller"
        case .makeLarger: "Make larger"
        case .sendBackward: "Send backward"
        case .bringForward: "Bring forward"
        case .retryDecode: "Retry loading image"
        case .delete: "Delete"
        }
    }
}

@MainActor
final class CanvasAccessibilityObjectElement: NSAccessibilityElement {
    let key: CanvasAccessibilityObjectKey
    weak var canvasView: CanvasNSView?
    private(set) var availableActions: [CanvasAccessibilityAction] = []
    /// The object's rectangle in canvas world space. The parent-space frame is
    /// derived from it, so a viewport change only has to re-project this value
    /// instead of rebuilding the element (CANVAS-017/PERF-09).
    private(set) var worldRect: CGRect = .null

    var objectID: UUID { key.id }
    var objectKind: CanvasAccessibilityObjectKind { key.kind }
    var availableActionNames: [String] { availableActions.map(\.title) }

    init(key: CanvasAccessibilityObjectKey, canvasView: CanvasNSView) {
        self.key = key
        self.canvasView = canvasView
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        label: String,
        valueDescription: String,
        worldRect: CGRect,
        selected: Bool,
        actions: [CanvasAccessibilityAction]
    ) {
        availableActions = actions
        self.worldRect = worldRect
        setAccessibilityParent(canvasView)
        setAccessibilityRole(objectKind == .image ? .image : .group)
        setAccessibilityIdentifier(
            "canvas-\(objectKind == .image ? "image" : objectKind == .semantic ? "object" : "stroke")-\(objectID.uuidString)"
        )
        setAccessibilityLabel(label)
        setAccessibilityValueDescription(valueDescription)
        setAccessibilityHelp(
            objectKind != .stroke
                ? "Select, move, resize, reorder, or delete this object. Press Return to edit text."
                : "Select or delete this ink stroke."
        )
        setAccessibilityEnabled(true)
        setAccessibilitySelected(selected)
        refreshAccessibilityFrame()
        setAccessibilityCustomActions(actions.map { action in
            NSAccessibilityCustomAction(name: action.title) { [weak self] in
                self?.perform(action) ?? false
            }
        })
    }

    /// Re-projects the stored world rectangle through the canvas's current
    /// viewport.
    func refreshAccessibilityFrame() {
        guard let canvasView else { return }
        setAccessibilityFrameInParentSpace(
            canvasView.canvasAccessibilityFrame(for: worldRect)
        )
    }

    func perform(_ action: CanvasAccessibilityAction) -> Bool {
        guard availableActions.contains(action) else { return false }
        return canvasView?.performCanvasAccessibilityAction(
            action,
            for: key
        ) ?? false
    }

    override func isAccessibilityFocused() -> Bool {
        canvasView?.accessibilityFocusedObjectKey == key
    }

    override func accessibilityPerformPress() -> Bool {
        perform(.select)
    }

    override func accessibilityPerformDelete() -> Bool {
        perform(.delete)
    }
}

extension CanvasNSView {
    /// Records that the objects accessibility describes have changed.
    ///
    /// The rebuild itself is deferred: it is coalesced to at most once per
    /// run-loop turn, and it is only performed eagerly once an accessibility
    /// client has actually queried the canvas. A client that has never asked
    /// for children gets its elements built on first query instead
    /// (CANVAS-017/PERF-09).
    func invalidateCanvasAccessibilityElements(postLayoutNotification: Bool) {
        canvasAccessibilityContentIsStale = true
        canvasAccessibilityPendingLayoutNotification =
            canvasAccessibilityPendingLayoutNotification || postLayoutNotification
        guard hasBuiltCanvasAccessibilityElements,
              !canvasAccessibilityRebuildIsScheduled else {
            return
        }
        canvasAccessibilityRebuildIsScheduled = true
        RunLoop.current.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushPendingAccessibilityRebuild()
            }
        }
    }

    /// Performs a coalesced rebuild that is still outstanding.
    func flushPendingAccessibilityRebuild() {
        canvasAccessibilityRebuildIsScheduled = false
        guard canvasAccessibilityContentIsStale,
              hasBuiltCanvasAccessibilityElements else {
            return
        }
        let shouldPost = canvasAccessibilityPendingLayoutNotification
        refreshCanvasAccessibilityElements(postLayoutNotification: shouldPost)
    }

    /// Moves existing accessibility frames to a new viewport without touching
    /// labels, values, actions or navigation order.
    ///
    /// Panning and zooming change only where objects appear, so an attached
    /// accessibility client still needs current frames while a full rebuild
    /// would be pure waste.
    func updateCanvasAccessibilityFramesForViewport() {
        guard hasBuiltCanvasAccessibilityElements,
              !canvasAccessibilityContentIsStale,
              canvasAccessibilityBuiltViewport != interaction.viewport else {
            return
        }
        canvasAccessibilityBuiltViewport = interaction.viewport
        for element in canvasAccessibilityElements.values {
            element.refreshAccessibilityFrame()
        }
    }

    func refreshCanvasAccessibilityElements(
        postLayoutNotification: Bool
    ) {
        canvasAccessibilityContentIsStale = false
        canvasAccessibilityPendingLayoutNotification = false
        hasBuiltCanvasAccessibilityElements = true
        canvasAccessibilityBuiltViewport = interaction.viewport
        accessibilityRebuildCount &+= 1
        let orderedStrokes = interaction.strokes.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        // The shared z-ordered display structure is computed once per content
        // change and reused by drawing, hit-testing and this rebuild
        // (CANVAS-018/PERF-10).
        let orderedImages = imageDisplayOrder.backToFront
        let nextOrder = orderedStrokes.map {
            CanvasAccessibilityObjectKey(kind: .stroke, id: $0.id)
        } + orderedImages.map {
            CanvasAccessibilityObjectKey(kind: .image, id: $0.id)
        } + semanticObjectsForDisplay.map {
            CanvasAccessibilityObjectKey(kind: .semantic, id: $0.id)
        }
        let semanticZIndices = semanticObjects.map(\.transform.zIndex)
        let lowestSemanticZIndex = semanticZIndices.min()
        let highestSemanticZIndex = semanticZIndices.max()
        let failedImageIDs = Set(
            orderedImages.filter { imageCache.state(for: $0) == .failed }.map(\.id)
        )
        func decodeFailed(_ image: CanvasPlacedImage) -> Bool {
            failedImageIDs.contains(image.id)
        }
        let liveKeys = Set(nextOrder)
        canvasAccessibilityElements = canvasAccessibilityElements.filter {
            liveKeys.contains($0.key)
        }
        if let accessibilityFocusedObjectKey,
           !liveKeys.contains(accessibilityFocusedObjectKey) {
            self.accessibilityFocusedObjectKey = nil
        }

        for (index, stroke) in orderedStrokes.enumerated() {
            let key = CanvasAccessibilityObjectKey(kind: .stroke, id: stroke.id)
            let element = canvasAccessibilityElements[key]
                ?? CanvasAccessibilityObjectElement(key: key, canvasView: self)
            canvasAccessibilityElements[key] = element
            let rect = stroke.bounds ?? CGRect(
                x: stroke.points.first?.x ?? 0,
                y: stroke.points.first?.y ?? 0,
                width: 1,
                height: 1
            )
            element.update(
                label: "Ink stroke \(index + 1) of \(orderedStrokes.count)",
                valueDescription: canvasAccessibilityPositionDescription(
                    worldRect: rect,
                    prefix: "\(stroke.color.title), width \(canvasAccessibilityNumber(stroke.width))"
                ),
                worldRect: rect,
                selected: accessibilityFocusedObjectKey == key,
                actions: [.select, .delete]
            )
        }

        for (index, image) in orderedImages.enumerated() {
            let key = CanvasAccessibilityObjectKey(kind: .image, id: image.id)
            let element = canvasAccessibilityElements[key]
                ?? CanvasAccessibilityObjectElement(key: key, canvasView: self)
            canvasAccessibilityElements[key] = element
            var actions: [CanvasAccessibilityAction] = [
                .select, .moveLeft, .moveRight, .moveUp, .moveDown,
                .makeSmaller, .makeLarger
            ]
            // `orderedImages` is sorted back-to-front by exactly the reverse
            // of `imageIsInFront`, so "another image is behind this one" is
            // simply "this is not the first element". That replaces two linear
            // scans per image (quadratic overall) with an index comparison.
            if lowestSemanticZIndex.map({ $0 <= image.zIndex }) == true || index > 0 {
                actions.append(.sendBackward)
            }
            if highestSemanticZIndex.map({ $0 >= image.zIndex }) == true
                || index < orderedImages.count - 1 {
                actions.append(.bringForward)
            }
            if decodeFailed(image) { actions.append(.retryDecode) }
            actions.append(.delete)
            let sizePrefix = "\(canvasAccessibilityNumber(image.width)) by \(canvasAccessibilityNumber(image.height))"
            element.update(
                label: "Image \(index + 1) of \(orderedImages.count)",
                valueDescription: canvasAccessibilityPositionDescription(
                    worldRect: image.worldRect,
                    prefix: decodeFailed(image)
                        ? "Could not be displayed, \(sizePrefix)"
                        : sizePrefix
                ),
                worldRect: image.worldRect,
                selected: selectedImageID == image.id,
                actions: actions
            )
        }

        // `comesBefore` is a strict total order over distinct object IDs, so a
        // single sort yields, for every object, how many objects sit behind and
        // in front of it. The previous two `contains` scans per object made
        // this rebuild quadratic in the board size.
        let placedOrder = (
            images.map(CanvasPlacedRenderObject.image)
                + semanticObjects.map(CanvasPlacedRenderObject.semantic)
        ).sorted(by: CanvasPlacedRenderObject.comesBefore)
        var placedDepthByID: [UUID: Int] = [:]
        placedDepthByID.reserveCapacity(placedOrder.count)
        for (depth, placed) in placedOrder.enumerated() where placedDepthByID[placed.id] == nil {
            placedDepthByID[placed.id] = depth
        }
        for object in semanticObjectsForDisplay {
            let key = CanvasAccessibilityObjectKey(kind: .semantic, id: object.id)
            let element = canvasAccessibilityElements[key]
                ?? CanvasAccessibilityObjectElement(key: key, canvasView: self)
            canvasAccessibilityElements[key] = element
            var actions: [CanvasAccessibilityAction] = [.select, .moveLeft, .moveRight, .moveUp, .moveDown, .makeSmaller, .makeLarger]
            if object.content?.text != nil { actions.append(.editText) }
            let depth = placedDepthByID[object.id]
            if let depth, depth > 0 { actions.append(.sendBackward) }
            if let depth, depth < placedOrder.count - 1 { actions.append(.bringForward) }
            actions.append(.delete)
            element.update(label: String(object.title.prefix(160)),
                valueDescription: canvasAccessibilityPositionDescription(worldRect: object.worldRect,
                    prefix: object.content?.text != nil ? "Editable text" : "Canvas object"),
                worldRect: object.worldRect,
                selected: selectedSemanticObjectID == object.id, actions: actions)
        }
        canvasAccessibilityNavigationOrder = nextOrder
        if postLayoutNotification, isRepresentationActive {
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    @discardableResult
    func focusNextCanvasObject(backward: Bool) -> UUID? {
        refreshCanvasAccessibilityElements(postLayoutNotification: false)
        guard !canvasAccessibilityNavigationOrder.isEmpty else { return nil }
        let nextIndex: Int
        if let focused = accessibilityFocusedObjectKey,
           let index = canvasAccessibilityNavigationOrder.firstIndex(of: focused) {
            let candidate = backward ? index - 1 : index + 1
            guard canvasAccessibilityNavigationOrder.indices.contains(candidate) else {
                return nil
            }
            nextIndex = candidate
        } else {
            nextIndex = backward ? canvasAccessibilityNavigationOrder.count - 1 : 0
        }
        let key = canvasAccessibilityNavigationOrder[nextIndex]
        _ = focusCanvasAccessibilityObject(key)
        return key.id
    }

    func performCanvasAccessibilityAction(
        _ action: CanvasAccessibilityAction,
        for key: CanvasAccessibilityObjectKey
    ) -> Bool {
        guard canvasAccessibilityNavigationOrder.contains(key) else { return false }
        switch action {
        case .select:
            return focusCanvasAccessibilityObject(key)
        case .retryDecode:
            // Recovery for an image whose decode failed (CANVAS-012). The
            // renderer only honours a retry for an image it is tracking, so a
            // stale element cannot resurrect a removed object.
            guard key.kind == .image,
                  let image = imagesForDisplay.first(where: { $0.id == key.id }),
                  imageCache.state(for: image) == .failed else {
                return false
            }
            imageCache.retryDecode(for: image)
            onRetryImageDecode(key.id)
            return true
        case .editText:
            guard focusCanvasAccessibilityObject(key), let object = selectedSemanticObject,
                  object.content?.text != nil else { return false }
            beginSemanticTextEditing(object)
            return semanticTextEditor != nil
        case .delete:
            guard focusCanvasAccessibilityObject(key) else { return false }
            if key.kind == .stroke {
                return onErase([key.id])
            } else if key.kind == .semantic {
                return onDeleteSemanticObject(key.id)
            } else {
                return onDeleteSelectedImage()
            }
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            guard key.kind != .stroke,
                  focusCanvasAccessibilityObject(key) else { return false }
            let delta: CGSize
            switch action {
            case .moveLeft: delta = CGSize(width: -1, height: 0)
            case .moveRight: delta = CGSize(width: 1, height: 0)
            case .moveUp: delta = CGSize(width: 0, height: -1)
            case .moveDown: delta = CGSize(width: 0, height: 1)
            default: return false
            }
            return key.kind == .semantic ? onNudgeSemanticObject(delta) : onNudgeSelectedImage(delta)
        case .makeSmaller, .makeLarger:
            guard key.kind != .stroke,
                  focusCanvasAccessibilityObject(key) else { return false }
            let factor = action == .makeLarger ? 1.1 : 0.9
            return key.kind == .semantic ? onResizeSemanticObject(factor) : onResizeSelectedImage(factor)
        case .sendBackward:
            guard key.kind != .stroke,
                  focusCanvasAccessibilityObject(key) else { return false }
            return key.kind == .semantic ? onMoveSemanticLayer(false) : onSendSelectedImageBackward()
        case .bringForward:
            guard key.kind != .stroke,
                  focusCanvasAccessibilityObject(key) else { return false }
            return key.kind == .semantic ? onMoveSemanticLayer(true) : onBringSelectedImageForward()
        }
    }

    @discardableResult
    private func focusCanvasAccessibilityObject(
        _ key: CanvasAccessibilityObjectKey
    ) -> Bool {
        guard canvasAccessibilityNavigationOrder.contains(key) else { return false }
        guard finishSemanticTextEditing(commit: true) else { return false }
        accessibilityFocusedObjectKey = key
        selectedSemanticObjectID = key.kind == .semantic ? key.id : nil
        onSelectSemanticObject(selectedSemanticObjectID)
        if key.kind == .image {
            selectedImageID = key.id
            onSelectImage(key.id)
        } else {
            selectedImageID = nil
            onSelectImage(nil)
        }
        window?.makeFirstResponder(self)
        refreshCanvasAccessibilityElements(postLayoutNotification: false)
        if let element = canvasAccessibilityElements[key] {
            NSAccessibility.post(
                element: element,
                notification: .focusedUIElementChanged
            )
        }
        NSAccessibility.post(
            element: self,
            notification: .selectedChildrenChanged
        )
        needsDisplay = true
        return true
    }

    func canvasAccessibilityFrame(for worldRect: CGRect) -> CGRect {
        guard !worldRect.isNull,
              !worldRect.isInfinite,
              worldRect.minX.isFinite,
              worldRect.minY.isFinite,
              worldRect.maxX.isFinite,
              worldRect.maxY.isFinite else { return .zero }
        let first = interaction.viewport.viewPoint(
            for: CanvasPoint(x: worldRect.minX, y: worldRect.minY),
            in: bounds.size
        )
        let second = interaction.viewport.viewPoint(
            for: CanvasPoint(x: worldRect.maxX, y: worldRect.maxY),
            in: bounds.size
        )
        var result = CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
        let minimumSide: CGFloat = 22
        if result.width < minimumSide {
            result = result.insetBy(dx: -(minimumSide - result.width) / 2, dy: 0)
        }
        if result.height < minimumSide {
            result = result.insetBy(dx: 0, dy: -(minimumSide - result.height) / 2)
        }
        // NSAccessibilityElement parent-space frames use a bottom-left
        // origin even though the Canvas NSView draws in flipped coordinates.
        result.origin.y = bounds.height - result.maxY
        return result
    }

    private func canvasAccessibilityPositionDescription(
        worldRect: CGRect,
        prefix: String
    ) -> String {
        let centerX = canvasAccessibilityNumber(Double(worldRect.midX))
        let centerY = canvasAccessibilityNumber(Double(worldRect.midY))
        return "\(prefix), center \(centerX), \(centerY)"
    }

    private func canvasAccessibilityNumber(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

enum CanvasImageDropFilter {
    static func supportedFileURLs(_ urls: [URL]) -> [URL] {
        urls.filter(isSupportedFileURL)
    }

    static func isSupportedFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .contentTypeKey
        ]), values.isRegularFile != false {
            if let contentType = values.contentType,
               contentType.conforms(to: .image) {
                return true
            }
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    static func supports(typeIdentifiers: [String]) -> Bool {
        typeIdentifiers.contains { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image)
        }
    }
}

@MainActor
final class CanvasFilePromiseBatchCoordinator {
    struct Slot: Equatable {
        let requestID: UUID
        let receiverIndex: Int
        let center: CanvasPoint
        let cleanupURL: URL
    }

    enum Delivery: Equatable {
        case waiting
        case ready(CanvasImageImportBatch)
        case late
    }

    let batchID: UUID
    let target: CanvasImportTarget
    let slots: [Slot]
    private var sources: [CanvasImageImportSource?]
    private(set) var isFinished = false

    init(
        batchID: UUID,
        target: CanvasImportTarget,
        slots: [Slot]
    ) {
        self.batchID = batchID
        self.target = target
        self.slots = slots
        sources = Array(repeating: nil, count: slots.count)
    }

    var cleanupURLs: [URL] {
        slots.map(\.cleanupURL)
    }

    func record(
        receiverIndex: Int,
        source: CanvasImageImportSource
    ) -> Delivery {
        guard !isFinished,
              let slotIndex = slots.indices.first(where: {
                  slots[$0].receiverIndex == receiverIndex && sources[$0] == nil
              }) else {
            return .late
        }
        sources[slotIndex] = source
        guard sources.allSatisfy({ $0 != nil }) else { return .waiting }
        isFinished = true
        return .ready(CanvasImageImportBatch(
            id: batchID,
            target: target,
            items: zip(slots, sources).compactMap { slot, source in
                guard let source else { return nil }
                return CanvasImageImportRequest(
                    id: slot.requestID,
                    source: source,
                    center: slot.center,
                    cleanupURL: slot.cleanupURL
                )
            }
        ))
    }

    func cancel() {
        isFinished = true
    }
}

enum CanvasCursorRole: Equatable {
    case arrow
    case pen
    case eraser
    case textPlacement
    case shapePlacement
    case openHand
    case closedHand
    case resizeTopLeftBottomRight
    case resizeTopRightBottomLeft
}

@MainActor
private enum CanvasToolCursors {
    // A two-tone precision cross has an unambiguous center on either a light
    // or dark canvas. No symbol bounding-box guess determines where ink lands.
    static let pen = precisionCursor(eraser: false)
    static let eraser = precisionCursor(eraser: true)

    private static func precisionCursor(eraser: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let path = NSBezierPath()
            if eraser {
                path.appendOval(in: CGRect(x: 5, y: 5, width: 14, height: 14))
            } else {
                path.move(to: CGPoint(x: 12, y: 2)); path.line(to: CGPoint(x: 12, y: 9))
                path.move(to: CGPoint(x: 12, y: 15)); path.line(to: CGPoint(x: 12, y: 22))
                path.move(to: CGPoint(x: 2, y: 12)); path.line(to: CGPoint(x: 9, y: 12))
                path.move(to: CGPoint(x: 15, y: 12)); path.line(to: CGPoint(x: 22, y: 12))
            }
            path.lineWidth = 3; NSColor.white.setStroke(); path.stroke()
            path.lineWidth = 1; NSColor.black.setStroke(); path.stroke()
            NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: 10, y: 10, width: 4, height: 4)).fill()
            NSColor.black.setFill(); NSBezierPath(ovalIn: CGRect(x: 11, y: 11, width: 2, height: 2)).fill()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 12, y: 12))
    }
}

extension CanvasNSView {
    var hasActivePointerInteraction: Bool {
        if panLastPoint != nil || shapePointerMode != nil { return true }
        switch imagePointerMode {
        case .moving, .resizing: return true
        case .none: break
        }
        return interaction.machine.state != .idle
    }

    var selectedImage: CanvasPlacedImage? {
        guard let selectedImageID else { return nil }
        return imagesForDisplay.first { $0.id == selectedImageID }
    }

    /// The images as currently displayed, including any live move/resize
    /// preview.
    ///
    /// During an image transform this used to rebuild the whole array on every
    /// access, and it is read by drawing, hit-testing, accessibility and the
    /// cursor path within a single pass (PERF-10). The array is now built once
    /// per change of the inputs it depends on and reused.
    var imagesForDisplay: [CanvasPlacedImage] {
        imageDisplayCache.images(
            base: images,
            previewID: semanticPointerActive ? nil : selectedImageID,
            previewTransform: semanticPointerActive ? nil : previewImageTransform,
            contentRevision: canvasContentRevision
        )
    }

    /// Front-to-back order over `imagesForDisplay`, shared by drawing,
    /// accessibility and pointer hit-testing.
    var imageDisplayOrder: CanvasImageHitTestOrder {
        imageDisplayCache.order(
            base: images,
            previewID: semanticPointerActive ? nil : selectedImageID,
            previewTransform: semanticPointerActive ? nil : previewImageTransform,
            contentRevision: canvasContentRevision
        )
    }

    var baseCursor: NSCursor {
        cursor(for: baseCursorRole)
    }

    var baseCursorRole: CanvasCursorRole {
        if spacePressed { return .openHand }
        switch imagePointerMode {
        case .moving: return .closedHand
        case let .resizing(_, handle, _): return resizeCursorRole(for: handle)
        case .none: break
        }
        if shapePointerMode != nil { return .shapePlacement }
        switch pendingPlacement {
        case .text: return .textPlacement
        case .shape: return .shapePlacement
        case nil: return toolCursorRole
        }
    }

    func cursor(at viewPoint: CGPoint) -> NSCursor {
        cursor(for: cursorRole(at: viewPoint))
    }

    func cursorRole(at viewPoint: CGPoint) -> CanvasCursorRole {
        if excludedControlRects.contains(where: { $0.contains(viewPoint) }) { return .arrow }
        if spacePressed { return .openHand }
        switch imagePointerMode {
        case .moving: return .closedHand
        case let .resizing(_, handle, _): return resizeCursorRole(for: handle)
        case .none: break
        }
        if shapePointerMode != nil { return .shapePlacement }
        switch pendingPlacement {
        case .text: return .textPlacement
        case .shape: return .shapePlacement
        case nil: break
        }
        guard interaction.tool == .select else { return toolCursorRole }
        if let selected = selectedSemanticObject,
           let handle = CanvasImagePlacement.resizeHandle(at: viewPoint, worldRect: selected.worldRect,
                viewport: interaction.viewport, viewportSize: bounds.size, radius: 9) {
            return resizeCursorRole(for: handle)
        }
        if let selectedImage,
           let handle = CanvasImagePlacement.resizeHandle(
                at: viewPoint,
                image: selectedImage,
                viewport: interaction.viewport,
                viewportSize: bounds.size,
                radius: 9
           ) {
            return resizeCursorRole(for: handle)
        }
        let worldPoint = interaction.viewport.worldPoint(
            for: viewPoint,
            in: bounds.size
        )
        if semanticObject(at: worldPoint) != nil { return .openHand }
        if imageDisplayOrder.topmostImage(at: worldPoint) != nil {
            return .openHand
        }
        return .arrow
    }

    var toolCursorRole: CanvasCursorRole {
        switch interaction.tool {
        case .select: .arrow
        case .pen: .pen
        case .eraser: .eraser
        }
    }

    func cursor(for role: CanvasCursorRole) -> NSCursor {
        switch role {
        case .arrow: .arrow
        case .pen: CanvasToolCursors.pen
        case .eraser: CanvasToolCursors.eraser
        case .textPlacement: .iBeam
        case .shapePlacement: .crosshair
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .resizeTopLeftBottomRight:
            if #available(macOS 15.0, *) {
                .frameResize(position: .topLeft, directions: .all)
            } else {
                .crosshair
            }
        case .resizeTopRightBottomLeft:
            if #available(macOS 15.0, *) {
                .frameResize(position: .topRight, directions: .all)
            } else {
                .crosshair
            }
        }
    }

    func resizeCursorRole(
        for handle: CanvasImageResizeHandle
    ) -> CanvasCursorRole {
        switch handle {
        case .topLeft, .bottomRight: .resizeTopLeftBottomRight
        case .topRight, .bottomLeft: .resizeTopRightBottomLeft
        }
    }

    func beginPan(at point: CGPoint) {
        interruptViewportGestureForPointer()
        discardImagePreview()
        discardShapePreview()
        _ = interaction.beginViewportGesture()
        panLastPoint = point
        needsDisplay = true
        NSCursor.closedHand.set()
    }

    @discardableResult
    func finishShapeInteraction(at viewPoint: CGPoint) -> Bool {
        guard let shapePointerMode else { return false }
        let endWorldPoint = interaction.viewport.worldPoint(
            for: viewPoint,
            in: bounds.size
        )
        let dragDistance = hypot(
            viewPoint.x - shapePointerMode.startViewPoint.x,
            viewPoint.y - shapePointerMode.startViewPoint.y
        )
        self.shapePointerMode = nil
        shapePreview = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)

        guard dragDistance >= 4, endWorldPoint.isFinite else {
            return true
        }
        onCompleteShape(
            shapePointerMode.kind,
            shapePointerMode.startWorldPoint,
            endWorldPoint
        )
        return true
    }

    func discardShapePreview() {
        shapePointerMode = nil
        shapePreview = nil
        needsDisplay = true
    }

    @discardableResult
    func beginViewportGestureSequence(
        source: ViewportGestureSource,
        mode: ViewportGestureMode
    ) -> Bool {
        let requested = ViewportGestureSequence(source: source, mode: mode)
        if let activeViewportGesture {
            return activeViewportGesture == requested
        }
        guard panLastPoint == nil else { return false }

        discardImagePreview()
        discardShapePreview()
        _ = interaction.beginViewportGesture()
        activeViewportGesture = requested
        return true
    }

    func finishViewportGestureSequence(
        source: ViewportGestureSource,
        at viewPoint: CGPoint
    ) {
        guard activeViewportGesture?.source == source else { return }
        interaction.finishViewportGesture()
        activeViewportGesture = nil
        window?.invalidateCursorRects(for: self)
        cursor(at: viewPoint).set()
    }

    func interruptViewportGestureForPointer() {
        let interruptedScroll = activeViewportGesture?.source == .scroll
            || pendingScrollMomentumMode != nil
        let interruptedMagnification = activeViewportGesture?.source == .magnification

        if activeViewportGesture != nil {
            interaction.finishViewportGesture()
            activeViewportGesture = nil
        }
        pendingScrollMomentumMode = nil
        if interruptedScroll { suppressesScrollSequence = true }
        if interruptedMagnification { suppressesMagnification = true }
    }

    func resetViewportGestureRouting(
        suppressScroll: Bool = false,
        suppressMagnification: Bool = false
    ) {
        activeViewportGesture = nil
        pendingScrollMomentumMode = nil
        suppressesScrollSequence = suppressScroll
        suppressesMagnification = suppressMagnification
    }

    func applyViewportPan(by translation: CGSize) {
        guard translation.width.isFinite,
              translation.height.isFinite,
              translation.width != 0 || translation.height != 0 else {
            return
        }
        let previous = interaction.viewport
        let viewport = interaction.pan(byViewTranslation: translation)
        guard viewport != previous else { return }
        onViewportChange(viewport)
        needsDisplay = true
    }

    func applyViewportZoom(
        by factor: Double,
        anchoredAt viewPoint: CGPoint,
        in viewportSize: CGSize
    ) {
        guard factor.isFinite, factor > 0, factor != 1 else { return }
        let previous = interaction.viewport
        let viewport = interaction.zoom(
            by: factor,
            anchoredAt: viewPoint,
            in: viewportSize
        )
        guard viewport != previous else { return }
        onViewportChange(viewport)
        needsDisplay = true
    }

    func continuePan(to point: CGPoint) {
        guard let panLastPoint else { return }
        let translation = CGSize(
            width: point.x - panLastPoint.x,
            height: point.y - panLastPoint.y
        )
        self.panLastPoint = point
        let viewport = interaction.pan(byViewTranslation: translation)
        onViewportChange(viewport)
        needsDisplay = true
    }

    func finishPointerInteraction(finalInkPoint: CGPoint?) {
        if interaction.machine.state == .panning {
            interaction.finishViewportGesture()
            panLastPoint = nil
            window?.invalidateCursorRects(for: self)
            return
        }

        if let finalInkPoint {
            _ = interaction.appendInk(at: finalInkPoint, in: bounds.size)
        }
        let completion = interaction.finishInk()
        needsDisplay = true
        switch completion {
        case let .stroke(points, color, width):
            onCompleteStroke(points, color, width)
        case let .erase(ids):
            _ = onErase(ids)
        case nil:
            break
        }
    }

    @discardableResult
    func finishImageInteraction() -> Bool {
        let id: UUID
        let original: CanvasImageTransform
        switch imagePointerMode {
        case .none:
            return false
        case let .moving(imageID, _, initial):
            id = imageID
            original = initial
        case let .resizing(imageID, _, initial):
            id = imageID
            original = initial
        }
        let final = previewImageTransform
        imagePointerMode = .none
        previewImageTransform = nil
        if let final, final != original {
            if semanticPointerActive { onTransformSemanticObject(id, final) }
            else { onTransformImage(id, final) }
        }
        semanticPointerActive = false
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        return true
    }

    func discardImagePreview() {
        semanticPointerActive = false
        imagePointerMode = .none
        previewImageTransform = nil
        needsDisplay = true
    }

    var defaultPasteViewPoint: CGPoint {
        let screenPoint = NSEvent.mouseLocation
        if let window {
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let localPoint = convert(windowPoint, from: nil)
            if bounds.contains(localPoint) { return localPoint }
        }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    @discardableResult
    func importPasteboard(
        _ pasteboard: NSPasteboard,
        at viewPoint: CGPoint
    ) -> Bool {
        let worldPoint = interaction.viewport.worldPoint(
            for: viewPoint,
            in: bounds.size
        )
        guard worldPoint.isFinite else {
            return false
        }
        var offsetIndex = 0
        func importPoint() -> CanvasPoint {
            defer { offsetIndex += 1 }
            let offset = Double(offsetIndex) * 12 / interaction.viewport.scale
            return CanvasPoint(x: worldPoint.x + offset, y: worldPoint.y + offset)
        }

        let urls = ((pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL]) ?? []).map { $0 as URL }
        let supportedURLs = CanvasImageDropFilter.supportedFileURLs(urls)
        if !supportedURLs.isEmpty {
            guard let target = onCaptureImageImportTarget() else { return false }
            onImportImageBatch(CanvasImageImportBatch(
                target: target,
                items: supportedURLs.map { url in
                    CanvasImageImportRequest(
                        source: .file(url),
                        center: importPoint()
                    )
                }
            ))
            return true
        }

        let receivers = ((pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver]) ?? []).filter {
            CanvasImageDropFilter.supports(typeIdentifiers: $0.fileTypes)
        }
        if !receivers.isEmpty {
            guard let target = onCaptureImageImportTarget() else { return false }
            let batchID = UUID()
            var slots: [CanvasFilePromiseBatchCoordinator.Slot] = []
            var destinations: [URL] = []
            for (receiverIndex, receiver) in receivers.enumerated() {
                let expectedCount = max(receiver.fileTypes.count, 1)
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "AtticCanvasPromise-\(batchID.uuidString)-\(receiverIndex)",
                        isDirectory: true
                    )
                destinations.append(destination)
                for _ in 0..<expectedCount {
                    slots.append(.init(
                        requestID: UUID(),
                        receiverIndex: receiverIndex,
                        center: importPoint(),
                        cleanupURL: destination
                    ))
                }
            }
            let coordinator = CanvasFilePromiseBatchCoordinator(
                batchID: batchID,
                target: target,
                slots: slots
            )
            filePromiseBatches[batchID] = coordinator

            for (receiverIndex, receiver) in receivers.enumerated() {
                let destination = destinations[receiverIndex]
                do {
                    try FileManager.default.createDirectory(
                        at: destination,
                        withIntermediateDirectories: true
                    )
                } catch {
                    let expectedCount = max(receiver.fileTypes.count, 1)
                    for _ in 0..<expectedCount {
                        finishFilePromiseDelivery(
                            batchID: batchID,
                            receiverIndex: receiverIndex,
                            destination: destination,
                            url: nil,
                            errorMessage: error.localizedDescription
                        )
                    }
                    continue
                }
                receiver.receivePromisedFiles(
                    atDestination: destination,
                    options: [:],
                    operationQueue: filePromiseQueue
                ) { [weak self] url, error in
                    Task { @MainActor [weak self] in
                        guard let self else {
                            if error == nil {
                                CanvasTemporaryImportCleanup.removeLateDelivery(
                                    at: url,
                                    from: destination
                                )
                            }
                            return
                        }
                        self.finishFilePromiseDelivery(
                            batchID: batchID,
                            receiverIndex: receiverIndex,
                            destination: destination,
                            url: error == nil ? url : nil,
                            errorMessage: error?.localizedDescription
                        )
                    }
                }
            }
            return true
        }

        if let png = pasteboard.data(forType: .png) {
            return importDirectImageData(png, at: importPoint())
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            return importDirectImageData(tiff, at: importPoint())
        }
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation {
            return importDirectImageData(tiff, at: importPoint())
        }
        return false
    }

    func hasSupportedImagePayload(_ pasteboard: NSPasteboard) -> Bool {
        let urls = ((pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL]) ?? []).map { $0 as URL }
        if !CanvasImageDropFilter.supportedFileURLs(urls).isEmpty {
            return true
        }
        if pasteboard.availableType(from: Self.directImagePasteboardTypes) != nil {
            return true
        }
        let receivers = (pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver]) ?? []
        return receivers.contains {
            CanvasImageDropFilter.supports(typeIdentifiers: $0.fileTypes)
        }
    }

    func importDirectImageData(_ data: Data, at point: CanvasPoint) -> Bool {
        guard let target = onCaptureImageImportTarget() else { return false }
        onImportImageBatch(CanvasImageImportBatch(
            target: target,
            items: [CanvasImageImportRequest(source: .data(data), center: point)]
        ))
        return true
    }

    func finishFilePromiseDelivery(
        batchID: UUID,
        receiverIndex: Int,
        destination: URL,
        url: URL?,
        errorMessage: String?
    ) {
        guard let coordinator = filePromiseBatches[batchID] else {
            if let url {
                CanvasTemporaryImportCleanup.removeLateDelivery(
                    at: url,
                    from: destination
                )
            }
            return
        }

        let source: CanvasImageImportSource
        if let errorMessage {
            source = .deliveryFailure(errorMessage)
        } else if let url, CanvasImageDropFilter.isSupportedFileURL(url) {
            source = .file(url)
        } else {
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            source = .deliveryFailure(
                "The promised file is not a supported image."
            )
        }

        switch coordinator.record(receiverIndex: receiverIndex, source: source) {
        case .waiting:
            break
        case let .ready(batch):
            filePromiseBatches[batchID] = nil
            onImportImageBatch(batch)
        case .late:
            if let url {
                CanvasTemporaryImportCleanup.removeLateDelivery(
                    at: url,
                    from: destination
                )
            }
        }
    }

    func cancelFilePromiseBatches() {
        let coordinators = Array(filePromiseBatches.values)
        filePromiseBatches.removeAll(keepingCapacity: true)
        filePromiseQueue.cancelAllOperations()
        for coordinator in coordinators {
            coordinator.cancel()
            CanvasTemporaryImportCleanup.removeOwnedDirectories(
                coordinator.cleanupURLs
            )
        }
    }

}

extension CanvasInkColor {
    var nsColor: NSColor {
        switch self {
        case .ink: .labelColor
        case .blue: .systemBlue
        case .red: .systemRed
        case .green: .systemGreen
        case .orange: .systemOrange
        }
    }
}
#endif
