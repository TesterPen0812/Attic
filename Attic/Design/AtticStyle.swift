import SwiftUI

enum AtticStyle {
    static let panelCornerRadius: CGFloat = 18
    /// Superellipse exponent for the panel corners. `5` produces a
    /// recognisably squircular silhouette without aggressive inward
    /// curvature.
    static let panelSquircleExponent: CGFloat = 5

    /// The AppKit window remains rectangular while the visible panel is a squircle.
    /// Disabling its system shadow prevents square bounds from showing beyond large corners.
    static let panelUsesSystemShadow = false
    static let horizontalPadding: CGFloat = 16
    static let rowHeight: CGFloat = 32
    static let taskSpacing: CGFloat = 4
}

struct OpticalGlassControls: Equatable {
    static let range = 0.0...100.0
    static let defaults = OpticalGlassControls(
        transparency: 88,
        frost: 14,
        refraction: 100,
        edgeShine: 18,
        tint: 10,
        readability: 22,
        interactionResponse: 28
    )

    var transparency: Double
    var frost: Double
    var refraction: Double
    var edgeShine: Double
    var tint: Double
    var readability: Double
    var interactionResponse: Double

    static func normalized(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback / 100 }
        return min(max(value, range.lowerBound), range.upperBound) / 100
    }
}

enum OpticalWindowActivity: Equatable {
    case key
    case inactive
}

/// A resolved rendering profile. Each user-facing axis maps to its own output
/// field so transparency, frost, and refraction cannot silently drive one
/// another. Window activity is intentionally ignored by `resolve`.
struct OpticalGlassProfile: Equatable {
    let surfaceOpacity: Double
    let frostRadius: Double
    let refractionBandPixels: Double
    let baseDisplacementPixels: Double
    let edgeShineOpacity: Double
    let tintOpacity: Double
    let readabilityOpacity: Double
    let interactionBoost: Double

    static func resolve(
        controls: OpticalGlassControls,
        windowActivity _: OpticalWindowActivity
    ) -> OpticalGlassProfile {
        let defaults = OpticalGlassControls.defaults
        let transparency = OpticalGlassControls.normalized(
            controls.transparency,
            fallback: defaults.transparency
        )
        let frost = OpticalGlassControls.normalized(
            controls.frost,
            fallback: defaults.frost
        )
        let refraction = OpticalGlassControls.normalized(
            controls.refraction,
            fallback: defaults.refraction
        )
        let edgeShine = OpticalGlassControls.normalized(
            controls.edgeShine,
            fallback: defaults.edgeShine
        )
        let tint = OpticalGlassControls.normalized(
            controls.tint,
            fallback: defaults.tint
        )
        let readability = OpticalGlassControls.normalized(
            controls.readability,
            fallback: defaults.readability
        )
        let interaction = OpticalGlassControls.normalized(
            controls.interactionResponse,
            fallback: defaults.interactionResponse
        )

        return OpticalGlassProfile(
            surfaceOpacity: pow(1 - transparency, 1.35),
            frostRadius: frost * 8,
            refractionBandPixels: refraction == 0 ? 0 : 28 + 8 * sqrt(refraction),
            baseDisplacementPixels: refraction == 0 ? 0 : 19 * pow(refraction, 1.15),
            edgeShineOpacity: edgeShine * 0.30,
            tintOpacity: tint * 0.16,
            readabilityOpacity: readability * 0.22,
            interactionBoost: 1 + interaction * 0.06
        )
    }

    func displacementPixels(interactionProgress: Double) -> Double {
        let progress = min(max(interactionProgress, 0), 1)
        return min(
            24 / PanelOpticalBoundary.maximumEdgeMultiplier,
            baseDisplacementPixels * (1 + (interactionBoost - 1) * progress)
        )
    }
}

enum OpticalBackdropBackend: Equatable {
    case liveFiltered
    case liveMaterial
    case opaque

    static func resolve(
        backgroundFiltersAvailable: Bool,
        reduceTransparency: Bool
    ) -> OpticalBackdropBackend {
        if reduceTransparency { return .opaque }
        return backgroundFiltersAvailable ? .liveFiltered : .liveMaterial
    }
}

/// Small state machine used by the backdrop owner to invalidate stale work and
/// make teardown observable in tests without retaining AppKit objects.
struct OpticalBackdropLifecycle: Equatable {
    enum Phase: Equatable {
        case stopped
        case installed
        case visible
    }

    private(set) var phase: Phase = .stopped
    private(set) var generation = 0

    @discardableResult
    mutating func install() -> Int {
        generation += 1
        phase = .installed
        return generation
    }

    mutating func show() {
        guard phase != .stopped else { return }
        phase = .visible
    }

    mutating func hide() {
        guard phase == .visible else { return }
        phase = .installed
    }

    mutating func stop() {
        generation += 1
        phase = .stopped
    }

    func accepts(_ candidateGeneration: Int) -> Bool {
        candidateGeneration == generation && phase != .stopped
    }
}

struct OpticalVector: Equatable {
    static let zero = OpticalVector(x: 0, y: 0)

    let x: Double
    let y: Double
}

struct OpticalDisplacementSample: Equatable {
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

/// Piecewise-linear approximation of the exact panel squircle. Refraction is
/// derived from the nearest point on this one continuous perimeter, avoiding
/// separate edge/corner formulas and the center seams they tend to create.
struct PanelOpticalBoundary {
    static let maximumEdgeMultiplier = 1.22

    private struct Segment {
        let start: CGPoint
        let end: CGPoint
        let inwardNormal: CGPoint
    }

    private struct NearestBoundaryPoint {
        let point: CGPoint
        let inwardNormal: CGPoint
        let distanceSquared: CGFloat
    }

    let size: CGSize
    private let segments: [Segment]

    init(
        size: CGSize,
        cornerRadius: CGFloat,
        exponent: CGFloat,
        segmentsPerCorner: Int = 64
    ) {
        self.size = size
        let points = SquircleGeometry.boundaryPoints(
            in: CGRect(origin: .zero, size: size),
            cornerRadius: cornerRadius,
            exponent: exponent,
            segmentsPerCorner: segmentsPerCorner
        )
        segments = points.indices.compactMap { index in
            let start = points[index]
            let end = points[(index + 1) % points.count]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > 0.000_001 else { return nil }
            return Segment(
                start: start,
                end: end,
                inwardNormal: CGPoint(x: -dy / length, y: dx / length)
            )
        }
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
              let nearest = nearestBoundaryPoint(to: point) else {
            return .identity(at: point)
        }

        let distance = sqrt(nearest.distanceSquared)
        let bandPoints = CGFloat(profile.refractionBandPixels / backingScale)
        guard distance < bandPoints else { return .identity(at: point) }

        let inward: CGPoint
        if distance > 0.000_001 {
            inward = CGPoint(
                x: (point.x - nearest.point.x) / distance,
                y: (point.y - nearest.point.y) / distance
            )
        } else {
            inward = nearest.inwardNormal
        }

        let linearInfluence = 1 - distance / bandPoints
        let influence = Self.smoothstep(linearInfluence)
        let bottomProximity = size.height > 0 ? 1 - nearest.point.y / size.height : 0
        let bottomWeight = Self.smoothstep((bottomProximity - 0.58) / 0.42)
        let cornerWeight = min(1, 2 * abs(inward.x * inward.y))
        let edgeMultiplier = min(
            Self.maximumEdgeMultiplier,
            0.84 + 0.16 * bottomWeight + 0.22 * cornerWeight
        )
        let displacementPoints = CGFloat(
            profile.displacementPixels(interactionProgress: interactionProgress) / backingScale
        )
        let magnitude = displacementPoints * edgeMultiplier * influence
        let displacement = OpticalVector(
            x: Double(inward.x * magnitude),
            y: Double(inward.y * magnitude)
        )

        return OpticalDisplacementSample(
            edgeInfluence: Double(influence),
            displacement: displacement,
            sourcePoint: CGPoint(
                x: point.x + CGFloat(displacement.x),
                y: point.y + CGFloat(displacement.y)
            )
        )
    }

    private func nearestBoundaryPoint(to point: CGPoint) -> NearestBoundaryPoint? {
        var result: NearestBoundaryPoint?

        for segment in segments {
            let dx = segment.end.x - segment.start.x
            let dy = segment.end.y - segment.start.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { continue }

            let projection = (
                (point.x - segment.start.x) * dx
                    + (point.y - segment.start.y) * dy
            ) / lengthSquared
            let t = min(max(projection, 0), 1)
            let candidate = CGPoint(
                x: segment.start.x + t * dx,
                y: segment.start.y + t * dy
            )
            let candidateDX = point.x - candidate.x
            let candidateDY = point.y - candidate.y
            let distanceSquared = candidateDX * candidateDX + candidateDY * candidateDY

            if let current = result, distanceSquared >= current.distanceSquared {
                continue
            }
            result = NearestBoundaryPoint(
                point: candidate,
                inwardNormal: segment.inwardNormal,
                distanceSquared: distanceSquared
            )
        }

        return result
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

/// The SwiftUI subtree owns only the accepted squircle clip. The live optical
/// background is installed below `NSHostingView`, so foreground Attic content
/// never enters the displacement filter and the old material/outline cannot
/// obscure the custom backdrop.
struct AtticPanelSurface: ViewModifier {
    let translucent: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .clipShape(
                Squircle(
                    cornerRadius: cornerRadius,
                    exponent: AtticStyle.panelSquircleExponent
                )
            )
    }
}

extension View {
    func atticPanelSurface(
        translucent: Bool,
        cornerRadius: CGFloat = AtticStyle.panelCornerRadius
    ) -> some View {
        modifier(
            AtticPanelSurface(
                translucent: translucent,
                cornerRadius: cornerRadius
            )
        )
    }
}
