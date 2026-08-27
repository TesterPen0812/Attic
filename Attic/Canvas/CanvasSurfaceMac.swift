#if os(macOS)
import AppKit
import SwiftUI

struct CanvasNSViewRepresentable: NSViewRepresentable {
    @ObservedObject var session: CanvasSession

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView()
        configure(view)
        return view
    }

    func updateNSView(
        _ nsView: CanvasNSView,
        context: Context
    ) {
        configure(nsView)
    }

    static func dismantleNSView(
        _ nsView: CanvasNSView,
        coordinator: ()
    ) {
        nsView.cancelInteraction()
    }

    private func configure(_ view: CanvasNSView) {
        view.onCompleteStroke = { [weak session] points, color, width in
            _ = session?.completeStroke(
                points: points,
                color: color,
                width: width
            )
        }
        view.onErase = { [weak session] ids in
            _ = session?.erase(strokeIDs: ids)
        }
        view.onViewportChange = { [weak session] viewport in
            session?.setViewport(viewport)
        }
        view.configure(
            strokes: session.strokes,
            tool: session.tool,
            color: session.color,
            width: session.width,
            viewport: session.viewport
        )
    }
}

@MainActor
final class CanvasNSView: NSView {
    var onCompleteStroke: (
        _ points: [CanvasPoint],
        _ color: CanvasInkColor,
        _ width: Double
    ) -> Void = { _, _, _ in }
    var onErase: (Set<UUID>) -> Void = { _ in }
    var onViewportChange: (CanvasViewport) -> Void = { _ in }

    private let interaction = CanvasInteractionController()
    private let pathCache = CanvasPathCache()
    private var panLastPoint: CGPoint?
    private var spacePressed = false
    private var appResignObservation: NSObjectProtocol?
    private var windowResignObservation: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        appResignObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelInteraction()
            }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let appResignObservation {
            NotificationCenter.default.removeObserver(appResignObservation)
        }
        if let windowResignObservation {
            NotificationCenter.default.removeObserver(windowResignObservation)
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(
        for event: NSEvent?
    ) -> Bool {
        true
    }

    func configure(
        strokes: [CanvasStroke],
        tool: CanvasTool,
        color: CanvasInkColor,
        width: Double,
        viewport: CanvasViewport
    ) {
        if interaction.configure(
            strokes: strokes,
            tool: tool,
            color: color,
            width: width,
            viewport: viewport
        ) {
            needsDisplay = true
        }
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let windowResignObservation {
            NotificationCenter.default.removeObserver(windowResignObservation)
            self.windowResignObservation = nil
        }
        guard let window else {
            cancelInteraction()
            return
        }

        windowResignObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelInteraction()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(
            bounds,
            cursor: spacePressed ? .openHand : .crosshair
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        drawCanvas(
            in: context,
            bounds: bounds,
            interaction: interaction,
            pathCache: pathCache,
            backgroundColor: NSColor.controlBackgroundColor.cgColor,
            strokeColor: { $0.nsColor.cgColor },
            eraserOutlineColor: NSColor.controlAccentColor.cgColor
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if spacePressed {
            beginPan(at: point)
        } else if interaction.beginInk(at: point, in: bounds.size) {
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if spacePressed {
            if interaction.machine.state != .panning {
                beginPan(at: point)
            } else {
                continuePan(to: point)
            }
        } else if interaction.machine.state == .panning {
            continuePan(to: point)
        } else if interaction.appendInk(at: point, in: bounds.size) {
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        finishPointerInteraction(
            finalInkPoint: convert(event.locationInWindow, from: nil)
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginPan(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDragged(with event: NSEvent) {
        continuePan(to: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseUp(with event: NSEvent) {
        finishPointerInteraction(finalInkPoint: nil)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginPan(at: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseDragged(with event: NSEvent) {
        continuePan(to: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseUp(with event: NSEvent) {
        finishPointerInteraction(finalInkPoint: nil)
    }

    override func scrollWheel(with event: NSEvent) {
        _ = interaction.cancel()
        let viewport = interaction.pan(byViewTranslation: CGSize(
            width: event.scrollingDeltaX,
            height: event.scrollingDeltaY
        ))
        onViewportChange(viewport)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        _ = interaction.cancel()
        let point = convert(event.locationInWindow, from: nil)
        let viewport = interaction.zoom(
            by: max(1 + Double(event.magnification), 0.01),
            anchoredAt: point,
            in: bounds.size
        )
        onViewportChange(viewport)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49 else {
            super.keyDown(with: event)
            return
        }

        if !spacePressed {
            cancelInteraction()
            spacePressed = true
            window?.invalidateCursorRects(for: self)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49 else {
            super.keyUp(with: event)
            return
        }

        spacePressed = false
        if interaction.machine.state == .panning {
            interaction.finishViewportGesture()
            panLastPoint = nil
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resignFirstResponder() -> Bool {
        cancelInteraction()
        return super.resignFirstResponder()
    }

    func cancelInteraction() {
        if interaction.cancel() {
            needsDisplay = true
        }
        panLastPoint = nil
        spacePressed = false
        window?.invalidateCursorRects(for: self)
    }

    private func beginPan(at point: CGPoint) {
        _ = interaction.beginViewportGesture()
        panLastPoint = point
        needsDisplay = true
    }

    private func continuePan(to point: CGPoint) {
        guard let panLastPoint else { return }
        let translation = CGSize(
            width: point.x - panLastPoint.x,
            height: point.y - panLastPoint.y
        )
        self.panLastPoint = point
        let viewport = interaction.pan(
            byViewTranslation: translation
        )
        onViewportChange(viewport)
        needsDisplay = true
    }

    private func finishPointerInteraction(
        finalInkPoint: CGPoint?
    ) {
        if interaction.machine.state == .panning {
            interaction.finishViewportGesture()
            panLastPoint = nil
            return
        }

        if let finalInkPoint {
            _ = interaction.appendInk(
                at: finalInkPoint,
                in: bounds.size
            )
        }
        let completion = interaction.finishInk()
        needsDisplay = true
        switch completion {
        case let .stroke(points, color, width):
            onCompleteStroke(points, color, width)
        case let .erase(ids):
            onErase(ids)
        case nil:
            break
        }
    }
}

extension CanvasInkColor {
    var nsColor: NSColor {
        switch self {
        case .ink: .labelColor
        case .blue: .systemBlue
        case .red: .systemRed
        case .green: .systemGreen
        case .orange: .systemOrange
        }
    }
}
#endif
