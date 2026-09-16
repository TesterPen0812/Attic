#if os(macOS)
import AppKit

enum CanvasPlacedRenderObject {
    case image(CanvasPlacedImage)
    case semantic(CanvasSemanticObject)
    var id: UUID {
        switch self { case let .image(value): value.id; case let .semantic(value): value.id }
    }
    var zIndex: Int64 {
        switch self { case let .image(value): value.zIndex; case let .semantic(value): value.transform.zIndex }
    }
    var worldRect: CGRect {
        switch self { case let .image(value): value.worldRect; case let .semantic(value): value.worldRect }
    }
    var createdAt: Date {
        switch self { case let .image(value): value.createdAt; case let .semantic(value): value.createdAt }
    }
    static func comesBefore(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

@MainActor
final class CanvasSemanticTextEditor: NSTextView, NSTextViewDelegate {
    var onCommit: (() -> Bool)?
    var onCancel: (() -> Void)?
    var onKeyboardCommit: (() -> Void)?
    var onDraft: ((String) -> Void)?
    /// Taking focus moves Undo/Redo onto this editor without a draft or canvas
    /// history change, so chrome must be told to re-read the route.
    var onFocus: (() -> Void)?
    var isFinishing = false
    private var readabilityEdgeColor: NSColor?
    /// Typing history belongs to this editor alone. With the window's shared
    /// manager, a closed editor's typing stayed undoable from the next editor,
    /// so Undo rendered enabled and changed nothing visible, and it outlived
    /// the editor in the app's plain Undo/Redo.
    private let typingUndoManager = UndoManager()
    private var observesTypingHistory = false
    private static weak var lastFocused: CanvasSemanticTextEditor?

    override var undoManager: UndoManager? { typingUndoManager }

    /// The editor that still has keyboard focus in its visible window, whether
    /// or not that window is key.
    static var focusedInVisibleWindow: CanvasSemanticTextEditor? {
        guard let editor = lastFocused, let window = editor.window,
              window.isVisible, window.firstResponder === editor else { return nil }
        return editor
    }

    func updateReadabilityEdge(color: NSColor?) {
        guard readabilityEdgeColor != color else { return }
        readabilityEdgeColor = color
        var attributes = typingAttributes
        let range = NSRange(location: 0, length: textStorage?.length ?? 0)
        if let color {
            let shadow = NSShadow()
            shadow.shadowOffset = .zero
            shadow.shadowBlurRadius = AtticClearGlassReadabilityPolicy.edgeRadius
            shadow.shadowColor = color
            textStorage?.addAttribute(.shadow, value: shadow, range: range)
            attributes[.shadow] = shadow
        } else {
            textStorage?.removeAttribute(.shadow, range: range)
            attributes.removeValue(forKey: .shadow)
        }
        typingAttributes = attributes
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        Self.lastFocused = self
        onFocus?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        if !isFinishing, onCommit?() == false { return false }
        return super.resignFirstResponder()
    }

    // The app's plain Edit ▸ Undo/Redo items otherwise resolve to the window,
    // which only knows its own undo manager.
    @objc func undo(_ sender: Any?) { typingUndoManager.undo() }
    @objc func redo(_ sender: Any?) { typingUndoManager.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = typingUndoManager.undoMenuItemTitle
            return typingUndoManager.canUndo
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = typingUndoManager.redoMenuItemTitle
            return typingUndoManager.canRedo
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    func textDidChange(_ notification: Notification) { onDraft?(string) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !observesTypingHistory else { return }
        observesTypingHistory = true
        // TextKit 2, which an editor on existing text uses, reports no text
        // change for its own undo or redo. Report those like TextKit 1 does, so
        // the saved draft and Undo/Redo availability follow them.
        for name: Notification.Name in [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(typingHistoryDidChangeText(_:)),
                                                   name: name, object: typingUndoManager)
        }
    }

    @objc private func typingHistoryDidChangeText(_ notification: Notification) { onDraft?(string) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
            unmarkText()
            if onCommit?() == true { onKeyboardCommit?() }
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z":
            if modifiers.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
        case "v": paste(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "a": selectAll(nil)
        case "\r": keyDown(with: event)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

extension CanvasNSView {
    var selectedSemanticObject: CanvasSemanticObject? {
        semanticObjectsForDisplay.first { $0.id == selectedSemanticObjectID }
    }

    var semanticObjectsForDisplay: [CanvasSemanticObject] {
        guard semanticPointerActive, let selectedSemanticObjectID, let previewImageTransform else { return semanticObjects }
        return semanticObjects.map { object in
            guard object.id == selectedSemanticObjectID else { return object }
            var preview = object
            preview.transform = previewImageTransform
            return preview
        }
    }

    func semanticObject(at worldPoint: CanvasPoint) -> CanvasSemanticObject? {
        let hitMargin = 6 / interaction.viewport.scale
        let hits = semanticObjectsForDisplay.filter {
            $0.worldRect.insetBy(dx: -hitMargin, dy: -hitMargin).contains(worldPoint.cgPoint)
        }.map(CanvasPlacedRenderObject.semantic)
        let imageHits = imagesForDisplay.filter { $0.worldRect.contains(worldPoint.cgPoint) }.map(CanvasPlacedRenderObject.image)
        guard case let .semantic(object)? = (hits + imageHits).max(by: CanvasPlacedRenderObject.comesBefore) else { return nil }
        return object
    }

    func beginSemanticPointerInteraction(at point: CGPoint, worldPoint: CanvasPoint, clickCount: Int) -> Bool {
        if let selected = selectedSemanticObject,
           let handle = CanvasImagePlacement.resizeHandle(at: point, worldRect: selected.worldRect,
                viewport: interaction.viewport, viewportSize: bounds.size, radius: 9) {
            _ = interaction.cancel()
            semanticPointerActive = true
            imagePointerMode = .resizing(id: selected.id, handle: handle, original: selected.transform)
            previewImageTransform = selected.transform
            cursor(for: resizeCursorRole(for: handle)).set()
            return true
        }
        guard let object = semanticObject(at: worldPoint) else { return false }
        _ = interaction.cancel()
        onSelectImage(nil)
        selectedImageID = nil
        selectedSemanticObjectID = object.id
        onSelectSemanticObject(object.id)
        accessibilityFocusedObjectKey = CanvasAccessibilityObjectKey(kind: .semantic, id: object.id)
        if clickCount >= 2, object.content?.text != nil {
            beginSemanticTextEditing(object)
        } else {
            semanticPointerActive = true
            imagePointerMode = .moving(id: object.id, startWorldPoint: worldPoint, original: object.transform)
            previewImageTransform = object.transform
            NSCursor.closedHand.set()
        }
        needsDisplay = true
        return true
    }

    func beginSemanticTextEditing(_ object: CanvasSemanticObject, insertion: CanvasSemanticTextDraft? = nil) {
        guard let content = object.content, let text = content.text else { return }
        if editingSemanticObjectID == object.id, let editor = semanticTextEditor {
            window?.makeFirstResponder(editor)
            return
        }
        guard finishSemanticTextEditing(commit: true) else { return }
        discardImagePreview()
        let editor = CanvasSemanticTextEditor(frame: .zero)
        editor.delegate = editor
        editor.isRichText = false
        editor.drawsBackground = false
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.textContainerInset = CGSize(width: 4, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.font = CanvasSemanticRenderer.font(content, scale: interaction.viewport.scale)
        editor.alignment = CanvasSemanticRenderer.alignment(content)
        editor.textColor = content.color.nsColor
        editor.insertionPointColor = selectionAccentColor
        let draft = insertion ?? onSemanticDraft(CanvasReplicaKey(canvasID: object.canvasID, id: object.id))
        editingSemanticBaseline = draft?.baseline ?? object
        editingSemanticIsInsertion = draft?.isInsertion ?? false
        editor.string = draft?.text ?? text
        editor.allowsUndo = true
        editor.setAccessibilityLabel("Edit canvas text")
        editor.setAccessibilityHelp("Type directly on the canvas. Command-Return saves; Escape cancels.")
        editor.onDraft = { [weak self] _ in
            self?.preserveCurrentSemanticDraft()
            self?.layoutSemanticTextEditor()
        }
        editor.onCommit = { [weak self] in self?.finishSemanticTextEditing(commit: true) ?? true }
        editor.onKeyboardCommit = { [weak self] in
            if let self { window?.makeFirstResponder(self) }
        }
        editor.onCancel = { [weak self] in
            _ = self?.finishSemanticTextEditing(commit: false)
            if let self { window?.makeFirstResponder(self) }
        }
        editor.onFocus = { [weak self] in self?.onEditingAvailabilityChange() }
        semanticTextEditor = editor
        editingSemanticObjectID = object.id
        reconcileSemanticTextEditing(with: [object])
        addSubview(editor)
        layoutSemanticTextEditor()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        needsDisplay = true
    }

    @discardableResult
    func finishSemanticTextEditing(commit: Bool) -> Bool {
        guard let editor = semanticTextEditor, let baseline = editingSemanticBaseline, !editor.isFinishing else { return true }
        editor.isFinishing = true
        defer { editor.isFinishing = false }
        let draft = CanvasSemanticTextDraft(baseline: baseline, text: editor.string, isInsertion: editingSemanticIsInsertion)
        if commit {
            preserveCurrentSemanticDraft()
            guard onCommitSemanticText(draft) else { return false }
        }
        onPreserveSemanticDraft(draft.key, nil)
        semanticTextEditor = nil
        editingSemanticObjectID = nil
        editingSemanticBaseline = nil
        editingSemanticIsInsertion = false
        editor.removeFromSuperview()
        needsDisplay = true
        return true
    }

    func layoutSemanticTextEditor() {
        guard let editor = semanticTextEditor,
              let object = editingSemanticIsInsertion ? editingSemanticBaseline
                : semanticObjects.first(where: { $0.id == editingSemanticObjectID }),
              let content = object.content else { return }
        let origin = interaction.viewport.viewPoint(for: CanvasPoint(x: object.worldRect.minX, y: object.worldRect.minY), in: bounds.size)
        let scale = interaction.viewport.scale
        let font = CanvasSemanticRenderer.font(content, scale: scale)
        let alignment = CanvasSemanticRenderer.alignment(content)
        let inset = CGSize(width: 4 * scale, height: 4 * scale)
        if editor.font != font { editor.font = font }
        if editor.alignment != alignment { editor.alignment = alignment }
        if editor.textColor != content.color.nsColor { editor.textColor = content.color.nsColor }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            editor.updateReadabilityEdge(color: clearReadabilityEnabled
                ? CanvasSemanticRenderer.readabilityEdgeColor(for: content.color.nsColor,
                    increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
                : nil)
        }
        if editor.textContainerInset != inset { editor.textContainerInset = inset }
        let width = object.transform.width * scale
        if editor.frame.width != width {
            editor.setFrameSize(CGSize(width: width, height: editor.frame.height))
        }

        var height = object.transform.height * scale
        if editingSemanticIsInsertion, let layout = editor.layoutManager, let container = editor.textContainer {
            // Reuse NSTextView's incremental layout, including its marked text
            // and trailing empty line. Final saved bounds still use the shared
            // Canvas renderer once, when the draft is committed.
            layout.ensureLayout(for: container)
            let usedHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
            height = max(48 * scale, ceil(usedHeight + 12 * scale))
        }
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        if editor.frame != frame { editor.frame = frame }
    }

    /// Leaving a page retains an unsaved draft in the session, without leaving
    /// the old page's editor attached to the newly selected page.
    func suspendSemanticTextEditing() {
        guard let editor = semanticTextEditor else { return }
        preserveCurrentSemanticDraft()
        editor.isFinishing = true
        semanticTextEditor = nil
        editingSemanticObjectID = nil
        editingSemanticBaseline = nil
        editingSemanticIsInsertion = false
        editor.removeFromSuperview()
        needsDisplay = true
    }

    func preserveCurrentSemanticDraft() {
        guard let editor = semanticTextEditor, let baseline = editingSemanticBaseline else { return }
        let draft = CanvasSemanticTextDraft(baseline: baseline, text: editor.string, isInsertion: editingSemanticIsInsertion)
        onPreserveSemanticDraft(draft.key, editor.string == baseline.content?.text ? nil : draft)
    }

    func reconcileSemanticTextEditing(with objects: [CanvasSemanticObject]) {
        guard !editingSemanticIsInsertion, let editor = semanticTextEditor, !editor.isFinishing,
              let baseline = editingSemanticBaseline,
              let current = objects.first(where: { $0.id == baseline.id && $0.canvasID == baseline.canvasID }),
              current != baseline else { return }
        let contentChanged = current.payload != baseline.payload || current.kind != baseline.kind
            || current.payloadVersion != baseline.payloadVersion || current.boardGeneration != baseline.boardGeneration
        if contentChanged, editor.string != baseline.content?.text {
            preserveCurrentSemanticDraft()
            onSemanticTextConflict(CanvasReplicaKey(canvasID: baseline.canvasID, id: baseline.id))
            return
        }
        guard let text = current.content?.text else {
            suspendSemanticTextEditing()
            return
        }
        if contentChanged {
            editor.string = text
            editor.undoManager?.removeAllActions()
            // Neither step reports a text change, and chrome already read the
            // editor's history earlier in the update that brought this change.
            onEditingAvailabilityChange()
        }
        editingSemanticBaseline = current
    }
}
#endif
