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
}
