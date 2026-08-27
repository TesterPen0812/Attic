import SwiftUI

/// Shared geometry for the visible panel mask and the optical displacement
/// field. Keeping one boundary definition prevents the refracted layer from
/// exposing a rectangular remnant outside the accepted squircle.
enum SquircleGeometry {
    static func boundaryPoints(
        in rect: CGRect,
        cornerRadius: CGFloat,
        exponent: CGFloat,
        segmentsPerCorner: Int = 32
    ) -> [CGPoint] {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        guard radius > 0, rect.width > 0, rect.height > 0 else { return [] }

        let n = max(1, exponent)
        let segmentCount = max(1, segmentsPerCorner)
        let corners: [(x: CGFloat, y: CGFloat, start: CGFloat)] = [
            (rect.minX + radius, rect.minY + radius, .pi),
            (rect.maxX - radius, rect.minY + radius, 3 * .pi / 2),
            (rect.maxX - radius, rect.maxY - radius, 0),
            (rect.minX + radius, rect.maxY - radius, .pi / 2)
        ]

        return corners.flatMap { corner in
            (0...segmentCount).map { index in
                let t = corner.start
                    + (CGFloat(index) / CGFloat(segmentCount)) * (.pi / 2)
                let cosine = cos(t)
                let sine = sin(t)
                let dx = radius * copysign(pow(abs(cosine), 2 / n), cosine)
                let dy = radius * copysign(pow(abs(sine), 2 / n), sine)
                return CGPoint(x: corner.x + dx, y: corner.y + dy)
            }
        }
    }

    static func path(
        in rect: CGRect,
        cornerRadius: CGFloat,
        exponent: CGFloat,
        segmentsPerCorner: Int = 32
    ) -> CGPath {
        let path = CGMutablePath()
        let points = boundaryPoints(
            in: rect,
            cornerRadius: cornerRadius,
            exponent: exponent,
            segmentsPerCorner: segmentsPerCorner
        )

        guard let first = points.first else {
            path.addRect(rect)
            return path
        }

        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

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
        Path(
            SquircleGeometry.path(
                in: rect,
                cornerRadius: cornerRadius,
                exponent: exponent
            )
        )
    }
}

extension Squircle {
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
