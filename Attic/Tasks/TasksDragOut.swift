import AppKit
import QuartzCore
import SwiftUI

/// A drag of tasks out of the panel into another app (owner-approved,
/// 2026-10-01): an AppKit dragging session carrying `TasksTextExport`'s
/// text, Markdown and RTF. Always a copy; the panel's data never changes.
@MainActor
enum TasksDragOut {
    static func begin(_ export: TasksTextExport, count: Int, from view: NSView, at location: CGPoint,
                      card: Card? = nil, ended: @escaping () -> Void) {
        guard let window = view.window else { card?.handOff(); ended(); return }
        let item = NSDraggingItem(pasteboardWriter: export.dragItem())
        // O14-11: the lifted card itself, where it lies, so the hand-off
        // from the panel's lift to the system's drag does not move or
        // change what is under the pointer; without one, a quiet label.
        if let card {
            item.setDraggingFrame(card.frame, contents: card.images.shadowed)
        } else {
            let image = Self.image(title: count == 1 ? export.items.first?.title ?? "" : String(localized: "\(count) tasks"))
            item.setDraggingFrame(CGRect(x: location.x - image.size.width / 2, y: location.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
        }
        // The event the drag starts from: the current mouse event, or one
        // made at the pointer for the same window.
        let event: NSEvent? = if let current = NSApp.currentEvent,
                                 [.leftMouseDown, .leftMouseDragged].contains(current.type) {
            current
        } else {
            NSEvent.mouseEvent(with: .leftMouseDragged, location: view.convert(location, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let event else { card?.handOff(); ended(); return }
        let source = Source(ended: ended)
        if let card {
            // Where the image lies against the pointer, on screen: the drop
            // point less this is where a cancelled card starts home from.
            let imageOnScreen = window.convertToScreen(view.convert(card.frame, to: nil))
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            source.card = card
            source.imageOffset = CGPoint(x: imageOnScreen.minX - pointer.x, y: imageOnScreen.minY - pointer.y)
            source.imageSize = imageOnScreen.size
            source.level = window.level
        }
        Source.current = source
        let session = view.beginDraggingSession(with: [item], event: event, source: source)
        // A cancelled drop springs home (`Source.springHome`), never the
        // system's slide back and fade.
        session.animatesToStartingPositionsOnCancelOrFail = card == nil
        session.draggingFormation = .none
        source.session = session
        Probe.shared.began += 1
        // If the system shows the image before any move, the card goes
        // with the next frame at the latest.
        if card != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak source] in source?.handOffOnce() }
        }
    }

    /// The lifted card a drag carries out of the panel (O14-11).
    struct Card {
        /// The card with its lift shadow (the drag image) and without (the
        /// card settling home lets its shadow go).
        struct Images {
            let shadowed: NSImage
            let plain: NSImage
            /// The room around the card for its shadow, each side.
            static let room: CGFloat = 20

            @MainActor
            init?<C: View>(card: C, width: CGFloat, environment: EnvironmentValues, scale: CGFloat) {
                func render(shadow: Bool) -> NSImage? {
                    let content = card
                        .frame(width: width, alignment: .topLeading)
                        .modifier(AtticReorderLiftModifier(lifted: true, shadow: shadow))
                        .padding(Self.room)
                        .environment(\.self, environment)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = scale
                    renderer.isOpaque = false
                    return renderer.nsImage
                }
                guard let shadowed = render(shadow: true), let plain = render(shadow: false) else { return nil }
                self.shadowed = shadowed
                self.plain = plain
            }
        }

        let images: Images
        /// The image's frame in the dragging view (the card where it lies,
        /// with its shadow room).
        let frame: CGRect
        /// The image's frame on screen when the card is back on its row
        /// (nil: the row is gone, nothing springs).
        let home: () -> CGRect?
        let reduceMotion: Bool
        /// The system's drag image is up: the panel's own card can go.
        let handOff: () -> Void
        /// The card is home (or the drop was taken): the drag is over.
        var settled: () -> Void = {}
    }

    /// UI tests: how many sessions began and ended (shown, under
    /// `ATTIC_UI_TESTING`, by the page's `tasks-drag-out-state` element).
    final class Probe: ObservableObject {
        static let shared = Probe()
        @Published var began = 0
        @Published var ended = 0
    }

    /// What a drag of tasks offers: a copy to other apps, nothing within
    /// Attic (a drop back on the panel does nothing).
    nonisolated static func operations(for context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    /// A quiet label of what is being dragged.
    static func image(title: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let width = min(280, ceil(text.size().width)) + 24
        let size = NSSize(width: width, height: 28)
        return NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.stroke()
            text.draw(with: CGRect(x: 12, y: (rect.height - text.size().height) / 2, width: rect.width - 24, height: text.size().height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }

    /// The session's source (internal for the tests, which end it as Esc
    /// does).
    @MainActor
    final class Source: NSObject, NSDraggingSource {
        /// Held for the session's life.
        static var current: Source?
        let ended: () -> Void
        /// The live session.
        weak var session: NSDraggingSession?
        /// The lifted card the drag carries, and where its image lies
        /// against the pointer on screen.
        var card: Card?
        var imageOffset: CGPoint = .zero
        var imageSize: CGSize = .zero
        var level: NSWindow.Level = .floating
        private var handedOff = false
        /// The card's way home after a cancelled drop.
        private var dragReturn: AtticDragReturn?

        init(ended: @escaping () -> Void) {
            self.ended = ended
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // A copy, never a move: nothing leaves Attic.
            TasksDragOut.operations(for: context)
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            handOffOnce()
            dragReturn?.moved(drawn: AtticDragReturn.drawnFrame(of: session))
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ended(at: screenPoint, operation: operation, drawn: AtticDragReturn.drawnFrame(of: session))
        }

        /// The session ended at `screenPoint` (internal for the tests).
        func ended(at screenPoint: NSPoint, operation: NSDragOperation, drawn: CGRect? = nil) {
            handOffOnce()
            let start = drawn.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil }
                ?? CGRect(origin: CGPoint(x: screenPoint.x + imageOffset.x, y: screenPoint.y + imageOffset.y), size: imageSize)
            guard let dragReturn else {
                card?.settled()
                finish()
                return
            }
            // Dropped nowhere (Esc, back on the panel, a place that takes
            // nothing): the card springs home to its row.
            dragReturn.ended(operation: operation, drawn: start) { [weak self] in
                self?.card?.settled()
                self?.finish()
            }
        }

        func handOffOnce() {
            guard !handedOff else { return }
            handedOff = true
            card?.handOff()
            if let card, dragReturn == nil {
                dragReturn = AtticDragReturn(shadowed: card.images.shadowed, plain: card.images.plain, home: card.home,
                                             level: level, reduceMotion: card.reduceMotion)
            }
        }

        /// The session ended: dropped, or cancelled (Esc, or no
        /// destination: no operation). Once; nothing in Attic changes
        /// either way.
        func finish() {
            guard Source.current === self else { return }
            Source.current = nil
            Probe.shared.ended += 1
            ended()
        }
    }
}

/// The way home for something dragged out of the panel (O14-11): a task's
/// lifted card, a task's file, a note's object. A cancelled drop (Esc, back
/// on the panel, a place that takes nothing) springs back to where the
/// item lies along a short curve (each axis on the failed-drop spring, the
/// vertical a little slower), from the size and place the system last drew
/// it back to its own, letting its shadow go as it settles. It never fades:
/// home, it lies exactly on the item, which takes over.
///
/// So the item never vanishes for a frame at the drop (the system takes its
/// image away before the drag's end reaches the app), the same picture lies
/// under the system's image wherever the pointer rests, in a clear window
/// over every display; it is withdrawn the moment the pointer moves again
/// (it would trail the system's image) and at once after a successful drop.
@MainActor
final class AtticDragReturn {
    private let shadowed: NSImage?
    private let plain: NSImage
    private let home: () -> CGRect?
    private let reduceMotion: Bool
    private let window: NSWindow
    private let shadowLayer = CALayer()
    private let cardLayer = CALayer()
    private var rest: DispatchWorkItem?
    private var lastDrawn: CGRect?
    private(set) var isResting = false
    /// How long the pointer rests before the picture lies under the
    /// system's image (two frames: a slower pointer reads as resting).
    nonisolated static let restDelay: TimeInterval = 0.035

    init(shadowed: NSImage?, plain: NSImage, home: @escaping () -> CGRect?, level: NSWindow.Level, reduceMotion: Bool) {
        self.shadowed = shadowed
        self.plain = plain
        self.home = home
        self.reduceMotion = reduceMotion
        let all = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let window = NSPanel(contentRect: all.isNull ? CGRect(x: 0, y: 0, width: 10, height: 10) : all,
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: level.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        window.animationBehavior = .none
        let host = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        host.wantsLayer = true
        window.contentView = host
        for (layer, image) in [(shadowLayer, shadowed), (cardLayer, plain as NSImage?)] {
            layer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            layer.contentsScale = window.backingScaleFactor
            layer.anchorPoint = .zero
            layer.isHidden = true
            host.layer?.addSublayer(layer)
        }
        self.window = window
        window.orderFrontRegardless()
    }

    /// The way home for a drag the system began from a view's own picture
    /// (a SwiftUI drag, a text view's selection): its image and the place
    /// it starts from, which is where the item lies. Nil without an image.
    static func starting(_ session: NSDraggingSession, level: NSWindow.Level?) -> AtticDragReturn? {
        var image: NSImage?
        var frame: CGRect?
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, stop in
            frame = item.draggingFrame
            if let contents = item.imageComponents?.first?.contents {
                if let picture = contents as? NSImage {
                    image = picture
                } else if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                    let cgImage = contents as! CGImage
                    image = NSImage(cgImage: cgImage, size: item.draggingFrame.size)
                }
            }
            stop.pointee = true
        }
        guard let image, let home = frame, home.width > 1, home.height > 1 else { return nil }
        return AtticDragReturn(shadowed: nil, plain: image, home: { home }, level: level ?? .floating,
                               reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Where the system draws the drag's image now, on screen.
    static func drawnFrame(of session: NSDraggingSession) -> CGRect? {
        var drawn: CGRect?
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, stop in
            drawn = item.draggingFrame
            stop.pointee = true
        }
        return drawn
    }

    private func place(_ frame: CGRect) {
        let origin = CGPoint(x: frame.minX - window.frame.minX, y: frame.minY - window.frame.minY)
        for layer in [shadowLayer, cardLayer] {
            layer.position = origin
            layer.bounds = CGRect(origin: .zero, size: frame.size)
        }
    }

    private func show(_ shown: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.isHidden = !shown || shadowed == nil
        cardLayer.isHidden = !shown
        CATransaction.commit()
        isResting = shown
    }

    /// The pointer moved: the picture is withdrawn, and lies under the
    /// system's image again once the pointer rests.
    func moved(drawn: CGRect?) {
        rest?.cancel()
        if isResting { show(false) }
        guard let drawn, !reduceMotion else { return }
        lastDrawn = drawn
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let frame = self.lastDrawn else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.place(frame)
                CATransaction.commit()
                self.show(true)
            }
        }
        rest = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restDelay, execute: work)
    }

    /// The drag ended. Cancelled, the item springs home and `done` runs
    /// once it is there; dropped, the picture goes at once.
    func ended(operation: NSDragOperation, drawn start: CGRect, done: @escaping () -> Void) {
        rest?.cancel()
        guard operation.isEmpty, !reduceMotion, let home = home() else {
            close()
            done()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(start)
        CATransaction.commit()
        show(true)
        springHome(from: start, to: home, done: done)
    }

    private func close() {
        rest?.cancel()
        window.orderOut(nil)
    }

    private func springHome(from start: CGRect, to home: CGRect, done: @escaping () -> Void) {
        let spring = AtticMotionPreset.failReturn.spring(in: .current)
        let to = CGPoint(x: home.minX - window.frame.minX, y: home.minY - window.frame.minY)
        let from = CGPoint(x: start.minX - window.frame.minX, y: start.minY - window.frame.minY)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                // Home: the item takes over the picture's place.
                self?.close()
                done()
            }
        }
        var settle: CFTimeInterval = 0
        let tracks: [(String, Any, Any, Double)] = [
            ("position.x", from.x, to.x, 1.0), ("position.y", from.y, to.y, 1.18),
            // Back to the item's own size, from what the system drew.
            ("bounds.size", NSValue(size: start.size), NSValue(size: home.size), 1.0)
        ]
        for (key, fromValue, value, slower) in tracks {
            let animation = CASpringAnimation(perceptualDuration: spring.response * slower, bounce: spring.bounce)
            animation.fromValue = fromValue
            animation.toValue = value
            animation.fillMode = .both
            animation.duration = animation.settlingDuration
            settle = max(settle, animation.settlingDuration)
            for target in [shadowLayer, cardLayer] {
                target.add(animation, forKey: key)
            }
        }
        for target in [shadowLayer, cardLayer] {
            target.position = to
            target.bounds.size = home.size
        }
        if shadowed != nil {
            // The shadow lets go over the second half of the way.
            let shadow = CABasicAnimation(keyPath: "opacity")
            shadow.fromValue = 1
            shadow.toValue = 0
            shadow.beginTime = CACurrentMediaTime() + settle * 0.35
            shadow.duration = settle * 0.4
            shadow.fillMode = .both
            shadow.timingFunction = AtticMotionScale.easeOutTimingFunction
            shadowLayer.add(shadow, forKey: "opacity")
            shadowLayer.opacity = 0
        }
        CATransaction.commit()
    }

    #if DEBUG
    var windowForTesting: NSWindow { window }
    #endif
}
