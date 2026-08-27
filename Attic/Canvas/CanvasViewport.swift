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
        guard viewPoint.x.isFinite,
              viewPoint.y.isFinite,
              viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0,
              center.isFinite,
              scale.isFinite,
              scale > 0 else {
            return CanvasPoint(x: .nan, y: .nan)
        }
        return CanvasPoint(
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
        guard first.isFinite, second.isFinite else { return .null }
        let result = CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
        guard result.origin.x.isFinite,
              result.origin.y.isFinite,
              result.width.isFinite,
              result.height.isFinite else {
            return .null
        }
        return result
    }

    mutating func pan(byViewTranslation translation: CGSize) {
        guard translation.width.isFinite,
              translation.height.isFinite else {
            return
        }

        let deltaX = Double(translation.width) / scale
        let deltaY = Double(translation.height) / scale
        let nextX = center.x - deltaX
        let nextY = center.y - deltaY
        guard deltaX.isFinite,
              deltaY.isFinite,
              nextX.isFinite,
              nextY.isFinite else {
            return
        }
        center.x = nextX
        center.y = nextY
    }

    mutating func zoom(
        by factor: Double,
        anchoredAt anchor: CGPoint,
        in viewportSize: CGSize
    ) {
        guard factor.isFinite, factor > 0 else { return }

        let anchoredWorldPoint = worldPoint(for: anchor, in: viewportSize)
        // Check the ratio before multiplying so a large but finite gesture
        // cannot overflow to infinity and accidentally fall back to scale 1.
        let newScale = factor > Self.maximumScale / scale
            ? Self.maximumScale
            : Self.clampedScale(scale * factor)
        guard newScale != scale else { return }

        let previousScale = scale
        scale = newScale
        let shiftedWorldPoint = worldPoint(for: anchor, in: viewportSize)
        let shiftX = anchoredWorldPoint.x - shiftedWorldPoint.x
        let shiftY = anchoredWorldPoint.y - shiftedWorldPoint.y
        let nextX = center.x + shiftX
        let nextY = center.y + shiftY
        guard shiftX.isFinite,
              shiftY.isFinite,
              nextX.isFinite,
              nextY.isFinite else {
            scale = previousScale
            return
        }
        center.x = nextX
        center.y = nextY
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
              bounds.width >= 0,
              bounds.height >= 0,
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

        let fittedCenter = CanvasPoint(
            x: Double(bounds.midX),
            y: Double(bounds.midY)
        )
        guard fittedCenter.isFinite else {
            reset()
            return
        }
        center = fittedCenter
        scale = Self.clampedScale(min(
            availableWidth / contentWidth,
            availableHeight / contentHeight
        ))
    }

    private static func clampedScale(_ scale: Double) -> Double {
        if scale.isNaN { return 1 }
        if scale == .infinity { return maximumScale }
        if scale == -.infinity { return minimumScale }
        return min(max(scale, minimumScale), maximumScale)
    }
}
