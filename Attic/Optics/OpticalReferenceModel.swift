import CoreGraphics
import Foundation

struct OpticalVector: Equatable, Sendable {
    static let zero = OpticalVector(x: 0, y: 0)

    let x: Double
    let y: Double
}

struct OpticalDisplacementSample: Equatable, Sendable {
    let edgeInfluence: Double
    let displacement: OpticalVector
    let sourcePoint: CGPoint

    static func identity(at point: CGPoint) -> OpticalDisplacementSample {
        OpticalDisplacementSample(
            edgeInfluence: 0,
            displacement: .zero,
            sourcePoint: point
        )
    }
}

/// Deterministic CPU reference for the Metal displacement field. It mirrors the
/// same corner-local exponent-5 boundary, physical-pixel band, bottom/corner
/// weighting, and hard displacement cap. Synthetic tests can therefore catch
/// seams and optical-math regressions without pretending to validate live
/// WindowServer composition or Screen Recording behavior.
struct PanelOpticalBoundary {
    private struct BoundarySample {
        let signedDistance: Double
        let outwardX: Double
        let outwardY: Double
    }

    let size: CGSize
    let cornerRadius: CGFloat
    let exponent: CGFloat

    init(
        size: CGSize,
        cornerRadius: CGFloat,
        exponent: CGFloat,
        segmentsPerCorner _: Int = 64
    ) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.exponent = exponent
    }

    func sample(
        at point: CGPoint,
        profile: OpticalGlassProfile,
        backingScale: Double,
        interactionProgress: Double = 0
    ) -> OpticalDisplacementSample {
        guard profile.baseDisplacementPixels > 0,
              profile.refractionBandPixels > 0,
              backingScale.isFinite,
              backingScale > 0,
              point.x >= 0,
              point.y >= 0,
              point.x <= size.width,
              point.y <= size.height,
              let boundary = boundary(at: point),
              boundary.signedDistance <= 0 else {
            return .identity(at: point)
        }

        let distanceInsidePixels = max(0, -boundary.signedDistance) * backingScale
        guard distanceInsidePixels < profile.refractionBandPixels else {
            return .identity(at: point)
        }

        let inwardX = -boundary.outwardX
        let inwardY = -boundary.outwardY
        let edgeInfluence = OpticalRefractionEnvelope.smoothstep(
            1 - distanceInsidePixels / profile.refractionBandPixels
        )
        let bottomProximity = size.height > 0
            ? 1 - Double(point.y / size.height)
            : 0
        let edgeMultiplier = OpticalRefractionEnvelope.edgeMultiplier(
            bottomProximity: bottomProximity,
            inwardX: inwardX,
            inwardY: inwardY
        )
        let displacementPixels = profile.displacementPixels(
            interactionProgress: interactionProgress
        )
        let magnitudePoints = displacementPixels
            * edgeMultiplier
            * edgeInfluence
            / backingScale
        let displacement = OpticalVector(
            x: inwardX * magnitudePoints,
            y: inwardY * magnitudePoints
        )

        return OpticalDisplacementSample(
            edgeInfluence: edgeInfluence,
            displacement: displacement,
            sourcePoint: CGPoint(
                x: point.x + displacement.x,
                y: point.y + displacement.y
            )
        )
    }

    private func boundary(at point: CGPoint) -> BoundarySample? {
        guard size.width > 0, size.height > 0 else { return nil }

        let width = Double(size.width)
        let height = Double(size.height)
        let halfWidth = max(width * 0.5, 0.0001)
        let halfHeight = max(height * 0.5, 0.0001)
        let radius = min(
            max(Double(cornerRadius), 0),
            min(halfWidth, halfHeight)
        )
        let n = max(Double(exponent), 1)
        let centeredX = Double(point.x) - halfWidth
        let centeredY = Double(point.y) - halfHeight
        let signX = centeredX >= 0 ? 1.0 : -1.0
        let signY = centeredY >= 0 ? 1.0 : -1.0
        let qX = abs(centeredX) - (halfWidth - radius)
        let qY = abs(centeredY) - (halfHeight - radius)
        let positiveX = max(qX, 0)
        let positiveY = max(qY, 0)
        let sum = pow(positiveX, n) + pow(positiveY, n)
        let roundedDistance = pow(max(sum, 0), 1 / n)
        let interiorDistance = min(max(qX, qY), 0)
        let signedDistance = roundedDistance + interiorDistance - radius

        var outwardX: Double
        var outwardY: Double
        if positiveX > 0 || positiveY > 0 {
            let denominator = pow(
                max(sum, 0.000_001),
                (n - 1) / n
            )
            outwardX = pow(positiveX, n - 1) / denominator * signX
            outwardY = pow(positiveY, n - 1) / denominator * signY
        } else if qX > qY {
            outwardX = signX
            outwardY = 0
        } else if qY > qX {
            outwardX = 0
            outwardY = signY
        } else {
            let inverseRootTwo = 1 / sqrt(2.0)
            outwardX = signX * inverseRootTwo
            outwardY = signY * inverseRootTwo
        }

        let length = hypot(outwardX, outwardY)
        guard length > 0.000_001 else { return nil }
        outwardX /= length
        outwardY /= length

        return BoundarySample(
            signedDistance: signedDistance,
            outwardX: outwardX,
            outwardY: outwardY
        )
    }
}
