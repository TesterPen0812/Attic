import AppKit
import QuartzCore

/// The Draw board (restart plan §2): live ink draws incrementally on its own
/// layers; committed content is one raster from the background renderer,
/// latest request winning; live ink stays until a raster that includes it
/// is installed. Input handlers only move layers and queue rasters.
///
/// The view is unflipped; the page model's screen points are y down, so
/// every conversion flips once here.
@MainActor
final class DrawBoardView: NSView, DrawBoardSink {
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

    #if DEBUG
    /// Test seam: the pointer's window location in place of the real one.
    var pointerOverride: CGPoint?
    #endif

    /// The drawing's pen cursor: a dot in the pen colour, sized to the
    /// stroke on screen (its 16 px image, r = width ÷ 2 + 1 px, at most
    /// 6 px: halved, the stroke plus 1 pt, at most 6 pt), in a white ring.
    static let cursorRing: CGFloat = 0.6
    static func penDotDiameter(strokeWidth: Double, zoom: CGFloat) -> CGFloat {
        min(6, max(2, CGFloat(strokeWidth) * zoom + 1))
    }
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
    }

    func drawSelectionChanged() { updateSelection() }

    func drawVisibilityChanged() {
        if model.isShown { needsRaster = true; requestRaster() } else { renderer.cancel(); requestedKey = nil }
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
            if handlesLayer.path != nil { window?.invalidateCursorRects(for: self) }
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
        if model.live == nil { window?.invalidateCursorRects(for: self) }
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

    override func scrollWheel(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        model.scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, command: command, at: boardPoint(event))
    }

    override func magnify(with event: NSEvent) {
        model.magnify(by: event.magnification, at: boardPoint(event))
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

    /// The resize cursor for a handle.
    static func cursor(for handle: DrawHandle) -> NSCursor {
        switch handle {
        case .topLeft: .frameResize(position: .topLeft, directions: .all)
        case .topRight: .frameResize(position: .topRight, directions: .all)
        case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
        case .left, .right: .columnResize
        case .start, .end: .crosshair
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch model.tool {
        case .select: .arrow
        case .text: .iBeam
        case .pen, .eraser, .shape: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
        // The handles show which way they resize, over the same reach a
        // press takes.
        let reach = DrawPageModel.handleHitRadius
        for spot in model.handleSpots {
            let point = boardToView(spot.point)
            addCursorRect(CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2),
                          cursor: Self.cursor(for: spot.handle))
        }
    }

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
