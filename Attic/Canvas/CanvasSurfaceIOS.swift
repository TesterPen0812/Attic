#if os(iOS)
import SwiftUI
import UIKit

struct CanvasUIViewRepresentable: UIViewRepresentable {
    @ObservedObject var session: CanvasSession

    func makeUIView(context: Context) -> CanvasUIView {
        let view = CanvasUIView()
        configure(view)
        return view
    }

    func updateUIView(
        _ uiView: CanvasUIView,
        context: Context
    ) {
        configure(uiView)
    }

    static func dismantleUIView(
        _ uiView: CanvasUIView,
        coordinator: ()
    ) {
        uiView.cancelInteraction()
    }

    private func configure(_ view: CanvasUIView) {
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
final class CanvasUIView: UIView, UIGestureRecognizerDelegate {
    var onCompleteStroke: (
        _ points: [CanvasPoint],
        _ color: CanvasInkColor,
        _ width: Double
    ) -> Void = { _, _, _ in }
    var onErase: (Set<UUID>) -> Void = { _ in }
    var onViewportChange: (CanvasViewport) -> Void = { _ in }

    private let interaction = CanvasInteractionController()
    private let pathCache = CanvasPathCache()
    private var activeTouch: UITouch?
    private var activeViewportGestureCount = 0
    private var appResignObservation: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isMultipleTouchEnabled = true
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "Canvas drawing board"
        accessibilityIdentifier = "canvas-surface"
        accessibilityTraits = [.allowsDirectInteraction]

        let pan = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePan(_:))
        )
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delegate = self
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(
            target: self,
            action: #selector(handlePinch(_:))
        )
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.delegate = self
        addGestureRecognizer(pinch)

        appResignObservation = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
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
            setNeedsDisplay()
        }
        let count = strokes.count
        let strokeSummary = count == 1 ? "1 stroke" : "\(count) strokes"
        accessibilityValue = "\(strokeSummary), \(tool.title) selected"
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelInteraction()
        }
    }

    override func traitCollectionDidChange(
        _ previousTraitCollection: UITraitCollection?
    ) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }

        drawCanvas(
            in: context,
            bounds: bounds,
            interaction: interaction,
            pathCache: pathCache,
            backgroundColor: UIColor.secondarySystemBackground.cgColor,
            strokeColor: { $0.uiColor.cgColor },
            eraserOutlineColor: tintColor.cgColor
        )
    }

    override func touchesBegan(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        let liveTouchCount = event?.allTouches?
            .filter { $0.phase != .ended && $0.phase != .cancelled }
            .count ?? touches.count
        guard activeTouch == nil,
              activeViewportGestureCount == 0,
              touches.count == 1,
              liveTouchCount == 1,
              let touch = touches.first else {
            discardDirectInk()
            return
        }

        activeTouch = touch
        if interaction.beginInk(
            at: touch.location(in: self),
            in: bounds.size
        ) {
            setNeedsDisplay()
        }
    }

    override func touchesMoved(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        guard let activeTouch,
              touches.contains(where: { $0 === activeTouch }) else {
            return
        }

        let samples = event?.coalescedTouches(
            for: activeTouch
        ) ?? [activeTouch]
        var changed = false
        for sample in samples {
            changed = interaction.appendInk(
                at: sample.location(in: self),
                in: bounds.size
            ) || changed
        }
        if changed {
            setNeedsDisplay()
        }
    }

    override func touchesEnded(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        guard let activeTouch,
              touches.contains(where: { $0 === activeTouch }) else {
            return
        }
        _ = interaction.appendInk(
            at: activeTouch.location(in: self),
            in: bounds.size
        )
        self.activeTouch = nil
        finishInk()
    }

    override func touchesCancelled(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        guard let activeTouch,
              touches.contains(where: { $0 === activeTouch }) else {
            return
        }
        self.activeTouch = nil
        if activeViewportGestureCount == 0,
           interaction.cancel() {
            setNeedsDisplay()
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer.view === self && otherGestureRecognizer.view === self
    }

    func cancelInteraction() {
        activeTouch = nil
        activeViewportGestureCount = 0
        if interaction.cancel() {
            setNeedsDisplay()
        }
    }

    @objc
    private func handlePan(
        _ recognizer: UIPanGestureRecognizer
    ) {
        switch recognizer.state {
        case .began:
            beginViewportGesture()
            recognizer.setTranslation(.zero, in: self)
        case .changed:
            let translation = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            let viewport = interaction.pan(
                byViewTranslation: CGSize(
                    width: translation.x,
                    height: translation.y
                )
            )
            onViewportChange(viewport)
            setNeedsDisplay()
        case .ended, .cancelled, .failed:
            endViewportGesture()
        case .possible:
            break
        @unknown default:
            endViewportGesture()
        }
    }

    @objc
    private func handlePinch(
        _ recognizer: UIPinchGestureRecognizer
    ) {
        switch recognizer.state {
        case .began:
            beginViewportGesture()
            recognizer.scale = 1
        case .changed:
            let factor = Double(recognizer.scale)
            recognizer.scale = 1
            let viewport = interaction.zoom(
                by: factor,
                anchoredAt: recognizer.location(in: self),
                in: bounds.size
            )
            onViewportChange(viewport)
            setNeedsDisplay()
        case .ended, .cancelled, .failed:
            endViewportGesture()
        case .possible:
            break
        @unknown default:
            endViewportGesture()
        }
    }

    private func beginViewportGesture() {
        if activeViewportGestureCount == 0 {
            discardDirectInk()
            _ = interaction.beginViewportGesture()
        }
        activeViewportGestureCount += 1
        setNeedsDisplay()
    }

    private func endViewportGesture() {
        guard activeViewportGestureCount > 0 else { return }
        activeViewportGestureCount -= 1
        if activeViewportGestureCount == 0 {
            interaction.finishViewportGesture()
        }
    }

    private func discardDirectInk() {
        activeTouch = nil
        if interaction.machine.state == .drawing
            || interaction.machine.state == .erasing {
            if interaction.cancel() {
                setNeedsDisplay()
            }
        }
    }

    private func finishInk() {
        let completion = interaction.finishInk()
        setNeedsDisplay()
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
    var uiColor: UIColor {
        switch self {
        case .ink: .label
        case .blue: .systemBlue
        case .red: .systemRed
        case .green: .systemGreen
        case .orange: .systemOrange
        }
    }
}
#endif
