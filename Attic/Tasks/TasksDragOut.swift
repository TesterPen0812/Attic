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
        /// The window the card springs home in, held while it moves.
        private var springWindow: NSWindow?

        init(ended: @escaping () -> Void) {
            self.ended = ended
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // A copy, never a move: nothing leaves Attic.
            TasksDragOut.operations(for: context)
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            handOffOnce()
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            // Where the system drew the image last (on screen): AppKit
            // narrows a wide drag image to 200 pt as it leaves, so the
            // card goes home from that size and place.
            var drawn: CGRect?
            session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, stop in
                drawn = item.draggingFrame
                stop.pointee = true
            }
            ended(at: screenPoint, operation: operation, drawn: drawn)
        }

        /// The session ended at `screenPoint` (internal for the tests).
        func ended(at screenPoint: NSPoint, operation: NSDragOperation, drawn: CGRect? = nil) {
            handOffOnce()
            // Dropped nowhere (Esc, back on the panel, a place that takes
            // nothing): the card springs home to its row.
            if operation.isEmpty, let card, !card.reduceMotion, let home = card.home() {
                let start = drawn.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil }
                    ?? CGRect(origin: CGPoint(x: screenPoint.x + imageOffset.x, y: screenPoint.y + imageOffset.y), size: imageSize)
                springHome(card, from: start, to: home)
                return
            }
            springWindow?.orderOut(nil)
            springWindow = nil
            card?.settled()
            finish()
        }

        func handOffOnce() {
            guard !handedOff else { return }
            handedOff = true
            card?.handOff()
            // Ready (and on screen, clear) before the drop, so a cancelled
            // card appears in the frame the system's image leaves.
            if card != nil, springWindow == nil {
                let window = makeSpringWindow()
                window.alphaValue = 0
                window.orderFrontRegardless()
                springWindow = window
            }
        }

        private func makeSpringWindow() -> NSWindow {
            let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: level.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
            window.animationBehavior = .none
            let host = NSView(frame: window.contentLayoutRect)
            host.wantsLayer = true
            window.contentView = host
            return window
        }

        /// The cancelled card goes back along a short curve (each axis on
        /// the failed-drop spring, the vertical a little slower) and
        /// settles on its row, its lift shadow going as it lands. It never
        /// fades: once home it lies exactly on the row, which takes over.
        private func springHome(_ card: Card, from start: CGRect, to home: CGRect) {
            let union = start.union(home).insetBy(dx: -40, dy: -40)
            let window = springWindow ?? makeSpringWindow()
            window.setFrame(union, display: false)
            let host = window.contentView!
            host.frame = CGRect(origin: .zero, size: union.size)
            host.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            func layer(_ image: NSImage) -> CALayer {
                let layer = CALayer()
                layer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                layer.contentsScale = window.backingScaleFactor
                layer.bounds = CGRect(origin: .zero, size: start.size)
                layer.anchorPoint = .zero
                layer.position = CGPoint(x: start.minX - union.minX, y: start.minY - union.minY)
                return layer
            }
            let shadowed = layer(card.images.shadowed)
            let plain = layer(card.images.plain)
            host.layer?.addSublayer(shadowed)
            host.layer?.addSublayer(plain)
            springWindow = window
            window.alphaValue = 1
            window.orderFrontRegardless()

            let spring = AtticMotionPreset.failReturn.spring(in: .current)
            let to = CGPoint(x: home.minX - union.minX, y: home.minY - union.minY)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Home: the row takes over the card's place.
                    self.springWindow?.orderOut(nil)
                    self.springWindow = nil
                    card.settled()
                    self.finish()
                }
            }
            var settle: CFTimeInterval = 0
            let size = home.size
            let tracks: [(String, Any, Any, Double)] = [
                ("position.x", shadowed.position.x, to.x, 1.0), ("position.y", shadowed.position.y, to.y, 1.18),
                // Back to the row's own size, from what the system drew.
                ("bounds.size", NSValue(size: start.size), NSValue(size: size), 1.0)
            ]
            for (key, from, value, slower) in tracks {
                let animation = CASpringAnimation(perceptualDuration: spring.response * slower, bounce: spring.bounce)
                animation.fromValue = from
                animation.toValue = value
                animation.fillMode = .both
                animation.duration = animation.settlingDuration
                settle = max(settle, animation.settlingDuration)
                for target in [shadowed, plain] {
                    target.add(animation, forKey: key)
                }
            }
            for target in [shadowed, plain] {
                target.position = to
                target.bounds.size = size
            }
            // The shadow lets go over the second half of the way.
            let shadow = CABasicAnimation(keyPath: "opacity")
            shadow.fromValue = 1
            shadow.toValue = 0
            shadow.beginTime = CACurrentMediaTime() + settle * 0.35
            shadow.duration = settle * 0.4
            shadow.fillMode = .both
            shadow.timingFunction = AtticMotionScale.easeOutTimingFunction
            shadowed.add(shadow, forKey: "opacity")
            shadowed.opacity = 0
            CATransaction.commit()
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
