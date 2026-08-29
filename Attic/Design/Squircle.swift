import SwiftUI

/// A squircular rounded rectangle: straight side sections with continuous
/// superellipse corners.
///
/// Unlike a full-bounds superellipse—whose curvature scales with the entire
/// panel and clips content along the edges—this shape confines the smooth
/// curvature to an explicit `cornerRadius × cornerRadius` region at each
/// corner. The sides between corners are perfectly straight, so content
/// laid out with reasonable horizontal padding is never clipped regardless
/// of panel dimensions.
///
/// The `exponent` controls the smoothness of each corner transition.
/// Higher values approach a sharp rectangle; lower values produce a softer,
/// more elliptical corner. The default of 5 gives a recognisably squircular
/// silhouette without aggressive inward curvature.
struct Squircle: Shape {
    /// Extent of each corner curve in points. The curve spans this distance
    /// from the corner along both the horizontal and vertical edges.
    var cornerRadius: CGFloat

    /// Superellipse exponent for the corner curve.
    var exponent: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        guard r > 0, rect.width > 0, rect.height > 0 else {
            return Path(roundedRect: rect, cornerRadius: 0)
        }

        let n = max(1.0, exponent)
        let segments = 32
        var path = Path()

        // Each corner is a quarter superellipse. Walking clockwise on screen
        // (y increases downward), the corners and their parametric start
        // angles are:
        //   top-left:     center (minX + r, minY + r), start π
        //   top-right:    center (maxX - r, minY + r), start 3π/2
        //   bottom-right: center (maxX - r, maxY - r), start 0
        //   bottom-left:  center (minX + r, maxY - r), start π/2
        let corners: [(cx: CGFloat, cy: CGFloat, start: CGFloat)] = [
            (rect.minX + r, rect.minY + r, .pi),
            (rect.maxX - r, rect.minY + r, 3 * .pi / 2),
            (rect.maxX - r, rect.maxY - r, 0),
            (rect.minX + r, rect.maxY - r, .pi / 2)
        ]

        for (cornerIndex, corner) in corners.enumerated() {
            for i in 0...segments {
                let t = corner.start + (CGFloat(i) / CGFloat(segments)) * (.pi / 2)
                let dx = r * copysign(pow(abs(cos(t)), 2 / n), cos(t))
                let dy = r * copysign(pow(abs(sin(t)), 2 / n), sin(t))
                let point = CGPoint(x: corner.cx + dx, y: corner.cy + dy)
                if cornerIndex == 0 && i == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }

        path.closeSubpath()
        return path
    }
}

extension Squircle {
    /// Analytic containment used by AppKit hit testing. `Path.contains` can
    /// include exact boundary pixels outside a closed superellipse, which is
    /// undesirable for a transparent, click-through window.
    static func contains(
        _ point: CGPoint,
        in rect: CGRect,
        cornerRadius: CGFloat,
        exponent: CGFloat = 5
    ) -> Bool {
        guard rect.contains(point) else { return false }

        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        guard radius > 0 else { return true }

        let innerHorizontal = rect.insetBy(dx: radius, dy: 0)
        let innerVertical = rect.insetBy(dx: 0, dy: radius)
        if innerHorizontal.contains(point) || innerVertical.contains(point) {
            return true
        }

        let centerX = point.x < rect.midX ? rect.minX + radius : rect.maxX - radius
        let centerY = point.y < rect.midY ? rect.minY + radius : rect.maxY - radius
        let normalizedX = abs(point.x - centerX) / radius
        let normalizedY = abs(point.y - centerY) / radius
        let power = max(1, exponent)
        return pow(normalizedX, power) + pow(normalizedY, power) <= 1
    }

    /// The maximum inward deviation of the corner curve from the rectangular
    /// bounding box, occurring at the 45° point of the superellipse.
    ///
    /// For exponent 5 this factor is approximately 0.129, meaning a 32-point
    /// corner curves inward by roughly 4.1 points at its deepest. Content
    /// padded beyond this distance from the edge is always inside the shape.
    static func cornerInsetFactor(exponent: CGFloat) -> CGFloat {
        1 - pow(0.5, 1 / max(1, exponent))
    }
}
