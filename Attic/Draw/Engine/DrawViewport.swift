import CoreGraphics

/// What part of the world the board shows: screen = world × zoom + offset,
/// in points with y down (the drawing's own axes). Pure value math, shared
/// by the page model, the board view and the renderer.
struct DrawViewport: Equatable, Codable, Sendable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var zoom: CGFloat = 1

    /// Planning.md, Draw › Board: pinch or ⌘-scroll zooms between 10 and 400 %.
    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 4
    /// Fit never magnifies past 200 % (the working file's `fit`).
    static let fitMaxZoom: CGFloat = 2
    /// Fit leaves 24 px (12 pt) inside the clear area.
    static let fitPadding: CGFloat = 12

    static func clamp(_ zoom: CGFloat) -> CGFloat { min(maxZoom, max(minZoom, zoom)) }

    func screen(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * zoom + x, y: point.y * zoom + y) }
    func world(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - x) / zoom, y: (point.y - y) / zoom) }

    func screen(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * zoom + x, y: rect.minY * zoom + y, width: rect.width * zoom, height: rect.height * zoom)
    }

    func panned(dx: CGFloat, dy: CGFloat) -> DrawViewport {
        DrawViewport(x: x + dx, y: y + dy, zoom: zoom)
    }

    /// Zoom to `newZoom` (clamped), keeping the world point under `anchor` still.
    func zoomed(to newZoom: CGFloat, around anchor: CGPoint) -> DrawViewport {
        let z = Self.clamp(newZoom)
        return DrawViewport(x: anchor.x - (anchor.x - x) * z / zoom, y: anchor.y - (anchor.y - y) * z / zoom, zoom: z)
    }

    /// ⇧0: 100 %, keeping the world point at the clear area's centre still.
    func actualSize(centre: CGPoint) -> DrawViewport { zoomed(to: 1, around: centre) }

    /// ⇧1 and the zoom pill: everything in `bounds` (world) centred in
    /// `clear` (screen), at most 200 %. Nothing to fit returns the origin at 100 %.
    static func fit(_ bounds: CGRect?, in clear: CGRect) -> DrawViewport {
        guard let bounds, !bounds.isNull, !bounds.isInfinite else { return DrawViewport() }
        let width = max(clear.width - fitPadding * 2, 1), height = max(clear.height - fitPadding * 2, 1)
        let z = clamp(min(fitMaxZoom, width / max(bounds.width, 1), height / max(bounds.height, 1)))
        return DrawViewport(x: clear.midX - bounds.midX * z, y: clear.midY - bounds.midY * z, zoom: z)
    }

    /// The affine map from world to screen (y down).
    var transform: CGAffineTransform { CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: x, ty: y) }

    /// "Fit" while lost (D5): whether any of `rects` (world) meets `clear` (screen).
    func anyInView(_ rects: [CGRect], clear: CGRect) -> Bool {
        rects.contains { screen($0).intersects(clear) }
    }
}
