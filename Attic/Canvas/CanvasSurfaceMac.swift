#if os(macOS)
@preconcurrency import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct CanvasNSViewRepresentable: NSViewRepresentable {
    @ObservedObject var session: CanvasSession
    let selectionAccentColor: NSColor
    let clearReadabilityEnabled: Bool
    var excludedRects: [CGRect] = []
    /// Presents the original bytes of an image for export. The canvas surface
    /// raises it from an accessibility or contextual recovery action; the
    /// owning SwiftUI view owns the file exporter.
    var onRequestImageExport: (CanvasPlacedImage) -> Void = { _ in }

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
        guard let completeDeactivation = nsView.prepareForDeferredDeactivation() else { return }
        // Dismantling runs while SwiftUI invalidates its graph. Finishing an
        // open editor publishes its retained draft and history availability,
        // which must happen after that graph update has completed.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                completeDeactivation()
            }
        }
    }

    func configure(_ view: CanvasNSView) {
        // The native view represents this session for its whole active
        // lifetime. Dismantling may defer the final draft commit until after
        // SwiftUI graph teardown, so the view must keep that session alive
        // until the deferred completion has captured it.
        view.representedSessionLifetime = session
        if view.excludedControlRects != excludedRects {
            view.excludedControlRects = excludedRects
            view.window?.invalidateCursorRects(for: view)
        }
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
        view.onFitViewport = { [weak session, weak view] size in
            session?.fit(in: size, excluding: view?.excludedControlRects ?? [])
        }
        view.onResetViewport = { [weak session] in session?.resetView() }
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
        view.onBeginTextInsertion = { [weak session] origin, width in
            session?.makeTextInsertion(at: origin, width: width)
        }
        view.onCompleteShape = { [weak session] shape, start, end in
            _ = session?.completePendingShape(shape, from: start, to: end)
        }
        view.onCancelPlacement = { [weak session] in
            session?.cancelPendingPlacement()
        }
        view.onDecodeFailuresChanged = { [weak session] ids in
            session?.setFailedImageIDs(ids)
        }
        view.onRetryImageDecode = { [weak session] id in
            session?.retryImageDecode(id)
        }
        view.onRequestImageExport = onRequestImageExport
        view.onSelectSemanticObject = { [weak session] id in session?.selectSemanticObject(id) }
        view.onTransformSemanticObject = { [weak session] id, transform in
            _ = session?.transformSemanticObject(id, to: transform)
        }
        view.onDeleteSemanticObject = { [weak session] id in session?.deleteSemanticObject(id) ?? false }
        view.onNudgeSemanticObject = { [weak session] delta in session?.nudgeSelectedSemanticObject(delta) ?? false }
        view.onResizeSemanticObject = { [weak session] factor in session?.resizeSelectedSemanticObject(by: factor) ?? false }
        view.onMoveSemanticLayer = { [weak session] forward in session?.moveSelectedSemanticLayer(forward: forward) ?? false }
        view.onCommitSemanticText = { [weak session] draft in session?.commitSemanticText(draft) ?? false }
        view.onSemanticTextConflict = { [weak session] key in
            Task { @MainActor [weak session] in
                guard let session, session.selectedCanvasID == key.canvasID,
                      session.semanticTextDraft(key) != nil else { return }
                session.reportSemanticTextConflict()
            }
        }
        view.onPreserveSemanticDraft = { [weak session] key, draft in session?.preserveSemanticTextDraft(key, draft: draft) }
        view.onSemanticDraft = { [weak session] key in session?.semanticTextDraft(key) }
        // Editor focus and history resets can happen inside a SwiftUI update,
        // so they republish availability on the next run-loop pass.
        view.onEditingAvailabilityChange = { [weak session] in
            RunLoop.current.perform(inModes: [.common]) { [weak session] in
                MainActor.assumeIsolated { session?.invalidateEditingAvailability() }
            }
        }
        if view.interactionInterruptionObservation == nil, view.isRepresentationActive {
            view.interactionInterruptionObservation = session.interactionInterruptions
                .sink { [weak view] in
                    MainActor.assumeIsolated { view?.interruptTransientInteraction() }
                }
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
            clearReadabilityEnabled: clearReadabilityEnabled,
            selectionAccentColor: selectionAccentColor,
            semanticObjects: session.semanticObjects,
            selectedSemanticObjectID: session.selectedSemanticObjectID
        )
        if let request = session.imageDecodeRetryRequest,
           view.lastDecodeRetryRequest != request {
            view.lastDecodeRetryRequest = request
            for image in view.images where request.imageIDs.contains(image.id) {
                view.imageCache.retryDecode(for: image)
            }
        }
        if let request = session.semanticTextEditRequest, view.lastSemanticTextEditRequest != request {
            view.lastSemanticTextEditRequest = request
            if let object = session.selectedSemanticObject { view.beginSemanticTextEditing(object) }
        }
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
    var onFitViewport: (CGSize) -> Void = { _ in }
    var onResetViewport: () -> Void = {}
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
    var onBeginTextInsertion: (CanvasPoint, Double) -> CanvasSemanticTextDraft? = { _, _ in nil }
    var editingSemanticIsInsertion = false
    var onCompleteShape: (
        CanvasShapeKind,
        CanvasPoint,
        CanvasPoint
    ) -> Void = { _, _, _ in }
    var onCancelPlacement: () -> Void = {}
    var onDecodeFailuresChanged: (Set<UUID>) -> Void = { _ in }
    var onRetryImageDecode: (UUID) -> Void = { _ in }
    var onRequestImageExport: (CanvasPlacedImage) -> Void = { _ in }
    var lastDecodeRetryRequest: CanvasImageDecodeRetryRequest?
    var lastSemanticTextEditRequest: UUID?
    var onSelectSemanticObject: (UUID?) -> Void = { _ in }
    var onTransformSemanticObject: (UUID, CanvasImageTransform) -> Void = { _, _ in }
    var onDeleteSemanticObject: (UUID) -> Bool = { _ in false }
    var onNudgeSemanticObject: (CGSize) -> Bool = { _ in false }
    var onResizeSemanticObject: (Double) -> Bool = { _ in false }
    var onMoveSemanticLayer: (Bool) -> Bool = { _ in false }
    var onCommitSemanticText: (CanvasSemanticTextDraft) -> Bool = { _ in false }
    var onSemanticTextConflict: (CanvasReplicaKey) -> Void = { _ in }
    var onPreserveSemanticDraft: (CanvasReplicaKey, CanvasSemanticTextDraft?) -> Void = { _, _ in }
    var onSemanticDraft: (CanvasReplicaKey) -> CanvasSemanticTextDraft? = { _ in nil }
    var onEditingAvailabilityChange: () -> Void = {}
    var semanticObjects: [CanvasSemanticObject] = [] {
        didSet { canvasContentRevision &+= 1 }
    }
    var selectedSemanticObjectID: UUID?
    var semanticPointerActive = false
    let semanticRenderCache = CanvasSemanticRenderCache()
    var semanticTextEditor: CanvasSemanticTextEditor?
    var editingSemanticObjectID: UUID?
    var editingSemanticBaseline: CanvasSemanticObject?

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
    let imageCache = CanvasImageDecodeCache(
        cancelsActiveDecodesWhenRemoved: false
    )
    let filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Attic Canvas File Promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    var filePromiseBatches: [UUID: CanvasFilePromiseBatchCoordinator] = [:]

    var canvasID = CanvasBoardItem.logicalBoardID
    var images: [CanvasPlacedImage] = [] {
        didSet { canvasContentRevision &+= 1 }
    }
    var imageSignatures: [CanvasImageDisplaySignature] = []
    /// Bumped whenever the objects on the canvas change. Everything derived
    /// from content — the z-ordered display array, accessibility elements —
    /// is keyed on it so viewport-only changes cannot invalidate them
    /// (CANVAS-017/PERF-09, CANVAS-018/PERF-10).
    var canvasContentRevision: UInt64 = 0
    let imageDisplayCache = CanvasImageDisplayCache()
    var canvasAccessibilityContentIsStale = true
    var canvasAccessibilityPendingLayoutNotification = false
    var canvasAccessibilityRebuildIsScheduled = false
    var hasBuiltCanvasAccessibilityElements = false
    var canvasAccessibilityBuiltViewport: CanvasViewport?
    /// Test seam: counts full accessibility rebuilds.
    var accessibilityRebuildCount: UInt64 = 0
    var lastCursorRectsRole: CanvasCursorRole?
    var selectedImageID: UUID?
    var pendingPlacement: CanvasPendingPlacement?
    var previewImageTransform: CanvasImageTransform?
    var imagePointerMode: ImagePointerMode = .none
    var shapePointerMode: ShapePointerMode?
    var shapePreview: CanvasStrokeGeometry?
    var clearReadabilityEnabled = false
    var selectionAccentColor = NSColor.controlAccentColor
    var panLastPoint: CGPoint?
    var spacePressed = false
    var activeViewportGesture: ViewportGestureSequence?
    var pendingScrollMomentumMode: ViewportGestureMode?
    var suppressesScrollSequence = false
    var suppressesMagnification = false
    private(set) var isRepresentationActive = true
    var representedSessionLifetime: CanvasSession?
    var trackingAreaReference: NSTrackingArea?
    var canvasAccessibilityElements: [
        CanvasAccessibilityObjectKey: CanvasAccessibilityObjectElement
    ] = [:]
    var canvasAccessibilityNavigationOrder: [CanvasAccessibilityObjectKey] = []
    var accessibilityFocusedObjectKey: CanvasAccessibilityObjectKey?
    var interactionInterruptionObservation: AnyCancellable?
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
            guard let self else { return }
            needsDisplay = true
            onDecodeFailuresChanged(Set(images.filter {
                self.imageCache.state(for: $0) == .failed
            }.map(\.id)))
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
            // The observer runs on the main queue. Cancel this interaction
            // now, not a later gesture after the panel has regained focus.
            MainActor.assumeIsolated {
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
    var excludedControlRects: [CGRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !excludedControlRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Canvas objects" }

    override func accessibilityHelp() -> String? {
        "Use Tab and Shift-Tab to move between canvas objects. Arrow keys move a selected object; Option-arrow keys resize it. Return edits text."
    }

    override func accessibilityChildren() -> [Any]? {
        refreshCanvasAccessibilityElements(postLayoutNotification: false)
        var children: [Any] = canvasAccessibilityNavigationOrder.compactMap {
            canvasAccessibilityElements[$0]
        }
        if let semanticTextEditor { children.append(semanticTextEditor) }
        return children
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
        clearReadabilityEnabled: Bool,
        selectionAccentColor: NSColor = .controlAccentColor,
        semanticObjects: [CanvasSemanticObject] = [],
        selectedSemanticObjectID: UUID? = nil
    ) {
        var changed = false
        // Accessibility describes objects, not the viewport, so pan and zoom
        // frames must not drag a rebuild along (CANVAS-017/PERF-09).
        var contentChanged = false
        if self.canvasID != canvasID {
            suspendSemanticTextEditing()
            self.canvasID = canvasID
            previewImageTransform = nil
            imagePointerMode = .none
            imageCache.removeAll()
            canvasAccessibilityElements.removeAll()
            canvasAccessibilityNavigationOrder.removeAll()
            accessibilityFocusedObjectKey = nil
            hasBuiltCanvasAccessibilityElements = false
            changed = true
            contentChanged = true
        }
        if self.semanticObjects != semanticObjects {
            if !editingSemanticIsInsertion, let id = editingSemanticObjectID, !semanticObjects.contains(where: { $0.id == id }) {
                suspendSemanticTextEditing()
            }
            reconcileSemanticTextEditing(with: semanticObjects)
            self.semanticObjects = semanticObjects
            semanticRenderCache.prepare(liveIDs: Set(semanticObjects.map(\.id)))
            changed = true
            contentChanged = true
        }
        if self.selectedSemanticObjectID != selectedSemanticObjectID {
            self.selectedSemanticObjectID = selectedSemanticObjectID
            if let id = selectedSemanticObjectID {
                accessibilityFocusedObjectKey = CanvasAccessibilityObjectKey(kind: .semantic, id: id)
            }
            changed = true
            contentChanged = true
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
            contentChanged = true
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
            contentChanged = true
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
        if !self.selectionAccentColor.isEqual(selectionAccentColor) {
            self.selectionAccentColor = selectionAccentColor
            changed = true
        }
        let strokeRevisionBefore = interaction.strokeContentRevision
        if interaction.configure(
            strokes: strokes,
            tool: tool,
            color: color,
            width: width,
            viewport: viewport
        ) {
            changed = true
        }
        if interaction.strokeContentRevision != strokeRevisionBefore {
            contentChanged = true
        }
        imageCache.prepare(
            for: CanvasImageDecodeCandidatePolicy.candidates(
                in: imagesForDisplay,
                viewport: interaction.viewport,
                viewportSize: bounds.size
            )
        )
        if contentChanged {
            invalidateCanvasAccessibilityElements(postLayoutNotification: changed)
        } else {
            // Viewport-only: reposition existing elements rather than
            // rebuilding their labels, values, actions and navigation order.
            updateCanvasAccessibilityFramesForViewport()
        }
        if changed { needsDisplay = true }
        layoutSemanticTextEditor()
        // Cursor rects depend on the tool, pending placement and pointer mode,
        // never on the viewport, so invalidating per pan/zoom frame was waste.
        let cursorRole = baseCursorRole
        if lastCursorRectsRole != cursorRole {
            lastCursorRectsRole = cursorRole
            window?.invalidateCursorRects(for: self)
        }
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
            MainActor.assumeIsolated {
                self?.cancelInteraction()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutSemanticTextEditor()
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
        for rect in excludedControlRects { addCursorRect(rect.intersection(bounds), cursor: .arrow) }
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
        let displayOrder = imageDisplayOrder
        let displayImages = displayOrder.backToFront
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        imageCache.prepare(
            for: CanvasImageDecodeCandidatePolicy.candidates(
                in: displayImages,
                viewport: interaction.viewport,
                viewportSize: bounds.size
            )
        )
        drawCanvas(
            in: context,
            bounds: bounds,
            interaction: interaction,
            pathCache: pathCache,
            backgroundColor: NSColor.clear.cgColor,
            strokeColor: { $0.nsColor.cgColor },
            eraserOutlineColor: selectionAccentColor.cgColor,
            images: displayImages,
            selectedImageID: selectedImageID,
            imageProvider: { [imageCache] image in
                imageCache.image(for: image)
            },
            imageSelectionColor: selectionAccentColor.cgColor,
            shapePreview: shapePreview,
            strokeReadabilityShadowColor: clearReadabilityEnabled
                ? { ink in CanvasSemanticRenderer.readabilityEdgeColor(
                    for: NSColor(cgColor: ink) ?? .labelColor,
                    increasedContrast: increasedContrast).cgColor }
                : nil,
            strokeReadabilityEdgeRadius: AtticClearGlassReadabilityPolicy.edgeRadius,
            drawPlacedObjects: { [self] context, cullingRect in
                let objects = displayImages.map(CanvasPlacedRenderObject.image)
                    + semanticObjectsForDisplay.map(CanvasPlacedRenderObject.semantic)
                for object in objects.sorted(by: CanvasPlacedRenderObject.comesBefore) {
                    guard object.worldRect.intersects(cullingRect) else { continue }
                    switch object {
                    case let .image(image):
                        if let decoded = imageCache.image(for: image) { drawCanvasImage(image, decoded: decoded, in: context) }
                    case let .semantic(object):
                        if object.id != editingSemanticObjectID {
                            CanvasSemanticRenderer.draw(object, in: context, cache: semanticRenderCache,
                                clearReadabilityEnabled: clearReadabilityEnabled,
                                increasedContrast: increasedContrast)
                        }
                    }
                }
            }
        )
        if let selected = selectedSemanticObject {
            drawCanvasObjectSelection(worldRect: selected.worldRect, context: context,
                viewport: interaction.viewport, viewportSize: bounds.size,
                color: selectionAccentColor.cgColor)
        }
        PerformanceSignposts.canvasDidDraw()
    }

    override func mouseDown(with event: NSEvent) {
        guard !excludedControlRects.contains(where: { $0.contains(convert(event.locationInWindow, from: nil)) }) else { return }
        guard finishSemanticTextEditing(commit: true) else { return }
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
            if placement.text.isEmpty {
                _ = interaction.cancel()
                if let object = semanticObject(at: worldPoint), object.content?.text != nil {
                    onSelectSemanticObject(object.id)
                    selectedSemanticObjectID = object.id
                    beginSemanticTextEditing(object)
                } else {
                    let scale = interaction.viewport.scale
                    let origin = CanvasPoint(x: worldPoint.x - 4, y: worldPoint.y - 4)
                    let width = max(48, min(280, (bounds.width - viewPoint.x) / scale))
                    if let draft = onBeginTextInsertion(origin, width) {
                        beginSemanticTextEditing(draft.baseline, insertion: draft)
                    }
                }
                return
            }
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
           beginSemanticPointerInteraction(at: viewPoint, worldPoint: worldPoint, clickCount: event.clickCount) {
            return
        }
        semanticPointerActive = false

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
           let hit = imageDisplayOrder.topmostImage(at: worldPoint) {
            _ = interaction.cancel()
            onSelectImage(hit.id)
            onSelectSemanticObject(nil)
            selectedSemanticObjectID = nil
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
        onSelectSemanticObject(nil)
        selectedSemanticObjectID = nil
        selectedImageID = nil
        accessibilityFocusedObjectKey = nil
        previewImageTransform = nil
        imagePointerMode = .none
        if interaction.beginInk(at: viewPoint, in: bounds.size) {
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if interaction.machine.state == .drawing { PerformanceSignposts.beginCanvasDrag() }
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
                preserveAspectRatio: semanticPointerActive
                    ? event.modifierFlags.contains(.shift)
                    : !event.modifierFlags.contains(.option)
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
        guard isRepresentationActive else { return }
        // A physical pinch can emit incidental two-finger scroll events.
        // Keep the live recognizer in charge; a finished/stale recognizer still
        // permits the existing scroll recovery path without a timeout or timer.
        if activeViewportGesture?.source == .magnification,
           !event.modifierFlags.contains(.command),
           gestureRecognizers.contains(where: {
               $0 is NSMagnificationGestureRecognizer && ($0.state == .began || $0.state == .changed)
           }) { return }
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

        // Ink, image, and shape interactions own the pointer. An incidental
        // scroll must not take over and discard their buffered work (CVD-05);
        // ignore the rest of its sequence, as the momentum guard below does.
        if activeViewportGesture == nil, hasActivePointerInteraction {
            pendingScrollMomentumMode = nil
            if momentumEnded {
                suppressesScrollSequence = false
            } else if !isStandalone {
                suppressesScrollSequence = true
            }
            return
        }

        if directBegan {
            if activeViewportGesture?.source == .magnification {
                finishViewportGestureSequence(source: .magnification, at: point)
                suppressesMagnification = true
            }
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
        // Ink, image, and shape interactions own the pointer. A pinch must not
        // take over and discard their buffered work (CVD-05); a continuous
        // pinch stays ignored until its next began.
        if activeViewportGesture == nil, hasActivePointerInteraction {
            switch recognizer.state {
            case .began, .changed:
                suppressesMagnification = true
                return
            case .possible:
                return
            default:
                break
            }
        }

        switch recognizer.state {
        case .began:
            suppressesMagnification = false
            // A new physical pinch supersedes scroll momentum (including a
            // scroll whose terminal event was consumed by an ancestor). Do
            // not let stale scroll ownership reject the whole pinch stream.
            if activeViewportGesture?.source == .scroll, panLastPoint == nil {
                finishViewportGestureSequence(source: .scroll, at: point)
                pendingScrollMomentumMode = nil
                suppressesScrollSequence = true
            }
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
        case .ended:
            if !suppressesMagnification, activeViewportGesture?.source == .magnification {
                applyViewportZoom(by: max(1 + Double(magnification), 0.01), anchoredAt: point, in: bounds.size)
            }
            finishViewportGestureSequence(source: .magnification, at: point)
            suppressesMagnification = false
            return
        case .cancelled, .failed:
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
        let shortcutModifiers = modifiers.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        // Popup-menu shortcuts are not a dependable responder route before
        // their nested menu has opened. Handle viewport keys on the native
        // canvas that actually owns focus, using its current measured bounds.
        // Section replacement can leave NSWindow itself as first responder.
        // An explicit viewport command may claim that otherwise-unassigned
        // focus, but must never take it from another section's text/control.
        if shortcutModifiers == .command || (shortcutModifiers == [.command, .shift] && (key == "=" || key == "+")),
           key == "9" || key == "0" || key == "=" || key == "+" || key == "-",
           isRepresentationActive, !isHiddenOrHasHiddenAncestor, let window,
           window.firstResponder === window || window.firstResponder === self
                || (semanticTextEditor != nil && window.firstResponder === semanticTextEditor) {
            guard finishSemanticTextEditing(commit: true) else { return true }
            window.makeFirstResponder(self)
            interruptViewportGestureForPointer()
            if key == "9" { onFitViewport(bounds.size) }
            else if key == "0" { onResetViewport() }
            else {
                applyViewportZoom(by: key == "-" ? 0.8 : 1.25,
                    anchoredAt: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds.size)
            }
            return true
        }
        if let editor = semanticTextEditor, window?.firstResponder === editor {
            return editor.performKeyEquivalent(with: event)
        }
        guard modifiers.contains(.command),
              let key else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "v":
            return importPasteboard(.general, at: defaultPasteViewPoint)
        case "]":
            if selectedSemanticObjectID != nil { return onMoveSemanticLayer(true) }
            guard selectedImageID != nil else { return false }
            return onBringSelectedImageForward()
        case "[":
            if selectedSemanticObjectID != nil { return onMoveSemanticLayer(false) }
            guard selectedImageID != nil else { return false }
            return onSendSelectedImageBackward()
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            if let object = selectedSemanticObject, object.content?.text != nil {
                beginSemanticTextEditing(object)
            } else { super.keyDown(with: event) }
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
            onSelectSemanticObject(nil)
            selectedSemanticObjectID = nil
            selectedImageID = nil
            accessibilityFocusedObjectKey = nil
            refreshCanvasAccessibilityElements(postLayoutNotification: false)
            needsDisplay = true
        case 51, 117:
            if let id = selectedSemanticObjectID {
                if !onDeleteSemanticObject(id) { super.keyDown(with: event) }
            } else if let key = accessibilityFocusedObjectKey,
               key.kind == .stroke {
                if !onErase([key.id]) {
                    super.keyDown(with: event)
                }
            } else if selectedImageID != nil {
                if !onDeleteSelectedImage() {
                    super.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        case 123, 124, 125, 126:
            guard selectedImageID != nil || selectedSemanticObjectID != nil else {
                super.keyDown(with: event)
                return
            }
            if event.modifierFlags.contains(.option) {
                let grows = event.keyCode == 124 || event.keyCode == 126
                let succeeded = selectedSemanticObjectID != nil
                    ? onResizeSemanticObject(grows ? 1.1 : 0.9) : onResizeSelectedImage(grows ? 1.1 : 0.9)
                if !succeeded {
                    super.keyDown(with: event)
                }
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
            let succeeded = selectedSemanticObjectID != nil ? onNudgeSemanticObject(delta) : onNudgeSelectedImage(delta)
            if !succeeded {
                super.keyDown(with: event)
            }
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
        // Keep suppression of an incidental sequence that began during the
        // pointer interaction; its tail is still foreign after cancellation and
        // is released by that sequence's terminal event or a new sequence.
        resetViewportGestureRouting(
            suppressScroll: interruptedScroll || suppressesScrollSequence,
            suppressMagnification: interruptedMagnification || suppressesMagnification
        )
        window?.invalidateCursorRects(for: self)
    }

    func activateRepresentation() {
        isRepresentationActive = true
        gestureRecognizers.forEach { $0.isEnabled = true }
    }

    /// Discards unfinished input for a transient interruption while keeping
    /// this representation, its caches, and in-flight imports alive.
    func interruptTransientInteraction() {
        guard isRepresentationActive else { return }
        if !finishSemanticTextEditing(commit: true) { suspendSemanticTextEditing() }
        cancelInteraction()
    }

    /// File-promise deliveries are owned by this view and end with it.
    /// Session-owned image imports are cancelled only by explicit user
    /// cancellation or the session's lifecycle cancellation, so replacing
    /// the view (for example, on a section change) cannot abort them.
    func deactivateRepresentation() {
        prepareForDeferredDeactivation()?()
    }

    @discardableResult
    func prepareForDeferredDeactivation() -> (@MainActor () -> Void)? {
        guard isRepresentationActive else { return nil }
        let sessionLifetime = representedSessionLifetime
        representedSessionLifetime = nil
        let semanticCompletion: (@MainActor () -> Void)?
        if let editor = semanticTextEditor,
           let baseline = editingSemanticBaseline,
           !editor.isFinishing {
            let draft = CanvasSemanticTextDraft(
                baseline: baseline,
                text: editor.string,
                isInsertion: editingSemanticIsInsertion
            )
            let retainedDraft = editor.string == baseline.content?.text ? nil : draft
            let preserveDraft = onPreserveSemanticDraft
            let commitDraft = onCommitSemanticText
            semanticCompletion = { [sessionLifetime] in
                withExtendedLifetime(sessionLifetime) {
                    preserveDraft(draft.key, retainedDraft)
                    if commitDraft(draft) {
                        preserveDraft(draft.key, nil)
                    } else {
                        preserveDraft(draft.key, retainedDraft)
                    }
                }
            }
            editor.isFinishing = true
            semanticTextEditor = nil
            editingSemanticObjectID = nil
            editingSemanticBaseline = nil
            editingSemanticIsInsertion = false
            editor.removeFromSuperview()
            needsDisplay = true
        } else {
            semanticCompletion = nil
        }
        isRepresentationActive = false
        interactionInterruptionObservation = nil
        gestureRecognizers.forEach { $0.isEnabled = false }
        cancelInteraction()
        cancelFilePromiseBatches()
        onViewportChange = { _ in }
        return { semanticCompletion?() }
    }

}
#endif
