import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// "Brighten glass over dark backgrounds" (owner, 2026-11-11, option C):
/// off by default; on, Light see-through surfaces get the 0.14 additive
/// white; Dark, Solid and Increase Contrast never do.
@MainActor
final class GlassLiftToggleTests: XCTestCase {
    func testSwitchIsOffForFreshInstallsAndRemembered() throws {
        let suite = "GlassLiftToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.brightenGlass)
        XCTAssertEqual(AtticDesignContext(mode: .light, surface: .glass).glassLift, 0)
        settings.brightenGlass = true
        XCTAssertTrue(AppSettings(defaults: defaults).brightenGlass)
    }

    func testLiftOnlyOnLightSeeThroughSurfacesWithTheSwitchOn() {
        let strength = AtticSurfaceModel.glassLiftStrength
        XCTAssertEqual(strength, 0.14)
        for kind in [AtticPanelSurfaceTreatment.Kind.glass, .frosted] {
            XCTAssertEqual(AtticSurfaceModel.glassLift(enabled: true, appearance: .light, kind: kind, increaseContrast: false), strength)
            XCTAssertEqual(AtticSurfaceModel.glassLift(enabled: false, appearance: .light, kind: kind, increaseContrast: false), 0)
            XCTAssertEqual(AtticSurfaceModel.glassLift(enabled: true, appearance: .dark, kind: kind, increaseContrast: false), 0)
            XCTAssertEqual(AtticSurfaceModel.glassLift(enabled: true, appearance: .light, kind: kind, increaseContrast: true), 0)
        }
        XCTAssertEqual(AtticSurfaceModel.glassLift(enabled: true, appearance: .light, kind: .solid, increaseContrast: false), 0)
    }

    func testDesignContextAppliesTheSameRule() {
        func lift(_ mode: AtticDesignContext.Mode, _ surface: PanelSurfaceStyle,
                  increaseContrast: Bool = false, reduceTransparency: Bool = false) -> Double {
            AtticDesignContext(mode: mode, surface: surface, increaseContrast: increaseContrast,
                               reduceTransparency: reduceTransparency, brightenGlass: true).glassLift
        }
        XCTAssertEqual(lift(.light, .glass), AtticSurfaceModel.glassLiftStrength)
        XCTAssertEqual(lift(.light, .frosted), AtticSurfaceModel.glassLiftStrength)
        XCTAssertEqual(lift(.dark, .glass), 0)
        XCTAssertEqual(lift(.light, .solid), 0)
        XCTAssertEqual(lift(.light, .glass, increaseContrast: true), 0)
        XCTAssertEqual(lift(.light, .glass, reduceTransparency: true), 0)
        // The panel's resolved surface model gives the same answer.
        let light = AtticDesignContext(mode: .light, surface: .glass, brightenGlass: true)
        XCTAssertEqual(light.tokens.panel.glassLift(enabled: true), AtticSurfaceModel.glassLiftStrength)
        let dark = AtticDesignContext(mode: .dark, surface: .glass, brightenGlass: true)
        XCTAssertEqual(dark.tokens.panel.glassLift(enabled: true), 0)
    }

    // MARK: - Genie snapshot

    /// Genie draws the panel's material live under the bent snapshot, and
    /// `PanelGenieMaterialView` adds the lift there. The snapshot (the scan's
    /// hidden layers, then `renderTier`) must leave the lift out exactly as
    /// it leaves the material out, or the flight is brightened twice.
    func testGenieSnapshotLeavesTheLiftOut() throws {
        for surface in [PanelSurfaceStyle.glass, .frosted] {
            let off = try snapshotSum(surface: surface, brightenGlass: false)
            let on = try snapshotSum(surface: surface, brightenGlass: true)
            XCTAssertGreaterThan(on.liftLayers, 0, "\(surface): the lift is drawn")
            XCTAssertEqual(on.liftHidden, on.liftLayers, "\(surface): every lift layer is hidden")
            XCTAssertEqual(on.hidden - off.hidden, on.liftLayers, "\(surface): only the lift is added")
            XCTAssertEqual(on.sum, off.sum, accuracy: off.sum * 0.002 + 1, "\(surface): the snapshot carries no lift")
        }
    }

    private func snapshotSum(surface: PanelSurfaceStyle, brightenGlass: Bool) throws
        -> (sum: Double, hidden: Int, liftLayers: Int, liftHidden: Int) {
        let size = CGSize(width: 320, height: 480)
        let context = AtticDesignContext(mode: .light, surface: surface, brightenGlass: brightenGlass)
        let shape = Squircle(cornerRadius: 52, exponent: AtticStyle.panelSquircleExponent)
        let host = NSHostingView(rootView: AtticSurfaceBackground(model: context.tokens.panel, shape: shape)
            .frame(width: size.width, height: size.height)
            .atticDesign(context))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        host.layoutSubtreeIfNeeded()
        host.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let root = try XCTUnwrap(host.layer)
        // As the controller: only live Frosted hides the surface material.
        let scan = PanelGenieView.scanGlass(in: root, surfaceRect: host.bounds, hidesSurfaceMaterial: surface == .frosted)
        let liftLayers = Self.layers(in: root).filter { ($0.compositingFilter as AnyObject?)?.description.contains("plusL") == true }
        let image = try XCTUnwrap(PanelGenieView.renderTier(of: host, hiding: scan.hidden, scale: 1))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmap = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let hidden = Set(scan.hidden.map(ObjectIdentifier.init))
        return (pixels.reduce(0) { $0 + Double($1) }, hidden.count, liftLayers.count,
                liftLayers.filter { hidden.contains(ObjectIdentifier($0)) }.count)
    }

    private static func layers(in layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap { layers(in: $0) }
    }
}
