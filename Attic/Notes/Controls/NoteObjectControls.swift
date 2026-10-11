import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The note's images and files, on the engine's command layer (Phase 2
/// slice 3b, UX plan § 3.5): the selected object's ring and resize corner,
/// the drop line and the carry card for files dragged in, a click on an
/// action drawn on a failed object, and the object's menu.
///
/// Nothing here edits text or rebuilds the editor: the ring and the drop
/// line are two thin views over the text view, moved when the selection or
/// the layout changes, and every change goes through `NoteObjectCommand`.
@MainActor
final class NoteObjectControls: NSObject, NoteObjectInteraction {
    let engine: NoteEditorEngine
    private weak var textView: NoteEditorTextView?
    private let selectionView = NoteObjectSelectionView()
    private let dropView = NoteDropIndicatorView()
    private var selectionObserver: NSObjectProtocol?
    private var previousLayout: (() -> Void)?
    private var lastColumnWidth: CGFloat = 0
    private var dropBoundary: Int?

    /// The page's source picker for Retry and Locate (the same open panel
    /// as Insert › Image or File…).
    var requestSource: ((NoteObjectSourceRequest) -> Void)?
    /// Diagnostic: how many times the ring moved (never on a keystroke that
    /// leaves no object selected).
    private(set) var ringUpdateCount = 0
    /// Diagnostics for tests: what shows over the text now.
    var isRingShown: Bool { !selectionView.isHidden && selectionView.alphaValue > 0 }
    var isResizeCornerShown: Bool { isRingShown && selectionView.isResizable }
    var ringFrame: NSRect { selectionView.frame }

    init(engine: NoteEditorEngine, textView: NoteEditorTextView) {
        self.engine = engine
        self.textView = textView
        super.init()
        selectionView.isHidden = true
        dropView.isHidden = true
        AtticOverlayHierarchy.attach(selectionView, to: textView)
        AtticOverlayHierarchy.attach(dropView, to: textView)
        selectionView.onResize = { [weak self] width, finished in self?.resize(toWidth: width, finished: finished) }
        textView.objectInteraction = self
        engine.onRetryImportObject = { [weak self] id in self?.requestSource?(.retry(id)) }
        engine.onLocateObject = { [weak self] id in self?.requestSource?(.locate(id)) }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateSelection() } }
        previousLayout = textView.onLayout
        textView.onLayout = { [weak self] in
            self?.previousLayout?()
            self?.layoutDidChange()
        }
        lastColumnWidth = engine.objectColumnWidth
        applyLook()
    }

    func invalidate() {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
        textView?.onLayout = previousLayout
        if textView?.objectInteraction === self { textView?.objectInteraction = nil }
        engine.onRetryImportObject = nil
        engine.onLocateObject = nil
        AtticOverlayHierarchy.remove(selectionView)
        AtticOverlayHierarchy.remove(dropView)
    }

    /// The accent follows the look (a change of palette, not a keystroke).
    func applyLook() {
        let accent = engine.objectDesign.tokens.focusRing.nsColor
        guard accent != selectionView.color else { return }
        selectionView.color = accent
        dropView.color = accent
    }

    // MARK: Commands

    /// Runs an object command through the engine, then refreshes what the
    /// command changed on the object's face.
    func run(_ command: NoteObjectCommand, objectID: UUID) {
        let engine = engine
        Task { @MainActor [weak self] in
            let done = await engine.perform(command, objectID: objectID)
            if done, case .locateAt = command { engine.refreshObjectFaces() }
            if done, case .replaceMissingAt = command { engine.refreshObjectFaces() }
            self?.updateSelection()
        }
    }

    /// Open With ▸ Other…: an application chosen in an open panel.
    func chooseApplication(for objectID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(.openWith(url), objectID: objectID)
    }

    /// Locate… found a file: the original is verified against the object's
    /// identity; a placement from before identities were kept is replaced
    /// explicitly with the chosen file instead.
    func locate(_ objectID: UUID, at url: URL) {
        guard let (object, _) = engine.objectPlacement(objectID) else { return }
        let extras = (object as? NoteImageAttachment)?.extras ?? (object as? NoteFileAttachment)?.extras ?? [:]
        run(extras["contentDigest"] == nil ? .replaceMissingAt(url) : .locateAt(url), objectID: objectID)
    }

    func objectCommands(for objectID: UUID) -> [AtticMenuCommand] {
        NoteObjectMenu.commands(for: objectID, engine: engine,
                                run: { [weak self] in self?.run($0, objectID: objectID) },
                                chooseApplication: { [weak self] in self?.chooseApplication(for: objectID) })
    }

    // MARK: Selection ring and resize corner

    private var selected: (NoteObjectAttachment, NSRange)? { NoteObjectMenu.selectedObject(in: engine) }

    func updateSelection() {
        guard let textView else { return }
        guard let (object, range) = selected, let rect = engine.rect(for: range) else {
            if !selectionView.isHidden { fade(selectionView, in: false) }
            return
        }
        ringUpdateCount += 1
        let resizable = object is NoteImageAttachment && engine.validate(.size(1), objectID: object.objectID).enabled
        selectionView.show(objectRect: rect, resizable: resizable,
                           cornerRadius: object is NoteFileAttachment ? AtticNoteObjectMetrics.cardRadius : AtticRadius.image,
                           in: textView)
        if selectionView.isHidden || selectionView.alphaValue < 1 { fade(selectionView, in: true) }
    }

    private func layoutDidChange() {
        let width = engine.objectColumnWidth
        if abs(width - lastColumnWidth) >= 1 {
            lastColumnWidth = width
            // A card spans the column: drawn again at its new width.
            engine.refreshObjectFaces()
        }
        if !selectionView.isHidden, !selectionView.isResizing { updateSelection() }
    }

    /// Resize corner: the ring follows the pointer (the image keeps its
    /// aspect ratio); the new width is written once, on release, as a
    /// fraction of the column (one Undo step).
    private func resize(toWidth width: CGFloat, finished: Bool) {
        guard let (object, range) = selected, let image = object as? NoteImageAttachment,
              let rect = engine.rect(for: range), let textView else { return }
        let column = max(1, textView.textContainer?.size.width ?? rect.width)
            - 2 * (textView.textContainer?.lineFragmentPadding ?? 0)
        let natural = image.pixelSize.map { $0.width / 2 } ?? column
        let clamped = min(max(width, column * 0.1), min(column, natural))
        if finished {
            let fraction = Double(min(1, max(0.1, clamped / column)))
            run(.size(fraction), objectID: image.objectID)
        } else {
            let aspect = rect.width > 0 ? rect.height / rect.width : 1
            selectionView.preview(objectRect: CGRect(x: rect.minX, y: rect.minY, width: clamped, height: clamped * aspect))
        }
    }

    // MARK: Clicks

    /// The object under `point` (a block object's own rectangle).
    private func object(at point: NSPoint) -> (NoteObjectAttachment, NSRange, NSRect)? {
        guard let textView else { return nil }
        let index = textView.characterIndexForInsertion(at: point)
        for location in [index, index - 1] where location >= 0 {
            guard let object = engine.object(at: location),
                  object is NoteImageAttachment || object is NoteFileAttachment else { continue }
            let range = NSRange(location: location, length: 1)
            guard let rect = engine.rect(for: range), rect.contains(point) else { continue }
            return (object, range, rect)
        }
        return nil
    }

    func handleMouseDown(_ event: NSEvent) -> Bool {
        guard event.clickCount == 1, let textView,
              !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) else { return false }
        let point = textView.convert(event.locationInWindow, from: nil)
        guard let (object, range, rect) = object(at: point) else { return false }
        // An action drawn on the object.
        if let face = engine.objectFace(for: object) {
            let local = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
            let actions = engine.inlineActions(for: object)
            if let index = AtticNoteObjectLayout.action(at: local, face: face, size: rect.size), index < actions.count {
                textView.setSelectedRange(range)
                run(actions[index].command, objectID: object.objectID)
                return true
            }
        }
        // The first click selects the object (its ring); a press on the
        // selected object is the text view's, so it can be dragged.
        guard textView.selectedRange() != range else { return false }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        return true
    }

    func objectMenu(for event: NSEvent) -> NSMenu? {
        guard let textView else { return nil }
        let point = textView.convert(event.locationInWindow, from: nil)
        guard let (object, range, _) = object(at: point) else { return nil }
        textView.setSelectedRange(range)
        let menu = AtticNativeMenu.make(objectCommands(for: object.objectID))
        menu.appearance = textView.window?.effectiveAppearance
        return menu
    }

    // MARK: Files dragged in

    private func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func isFileDrag(_ info: any NSDraggingInfo) -> Bool {
        guard let textView, (info.draggingSource as AnyObject?) !== textView else { return false }
        return !fileURLs(info).isEmpty
    }

    func fileDragUpdated(_ info: any NSDraggingInfo, entered: Bool) -> NSDragOperation? {
        guard isFileDrag(info), let textView else { return nil }
        guard textView.isEditable else {
            fileDragEnded()
            return []
        }
        if entered { dressCarryCards(info) }
        let point = textView.convert(info.draggingLocation, from: nil)
        let boundary = Self.dropBoundary(at: point, engine: engine, textView: textView)
        if boundary != dropBoundary {
            dropBoundary = boundary
            showDropLine(at: boundary)
        }
        return .copy
    }

    func fileDragEnded() {
        dropBoundary = nil
        if !dropView.isHidden { fade(dropView, in: false) }
    }

    func performFileDrop(_ info: any NSDraggingInfo) -> Bool? {
        guard isFileDrag(info), let textView else { return nil }
        let urls = fileURLs(info)
        let point = textView.convert(info.draggingLocation, from: nil)
        let boundary = dropBoundary ?? Self.dropBoundary(at: point, engine: engine, textView: textView)
        fileDragEnded()
        guard textView.isEditable, let request = engine.onFileBatchRequest else { return false }
        // A zero-length target is a block boundary: the files land between
        // lines, and the batch keeps its place while typing goes on.
        request(urls, "", NSRange(location: boundary, length: 0))
        return true
    }

    /// Where dropped files land: the start of the paragraph under the
    /// pointer, or its end when the pointer is on its lower half; never in
    /// the title, never inside an object (objects are paragraphs of their
    /// own, so a paragraph boundary is always between lines).
    static func dropBoundary(at point: NSPoint, engine: NoteEditorEngine, textView: NSTextView) -> Int {
        let length = engine.textStorage.length
        guard length > 0 else { return 0 }
        let titleEnd = min(NSMaxRange(engine.paragraphRange(at: 0)), length)
        let index = min(textView.characterIndexForInsertion(at: point), length)
        let paragraph = engine.paragraphRange(at: min(index, length - 1))
        var boundary = NSMaxRange(paragraph)
        if let rect = engine.rect(for: paragraph), point.y < rect.midY { boundary = paragraph.location }
        return max(boundary, titleEnd)
    }

    private func showDropLine(at boundary: Int) {
        guard let textView else { return }
        let length = engine.textStorage.length
        let y: CGFloat
        if boundary < length, let rect = engine.rect(for: NSRange(location: boundary, length: 1)) {
            y = rect.minY
        } else if length > 0, let rect = engine.rect(for: NSRange(location: length - 1, length: 1)) {
            y = rect.maxY
        } else {
            y = textView.textContainerOrigin.y
        }
        let padding = textView.textContainer?.lineFragmentPadding ?? 0
        let x = textView.textContainerOrigin.x + padding
        let width = max(0, (textView.textContainer?.size.width ?? textView.bounds.width) - padding * 2)
        dropView.place(lineY: y, x: x, width: width)
        if dropView.isHidden || dropView.alphaValue < 1 { fade(dropView, in: true) }
    }

    /// The carry card: each dragged file becomes the note's card (a stack,
    /// "+N" on the top one) while it is over the note; AppKit gives the
    /// source's images back when the drag leaves.
    private func dressCarryCards(_ info: any NSDraggingInfo) {
        guard let textView else { return }
        let urls = fileURLs(info)
        let renderer = NoteObjectRenderer(design: engine.objectDesign)
        info.draggingFormation = .stack
        info.enumerateDraggingItems(options: [], for: textView, classes: [NSURL.self],
                                    searchOptions: [.urlReadingFileURLsOnly: true]) { item, index, _ in
            let url = (item.item as? URL) ?? urls[min(index, max(0, urls.count - 1))]
            let type = (UTType(filenameExtension: url.pathExtension) ?? .data).identifier
            let image = renderer.carryCard(name: url.lastPathComponent,
                                           systemImage: AtticNoteObjectFace.systemImage(forContentType: type),
                                           more: index == 0 ? max(0, urls.count - 1) : 0)
            let frame = NSRect(origin: item.draggingFrame.origin, size: image.size)
            item.setDraggingFrame(frame, contents: image)
        }
    }

    // MARK: Motion

    private func fade(_ view: NSView, in showing: Bool) {
        let reduced = AtticMotionPreference.reducesMotion
        if showing { view.isHidden = false }
        guard !reduced else {
            view.alphaValue = showing ? 1 : 0
            view.isHidden = !showing
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AtticMotionPreset.hover.duration
            view.animator().alphaValue = showing ? 1 : 0
        } completionHandler: {
            MainActor.assumeIsolated { if !showing, view.alphaValue == 0 { view.isHidden = true } }
        }
    }
}

/// What the page's open panel is choosing a file for.
enum NoteObjectSourceRequest: Equatable {
    case retry(UUID)
    case locate(UUID)
}

// MARK: - Views over the text

/// The selected object's 2 pt ring, and the resize corner on an image.
final class NoteObjectSelectionView: NSView {
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true; handle.color = color } }
    var onResize: ((CGFloat, Bool) -> Void)?
    private let handle = NoteResizeHandleView()
    private(set) var isResizing = false
    var isResizable: Bool { !handle.isHidden }
    private var objectWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(handle)
        handle.onDrag = { [weak self] dx, finished in
            guard let self else { return }
            self.isResizing = !finished
            self.onResize?(self.objectWidth + dx, finished)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Only the corner takes the pointer; the ring lets clicks through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !handle.isHidden else { return nil }
        let local = convert(point, from: superview)
        return handle.frame.contains(local) ? handle : nil
    }

    private var cornerRadius: CGFloat = AtticRadius.image

    func show(objectRect: CGRect, resizable: Bool, cornerRadius: CGFloat, in view: NSView) {
        objectWidth = objectRect.width
        self.cornerRadius = cornerRadius
        handle.isHidden = !resizable
        place(objectRect)
    }

    func preview(objectRect: CGRect) { place(objectRect) }

    private func place(_ objectRect: CGRect) {
        let m = AtticNoteObjectMetrics.self
        let outset = m.ringOutset + m.ringWidth
        let room = m.resizeHitTarget / 2
        frame = objectRect.insetBy(dx: -outset - room, dy: -outset - room)
        let size = m.resizeHitTarget
        handle.frame = NSRect(x: bounds.maxX - room - outset - size / 2, y: bounds.maxY - room - outset - size / 2,
                              width: size, height: size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = AtticNoteObjectMetrics.self
        let room = m.resizeHitTarget / 2
        let ring = bounds.insetBy(dx: room + m.ringWidth / 2, dy: room + m.ringWidth / 2)
        let path = NSBezierPath(roundedRect: ring, xRadius: cornerRadius + m.ringOutset,
                                yRadius: cornerRadius + m.ringOutset)
        path.lineWidth = m.ringWidth
        color.setStroke()
        path.stroke()
    }
}

/// The resize corner: a small disc in the accent with a white rim.
final class NoteResizeHandleView: NSView {
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var onDrag: ((CGFloat, Bool) -> Void)?
    private var start: NSPoint?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let size = AtticNoteObjectMetrics.resizeHandle
        let disc = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: disc.insetBy(dx: -1.5, dy: -1.5)).fill()
        color.setFill()
        NSBezierPath(ovalIn: disc).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: NSCursor.frameResize(position: .bottomRight, directions: .all))
    }

    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        onDrag?(event.locationInWindow.x - start.x, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        self.start = nil
        onDrag?(event.locationInWindow.x - start.x, true)
    }
}

/// Where dragged files will land: a 2 pt line across the column with a
/// small disc at its start, between two lines of the note.
final class NoteDropIndicatorView: NSView {
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func place(lineY: CGFloat, x: CGFloat, width: CGFloat) {
        let cap = AtticNoteObjectMetrics.dropLineCap
        frame = NSRect(x: x - cap / 2, y: lineY - cap / 2, width: width + cap / 2, height: cap)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = AtticNoteObjectMetrics.self
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: m.dropLineCap, height: m.dropLineCap)).fill()
        let line = NSRect(x: m.dropLineCap / 2, y: (bounds.height - m.dropLineWidth) / 2,
                          width: bounds.width - m.dropLineCap / 2, height: m.dropLineWidth)
        NSBezierPath(roundedRect: line, xRadius: m.dropLineWidth / 2, yRadius: m.dropLineWidth / 2).fill()
    }
}
