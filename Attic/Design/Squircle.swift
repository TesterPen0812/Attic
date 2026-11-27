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
struct Squircle: InsettableShape {
    /// Extent of each corner curve in points. The curve spans this distance
    /// from the corner along both the horizontal and vertical edges.
    var cornerRadius: CGFloat

    /// Superellipse exponent for the corner curve.
    var exponent: CGFloat = 5

    /// How far the shape is drawn inside its rect (`inset(by:)`, so strokes
    /// can sit inside the edge); the corner shrinks with it.
    var insetAmount: CGFloat = 0

    /// Square top or bottom corners, for a highlight that runs on into the
    /// row above or below it (`AtticSelectionRun`).
    var squaredTop = false
    var squaredBottom = false

    init(cornerRadius: CGFloat, exponent: CGFloat = 5, squaredTop: Bool = false, squaredBottom: Bool = false) {
        self.cornerRadius = cornerRadius
        self.exponent = exponent
        self.squaredTop = squaredTop
        self.squaredBottom = squaredBottom
    }

    func inset(by amount: CGFloat) -> Squircle {
        var inset = self
        inset.insetAmount += amount
        return inset
    }

    /// The path is a pure function of the shape and the rect, and SwiftUI
    /// asks a clip or content shape for it on every hit test: each hover
    /// responder's contains check, so every scroll event rebuilt the panel's
    /// unchanged squircle (4 × 33 superellipse points; scroll trace 27 Nov,
    /// `Squircle.path` under `AtticPanelContentContainer.hitTest`). A built
    /// path is kept for its shape and rect and rebuilt when either changes.
    func path(in fullRect: CGRect) -> Path {
        SquirclePathCache.shared.path(for: SquirclePathCache.Key(self, fullRect)) { buildPath(in: fullRect) }
    }

    fileprivate func buildPath(in fullRect: CGRect) -> Path {
        let rect = fullRect.insetBy(dx: insetAmount, dy: insetAmount)
        let cornerRadius = max(0, cornerRadius - insetAmount)
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
            if (cornerIndex < 2 ? squaredTop : squaredBottom) {
                let point = CGPoint(x: cornerIndex == 0 || cornerIndex == 3 ? rect.minX : rect.maxX,
                                    y: cornerIndex < 2 ? rect.minY : rect.maxY)
                if cornerIndex == 0 { path.move(to: point) } else { path.addLine(to: point) }
                continue
            }
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

/// Built squircle paths, by everything `Squircle.path(in:)` reads. Shapes
/// draw and hit-test from render and main threads, so it is locked; a resize
/// makes a new rect every frame, so it is bounded and starts over when full.
final class SquirclePathCache: @unchecked Sendable {
    struct Key: Hashable {
        let x, y, width, height, cornerRadius, exponent, inset: CGFloat
        let squaredTop, squaredBottom: Bool

        init(_ shape: Squircle, _ rect: CGRect) {
            x = rect.origin.x; y = rect.origin.y; width = rect.size.width; height = rect.size.height
            cornerRadius = shape.cornerRadius; exponent = shape.exponent; inset = shape.insetAmount
            squaredTop = shape.squaredTop; squaredBottom = shape.squaredBottom
        }
    }

    static let shared = SquirclePathCache(capacity: 64)

    private let capacity: Int
    private let lock = NSLock()
    private var paths: [Key: Path] = [:]
    #if DEBUG
    private var builds = 0
    /// Test seam: off, every call builds (the trunk's behaviour), so a test
    /// can compare kept and fresh paths.
    var isEnabled = true
    #endif

    init(capacity: Int) { self.capacity = capacity }

    func path(for key: Key, build: () -> Path) -> Path {
        lock.lock()
        #if DEBUG
        let enabled = isEnabled && false
        #else
        let enabled = true
        #endif
        if enabled, let kept = paths[key] {
            lock.unlock()
            return kept
        }
        #if DEBUG
        builds += 1
        #endif
        lock.unlock()
        let built = build()
        guard enabled else { return built }
        lock.lock()
        if paths.count >= capacity { paths.removeAll(keepingCapacity: true) }
        paths[key] = built
        lock.unlock()
        return built
    }

    #if DEBUG
    /// How many paths were built (cache misses), for count tests.
    var buildCount: Int { lock.lock(); defer { lock.unlock() }; return builds }

    func removeAll() { lock.lock(); paths.removeAll(); lock.unlock() }
    #endif
}
