import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The one frame every panel surface shares: the outside-only elevation,
/// the hairline edge and the native-glass control outline. These pin the
/// parts that are pure geometry or pure tokens; whether the frame reads
/// well on a real desktop is the capture pass in the appearance ledger.
@MainActor
final class PanelFrameTests: XCTestCase {
    private struct Sample {
        let alpha: Double
        let red: Double
    }

    /// Renders the outside shadow alone, with room around it, and returns
    /// the pixel sampler. The renderer draws at 2x so a 0.75pt overlap is
    /// still a whole pixel.
    private func renderOutsideShadow(
        elevation: AtticPanelSurfaceElevation,
        size: CGSize = CGSize(width: 160, height: 120),
        cornerRadius: CGFloat = 40
    ) throws -> (CGSize, (CGFloat, CGFloat) -> Sample) {
        let margin = AtticStyle.panelElevationMargin
        let shape = Squircle(cornerRadius: cornerRadius, exponent: AtticStyle.panelSquircleExponent)
        let view = AtticPanelOutsideShadow(shape: shape, elevation: elevation)
            .frame(width: size.width, height: size.height)
            .padding(margin)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let canvas = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        XCTAssertEqual(CGFloat(rep.pixelsWide), canvas.width * 2)
        XCTAssertEqual(CGFloat(rep.pixelsHigh), canvas.height * 2)
        return (canvas, { x, y in
            guard let color = rep.colorAt(x: Int(x * 2), y: Int(y * 2)) else {
                return Sample(alpha: -1, red: -1)
            }
            return Sample(alpha: Double(color.alphaComponent), red: Double(color.redComponent))
        })
    }

    func testOutsideShadowNeverDrawsInsideTheShape() throws {
        let margin = AtticStyle.panelElevationMargin
        for elevation in [AtticPanelSurfaceElevation.light, .dark] {
            let (canvas, sample) = try renderOutsideShadow(elevation: elevation)
            let inner = CGRect(x: margin, y: margin,
                               width: canvas.width - margin * 2, height: canvas.height - margin * 2)
            // Interior: nothing at all, from the centre right up to the edge.
            for point in [
                CGPoint(x: inner.midX, y: inner.midY),
                CGPoint(x: inner.minX + 2, y: inner.midY),
                CGPoint(x: inner.maxX - 2, y: inner.midY),
                CGPoint(x: inner.midX, y: inner.minY + 2),
                CGPoint(x: inner.midX, y: inner.maxY - 2),
                CGPoint(x: inner.minX + 1, y: inner.midY),
                CGPoint(x: inner.midX, y: inner.maxY - 1)
            ] {
                XCTAssertEqual(sample(point.x, point.y).alpha, 0, accuracy: 0.004,
                               "\(elevation) draws inside the shape at \(point)")
            }
            // Exterior: the shadow is present just outside the edge on every
            // side and has faded out before the margin ends. The offset
            // makes the bottom stronger than the top, never the reverse.
            let left = sample(inner.minX - 3, inner.midY).alpha
            let right = sample(inner.maxX + 3, inner.midY).alpha
            let top = sample(inner.midX, inner.minY - 3).alpha
            let bottom = sample(inner.midX, inner.maxY + 3).alpha
            XCTAssertGreaterThan(left, 0.01, "\(elevation) left")
            XCTAssertGreaterThan(right, 0.01, "\(elevation) right")
            XCTAssertGreaterThan(top, 0.005, "\(elevation) top")
            XCTAssertGreaterThan(bottom, 0.01, "\(elevation) bottom")
            XCTAssertGreaterThanOrEqual(bottom, top, "\(elevation) offset points down")
            XCTAssertLessThan(sample(inner.minX - margin + 1, inner.midY).alpha, 0.01,
                              "\(elevation) must fade out inside the margin")
            XCTAssertLessThan(sample(inner.midX, inner.maxY + margin - 1).alpha, 0.01,
                              "\(elevation) must fade out inside the margin")
            // Strength scales with the elevation opacity at the same point.
            XCTAssertLessThan(bottom, elevation.opacity + 0.01)
        }
        let (_, light) = try renderOutsideShadow(elevation: .light)
        let (_, dark) = try renderOutsideShadow(elevation: .dark)
        XCTAssertGreaterThan(dark(margin + 80, margin + 120 + 3).alpha,
                             light(margin + 80, margin + 120 + 3).alpha)
    }

    func testOutsideShadowClearsTheCornersOfTheSquircleToo() throws {
        let margin = AtticStyle.panelElevationMargin
        let (canvas, sample) = try renderOutsideShadow(elevation: .dark, cornerRadius: 60)
        let inner = CGRect(x: margin, y: margin,
                           width: canvas.width - margin * 2, height: canvas.height - margin * 2)
        // A corner pixel of the bounding box lies outside the squircle, so
        // it is exterior: shadowed, not cut out.
        XCTAssertGreaterThan(sample(inner.minX + 1, inner.minY + 1).alpha, 0.01)
        // The 45° point of the corner curve is inside the shape.
        let inset = 60 * Squircle.cornerInsetFactor(exponent: AtticStyle.panelSquircleExponent)
        XCTAssertEqual(sample(inner.minX + inset + 3, inner.minY + inset + 3).alpha, 0, accuracy: 0.004)
    }

    func testNativeGlassControlsCarryAFaintOutlineOnEverySurface() {
        XCTAssertEqual(AtticGlassControlTreatment.nativeGlassOutlineOpacity(for: .standard), 0.10)
        XCTAssertEqual(AtticGlassControlTreatment.nativeGlassOutlineOpacity(for: .increased), 0.20)
        XCTAssertGreaterThan(AtticGlassControlTreatment.nativeGlassOutlineOpacity(for: .increased),
                             AtticGlassControlTreatment.nativeGlassOutlineOpacity(for: .standard))
        XCTAssertEqual(AtticGlassControlTreatment.nativeGlassOutlineLineWidth(for: .standard), 0.75)
        XCTAssertEqual(AtticGlassControlTreatment.nativeGlassOutlineLineWidth(for: .increased), 1)
        // The outline is a boundary, never a border: it stays well below
        // the panel's own opaque control edge.
        XCTAssertLessThan(AtticGlassControlTreatment.nativeGlassOutlineOpacity(for: .standard), 0.17)
    }

    func testShadowCasterInsetHidesItsRimWithoutOpeningASeam() throws {
        // At 2x one device pixel is 0.5pt: the caster's anti-aliased rim
        // must lie inside the exact cut-out, and the cut-out must not reach
        // beyond the true edge, or a bright seam opens between the hairline
        // and the shadow (measured on the Light Solid capture).
        XCTAssertGreaterThanOrEqual(AtticPanelOutsideShadow.casterInset, 0.5)
        XCTAssertLessThanOrEqual(AtticPanelOutsideShadow.casterInset, 1)
        let margin = AtticStyle.panelElevationMargin
        let (canvas, sample) = try renderOutsideShadow(elevation: .light)
        let inner = CGRect(x: margin, y: margin,
                           width: canvas.width - margin * 2, height: canvas.height - margin * 2)
        // The very first pixel outside the edge still carries shadow.
        let justOutside = sample(inner.minX - 0.5, inner.midY).alpha
        let furtherOut = sample(inner.minX - 2, inner.midY).alpha
        XCTAssertGreaterThan(justOutside, 0.01)
        XCTAssertGreaterThanOrEqual(justOutside, furtherOut * 0.8,
                                    "the shadow must not be eaten next to the edge")
    }
}
