import AppKit
import QuartzCore
import SwiftUI

/// A drag of tasks out of the panel into another app (owner-approved,
/// 2026-10-01): an AppKit dragging session carrying `TasksTextExport`'s
/// text, Markdown and RTF, plus promised text and attachment files for
/// Finder. Always a copy; the panel's data never changes.
@MainActor
enum TasksDragOut {
    static func begin(_ export: TasksTextExport, count: Int, from view: NSView, at location: CGPoint,
                      card: Card? = nil, files: TaskImageFiles = .shared, ended: @escaping () -> Void) {
        guard let window = view.window else { card?.handOff(); card?.settled(); ended(); return }
        let item = leadingItem(for: export, count: count, at: location, card: card)
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

    /// The drag's first item: the tasks' text and files promise. O14-11:
    /// at the lifted card's place, so the hand-off from the panel's lift to
    /// the drag does not move what is under the pointer; without a card, a
    /// quiet label at the pointer. V-09: with a card, the system's image is
    /// clear: the card itself (`AtticDragReturn`) is the drag's one picture.
    static func leadingItem(for export: TasksTextExport, count: Int, at location: CGPoint, card: Card?) -> NSDraggingItem {
        let item = NSDraggingItem(pasteboardWriter: export.dragWriter())
        if let card {
            item.setDraggingFrame(card.frame, contents: AtticDragReturn.clearImage(size: card.images.shadowed.size))
        } else {
            let image = Self.image(title: count == 1 ? export.items.first?.title ?? "" : String(localized: "\(count) tasks"))
            item.setDraggingFrame(CGRect(x: location.x - image.size.width / 2, y: location.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
        }
        return item
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
        /// K-04 evidence, on screen: the last cancelled file's home, where
        /// it started home from, and the picture's window frame then.
        @Published var fileHome: CGRect?
        @Published var fileStart: CGRect?
        @Published var fileWindow: CGRect?
        /// The last start less its release point (the grip's offset).
        var state: String {
            var text = "began \(began) ended \(ended)"
            if let lastStart, let lastRelease {
                text += String(format: " start %.0f,%.0f release %.0f,%.0f", lastStart.minX, lastStart.minY, lastRelease.x, lastRelease.y)
                if let lastReported {
                    text += String(format: " reported %.0f,%.0f", lastReported.minX, lastReported.minY)
                }
            }
            if let fileHome, let fileStart {
                text += String(format: " file home %.0f,%.0f,%.0f,%.0f start %.0f,%.0f", fileHome.minX, fileHome.minY,
                               fileHome.width, fileHome.height, fileStart.minX, fileStart.minY)
                if let fileWindow {
                    text += String(format: " window %.0f,%.0f,%.0f,%.0f", fileWindow.minX, fileWindow.minY, fileWindow.width, fileWindow.height)
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
            // V-09: the drag's picture shows where the panel's card lies,
            // then the card goes: one card throughout.
            if let card, dragReturn == nil {
                dragReturn = AtticDragReturn(shadowed: card.images.shadowed, plain: card.images.plain, home: card.home,
                                             level: level, reduceMotion: card.reduceMotion)
                dragReturn?.moved(drawn: grip.frame(at: NSEvent.mouseLocation))
            }
            card?.handOff()
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
/// V-09: it is the drag's only picture, from the moment the drag begins:
/// the system's own image is clear (`clearImage`), and this one follows the
/// pointer in a clear window over every display. The system shrinks,
/// gathers and moves its image over other apps and destinations, so a
/// second picture resting under it showed as a second card. So the item
/// never vanishes for a frame at the drop, and springs home from exactly
/// what was on screen; a successful drop takes it away at once.
@MainActor
final class AtticDragReturn {
    private let shadowed: NSImage?
    private let plain: NSImage
    private let home: () -> CGRect?
    private let reduceMotion: Bool
    private let window: NSWindow
    private let shadowLayer = CALayer()
    private let cardLayer = CALayer()
    private var lastDrawn: CGRect?
    /// Shown: the drag's picture is on screen.
    private(set) var isShown = false
    /// V-09: the system's own drag image is clear for a drag that carries
    /// this picture (`clearImage`), so this is the drag's only picture.
    static func clearImage(size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { _ in true }
    }

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
                         level: NSWindow.Level?, source: CGRect? = nil) -> (dragReturn: AtticDragReturn, grip: AtticDragGrip)? {
        guard let window = view.window else { return nil }
        var image: NSImage?
        var frame: CGRect?
        var inWindow: CGRect?
        session.enumerateDraggingItems(options: [], for: view, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, stop in
            // K-04: a SwiftUI drag reports its item's place relative to the
            // pointer, not in the view (read as the view's, it lay at the
            // screen's far left). The picture lies at its component's offset
            // from the dragged view, so that view's own frame, recorded as
            // its drag began (`source`, SwiftUI's global space: the window's
            // content, from its top left), places it; without one, the
            // reported frame, in the view.
            let component = item.imageComponents?.first
            if let source, let component, let height = window.contentView?.bounds.height {
                inWindow = pictureFrame(dragged: source, component: component.frame, contentHeight: height)
                frame = inWindow
            } else {
                frame = item.draggingFrame
            }
            if let contents = component?.contents {
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
        let home = window.convertToScreen(inWindow ?? view.convert(frame, to: nil))
        let dragReturn = AtticDragReturn(shadowed: nil, plain: image, home: { home }, level: level ?? .floating,
                                         reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        return (dragReturn, AtticDragGrip(image: home, pointer: screenPoint))
    }

    /// Where a SwiftUI view that starts a drag lies, in SwiftUI's global
    /// space (its window's content, from the top left), handed to the host as the drag
    /// begins (K-04). A reference, so recording it re-renders nothing.
    @MainActor
    final class SourceFrame {
        var frame: CGRect = .zero
        /// The view whose drag begins next; taken once by the host.
        static var next: CGRect?
        static func take() -> CGRect? {
            defer { next = nil }
            return next.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil }
        }
    }

    /// K-04: where a SwiftUI drag's picture lies in its window (the
    /// window's base space): its component's offset from the dragged view,
    /// whose frame is in SwiftUI's global space (the window's content, from
    /// the top left). Pure, tested.
    nonisolated static func pictureFrame(dragged source: CGRect, component: CGRect, contentHeight: CGFloat) -> CGRect {
        CGRect(x: source.minX + component.minX, y: contentHeight - source.maxY + component.minY,
               width: component.width, height: component.height)
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
        isShown = shown
    }

    /// The pointer moved: the picture is withdrawn, and lies under the
    /// system's image again once the pointer rests.
    func moved(drawn: CGRect?) {
        guard let drawn else { return }
        lastDrawn = drawn
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(drawn)
        CATransaction.commit()
        if !isShown { show(true) }
    }

    /// The drag ended. Cancelled, the item springs home and `done` runs
    /// once it is there; dropped, the picture goes at once.
    func ended(operation: NSDragOperation, drawn start: CGRect, done: @escaping () -> Void) {
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
        window.orderOut(nil)
    }

    private func springHome(from start: CGRect, to home: CGRect, done: @escaping () -> Void) {
        let spring = AtticMotionPreset.failReturn.spring(in: .current)
        let to = CGPoint(x: home.minX - window.frame.minX, y: home.minY - window.frame.minY)
        let from = CGPoint(x: start.minX - window.frame.minX, y: start.minY - window.frame.minY)
        CATransaction.begin()
        // Only the release-point springs animate. Model writes must not
        // add an implicit position/bounds action from the hidden overlay.
        CATransaction.setDisableActions(true)
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

    /// Evidence (K-04): where the item lies, and the picture's window.
    var homeOnScreen: CGRect? { home() }
    var windowFrame: CGRect { window.frame }

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
