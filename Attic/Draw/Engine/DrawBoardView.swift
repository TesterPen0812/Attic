import AppKit
import Combine
import QuartzCore

/// The Draw board (restart plan §2): live ink draws incrementally on its own
/// layers; committed content is one raster from the background renderer,
/// latest request winning; live ink stays until a raster that includes it
/// is installed. Input handlers only move layers and queue rasters.
///
/// The view is unflipped; the page model's screen points are y down, so
/// every conversion flips once here.
@MainActor
final class DrawBoardView: NSView, DrawBoardSink, AtticHorizontalScrollOwner {
    let model: DrawPageModel

    private let dotsLayer = CALayer()
    private let committedLayer = CALayer()
    /// Live overlays in world points: ink, the shape being dragged out.
    private let worldLayer = CALayer()
    private let selectionLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()
    private var liveInk: DrawLiveInk?
    private var liveShape: CAShapeLayer?
    private var liveStartRevision = 0
    /// Committed overlays waiting for a raster that includes their revision.
    private(set) var pendingOverlays: [(revision: Int, layer: CALayer)] = []
    private var requestedKey: DrawRasterKey?
    private(set) var installedKey: DrawRasterKey?
    private var needsRaster = true
    private var dots = DrawDots()
    private(set) var editor: DrawTextEditorView?
    /// Whether the scroll gesture under way began over the board's clear
    /// area (it pans and zooms) or over the top row or bar (it doesn't).
    private var scrollGestureIsOwn = true
    private var cursorArea: NSTrackingArea?
    private var cursorRefreshQueued = false
    /// The board set the cursor last (so leaving it restores the normal one).
    private var showsBoardCursor = false
    private var modelChanges: AnyCancellable?
    private var stateObservers: [NSObjectProtocol] = []

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
    #endif

    private lazy var renderer = DrawLatestRenderer<DrawRasterRequest, DrawRasterImage>(
        work: { request, stale in DrawRaster.render(request, cancelled: stale) },
        install: { [weak self] request, image in self?.install(request, image) }
    )

    init(model: DrawPageModel) {
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: model.boardSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for sublayer in [dotsLayer, committedLayer, worldLayer] {
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
        layoutLayers()
        requestRaster()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        requestRaster()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dots = DrawDots()
        layoutLayers()
        requestRaster()
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
            let s = viewport.zoom / installed.viewport.zoom
            committedLayer.bounds = CGRect(origin: .zero, size: installed.size)
            committedLayer.setAffineTransform(CGAffineTransform(
                a: s, b: 0, c: 0, d: s,
                tx: viewport.x - s * installed.viewport.x,
                ty: height - s * installed.size.height + s * installed.viewport.y - viewport.y))
        }
        dots.place(in: dotsLayer, viewport: viewport, size: bounds.size, dark: isDark)
        updateSelection()
        updateEditorFrame()
        CATransaction.commit()
    }

    // MARK: Rasters

    private func currentKey() -> DrawRasterKey {
        let move = model.rasterMove
        return DrawRasterKey(revision: model.contentRevision, viewport: model.viewport, size: bounds.size, scale: scale,
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
        #if DEBUG
        rasterRequests += 1
        #endif
        renderer.request(DrawRasterRequest(key: key, objects: model.objects, replacements: model.rasterReplacements))
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
        updateSelection()
        requestRaster()
    }

    func drawViewportChanged() {
        layoutLayers()
        requestRaster()
        queueCursorRefresh()
    }

    func drawSelectionChanged() { updateSelection() }

    func drawVisibilityChanged() {
        if model.isShown { needsRaster = true; requestRaster() } else { renderer.cancel(); requestedKey = nil }
        queueCursorRefresh()
    }

    func drawLiveChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        marqueeLayer.path = nil
        switch model.live {
        case .ink(let points):
            if liveInk == nil {
                liveStartRevision = model.contentRevision
                let ink = DrawLiveInk(colour: DrawPalette(dark: isDark).cgColor(model.colour),
                                      width: CGFloat(model.strokeSize.strokeWidth))
                worldLayer.addSublayer(ink.container)
                liveInk = ink
            }
            liveInk?.update(points)
        case .shape(let kind, let start, let end):
            if liveShape == nil {
                liveStartRevision = model.contentRevision
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
            let committed = model.contentRevision > liveStartRevision
            for finished in [liveInk?.container, liveShape].compactMap({ $0 }) {
                if committed { pendingOverlays.append((model.contentRevision, finished)) } else { finished.removeFromSuperlayer() }
            }
            liveInk = nil
            liveShape = nil
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
            let moved = object.translated(by: DrawPoint(x: offset.x, y: offset.y), id: object.id)
            if chosen.count == 1, case .shape(let kind) = moved.content, kind == .line || kind == .arrow { continue }
            let rect = viewRect(viewport.screen(DrawGeometry.bounds(moved)).insetBy(dx: -gap, dy: -gap))
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
                editor.owner = nil
                editor.removeFromSuperview()
                self.editor = nil
                window?.makeFirstResponder(self)
            }
            updateSelection()
            return
        }
        let editor = self.editor ?? makeEditor()
        editor.apply(edit, zoom: model.viewport.zoom, palette: DrawPalette(dark: isDark), replacingText: replacingText)
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
        if event.clickCount == 2, model.live == nil {
            model.doubleClick(at: point)
            return
        }
        model.pointerDown(at: point, shift: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        model.pointerDragged(to: boardPoint(event), shift: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        model.pointerUp(at: boardPoint(event))
    }

    override func otherMouseDown(with event: NSEvent) { model.pointerDown(at: boardPoint(event), panButton: true) }
    override func otherMouseDragged(with event: NSEvent) { model.pointerDragged(to: boardPoint(event)) }
    override func otherMouseUp(with event: NSEvent) { model.pointerUp(at: boardPoint(event)) }

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
        if !model.handleKey(Self.key(event)) { super.keyDown(with: event) }
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
        super.viewDidMoveToWindow()
        for observer in stateObservers { NotificationCenter.default.removeObserver(observer) }
        stateObservers = []
        guard let window else { return }
        let names: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didBecomeKeyNotification, window), (NSWindow.didResignKeyNotification, window),
            (NSApplication.didBecomeActiveNotification, nil), (NSApplication.didResignActiveNotification, nil),
        ]
        for (name, object) in names {
            stateObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.queueCursorRefresh() }
            })
        }
        queueCursorRefresh()
    }

    override func mouseEntered(with event: NSEvent) { applyCursor(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { applyCursor(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { applyCursor(at: event.locationInWindow) }
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
            showsBoardCursor = false
            NSCursor.arrow.set()
            window?.resetCursorRects()
        }
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

    private static var penCursors: [String: NSCursor] = [:]

    /// The pen's dot: the pen colour, a white ring, the hot spot at its centre.
    static func penCursor(colour: CGColor) -> NSCursor {
        let d = penDotDiameter
        let key = "\(colour.components ?? [])"
        if let cursor = penCursors[key] { return cursor }
        let side = d + cursorRing * 2
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            let dot = NSBezierPath(ovalIn: CGRect(x: cursorRing, y: cursorRing, width: d, height: d))
            (NSColor(cgColor: colour) ?? .labelColor).setFill()
            dot.fill()
            NSColor.white.setStroke()
            dot.lineWidth = cursorRing * 2
            dot.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: CGPoint(x: side / 2, y: side / 2))
        if penCursors.count > 64 { penCursors.removeAll() }
        penCursors[key] = cursor
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
        String(localized: "\(model.objects.count) objects, \(model.selection.count) selected")
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

/// The ink being drawn: frozen chunks of at most 32 samples and a short
/// tail, so each pointer event redraws only the tail (the lab's
/// `RetainedStroke`, as vector layers).
@MainActor
final class DrawLiveInk {
    let container = CALayer()
    private var tail: CAShapeLayer
    private var startIndex = 1
    private var startPoint: CGPoint?
    private let colour: CGColor
    private let width: CGFloat
    static let chunk = 32

    init(colour: CGColor, width: CGFloat) {
        self.colour = colour
        self.width = width
        container.actions = DrawBoardView.noActions
        tail = CAShapeLayer()
        tail = makeLayer()
    }

    private func makeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.actions = DrawBoardView.noActions
        layer.fillColor = nil
        layer.strokeColor = colour
        layer.lineWidth = width
        layer.lineCap = .round
        layer.lineJoin = .round
        container.addSublayer(layer)
        return layer
    }

    var layerCount: Int { container.sublayers?.count ?? 0 }

    func update(_ points: [CGPoint]) {
        guard let first = points.first else { return }
        if startPoint == nil { startPoint = first }
        if points.count - startIndex > Self.chunk, let start = startPoint {
            // Freeze everything up to the last midpoint; the tail restarts there.
            let frozen = CGMutablePath()
            frozen.move(to: start)
            for index in startIndex..<(points.count - 1) {
                frozen.addQuadCurve(to: DrawInk.mid(points[index], points[index + 1]), control: points[index])
            }
            tail.path = frozen
            tail = makeLayer()
            startPoint = DrawInk.mid(points[points.count - 2], points[points.count - 1])
            startIndex = points.count - 1
        }
        let path = CGMutablePath()
        DrawInk.livePath(start: startPoint ?? first, points: points[min(startIndex, points.count)...], into: path)
        tail.path = path
    }
}

/// The dots: one tiny tile per spacing as the layer's pattern, the layer
/// shifted by the pan modulo a tile, so panning never draws anything.
@MainActor
struct DrawDots {
    private var tiles: [Int: CGColor] = [:]

    /// The working file's 32 px grid and 1.7 px dots at rgba(0,0,0,0.13).
    static let spacing: CGFloat = 16
    static let alpha: CGFloat = 0.13

    mutating func place(in layer: CALayer, viewport: DrawViewport, size: CGSize, dark: Bool) {
        let step = Self.spacing * viewport.zoom
        guard step >= 2, size.width > 0 else { layer.backgroundColor = nil; return }
        let bucket = Int((step * 4).rounded())
        let colour: CGColor
        if let cached = tiles[bucket] {
            colour = cached
        } else {
            colour = Self.tile(step: CGFloat(bucket) / 4, zoom: viewport.zoom, dark: dark)
            tiles[bucket] = colour
        }
        let tileStep = CGFloat(bucket) / 4
        func positiveMod(_ a: CGFloat, _ b: CGFloat) -> CGFloat { let r = a.truncatingRemainder(dividingBy: b); return r < 0 ? r + b : r }
        layer.backgroundColor = colour
        layer.bounds = CGRect(x: 0, y: 0, width: size.width + tileStep * 2, height: size.height + tileStep * 2)
        layer.position = CGPoint(x: positiveMod(viewport.x, tileStep) - tileStep,
                                 y: positiveMod(size.height - viewport.y, tileStep) - tileStep)
    }

    private static func tile(step: CGFloat, zoom: CGFloat, dark: Bool) -> CGColor {
        let radius = 0.85 * zoom / max(0.5, zoom)
        let image = NSImage(size: CGSize(width: step, height: step), flipped: false) { rect in
            NSColor(white: dark ? 1 : 0, alpha: alpha).setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2)).fill()
            return true
        }
        return NSColor(patternImage: image).cgColor
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
            string = edit.text
            setSelectedRange(NSRange(location: (edit.text as NSString).length, length: 0))
        }
        textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textStorage?.length ?? 0))
        applying = false
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
