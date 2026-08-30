#if os(macOS)
@preconcurrency import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CanvasNSViewRepresentable: NSViewRepresentable {
    @ObservedObject var session: CanvasSession
    let clearReadabilityEnabled: Bool

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView()
        configure(view)
        return view
    }

    func updateNSView(
        _ nsView: CanvasNSView,
        context: Context
    ) {
        configure(nsView)
    }

    static func dismantleNSView(
        _ nsView: CanvasNSView,
        coordinator: ()
    ) {
        nsView.cancelInteraction()
    }

    func configure(_ view: CanvasNSView) {
        view.onCompleteStroke = { [weak session] points, color, width in
            _ = session?.completeStroke(
                points: points,
                color: color,
                width: width
            )
        }
        view.onErase = { [weak session] ids in
            _ = session?.erase(strokeIDs: ids)
        }
        view.onViewportChange = { [weak session] viewport in
            session?.setViewport(viewport)
        }
        view.onSelectImage = { [weak session] id in
            session?.selectImage(id)
        }
        view.onTransformImage = { [weak session] id, transform in
            _ = session?.transformImage(id, to: transform)
        }
        view.onDeleteSelectedImage = { [weak session] in
            _ = session?.deleteSelectedImage()
        }
        view.onNudgeSelectedImage = { [weak session] delta in
            _ = session?.nudgeSelectedImage(viewDelta: delta)
        }
        view.onBringSelectedImageForward = { [weak session] in
            _ = session?.bringSelectedImageForward()
        }
        view.onSendSelectedImageBackward = { [weak session] in
            _ = session?.sendSelectedImageBackward()
        }
        view.onImportImageData = { [weak session] data, point in
            Task { @MainActor [weak session] in
                _ = await session?.importImage(data: data, at: point)
            }
        }
        view.onImportImageURL = { [weak session] url, point, removeAfterImport in
            Task { @MainActor [weak session] in
                _ = await session?.importImage(url: url, at: point)
                if removeAfterImport {
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.removeItem(
                        at: url.deletingLastPathComponent()
                    )
                }
            }
        }
        view.onPlaceText = { [weak session] placement, point in
            Task { @MainActor [weak session] in
                _ = await session?.completePendingText(placement, at: point)
            }
        }
        view.onCompleteShape = { [weak session] shape, start, end in
            _ = session?.completePendingShape(shape, from: start, to: end)
        }
        view.onCancelPlacement = { [weak session] in
            session?.cancelPendingPlacement()
        }
        view.configure(
            canvasID: session.selectedCanvasID,
            strokes: session.strokes,
            images: session.images,
            selectedImageID: session.selectedImageID,
            tool: session.tool,
            color: session.color,
            width: session.width,
            viewport: session.viewport,
            pendingPlacement: session.pendingPlacement,
            clearReadabilityEnabled: clearReadabilityEnabled
        )
    }
}

@MainActor
final class CanvasNSView: NSView {
    var onCompleteStroke: (
        _ points: [CanvasPoint],
        _ color: CanvasInkColor,
        _ width: Double
    ) -> Void = { _, _, _ in }
    var onErase: (Set<UUID>) -> Void = { _ in }
    var onViewportChange: (CanvasViewport) -> Void = { _ in }
    var onSelectImage: (UUID?) -> Void = { _ in }
    var onTransformImage: (UUID, CanvasImageTransform) -> Void = { _, _ in }
    var onDeleteSelectedImage: () -> Void = {}
    var onNudgeSelectedImage: (CGSize) -> Void = { _ in }
    var onBringSelectedImageForward: () -> Void = {}
    var onSendSelectedImageBackward: () -> Void = {}
    var onImportImageData: (Data, CanvasPoint) -> Void = { _, _ in }
    var onImportImageURL: (URL, CanvasPoint, Bool) -> Void = { _, _, _ in }
    var onPlaceText: (CanvasTextPlacement, CanvasPoint) -> Void = { _, _ in }
    var onCompleteShape: (
        CanvasShapeKind,
        CanvasPoint,
        CanvasPoint
    ) -> Void = { _, _, _ in }
    var onCancelPlacement: () -> Void = {}

    enum ImagePointerMode {
        case none
        case moving(
            id: UUID,
            startWorldPoint: CanvasPoint,
            original: CanvasImageTransform
        )
        case resizing(
            id: UUID,
            handle: CanvasImageResizeHandle,
            original: CanvasImageTransform
        )
    }

    struct ShapePointerMode {
        let kind: CanvasShapeKind
        let startViewPoint: CGPoint
        let startWorldPoint: CanvasPoint
        var endWorldPoint: CanvasPoint
    }

    static let directImagePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.image.identifier)
    ]

    let interaction = CanvasInteractionController()
    let pathCache = CanvasPathCache()
    let imageCache = CanvasImageDecodeCache()
    let filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Attic Canvas File Promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    var canvasID = CanvasBoardItem.logicalBoardID
    var images: [CanvasPlacedImage] = []
    var imageSignatures: [CanvasImageDisplaySignature] = []
    var selectedImageID: UUID?
    var pendingPlacement: CanvasPendingPlacement?
    var previewImageTransform: CanvasImageTransform?
    var imagePointerMode: ImagePointerMode = .none
    var shapePointerMode: ShapePointerMode?
    var shapePreview: CanvasStrokeGeometry?
    var clearReadabilityEnabled = false
    var panLastPoint: CGPoint?
    var spacePressed = false
    var trackingAreaReference: NSTrackingArea?
    nonisolated(unsafe) var appResignObservation: NSObjectProtocol?
    nonisolated(unsafe) var windowResignObservation: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(
            [.fileURL]
                + Self.directImagePasteboardTypes
                + NSFilePromiseReceiver.readableDraggedTypes.map {
                    NSPasteboard.PasteboardType(rawValue: $0)
                }
        )
        imageCache.onImageReady = { [weak self] in
            self?.needsDisplay = true
        }

        // Own pinch recognition at the native Canvas boundary. Depending on
        // responder-chain magnify delivery alone lets a SwiftUI ancestor take
        // the stream after focus or native-view lifecycle changes. AppKit
        // gives this recognizer first access to events hit-tested to the
        // Canvas, and delays propagation so the zoom is applied exactly once.
        let magnificationRecognizer = NSMagnificationGestureRecognizer(
            target: self,
            action: #selector(handleMagnification(_:))
        )
        magnificationRecognizer.delaysMagnificationEvents = true
        addGestureRecognizer(magnificationRecognizer)

        appResignObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelInteraction()
            }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let appResignObservation {
            NotificationCenter.default.removeObserver(appResignObservation)
        }
        if let windowResignObservation {
            NotificationCenter.default.removeObserver(windowResignObservation)
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func configure(
        canvasID: UUID,
        strokes: [CanvasStroke],
        images: [CanvasPlacedImage],
        selectedImageID: UUID?,
        tool: CanvasTool,
        color: CanvasInkColor,
        width: Double,
        viewport: CanvasViewport,
        pendingPlacement: CanvasPendingPlacement?,
        clearReadabilityEnabled: Bool
    ) {
        var changed = false
        if self.canvasID != canvasID {
            self.canvasID = canvasID
            previewImageTransform = nil
            imagePointerMode = .none
            imageCache.removeAll()
            changed = true
        }
        let nextImageSignatures = images.map(CanvasImageDisplaySignature.init)
        if imageSignatures != nextImageSignatures {
            if case .none = imagePointerMode {
                // No in-flight image gesture to cancel.
            } else {
                imagePointerMode = .none
                previewImageTransform = nil
            }
            self.images = images
            imageSignatures = nextImageSignatures
            changed = true
        }
        if self.selectedImageID != selectedImageID {
            self.selectedImageID = selectedImageID
            imagePointerMode = .none
            previewImageTransform = nil
            changed = true
        }
        if self.pendingPlacement != pendingPlacement {
            self.pendingPlacement = pendingPlacement
            shapePointerMode = nil
            shapePreview = nil
            changed = true
        }
        if self.clearReadabilityEnabled != clearReadabilityEnabled {
            self.clearReadabilityEnabled = clearReadabilityEnabled
            changed = true
        }
        if interaction.configure(
            strokes: strokes,
            tool: tool,
            color: color,
            width: width,
            viewport: viewport
        ) {
            changed = true
        }
        imageCache.prepare(for: images)
        if changed { needsDisplay = true }
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let windowResignObservation {
            NotificationCenter.default.removeObserver(windowResignObservation)
            self.windowResignObservation = nil
        }
        guard let window else {
            cancelInteraction()
            return
        }

        windowResignObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelInteraction()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: baseCursor)
    }

    override func mouseMoved(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let displayImages = imagesForDisplay
        imageCache.prepare(for: displayImages)
        drawCanvas(
            in: context,
            bounds: bounds,
            interaction: interaction,
            pathCache: pathCache,
            backgroundColor: NSColor.clear.cgColor,
            strokeColor: { $0.nsColor.cgColor },
            eraserOutlineColor: NSColor.controlAccentColor.cgColor,
            images: displayImages,
            selectedImageID: selectedImageID,
            imageProvider: { [imageCache] image in
                imageCache.image(for: image)
            },
            imageSelectionColor: NSColor.controlAccentColor.cgColor,
            shapePreview: shapePreview,
            strokeReadabilityShadowColor: clearReadabilityEnabled
                ? readabilityShadowColor
                : nil
        )
    }

    private var readabilityShadowColor: CGColor {
        let match = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return (match == .darkAqua
            ? NSColor.black.withAlphaComponent(0.56)
            : NSColor.white.withAlphaComponent(0.62)).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        if spacePressed {
            beginPan(at: viewPoint)
            return
        }

        let worldPoint = interaction.viewport.worldPoint(
            for: viewPoint,
            in: bounds.size
        )
        guard worldPoint.isFinite else { return }

        switch pendingPlacement {
        case let .text(placement):
            onPlaceText(placement, worldPoint)
            return
        case let .shape(shape):
            _ = interaction.cancel()
            discardImagePreview()
            onSelectImage(nil)
            selectedImageID = nil
            shapePointerMode = ShapePointerMode(
                kind: shape,
                startViewPoint: viewPoint,
                startWorldPoint: worldPoint,
                endWorldPoint: worldPoint
            )
            shapePreview = nil
            needsDisplay = true
            return
        case nil:
            break
        }

        if interaction.tool == .select,
           let selectedImage,
           let handle = CanvasImagePlacement.resizeHandle(
                at: viewPoint,
                image: selectedImage,
                viewport: interaction.viewport,
                viewportSize: bounds.size,
                radius: 9
           ) {
            _ = interaction.cancel()
            imagePointerMode = .resizing(
                id: selectedImage.id,
                handle: handle,
                original: selectedImage.transform
            )
            previewImageTransform = selectedImage.transform
            needsDisplay = true
            cursor(for: resizeCursorRole(for: handle)).set()
            return
        }

        if interaction.tool == .select,
           let hit = CanvasImagePlacement.topmostImage(
            at: worldPoint,
            images: imagesForDisplay
        ) {
            _ = interaction.cancel()
            onSelectImage(hit.id)
            selectedImageID = hit.id
            imagePointerMode = .moving(
                id: hit.id,
                startWorldPoint: worldPoint,
                original: hit.transform
            )
            previewImageTransform = hit.transform
            needsDisplay = true
            NSCursor.closedHand.set()
            return
        }

        onSelectImage(nil)
        selectedImageID = nil
        previewImageTransform = nil
        imagePointerMode = .none
        if interaction.beginInk(at: viewPoint, in: bounds.size) {
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let worldPoint = interaction.viewport.worldPoint(
            for: viewPoint,
            in: bounds.size
        )
        if var shapePointerMode {
            guard worldPoint.isFinite else { return }
            shapePointerMode.endWorldPoint = worldPoint
            self.shapePointerMode = shapePointerMode
            let points = shapePointerMode.kind.points(
                from: shapePointerMode.startWorldPoint,
                to: worldPoint
            )
            shapePreview = points.isEmpty ? nil : CanvasStrokeGeometry(
                color: interaction.color,
                width: interaction.width,
                points: points
            )
            needsDisplay = true
            return
        }
        switch imagePointerMode {
        case .none:
            break
        case let .moving(_, startWorldPoint, original):
            previewImageTransform = CanvasImagePlacement.movedTransform(
                from: original,
                by: CanvasPoint(
                    x: worldPoint.x - startWorldPoint.x,
                    y: worldPoint.y - startWorldPoint.y
                )
            )
            needsDisplay = true
            return
        case let .resizing(_, handle, original):
            previewImageTransform = CanvasImagePlacement.resizedTransform(
                from: original,
                handle: handle,
                to: worldPoint,
                preserveAspectRatio: !event.modifierFlags.contains(.option)
            )
            needsDisplay = true
            return
        }

        if spacePressed {
            if interaction.machine.state != .panning {
                beginPan(at: viewPoint)
            } else {
                continuePan(to: viewPoint)
            }
        } else if interaction.machine.state == .panning {
            continuePan(to: viewPoint)
        } else if interaction.appendInk(at: viewPoint, in: bounds.size) {
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if finishShapeInteraction(
            at: convert(event.locationInWindow, from: nil)
        ) { return }
        if finishImageInteraction() { return }
        finishPointerInteraction(
            finalInkPoint: convert(event.locationInWindow, from: nil)
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginPan(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDragged(with event: NSEvent) {
        continuePan(to: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseUp(with event: NSEvent) {
        finishPointerInteraction(finalInkPoint: nil)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginPan(at: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseDragged(with event: NSEvent) {
        continuePan(to: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseUp(with event: NSEvent) {
        finishPointerInteraction(finalInkPoint: nil)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            let factor = exp(Double(event.scrollingDeltaY) * 0.025)
            applyViewportZoom(
                by: factor,
                anchoredAt: point,
                in: bounds.size
            )
            return
        }

        discardImagePreview()
        discardShapePreview()
        prepareForViewportEvent(at: point)
        let viewport = interaction.pan(byViewTranslation: CGSize(
            width: event.scrollingDeltaX,
            height: event.scrollingDeltaY
        ))
        onViewportChange(viewport)
        needsDisplay = true
    }

    @objc private func handleMagnification(
        _ recognizer: NSMagnificationGestureRecognizer
    ) {
        let magnification = recognizer.magnification
        guard magnification.isFinite, magnification != 0 else { return }

        // NSMagnificationGestureRecognizer reports the current change. Consume
        // it incrementally so repeated callbacks do not compound old deltas.
        recognizer.magnification = 0
        applyViewportZoom(
            by: max(1 + Double(magnification), 0.01),
            anchoredAt: recognizer.location(in: self),
            in: bounds.size
        )
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "v":
            return importPasteboard(.general, at: defaultPasteViewPoint)
        case "]":
            guard selectedImageID != nil else { return false }
            onBringSelectedImageForward()
            return true
        case "[":
            guard selectedImageID != nil else { return false }
            onSendSelectedImageBackward()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:
            if !spacePressed {
                cancelInteraction()
                spacePressed = true
                window?.invalidateCursorRects(for: self)
            }
        case 53:
            cancelInteraction()
            onCancelPlacement()
            onSelectImage(nil)
            selectedImageID = nil
            needsDisplay = true
        case 51, 117:
            if selectedImageID != nil {
                onDeleteSelectedImage()
            } else {
                super.keyDown(with: event)
            }
        case 123, 124, 125, 126:
            guard selectedImageID != nil else {
                super.keyDown(with: event)
                return
            }
            let distance: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: CGSize
            switch event.keyCode {
            case 123: delta = CGSize(width: -distance, height: 0)
            case 124: delta = CGSize(width: distance, height: 0)
            case 125: delta = CGSize(width: 0, height: distance)
            default: delta = CGSize(width: 0, height: -distance)
            }
            onNudgeSelectedImage(delta)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49 else {
            super.keyUp(with: event)
            return
        }

        spacePressed = false
        if interaction.machine.state == .panning {
            interaction.finishViewportGesture()
            panLastPoint = nil
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resignFirstResponder() -> Bool {
        cancelInteraction()
        return super.resignFirstResponder()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasSupportedImagePayload(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasSupportedImagePayload(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        return importPasteboard(sender.draggingPasteboard, at: point)
    }

    @objc func paste(_ sender: Any?) {
        importPasteboard(.general, at: defaultPasteViewPoint)
    }

    func cancelInteraction() {
        if interaction.cancel() {
            needsDisplay = true
        }
        discardImagePreview()
        discardShapePreview()
        panLastPoint = nil
        spacePressed = false
        window?.invalidateCursorRects(for: self)
    }

}
#endif
