import AppKit
import QuartzCore
import SwiftUI

/// A drag of tasks out of the panel into another app (owner-approved,
/// 2026-10-01): an AppKit dragging session carrying `TasksTextExport`'s
/// text, Markdown and RTF. Always a copy; the panel's data never changes.
@MainActor
enum TasksDragOut {
    static func begin(_ export: TasksTextExport, count: Int, from view: NSView, at location: CGPoint,
                      card: Card? = nil, files: TaskImageFiles = .shared, ended: @escaping () -> Void) {
        guard let window = view.window else { card?.handOff(); card?.settled(); ended(); return }
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
        guard let event else { card?.handOff(); card?.settled(); ended(); return }
        let source = Source(ended: ended)
        if let card {
            // O17-12: where the image lies against the pointer, on screen.
            // The system keeps it there for the whole drag, so the release
            // point and this grip give where a cancelled card starts home
            // from, in screen space, whatever the session reports.
            let imageOnScreen = window.convertToScreen(view.convert(card.frame, to: nil))
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            source.card = card
            source.grip = AtticDragGrip(image: imageOnScreen, pointer: pointer)
            source.level = window.level
        }
        // O17-15: each task's files go with its text, as file promises the
        // receiver writes where it wants them (Finder, Mail, Notes…). They
        // add no picture of their own: the card (or the label) stands for
        // the whole drag.
        let attachments = attachmentItems(for: export, files: files, frame: item.draggingFrame)
        Source.current = source
        let session = view.beginDraggingSession(with: [item] + attachments, event: event, source: source)
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

        init(images: Images, frame: CGRect, home: @escaping () -> CGRect?, reduceMotion: Bool,
             handOff: @escaping () -> Void, settled: @escaping () -> Void = {}) {
            self.images = images
            self.frame = frame
            self.home = home
            self.reduceMotion = reduceMotion
            self.handOff = handOff
            self.settled = settled
        }
    }

    /// The tasks' files as dragging items (O17-15): one file promise each,
    /// with no picture of its own, at the text's frame.
    static func attachmentItems(for export: TasksTextExport, files: TaskImageFiles, frame: CGRect) -> [NSDraggingItem] {
        export.items.flatMap(\.files).map { reference in
            let attachment = NSDraggingItem(pasteboardWriter: TaskAttachmentFilePromise(reference: reference, files: files))
            attachment.setDraggingFrame(frame, contents: nil)
            return attachment
        }
    }

    /// UI tests: how many sessions began and ended (shown, under
    /// `ATTIC_UI_TESTING`, by the page's `tasks-drag-out-state` element).
    final class Probe: ObservableObject {
        static let shared = Probe()
        @Published var began = 0
        @Published var ended = 0
        /// O17-12 evidence, on screen: where the last cancelled card
        /// started home from, the pointer it was released at, and the
        /// frame the session itself reported for its image then.
        @Published var lastStart: CGRect?
        @Published var lastRelease: CGPoint?
        @Published var lastReported: CGRect?
        /// The last start less its release point (the grip's offset).
        var state: String {
            var text = "began \(began) ended \(ended)"
            if let lastStart, let lastRelease {
                text += String(format: " start %.0f,%.0f release %.0f,%.0f", lastStart.minX, lastStart.minY, lastRelease.x, lastRelease.y)
                if let lastReported {
                    text += String(format: " reported %.0f,%.0f", lastReported.minX, lastReported.minY)
                }
            }
            return text
        }
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
        var grip = AtticDragGrip(offset: .zero, size: .zero)
        var level: NSWindow.Level = .floating
        private var handedOff = false
        /// The card's way home after a cancelled drop.
        private var dragReturn: AtticDragReturn?
        #if DEBUG
        var dragReturnForTesting: AtticDragReturn? { dragReturn }
        #endif

        init(ended: @escaping () -> Void) {
            self.ended = ended
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // A copy, never a move: nothing leaves Attic.
            TasksDragOut.operations(for: context)
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            handOffOnce()
            dragReturn?.moved(drawn: grip.frame(at: screenPoint))
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ended(at: screenPoint, operation: operation, reported: AtticDragReturn.reportedFrame(of: session))
        }

        /// The session ended at `screenPoint` (internal for the tests).
        /// The card starts home from exactly where it was let go: the
        /// release point and the grip, both on screen. `reported` (the
        /// session's own frame for its image) is kept as evidence only: it
        /// is not where the image was drawn (O17-12, the corner jump).
        func ended(at screenPoint: NSPoint, operation: NSDragOperation, reported: CGRect? = nil) {
            handOffOnce()
            let start = grip.frame(at: screenPoint)
            if operation.isEmpty, card != nil {
                Probe.shared.lastStart = start
                Probe.shared.lastRelease = screenPoint
                Probe.shared.lastReported = reported
            }
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
    /// (a SwiftUI drag, a text view's selection): its image, where it lies
    /// (home) and how it lies against the pointer (`grip`), all on screen.
    /// The item's frame is read in `view`'s own space and converted here,
    /// never taken as screen space from the session (O17-12). Nil without
    /// an image or a window.
    static func starting(_ session: NSDraggingSession, from view: NSView, at screenPoint: CGPoint,
                         level: NSWindow.Level?) -> (dragReturn: AtticDragReturn, grip: AtticDragGrip)? {
        guard let window = view.window else { return nil }
        var image: NSImage?
        var frame: CGRect?
        session.enumerateDraggingItems(options: [], for: view, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, stop in
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
        guard let image, let frame, frame.width > 1, frame.height > 1 else { return nil }
        let home = window.convertToScreen(view.convert(frame, to: nil))
        let dragReturn = AtticDragReturn(shadowed: nil, plain: image, home: { home }, level: level ?? .floating,
                                         reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        return (dragReturn, AtticDragGrip(image: home, pointer: screenPoint))
    }

    /// The frame the session reports for its first item, asked for in
    /// screen space. Evidence only (`TasksDragOut.Probe`): at the end of a
    /// drag it is not where the system drew the image (O17-12).
    static func reportedFrame(of session: NSDraggingSession) -> CGRect? {
        var reported: CGRect?
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, stop in
            reported = item.draggingFrame
            stop.pointee = true
        }
        return reported
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
        #if DEBUG
        startOnScreen = CGRect(origin: CGPoint(x: cardLayer.position.x + window.frame.minX, y: cardLayer.position.y + window.frame.minY),
                               size: cardLayer.bounds.size)
        #endif
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
    /// Where the picture lay, on screen, the moment it began home.
    private(set) var startOnScreen: CGRect?
    #endif
}

/// How a dragged picture lies against the pointer (O17-12): its offset from
/// the pointer and its size, on screen. The system moves the picture with
/// the pointer and keeps this offset for the whole drag, so a release point
/// gives exactly where the picture was let go. Pure, tested.
struct AtticDragGrip: Equatable {
    /// The picture's origin less the pointer, in screen points.
    let offset: CGPoint
    let size: CGSize

    init(offset: CGPoint, size: CGSize) {
        self.offset = offset
        self.size = size
    }

    /// The picture at `image` while the pointer is at `pointer` (both on
    /// screen).
    init(image: CGRect, pointer: CGPoint) {
        self.init(offset: CGPoint(x: image.minX - pointer.x, y: image.minY - pointer.y), size: image.size)
    }

    /// Where the picture lies when the pointer is at `pointer` (screen).
    func frame(at pointer: CGPoint) -> CGRect {
        CGRect(origin: CGPoint(x: pointer.x + offset.x, y: pointer.y + offset.y), size: size)
    }
}


/// Something in a window that takes dropped files and knows where each
/// lands (O17-13): the Tasks page, whose row puts a dropped file in its
/// files list.
@MainActor
protocol AtticDropLandingSource: AnyObject {
    /// The view whose space `landingSlot(at:)` answers in.
    var landingView: NSView? { get }
    /// Where something dropped at `point` settles, or nil when nothing
    /// there takes it.
    func landingSlot(at point: CGPoint) -> CGRect?
}

/// A drop that lands (O17-13): an accepted drop's picture settles into the
/// place its item goes, shrinking into it on the system's own destination
/// animation, instead of vanishing where it was let go. The window's host
/// asks before the drop is performed (`slot`) and moves the pictures once
/// it is (`land`).
@MainActor
enum AtticDropLanding {
    private struct Entry {
        weak var source: AtticDropLandingSource?
    }

    private static var entries: [Entry] = []

    static func register(_ source: AtticDropLandingSource) {
        entries.removeAll { $0.source == nil || $0.source === source }
        entries.append(Entry(source: source))
    }

    /// Where a drop at `windowPoint` (the window's space) lands, in
    /// `view`'s space: the first shown source in the same window that
    /// takes it.
    static func slot(at windowPoint: CGPoint, in view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        entries.removeAll { $0.source == nil }
        for entry in entries {
            guard let source = entry.source, let landing = source.landingView, landing.window === window,
                  !landing.isHiddenOrHasHiddenAncestor,
                  let slot = source.landingSlot(at: landing.convert(windowPoint, from: nil)) else { continue }
            return view.convert(landing.convert(slot, to: nil), from: nil)
        }
        return nil
    }

    /// A picture of `size` settled into `slot`: as large as fits, its own
    /// shape kept, centred. Pure, tested.
    nonisolated static func frame(for size: CGSize, in slot: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return slot }
        let scale = min(slot.width / size.width, slot.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: slot.midX - fitted.width / 2, y: slot.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// Before the drop is performed (after the host's own preparation):
    /// a drop the host takes, over a place that knows where it lands, will
    /// animate there. The slot, in `view`'s space, or nil.
    static func prepare(_ info: NSDraggingInfo, accepted: Bool, in view: NSView) -> CGRect? {
        guard accepted, let slot = slot(at: info.draggingLocation, in: view) else { return nil }
        info.animatesToDestination = true
        return slot
    }

    /// After the drop is performed: taken, its pictures go to `slot`.
    static func perform(_ info: NSDraggingInfo, accepted: Bool, slot: CGRect?, in view: NSView) {
        guard accepted, let slot else { return }
        land(info, in: view, slot: slot)
    }

    /// The drop was taken: each picture goes to `slot` (`view`'s space).
    static func land(_ info: NSDraggingInfo, in view: NSView, slot: CGRect) {
        info.enumerateDraggingItems(options: [], for: view, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            item.draggingFrame = frame(for: item.draggingFrame.size, in: slot)
        }
    }
}
