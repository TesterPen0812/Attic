import Foundation

struct CanvasInputStateMachine {
    enum State: Equatable {
        case idle
        case drawing([CanvasPoint])
        case erasing([CanvasPoint])
        case panning
    }

    enum Completion: Equatable {
        case stroke([CanvasPoint])
        case erase([CanvasPoint])
    }

    private(set) var state: State = .idle

    @discardableResult
    mutating func beginInk(
        tool: CanvasTool,
        at point: CanvasPoint
    ) -> Bool {
        guard state == .idle, point.isFinite else { return false }

        switch tool {
        case .pen:
            state = .drawing([point])
        case .eraser:
            state = .erasing([point])
        }
        return true
    }

    mutating func append(_ point: CanvasPoint) {
        guard point.isFinite else { return }

        switch state {
        case var .drawing(points):
            if points.last != point {
                points.append(point)
                state = .drawing(points)
            }
        case var .erasing(points):
            if points.last != point {
                points.append(point)
                state = .erasing(points)
            }
        case .idle, .panning:
            break
        }
    }

    /// Returns true when taking ownership for pan discarded unfinished ink.
    @discardableResult
    mutating func beginPan() -> Bool {
        switch state {
        case .drawing, .erasing:
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
        switch state {
        case let .drawing(points):
            state = .idle
            return points.isEmpty ? nil : .stroke(points)
        case let .erasing(points):
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
        state = .idle
        return true
    }
}
