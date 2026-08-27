import Foundation

struct CanvasInputStateMachine {
    enum State: Equatable {
        case idle
        case drawing
        case erasing
        case panning
    }

    enum Completion: Equatable {
        case stroke([CanvasPoint])
        case erase([CanvasPoint])
    }

    private(set) var state: State = .idle
    private var bufferedPoints: [CanvasPoint] = []

    @discardableResult
    mutating func beginInk(
        tool: CanvasTool,
        at point: CanvasPoint
    ) -> Bool {
        guard state == .idle, point.isFinite else { return false }

        bufferedPoints = [point]
        switch tool {
        case .pen:
            state = .drawing
        case .eraser:
            state = .erasing
        }
        return true
    }

    mutating func append(_ point: CanvasPoint) {
        guard point.isFinite else { return }
        guard state == .drawing || state == .erasing else { return }
        guard bufferedPoints.last != point else { return }
        bufferedPoints.append(point)
    }

    /// Returns true when taking ownership for pan discarded unfinished ink.
    @discardableResult
    mutating func beginPan() -> Bool {
        switch state {
        case .drawing, .erasing:
            bufferedPoints.removeAll(keepingCapacity: true)
            state = .panning
            return true
        case .idle:
            state = .panning
            return false
        case .panning:
            return false
        }
    }

    mutating func finishInk() -> Completion? {
        let points = bufferedPoints
        switch state {
        case .drawing:
            bufferedPoints.removeAll(keepingCapacity: true)
            state = .idle
            return points.isEmpty ? nil : .stroke(points)
        case .erasing:
            bufferedPoints.removeAll(keepingCapacity: true)
            state = .idle
            return points.isEmpty ? nil : .erase(points)
        case .idle, .panning:
            return nil
        }
    }

    mutating func finishPan() {
        guard state == .panning else { return }
        state = .idle
    }

    @discardableResult
    mutating func cancel() -> Bool {
        guard state != .idle else { return false }
        bufferedPoints.removeAll(keepingCapacity: true)
        state = .idle
        return true
    }
}
