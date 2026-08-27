import Foundation

struct CanvasInputStateMachine {
    static let maximumBufferedPointCount = 12_000

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

    var bufferedPointCount: Int { bufferedPoints.count }

    @discardableResult
    mutating func beginInk(
        tool: CanvasTool,
        at point: CanvasPoint
    ) -> Bool {
        guard state == .idle, point.isFinite else { return false }

        bufferedPoints.removeAll(keepingCapacity: true)
        bufferedPoints.append(point)
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

        if bufferedPoints.count >= Self.maximumBufferedPointCount {
            compactBufferedPoints()
        }
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

    /// Bounds memory for exceptionally long gestures while retaining the
    /// original start, the latest endpoint, and deterministic intermediate
    /// samples. Repeated compaction lowers historical resolution rather than
    /// rejecting the operation or growing without bound.
    private mutating func compactBufferedPoints() {
        guard bufferedPoints.count > 2 else { return }

        var compacted: [CanvasPoint] = []
        compacted.reserveCapacity(bufferedPoints.count / 2 + 2)
        compacted.append(bufferedPoints[0])
        for index in stride(
            from: 2,
            to: bufferedPoints.count - 1,
            by: 2
        ) {
            compacted.append(bufferedPoints[index])
        }
        if compacted.last != bufferedPoints.last {
            compacted.append(bufferedPoints[bufferedPoints.count - 1])
        }
        bufferedPoints = compacted
    }
}
