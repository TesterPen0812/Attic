import CoreGraphics
import Foundation

enum CanvasSurfaceCompletion {
    case stroke(
        points: [CanvasPoint],
        color: CanvasInkColor,
        width: Double
    )
    case erase(Set<UUID>)
}

final class CanvasInteractionController {
    private(set) var strokes: [CanvasStroke] = []
    private(set) var tool: CanvasTool = .pen
    private(set) var color: CanvasInkColor = .ink
    private(set) var width: Double = 3
    private(set) var viewport = CanvasViewport()
    private(set) var machine = CanvasInputStateMachine()
    private(set) var activePath: CGPath?
    private(set) var eraserWorldPoint: CanvasPoint?
    private(set) var eraserRadiusWorld = 0.0

    private var strokeRenderKeys: [CanvasStrokeRenderKey] = []
    private var mutableActivePath: CGMutablePath?
    private var activeColor: CanvasInkColor = .ink
    private var activeWidth = 3.0
    private var lastAcceptedWorldPoint: CanvasPoint?
    private var erasedStrokeIDs: Set<UUID> = []

    var activeStrokeColor: CanvasInkColor { activeColor }
    var activeStrokeWidth: Double { activeWidth }

    @discardableResult
    func configure(
        strokes: [CanvasStroke],
        tool: CanvasTool,
        color: CanvasInkColor,
        width: Double,
        viewport: CanvasViewport
    ) -> Bool {
        let newRenderKeys = strokes.map(\.renderKey)
        let semanticContentChanged = strokeRenderKeys != newRenderKeys
        let styleChanged = self.tool != tool
            || self.color != color
            || self.width != width
        let viewportChanged = self.viewport != viewport

        let shouldCancelInk = (
            machine.state == .drawing || machine.state == .erasing
        ) && (semanticContentChanged || styleChanged || viewportChanged)
        let cancelled = shouldCancelInk ? cancel() : false

        if semanticContentChanged {
            self.strokes = strokes
            strokeRenderKeys = newRenderKeys
        }
        self.tool = tool
        self.color = color
        self.width = width
        self.viewport = viewport
        return cancelled
            || semanticContentChanged
            || styleChanged
            || viewportChanged
    }

    @discardableResult
    func beginInk(
        at viewPoint: CGPoint,
        in size: CGSize
    ) -> Bool {
        let worldPoint = viewport.worldPoint(
            for: viewPoint,
            in: size
        )
        guard machine.beginInk(tool: tool, at: worldPoint) else {
            return false
        }

        activeColor = color
        activeWidth = width
        lastAcceptedWorldPoint = worldPoint
        erasedStrokeIDs.removeAll(keepingCapacity: true)

        switch tool {
        case .pen:
            let path = CGMutablePath()
            path.move(to: worldPoint.cgPoint)
            // A zero-length segment with a round cap renders a dot.
            path.addLine(to: worldPoint.cgPoint)
            mutableActivePath = path
            activePath = path
            eraserWorldPoint = nil
        case .eraser:
            mutableActivePath = nil
            activePath = nil
            eraserRadiusWorld = max(12 / viewport.scale, 2)
            eraserWorldPoint = worldPoint
            accumulateEraseHits(along: [worldPoint])
        }
        return true
    }

    @discardableResult
    func appendInk(
        at viewPoint: CGPoint,
        in size: CGSize
    ) -> Bool {
        guard machine.state == .drawing || machine.state == .erasing else {
            return false
        }

        let worldPoint = viewport.worldPoint(
            for: viewPoint,
            in: size
        )
        guard worldPoint.isFinite else {
            return false
        }
        guard let previousPoint = lastAcceptedWorldPoint else { return false }

        let minimumDistance = max(0.65 / viewport.scale, 0.05)
        let distanceSquared = squaredDistance(
            from: previousPoint,
            to: worldPoint
        )
        guard distanceSquared.isFinite,
              distanceSquared >= minimumDistance * minimumDistance else {
            return false
        }

        machine.append(worldPoint)
        lastAcceptedWorldPoint = worldPoint

        switch machine.state {
        case .drawing:
            mutableActivePath?.addLine(to: worldPoint.cgPoint)
            activePath = mutableActivePath
        case .erasing:
            eraserWorldPoint = worldPoint
            accumulateEraseHits(along: [previousPoint, worldPoint])
        case .idle, .panning:
            break
        }
        return true
    }

    func finishInk() -> CanvasSurfaceCompletion? {
        let completion = machine.finishInk()
        let color = activeColor
        let width = activeWidth
        let erasedIDs = erasedStrokeIDs
        resetTransientState()

        switch completion {
        case let .stroke(points):
            return .stroke(
                points: points,
                color: color,
                width: width
            )
        case .erase:
            return erasedIDs.isEmpty ? nil : .erase(erasedIDs)
        case nil:
            return nil
        }
    }

    /// Viewport gestures own the interaction exclusively. Taking ownership
    /// discards any unfinished ink before the first pan or zoom delta applies.
    @discardableResult
    func beginViewportGesture() -> Bool {
        let discardedInk = machine.beginPan()
        resetTransientState(keepingMachineState: true)
        return discardedInk
    }

    func finishViewportGesture() {
        machine.finishPan()
    }

    @discardableResult
    func cancel() -> Bool {
        let cancelled = machine.cancel()
        resetTransientState()
        return cancelled
    }

    func pan(byViewTranslation translation: CGSize) -> CanvasViewport {
        viewport.pan(byViewTranslation: translation)
        return viewport
    }

    func zoom(
        by factor: Double,
        anchoredAt anchor: CGPoint,
        in size: CGSize
    ) -> CanvasViewport {
        viewport.zoom(by: factor, anchoredAt: anchor, in: size)
        return viewport
    }

    private func accumulateEraseHits(
        along points: [CanvasPoint]
    ) {
        let remainingStrokes = strokes.filter {
            !erasedStrokeIDs.contains($0.id)
        }
        erasedStrokeIDs.formUnion(
            CanvasHitTesting.strokeIDs(
                hitBy: points,
                radius: eraserRadiusWorld,
                strokes: remainingStrokes
            )
        )
    }

    private func resetTransientState(
        keepingMachineState: Bool = false
    ) {
        mutableActivePath = nil
        activePath = nil
        eraserWorldPoint = nil
        eraserRadiusWorld = 0
        lastAcceptedWorldPoint = nil
        erasedStrokeIDs.removeAll(keepingCapacity: true)
        if !keepingMachineState, machine.state != .idle {
            _ = machine.cancel()
        }
    }

    private func squaredDistance(
        from lhs: CanvasPoint,
        to rhs: CanvasPoint
    ) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}
