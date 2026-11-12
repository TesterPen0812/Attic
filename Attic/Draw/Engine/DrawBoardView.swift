import AppKit
import Combine
import QuartzCore

/// The Draw board (restart plan §2): live ink draws incrementally on its own
/// layers; committed content is a world-space raster from the background
/// renderer. Its pixels cover the drawing, independent of pan and zoom, so
/// input can transform it without waiting for another raster. Live ink stays
/// until a raster that includes it is installed.
///
/// The view is unflipped; the page model's screen points are y down, so
/// every conversion flips once here.
@MainActor
final class DrawBoardView: NSView, DrawBoardSink, AtticHorizontalScrollOwner {
    #if DEBUG
    static private(set) var activeNotificationRegistrationsForTesting = 0
    #endif
    let model: DrawPageModel

    private let dotsLayer = CALayer()
    private let committedLayer = CALayer()
    /// A screen-resolution raster replaces the world backing while the
    /// viewport is resting. Pan/zoom restores the complete world backing.
    private let detailLayer = CALayer()
    /// Live overlays in world points: ink, the shape being dragged out.
    private let worldLayer = CALayer()
    private let selectionLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()
    private var liveInk: DrawLiveInk?
    private var liveShape: CAShapeLayer?
    private var liveStartRevision = 0
    private var liveStartCanvasID: UUID?
    /// Committed overlays waiting for a raster that includes their revision.
    private(set) var pendingOverlays: [(revision: Int, layer: CALayer)] = []
    private var requestedKey: DrawRasterKey?
    private(set) var installedKey: DrawRasterKey?
    private var detailRequestedKey: DrawRasterKey?
    private var detailInstalledKey: DrawRasterKey?
    private var detailSettle: DispatchWorkItem?
    private var needsRaster = true
    private var dots = DrawDots()
    private(set) var editor: DrawTextEditorView?
    private var appliedEditorPresentation: (zoom: CGFloat, dark: Bool)?
    /// Whether the scroll gesture under way began over the board's clear
    /// area (it pans and zooms) or over the top row or bar (it doesn't).
    private var scrollGestureIsOwn = true
    private var cursorArea: NSTrackingArea?
    private var cursorRefreshQueued = false
    /// The board set the cursor last (so leaving it restores the normal one).
    private var showsBoardCursor = false
    private var modelChanges: AnyCancellable?
    private var stateObservers: [NSObjectProtocol] = []
    private var objectAccessibility: [UUID: DrawAccessibilityObjectElement] = [:]
    private var accessibilityRevision = -1
    private var accessibilityNotificationQueued = false

    #if DEBUG
    /// Test seam: the pointer's window location in place of the real one.
    var pointerOverride: CGPoint?
    /// Test seam: scroll events this board was given, and the ones it used.
    private(set) var scrollEventsReceived = 0
    private(set) var scrollEventsUsed = 0
    /// Test seam: the board's last cursor decisions.
    private(set) var cursorLog: [String] = []
    #endif

    /// Screen points, independent of the canvas transform and stroke size.
    /// The 2 Nov brief supersedes the drawing's stroke-sized pen cursor.
    static let cursorRing: CGFloat = 0.6
    static let penDotDiameter: CGFloat = 6
    /// The eraser's 24 px ring, halved: 12 pt, its 10 pt circle the
    /// eraser's own reach (5 pt either side of the pointer).
    static let eraserCursorSize: CGFloat = 12

    #if DEBUG
    /// Test seam: rasters requested and installed by this board.
    private(set) var rasterRequests = 0
    private(set) var rasterInstalls = 0
    private(set) var detailInstalls = 0
    #endif

    private lazy var renderer = DrawLatestRenderer<DrawRasterRequest, DrawRasterImage>(
        work: { request, stale in DrawRaster.render(request, cancelled: stale) },
        install: { [weak self] request, image in self?.install(request, image) }
    )

    private lazy var detailRenderer = DrawLatestRenderer<DrawRasterRequest, DrawRasterImage>(
        work: { request, stale in DrawRaster.render(request, cancelled: stale) },
        install: { [weak self] request, image in self?.installDetail(request, image) }
    )

    init(model: DrawPageModel) {
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: model.boardSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // The committed raster and the live overlays span the whole drawing,
        // well past the board. A page switch carries the board a panel width
        // aside while it stays opaque, so unclipped they were drawn over the
        // page coming in (owner, 12 Nov). Nothing belongs outside the board.
        clipsToBounds = true
        for sublayer in [dotsLayer, committedLayer, detailLayer, worldLayer] {
            sublayer.anchorPoint = .zero
            sublayer.position = .zero
            sublayer.actions = Self.noActions
            layer?.addSublayer(sublayer)
        }
        for shapeLayer in [selectionLayer, handlesLayer, marqueeLayer] {
            shapeLayer.actions = Self.noActions
            shapeLayer.fillColor = nil
            layer?.addSublayer(shapeLayer)
        }
        let blue = NSColor.systemBlue.cgColor
        selectionLayer.strokeColor = blue
        selectionLayer.lineWidth = 1
        handlesLayer.strokeColor = blue
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.lineWidth = 1
        marqueeLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
        marqueeLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
        marqueeLayer.lineWidth = 0.75
        model.board = self
        // Pinch is the board's own recognizer's: AppKit gives a view's
        // recognizers the events hit-tested to it before any responder,
        // and holds the magnify events back while it recognizes, so no
        // ancestor or responder-chain route decides whether a pinch zooms
        // (the old Canvas met the same in this panel, bc2d7991).
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delaysMagnificationEvents = true
        addGestureRecognizer(pinch)
        // Anything the page changes (tool, size, colour, a strip, the menu,
        // the selection) may change the cursor under a resting pointer.
        modelChanges = model.objectWillChange.sink { [weak self] _ in self?.queueCursorRefresh() }
        registerForDraggedTypes(DrawPageModel.imagePasteboardTypes + [.fileURL])
        layoutLayers()
    }

    required init?(coder: NSCoder) { fatalError("Not archived") }

    static let noActions: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                                                "contents": NSNull(), "path": NSNull(), "hidden": NSNull(),
                                                "backgroundColor": NSNull(), "sublayers": NSNull(), "frame": NSNull()]

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    // MARK: Geometry

    /// Board points (y down) for a view point.
    func boardPoint(_ viewPoint: CGPoint) -> CGPoint { CGPoint(x: viewPoint.x, y: bounds.height - viewPoint.y) }
    func boardPoint(_ event: NSEvent) -> CGPoint { boardPoint(convert(event.locationInWindow, from: nil)) }
    private func viewRect(_ boardRect: CGRect) -> CGRect {
        CGRect(x: boardRect.minX, y: bounds.height - boardRect.maxY, width: boardRect.width, height: boardRect.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        model.setBoard(size: newSize, clearInsets: model.clearInsets)
        invalidateDetail()
        layoutLayers()
        requestRaster()
        scheduleDetail()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        requestRaster()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshEditorAppearance()
        layoutLayers()
        requestRaster()
    }

    private func refreshEditorAppearance() {
        guard let editor, let edit = model.editing else { return }
        let zoom = model.viewport.zoom
        let dark = isDark
        if let applied = appliedEditorPresentation, applied.zoom == zoom, applied.dark == dark { return }
        editor.apply(edit, zoom: zoom, palette: DrawPalette(dark: dark), replacingText: false)
        appliedEditorPresentation = (zoom, dark)
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let viewport = model.viewport
        let height = bounds.height
        // World to view: y flips once, then the viewport.
        worldLayer.setAffineTransform(CGAffineTransform(a: viewport.zoom, b: 0, c: 0, d: -viewport.zoom,
                                                        tx: viewport.x, ty: height - viewport.y))
        if let installed = installedKey {
            // The installed raster, carried to the current viewport until the
            // next one arrives (a pan or zoom never waits for it).
            placeRaster(committedLayer, key: installed, viewport: viewport, height: height)
        }
        if let installed = detailInstalledKey {
            placeRaster(detailLayer, key: installed, viewport: viewport, height: height)
        }
        dots.place(in: dotsLayer, viewport: viewport, size: bounds.size, dark: isDark)
        updateSelection()
        updateEditorFrame()
        CATransaction.commit()
    }

    private func placeRaster(_ layer: CALayer, key: DrawRasterKey, viewport: DrawViewport, height: CGFloat) {
        let s = viewport.zoom / key.viewport.zoom
        layer.bounds = CGRect(origin: .zero, size: key.size)
        layer.setAffineTransform(CGAffineTransform(
            a: s, b: 0, c: 0, d: s,
            tx: viewport.x - s * key.viewport.x,
            ty: height - s * key.size.height + s * key.viewport.y - viewport.y))
    }

    // MARK: Rasters

    /// The backing image covers every committed object, including geometry
    /// being moved or replaced. A raster clipped to the current viewport
    /// cannot reveal pixels that scroll into view during a continuous pinch.
    private func rasterCoverage() -> CGRect {
        var coverage = DrawGeometry.union(model.objects) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        if let move = model.rasterMove {
            for object in model.objects where move.ids.contains(object.id) {
                coverage = coverage.union(DrawGeometry.bounds(object.translated(
                    by: DrawPoint(x: move.offset.x, y: move.offset.y), id: object.id)))
            }
        }
        for object in model.rasterReplacements.values {
            coverage = coverage.union(DrawGeometry.bounds(object))
        }
        // Includes stroke caps, image rounded corners and antialiasing.
        coverage = coverage.insetBy(dx: -12, dy: -12)
        return CGRect(x: floor(coverage.minX), y: floor(coverage.minY),
                      width: ceil(coverage.maxX) - floor(coverage.minX),
                      height: ceil(coverage.maxY) - floor(coverage.minY))
    }

    private func currentKey() -> DrawRasterKey {
        let move = model.rasterMove
        let coverage = rasterCoverage()
        // A large or sparse canvas must never allocate an unbounded bitmap.
        // Keep its complete extent, reducing the backing density if needed.
        let maxPixels: CGFloat = 12_000_000
        let density = min(scale, 8192 / max(coverage.width, coverage.height),
                          sqrt(maxPixels / (coverage.width * coverage.height)))
        let rasterViewport = DrawViewport(x: -coverage.minX, y: -coverage.minY)
        return DrawRasterKey(revision: model.contentRevision, viewport: rasterViewport,
                             size: coverage.size, scale: density,
                             dark: isDark, hidden: model.rasterHidden, moved: move?.ids ?? [], offset: move?.offset ?? .zero,
                             replaced: model.rasterReplacements.mapValues(\.frame))
    }

    /// Queues the committed raster for the current state; the board does
    /// nothing while hidden.
    func requestRaster() {
        guard model.isShown, bounds.width > 0, bounds.height > 0 else { needsRaster = true; return }
        let key = currentKey()
        guard key != requestedKey || needsRaster else { return }
        needsRaster = false
        requestedKey = key
        invalidateDetail()
        scheduleDetail()
        #if DEBUG
        rasterRequests += 1
        #endif
        renderer.request(DrawRasterRequest(key: key, objects: model.objects, replacements: model.rasterReplacements))
    }

    private func detailKey() -> DrawRasterKey {
        let move = model.rasterMove
        return DrawRasterKey(revision: model.contentRevision, viewport: model.viewport, size: bounds.size, scale: scale,
                             dark: isDark, hidden: model.rasterHidden, moved: move?.ids ?? [], offset: move?.offset ?? .zero,
                             replaced: model.rasterReplacements.mapValues(\.frame))
    }

    /// Stop displaying a viewport-clipped image as soon as any movement
    /// begins. The world raster underneath has all pixels to move into view.
    private func invalidateDetail() {
        detailSettle?.cancel()
        detailSettle = nil
        detailRenderer.cancel()
        detailRequestedKey = nil
        detailInstalledKey = nil
        detailLayer.isHidden = true
        committedLayer.isHidden = false
    }

    private func scheduleDetail() {
        guard model.isShown else { return }
        // At normal size the world bitmap already supplies one device pixel
        // per pixel. Detail is only useful when it would be visibly sharper.
        let worldDensity = requestedKey?.scale ?? installedKey?.scale ?? 0
        guard worldDensity < scale * model.viewport.zoom * 0.99 else { return }
        detailSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestDetail() }
        detailSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    private func requestDetail() {
        guard model.isShown, bounds.width > 0, bounds.height > 0 else { return }
        let key = detailKey()
        detailRequestedKey = key
        detailRenderer.request(DrawRasterRequest(key: key, objects: model.objects,
                                                replacements: model.rasterReplacements))
    }

    private func installDetail(_ request: DrawRasterRequest, _ result: DrawRasterImage) {
        guard model.isShown, request.key == detailRequestedKey, request.key == detailKey() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detailLayer.contents = result.image
        detailLayer.contentsScale = request.key.scale
        detailInstalledKey = request.key
        layoutLayers()
        detailLayer.isHidden = false
        committedLayer.isHidden = true
        CATransaction.commit()
        #if DEBUG
        rasterInstalls += 1
        detailInstalls += 1
        #endif
    }

    private func install(_ request: DrawRasterRequest, _ result: DrawRasterImage) {
        guard request.key == requestedKey, model.isShown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        committedLayer.contents = result.image
        committedLayer.contentsScale = request.key.scale
        committedLayer.setAffineTransform(.identity)
        installedKey = request.key
        pendingOverlays.removeAll { overlay in
            guard overlay.revision <= request.key.revision else { return false }
            overlay.layer.removeFromSuperlayer()
            return true
        }
        layoutLayers()
        CATransaction.commit()
        #if DEBUG
        rasterInstalls += 1
        #endif
    }

    // MARK: DrawBoardSink

    func drawContentChanged() {
        queueObjectAccessibilityUpdate()
        updateSelection()
        requestRaster()
    }

    func drawViewportChanged() {
        refreshEditorAppearance()
        invalidateDetail()
        layoutLayers()
        scheduleDetail()
        queueCursorRefresh()
    }

    func drawSelectionChanged() { updateSelection(); queueObjectAccessibilityUpdate() }

    func drawVisibilityChanged() {
        if model.isShown {
            // Hiding cancels in-flight rendering, but leaves the last complete
            // world backing installed. Keep using it when nothing changed;
            // returning to a 2,000-object board needn't raster every object.
            if let installedKey, installedKey == currentKey() {
                needsRaster = false
                requestedKey = installedKey
                scheduleDetail()
            } else {
                needsRaster = true
                requestRaster()
            }
        } else {
            renderer.cancel()
            requestedKey = nil
            invalidateDetail()
            releaseCursor()
        }
        if model.isShown { queueInitialKeyboardFocus() }
        queueCursorRefresh()
    }

    func drawReturnKeyboard() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.isShown, !self.isHiddenOrHasHiddenAncestor,
                  !self.model.isSearching, !self.model.isFiltering, !self.model.library.isRenaming,
                  self.model.editing == nil, let window = self.window else { return }
            if let text = window.firstResponder as? NSTextView {
                let field = text.delegate as? NSTextField
                guard ["draw-title-filter", "draw-library-search"].contains(field?.accessibilityIdentifier() ?? "") else { return }
            }
            window.makeFirstResponder(self)
        }
    }

    private func queueInitialKeyboardFocus() {
        // The shell clears the previous page's responder when switching.
        // Claim this window's responder after the new page is installed;
        // this never makes the window key or activates the application.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.isShown, !self.isHiddenOrHasHiddenAncestor,
                  !self.model.isSearching, !self.model.isFiltering, self.model.editing == nil,
                  let window = self.window, !(window.firstResponder is NSTextView) else { return }
            window.makeFirstResponder(self)
        }
    }

    func drawLiveChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        marqueeLayer.path = nil
        switch model.live {
        case .ink(let trace):
            if liveInk == nil || (trace.hasPressure && liveInk?.usesPressure == false) {
                liveInk?.container.removeFromSuperlayer()
                liveStartRevision = model.contentRevision
                liveStartCanvasID = model.canvasID
                let ink = DrawLiveInk(colour: DrawPalette(dark: isDark).cgColor(model.colour),
                                      width: CGFloat(model.strokeSize.strokeWidth), usesPressure: trace.hasPressure)
                worldLayer.addSublayer(ink.container)
                liveInk = ink
            }
            liveInk?.update(trace)
        case .shape(let kind, let start, let end):
            if liveShape == nil {
                liveStartRevision = model.contentRevision
                liveStartCanvasID = model.canvasID
                let shapeLayer = CAShapeLayer()
                shapeLayer.actions = Self.noActions
                shapeLayer.fillColor = nil
                shapeLayer.lineCap = .round
                shapeLayer.lineJoin = .round
                shapeLayer.strokeColor = DrawPalette(dark: isDark).cgColor(model.colour)
                shapeLayer.lineWidth = CGFloat(model.strokeSize.strokeWidth)
                worldLayer.addSublayer(shapeLayer)
                liveShape = shapeLayer
            }
            let frame = kind == .line || kind == .arrow ? DrawGeometry.lineFrame(from: start, to: end)
                : DrawGeometry.boxFrame(from: start, to: end)
            liveShape?.path = DrawGeometry.shapePath(kind, frame: frame, corners: .square,
                                                    width: CGFloat(model.strokeSize.strokeWidth))
        case .marquee(let from, let to, _):
            let rect = model.viewport.screen(CGRect(x: from.x, y: from.y, width: to.x - from.x, height: to.y - from.y).standardized)
            marqueeLayer.path = CGPath(roundedRect: viewRect(rect), cornerWidth: 4, cornerHeight: 4, transform: nil)
        case .move, .resize:
            updateSelection()
        case .erase, .pan:
            break
        case nil:
            // Finished: a committed stroke or shape stays drawn live until
            // the raster with its revision is installed.
            let committed = liveStartCanvasID == model.canvasID && model.contentRevision > liveStartRevision
            for finished in [liveInk?.container, liveShape].compactMap({ $0 }) {
                if committed { pendingOverlays.append((model.contentRevision, finished)) } else { finished.removeFromSuperlayer() }
            }
            liveInk = nil
            liveShape = nil
            liveStartCanvasID = nil
            updateSelection()
        }
    }

    // MARK: Selection outline

    /// The blue outline with handles (screen points, never scaled).
    private func updateSelection() {
        let chosen = model.displayedSelection
        let outline = CGMutablePath(), handles = CGMutablePath()
        guard !chosen.isEmpty, model.editing == nil else {
            if handlesLayer.path != nil { queueCursorRefresh() }
            selectionLayer.path = nil
            handlesLayer.path = nil
            return
        }
        let offset = model.rasterMove?.offset ?? .zero
        let viewport = model.viewport
        let gap: CGFloat = 4
        func handle(_ point: CGPoint) {
            handles.addPath(CGPath(roundedRect: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6),
                                   cornerWidth: 2, cornerHeight: 2, transform: nil))
        }
        for object in chosen {
            if chosen.count == 1, case .shape(let kind) = object.content, kind == .line || kind == .arrow { continue }
            let bounds = DrawGeometry.bounds(object).offsetBy(dx: offset.x, dy: offset.y)
            let rect = viewRect(viewport.screen(bounds).insetBy(dx: -gap, dy: -gap))
            outline.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        }
        // One object's handles, or the corners around several (they scale
        // as a group).
        for spot in model.handleSpots { handle(boardToView(spot.point)) }
        if model.live == nil { queueCursorRefresh() }
        selectionLayer.path = outline
        handlesLayer.path = handles
    }

    private func boardToView(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: bounds.height - point.y) }

    // MARK: Text box

    func drawEditingChanged(replacingText: Bool) {
        guard let edit = model.editing else {
            if let editor {
                let wasEditingFirstResponder = window?.firstResponder === editor
                editor.owner = nil
                editor.removeFromSuperview()
                self.editor = nil
                appliedEditorPresentation = nil
                if wasEditingFirstResponder { window?.makeFirstResponder(self) }
            }
            updateSelection()
            return
        }
        let editor = self.editor ?? makeEditor()
        editor.apply(edit, zoom: model.viewport.zoom, palette: DrawPalette(dark: isDark), replacingText: replacingText)
        appliedEditorPresentation = (model.viewport.zoom, isDark)
        updateEditorFrame()
        if window?.firstResponder !== editor { window?.makeFirstResponder(editor) }
        updateSelection()
    }

    private func makeEditor() -> DrawTextEditorView {
        let editor = DrawTextEditorView(frame: .zero)
        editor.owner = self
        addSubview(editor)
        self.editor = editor
        return editor
    }

    private func updateEditorFrame() {
        guard let editor, let edit = model.editing else { return }
        let viewport = model.viewport
        let fontSize = edit.pointSize
        let size = DrawText.size(of: edit.text, fontSize: CGFloat(edit.style.size.textSize), width: edit.width, scale: edit.scale)
        let origin = viewport.screen(edit.origin)
        let frame = CGRect(x: origin.x, y: origin.y, width: (size.width + (edit.width == nil ? fontSize : 0)) * viewport.zoom,
                           height: max(size.height, fontSize * DrawText.lineHeight) * viewport.zoom)
        editor.frame = viewRect(frame)
    }

    func editorTextChanged(_ text: String) {
        model.typed(text)
        updateEditorFrame()
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        if model.editing == nil { window?.makeFirstResponder(self) }
        let point = boardPoint(event)
        if event.clickCount == 2, model.tool == .select, model.live == nil {
            model.doubleClick(at: point)
            return
        }
        model.pointerDown(at: point, shift: event.modifierFlags.contains(.shift), pressure: penPressure(event))
    }

    override func mouseDragged(with event: NSEvent) {
        model.pointerDragged(to: boardPoint(event), shift: event.modifierFlags.contains(.shift), pressure: penPressure(event), panButton: false)
    }

    override func mouseUp(with event: NSEvent) {
        model.pointerUp(at: boardPoint(event), shift: event.modifierFlags.contains(.shift), pressure: penPressure(event), panButton: false)
    }

    /// Tablet-point samples may arrive separately from mouse drags; include
    /// their pressure and coordinates only while a pen gesture is active.
    override func tabletPoint(with event: NSEvent) {
        guard case .ink = model.live, let pressure = penPressure(event) else { return }
        model.pointerDragged(to: boardPoint(event), pressure: pressure)
    }

    /// Trackpads and ordinary mice can report force, but pen pressure is
    /// meaningful only on tablet-point events. Keep their strokes constant.
    private func penPressure(_ event: NSEvent) -> CGFloat? {
        guard (event.type == .tabletPoint || event.subtype == .tabletPoint), event.pressure.isFinite else { return nil }
        let pressure = CGFloat(event.pressure)
        return Swift.min(CGFloat(1), Swift.max(CGFloat(0), pressure))
    }

    override func otherMouseDown(with event: NSEvent) { model.pointerDown(at: boardPoint(event), panButton: true) }
    override func otherMouseDragged(with event: NSEvent) { model.pointerDragged(to: boardPoint(event), panButton: true) }
    override func otherMouseUp(with event: NSEvent) { model.pointerUp(at: boardPoint(event), panButton: true) }

    /// A scroll gesture is the board's when it begins over the clear area
    /// (a gesture belongs to what is under the pointer when it begins). Over
    /// the top row and the bar's empty space it has no job here, so it is
    /// swipe-to-close's (`AtticHorizontalScrollOwner`), and nothing pans.
    var ownsHorizontalScrolling: Bool { model.isShown }

    func ownsHorizontalScroll(beginningAt windowPoint: CGPoint) -> Bool {
        model.isShown && model.clearRect.contains(boardPoint(convert(windowPoint, from: nil)))
    }

    /// Line deltas (a mouse wheel's notches) in points, as AppKit's own
    /// scroll views move them.
    static let lineScroll: CGFloat = 8

    override func scrollWheel(with event: NSEvent) {
        #if DEBUG
        scrollEventsReceived += 1
        #endif
        let point = boardPoint(event)
        // A new gesture (or a wheel's lone event) decides ownership; its
        // later samples and momentum keep the answer.
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            scrollGestureIsOwn = model.clearRect.contains(point)
        }
        guard scrollGestureIsOwn else { return super.scrollWheel(with: event) }
        let command = event.modifierFlags.contains(.command)
        // A physical pinch can send stray two-finger scrolls; the pinch wins.
        if !command, isPinching { return }
        let scale = event.hasPreciseScrollingDeltas ? 1 : Self.lineScroll
        #if DEBUG
        scrollEventsUsed += 1
        #endif
        model.scroll(dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale, command: command, at: point)
        refreshCursor()
    }

    private var isPinching: Bool {
        gestureRecognizers.contains { $0 is NSMagnificationGestureRecognizer && ($0.state == .began || $0.state == .changed) }
    }

    @objc private func pinched(_ recognizer: NSMagnificationGestureRecognizer) {
        let amount = recognizer.magnification
        // The recognizer reports the total so far; take each change once.
        recognizer.magnification = 0
        guard amount.isFinite, amount != 0 else { return }
        let location = recognizer.location(in: self)
        model.magnify(by: amount, at: boardPoint(location))
        refreshCursor()
    }

    /// Reached only when the recognizer passes a magnify on (it fails).
    override func magnify(with event: NSEvent) {
        model.magnify(by: event.magnification, at: boardPoint(event))
        refreshCursor()
    }

    // MARK: Keys

    static func key(_ event: NSEvent) -> DrawKey {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return DrawKey(characters: event.charactersIgnoringModifiers?.lowercased() ?? "", keyCode: event.keyCode,
                       command: flags.contains(.command), shift: flags.contains(.shift),
                       option: flags.contains(.option), control: flags.contains(.control))
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            model.spaceHeld = true
            return
        }
        let key = Self.key(event)
        if key.keyCode == 48, !key.command, !key.option, !key.control, model.editing == nil, model.live == nil {
            if !model.handleKey(key) {
                if key.shift { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
            }
            return
        }
        if !model.handleKey(key) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { model.spaceHeld = false; return }
        super.keyUp(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let window, window.firstResponder === self, model.isShown, !isHiddenOrHasHiddenAncestor else {
            return super.performKeyEquivalent(with: event)
        }
        let key = Self.key(event)
        guard key.command, model.handleKey(key) else { return super.performKeyEquivalent(with: event) }
        return true
    }

    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc override func selectAll(_ sender: Any?) { model.selectAll() }
    @objc func copy(_ sender: Any?) { model.copySelection() }
    @objc func cut(_ sender: Any?) { model.cutSelection() }
    @objc func paste(_ sender: Any?) { model.paste() }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }

    // MARK: Cursor and accessibility

    /// A drop of images (files or data) at a board point: starts the import.
    func acceptDrop(from pasteboard: NSPasteboard, at point: CGPoint) -> Bool {
        model.importImages(from: pasteboard, at: point) != nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        DrawPageModel.holdsImages(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        DrawPageModel.holdsImages(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptDrop(from: sender.draggingPasteboard, at: boardPoint(convert(sender.draggingLocation, from: nil)))
    }

    /// The resize cursor for a handle (Draw 3), one instance per kind.
    static func cursor(for handle: DrawHandle) -> NSCursor {
        if let cursor = handleCursors[handle] { return cursor }
        let cursor = makeCursor(for: handle)
        handleCursors[handle] = cursor
        return cursor
    }

    private static var handleCursors: [DrawHandle: NSCursor] = [:]

    private static func makeCursor(for handle: DrawHandle) -> NSCursor {
        switch handle {
        case .topLeft: .frameResize(position: .topLeft, directions: .all)
        case .topRight: .frameResize(position: .topRight, directions: .all)
        case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
        case .left, .right: .columnResize
        case .start, .end: .crosshair
        }
    }

    // The cursor (brief "Draw input"): the board sets it itself, from a
    // tracking area that is active whether or not the panel is key or
    // Attic is active. Cursor rects (and `.cursorUpdate` tracking) only
    // work in the key window, and the panel is a non-activating panel that
    // becomes key only on a press, so they left the system's cursor in place
    // after a reveal, a hover, or a menu or popover closing; and they were
    // rebuilt only when SwiftUI happened to update the representable.
    // The board's cursor shows only where the board is what the pointer is
    // over (not under the tool bar, the top row or the selection bar), and
    // handles win over their reach.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorArea { removeTrackingArea(cursorArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorArea = area
    }

    override func viewDidMoveToWindow() {
        releaseCursor()
        super.viewDidMoveToWindow()
        for observer in stateObservers { NotificationCenter.default.removeObserver(observer) }
        #if DEBUG
        Self.activeNotificationRegistrationsForTesting -= stateObservers.count
        #endif
        stateObservers = []
        guard let window else { return }
        if model.isShown { queueInitialKeyboardFocus() }
        let names: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didBecomeKeyNotification, window), (NSWindow.didResignKeyNotification, window),
            (NSApplication.didBecomeActiveNotification, nil), (NSApplication.didResignActiveNotification, nil),
            (AtticBackgroundInput.didRestorePolicyNotification, window),
            (AtticPanel.willOrderOutNotification, window), (NSWindow.willCloseNotification, window),
        ]
        for (name, object) in names {
            stateObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == AtticPanel.willOrderOutNotification || name == NSWindow.willCloseNotification {
                        self?.releaseCursor()
                    } else { self?.queueCursorRefresh() }
                }
            })
        }
        #if DEBUG
        Self.activeNotificationRegistrationsForTesting += stateObservers.count
        #endif
        queueCursorRefresh()
    }

    override func mouseEntered(with event: NSEvent) { applyCursor(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { applyCursor(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { releaseCursor() }
    override func cursorUpdate(with event: NSEvent) { applyCursor(at: event.locationInWindow) }

    /// Sets the cursor for the pointer where it rests, on the next turn of
    /// the main loop (after the change that asked has laid out).
    ///
    /// The pointer's owner is found by hit testing, so the refresh waits for
    /// SwiftUI to apply the change that asked (a menu or strip closing
    /// takes its card away in the same turn's update): one hop on the main
    /// queue lands before that update, the second after it.
    func queueCursorRefresh() {
        guard !cursorRefreshQueued else { return }
        cursorRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.cursorRefreshQueued = false
                    self?.refreshCursor()
                }
            }
        }
    }

    /// A menu, strip or popover that is closing still covers the board
    /// until its fade ends (SwiftUI removes it, and its AppKit container,
    /// after the motion): one more look once the app's overlay motions are
    /// over. Bounded: one retry per change.
    static let overlaySettle: TimeInterval = 0.45
    private var settleRetryPending = false

    func refreshCursor() {
        guard let window else { return }
        var point = window.mouseLocationOutsideOfEventStream
        #if DEBUG
        if let pointerOverride { point = pointerOverride }
        #endif
        applyCursor(at: point)
        if cursor(atWindowPoint: point) == nil, model.isShown, !settleRetryPending,
           bounds.contains(convert(point, from: nil)) {
            settleRetryPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlaySettle) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.settleRetryPending = false
                    guard let window = self.window else { return }
                    var point = window.mouseLocationOutsideOfEventStream
                    #if DEBUG
                    if let pointerOverride = self.pointerOverride { point = pointerOverride }
                    #endif
                    self.applyCursor(at: point)
                }
            }
        }
    }

    private func applyCursor(at windowPoint: CGPoint) {
        #if DEBUG
        let hit = window?.contentView.flatMap { content in
            content.hitTest(content.superview.map { $0.convert(windowPoint, from: nil) } ?? windowPoint)
        }
        cursorLog.append("\(windowPoint) \(model.tool) \(model.colour) shown=\(model.isShown) hit=\(hit.map { "\(type(of: $0))" } ?? "nil") had=\(showsBoardCursor)")
        if cursorLog.count > 8 { cursorLog.removeFirst() }
        #endif
        if let cursor = cursor(atWindowPoint: windowPoint) {
            showsBoardCursor = true
            cursor.set()
        } else if showsBoardCursor {
            // Off the board: the normal cursor, then whatever the panel's
            // own cursor rects (the drag region, the edges) say.
            releaseCursor()
            window?.resetCursorRects()
        }
    }

    private func releaseCursor() {
        guard showsBoardCursor else { return }
        showsBoardCursor = false
        NSCursor.arrow.set()
    }

    /// The board's cursor at a window point, or nil where the board isn't
    /// what the pointer is over.
    func cursor(atWindowPoint windowPoint: CGPoint) -> NSCursor? {
        guard model.isShown, let window, window.isVisible, !isHiddenOrHasHiddenAncestor,
              let content = window.contentView,
              content.hitTest(content.superview.map { $0.convert(windowPoint, from: nil) } ?? windowPoint) === self
        else { return nil }
        let point = boardPoint(convert(windowPoint, from: nil))
        let reach = DrawPageModel.handleHitRadius
        if model.live == nil,
           let spot = model.handleSpots.first(where: { abs($0.point.x - point.x) <= reach && abs($0.point.y - point.y) <= reach }) {
            return Self.cursor(for: spot.handle)
        }
        return toolCursor
    }

    private var toolCursor: NSCursor {
        switch model.tool {
        case .select: .arrow
        case .text: .iBeam
        case .shape: .crosshair
        case .pen:
            Self.penCursor(colour: DrawPalette(dark: isDark).cgColor(model.colour))
        case .eraser: Self.eraserCursor
        }
    }

    // CGColor equality includes its colour space, including unnamed spaces.
    private static var penCursors: [(colour: CGColor, cursor: NSCursor)] = []

    /// The pen's dot: the pen colour, a white ring, the hot spot at its centre.
    static func penCursor(colour: CGColor) -> NSCursor {
        let d = penDotDiameter
        if let cached = penCursors.first(where: { $0.colour == colour }) { return cached.cursor }
        let side: CGFloat = 8
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            let outer = d + cursorRing * 2
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: (side - outer) / 2, y: (side - outer) / 2, width: outer, height: outer)).fill()
            (NSColor(cgColor: colour) ?? .labelColor).setFill()
            NSBezierPath(ovalIn: CGRect(x: (side - d) / 2, y: (side - d) / 2, width: d, height: d)).fill()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: CGPoint(x: side / 2, y: side / 2))
        if penCursors.count > 64 { penCursors.removeAll() }
        penCursors.append((colour, cursor))
        return cursor
    }

    /// The eraser's ring: a faint white fill and a dark outline, centred.
    static let eraserCursor: NSCursor = {
        let side = eraserCursorSize
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            let ring = NSBezierPath(ovalIn: CGRect(x: 1, y: 1, width: side - 2, height: side - 2))
            NSColor(white: 1, alpha: 0.5).setFill()
            ring.fill()
            NSColor(srgbRed: 60 / 255, green: 62 / 255, blue: 66 / 255, alpha: 1).setStroke()
            ring.lineWidth = 0.65
            ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: side / 2, y: side / 2))
    }()

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { String(localized: "Drawing board") }
    override func accessibilityValue() -> Any? {
        let percent = Int((model.viewport.zoom * 100).rounded())
        return String(localized: "\(model.objects.count) objects, \(model.selection.count) selected, \(percent) % zoom")
    }

    private func prepareObjectAccessibility() {
        guard accessibilityRevision != model.contentRevision else { return }
        IdleLatencyTrace.span("draw_accessibility_refresh") {
            let navigationIDs = model.objectNavigationIDs
            // model.object(id) scans the array. Doing so once for every
            // VoiceOver child makes each edit's accessibility refresh O(n²).
            let objectsByID = Dictionary(model.objects.map { ($0.id, $0) },
                                         uniquingKeysWith: { first, _ in first })
            let ids = Set(navigationIDs)
            objectAccessibility = objectAccessibility.filter { ids.contains($0.key) }
            for (index, id) in navigationIDs.enumerated() {
                guard let object = objectsByID[id] else { continue }
                let element = objectAccessibility[id] ?? DrawAccessibilityObjectElement(board: self, id: id)
                element.update(object, number: index + 1)
                objectAccessibility[id] = element
            }
            accessibilityRevision = model.contentRevision
        }
    }

    private func queueObjectAccessibilityUpdate() {
        // A board never queried by an accessibility client pays no tree cost.
        guard accessibilityRevision >= 0, !accessibilityNotificationQueued else { return }
        accessibilityNotificationQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.accessibilityNotificationQueued = false
            self.prepareObjectAccessibility()
            NSAccessibility.post(element: self, notification: .layoutChanged)
            if self.window?.firstResponder === self, self.model.selection.count == 1,
               let element = self.objectAccessibility[self.model.selection[0]] {
                NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
            }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        prepareObjectAccessibility()
        var children: [Any] = model.objectNavigationIDs.compactMap { objectAccessibility[$0] }
        if let editor { children.append(editor) }
        return children
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        prepareObjectAccessibility()
        return model.objectNavigationIDs.filter { model.selection.contains($0) }.compactMap { objectAccessibility[$0] }
    }

    fileprivate func focusAccessibleObject(_ id: UUID) -> Bool {
        guard let canvasID = model.canvasID, model.object(id) != nil, model.live == nil else { return false }
        model.endEditing()
        model.reveal(canvasID: canvasID, objectID: id)
        window?.makeFirstResponder(self)
        return true
    }

    fileprivate func objectAccessibilityFrame(_ worldRect: CGRect) -> CGRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(viewRect(model.viewport.screen(worldRect)), to: nil))
    }

    /// The handles' resize, for VoiceOver.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard !model.selection.isEmpty else { return nil }
        return [NSAccessibilityCustomAction(name: String(localized: "Make Larger")) { [weak self] in
                    self?.model.scaleSelection(by: 1.1); return true },
                NSAccessibilityCustomAction(name: String(localized: "Make Smaller")) { [weak self] in
                    self?.model.scaleSelection(by: 1 / 1.1); return true }]
    }
}

/// One retained accessibility element per Draw object; its frame follows the
/// viewport without rebuilding the tree during a pan or zoom.
@MainActor
private final class DrawAccessibilityObjectElement: NSAccessibilityElement {
    private weak var board: DrawBoardView?
    private let id: UUID
    private var worldRect = CGRect.zero
    private var name = ""
    private var image = false

    init(board: DrawBoardView, id: UUID) {
        self.board = board
        self.id = id
        super.init()
        setAccessibilityParent(board)
        setAccessibilityIdentifier("draw-object-" + id.uuidString)
        setAccessibilityEnabled(true)
    }
    required init?(coder: NSCoder) { nil }

    func update(_ object: DrawObject, number: Int) {
        worldRect = DrawGeometry.bounds(object)
        image = object.isImage
        switch object.content {
        case let .text(text): name = String(localized: "Text") + ", " + (text.isEmpty ? String(localized: "Empty") : String(text.prefix(160)))
        case .stroke: name = String(localized: "Pen stroke") + " \(number)"
        case let .shape(shape):
            let kind: String = switch shape {
            case .rectangle: String(localized: "Rectangle")
            case .ellipse: String(localized: "Ellipse")
            case .line: String(localized: "Line")
            case .arrow: String(localized: "Arrow")
            }
            name = kind + " \(number)"
        case .image: name = String(localized: "Image") + " \(number)"
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { image ? .image : .group }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityFrame() -> NSRect { board?.objectAccessibilityFrame(worldRect) ?? .zero }
    override func isAccessibilitySelected() -> Bool { board?.model.selection.contains(id) == true }
    override func isAccessibilityFocused() -> Bool {
        guard let board else { return false }
        return board.window?.firstResponder === board && board.model.selection == [id]
    }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { _ = board?.focusAccessibleObject(id) }
    }
    override func accessibilityPerformPress() -> Bool { board?.focusAccessibleObject(id) ?? false }
}

/// The ink being drawn: frozen chunks of at most 32 samples and a short
/// tail, so each pointer event redraws only the tail (the lab's
/// `RetainedStroke`, as vector layers).
@MainActor
final class DrawLiveInk {
    let container = CALayer()
    private var tail: CAShapeLayer
    private var startIndex = 1
    private var startPoint: DrawInkSample?
    private let colour: CGColor
    private let width: CGFloat
    let usesPressure: Bool
    static let chunk = 32

    init(colour: CGColor, width: CGFloat, usesPressure: Bool = false) {
        self.colour = colour
        self.width = width
        self.usesPressure = usesPressure
        container.actions = DrawBoardView.noActions
        tail = CAShapeLayer()
        tail = makeLayer()
    }

    private func makeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.actions = DrawBoardView.noActions
        layer.fillColor = usesPressure ? colour : nil
        layer.strokeColor = usesPressure ? nil : colour
        layer.lineWidth = width
        layer.lineCap = .round
        layer.lineJoin = .round
        container.addSublayer(layer)
        return layer
    }

    var layerCount: Int { container.sublayers?.count ?? 0 }

    func update(_ trace: DrawInkTrace) {
        let points = trace.samples
        guard let first = points.first else { return }
        if startPoint == nil { startPoint = first }
        if points.count - startIndex > Self.chunk, let start = startPoint {
            // Freeze everything up to the last midpoint; the tail restarts there.
            let last = points.count - 1
            let middle = DrawInkSample(point: DrawInk.mid(points[last - 1].point, points[last].point),
                                       pressure: points[last - 1].pressure == nil && points[last].pressure == nil
                                           ? nil : ((points[last - 1].pressure ?? 0.5) + (points[last].pressure ?? 0.5)) / 2)
            if usesPressure {
                let segment = [start] + Array(points[startIndex..<last]) + [middle]
                tail.path = DrawInk.pressureOutline(DrawInk.smooth(segment), baseWidth: width)
            } else {
                let frozen = CGMutablePath()
                frozen.move(to: start.point)
                for index in startIndex..<last {
                    frozen.addQuadCurve(to: DrawInk.mid(points[index].point, points[index + 1].point), control: points[index].point)
                }
                tail.path = frozen
            }
            tail = makeLayer()
            startPoint = middle
            startIndex = points.count - 1
        }
        if usesPressure {
            let segment = [startPoint ?? first] + Array(points[min(startIndex, points.count)...])
            tail.path = DrawInk.pressureOutline(DrawInk.smooth(segment), baseWidth: width)
        } else {
            let path = CGMutablePath()
            DrawInk.livePath(start: (startPoint ?? first).point,
                             points: points[min(startIndex, points.count)...], into: path)
            tail.path = path
        }
    }
}

/// The dots: one tiny tile per spacing as the layer's pattern, the layer
/// shifted by the pan modulo a tile, so panning never draws anything.
@MainActor
struct DrawDots {
    private struct TileKey: Hashable {
        let bucket: Int
        let ink: AtticRGBA
    }

    private struct InkKey: Hashable {
        let colours: AtticDesignContext.ColourKey?
        let dark: Bool
    }

    private var tiles: [TileKey: CGColor] = [:]
    private static var inks: [InkKey: AtticRGBA] = [:]
    /// The panel's design (surface, mode), from SwiftUI.
    var design: AtticDesignContext?
    /// Tiles drawn so far (a pan draws none).
    private(set) var tilesRendered = 0
    /// The grid point (world) the pattern is laid from, at a zoom.
    private var anchor: (zoom: CGFloat, x: CGFloat, y: CGFloat)?

    /// The working file's 32 px grid and 1.7 px dots at rgba(0,0,0,0.13).
    static let spacing: CGFloat = 16
    static let alpha: CGFloat = 0.13
    /// Dots closer than this on screen crowd the board.
    static let minimumStep: CGFloat = 8

    /// The grid on screen at a zoom: the distance between the dots shown,
    /// and how many grid points that is. Zoomed out past 50 %, every second
    /// dot goes, then every fourth (every eighth at 10 %), so the grid thins
    /// out rather than crowding or vanishing.
    static func grid(zoom: CGFloat) -> (step: CGFloat, every: Int)? {
        guard zoom > 0 else { return nil }
        var every = 1
        while spacing * zoom * CGFloat(every) < minimumStep - 0.0001 { every *= 2 }
        return (spacing * zoom * CGFloat(every), every)
    }

    /// The dot's diameter on screen: the working file's 1.7 pt at 100 %,
    /// the same at every zoom.
    static func dotDiameter(zoom: CGFloat) -> CGFloat { 1.7 }

    /// The dot's ink on the board's surface. Solid (and glass made solid by
    /// Reduce Transparency) keeps the working file's black, or white, at
    /// 0.13. Glass and Frosted take the panel's own ink made see-through, as
    /// the greys on glass do (`AtticSurfaceInk.toneInk`), at the alpha
    /// that keeps, over each desktop the glass is judged on (black, mid grey,
    /// white), at least the contrast the working file's dot has on the solid
    /// panel: as readable wherever the panel sits.
    static func ink(design: AtticDesignContext?, dark: Bool) -> AtticRGBA {
        let drawn: AtticRGBA = dark ? .white(alpha) : .black(alpha)
        guard var context = design else { return drawn }
        context.mode = dark ? .dark : .light
        let key = InkKey(colours: context.colourKey, dark: dark)
        if let cached = inks[key] { return cached }
        let tokens = context.tokens
        var value = drawn
        if AtticSurfaceInk.seeThrough(tokens) {
            var solid = context
            solid.surface = .solid
            let target = drawn.contrast(on: solid.tokens.panel.composite(.midGrey, at: AtticSurfaceModel.contentTop))
            let ink = tokens.ink(.heading).withAlpha(1)
            let needed = AtticSurfaceModel.Desktop.allCases.map { desktop -> Double in
                let base = tokens.panel.composite(desktop, at: AtticSurfaceModel.contentTop)
                var low = 0.0, high = 1.0
                for _ in 0..<30 {
                    let mid = (low + high) / 2
                    if ink.withAlpha(mid).contrast(on: base) < target { low = mid } else { high = mid }
                }
                return high
            }
            value = ink.withAlpha(min(1, needed.max() ?? Double(alpha)))
        }
        inks[key] = value
        return value
    }

    mutating func place(in layer: CALayer, viewport: DrawViewport, size: CGSize, dark: Bool) {
        guard let grid = Self.grid(zoom: viewport.zoom), size.width > 0 else { layer.backgroundColor = nil; return }
        let ink = Self.ink(design: design, dark: dark)
        let key = TileKey(bucket: Int((grid.step * 4).rounded()), ink: ink)
        let colour: CGColor
        if let cached = tiles[key] {
            colour = cached
        } else {
            let image = Self.tileImage(step: CGFloat(key.bucket) / 4, diameter: Self.dotDiameter(zoom: viewport.zoom), ink: ink)
            colour = NSColor(patternImage: image).cgColor
            tiles[key] = colour
            tilesRendered += 1
        }
        let tileStep = CGFloat(key.bucket) / 4
        // One kept grid point, picked by the board's bottom left (where the
        // pattern starts) when the zoom changes, carries the pattern; a pan
        // moves it with the board and wraps the layer by whole tiles, so the
        // dots near it are grid points.
        if anchor?.zoom != viewport.zoom {
            let period = Self.spacing * CGFloat(grid.every)
            func kept(before edge: CGFloat) -> CGFloat {
                ((edge - Self.spacing / 2) / period).rounded(.down) * period + Self.spacing / 2
            }
            anchor = (viewport.zoom, kept(before: -viewport.x / viewport.zoom), kept(before: (size.height - viewport.y) / viewport.zoom))
        }
        guard let anchor else { return }
        let x = viewport.x + anchor.x * viewport.zoom
        let y = size.height - viewport.y - anchor.y * viewport.zoom
        func positiveMod(_ a: CGFloat, _ b: CGFloat) -> CGFloat { let r = a.truncatingRemainder(dividingBy: b); return r < 0 ? r + b : r }
        layer.backgroundColor = colour
        layer.bounds = CGRect(x: 0, y: 0, width: size.width + tileStep * 2, height: size.height + tileStep * 2)
        layer.position = CGPoint(x: positiveMod(x - tileStep / 2, tileStep) - tileStep,
                                 y: positiveMod(y - tileStep / 2, tileStep) - tileStep)
    }

    /// One tile: a dot in the middle of a `step` square.
    static func tileImage(step: CGFloat, diameter: CGFloat, ink: AtticRGBA) -> NSImage {
        let radius = diameter / 2
        return NSImage(size: CGSize(width: step, height: step), flipped: false) { rect in
            ink.nsColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2)).fill()
            return true
        }
    }
}

extension DrawBoardView {
    /// The panel's surface and mode for the dots (Glass, Frosted, Solid).
    func setDotsDesign(_ design: AtticDesignContext) {
        guard dots.design?.colourKey != design.colourKey else { return }
        dots.design = design
        layoutLayers()
    }
}

/// The open text box: types straight into the store (one Undo step per
/// edit), IME composing in place; ⌘Z and ⇧⌘Z are the store's.
@MainActor
final class DrawTextEditorView: NSTextView, NSTextViewDelegate {
    weak var owner: DrawBoardView?
    private var applying = false

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    required init?(coder: NSCoder) { fatalError("Not archived") }

    private func commonInit() {
        delegate = self
        isRichText = false
        drawsBackground = false
        allowsUndo = false
        textContainerInset = .zero
        isHorizontallyResizable = true
        isVerticallyResizable = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        setAccessibilityLabel(String(localized: "Text box"))
    }

    func apply(_ edit: DrawTextEdit, zoom: CGFloat, palette: DrawPalette, replacingText: Bool) {
        let fontSize = edit.pointSize * zoom
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = fontSize * DrawText.lineHeight
        paragraph.maximumLineHeight = fontSize * DrawText.lineHeight
        let colour = NSColor(cgColor: palette.cgColor(edit.style.colour)) ?? .labelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: colour,
                                                         .paragraphStyle: paragraph]
        typingAttributes = attributes
        insertionPointColor = colour
        // A box with a set width wraps inside it; others grow to the right.
        let wrap = edit.width.map { $0 * zoom }
        isHorizontallyResizable = wrap == nil
        textContainer?.size = CGSize(width: wrap ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        applying = true
        if replacingText, string != edit.text, !hasMarkedText() {
            let caret = Self.caretAfterChange(from: string, to: edit.text)
            string = edit.text
            setSelectedRange(NSRange(location: caret, length: 0))
        }
        textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textStorage?.length ?? 0))
        applying = false
    }

    /// Undo and Redo replace text from the store. Return to the changed
    /// grapheme boundary, including for edits before emoji or RTL writing.
    private static func caretAfterChange(from before: String, to after: String) -> Int {
        let old = Array(before), new = Array(after)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        return String(new.dropLast(suffix)).utf16.count
    }

    /// A text box has one font and one colour: rich text inserted by the
    /// Character Viewer or an input method takes the box's style.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText((string as? NSAttributedString)?.string ?? string, replacementRange: replacementRange)
    }

    func textDidChange(_ notification: Notification) {
        guard !applying, !hasMarkedText() else { return }
        owner?.editorTextChanged(string)
    }

    override func unmarkText() {
        super.unmarkText()
        if !applying { owner?.editorTextChanged(string) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let owner else { return super.performKeyEquivalent(with: event) }
        let key = DrawBoardView.key(event)
        if key.command, key.characters == "z", !key.option, !key.control {
            key.shift ? owner.model.redo() : owner.model.undo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func undo(_ sender: Any?) { owner?.model.undo() }
    @objc func redo(_ sender: Any?) { owner?.model.redo() }

    override func cancelOperation(_ sender: Any?) { owner?.model.endEditing() }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, owner != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, let owner = self.owner, owner.window?.firstResponder !== self else { return }
                owner.model.endEditing()
            }
        }
        return resigned
    }
}
