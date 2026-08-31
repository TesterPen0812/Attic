#if os(macOS)
@preconcurrency import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CanvasNSViewRepresentable: NSViewRepresentable {
    @ObservedObject var session: CanvasSession
    let clearReadabilityEnabled: Bool

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView()
        view.activateRepresentation()
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
        nsView.deactivateRepresentation()
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
            session?.erase(strokeIDs: ids) ?? false
        }
        view.onViewportChange = { [weak session, weak view] viewport in
            guard view?.isRepresentationActive == true else { return }
            session?.setViewport(viewport)
        }
        view.onSelectImage = { [weak session] id in
            session?.selectImage(id)
        }
        view.onTransformImage = { [weak session] id, transform in
            _ = session?.transformImage(id, to: transform)
        }
        view.onDeleteSelectedImage = { [weak session] in
            session?.deleteSelectedImage() ?? false
        }
        view.onNudgeSelectedImage = { [weak session] delta in
            session?.nudgeSelectedImage(viewDelta: delta) ?? false
        }
        view.onResizeSelectedImage = { [weak session] factor in
            session?.resizeSelectedImage(by: factor) ?? false
        }
        view.onBringSelectedImageForward = { [weak session] in
            session?.bringSelectedImageForward() ?? false
        }
        view.onSendSelectedImageBackward = { [weak session] in
            session?.sendSelectedImageBackward() ?? false
        }
        view.onCaptureImageImportTarget = { [weak session] in
            session?.captureImageImportTarget()
        }
        view.onImportImageBatch = { [weak session] batch in
            session?.startImageImportBatch(batch)
        }
        view.onCancelImageImportBatches = { [weak session] in
            session?.cancelAllImageImportBatches()
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
    enum ViewportGestureMode: Equatable {
        case pan
        case zoom
    }

    enum ViewportGestureSource: Equatable {
        case scroll
        case magnification
    }

    struct ViewportGestureSequence: Equatable {
        let source: ViewportGestureSource
        let mode: ViewportGestureMode
    }

    var onCompleteStroke: (
        _ points: [CanvasPoint],
        _ color: CanvasInkColor,
        _ width: Double
    ) -> Void = { _, _, _ in }
    var onErase: (Set<UUID>) -> Bool = { _ in false }
    var onViewportChange: (CanvasViewport) -> Void = { _ in }
    var onSelectImage: (UUID?) -> Void = { _ in }
    var onTransformImage: (UUID, CanvasImageTransform) -> Void = { _, _ in }
    var onDeleteSelectedImage: () -> Bool = { false }
    var onNudgeSelectedImage: (CGSize) -> Bool = { _ in false }
    var onResizeSelectedImage: (Double) -> Bool = { _ in false }
    var onBringSelectedImageForward: () -> Bool = { false }
    var onSendSelectedImageBackward: () -> Bool = { false }
    var onCaptureImageImportTarget: () -> CanvasImportTarget? = { nil }
    var onImportImageBatch: (CanvasImageImportBatch) -> Void = { _ in }
    var onCancelImageImportBatches: () -> Void = {}
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
    var filePromiseBatches: [UUID: CanvasFilePromiseBatchCoordinator] = [:]

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
    var activeViewportGesture: ViewportGestureSequence?
    var pendingScrollMomentumMode: ViewportGestureMode?
    var suppressesScrollSequence = false
    var suppressesMagnification = false
    private(set) var isRepresentationActive = true
    var trackingAreaReference: NSTrackingArea?
    var canvasAccessibilityElements: [
        CanvasAccessibilityObjectKey: CanvasAccessibilityObjectElement
    ] = [:]
    var canvasAccessibilityNavigationOrder: [CanvasAccessibilityObjectKey] = []
    var accessibilityFocusedObjectKey: CanvasAccessibilityObjectKey?
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

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Canvas objects" }

    override func accessibilityHelp() -> String? {
        "Use Tab and Shift-Tab to move between canvas objects. Arrow keys move an image; Option-arrow keys resize it."
    }

    override func accessibilityChildren() -> [Any]? {
        refreshCanvasAccessibilityElements(postLayoutNotification: false)
        return canvasAccessibilityNavigationOrder.compactMap {
            canvasAccessibilityElements[$0]
        }
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        refreshCanvasAccessibilityElements(postLayoutNotification: false)
        return canvasAccessibilityNavigationOrder.compactMap { key in
            guard let element = canvasAccessibilityElements[key],
                  element.isAccessibilitySelected() else { return nil }
            return element
        }
    }

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
            canvasAccessibilityElements.removeAll()
            canvasAccessibilityNavigationOrder.removeAll()
            accessibilityFocusedObjectKey = nil
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
            if let selectedImageID {
                accessibilityFocusedObjectKey = CanvasAccessibilityObjectKey(
                    kind: .image,
                    id: selectedImageID
                )
            }
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
        refreshCanvasAccessibilityElements(postLayoutNotification: changed)
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
        interruptViewportGestureForPointer()
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
            accessibilityFocusedObjectKey = CanvasAccessibilityObjectKey(
                kind: .image,
                id: hit.id
            )
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
        accessibilityFocusedObjectKey = nil
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
        let requestedMode: ViewportGestureMode = event.modifierFlags.contains(.command)
            ? .zoom
            : .pan
        let directPhase = event.phase
        let momentumPhase = event.momentumPhase
        let directBegan = directPhase.contains(.began)
        let directCancelled = directPhase.contains(.cancelled)
        let directEnded = directPhase.contains(.ended) || directCancelled
        let momentumBegan = momentumPhase.contains(.began)
        let momentumEnded = momentumPhase.contains(.ended)
            || momentumPhase.contains(.cancelled)
        let isStandalone = directPhase.isEmpty && momentumPhase.isEmpty
        let delta = CGSize(
            width: event.scrollingDeltaX,
            height: event.scrollingDeltaY
        )
        let hasDelta = delta.width.isFinite
            && delta.height.isFinite
            && (delta.width != 0 || delta.height != 0)

        if directBegan {
            finishViewportGestureSequence(source: .scroll, at: point)
            pendingScrollMomentumMode = nil
            suppressesScrollSequence = false
            _ = beginViewportGestureSequence(
                source: .scroll,
                mode: requestedMode
            )
        } else if suppressesScrollSequence {
            if isStandalone {
                guard !hasActivePointerInteraction else { return }
                suppressesScrollSequence = false
                pendingScrollMomentumMode = nil
            } else {
                if momentumEnded {
                    suppressesScrollSequence = false
                    pendingScrollMomentumMode = nil
                } else if directEnded {
                    pendingScrollMomentumMode = nil
                }
                return
            }
        }

        if momentumBegan, activeViewportGesture?.source != .scroll {
            guard interaction.machine.state == .idle else {
                pendingScrollMomentumMode = nil
                suppressesScrollSequence = true
                return
            }
            _ = beginViewportGestureSequence(
                source: .scroll,
                mode: pendingScrollMomentumMode ?? requestedMode
            )
        }

        if activeViewportGesture == nil,
           hasDelta,
           !directCancelled,
           !momentumEnded {
            _ = beginViewportGestureSequence(
                source: .scroll,
                mode: !momentumPhase.isEmpty
                    ? pendingScrollMomentumMode ?? requestedMode
                    : requestedMode
            )
        }

        if hasDelta,
           let sequence = activeViewportGesture,
           sequence.source == .scroll {
            switch sequence.mode {
            case .pan:
                applyViewportPan(by: delta)
            case .zoom:
                applyViewportZoom(
                    by: exp(Double(delta.height) * 0.025),
                    anchoredAt: point,
                    in: bounds.size
                )
            }
        }

        if isStandalone {
            finishViewportGestureSequence(source: .scroll, at: point)
            pendingScrollMomentumMode = nil
        } else if directEnded {
            let completedMode = activeViewportGesture?.source == .scroll
                ? activeViewportGesture?.mode
                : nil
            finishViewportGestureSequence(source: .scroll, at: point)
            pendingScrollMomentumMode = directCancelled ? nil : completedMode
        }

        if momentumEnded {
            finishViewportGestureSequence(source: .scroll, at: point)
            pendingScrollMomentumMode = nil
            suppressesScrollSequence = false
        }
    }

    @objc private func handleMagnification(
        _ recognizer: NSMagnificationGestureRecognizer
    ) {
        guard isRepresentationActive else { return }
        let magnification = recognizer.magnification
        recognizer.magnification = 0
        let point = recognizer.location(in: self)

        switch recognizer.state {
        case .began:
            suppressesMagnification = false
            _ = beginViewportGestureSequence(
                source: .magnification,
                mode: .zoom
            )
        case .changed:
            guard !suppressesMagnification else { return }
            if activeViewportGesture == nil {
                _ = beginViewportGestureSequence(
                    source: .magnification,
                    mode: .zoom
                )
            }
        case .ended, .cancelled, .failed:
            finishViewportGestureSequence(source: .magnification, at: point)
            suppressesMagnification = false
            return
        case .possible:
            // AppKit does not dispatch actions while possible. Keeping this
            // path self-contained makes direct action tests deterministic.
            guard !suppressesMagnification,
                  magnification.isFinite,
                  magnification != 0 else { return }
            guard beginViewportGestureSequence(
                source: .magnification,
                mode: .zoom
            ) else { return }
            applyViewportZoom(
                by: max(1 + Double(magnification), 0.01),
                anchoredAt: point,
                in: bounds.size
            )
            finishViewportGestureSequence(source: .magnification, at: point)
            return
        @unknown default:
            finishViewportGestureSequence(source: .magnification, at: point)
            suppressesMagnification = false
            return
        }

        guard magnification.isFinite, magnification != 0,
              activeViewportGesture == ViewportGestureSequence(
                source: .magnification,
                mode: .zoom
              ) else { return }
        applyViewportZoom(
            by: max(1 + Double(magnification), 0.01),
            anchoredAt: point,
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
            return onBringSelectedImageForward()
        case "[":
            guard selectedImageID != nil else { return false }
            return onSendSelectedImageBackward()
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48:
            let backward = event.modifierFlags.contains(.shift)
            guard focusNextCanvasObject(backward: backward) == nil else { return }
            accessibilityFocusedObjectKey = nil
            refreshCanvasAccessibilityElements(postLayoutNotification: false)
            if backward {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
        case 49:
            if !spacePressed {
                cancelInteraction()
                spacePressed = true
                window?.invalidateCursorRects(for: self)
            }
        case 53:
            cancelInteraction()
            cancelFilePromiseBatches()
            onCancelImageImportBatches()
            onCancelPlacement()
            onSelectImage(nil)
            selectedImageID = nil
            accessibilityFocusedObjectKey = nil
            refreshCanvasAccessibilityElements(postLayoutNotification: false)
            needsDisplay = true
        case 51, 117:
            if let key = accessibilityFocusedObjectKey,
               key.kind == .stroke {
                onErase([key.id])
            } else if selectedImageID != nil {
                onDeleteSelectedImage()
            } else {
                super.keyDown(with: event)
            }
        case 123, 124, 125, 126:
            guard selectedImageID != nil else {
                super.keyDown(with: event)
                return
            }
            if event.modifierFlags.contains(.option) {
                let grows = event.keyCode == 124 || event.keyCode == 126
                onResizeSelectedImage(grows ? 1.1 : 0.9)
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
        let interruptedScroll = activeViewportGesture?.source == .scroll
            || pendingScrollMomentumMode != nil
        let interruptedMagnification = activeViewportGesture?.source == .magnification
        if interaction.cancel() {
            needsDisplay = true
        }
        discardImagePreview()
        discardShapePreview()
        panLastPoint = nil
        spacePressed = false
        resetViewportGestureRouting(
            suppressScroll: interruptedScroll,
            suppressMagnification: interruptedMagnification
        )
        window?.invalidateCursorRects(for: self)
    }

    func activateRepresentation() {
        isRepresentationActive = true
        gestureRecognizers.forEach { $0.isEnabled = true }
    }

    func deactivateRepresentation() {
        isRepresentationActive = false
        gestureRecognizers.forEach { $0.isEnabled = false }
        cancelInteraction()
        cancelFilePromiseBatches()
        onCancelImageImportBatches()
        onViewportChange = { _ in }
    }

}
#endif
