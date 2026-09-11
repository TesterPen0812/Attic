import CoreGraphics
import Foundation

/// Pure deformation geometry for the corner-pulled ("genie") main-panel
/// transition. Everything here is a deterministic function of progress and the
/// configured dock corner: the same map runs hide and reveal, sampled at
/// whatever cadence the renderer provides. No AppKit, no timers, no global
/// state — this file is deliberately portable so the math is unit-testable in
/// isolation from the SpriteKit presentation that consumes it.
///
/// Model: every source point P travels toward the corner anchor A by a
/// consumption fraction c(P) = clamp01(p * (1 + lead * closeness(P))). The
/// destination A + (P - A) * (1 - c) keeps P on its own ray from A, so distinct
/// rays never cross and the sheet cannot fold or self-intersect. Points whose
/// consumption saturates land exactly on A — that saturated cap is the
/// "pulled into the point" tip. closeness() is a corner-weighted power field,
/// so the anchor-facing region is consumed first while the far edge trails
/// behind on a smooth narrowing funnel.
enum PanelGenieGeometry {
    /// Direction the transition is travelling. `conceal` pulls the sheet into
    /// the anchor point; `reveal` unfurls it back out of the same point.
    enum MotionDirection {
        case conceal
        case reveal
    }

    /// Named, bounded tunables. The ranges are clamped on use so a bad edit
    /// degrades gracefully instead of corrupting geometry.
    struct Spec: Equatable {
        /// Full 0→1 traversal budgets (seconds). Partial runs scale down by
        /// `distanceExponent` so reversals stay responsive.
        var hideDuration: TimeInterval = 0.34
        var showDuration: TimeInterval = 0.38
        /// How strongly the anchor-adjacent region leads the rest of the
        /// sheet into the point. 0 would be uniform contraction.
        var cornerLead: CGFloat = 1.15
        /// Weight of the horizontal vs vertical "nearness to the anchor
        /// corner" axes in the closeness field.
        var horizontalWeight: CGFloat = 0.5
        var verticalWeight: CGFloat = 0.5
        /// Exponent applied to each lead axis. >1 keeps the far portion wide
        /// early and makes the consumption frontier curve into the corner.
        var leadExponent: CGFloat = 1.5
        /// Exponent applied to the whole consumption value. >1 lets the far
        /// edge linger early then get drawn in late — the funnel mouth stays
        /// open and closes into the tip. The saturated frontier (where the
        /// sheet has fully entered the point) is unchanged by this shaping.
        var consumptionExponent: CGFloat = 1.25
        /// The endpoint sits this many points inside the usable work-area
        /// corner so the tip never reaches under the menu bar or Dock edge.
        var anchorInset: CGFloat = 2
        /// Mesh resolution: target points per cell, clamped to the segment
        /// bounds so extreme panel sizes stay smooth but bounded.
        var meshCellSize: CGFloat = 12
        var meshMinimumSegments: Int = 16
        var meshMaximumSegments: Int = 56
        /// Runs shorter than this snap — avoids a visible stall when the
        /// remaining distance is already tiny.
        var minimumRunDuration: TimeInterval = 0.09
        /// Partial-run duration scaling: distance^exponent * base duration.
        var distanceExponent: CGFloat = 0.55
        /// Below this remaining distance a run completes exactly.
        var completionEpsilon: CGFloat = 0.0008
        /// The grid never fully degenerates on screen; at progress 1 the
        /// window is ordered out instead of rendering a zero-area mesh.
        var displayProgressCeiling: CGFloat = 0.9995
        /// Reduced-motion / capture-failure fade budget.
        var fadeDuration: TimeInterval = 0.16
        /// Interactive swipe travel that maps to a full pull, matching the
        /// previous collapse presentation's feel.
        var swipeTravelMinimum: CGFloat = 120
        var swipeTravelMaximum: CGFloat = 280
        var swipeTravelWidthFactor: CGFloat = 0.65
        var swipeProgressCeiling: CGFloat = 0.95
        /// Reduced-motion swipe feedback is a restrained dim, not a funnel.
        var reducedMotionSwipeFloor: CGFloat = 0.4

        static let standard = Spec()
    }

    /// Cubic-bezier timing on the unit square with fixed endpoints (0,0) and
    /// (1,1). `solve` returns y(x); this is the same curve shape AppKit/CA
    /// timing functions express, evaluated without Core Animation.
    struct CubicBezierTiming: Equatable {
        let x1: CGFloat
        let y1: CGFloat
        let x2: CGFloat
        let y2: CGFloat

        /// Hide accelerates into the point (slow start, decisive finish).
        static let conceal = CubicBezierTiming(x1: 0.45, y1: 0, x2: 0.72, y2: 0.42)
        /// Reveal answers immediately then settles softly out of the point —
        /// a strong initial slope also catches a mid-flight reversal without
        /// a dead stop.
        static let reveal = CubicBezierTiming(x1: 0.24, y1: 0.82, x2: 0.42, y2: 1)

        func solve(_ input: CGFloat) -> CGFloat {
            guard input.isFinite else { return 0 }
            let x = min(1, max(0, input))
            if x == 0 || x == 1 { return x }
            // Newton–Raphson on t for x(t) = x, then bisection fallback.
            var t = x
            for _ in 0..<6 {
                let currentX = sample(t, x1, x2) - x
                if abs(currentX) < 1e-5 { return sample(t, y1, y2) }
                let slope = derivative(t, x1, x2)
                if abs(slope) < 1e-5 { break }
                t = min(1, max(0, t - currentX / slope))
            }
            var lower: CGFloat = 0
            var upper: CGFloat = 1
            t = x
            for _ in 0..<24 {
                let currentX = sample(t, x1, x2)
                if abs(currentX - x) < 1e-5 { break }
                if currentX < x { lower = t } else { upper = t }
                t = (lower + upper) / 2
            }
            return sample(t, y1, y2)
        }

        private func sample(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }

        private func derivative(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
        }
    }

    /// One bounded progress run: `progress(at:)` is a pure function of time,
    /// so a frame can never depend on callback ordering or display cadence.
    struct MotionRun: Equatable {
        var from: CGFloat
        var to: CGFloat
        var startTime: TimeInterval?
        var duration: TimeInterval
        var timing: CubicBezierTiming

        func progress(at time: TimeInterval) -> CGFloat {
            guard let startTime, duration > 0, time.isFinite else { return from }
            let raw = min(1, max(0, (time - startTime) / duration))
            return from + (to - from) * timing.solve(raw)
        }

        func isComplete(at time: TimeInterval) -> Bool {
            guard let startTime, duration > 0 else { return true }
            return time - startTime >= duration
        }
    }

    // MARK: - Anchor

    /// The real destination point: the configured work-area corner on the
    /// correct display, pulled `anchorInset` toward the interior so the tip
    /// always stays inside the usable area (menu bar, Dock and Retina-safe).
    static func anchorPoint(
        in workArea: CGRect,
        corner: ScreenCorner,
        spec: Spec = .standard
    ) -> CGPoint {
        guard workArea.isFinite else { return .zero }
        let inset = min(max(0, spec.anchorInset), min(workArea.width, workArea.height) / 2)
        let x = (corner == .topRight || corner == .bottomRight)
            ? workArea.maxX - inset
            : workArea.minX + inset
        let y = (corner == .topRight || corner == .topLeft)
            ? workArea.maxY - inset
            : workArea.minY + inset
        return CGPoint(x: x, y: y)
    }

    /// Anchor expressed in panel-local points ((0,0) = the visible panel
    /// rect's lower-left). May legitimately sit outside the panel bounds —
    /// that overshoot is what makes the tip reach the screen corner.
    static func anchorInPanelSpace(
        panelVisibleFrame: CGRect,
        workArea: CGRect,
        corner: ScreenCorner,
        spec: Spec = .standard
    ) -> CGPoint {
        let anchor = anchorPoint(in: workArea, corner: corner, spec: spec)
        return CGPoint(
            x: anchor.x - panelVisibleFrame.minX,
            y: anchor.y - panelVisibleFrame.minY
        )
    }

    // MARK: - Forward warp map

    /// Per-point consumption fraction in [0,1]. `leadX`/`leadY` are the
    /// normalized distances toward the anchor's horizontal/vertical sides
    /// (1 at the anchor edge, 0 at the far edge).
    static func consumption(
        leadX: CGFloat,
        leadY: CGFloat,
        progress: CGFloat,
        spec: Spec = .standard
    ) -> CGFloat {
        guard leadX.isFinite, leadY.isFinite, progress.isFinite else { return 0 }
        let lead = max(0, spec.cornerLead)
        let exponent = max(0.01, spec.leadExponent)
        let closeness = min(1, max(0, spec.horizontalWeight)) * pow(min(1, max(0, leadX)), exponent)
            + min(1, max(0, spec.verticalWeight)) * pow(min(1, max(0, leadY)), exponent)
        let raw = min(1, max(0, progress * (1 + lead * closeness)))
        return pow(raw, max(0.01, spec.consumptionExponent))
    }

    /// Normalized lead coordinates of a unit-space source point for the
    /// given corner. Mirroring happens here so all four corners share one
    /// field.
    static func leadCoordinates(
        u: CGFloat,
        v: CGFloat,
        corner: ScreenCorner
    ) -> (leadX: CGFloat, leadY: CGFloat) {
        let uu = min(1, max(0, u))
        let vv = min(1, max(0, v))
        switch corner {
        case .topRight: return (uu, vv)
        case .topLeft: return (1 - uu, vv)
        case .bottomRight: return (uu, 1 - vv)
        case .bottomLeft: return (1 - uu, 1 - vv)
        }
    }

    /// Forward map: panel-local source point (points, origin at the visible
    /// rect's lower-left) → deformed destination. Identity at progress 0;
    /// collapses exactly onto `anchor` at progress 1. Invalid inputs return
    /// the untouched source so a bad frame fails safe rather than warping.
    static func warpedPoint(
        _ point: CGPoint,
        in size: CGSize,
        progress: CGFloat,
        corner: ScreenCorner,
        anchor: CGPoint,
        spec: Spec = .standard
    ) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite,
              anchor.x.isFinite, anchor.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return point }
        let p = min(1, max(0, progress.isFinite ? progress : 0))
        guard p > 0 else { return point }
        let leads = leadCoordinates(
            u: point.x / size.width,
            v: point.y / size.height,
            corner: corner
        )
        let c = consumption(leadX: leads.leadX, leadY: leads.leadY, progress: p, spec: spec)
        return CGPoint(
            x: point.x + (anchor.x - point.x) * c,
            y: point.y + (anchor.y - point.y) * c
        )
    }

    /// The progress actually rendered: identical to progress until the very
    /// tip, then clamped so the mesh stays non-degenerate on screen. Full
    /// collapse is completed by ordering the surface out, not by sampling an
    /// exactly-zero-area mesh.
    static func displayProgress(_ progress: CGFloat, spec: Spec = .standard) -> CGFloat {
        guard progress.isFinite else { return 0 }
        return min(max(0, progress), spec.displayProgressCeiling)
    }

    // MARK: - Mesh

    /// Vertex-grid divisions for a panel size: roughly one cell per
    /// `meshCellSize` points, bounded so extreme sizes stay finite.
    static func meshDivisions(
        for size: CGSize,
        spec: Spec = .standard
    ) -> (columns: Int, rows: Int) {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return (spec.meshMinimumSegments, spec.meshMinimumSegments)
        }
        let cell = max(4, spec.meshCellSize)
        let lower = max(1, spec.meshMinimumSegments)
        let upper = max(lower, spec.meshMaximumSegments)
        let columns = min(upper, max(lower, Int((size.width / cell).rounded())))
        let rows = min(upper, max(lower, Int((size.height / cell).rounded())))
        return (columns, rows)
    }

    /// Identity unit-space vertex field for `columns × rows` cells, row-major
    /// from the lower-left — matches the ordering SKWarpGeometryGrid expects.
    static func sourcePositions(columns: Int, rows: Int) -> [CGPoint] {
        let columns = max(1, columns)
        let rows = max(1, rows)
        var positions: [CGPoint] = []
        positions.reserveCapacity((columns + 1) * (rows + 1))
        for row in 0...rows {
            for column in 0...columns {
                positions.append(CGPoint(
                    x: CGFloat(column) / CGFloat(columns),
                    y: CGFloat(row) / CGFloat(rows)
                ))
            }
        }
        return positions
    }

    /// Forward-warped unit-space destinations for every source vertex, in the
    /// same row-major order. Values may exceed [0,1] — the anchor overshoots
    /// the sprite bounds to reach the screen corner.
    static func destinationPositions(
        columns: Int,
        rows: Int,
        size: CGSize,
        progress: CGFloat,
        corner: ScreenCorner,
        anchor: CGPoint,
        spec: Spec = .standard
    ) -> [CGPoint] {
        let sources = sourcePositions(columns: columns, rows: rows)
        guard size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite else { return sources }
        return sources.map { source in
            let warped = warpedPoint(
                CGPoint(x: source.x * size.width, y: source.y * size.height),
                in: size,
                progress: progress,
                corner: corner,
                anchor: anchor,
                spec: spec
            )
            return CGPoint(x: warped.x / size.width, y: warped.y / size.height)
        }
    }

    // MARK: - Runs

    static func transitionDuration(
        distance: CGFloat,
        direction: MotionDirection,
        spec: Spec = .standard
    ) -> TimeInterval {
        let base = direction == .conceal ? spec.hideDuration : spec.showDuration
        let clamped = min(1, max(0, distance.isFinite ? distance : 0))
        let scaled = base * Double(pow(clamped, spec.distanceExponent))
        return max(spec.minimumRunDuration, scaled)
    }

    /// Plans a bounded run from the currently applied progress to `target`,
    /// continuing from whatever is on screen — the interruption contract.
    static func planRun(
        from current: CGFloat,
        to target: CGFloat,
        direction: MotionDirection,
        spec: Spec = .standard
    ) -> MotionRun {
        let distance = abs(target - current)
        return MotionRun(
            from: current,
            to: target,
            startTime: nil,
            duration: transitionDuration(distance: distance, direction: direction, spec: spec),
            timing: direction == .conceal ? .conceal : .reveal
        )
    }

    // MARK: - Interactive dismissal

    static func swipeProgress(
        forSwipeDistance distance: CGFloat,
        panelWidth: CGFloat,
        spec: Spec = .standard
    ) -> CGFloat {
        guard distance.isFinite, panelWidth.isFinite else { return 0 }
        let travel = min(
            spec.swipeTravelMaximum,
            max(spec.swipeTravelMinimum, panelWidth * spec.swipeTravelWidthFactor)
        )
        guard travel > 0 else { return 0 }
        return min(spec.swipeProgressCeiling, max(0, distance / travel))
    }
}
