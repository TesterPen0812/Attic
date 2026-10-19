import AppKit
import QuartzCore

// MARK: - Where a dragged block lands (DG1)

/// Every block's rectangle in the text view, measured once when a block
/// drag starts, and the drop each half of a block means. A pointer move
/// then picks its slot by a binary search: no layout per event.
struct NoteBlockDropSlots {
    struct Slot: Equatable {
        let position: NoteBlockDropPosition
        /// The drop line, in the text view: in the gap between the two
        /// blocks, at the drop's depth.
        let line: CGRect
    }

    struct Block: Equatable {
        let range: NSRange
        let rect: CGRect
        /// Dropping before or after this block (nil: no move, or a place
        /// the move can't use).
        let before: Slot?
        let after: Slot?
    }

    /// A block and which half of it the pointer is over.
    struct Choice: Equatable {
        let index: Int
        let after: Bool
    }

    /// Top to bottom.
    let blocks: [Block]
    /// How far past a block's middle the pointer must go before the
    /// choice flips to its other half (no flicker on the boundary).
    static let hysteresis: CGFloat = 4

    /// The block half under `y` (in the text view). Above the first block
    /// is its top half; below the last, its bottom half; in a gap, the
    /// nearer block.
    func choice(atY y: CGFloat, current: Choice?) -> Choice? {
        guard !blocks.isEmpty else { return nil }
        // The first block whose bottom is at or below y.
        var low = 0, high = blocks.count
        while low < high {
            let middle = (low + high) / 2
            if blocks[middle].rect.maxY < y { low = middle + 1 } else { high = middle }
        }
        guard low < blocks.count else { return Choice(index: blocks.count - 1, after: true) }
        var index = low
        let rect = blocks[index].rect
        if y < rect.minY {
            guard index > 0 else { return Choice(index: 0, after: false) }
            // In the gap above: the nearer side.
            let above = blocks[index - 1].rect
            if y < (above.maxY + rect.minY) / 2 { index -= 1; return Choice(index: index, after: true) }
            return Choice(index: index, after: false)
        }
        let middle = blocks[index].rect.midY
        if let current, current.index == index, abs(y - middle) < Self.hysteresis {
            return current
        }
        return Choice(index: index, after: y > middle)
    }

    func slot(for choice: Choice?) -> Slot? {
        guard let choice, blocks.indices.contains(choice.index) else { return nil }
        return choice.after ? blocks[choice.index].after : blocks[choice.index].before
    }
}

extension NoteEditorTextView {
    /// The note's blocks below the title, measured once (the whole note is
    /// laid out first, so later moves and autoscroll find exact places).
    func blockDropSlots(moving source: NSRange) -> NoteBlockDropSlots {
        guard let engine, let layoutManager = textLayoutManager else { return NoteBlockDropSlots(blocks: []) }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let length = engine.textStorage.length
        let titleEnd = engine.titleParagraphRange.length
        var ranges: [NSRange] = []
        var location = titleEnd
        while location < length {
            let block = engine.blockRange(at: location)
            guard block.length > 0, block.location <= location, NSMaxRange(block) > location else { location += 1; continue }
            ranges.append(block)
            location = NSMaxRange(block)
        }
        var rects: [Int: CGRect] = [:]
        for range in ranges { if let rect = rect(ofBlock: range) { rects[range.location] = rect } }
        let width = textContainer?.size.width ?? bounds.width
        func rectOfBlock(at location: Int) -> CGRect? {
            guard location >= titleEnd, location < length else { return nil }
            let block = engine.blockRange(at: location)
            return rects[block.location] ?? rect(ofBlock: block)
        }
        /// Only drops the move accepts (`moveBlock`'s own rules), so the
        /// line never promises one that does nothing.
        func slot(_ block: NSRange, _ rect: CGRect, after: Bool) -> NoteBlockDropSlots.Slot? {
            guard NSIntersectionRange(block, source).length == 0, block.location != source.location,
                  let position = engine.blockDropPosition(at: block.location, after: after),
                  position.location != source.location, position.location != NSMaxRange(source),
                  position.location > titleEnd, position.location <= length,
                  position.location < source.location || position.location > NSMaxRange(source),
                  position.location == length || engine.blockRange(at: position.location).location == position.location
            else { return nil }
            let gapY: CGFloat
            if after {
                gapY = rectOfBlock(at: position.location).map { (rect.maxY + $0.minY) / 2 } ?? rect.maxY + AtticNoteType.paragraphGap / 2
            } else {
                gapY = rectOfBlock(at: block.location - 1).map { ($0.maxY + rect.minY) / 2 } ?? rect.minY - AtticNoteType.paragraphGap / 2
            }
            let indent = CGFloat(position.depth) * AtticNoteType.listLevelStep
            let line = CGRect(x: textContainerOrigin.x + indent, y: gapY - AtticNoteType.dropLineThickness / 2,
                              width: max(0, width - indent), height: AtticNoteType.dropLineThickness)
            return NoteBlockDropSlots.Slot(position: position, line: line)
        }
        let blocks = ranges.compactMap { range -> NoteBlockDropSlots.Block? in
            guard let rect = rects[range.location], rect.height > 0 else { return nil }
            return NoteBlockDropSlots.Block(range: range, rect: rect, before: slot(range, rect, after: false),
                                            after: slot(range, rect, after: true))
        }.sorted { $0.rect.minY < $1.rect.minY }
        return NoteBlockDropSlots(blocks: blocks)
    }
}

// MARK: - The lifted card (DG1)

/// Where a block drag's card is drawn: a layer-hosting view over the
/// whole page in the panel's overlay layer, above the page's floating
/// controls (the header, the bottom row, the format bar), so the card is
/// never under them, never blurred by them and never scrolled away with
/// the text. The card is one Core Animation layer moved by its position:
/// following the pointer changes no view frame and lays nothing out.
@MainActor
final class NoteBlockDragStage: NSView {
    let card = CALayer()
    private let image = CALayer()
    /// The card's room around its snapshot.
    let padding = CGSize(width: 6, height: 4)
    private let shadowOpacity: Float

    init(frame: CGRect, snapshot: NSImage?, size: CGSize, tokens: AtticColorTokens, scale: CGFloat) {
        shadowOpacity = Float(tokens.dropdownShadow.alpha)
        super.init(frame: frame)
        // Layer-hosting: this view's layer tree is its own (y up, as the
        // view), and AppKit never re-lays it out.
        let root = CALayer()
        root.masksToBounds = false
        layer = root
        wantsLayer = true
        let cardSize = CGSize(width: size.width + padding.width * 2, height: size.height + padding.height * 2)
        card.bounds = CGRect(origin: .zero, size: cardSize)
        card.backgroundColor = tokens.popoverFill.nsColor.cgColor
        card.cornerRadius = NoteDragLiftView.cornerRadius
        card.cornerCurve = .continuous
        card.borderWidth = AtticHairline.width
        card.borderColor = tokens.popoverOuterRim.nsColor.cgColor
        card.shadowColor = tokens.dropdownShadow.nsColor.withAlphaComponent(1).cgColor
        card.shadowOpacity = shadowOpacity
        card.shadowRadius = AtticShadows.dropdown.radius / 2
        card.shadowOffset = CGSize(width: 0, height: -AtticShadows.dropdown.y / 2)
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: NoteDragLiftView.cornerRadius,
                                 cornerHeight: NoteDragLiftView.cornerRadius, transform: nil)
        card.contentsScale = scale
        image.contents = snapshot
        image.contentsGravity = .resize
        image.contentsScale = scale
        image.frame = CGRect(x: padding.width, y: padding.height, width: size.width, height: size.height)
        card.addSublayer(image)
        root.addSublayer(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not archived") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The card's frame in this view (its model value).
    var cardFrame: CGRect {
        CGRect(x: card.position.x - card.bounds.width / 2, y: card.position.y - card.bounds.height / 2,
               width: card.bounds.width, height: card.bounds.height)
    }

    /// The card's frame where it is on screen now (mid-animation included).
    var shownCardFrame: CGRect {
        let shown = card.presentation() ?? card
        return CGRect(x: shown.position.x - card.bounds.width / 2, y: shown.position.y - card.bounds.height / 2,
                      width: card.bounds.width, height: card.bounds.height)
    }

    /// Puts the card's origin at `origin` (this view's points), at once,
    /// on the device's pixel grid so the snapshot stays sharp.
    func place(origin: CGPoint) {
        let scale = max(1, window?.backingScaleFactor ?? card.contentsScale)
        let x = (origin.x * scale).rounded() / scale, y = (origin.y * scale).rounded() / scale
        let position = CGPoint(x: x + card.bounds.width / 2, y: y + card.bounds.height / 2)
        guard position != card.position else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.position = position
        CATransaction.commit()
    }

    /// The lift: a short spring up to a slightly larger card with its
    /// shadow (none under Reduce Motion).
    func lift(animated: Bool) {
        guard animated else { return }
        let grow = CASpringAnimation(keyPath: "transform.scale")
        Self.tune(grow)
        grow.fromValue = 1
        grow.toValue = Self.liftScale
        grow.duration = grow.settlingDuration
        card.transform = CATransform3DMakeScale(Self.liftScale, Self.liftScale, 1)
        card.add(grow, forKey: "lift")
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0
        shadow.toValue = shadowOpacity
        shadow.duration = AtticMotionScale.fast
        card.add(shadow, forKey: "liftShadow")
    }

    /// The landing: the card springs to `origin` and back to its size,
    /// then fades, and `done` runs. With no motion it just goes.
    func settle(at origin: CGPoint?, animated: Bool, done: @escaping () -> Void) {
        guard animated else { done(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        var duration = AtticMotionScale.fast
        if let origin {
            let from = (card.presentation() ?? card).position
            let to = CGPoint(x: origin.x + card.bounds.width / 2, y: origin.y + card.bounds.height / 2)
            let move = CASpringAnimation(keyPath: "position")
            Self.tune(move)
            move.fromValue = NSValue(point: from)
            move.toValue = NSValue(point: to)
            move.duration = move.settlingDuration
            duration = move.duration
            CATransaction.setDisableActions(true)
            card.position = to
            card.add(move, forKey: "settle")
        }
        let shrink = CASpringAnimation(keyPath: "transform.scale")
        Self.tune(shrink)
        shrink.fromValue = (card.presentation() ?? card).value(forKeyPath: "transform.scale") ?? Self.liftScale
        shrink.toValue = 1
        shrink.duration = shrink.settlingDuration
        card.transform = CATransform3DIdentity
        card.add(shrink, forKey: "drop")
        // The block is already in its place underneath: the card fades as
        // it arrives.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + max(0, min(duration, 0.22) - AtticMotionScale.fast * 0.5)
        fade.duration = AtticMotionScale.fast
        fade.fillMode = .backwards
        card.opacity = 0
        card.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// The card is about the same size as the block: a small lift, as a
    /// native list's dragged row.
    static let liftScale: CGFloat = 1.02

    /// A short native spring: critically damped, about a fifth of a second.
    private static func tune(_ spring: CASpringAnimation) {
        spring.mass = 1
        spring.stiffness = 520
        spring.damping = 2 * sqrt(520)
        spring.initialVelocity = 0
    }
}

// MARK: - The drag (DG1)

/// One block drag (⋮⋮), from the lift to the drop or the cancel. The card
/// follows the pointer one to one; the drop line glides between gaps; near
/// the page's top or bottom edge the note scrolls each display frame, at a
/// speed that grows with the pointer's distance into the edge.
@MainActor
final class NoteBlockDragSession: NSObject {
    private weak var textView: NoteEditorTextView?
    let source: NSRange
    let slots: NoteBlockDropSlots
    let stage: NoteBlockDragStage
    private let sourceRect: CGRect
    /// The pointer's offset from the card's origin, held for the whole drag.
    private let grab: CGPoint
    private let animated: Bool
    private var dim: NoteBlockDragDim?
    private(set) var choice: NoteBlockDropSlots.Choice?
    private(set) var windowPoint: CGPoint
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private var lastFollowed: CGPoint?
    private lazy var ticker = NoteBlockDragTicker(owner: self)
    #if DEBUG
    private var probe: NoteDragProbe?
    #endif

    /// The drop the line shows now.
    var target: NoteBlockDropPosition? { slots.slot(for: choice)?.position }

    /// Lifts `source` (its rectangle `sourceRect` in the text view); the
    /// press was at `pressPoint` (window).
    init?(textView: NoteEditorTextView, source: NSRange, sourceRect: CGRect, pressPoint: CGPoint) {
        guard let engine = textView.engine, let window = textView.window,
              let parent = Self.overlayParent(of: textView), let scrollView = textView.enclosingScrollView else { return nil }
        self.textView = textView
        self.source = source
        self.sourceRect = sourceRect
        windowPoint = pressPoint
        animated = !engine.style.design.reduceMotion
        slots = textView.blockDropSlots(moving: source)
        let snapshot = NoteDragLiftView.snapshot(of: sourceRect, in: textView)
        let pageFrame = parent.convert(scrollView.bounds, from: scrollView)
        let stage = NoteBlockDragStage(frame: pageFrame, snapshot: snapshot, size: sourceRect.size,
                                       tokens: engine.style.tokens, scale: window.backingScaleFactor)
        self.stage = stage
        // On top of every floating control (added last), before any
        // conversion: the stage converts through its window.
        parent.addSubview(stage, positioned: .above, relativeTo: nil)
        let home = Self.cardFrame(for: sourceRect, padding: stage.padding, in: stage, from: textView)
        let press = stage.convert(pressPoint, from: nil)
        grab = CGPoint(x: press.x - home.minX, y: press.y - home.minY)
        super.init()
        stage.place(origin: home.origin)
        stage.lift(animated: animated)
        dim = NoteBlockDragDim(textView: textView, block: source, rect: sourceRect)
        textView.dropLine.ink = engine.style.tokens.focusRing.nsColor
        let link = textView.displayLink(target: ticker, selector: #selector(NoteBlockDragTicker.frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        #if DEBUG
        probe = NoteDragProbe.begin(in: textView) { [weak self] in
            guard let self, let textView = self.textView else { return (nil, nil) }
            let line = textView.dropLine.isHidden ? nil : textView.convert(textView.dropLine.frame, to: nil).midY
            return (self.stage.convert(self.stage.shownCardFrame, to: nil).maxY, line)
        }
        #endif
    }

    /// The panel's overlay layer (above the page and its floating
    /// controls), or a plain window's content view.
    static func overlayParent(of view: NSView) -> NSView? {
        var candidate = view.superview
        while let current = candidate {
            if let container = current as? AtticPanelContentContainer { return container.overlayLayer }
            candidate = current.superview
        }
        return view.window?.contentView
    }

    /// The card around a block whose rectangle is `rect` in `textView`,
    /// in `stage`.
    static func cardFrame(for rect: CGRect, padding: CGSize, in stage: NSView, from textView: NSView) -> CGRect {
        stage.convert(rect, from: textView).insetBy(dx: -padding.width, dy: -padding.height)
    }

    // MARK: Following the pointer

    /// A drag event: the card moves under the pointer at once.
    func pointerMoved(to point: CGPoint) {
        #if DEBUG
        let started = CACurrentMediaTime()
        defer { probe?.eventHandled(since: started) }
        #endif
        windowPoint = point
        follow()
        chooseSlot()
    }

    private func follow() {
        let local = stage.convert(windowPoint, from: nil)
        let size = stage.card.bounds.size
        var origin = CGPoint(x: local.x - grab.x, y: local.y - grab.y)
        // Along the column: the card moves up and down with the pointer and
        // stays whole on the page (over the header and the bottom row, never
        // past the panel's edge), as a native list's row does.
        origin.x = stage.cardFrame.minX
        origin.y = min(max(origin.y, 0), max(0, stage.bounds.height - size.height))
        stage.place(origin: origin)
    }

    private func chooseSlot() {
        guard let textView else { return }
        let point = textView.convert(windowPoint, from: nil)
        let next = slots.choice(atY: point.y, current: choice)
        guard next != choice else { return }
        let before = slots.slot(for: choice)
        choice = next
        let slot = slots.slot(for: next)
        guard slot != before else { return }
        showLine(slot?.line, in: textView)
    }

    /// The drop line glides from gap to gap; it fades in where it first
    /// shows and out when there is no drop.
    private func showLine(_ rect: CGRect?, in textView: NoteEditorTextView) {
        let line = textView.dropLine
        guard let rect else {
            line.isHidden = true
            return
        }
        if line.isHidden || !animated {
            line.layer?.removeAllAnimations()
            line.frame = rect
            line.isHidden = false
            line.needsDisplay = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AtticMotionScale.fast
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            line.animator().frame = rect
        }
    }

    // MARK: Autoscroll

    fileprivate func frame(_ link: CADisplayLink) {
        let delta = lastFrame.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastFrame = link.timestamp
        guard let textView, let window = textView.window, let scroll = textView.enclosingScrollView else { return }
        // The latest drag event's point: events come at least once per
        // frame while the pointer moves, and it stays put when it doesn't.
        let pointer = windowPoint
        let moved = pointer != lastFollowed
        lastFollowed = pointer
        _ = window
        let clip = scroll.contentView
        let insets = clip.contentInsets
        var viewport = clip.bounds
        viewport.origin.y += max(0, insets.top)
        viewport.size.height -= max(0, insets.top) + max(0, insets.bottom)
        let local = clip.convert(pointer, from: nil)
        // The clip is flipped (its document is): y grows down the note.
        let velocity = MarqueeGeometry.scrollVelocity(pointerY: local.y, viewport: viewport)
        var scrolled = false
        if velocity != 0, let document = scroll.documentView {
            var next = clip.bounds.origin
            next.y = MarqueeGeometry.scrollOrigin(current: next.y, velocity: velocity, seconds: delta,
                                                  minimum: -insets.top,
                                                  maximum: max(-insets.top, document.frame.height - clip.bounds.height + insets.bottom))
            if next != clip.bounds.origin {
                clip.scroll(to: next)
                scroll.reflectScrolledClipView(clip)
                scrolled = true
            }
        }
        if moved { follow() }
        if moved || scrolled { chooseSlot() }
    }

    // MARK: Ending

    /// The drop: the block moves (one Undo step) and the card settles into
    /// its new place. Returns whether it moved.
    @discardableResult func drop() -> Bool {
        guard let textView, let engine = textView.engine else { end(at: nil, how: "drop"); return false }
        // Undimmed before the edit: the dim names the block's place as it was.
        dim?.restore()
        dim = nil
        textView.dropLine.isHidden = true
        guard let target, let line = slots.slot(for: choice)?.line else {
            end(at: home(in: textView), how: "drop-home")
            return false
        }
        let clip = textView.enclosingScrollView?.contentView
        let lineOnPage = clip.map { line.midY - $0.bounds.minY }
        let moved = engine.moveBlock(source, to: target.location)
        guard moved else { end(at: home(in: textView), how: "drop-refused"); return false }
        // The move selects the block where it landed.
        let landing = textView.selectedRange().location
        let block = engine.blockRange(at: min(max(landing, 0), max(0, engine.textStorage.length - 1)))
        // Exact places for it: the edit left the text before it estimated.
        if let layout = textView.textLayoutManager, let end = engine.textRange(for: block)?.endLocation,
           let prefix = NSTextRange(location: layout.documentRange.location, end: end) {
            layout.ensureLayout(for: prefix)
        }
        let rect = textView.rect(ofBlock: block)
        // The block lands where the line was: the note keeps it there (no
        // reveal of the old caret, no jump when a block left from above).
        textView.cancelPendingReveal()
        if let clip, let scroll = textView.enclosingScrollView, let rect, let lineOnPage {
            let insets = clip.contentInsets
            var origin = clip.bounds.origin
            origin.y = min(max(rect.minY - lineOnPage, -insets.top),
                           max(-insets.top, textView.frame.height - clip.bounds.height + insets.bottom))
            if origin != clip.bounds.origin {
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
            }
        }
        end(at: rect.map { visible(Self.cardFrame(for: $0, padding: stage.padding, in: stage, from: textView)) } ?? nil,
            how: "drop")
        return true
    }

    /// Esc, the panel losing key status or hiding, or the page going
    /// away: the card glides back over its source; nothing moves.
    func cancel() {
        dim?.restore()
        dim = nil
        guard let textView else { end(at: nil, how: "cancel"); return }
        textView.dropLine.isHidden = true
        end(at: home(in: textView), how: "cancel")
    }

    private func home(in textView: NoteEditorTextView) -> CGPoint? {
        visible(Self.cardFrame(for: sourceRect, padding: stage.padding, in: stage, from: textView))
    }

    /// A landing the card can glide to: on the page (one off the page
    /// fades where it is instead).
    private func visible(_ frame: CGRect) -> CGPoint? {
        stage.bounds.intersects(frame) ? frame.origin : nil
    }

    private var ended = false

    private func end(at origin: CGPoint?, how: String) {
        guard !ended else { return }
        ended = true
        link?.invalidate()
        link = nil
        #if DEBUG
        probe?.end(how)
        probe = nil
        #endif
        CATransaction.flush()
        let stage = stage
        stage.settle(at: origin, animated: animated && stage.window != nil) { stage.removeFromSuperview() }
        // A window that never draws may not finish the animation: the card
        // goes anyway once it would have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { stage.removeFromSuperview() }
    }

    /// The drag is over in any way not yet handled (the view went away).
    func finish() {
        dim?.restore()
        dim = nil
        textView?.dropLine.isHidden = true
        end(at: nil, how: "gone")
    }
}

@MainActor
private final class NoteBlockDragTicker: NSObject {
    weak var owner: NoteBlockDragSession?
    init(owner: NoteBlockDragSession) { self.owner = owner }
    @objc func frame(_ link: CADisplayLink) { owner?.frame(link) }
}
