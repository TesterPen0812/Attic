import Foundation

enum CanvasTool: String, CaseIterable, Codable, Identifiable {
    case pen
    case eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .eraser: "Eraser"
        }
    }

    var symbolName: String {
        switch self {
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        }
    }
}

enum CanvasInkColor: String, CaseIterable, Codable, Identifiable {
    case ink
    case blue
    case red
    case green
    case orange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ink: "Ink"
        case .blue: "Blue"
        case .red: "Red"
        case .green: "Green"
        case .orange: "Orange"
        }
    }
}

struct CanvasPoint: Codable, Hashable {
    var x: Double
    var y: Double

    static let zero = CanvasPoint(x: 0, y: 0)

    var isFinite: Bool {
        x.isFinite && y.isFinite
    }

    var cgPoint: CGPoint {
        CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }
}

struct CanvasBoard: Identifiable, Equatable {
    let id: UUID
    let name: String
    let sortIndex: Int64
    let clearGeneration: Int64
    let mutationVersion: Int64
    let createdAt: Date
    let updatedAt: Date

    static let defaultBoard = CanvasBoard(
        id: CanvasBoardItem.logicalBoardID,
        name: "Canvas",
        sortIndex: 0,
        clearGeneration: 0,
        mutationVersion: 1,
        createdAt: .distantPast,
        updatedAt: .distantPast
    )

    static let recoveryBoard = CanvasBoard(
        id: CanvasBoardItem.recoveryBoardID,
        name: "Canvas",
        sortIndex: 0,
        clearGeneration: 0,
        mutationVersion: 1,
        createdAt: .distantPast,
        updatedAt: .distantPast
    )
}

struct CanvasStrokeGeometry: Equatable {
    let color: CanvasInkColor
    let width: Double
    let points: [CanvasPoint]
}

struct CanvasStroke: Identifiable, Equatable {
    let id: UUID
    let canvasID: UUID
    /// Ephemeral identity for native rendering caches. It is deliberately not
    /// persisted or included in semantic equality.
    let renderToken: UUID
    let color: CanvasInkColor
    let width: Double
    let points: [CanvasPoint]
    let boardGeneration: Int64
    let mutationVersion: Int64
    let createdAt: Date
    let updatedAt: Date
    let bounds: CGRect?

    init(
        id: UUID = UUID(),
        canvasID: UUID = CanvasBoardItem.logicalBoardID,
        renderToken: UUID = UUID(),
        color: CanvasInkColor,
        width: Double,
        points: [CanvasPoint],
        boardGeneration: Int64 = 0,
        mutationVersion: Int64 = 1,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.canvasID = canvasID
        self.renderToken = renderToken
        self.color = color
        self.width = width
        self.points = points
        self.boardGeneration = boardGeneration
        self.mutationVersion = mutationVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        bounds = Self.makeBounds(points: points, width: width)
    }

    static func == (lhs: CanvasStroke, rhs: CanvasStroke) -> Bool {
        lhs.id == rhs.id
            && lhs.canvasID == rhs.canvasID
            && lhs.color == rhs.color
            && lhs.width == rhs.width
            && lhs.points == rhs.points
            && lhs.boardGeneration == rhs.boardGeneration
            && lhs.mutationVersion == rhs.mutationVersion
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }

    var renderKey: CanvasStrokeRenderKey {
        CanvasStrokeRenderKey(id: id, token: renderToken)
    }

    private static func makeBounds(
        points: [CanvasPoint],
        width: Double
    ) -> CGRect? {
        guard let first = points.first else { return nil }

        var minimumX = first.x
        var maximumX = first.x
        var minimumY = first.y
        var maximumY = first.y
        for point in points.dropFirst() {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }

        let halfWidth = max(width, 0) / 2
        return CGRect(
            x: minimumX - halfWidth,
            y: minimumY - halfWidth,
            width: max(maximumX - minimumX, 0) + halfWidth * 2,
            height: max(maximumY - minimumY, 0) + halfWidth * 2
        )
    }
}

struct CanvasStrokeRenderKey: Equatable, Hashable {
    let id: UUID
    let token: UUID
}

enum CanvasHitTesting {
    static func strokeIDs(
        hitBy eraserPoints: [CanvasPoint],
        radius: Double,
        strokes: [CanvasStroke]
    ) -> Set<UUID> {
        guard !eraserPoints.isEmpty, radius.isFinite, radius >= 0 else {
            return []
        }

        let eraserBounds = pointBounds(eraserPoints).insetBy(
            dx: -CGFloat(radius),
            dy: -CGFloat(radius)
        )
        var result: Set<UUID> = []
        result.reserveCapacity(min(strokes.count, 16))
        for stroke in strokes {
            guard stroke.bounds?.intersects(eraserBounds) == true else {
                continue
            }
            if intersects(
                eraserPoints: eraserPoints,
                stroke: stroke,
                radius: radius
            ) {
                result.insert(stroke.id)
            }
        }
        return result
    }

    private static func pointBounds(_ points: [CanvasPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minimumX = first.x
        var maximumX = first.x
        var minimumY = first.y
        var maximumY = first.y
        for point in points.dropFirst() {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private static func intersects(
        eraserPoints: [CanvasPoint],
        stroke: CanvasStroke,
        radius: Double
    ) -> Bool {
        guard !stroke.points.isEmpty else { return false }
        let threshold = radius + max(stroke.width, 0) / 2
        let thresholdSquared = threshold * threshold
        let eraserSegmentCount = max(eraserPoints.count - 1, 1)
        let strokeSegmentCount = max(stroke.points.count - 1, 1)

        for eraserIndex in 0..<eraserSegmentCount {
            let eraserStart = eraserPoints[eraserIndex]
            let eraserEnd = eraserPoints[min(eraserIndex + 1, eraserPoints.count - 1)]
            for strokeIndex in 0..<strokeSegmentCount {
                let strokeStart = stroke.points[strokeIndex]
                let strokeEnd = stroke.points[min(strokeIndex + 1, stroke.points.count - 1)]
                if segmentDistanceSquared(
                    eraserStart,
                    eraserEnd,
                    strokeStart,
                    strokeEnd
                ) <= thresholdSquared {
                    return true
                }
            }
        }
        return false
    }

    private static func segmentDistanceSquared(
        _ a0: CanvasPoint,
        _ a1: CanvasPoint,
        _ b0: CanvasPoint,
        _ b1: CanvasPoint
    ) -> Double {
        if segmentsIntersect(a0, a1, b0, b1) {
            return 0
        }

        return min(
            pointToSegmentDistanceSquared(a0, b0, b1),
            pointToSegmentDistanceSquared(a1, b0, b1),
            pointToSegmentDistanceSquared(b0, a0, a1),
            pointToSegmentDistanceSquared(b1, a0, a1)
        )
    }

    private static func pointToSegmentDistanceSquared(
        _ point: CanvasPoint,
        _ start: CanvasPoint,
        _ end: CanvasPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return squaredDistance(point, start)
        }

        let projection = (
            (point.x - start.x) * dx + (point.y - start.y) * dy
        ) / lengthSquared
        let t = min(max(projection, 0), 1)
        let nearest = CanvasPoint(
            x: start.x + t * dx,
            y: start.y + t * dy
        )
        return squaredDistance(point, nearest)
    }

    private static func squaredDistance(
        _ lhs: CanvasPoint,
        _ rhs: CanvasPoint
    ) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func segmentsIntersect(
        _ a0: CanvasPoint,
        _ a1: CanvasPoint,
        _ b0: CanvasPoint,
        _ b1: CanvasPoint
    ) -> Bool {
        let epsilon = 0.000_000_001
        let o1 = orientation(a0, a1, b0)
        let o2 = orientation(a0, a1, b1)
        let o3 = orientation(b0, b1, a0)
        let o4 = orientation(b0, b1, a1)

        if o1 * o2 < -epsilon, o3 * o4 < -epsilon {
            return true
        }

        return (abs(o1) <= epsilon && contains(b0, on: a0, a1))
            || (abs(o2) <= epsilon && contains(b1, on: a0, a1))
            || (abs(o3) <= epsilon && contains(a0, on: b0, b1))
            || (abs(o4) <= epsilon && contains(a1, on: b0, b1))
    }

    private static func orientation(
        _ a: CanvasPoint,
        _ b: CanvasPoint,
        _ c: CanvasPoint
    ) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func contains(
        _ point: CanvasPoint,
        on start: CanvasPoint,
        _ end: CanvasPoint
    ) -> Bool {
        point.x >= min(start.x, end.x) - 0.000_000_001
            && point.x <= max(start.x, end.x) + 0.000_000_001
            && point.y >= min(start.y, end.y) - 0.000_000_001
            && point.y <= max(start.y, end.y) + 0.000_000_001
    }
}
