import Foundation

struct CanvasViewport: Equatable {
    static let minimumScale = 0.25
    static let maximumScale = 8.0

    var center: CanvasPoint
    private(set) var scale: Double

    init(
        center: CanvasPoint = .zero,
        scale: Double = 1
    ) {
        self.center = center.isFinite ? center : .zero
        self.scale = Self.clampedScale(scale)
    }

    func viewPoint(
        for worldPoint: CanvasPoint,
        in viewportSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: viewportSize.width / 2
                + CGFloat((worldPoint.x - center.x) * scale),
            y: viewportSize.height / 2
                + CGFloat((worldPoint.y - center.y) * scale)
        )
    }

    func worldPoint(
        for viewPoint: CGPoint,
        in viewportSize: CGSize
    ) -> CanvasPoint {
        CanvasPoint(
            x: center.x
                + Double(viewPoint.x - viewportSize.width / 2) / scale,
            y: center.y
                + Double(viewPoint.y - viewportSize.height / 2) / scale
        )
    }

    func worldRect(
        for viewRect: CGRect,
        in viewportSize: CGSize
    ) -> CGRect {
        guard !viewRect.isNull,
              !viewRect.isInfinite,
              viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return .null
        }

        let first = worldPoint(
            for: CGPoint(x: viewRect.minX, y: viewRect.minY),
            in: viewportSize
        )
        let second = worldPoint(
            for: CGPoint(x: viewRect.maxX, y: viewRect.maxY),
            in: viewportSize
        )
        return CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    mutating func pan(byViewTranslation translation: CGSize) {
        guard translation.width.isFinite,
              translation.height.isFinite else {
            return
        }

        center.x -= Double(translation.width) / scale
        center.y -= Double(translation.height) / scale
    }

    mutating func zoom(
        by factor: Double,
        anchoredAt anchor: CGPoint,
        in viewportSize: CGSize
    ) {
        guard factor.isFinite, factor > 0 else { return }

        let anchoredWorldPoint = worldPoint(for: anchor, in: viewportSize)
        let newScale = Self.clampedScale(scale * factor)
        guard newScale != scale else { return }

        scale = newScale
        let shiftedWorldPoint = worldPoint(for: anchor, in: viewportSize)
        center.x += anchoredWorldPoint.x - shiftedWorldPoint.x
        center.y += anchoredWorldPoint.y - shiftedWorldPoint.y
    }

    mutating func reset() {
        center = .zero
        scale = 1
    }

    mutating func fit(
        bounds: CGRect?,
        in viewportSize: CGSize,
        padding: Double = 24
    ) {
        guard let bounds,
              !bounds.isNull,
              !bounds.isInfinite,
              bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            reset()
            return
        }

        let safePadding = max(padding.isFinite ? padding : 0, 0)
        let availableWidth = max(Double(viewportSize.width) - safePadding * 2, 1)
        let availableHeight = max(Double(viewportSize.height) - safePadding * 2, 1)
        let contentWidth = max(Double(bounds.width), 1)
        let contentHeight = max(Double(bounds.height), 1)

        center = CanvasPoint(
            x: Double(bounds.midX),
            y: Double(bounds.midY)
        )
        scale = Self.clampedScale(min(
            availableWidth / contentWidth,
            availableHeight / contentHeight
        ))
    }

    private static func clampedScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1 }
        return min(max(scale, minimumScale), maximumScale)
    }
}
