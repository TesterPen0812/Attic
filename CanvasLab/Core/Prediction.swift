import CoreGraphics

/// C3 only: bounded constant-velocity extrapolation, one 120 Hz interval.
/// Predicted points are never admitted into committed geometry.
enum Prediction {
    static func point(previous: CGPoint, latest: CGPoint, dt: Double, horizon: Double = 1.0 / 120) -> CGPoint {
        guard dt > 0 else { return latest }
        let dx = latest.x - previous.x, dy = latest.y - previous.y
        let gain = min(horizon / dt, 1)
        let length = hypot(dx, dy), cap = length > 0 ? min(12 / length, gain) : 0
        return CGPoint(x: latest.x + dx * cap, y: latest.y + dy * cap)
    }
}
