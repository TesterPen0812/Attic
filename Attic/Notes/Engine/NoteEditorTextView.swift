import AppKit
import QuartzCore
import UniformTypeIdentifiers

/// The note text view: a stock TextKit 2 `NSTextView` with narrow hooks.
///
/// - Marks the entry points that are a person's own editing (typing, IME,
///   dictation, delete commands, cut, paste, drag), so the engine's object
///   guard can tell them from Find and Replace, Services and Writing Tools.
/// - Routes Undo and Redo to the engine's own history (`allowsUndo` is off).
/// - Announces an input-method composition that replaces a selection
///   before the storage changes, so its undo step knows the replaced text.
/// - Clicking a checkbox ticks it without moving the caret.
/// - Exposes objects to VoiceOver.
/// - Marks keystroke-to-commit for the performance trace.
final class NoteEditorTextView: NSTextView, NSAccessibilityCustomRotorItemSearchDelegate {
    weak var engine: NoteEditorEngine? {
        didSet {
            if engine !== oldValue { cancelCalloutIconSession(reason: "engine changed") }
            installCodeColouring()
        }
    }
    var calloutIconSession: NoteCalloutIconSession?

    func cancelCalloutIconSession(reason: String) { calloutIconSession?.cancel(reason: reason) }

    /// Page presentation restores the current input client. It must not
    /// replace the palette receiver with the note body during a handoff.
    func restoreInputFocus() {
        window?.makeFirstResponder(calloutIconSession?.receiver ?? self)
    }

    override var isEditable: Bool {
        didSet { if !isEditable { cancelCalloutIconSession(reason: "read only") } }
    }

    override func becomeFirstResponder() -> Bool {
        cancelCalloutIconSession(reason: "editor keyboard or accessibility entry")
        return super.becomeFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelCalloutIconSession(reason: "leaving window") }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidHide() {
        cancelCalloutIconSession(reason: "editor hidden")
        super.viewDidHide()
    }
    var marquee: NoteMarqueeSelection?

    /// TextKit lays the note's empty last line (its extra line) out with
    /// the typing attributes while the caret is on it, at whatever moment
    /// it lays the paragraph out, which can be before the editor gives the
    /// line its own attributes (Return, a click below the last block, a
    /// format picked). When they change there, the line is laid out again
    /// at once, so it never keeps a stale place (O18-04, K-02). Only then:
    /// one paragraph, never per keystroke on a typed line.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        didSet {
            guard let engine, let storage = textStorage, storage.length > 0, storage.editedMask.isEmpty,
                  selectedRange() == NSRange(location: storage.length, length: 0),
                  [0x0A, 0x2028].contains((storage.string as NSString).character(at: storage.length - 1)),
                  (oldValue[.paragraphStyle] as? NSParagraphStyle) != (typingAttributes[.paragraphStyle] as? NSParagraphStyle)
            else { return }
            engine.refreshEmptyLastLine()
        }
    }
    override var shouldDrawInsertionPoint: Bool { marquee?.isEmpty != false && super.shouldDrawInsertionPoint }
    var proseTextCompletionEnabled = false
    private(set) lazy var undoShim = NoteUndoManagerShim(textView: self)
    /// After each layout pass: the page keeps the title's accessories (the
    /// note menu button and the tag line) on the title's lines.
    var onLayout: (() -> Void)?
    /// A mouse selection is being made: AppKit's own tracking of a press in
    /// the text (a drag-select, with its autoscroll) runs until the button
    /// comes up. The selection bar waits it out (V-03), as Apple's apps do.
    var isTrackingMouseSelection = false {
        didSet { if isTrackingMouseSelection != oldValue { onMouseSelectionTracking?(isTrackingMouseSelection) } }
    }
    var onMouseSelectionTracking: ((Bool) -> Void)?
    /// Views laid over the text (the title's accessories), read by
    /// VoiceOver after the text.
    var accessoryViews: [NSView] = []
    private lazy var headingsRotor = NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self)
    private lazy var tablesRotor = NSAccessibilityCustomRotor(rotorType: .table, itemSearchDelegate: self)

    func installHeadingsRotor() { setAccessibilityCustomRotors([headingsRotor, tablesRotor]) }

    // MARK: Code stays out of spell checking

    /// Only the prose around code is checked: Mono lines and inline code are
    /// never sent (Codex's change, kept), and their marks are cleared as
    /// they are styled.
    override func checkText(in range: NSRange, types checkingTypes: NSTextCheckingTypes,
                            options: [NSSpellChecker.OptionKey: Any] = [:]) {
        guard let engine else { return super.checkText(in: range, types: checkingTypes, options: options) }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: engine.textStorage.length))
        var prose: [NSRange] = []
        engine.textStorage.enumerateAttributes(in: clamped) { attributes, part, _ in
            guard attributes[.noteBlockStyle] as? String != "mono", attributes[.noteMark(.code)] == nil else { return }
            if let last = prose.last, NSMaxRange(last) == part.location {
                prose[prose.count - 1] = NSUnionRange(last, part)
            } else { prose.append(part) }
        }
        for part in prose { super.checkText(in: part, types: checkingTypes, options: options) }
    }

    // MARK: A selected object shows its ring only (F-07)

    /// While a file or an image is selected, the system's selection
    /// highlight stays hidden: in a non-key panel TextKit draws its inactive
    /// grey line box behind the card whatever `selectedTextAttributes` say,
    /// a square block wider than the card's rounded ring.
    var hidesSelectionHighlight = false {
        didSet { if hidesSelectionHighlight != oldValue { applySelectionHighlightVisibility() } }
    }

    /// TextKit's selection layer (`_NSTextSelectionView`): the highlight's
    /// host, below the text. Found by class name, as AppKit names no API for it.
    var selectionHighlightViews: [NSView] {
        subviews.filter { NSStringFromClass(type(of: $0)).hasSuffix("TextSelectionView") }
    }

    private func applySelectionHighlightVisibility() {
        for view in selectionHighlightViews where view.alphaValue != (hidesSelectionHighlight ? 0 : 1) {
            view.alphaValue = hidesSelectionHighlight ? 0 : 1
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if hidesSelectionHighlight { applySelectionHighlightVisibility() }
    }

    // MARK: Syntax colours (R14)

    /// Code tokens draw in their syntax inks as TextKit rendering attributes,
    /// outside the note's marks and its Undo: each code fragment is coloured
    /// when TextKit validates it for display, from the engine's tokens for
    /// its block (one scan per block per edit, `codeTokenMemo`).
    private var codeColourEdits = 0
    private var codeTokenMemo: (block: NSRange, edits: Int, tokens: [(NSRange, NoteSyntaxToken)])?
    private var codeEditObserver: NSObjectProtocol?
    private var codeColourDesign: AtticDesignContext?
    private var codeColours: [NoteSyntaxToken: NSColor] = [:]

    private func installCodeColouring() {
        if let codeEditObserver { NotificationCenter.default.removeObserver(codeEditObserver) }
        codeEditObserver = nil
        codeTokenMemo = nil
        guard let engine, let layoutManager = textLayoutManager else { return }
        layoutManager.renderingAttributesValidator = { [weak self] manager, fragment in
            MainActor.assumeIsolated { self?.colourFragment(fragment, manager: manager) }
        }
        codeEditObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: engine.textStorage, queue: nil
        ) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            let edited = storage.editedRange
            MainActor.assumeIsolated { self?.codeTextEdited(edited) }
        }
    }

    /// An edit can change the tokens of every later line of its block (an
    /// opened comment or string): the block's colours are validated again.
    private func codeTextEdited(_ edited: NSRange) {
        codeColourEdits &+= 1
        guard let engine, edited.location != NSNotFound else { return }
        let location = min(edited.location, max(0, engine.textStorage.length - 1))
        guard engine.textStorage.length > 0, engine.paragraphStyle(at: location)?.isCode == true else { return }
        engine.afterStorageEdit { [weak self] current in
            guard let self, self.engine === current, let manager = self.textLayoutManager,
                  location < current.textStorage.length, current.paragraphStyle(at: location)?.isCode == true,
                  let range = current.textRange(for: current.blockRange(at: location)) else { return }
            manager.invalidateRenderingAttributes(for: range)
        }
    }

    private func syntaxColour(_ token: NoteSyntaxToken) -> NSColor? {
        guard let engine else { return nil }
        if codeColourDesign != engine.style.design {
            codeColourDesign = engine.style.design
            let tokens = engine.style.tokens
            codeColours = Dictionary(uniqueKeysWithValues: NoteSyntaxToken.allCases.compactMap { token in
                tokens.syntaxInk(token).map { (token, $0.nsColor) }
            })
        }
        return codeColours[token]
    }

    /// Each fragment's drawn colour: code in its syntax inks, a ticked
    /// checklist line in the secondary grey (T-06 B, owner 2026-10-15: one
    /// done style everywhere; the filled box stays). Rendering attributes
    /// only, so the note's text and its Undo never change.
    private func colourFragment(_ fragment: NSTextLayoutFragment, manager: NSTextLayoutManager) {
        if let dim = dragDimRange, let engine {
            let content = engine.contentStorage
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            if NSLocationInRange(start, dim) {
                manager.removeRenderingAttribute(.foregroundColor, for: fragment.rangeInElement)
                manager.addRenderingAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, for: fragment.rangeInElement)
                return
            }
        }
        if let block = fragment as? NoteBlockLayoutFragment, block.monoBlockRect != nil {
            colourCode(in: fragment, manager: manager)
        } else {
            colourChecklistLine(fragment, manager: manager)
        }
    }

    /// A dragged block's place (V-06): its text draws dimmed until the drop.
    var dragDimRange: NSRange? {
        didSet {
            guard dragDimRange != oldValue, let engine, let manager = textLayoutManager else { return }
            for range in [oldValue, dragDimRange].compactMap({ $0 }) {
                if let textRange = engine.textRange(for: range) { manager.invalidateRenderingAttributes(for: textRange) }
            }
            needsDisplay = true
        }
    }

    private func colourChecklistLine(_ fragment: NSTextLayoutFragment, manager: NSTextLayoutManager) {
        guard let engine else { return }
        let content = engine.contentStorage
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        guard start >= 0, start < engine.textStorage.length else { return }
        if engine.checklistBox(inParagraphAt: start)?.isChecked == true {
            manager.addRenderingAttribute(.foregroundColor, value: engine.style.checkedChecklistColor, for: fragment.rangeInElement)
        } else {
            manager.removeRenderingAttribute(.foregroundColor, for: fragment.rangeInElement)
        }
    }

    private func colourCode(in fragment: NSTextLayoutFragment, manager: NSTextLayoutManager) {
        guard let engine, let block = fragment as? NoteBlockLayoutFragment, block.monoBlockRect != nil else { return }
        let content = engine.contentStorage
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let end = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.endLocation)
        guard start >= 0, start < engine.textStorage.length, end > start else { return }
        let range = engine.blockRange(at: start)
        let tokens: [(NSRange, NoteSyntaxToken)]
        if let memo = codeTokenMemo, memo.block == range, memo.edits == codeColourEdits {
            tokens = memo.tokens
        } else {
            tokens = engine.codeTokens(in: NSRange(location: start, length: 0))
            codeTokenMemo = (range, codeColourEdits, tokens)
        }
        manager.removeRenderingAttribute(.foregroundColor, for: fragment.rangeInElement)
        // Tokens are in order: find the first that reaches this fragment.
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(tokens[mid].0) <= start { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < tokens.count, tokens[index].0.location < end {
            let (tokenRange, token) = tokens[index]
            index += 1
            let part = NSIntersectionRange(tokenRange, NSRange(location: start, length: end - start))
            guard part.length > 0, let colour = syntaxColour(token), let textRange = engine.textRange(for: part) else { continue }
            manager.addRenderingAttribute(.foregroundColor, value: colour, for: textRange)
        }
    }

    // MARK: The block handle (R14 D.2)

    /// The handle beside the block under the pointer (one at a time). It
    /// hides on typing (back on the next mouse move), during a selection
    /// drag, while a menu is open and on the title line.
    private(set) lazy var blockHandle: NoteBlockHandleView = {
        let handle = NoteBlockHandleView(frame: .zero)
        handle.isHidden = true
        handle.alphaValue = 0
        handle.onPress = { [weak self] event in self?.trackBlockHandle(with: event) }
        handle.onMove = { [weak self] up in self?.moveHandledBlock(up: up) ?? false }
        addSubview(handle)
        return handle
    }()
    /// A location in the block the handle belongs to.
    private(set) var handleBlockLocation: Int?
    private var handleHiddenForTyping = false
    private lazy var dropLine: NoteDropLineView = {
        let line = NoteDropLineView(frame: .zero)
        line.isHidden = true
        addSubview(line)
        return line
    }()

    /// The fragment under `point` (in this view), searched on the text
    /// column's line so the margin beside a block finds it too.
    private func fragment(nearViewPoint point: NSPoint) -> (NSTextLayoutFragment, Int)? {
        guard let engine, let layoutManager = textLayoutManager else { return nil }
        let origin = textContainerOrigin
        let width = textContainer?.size.width ?? bounds.width
        let containerPoint = CGPoint(x: min(max(point.x - origin.x, 1), max(1, width - 1)), y: point.y - origin.y)
        guard let fragment = layoutManager.textLayoutFragment(for: containerPoint) else { return nil }
        let content = engine.contentStorage
        let location = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        guard location >= 0, location < engine.textStorage.length else { return nil }
        return (fragment, location)
    }

    /// The block whose handle the pointer at `point` shows: over its lines
    /// or the margin beside them; never the title, a table (its own grips)
    /// or an empty note's end.
    func blockLocation(at point: NSPoint) -> Int? {
        guard let engine, let (fragment, location) = fragment(nearViewPoint: point) else { return nil }
        let frame = fragment.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard point.y >= frame.minY, point.y <= frame.maxY, point.x < frame.maxX + textContainerOrigin.x,
              location > engine.titleParagraphRange.length - 1, location >= engine.titleParagraphRange.length else { return nil }
        if engine.object(at: location) is NoteTableAttachment { return nil }
        return location
    }

    /// The first line of the block at `location`, in this view: its frame
    /// and the y of its cap-height middle (the handle's centre).
    private func firstLine(ofBlockAt location: Int) -> (frame: CGRect, centreY: CGFloat)? {
        guard let engine, let layoutManager = textLayoutManager,
              let range = engine.textRange(for: NSRange(location: location, length: 0)),
              let fragment = layoutManager.textLayoutFragment(for: range.location),
              let line = fragment.textLineFragments.first else { return nil }
        let origin = textContainerOrigin
        let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
        let font = engine.textStorage.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? engine.style.bodyFont
        let baseline = frame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        let capMiddle = engine.object(at: location) != nil && engine.isBlockObject(at: location)
            ? frame.minY + line.typographicBounds.midY : baseline - font.capHeight / 2
        return (frame, capMiddle)
    }

    func updateBlockHandle(at point: NSPoint?) {
        guard isEditable, let point, !handleHiddenForTyping, marquee?.isEmpty != false else { return hideBlockHandle() }
        if !blockHandle.isHidden, blockHandle.frame.contains(point) { return }
        guard let location = blockLocation(at: point) else { return hideBlockHandle() }
        showBlockHandle(forBlockAt: location)
    }

    func showBlockHandle(forBlockAt location: Int) {
        guard let engine else { return }
        let block = engine.blockRange(at: location)
        guard let line = firstLine(ofBlockAt: block.location) else { return hideBlockHandle() }
        let size = AtticNoteType.handleHitSize
        let frame = NSRect(x: textContainerOrigin.x - AtticNoteType.handleFromColumn - size.width / 2,
                           y: (line.centreY - size.height / 2).rounded(), width: size.width, height: size.height)
        blockHandle.ink = engine.style.tokens.tableGripDot.nsColor
        if blockHandle.frame != frame { blockHandle.frame = frame }
        let changed = handleBlockLocation.map { engine.blockRange(at: $0) } != block
        handleBlockLocation = block.location
        if blockHandle.isHidden || blockHandle.alphaValue < 1 {
            blockHandle.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AtticMotionScale.fast
                blockHandle.animator().alphaValue = 1
            }
            NSAccessibility.post(element: self, notification: .layoutChanged)
        } else if changed {
            blockHandle.needsDisplay = true
        }
    }

    func hideBlockHandle() {
        guard !blockHandle.isHidden else { return }
        handleBlockLocation = nil
        blockHandle.alphaValue = 0
        blockHandle.isHidden = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    #if DEBUG
    /// Capture seam: the hover chrome of the block at `location` (its
    /// handle, and Copy on a code block), as if the pointer were over it.
    func showHoverChrome(forBlockAt location: Int) {
        showBlockHandle(forBlockAt: location)
        blockHandle.alphaValue = 1
        if engine?.paragraphStyle(at: location)?.isCode == true {
            hoveredMonoLocation = location
            placeMonoCopy()
            pinsMonoCopy = true
        }
        pinsBlockHandle = true
        if let engine {
            let line = engine.lineRange(at: location).location
            if engine.headingControls[line] != nil {
                engine.setHoveredHeading(line)
                pinsHeadingHover = true
            }
        }
    }
    var pinsBlockHandle = false
    /// Capture seam: the hovered heading stays where the scene put it.
    var pinsHeadingHover = false
    #endif

    /// The block's rectangle in this view (its fragments' union).
    private func rect(ofBlock block: NSRange) -> CGRect? {
        guard let engine, let layoutManager = textLayoutManager, let range = engine.textRange(for: block) else { return nil }
        var union: CGRect?
        layoutManager.enumerateTextLayoutFragments(from: range.location, options: [.ensuresLayout]) { fragment in
            let start = engine.contentStorage.offset(from: engine.contentStorage.documentRange.location, to: fragment.rangeInElement.location)
            guard start < NSMaxRange(block) || (block.length == 0 && start == block.location) else { return false }
            var frame = fragment.layoutFragmentFrame
            if let box = fragment as? NoteBlockLayoutFragment, let mono = box.monoBlockRect ?? box.calloutBoxRect {
                frame = mono.offsetBy(dx: frame.minX, dy: frame.minY).union(CGRect(x: frame.minX, y: frame.minY + box.spacingBefore, width: frame.width, height: 0))
            } else if let paragraph = engine.textStorage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle {
                frame = CGRect(x: frame.minX, y: frame.minY + paragraph.paragraphSpacingBefore, width: frame.width,
                               height: max(0, frame.height - paragraph.paragraphSpacingBefore))
            }
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        return union.map { CGRect(x: 0, y: $0.minY, width: textContainer?.size.width ?? $0.width, height: $0.height)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y) }
    }

    /// Where a block dragged to `point` lands: before or after the block
    /// under it (never inside the dragged block itself), with its line.
    private func dropTarget(at point: NSPoint, moving source: NSRange) -> (NoteBlockDropPosition, CGRect)? {
        guard let engine, let (_, location) = fragment(nearViewPoint: point) else { return nil }
        guard location >= engine.titleParagraphRange.length else { return nil }
        let block = engine.blockRange(at: location)
        guard let rect = rect(ofBlock: block) else { return nil }
        let after = point.y > rect.midY
        guard NSIntersectionRange(block, source).length == 0, block.location != source.location,
              let position = engine.blockDropPosition(at: block.location, after: after),
              position.location != source.location, position.location != NSMaxRange(source),
              position.location > engine.titleParagraphRange.length - 1 else { return nil }
        // The line sits in the gap between the two blocks, at the drop's depth.
        let gapY: CGFloat
        if after {
            let below = position.location < engine.textStorage.length ? self.rect(ofBlock: engine.blockRange(at: position.location)) : nil
            gapY = below.map { (rect.maxY + $0.minY) / 2 } ?? rect.maxY + AtticNoteType.paragraphGap / 2
        } else {
            let above = block.location > engine.titleParagraphRange.length ? self.rect(ofBlock: engine.blockRange(at: block.location - 1)) : nil
            gapY = above.map { ($0.maxY + rect.minY) / 2 } ?? rect.minY - AtticNoteType.paragraphGap / 2
        }
        let indent = CGFloat(position.depth) * AtticNoteType.listLevelStep
        let width = (textContainer?.size.width ?? bounds.width) - indent
        let line = CGRect(x: textContainerOrigin.x + indent, y: gapY - AtticNoteType.dropLineThickness / 2,
                          width: max(0, width), height: AtticNoteType.dropLineThickness)
        return (position, line)
    }

    /// A click on the handle selects the block; a drag moves it (Esc or a
    /// drop where it started cancels; the move is one Undo step).
    ///
    /// V-06: the block lifts onto a card (the dropdowns' surface, so nothing
    /// shows through it) while its place in the text dims. The card hangs
    /// from the drop line, gliding from gap to gap, so the line runs along
    /// its top edge and never through its text; with no drop (over the
    /// block itself) it settles back over its source.
    private func trackBlockHandle(with event: NSEvent) {
        guard let engine, let window, let location = handleBlockLocation else { return }
        let source = engine.blockRange(at: location)
        guard let sourceRect = rect(ofBlock: source) else { return }
        let start = convert(event.locationInWindow, from: nil)
        var dragging = false
        var target: NoteBlockDropPosition?
        var lift: NoteDragLiftView?
        var dim: NoteBlockDragDim?
        NSCursor.closedHand.push()
        defer {
            NSCursor.pop()
            lift?.removeFromSuperview()
            dim?.restore()
            dropLine.isHidden = true
        }
        let animated = !engine.style.design.reduceMotion
        tracking: while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                                    until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            switch next.type {
            case .keyDown where next.keyCode == 53:
                return
            case .leftMouseDragged:
                let point = convert(next.locationInWindow, from: nil)
                if !dragging, hypot(point.x - start.x, point.y - start.y) > 3 {
                    dragging = true
                    lift = makeBlockLift(sourceRect)
                    dim = NoteBlockDragDim(textView: self, block: source, rect: sourceRect)
                    hideBlockHandle()
                }
                guard dragging, let card = lift else { continue }
                autoscroll(with: next)
                var frame = card.frame
                if let (position, line) = dropTarget(at: point, moving: source) {
                    target = position
                    dropLine.ink = engine.style.tokens.focusRing.nsColor
                    dropLine.frame = line
                    dropLine.isHidden = false
                    dropLine.needsDisplay = true
                    frame.origin.y = line.maxY + Self.liftGapBelowDropLine
                } else {
                    target = nil
                    dropLine.isHidden = true
                    frame.origin.y = sourceRect.minY - card.padding.height
                }
                card.move(to: frame, animated: animated)
            case .leftMouseUp:
                if dragging {
                    // Undimmed before the edit: the dim names the block's
                    // place as it was.
                    dim?.restore()
                    dim = nil
                    if let target { engine.moveBlock(source, to: target.location) }
                } else {
                    window.makeFirstResponder(self)
                    setSelectedRange(source)
                }
                break tracking
            default:
                break
            }
        }
    }

    /// The lifted card's top edge under the drop line.
    static let liftGapBelowDropLine: CGFloat = 3

    private func makeBlockLift(_ rect: CGRect) -> NoteDragLiftView? {
        guard let engine else { return nil }
        let image = NoteDragLiftView.snapshot(of: rect, in: self)
        let padding = CGSize(width: 6, height: 4)
        let card = NoteDragLiftView(snapshot: image, size: rect.size, padding: padding, tokens: engine.style.tokens)
        card.frame.origin = CGPoint(x: rect.minX - padding.width, y: rect.minY - padding.height)
        card.unregisterDraggedTypes()
        addSubview(card)
        return card
    }

    /// VoiceOver's Move Block Up / Down: past the block above or below.
    private func moveHandledBlock(up: Bool) -> Bool {
        guard let engine, let location = handleBlockLocation else { return false }
        let source = engine.blockRange(at: location)
        if up {
            guard source.location > engine.titleParagraphRange.length else { return false }
            let above = engine.blockRange(at: source.location - 1)
            guard above.location >= engine.titleParagraphRange.length else { return false }
            return engine.moveBlock(source, to: above.location)
        }
        guard NSMaxRange(source) < engine.textStorage.length else { return false }
        let below = engine.blockRange(at: NSMaxRange(source))
        return engine.moveBlock(source, to: NSMaxRange(below))
    }

    // MARK: A block at the note's end

    private var isSizingForTrailingBlock = false

    /// AppKit sizes the text view to its last line, without the bottom
    /// padding a block at the note's end keeps below that line (a code
    /// block, a callout, an empty last line's box): the view is made tall
    /// enough for the block's whole fragment and what it paints (O18-01).
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if isVerticallyResizable, !isSizingForTrailingBlock, let engine {
            isSizingForTrailingBlock = true
            if let bottom = engine.trailingBlockBottom() {
                size.height = max(size.height, ceil(bottom + textContainerOrigin.y + textContainerInset.height))
            }
            isSizingForTrailingBlock = false
        }
        super.setFrameSize(size)
    }

    // MARK: Copy on a Mono block

    /// The Mono block's Copy, shown while the pointer is over a block.
    private(set) lazy var monoCopyButton: NoteMonoCopyButton = {
        let button = NoteMonoCopyButton(frame: .zero)
        button.isHidden = true
        button.onCopy = { [weak self] in self?.copyHoveredMonoBlock() }
        addSubview(button)
        return button
    }()
    /// A location inside the block the Copy belongs to.
    private(set) var monoCopyLocation: Int?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        handleHiddenForTyping = false
        #if DEBUG
        if !pinsBlockHandle { updateBlockHandle(at: convert(event.locationInWindow, from: nil)) }
        #else
        updateBlockHandle(at: convert(event.locationInWindow, from: nil))
        #endif
        updateMonoCopy(at: convert(event.locationInWindow, from: nil))
        updateHeadingHover(at: convert(event.locationInWindow, from: nil))
        hostedCursor(atWindowPoint: event.locationInWindow)?.set()
    }

    /// T-09 C: the pointer anywhere on a heading's line (its chevron
    /// included) shows that heading's fold chevron.
    func updateHeadingHover(at point: NSPoint?) {
        guard let engine else { return }
        #if DEBUG
        if pinsHeadingHover { return }
        #endif
        engine.setHoveredHeading(point.flatMap(headingOffset(at:)))
    }

    private func headingOffset(at point: NSPoint) -> Int? {
        guard let engine else { return nil }
        if let hit = engine.headingControls.first(where: { $0.value.frame.contains(point) }) { return hit.key }
        // The whole line's band, margins included: a fragment's frame may
        // be only as wide as its text.
        guard let (fragment, location) = fragment(nearViewPoint: point) else { return nil }
        let frame = fragment.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard point.y >= frame.minY, point.y <= frame.maxY else { return nil }
        let line = engine.lineRange(at: location).location
        return engine.headingControls[line] != nil ? line : nil
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        hostedCursor(atWindowPoint: event.locationInWindow)?.set()
    }

    private func hostedCursor(atWindowPoint point: CGPoint) -> NSCursor? {
        var target = super.hitTest(convert(point, from: nil))
        while let view = target, view !== self {
            if let control = view as? AtticNoteTableControlView { return control.hoverCursor }
            if view is NoteResizeHandleView { return NSCursor.frameResize(position: .bottomRight, directions: .all) }
            if view is NoteMonoCopyButton { return .arrow }
            if view is NoteBlockHandleView { return .openHand }
            if let table = view as? NoteTableView { return table.edgeCursor(atWindowPoint: point) }
            target = view.superview
        }
        let local = convert(point, from: nil)
        if isEditable, checkboxLocation(at: local) != nil { return .arrow }
        let index = characterIndexForInsertion(at: local)
        if let engine {
            for location in [index, max(0, index - 1)] {
                if let object = engine.object(at: location),
                   object is NoteImageAttachment || object is NoteFileAttachment,
                   let rect = engine.rect(for: NSRange(location: location, length: 1)), rect.contains(local) {
                    return .arrow
                }
            }
        }
        if !isEditable {
            // Insertion indices also resolve in the blank margin. Only the
            // linked glyph itself is a link target; check both sides of a caret.
            if let storage = textStorage, let engine {
                for location in [index, max(0, index - 1)] where location < storage.length {
                    if storage.attribute(.link, at: location, effectiveRange: nil) != nil {
                        let range = (storage.string as NSString).rangeOfComposedCharacterSequence(at: location)
                        if let rect = engine.rect(for: range), rect.contains(local) { return .pointingHand }
                    }
                }
            }
            return .arrow
        }
        return nil
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        #if DEBUG
        if !pinsBlockHandle { hideBlockHandle() }
        #else
        hideBlockHandle()
        #endif
        updateMonoCopy(at: nil)
        updateHeadingHover(at: nil)
    }

    #if DEBUG
    /// Capture seam: Copy stays where the scene put it, whatever the pointer does.
    var pinsMonoCopy = false
    #endif

    /// The block the pointer is over (nil: none).
    private var hoveredMonoLocation: Int?

    /// Shows Copy on the block under `point` (hides it elsewhere, unless
    /// the caret keeps it on its own block).
    func updateMonoCopy(at point: NSPoint?) {
        #if DEBUG
        if pinsMonoCopy, !monoCopyButton.isHidden { return }
        #endif
        // The chip rises above the block: the pointer reaching it is still
        // on the block's Copy.
        if let point, !monoCopyButton.isHidden, monoCopyButton.frame.contains(point) { return }
        hoveredMonoLocation = point.flatMap { engine?.monoBlock(at: $0)?.location }
        placeMonoCopy()
    }

    /// The block the caret is in, while the keyboard is in the text (Copy
    /// then shows for the keyboard and for VoiceOver).
    private var caretMonoLocation: Int? {
        guard let engine, window?.firstResponder === self else { return nil }
        let length = engine.textStorage.length
        guard length > 0 else { return nil }
        var probe = selectedRange().location
        if probe >= length {
            // At the note's end: still in the block on its last code line,
            // not on the empty line after it.
            probe = length - 1
            if (engine.textStorage.string as NSString).character(at: probe) == 0x0A { return nil }
        }
        return engine.paragraphStyle(at: probe)?.isCode == true ? probe : nil
    }

    private var monoCopyPlacementScheduled = false

    /// The caret is AppKit's own; this only hides it under a marquee (O18-03).
    private(set) lazy var caretVisibility = NoteCaretVisibility(textView: self)

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        caretVisibility.refresh()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if marquee?.isSettingNativeSelection == false { marquee?.clear() }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        caretVisibility.refresh()
        guard engine != nil, !stillSelecting else { return }
        // After the text system has finished with this change (placing
        // Copy reads the block's layout).
        guard !monoCopyPlacementScheduled else { return }
        monoCopyPlacementScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.monoCopyPlacementScheduled = false
            self?.placeMonoCopy()
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.placeMonoCopy() } }
        return resigned
    }

    /// Puts Copy on the hovered block, else the caret's, else hides it.
    /// Its chip is opaque in the block's own fill, inside the corner.
    func placeMonoCopy() {
        #if DEBUG
        if pinsMonoCopy, !monoCopyButton.isHidden { return }
        #endif
        guard let engine, let location = hoveredMonoLocation ?? caretMonoLocation,
              let range = engine.monoBlockRange(at: location), let rect = engine.monoBlockRect(for: range) else {
            if monoCopyLocation != nil || !monoCopyButton.isHidden {
                monoCopyLocation = nil
                monoCopyButton.isHidden = true
                NSAccessibility.post(element: self, notification: .layoutChanged)
            }
            return
        }
        let style = engine.style
        let tokens = style.tokens
        let blockFill = tokens.recessed.over(tokens.panel.base.withAlpha(1))
        monoCopyButton.fill = blockFill.nsColor
        monoCopyButton.hoverFill = tokens.chipHover.over(blockFill).nsColor
        monoCopyButton.ink = style.secondaryColor
        let origin = textContainerOrigin
        let size = NoteMonoCopyButton.size, inset = AtticNoteType.monoCopyInset
        let frame = NSRect(x: origin.x + rect.maxX - inset - size, y: origin.y + rect.minY + AtticNoteType.monoCopyTop,
                           width: size, height: size)
        if monoCopyButton.frame != frame { monoCopyButton.frame = frame }
        let wasHidden = monoCopyButton.isHidden
        monoCopyLocation = location
        monoCopyButton.isHidden = false
        if wasHidden { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    /// Where Copy puts the block's text (a test uses its own pasteboard).
    var copyPasteboard: NSPasteboard = .general

    private func copyHoveredMonoBlock() {
        guard let engine, let location = monoCopyLocation, let text = engine.monoBlockText(at: location) else { return }
        let pasteboard = copyPasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor parameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let engine else { return nil }
        if rotor.type == .table {
            // The note's tables, in order (each one's hosted view).
            let tables = engine.tableViews()
            let current = parameters.currentItem?.targetElement as? NoteTableView
            let index = current.flatMap { view in tables.firstIndex { $0 === view } }
            let next: NoteTableView?
            if parameters.searchDirection == .next {
                next = index.map { $0 + 1 < tables.count ? tables[$0 + 1] : nil } ?? tables.first
            } else {
                next = index.map { $0 > 0 ? tables[$0 - 1] : nil } ?? tables.last
            }
            guard let next else { return nil }
            let result = NSAccessibilityCustomRotor.ItemResult(targetElement: next)
            result.customLabel = next.accessibilityLabel() ?? ""
            return result
        }
        let headings = engine.headingRanges()
        let current = parameters.currentItem?.targetRange.location ?? (parameters.searchDirection == .next ? -1 : Int.max)
        let candidate = parameters.searchDirection == .next
            ? headings.first(where: { $0.range.location > current && ($0.text.localizedStandardContains(parameters.filterString) || parameters.filterString.isEmpty) })
            : headings.reversed().first(where: { $0.range.location < current && ($0.text.localizedStandardContains(parameters.filterString) || parameters.filterString.isEmpty) })
        guard let candidate else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = candidate.range
        result.customLabel = candidate.text
        return result
    }

    // MARK: A person's own editing

    private func asUserEdit<T>(_ body: () -> T) -> T {
        engine?.userEditDepth += 1
        defer { engine?.userEditDepth -= 1 }
        return body()
    }

    override func keyDown(with event: NSEvent) {
        handleHiddenForTyping = true
        hideBlockHandle()
        if marquee?.isEmpty == false {
            if event.keyCode == 51 || event.keyCode == 117 { _ = marquee?.delete(); return }
            if event.keyCode == 53 { marquee?.clear(); return }
            if !event.modifierFlags.contains(.command) { marquee?.clear() }
        }
        engine?.updateTextChecking()
        if engine?.find.handleKey(event) == true { return }
        if let engine, selectedRange().length == 1,
           let object = engine.object(at: selectedRange().location),
           object is NoteImageAttachment || object is NoteFileAttachment {
            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if flags.isEmpty, event.charactersIgnoringModifiers == " " {
                Task { await engine.perform(.quickLook, objectID: object.objectID) }
                return
            }
        }
        if engine?.handleShortcut(event) == true { return }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if flags == [.command, .option, .shift], event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteAsPlainText(nil)
            return
        }
        let typing = event.charactersIgnoringModifiers?.isEmpty == false
            && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control)
        guard typing else { return asUserEdit { super.keyDown(with: event) } }
        // Keystroke to the commit of the frame that shows it: TextKit 2 draws
        // text in layout-fragment layers, so the end marker is the Core
        // Animation commit that carries the change, not a view draw call.
        PerformanceSignposts.beginNoteKey()
        CATransaction.begin()
        CATransaction.setCompletionBlock { PerformanceSignposts.noteDidDraw() }
        asUserEdit { super.keyDown(with: event) }
        CATransaction.commit()
    }

    /// Keystroke-to-layout end marker. The macOS 26 SDK does not expose
    /// NSTextView's viewport-controller delegate method for overriding, so
    /// the marker closes after the view's own layout or pre-draw pass,
    /// where TextKit 2 lays out the viewport.
    override func layout() {
        // The accessories and overlays placed from here move at once but
        // join or leave a parent only after this pass (P1-01 hypothesis).
        AtticOverlayHierarchy.layoutPass {
            super.layout()
            if hidesSelectionHighlight { applySelectionHighlightVisibility() }
            marquee?.layoutChanged()
            engine?.refreshViewportImages()
            PerformanceSignposts.noteDidLayout()
            updatePlaceholder()
            engine?.updateHeadingControls()
            onLayout?()
        }
        caretVisibility.refresh()
        if revealsCaretAfterLayout {
            revealsCaretAfterLayout = false
            revealCaretClearOfBands()
        }
    }

    // MARK: The caret's line in view (V-02)

    private var revealsCaretAfterLayout = false

    /// After an edit or a format picked here, the caret's line is brought
    /// into view clear of the floating controls once the edit is laid out
    /// (the note may only grow then).
    func revealCaretAfterLayout() {
        guard window?.firstResponder === self else { return }
        // Now, and again after the next layout pass AppKit runs anyway
        // (no extra pass is asked for: typing costs nothing more).
        revealsCaretAfterLayout = true
        revealCaretClearOfBands()
    }

    /// V-02 (owner recording, 10-17): content runs under the floating
    /// controls (10-17), so the scroll view's content insets cover them,
    /// and the clip view counts what is under them as visible. The line
    /// being typed on is scrolled to clear them: above the bottom row,
    /// below the header. The insets are the bands; nothing fades.
    func revealCaretClearOfBands() {
        guard let engine, let scroll = enclosingScrollView, selectedRange().length == 0,
              let rect = engine.caretRect(at: selectedRange().location) else { return }
        let clip = scroll.contentView
        let insets = scroll.contentInsets
        let visible = convert(clip.bounds, from: clip)
        let low = visible.maxY - insets.bottom, high = visible.minY + insets.top
        let shift = rect.maxY > low ? rect.maxY - low : (rect.minY < high ? rect.minY - high : 0)
        guard abs(shift) > 0.5 else { return }
        var bounds = clip.bounds
        bounds.origin.y += clip.isFlipped == isFlipped ? shift : -shift
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: The title's placeholder

    /// "Title" is drawn by this view itself, on its own layer. TextKit 2
    /// draws the text in separate fragment views and the caret in its own
    /// view, so an edit never asks this view to draw again (CU P2-01: the
    /// first title typed or pasted into a new note was drawn over the stale
    /// "Title" until the editor was rebuilt). Whenever the placeholder comes
    /// or goes, its whole line is redrawn here.
    private var drawsPlaceholder = false

    private var showsPlaceholder: Bool {
        guard let engine else { return false }
        return engine.textStorage.length == 0 && !hasMarkedText()
    }

    /// The placeholder's line, the column's full width.
    var placeholderRect: NSRect {
        let height = max(NoteTextStyle.titleLineHeight, ceil((engine?.style.titleFont).map { $0.ascender - $0.descender } ?? 0))
        return NSRect(x: 0, y: textContainerOrigin.y, width: bounds.width, height: height + 4)
    }

    /// Redraws the placeholder's line when it comes or goes. Cheap: one
    /// comparison per edit, layout pass and composition change.
    func updatePlaceholder() {
        let shows = showsPlaceholder
        guard shows != drawsPlaceholder else { return }
        drawsPlaceholder = shows
        setNeedsDisplay(placeholderRect)
    }

    override func didChangeText() {
        super.didChangeText()
        updatePlaceholder()
        revealCaretAfterLayout()
    }

    override func unmarkText() {
        super.unmarkText()
        updatePlaceholder()
    }

    /// "Title" on a new note's empty first line.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawsPlaceholder = showsPlaceholder
        guard drawsPlaceholder, let engine else { return }
        let origin = textContainerOrigin
        let placeholder = NSAttributedString(string: String(localized: "Title"), attributes: [
            .font: engine.style.titleFont,
            .foregroundColor: engine.style.placeholderColor
        ])
        placeholder.draw(at: NSPoint(x: origin.x + (textContainer?.lineFragmentPadding ?? 0), y: origin.y))
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        marquee?.layoutChanged()
        engine?.updateHeadingControls()
        engine?.refreshViewportImages()
        PerformanceSignposts.noteDidLayout()
    }

    /// TextKit's attachment-adjacent caret can be shorter than the glyph
    /// line. Reveal both, so typing after a block clears the footer inset.
    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        guard let engine, range.location != NSNotFound, range.length == 0,
              range.location > 0, range.location <= engine.textStorage.length,
              (engine.textStorage.string as NSString).character(at: range.location - 1) != 0x0A,
              let glyph = engine.rect(for: NSRange(location: range.location - 1, length: 1)) else { return }
        let rect = engine.caretRect(at: range.location).map { $0.union(glyph) } ?? glyph
        scrollToVisible(rect)
    }

    /// A palette request has its own input client. Unexpected body input
    /// fails closed, without routing anything to the note or the callout.
    private func refusesUnexpectedCalloutInput() -> Bool {
        guard let session = calloutIconSession, session.state != .ended else { return false }
        NSLog("Callout icon input refused unexpected note-body delivery (session %@)", session.id.uuidString)
        return true
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if refusesUnexpectedCalloutInput() { return }
        let generation = engine?.history.recordingGeneration
        defer { engine?.history.completeSelection(since: generation) }
        guard let engine, !engine.isWritingToolsSessionActive else {
            return super.insertText(string, replacementRange: replacementRange)
        }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        // A typed Space after `#word` in the title takes the tag (the space
        // itself is not inserted). A paste never reaches here.
        if text == " ", !hasMarkedText(), range == selectedRange(), engine.takeTitleHashtag() { return }
        let wrap = hasMarkedText() ? (before: false, after: false) : engine.adjustedInsertion(text, at: range)
        var payload: Any = string
        if wrap.before || wrap.after {
            let attributed = (string as? NSAttributedString).map(NSMutableAttributedString.init(attributedString:))
                ?? NSMutableAttributedString(string: text, attributes: typingAttributes)
            if wrap.before { attributed.insert(NSAttributedString(string: "\n", attributes: typingAttributes), at: 0) }
            if wrap.after { attributed.append(NSAttributedString(string: "\n", attributes: typingAttributes)) }
            payload = attributed
        }
        let wasComposing = hasMarkedText()
        asUserEdit { super.insertText(payload, replacementRange: replacementRange) }
        if wrap.after {
            setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        }
        if !wasComposing, wrap.before == false, wrap.after == false {
            engine.handleTypedText(text, wasComposing: wasComposing)
        }
        scrollRangeToVisible(selectedRange())
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if refusesUnexpectedCalloutInput() { return }
        if !hasMarkedText() {
            let replaced = replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange
            engine?.history.beginComposition(replacing: replaced)
        }
        asUserEdit { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange) }
        updatePlaceholder()
    }

    /// A list the keys reach first (the title's tag suggestions): ↑ ↓,
    /// Return, Tab and Esc go to it while it shows.
    var suggestionCommand: ((Selector) -> Bool)?

    override func doCommand(by selector: Selector) {
        if !hasMarkedText(), suggestionCommand?(selector) == true { return }
        if !hasMarkedText(), let engine {
            // OD-7: in the title Tab moves to the body; in the body it
            // indents (Apple Notes and Pages); ⌃Tab leaves the editor
            // (`NoteFormatControls.handleKey`).
            if selector == #selector(insertTab(_:)), engine.moveFromTitleToBody() { return }
            if selector == #selector(insertTab(_:)), engine.perform(.indent) { return }
            if selector == #selector(insertBacktab(_:)), engine.perform(.outdent) { return }
            // An arrow that lands on a table's line goes into the table.
            let moves = [#selector(moveDown(_:)), #selector(moveUp(_:)), #selector(moveLeft(_:)), #selector(moveRight(_:)),
                         #selector(moveForward(_:)), #selector(moveBackward(_:))]
            if moves.contains(selector), !engine.tableViews().isEmpty {
                let old = selectedRange()
                let x = engine.caretRect(at: old.length == 0 ? old.location : NSMaxRange(old))?.minX
                asUserEdit { super.doCommand(by: selector) }
                _ = engine.enterTableAfterMove(selector, from: old, x: x)
                return
            }
        }
        asUserEdit { super.doCommand(by: selector) }
    }

    override func insertNewline(_ sender: Any?) {
        // Return on a selected table goes into its first cell.
        if let engine, !hasMarkedText(), selectedRange().length == 1,
           let table = engine.tableAttachment(at: selectedRange().location) {
            engine.enterTable(table, at: NoteTable.Position(row: 0, column: 0), caret: .end)
            return
        }
        // Return after `#word` in the title takes the tag, then moves on.
        if !hasMarkedText() { engine?.takeTitleHashtag() }
        if engine?.handleNewline() == true { return }
        asUserEdit { super.insertNewline(sender) }
    }

    override func deleteBackward(_ sender: Any?) {
        if marquee?.isEmpty == false { _ = marquee?.delete(); return }
        if let engine, selectedRange().length == 1,
           let object = engine.object(at: selectedRange().location),
           object is NoteImageAttachment || object is NoteFileAttachment {
            Task { await engine.perform(.delete, objectID: object.objectID) }
            return
        }
        if engine?.handleDeleteBackward() == true { return }
        asUserEdit { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        if marquee?.isEmpty == false { _ = marquee?.delete(); return }
        if engine?.handleDeleteForward() == true { return }
        asUserEdit { super.deleteForward(sender) }
    }

    /// Where Esc goes when the note has nothing left to close (the panel
    /// hides). Tests set it; in the panel it is the window's own route.
    var escapeFallback: (() -> Void)?

    /// The Esc chain from the note (UX plan § 4.9): an input-method
    /// composition keeps Esc; the tag suggestions (handled before this, in
    /// `doCommand`) close; `#word` in the title stays text; the Find bar
    /// closes; then, with nothing left to close, the panel hides. The text
    /// view's own completion list is not used in notes.
    override func cancelOperation(_ sender: Any?) {
        if let session = calloutIconSession {
            session.cancel(reason: "editor Escape", returnFocus: true)
            return
        }
        if marquee?.isEmpty == false { marquee?.clear(); return }
        // NSTextView has no cancelOperation of its own (calling super would
        // raise): what it doesn't take goes up the responder chain.
        guard engine != nil else { return passEscapeOn(sender) }
        // The input method owns Esc during a composition.
        if hasMarkedText() { return }
        if engine?.slashSession != nil { engine?.dismissSlashSession(); return }
        if engine?.pendingSlashDate != nil { engine?.cancelSlashDate(); return }
        if engine?.keepTitleHashtagLiteral() == true { return }
        if let scrollView = enclosingScrollView, scrollView.isFindBarVisible {
            let hide = NSMenuItem()
            hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
            performTextFinderAction(hide)
            window?.makeFirstResponder(self)
            return
        }
        if let escapeFallback { return escapeFallback() }
        if let panel = window as? AtticPanel, let hide = panel.onUnhandledEscape { return hide() }
        passEscapeOn(sender)
    }

    private func passEscapeOn(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
    }

    override func cut(_ sender: Any?) {
        if marquee?.isEmpty == false {
            if isEditable, marquee?.copy(to: .general) == true { _ = marquee?.delete() }
            return
        }
        asUserEdit { super.cut(sender) }
    }
    override func delete(_ sender: Any?) {
        if marquee?.isEmpty == false { _ = marquee?.delete(); return }
        if let engine, selectedRange().length == 1,
           let object = engine.object(at: selectedRange().location),
           object is NoteImageAttachment || object is NoteFileAttachment {
            Task { await engine.perform(.delete, objectID: object.objectID) }
            return
        }
        asUserEdit { super.delete(sender) }
    }
    override func copy(_ sender: Any?) {
        if marquee?.isEmpty == false { _ = marquee?.copy(to: .general); return }
        if let engine, selectedRange().length == 1,
           let object = engine.object(at: selectedRange().location),
           object is NoteImageAttachment || object is NoteFileAttachment {
            let command: NoteObjectCommand = object is NoteImageAttachment ? .copyImage : .copyFile
            Task { await engine.perform(command, objectID: object.objectID) }
            return
        }
        super.copy(sender)
    }
    @objc func printNote(_ sender: Any?) {
        guard let engine else { return }
        Task { _ = await engine.printNote() }
    }

    /// File › Print… (⌘P in the menu bar) prints the note as the engine
    /// lays it out for paper, never this view's own drawing.
    override func printView(_ sender: Any?) {
        guard engine != nil else { return super.printView(sender) }
        printNote(sender)
    }
    override func paste(_ sender: Any?) {
        if refusesUnexpectedCalloutInput() { return }
        if engine?.handlePaste(.general) == true { return }
        asUserEdit { super.paste(sender) }
    }
    override func pasteAsPlainText(_ sender: Any?) {
        if refusesUnexpectedCalloutInput() { return }
        engine?.isPastingAsPlainText = true
        defer { engine?.isPastingAsPlainText = false }
        asUserEdit { super.pasteAsPlainText(sender) }
    }

    // MARK: Files dragged in (the page's object controls)

    /// The drop line, the carry card and the drop's block boundary belong
    /// to the object controls; everything else is the text view's own.
    weak var objectInteraction: NoteObjectInteraction?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let operation = objectInteraction?.fileDragUpdated(sender, entered: true) { return operation }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let operation = objectInteraction?.fileDragUpdated(sender, entered: false) { return operation }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        objectInteraction?.fileDragEnded()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        objectInteraction?.fileDragEnded()
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if objectInteraction?.isFileDrag(sender) == true { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let handled = objectInteraction?.performFileDrop(sender) { return handled }
        let isSelfMove = (sender.draggingSource as AnyObject?) === self
            && sender.draggingSourceOperationMask.contains(.move)
        engine?.isPerformingSelfMove = isSelfMove
        engine?.history.beginGroup()
        defer {
            engine?.history.endGroup()
            engine?.isPerformingSelfMove = false
        }
        return asUserEdit { super.performDragOperation(sender) }
    }

    // MARK: Pasteboard

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        engine == nil ? super.writablePasteboardTypes : [NoteEditorEngine.fragmentType, .rtf, .string, TasksTextExport.markdownType]
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        if marquee?.isEmpty == false { return marquee?.copy(to: pboard) ?? false }
        guard let engine else { return super.writeSelection(to: pboard, types: types) }
        return engine.writeSelection(selectedRange(), to: pboard, types: types)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [NoteEditorEngine.fragmentType, NoteTablePaste.tableType, .fileURL, .png, .tiff, .rtf, .html, .string]
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let engine else { return super.readSelection(from: pboard, type: type) }
        let target = rangeForUserTextChange
        guard target.location != NSNotFound else { return false }
        if type == NoteEditorEngine.fragmentType, let data = pboard.data(forType: type) {
            if engine.isPerformingSelfMove { return engine.paste(fragmentData: data, at: target) }
            // The private type owns this paste even if verification refuses it:
            // AppKit must not fall back to plain text and flatten its objects.
            Task { @MainActor [weak self, weak engine] in
                guard let self, let engine, self.engine === engine, self.rangeForUserTextChange == target else { return }
                _ = await engine.pasteDurably(fragmentData: data, at: target)
            }
            return true
        }
        // Tabular data (cells copied from a table, a spreadsheet, a web
        // page's table, a Markdown table) pastes as a table.
        if !engine.isPastingAsPlainText, [NoteTablePaste.tableType, .rtf, .html, .string].contains(type) || type == NoteTablePaste.tsvType {
            var oversized = false
            if let table = NoteTablePaste.table(from: pboard, onOversized: { oversized = true }) {
                let source = pboard.string(forType: NoteTablePaste.tsvType) ?? pboard.string(forType: .string) ?? NoteTableText.tsv(table)
                return engine.pasteTable(table, at: target, sourceText: source)
            }
            if oversized {
                let source = pboard.string(forType: NoteTablePaste.tsvType) ?? pboard.string(forType: .string)
                    ?? pboard.string(forType: .html).map(NoteTablePaste.plainText(fromHTML:)) ?? ""
                return engine.pasteOversizedTableAsText(source, at: target)
            }
        }
        if type == .fileURL,
           let urls = pboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            engine.onFileBatchRequest?(urls, pboard.string(forType: .string) ?? "", target)
            return engine.onFileBatchRequest != nil
        }
        if (type == .png || type == .tiff), let data = pboard.data(forType: type) {
            engine.onRawImageBatchRequest?(data, type == .png ? "png" : "tiff", target)
            return engine.onRawImageBatchRequest != nil
        }
        if (type == .rtf || type == .html), let data = pboard.data(forType: type) {
            return engine.pasteRichText(data, type: type, at: target)
        }
        if let text = pboard.string(forType: .string) {
            return engine.pastePlainText(text, at: target)
        }
        return false
    }

    // MARK: Undo route (editor-owned)

    override var undoManager: UndoManager? { engine == nil ? super.undoManager : undoShim }

    @objc func undo(_ sender: Any?) {
        guard let engine, !hasMarkedText() else { return }
        engine.undoCommand()
    }

    @objc func redo(_ sender: Any?) {
        guard let engine, !hasMarkedText() else { return }
        engine.redoCommand()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if marquee?.isEmpty == false {
            if item.action == #selector(copy(_:)) { return true }
            if item.action == #selector(cut(_:)) || item.action == #selector(delete(_:)) { return isEditable }
        }
        if let engine {
            if item.action == #selector(undo(_:)) {
                let name = engine.undoCommandName
                (item as? NSMenuItem)?.title = name.isEmpty ? String(localized: "Undo") : String(localized: "Undo \(name)")
                return isEditable && engine.canUndoCommand
            }
            if item.action == #selector(redo(_:)) {
                let name = engine.redoCommandName
                (item as? NSMenuItem)?.title = name.isEmpty ? String(localized: "Redo") : String(localized: "Redo \(name)")
                return isEditable && engine.canRedoCommand
            }
        }
        return super.validateUserInterfaceItem(item)
    }

    /// O14-01: one click on a panel that is not key both makes it key and
    /// places the caret (or ticks a box) here (`AtticPanel.acceptsEveryFirstMouse`).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        AtticPanel.acceptsEveryFirstMouse(in: window) || super.acceptsFirstMouse(for: event)
    }

    // MARK: Checkbox clicks

    override func mouseDown(with event: NSEvent) {
        calloutIconSession?.cancel(reason: "editor mouse down", returnFocus: true)
        guard let engine else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            let index = characterIndexForInsertion(at: point)
            for location in [index, max(0, index - 1)] {
                guard let object = engine.object(at: location),
                      object is NoteImageAttachment || object is NoteFileAttachment else { continue }
                setSelectedRange(NSRange(location: location, length: 1))
                Task { await engine.perform(.quickLook, objectID: object.objectID) }
                return
            }
        }
        // An image or a file: a click selects it, or runs the action drawn
        // under the pointer (the page's object controls).
        if objectInteraction?.handleMouseDown(event) == true { return }
        guard isEditable else { return super.mouseDown(with: event) }
        if let location = checkboxLocation(at: point) {
            engine.toggleCheckbox(atLineOf: location)
            return
        }
        // R14: a code block's label opens its language menu; a callout's
        // emoji opens its icon menu.
        if let (location, rect) = codeLabel(at: point) {
            showLanguageMenu(forBlockAt: location, below: rect)
            return
        }
        if let (location, rect) = calloutIcon(at: point) {
            showCalloutIconMenu(forBlockAt: location, below: rect)
            return
        }
        // A click below the final block starts a new line there (D.1 #15,
        // O17-08). The page's marquee takes such clicks first while it is
        // on (`NoteMarqueeSelection`); this covers the rest.
        if event.clickCount == 1, point.y > finalTextBottom(), engine.startLineBelowFinalBlock() { return }
        hideBlockHandle()
        // AppKit tracks the press until the button comes up.
        isTrackingMouseSelection = true
        defer { isTrackingMouseSelection = false }
        super.mouseDown(with: event)
        settleCaretBesideObject(clickedAt: point)
    }

    /// K-03 (owner recording, 10-17): a click beside a table, image or file
    /// (in the gap above it, or past its side) puts the caret on the nearest
    /// text line, never on the object's own line, where AppKit's caret is
    /// the object's whole height (a 124 pt bar down a table's edge). Above
    /// the object's middle: the end of the line above; below: the start of
    /// the line after. The caret stays AppKit's own (O18-03); only where it
    /// goes changes. Keyboard moves are left alone.
    func settleCaretBesideObject(clickedAt point: NSPoint) {
        guard let engine, let storage = textStorage else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        let string = storage.string as NSString
        var object = selection.location
        if !(object < string.length && engine.isBlockObject(at: object)) {
            object = selection.location - 1
            guard object >= 0, object < string.length, engine.isBlockObject(at: object),
                  selection.location == string.length || string.character(at: selection.location) == 0x0A else { return }
        }
        guard !(engine.object(at: object) is NoteDividerAttachment),
              let rect = engine.rect(for: NSRange(location: object, length: 1)) else { return }
        let line = engine.lineRange(at: object)
        if point.y < rect.midY, line.location > 0 {
            setSelectedRange(NSRange(location: line.location - 1, length: 0))
        } else if NSMaxRange(line) < string.length {
            setSelectedRange(NSRange(location: NSMaxRange(line) + (string.character(at: NSMaxRange(line)) == 0x0A ? 1 : 0), length: 0))
        }
    }

    // MARK: Code language and callout icon menus (R14)

    /// The bottom of the note's last line box, in this view (a box's
    /// bottom padding included).
    func finalTextBottom() -> CGFloat {
        guard let layoutManager = textLayoutManager else { return .greatestFiniteMagnitude }
        var bottom: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { fragment in
            bottom = fragment.layoutFragmentFrame.maxY
            if let box = fragment as? NoteBlockLayoutFragment,
               let rect = box.lastLineBoxRect ?? box.monoBlockRect ?? box.calloutBoxRect {
                bottom = max(bottom, rect.maxY + fragment.layoutFragmentFrame.minY)
            }
            return false
        }
        return bottom + textContainerOrigin.y
    }

    /// The code label under `point`: the block's location and the label's
    /// rectangle in this view (its text and 4 pt around it).
    func codeLabel(at point: NSPoint) -> (Int, NSRect)? {
        guard let (fragment, location) = fragment(nearViewPoint: point),
              let block = fragment as? NoteBlockLayoutFragment, let label = block.codeLabel, let row = block.codeLabelRect else { return nil }
        let width = (label as NSString).size(withAttributes: [.font: NoteTextStyle.font(for: AtticNoteType.codeLabel)]).width
        let rect = NSRect(x: row.minX - 4, y: row.minY - 2, width: ceil(width) + 8, height: row.height + 4)
            .offsetBy(dx: fragment.layoutFragmentFrame.minX + textContainerOrigin.x, dy: fragment.layoutFragmentFrame.minY + textContainerOrigin.y)
        return rect.contains(point) ? (location, rect) : nil
    }

    /// The callout icon under `point`, as `codeLabel(at:)`.
    func calloutIcon(at point: NSPoint) -> (Int, NSRect)? {
        guard let (fragment, location) = fragment(nearViewPoint: point),
              let block = fragment as? NoteBlockLayoutFragment, let slot = block.calloutIconRect else { return nil }
        let rect = slot.insetBy(dx: -4, dy: 0)
            .offsetBy(dx: fragment.layoutFragmentFrame.minX + textContainerOrigin.x, dy: fragment.layoutFragmentFrame.minY + textContainerOrigin.y)
        return rect.contains(point) ? (location, rect) : nil
    }

    /// The language menu's commands for the code block at `location`.
    func languageCommands(forBlockAt location: Int) -> [AtticMenuCommand] {
        guard let engine else { return [] }
        let current = engine.codeLanguage(at: location)
        return NoteCodeLanguageName.menu.enumerated().map { index, language in
            var command = AtticMenuCommand(verbatim: NoteCodeLanguageName.menuTitle(for: language),
                                           startsSection: index == 1) { [weak engine] in
                _ = engine?.setCodeLanguage(language, at: location)
            }
            command.state = language == current ? .on : nil
            command.identifier = "note-code-language-\(language ?? "plain")"
            return command
        }
    }

    /// The Icon menu's commands for the callout at `location`: six emoji,
    /// the system's Emoji & Symbols palette and No Icon.
    func calloutIconCommands(forBlockAt location: Int) -> [AtticMenuCommand] {
        guard let engine else { return [] }
        let current = engine.paragraphStyle(at: location)?.calloutIcon
        var commands = NoteCalloutIcons.menu.map { icon in
            var command = AtticMenuCommand(verbatim: icon) { [weak engine] in _ = engine?.setCalloutIcon(icon, at: location) }
            command.state = icon == current ? .on : nil
            return command
        }
        commands.append(AtticMenuCommand("Emoji & Symbols…", startsSection: true) { [weak self] in
            self?.pickCalloutIconFromPalette(forBlockAt: location)
        })
        var none = AtticMenuCommand("No Icon") { [weak engine] in _ = engine?.setCalloutIcon("", at: location) }
        none.state = current == "" ? .on : nil
        commands.append(none)
        return commands
    }

    private func showLanguageMenu(forBlockAt location: Int, below rect: NSRect) {
        hideBlockHandle()
        AtticNativeMenu.popUp(languageCommands(forBlockAt: location), below: rect, in: self)
    }

    private func showCalloutIconMenu(forBlockAt location: Int, below rect: NSRect) {
        hideBlockHandle()
        AtticNativeMenu.popUp(calloutIconCommands(forBlockAt: location), below: rect, in: self)
    }

    /// The palette gets a separate visible text system before it opens.
    func pickCalloutIconFromPalette(forBlockAt location: Int, showPalette: (() -> Void)? = nil) {
        cancelCalloutIconSession(reason: "another picker")
        guard let engine, !engine.isReadOnly, engine.activity == .idle,
              isEditable, !hasMarkedText(), !isHiddenOrHasHiddenAncestor, let window,
              location >= 0, location <= engine.textStorage.length,
              engine.paragraphStyle(at: location)?.isCallout == true else { return }
        (window.firstResponder as? NoteCalloutIconInputView)?.session?.cancel(reason: "another picker")
        let session = NoteCalloutIconSession(engine: engine, editor: self, window: window, location: location)
        calloutIconSession = session
        session.begin { if let showPalette { showPalette() } else { NSApp.orderFrontCharacterPalette(session.receiver) } }
    }

    /// The same layout slot that draws the callout icon, including a trailing
    /// empty paragraph represented by the engine's paragraph model.
    func calloutInputOrigin(at location: Int) -> NSPoint {
        if let engine, let manager = textLayoutManager,
           let start = engine.contentStorage.location(engine.contentStorage.documentRange.location, offsetBy: location) {
            var origin: NSPoint?
            manager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
                if let block = fragment as? NoteBlockLayoutFragment, let slot = block.calloutIconRect {
                    origin = NSPoint(x: slot.midX + fragment.layoutFragmentFrame.minX + self.textContainerOrigin.x - 16,
                                     y: slot.midY + fragment.layoutFragmentFrame.minY + self.textContainerOrigin.y - 16)
                }
                return false
            }
            if let origin { return origin }
        }
        let caret = engine?.caretRect(at: location) ?? NSRect(x: textContainerOrigin.x + 28, y: textContainerOrigin.y, width: 1, height: 28)
        return NSPoint(x: caret.minX - 32, y: caret.midY - 16)
    }

    func checkboxLocation(at point: NSPoint) -> Int? {
        guard let engine else { return nil }
        if let range = engine.checkboxRange(near: point), let rect = engine.rect(for: range) {
            let hit = NSRect(x: rect.minX - 4, y: rect.minY - 4,
                             width: NoteChecklistAttachment.boxSize + 8, height: rect.height + 8)
            if hit.contains(point) { return range.location }
        }
        let index = characterIndexForInsertion(at: point)
        let candidates = [index, max(0, index - 1)]
        for location in candidates {
            let line = engine.lineRange(at: location)
            guard engine.checklistBox(inParagraphAt: location) != nil else { continue }
            let range = NSRange(location: line.location, length: 1)
            guard let rect = engine.rect(for: range) else { continue }
            let hit = NSRect(x: rect.minX - 4, y: rect.minY - 4,
                             width: NoteChecklistAttachment.boxSize + 8, height: rect.height + 8)
            if hit.contains(point) { return range.location }
        }
        return nil
    }

    // MARK: Context menu

    /// The page's format controls add their Format, Insert and link rows
    /// from the one command catalog (slice 3a UI); the rows below remain
    /// the fallback for a text view without them.
    var contextMenuProvider: ((NSMenu, NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        calloutIconSession?.cancel(reason: "editor right click", returnFocus: true)
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        calloutIconSession?.cancel(reason: "editor context menu", returnFocus: true)
        hideBlockHandle()
        // An image's or a file's own menu, read-only notes included.
        if let objectMenu = objectInteraction?.objectMenu(for: event) { return objectMenu }
        let menu = super.menu(for: event) ?? NSMenu()
        guard engine != nil, isEditable else { return menu }
        if let contextMenuProvider {
            contextMenuProvider(menu, event)
            return menu
        }
        menu.insertItem(.separator(), at: 0)
        let insert = NSMenuItem(title: String(localized: "Insert"), action: nil, keyEquivalent: "")
        insert.submenu = NoteEditorTextView.insertMenu(target: self)
        menu.insertItem(insert, at: 0)
        let format = NSMenuItem(title: String(localized: "Format"), action: nil, keyEquivalent: "")
        format.submenu = formatMenu()
        menu.insertItem(format, at: 0)
        return menu
    }

    private func formatMenu() -> NSMenu {
        let menu = NSMenu()
        let commands: [NoteFormatCommand] = [
            .paragraph(.body), .paragraph(.heading(1)), .paragraph(.heading(2)), .paragraph(.heading(3)),
            .paragraph(.mono), .paragraph(.bullet), .paragraph(.number), .paragraph(.checklist), .paragraph(.quote),
            .mark(.bold), .mark(.italic), .mark(.underline), .mark(.strikethrough), .mark(.code),
            .mark(.highlight), .mark(.link), .indent, .outdent, .removeLink
        ]
        for command in commands {
            if [.mark(.bold), .indent].contains(command) { menu.addItem(.separator()) }
            let item = NSMenuItem(title: command.title, action: #selector(performFormatMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            item.image = NSImage(systemSymbolName: command.symbolName, accessibilityDescription: command.title)
            let state = engine?.validate(command, selection: selectedRange())
            item.isEnabled = state?.enabled ?? false
            item.state = switch state?.state {
            case .on: .on
            case .mixed: .mixed
            default: .off
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performFormatMenuItem(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? NoteFormatCommand else { return }
        _ = engine?.perform(command, selection: selectedRange())
    }

    static func insertMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        let checklist = NSMenuItem(title: String(localized: "Checklist"), action: #selector(insertChecklistLine(_:)), keyEquivalent: "")
        checklist.target = target
        let date = NSMenuItem(title: String(localized: "Today’s Date"), action: #selector(insertTodaysDate(_:)), keyEquivalent: "")
        date.target = target
        menu.items = [checklist, date]
        return menu
    }

    @objc func insertChecklistLine(_ sender: Any?) {
        guard let engine else { return }
        let selection = selectedRange()
        _ = engine.perform(.paragraph(engine.paragraphStyle(at: selection.location) == .checklist ? .body : .checklist), selection: selection)
    }
    @objc func insertTodaysDate(_ sender: Any?) { _ = engine?.perform(.date(NoteDay(date: Date()))) }

    // MARK: Accessibility

    override func accessibilitySelectedTextRanges() -> [NSValue]? {
        guard let marquee, !marquee.isEmpty else { return super.accessibilitySelectedTextRanges() }
        return marquee.ranges.map { NSValue(range: $0) }
    }

    override func accessibilitySelectedText() -> String? {
        guard let marquee, !marquee.isEmpty, let engine else { return super.accessibilitySelectedText() }
        return marquee.ranges.map { NoteTextExport.plainText(engine.fragment(for: $0)) }.joined(separator: "\n")
    }

    override func accessibilityChildren() -> [Any]? {
        let base = super.accessibilityChildren() ?? []
        guard let engine else { return base }
        var accessories = accessoryViews.filter { view in !view.isHidden && !base.contains { ($0 as AnyObject) === view } }
        accessories += (calloutIconSession?.accessibilityControls ?? []).filter { control in
            !base.contains { ($0 as AnyObject) === control }
        }
        accessories += engine.headingControls.values.filter { button in
            !base.contains { ($0 as AnyObject) === button }
        }
        // Copy, while it shows (the caret in a block, or the pointer over one).
        if !monoCopyButton.isHidden, !base.contains(where: { ($0 as AnyObject) === monoCopyButton }) {
            accessories.append(monoCopyButton)
        }
        let tables = engine.tableViews().filter { table in
            guard let attachment = table.attachment, let range = engine.range(ofTable: attachment) else { return false }
            return !engine.isRangeFolded(range) && !base.contains { ($0 as AnyObject) === table }
        }
        return base + engine.accessibilityElements(for: self) + tables + accessories
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let base = super.accessibilityAttributedString(for: range), let engine,
              let storage = textStorage else { return super.accessibilityAttributedString(for: range) }
        let result = NSMutableAttributedString(attributedString: base)
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        let elements = engine.accessibilityElements(for: self).compactMap { $0 as? NoteObjectAccessibilityElement }
        storage.enumerateAttribute(.attachment, in: clamped) { value, objectRange, _ in
            if let table = value as? NoteTableAttachment, let view = table.hostedView {
                let local = NSRange(location: objectRange.location - range.location, length: objectRange.length)
                if local.location >= 0, NSMaxRange(local) <= result.length {
                    result.addAttribute(.accessibilityAttachment, value: view, range: local)
                }
                return
            }
            guard let object = value as? NoteObjectAttachment,
                  let element = elements.first(where: { $0.objectID == object.objectID }) else { return }
            let local = NSRange(location: objectRange.location - range.location, length: objectRange.length)
            guard local.location >= 0, NSMaxRange(local) <= result.length else { return }
            result.addAttribute(.accessibilityAttachment, value: element, range: local)
        }
        for paragraph in engine.accessibilityParagraphs(in: clamped) {
            let local = NSIntersectionRange(paragraph.range, range)
            guard local.length > 0 else { continue }
            let target = NSRange(location: local.location - range.location, length: local.length)
            if let level = paragraph.headingLevel {
                result.addAttribute(NSAttributedString.Key(NSAccessibility.Attribute.headingLevelAttribute.rawValue),
                                    value: level, range: target)
            }
            if paragraph.style == "quote" {
                result.addAttribute(NSAttributedString.Key(NSAccessibility.Attribute.blockQuoteLevelAttribute.rawValue),
                                    value: 1 + paragraph.indent, range: target)
            }
            if paragraph.style == "bullet" || paragraph.style == "number" {
                let marker = paragraph.style == "number" ? "\(paragraph.listOrdinal ?? 1)." : "•"
                result.addAttribute(.accessibilityListItemPrefix, value: NSAttributedString(string: marker), range: target)
                result.addAttribute(.accessibilityListItemIndex, value: (paragraph.listOrdinal ?? 1) - 1, range: target)
                result.addAttribute(.accessibilityListItemLevel, value: paragraph.indent, range: target)
            }
        }
        return result
    }
}

/// The text view's `undoManager`: menu validation and any caller that asks
/// the responder chain's undo manager reach the engine's own history.
/// Registrations made on it by the system are accepted and ignored: every
/// change they describe is already a step in the engine's history.
final class NoteUndoManagerShim: UndoManager {
    private weak var textView: NoteEditorTextView?

    init(textView: NoteEditorTextView) {
        self.textView = textView
        super.init()
        // Registrations are grouped per event as usual and kept to one
        // level: they are never run (undo and redo go to the history).
        levelsOfUndo = 1
    }

    private var history: NoteUndoHistory? {
        MainActor.assumeIsolated { textView?.engine?.history }
    }

    override var canUndo: Bool { MainActor.assumeIsolated { textView?.engine?.canUndoCommand ?? false } }
    override var canRedo: Bool { MainActor.assumeIsolated { textView?.engine?.canRedoCommand ?? false } }
    override var undoActionName: String { MainActor.assumeIsolated { textView?.engine?.undoCommandName ?? "" } }
    override var redoActionName: String { MainActor.assumeIsolated { textView?.engine?.redoCommandName ?? "" } }

    override func undo() {
        MainActor.assumeIsolated { _ = textView?.engine?.undoCommand() }
    }

    override func redo() {
        MainActor.assumeIsolated { _ = textView?.engine?.redoCommand() }
    }
}

/// What the page's object controls answer for the note's text view: object
/// clicks and menus, and files dragged in from elsewhere. nil or false
/// leaves the event to the text view.
@MainActor
protocol NoteObjectInteraction: AnyObject {
    func handleMouseDown(_ event: NSEvent) -> Bool
    func objectMenu(for event: NSEvent) -> NSMenu?
    func isFileDrag(_ info: any NSDraggingInfo) -> Bool
    /// The operation for a drag of files from elsewhere, or nil when it is
    /// not one (text, or a move within the note).
    func fileDragUpdated(_ info: any NSDraggingInfo, entered: Bool) -> NSDragOperation?
    func fileDragEnded()
    func performFileDrop(_ info: any NSDraggingInfo) -> Bool?
}

/// V-06: a dragged block's own place dims while its card is lifted (its
/// text through the editor's rendering attributes, which change no layout;
/// hosted views such as a table by their opacity), and comes back on drop.
@MainActor
final class NoteBlockDragDim {
    private weak var textView: NoteEditorTextView?
    private var views: [(NSView, CGFloat)] = []

    init(textView: NoteEditorTextView, block: NSRange, rect: CGRect) {
        self.textView = textView
        textView.dragDimRange = block
        // Hosted views (tables, images and files) in the block's rectangle,
        // wherever TextKit keeps them under the text view.
        let hosted = (textView.engine?.tableViews() ?? []) as [NSView]
        var seen = Set<ObjectIdentifier>()
        for view in hosted + textView.subviews where seen.insert(ObjectIdentifier(view)).inserted {
            guard !view.isHidden, view.window === textView.window, !(view is NoteDragLiftView), !(view is NoteDropLineView),
                  view !== textView.blockHandle, view.isDescendant(of: textView) else { continue }
            let frame = view.superview === textView ? view.frame : textView.convert(view.bounds, from: view)
            guard rect.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
            views.append((view, view.alphaValue))
            view.alphaValue = Self.viewOpacity
        }
    }

    static let viewOpacity: CGFloat = 0.35

    func restore() {
        textView?.dragDimRange = nil
        for (view, alpha) in views { view.alphaValue = alpha }
        views = []
    }
}
