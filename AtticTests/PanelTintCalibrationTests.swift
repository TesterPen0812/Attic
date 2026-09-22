import Foundation
import SwiftUI
import XCTest
@testable import Attic

/// Recomputes every cell of the shipped tint table with an independent Lab
/// implementation, checks the readability floor, and pins the Depth crown.
/// Set `ATTIC_PRINT_TINT_TABLE=1` to print regenerated Swift source for the
/// table after a palette or model change.
final class PanelTintCalibrationTests: XCTestCase {
    private typealias Kind = AtticPanelSurfaceTreatment.Kind

    /// Independent ΔE76: a second sRGB → Lab conversion written from the
    /// standard formulas, so a mistake in the app's copy cannot self-verify.
    private func independentDeltaE(_ a: AtticThemeColor, _ b: AtticThemeColor) -> Double {
        func lab(_ c: AtticThemeColor) -> (Double, Double, Double) {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = lin(c.red), g = lin(c.green), bl = lin(c.blue)
            let x = (r * 0.4124 + g * 0.3576 + bl * 0.1805) / 0.95047
            let y = (r * 0.2126 + g * 0.7152 + bl * 0.0722) / 1.0
            let z = (r * 0.0193 + g * 0.1192 + bl * 0.9505) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (l1, a1, b1) = lab(a)
        let (l2, a2, b2) = lab(b)
        return sqrt(pow(l1 - l2, 2) + pow(a1 - a2, 2) + pow(b1 - b2, 2))
    }

    private func treatment(_ theme: AtticPanelTheme, _ appearance: AtticPanelThemeAppearance,
                           _ kind: Kind, depth: Bool, tint: PanelTintLevel = .off,
                           contrast: ColorSchemeContrast = .standard) -> AtticPanelSurfaceTreatment {
        theme.surfaceTreatment(appearance: appearance, contrast: contrast,
                               surface: PanelSurfaceStyle(kind), depth: depth, tint: tint,
                               reduceTransparency: false)
    }

    func testTableHasEveryCell() {
        var count = 0
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in Kind.allCases {
                    for depth in [false, true] {
                        for level in PanelTintLevel.allCases where level != .off {
                            count += 1
                            XCTAssertNotNil(PanelTintCalibration.cell(
                                theme: theme, appearance: appearance, kind: kind, depth: depth, level: level
                            ), "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue) depth=\(depth) \(level.rawValue)")
                        }
                        XCTAssertNil(PanelTintCalibration.cell(
                            theme: theme, appearance: appearance, kind: kind, depth: depth, level: .off))
                    }
                }
            }
        }
        XCTAssertEqual(count, 7 * 2 * 3 * 2 * 3)
        XCTAssertEqual(PanelTintCalibration.table.count, 7 * 2 * 3 * 2)
    }

    func testEveryCellReproducesItsTargetDifferenceAndKeepsTextReadable() {
        var clamped: [String] = []
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in Kind.allCases {
                    for depth in [false, true] {
                        let base = treatment(theme, appearance, kind, depth: depth)
                        let backdrop = PanelTintCalibration.worstCaseBackdrop(for: appearance)
                        let untinted = base.compositedSurface(over: backdrop, location: 0)
                        XCTAssertEqual(untinted, PanelTintCalibration.baseComposite(
                            treatment: base, depth: depth, backdrop: backdrop))
                        for level in [PanelTintLevel.subtle, .vivid, .bold] {
                            let tinted = treatment(theme, appearance, kind, depth: depth, tint: level)
                            let context = "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue) depth=\(depth) \(level.rawValue)"
                            guard let cell = PanelTintCalibration.cell(
                                theme: theme, appearance: appearance, kind: kind, depth: depth, level: level
                            ) else { XCTFail(context); continue }
                            XCTAssertEqual(tinted.tintTopOpacity, cell.topOpacity, context)
                            XCTAssertGreaterThan(cell.topOpacity, 0, context)
                            XCTAssertLessThanOrEqual(cell.topOpacity, 1, context)

                            let top = tinted.compositedSurface(over: backdrop, location: 0)
                            let difference = independentDeltaE(untinted, top)
                            XCTAssertEqual(difference, cell.colorDifference, accuracy: 0.05,
                                           "\(context): stored ΔE drifted")
                            let target = level.targetColorDifference ?? 0
                            if cell.isClamped {
                                clamped.append(context)
                                XCTAssertLessThan(difference, target, "\(context): a clamped cell is below target")
                            } else {
                                XCTAssertEqual(difference, target, accuracy: 0.25, context)
                            }
                            // The readability floor at the top edge, over the
                            // worst-case composite, for primary and secondary.
                            let contrast = PanelTintCalibration.minimumForegroundContrast(
                                palette: tinted.palette, over: top)
                            XCTAssertGreaterThanOrEqual(contrast, AtticPanelSurfaceTreatment.readableContrastTarget - 0.0001,
                                                        "\(context): text falls below 4.75:1")
                            // And everywhere below the top edge, where the
                            // wash only fades, over the eight desktop extremes.
                            for extreme in [0.0, 1.0] {
                                for red in [0.0, 1.0] { for green in [0.0, 1.0] { for blue in [0.0, 1.0] {
                                    _ = extreme
                                    let desktop = AtticThemeColor(red: red, green: green, blue: blue)
                                    for location in [0.0, 0.2, 0.42, 0.6, 0.74, 1.0] {
                                        let color = tinted.compositedSurface(over: desktop, location: location)
                                        XCTAssertGreaterThanOrEqual(
                                            PanelTintCalibration.minimumForegroundContrast(palette: tinted.palette, over: color),
                                            4.5, "\(context) desktop=\(desktop.hexString) location=\(location)")
                                    }
                                } } }
                            }
                        }
                    }
                }
            }
        }
        // Which cells the readability floor set is recorded in the appearance
        // ledger; this keeps that list honest.
        XCTAssertEqual(Set(clamped), Set(PanelTintCalibration.clampedCellDescriptions))
    }

    func testTableMatchesTheSolver() {
        // The shipped table is the solver's output at the time it was
        // generated. If a palette, foreground or crown stop changes, the
        // solver moves and this fails until the table is regenerated.
        let solved = PanelTintCalibration.solveTable()
        XCTAssertEqual(solved.count, PanelTintCalibration.table.count)
        for (key, cells) in solved {
            for (level, cell) in cells {
                let shipped = PanelTintCalibration.table[key]?[level]
                XCTAssertEqual(shipped?.topOpacity, cell.topOpacity, "\(key) \(level.rawValue)")
                XCTAssertEqual(shipped?.isClamped, cell.isClamped, "\(key) \(level.rawValue)")
                if let shipped {
                    XCTAssertEqual(shipped.colorDifference, cell.colorDifference, accuracy: 0.011, "\(key) \(level.rawValue)")
                }
            }
        }
        if ProcessInfo.processInfo.environment["ATTIC_PRINT_TINT_TABLE"] == "1" {
            print("=== PanelTintCalibration.table ===")
            print(PanelTintCalibration.swiftSource(for: solved))
            print("=== end ===")
        }
    }

    func testStepsGrowMonotonicallyOnEveryCellAndMatchThePrototypeOnSolid() throws {
        // The prototype solved Solid without Depth and no palette clamped
        // there; the shipped values must agree within the table's rounding.
        let prototype: [String: [String: (String, Double)]] = [
            "original-dark": ["subtle": ("247BF2", 0.027), "vivid": ("247BF2", 0.065), "bold": ("247BF2", 0.116)],
            "original-light": ["subtle": ("2681FF", 0.035), "vivid": ("2681FF", 0.082), "bold": ("2681FF", 0.141)],
            "amethyst-light": ["subtle": ("6D26FF", 0.024), "vivid": ("6D26FF", 0.055), "bold": ("6D26FF", 0.094)],
            "smokedUmber-dark": ["subtle": ("F2A624", 0.023), "vivid": ("F2A624", 0.054), "bold": ("F2A624", 0.093)]
        ]
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in Kind.allCases {
                    for depth in [false, true] {
                        let cells = [PanelTintLevel.subtle, .vivid, .bold].compactMap {
                            PanelTintCalibration.cell(theme: theme, appearance: appearance, kind: kind, depth: depth, level: $0)
                        }
                        XCTAssertEqual(cells.count, 3)
                        XCTAssertLessThanOrEqual(cells[0].topOpacity, cells[1].topOpacity)
                        XCTAssertLessThanOrEqual(cells[1].topOpacity, cells[2].topOpacity)
                        if !cells[1].isClamped {
                            XCTAssertLessThan(cells[0].topOpacity, cells[1].topOpacity)
                        }
                        if !cells[2].isClamped {
                            XCTAssertLessThan(cells[1].topOpacity, cells[2].topOpacity)
                        }
                        if kind == .solid, !depth,
                           let expected = prototype["\(theme.rawValue)-\(appearance.rawValue)"] {
                            let wash = PanelTintCalibration.washColor(
                                for: theme.palette(for: appearance), appearance: appearance)
                            XCTAssertEqual(wash.hexString, expected["subtle"]?.0)
                            XCTAssertFalse(cells[0].isClamped)
                            XCTAssertEqual(cells[0].topOpacity, try XCTUnwrap(expected["subtle"]?.1), accuracy: 0.002)
                            XCTAssertEqual(cells[1].topOpacity, try XCTUnwrap(expected["vivid"]?.1), accuracy: 0.002)
                            XCTAssertEqual(cells[2].topOpacity, try XCTUnwrap(expected["bold"]?.1), accuracy: 0.002)
                        }
                    }
                }
            }
        }
    }

    func testGlassCellsHoldTheirStrengthOverAMidGreyBackdropToo() {
        // Calibrated over the worst-case backdrop, the same opacity over a
        // mid-grey desktop must still read as the same step: close to the
        // strength it was solved for, never collapsing or doubling. The
        // readability floor also still holds there.
        let grey = AtticThemeColor(red: 0.5, green: 0.5, blue: 0.5)
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in [Kind.glass, .frosted] {
                    for depth in [false, true] {
                        let base = treatment(theme, appearance, kind, depth: depth)
                        let untinted = base.compositedSurface(over: grey, location: 0)
                        for level in [PanelTintLevel.subtle, .vivid, .bold] {
                            let tinted = treatment(theme, appearance, kind, depth: depth, tint: level)
                            let top = tinted.compositedSurface(over: grey, location: 0)
                            let difference = independentDeltaE(untinted, top)
                            guard let cell = PanelTintCalibration.cell(
                                theme: theme, appearance: appearance, kind: kind, depth: depth, level: level
                            ) else { XCTFail(); continue }
                            let context = "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue) depth=\(depth) \(level.rawValue) grey ΔE \(difference) vs \(cell.colorDifference)"
                            XCTAssertGreaterThan(difference, cell.colorDifference * 0.5, context)
                            XCTAssertLessThan(difference, cell.colorDifference * 1.8, context)
                            XCTAssertGreaterThanOrEqual(
                                PanelTintCalibration.minimumForegroundContrast(palette: tinted.palette, over: top),
                                AtticPanelSurfaceTreatment.readableContrastTarget, context)
                        }
                    }
                }
            }
        }
    }

    func testIncreasedContrastChangesNothingTheTableDependsOn() {
        // The composite depends on the surface, the foundation (from the
        // fixed foregrounds) and the accent hue; Increased Contrast changes
        // only edges and selection, so the same table applies.
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                let standard = theme.palette(for: appearance, contrast: .standard)
                let increased = theme.palette(for: appearance, contrast: .increased)
                XCTAssertEqual(standard.opaqueSurface, increased.opaqueSurface)
                XCTAssertEqual(standard.accent, increased.accent)
                XCTAssertEqual(standard.primaryForeground, increased.primaryForeground)
                XCTAssertEqual(standard.secondaryForeground, increased.secondaryForeground)
                for kind in Kind.allCases {
                    for depth in [false, true] {
                        for level in PanelTintLevel.allCases {
                            let a = treatment(theme, appearance, kind, depth: depth, tint: level)
                            let b = treatment(theme, appearance, kind, depth: depth, tint: level, contrast: .increased)
                            XCTAssertEqual(a.foundationOpacity, b.foundationOpacity)
                            XCTAssertEqual(a.tintTopOpacity, b.tintTopOpacity)
                            XCTAssertEqual(a.washColor, b.washColor)
                        }
                    }
                }
            }
        }
    }

    func testWashColourIsTheAccentHueSaturated() {
        XCTAssertEqual(PanelTintCalibration.saturation, 0.85)
        XCTAssertEqual(PanelTintCalibration.value(for: .light), 1.0)
        XCTAssertEqual(PanelTintCalibration.value(for: .dark), 0.95)
        XCTAssertEqual(PanelTintCalibration.fadeEnd, 0.6)
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                let palette = theme.palette(for: appearance)
                let wash = PanelTintCalibration.washColor(for: palette, appearance: appearance)
                XCTAssertEqual(PanelTintCalibration.hue(of: wash), PanelTintCalibration.hue(of: palette.accent), accuracy: 0.002)
                let maximum = max(wash.red, wash.green, wash.blue)
                let minimum = min(wash.red, wash.green, wash.blue)
                XCTAssertEqual(maximum, PanelTintCalibration.value(for: appearance), accuracy: 0.0001)
                XCTAssertEqual((maximum - minimum) / maximum, 0.85, accuracy: 0.0001)
            }
        }
        let t = treatment(.original, .light, .solid, depth: false, tint: .vivid)
        XCTAssertEqual(t.tintOpacity(at: 0), t.tintTopOpacity)
        XCTAssertEqual(t.tintOpacity(at: 0.3), t.tintTopOpacity / 2, accuracy: 0.000_001)
        XCTAssertEqual(t.tintOpacity(at: 0.6), 0)
        XCTAssertEqual(t.tintOpacity(at: 1), 0)
        XCTAssertEqual(t.tintOpacity(at: .nan), 0)
        XCTAssertEqual(treatment(.original, .light, .solid, depth: false).tintOpacity(at: 0), 0)
    }

    // MARK: Depth

    func testDepthCrownUsesTheExactStops() {
        XCTAssertEqual(PanelDepthCrown.stops.map(\.opacity), [0.82, 0.58, 0.18, 0.02])
        XCTAssertEqual(PanelDepthCrown.stops.map(\.location), [0.00, 0.42, 0.74, 1.00])
        XCTAssertEqual(PanelDepthCrown.poleColor(for: .dark), AtticThemeColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(PanelDepthCrown.poleColor(for: .light), AtticThemeColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(PanelDepthCrown.opacity(at: 0), 0.82)
        XCTAssertEqual(PanelDepthCrown.opacity(at: 0.42), 0.58)
        XCTAssertEqual(PanelDepthCrown.opacity(at: 0.21), 0.70, accuracy: 0.000_001)
        XCTAssertEqual(PanelDepthCrown.opacity(at: 0.74), 0.18)
        XCTAssertEqual(PanelDepthCrown.opacity(at: 1), 0.02)
        XCTAssertEqual(PanelDepthCrown.opacity(at: -1), 0.82)
        XCTAssertEqual(PanelDepthCrown.opacity(at: 2), 0.02)
        XCTAssertEqual(PanelDepthCrown.opacity(at: .nan), 0)
    }

    func testDepthAppliesToEverySurfaceAndPaletteAndKeepsTheFloor() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in Kind.allCases {
                    let plain = treatment(theme, appearance, kind, depth: false)
                    let deep = treatment(theme, appearance, kind, depth: true)
                    XCTAssertTrue(deep.depth)
                    XCTAssertEqual(plain.foundationOpacity, deep.foundationOpacity,
                                   "Depth is one layer above the fill; it never changes the foundation")
                    let backdrop = PanelTintCalibration.worstCaseBackdrop(for: appearance)
                    let top = deep.compositedSurface(over: backdrop, location: 0)
                    let expected = plain.compositedSurface(over: backdrop, location: 0)
                        .mixed(with: PanelDepthCrown.poleColor(for: appearance), amount: 0.82)
                    XCTAssertEqual(top, expected)
                    // The crown pole is the readable direction for the mode,
                    // so the floor holds everywhere under it.
                    for red in [0.0, 1.0] { for green in [0.0, 1.0] { for blue in [0.0, 1.0] {
                        let desktop = AtticThemeColor(red: red, green: green, blue: blue)
                        for location in [0.0, 0.42, 0.74, 1.0] {
                            XCTAssertGreaterThanOrEqual(
                                PanelTintCalibration.minimumForegroundContrast(
                                    palette: deep.palette, over: deep.compositedSurface(over: desktop, location: location)),
                                4.5, "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue) \(desktop.hexString) \(location)")
                        }
                    } } }
                }
            }
        }
    }

    func testReduceTransparencyRendersSolidButKeepsDepthAndTint() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for surface in PanelSurfaceStyle.allCases {
                    let reduced = theme.surfaceTreatment(appearance: appearance, surface: surface,
                                                         depth: true, tint: .bold, reduceTransparency: true)
                    XCTAssertEqual(reduced.kind, .solid)
                    XCTAssertEqual(reduced.foundationOpacity, 1)
                    XCTAssertTrue(reduced.depth)
                    XCTAssertEqual(reduced.tint, .bold)
                    XCTAssertGreaterThan(reduced.tintTopOpacity, 0)
                    let solid = theme.surfaceTreatment(appearance: appearance, surface: .solid,
                                                       depth: true, tint: .bold, reduceTransparency: false)
                    XCTAssertEqual(reduced, solid)
                }
            }
        }
    }

    func testReadableFoundationIsTheLowestWholePercentMeetingContrastTarget() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in [Kind.glass, .frosted] {
                    let surface = treatment(theme, appearance, kind, depth: false)
                    let backdrop = PanelTintCalibration.worstCaseBackdrop(for: appearance)
                    func contrastAt(_ opacity: Double) -> Double {
                        PanelTintCalibration.minimumForegroundContrast(
                            palette: surface.palette,
                            over: backdrop.mixed(with: surface.palette.opaqueSurface, amount: opacity))
                    }
                    let context = "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue)"
                    XCTAssertGreaterThanOrEqual(contrastAt(surface.foundationOpacity),
                                                AtticPanelSurfaceTreatment.readableContrastTarget, context)
                    XCTAssertLessThan(contrastAt(surface.foundationOpacity - 0.01),
                                      AtticPanelSurfaceTreatment.readableContrastTarget, context)
                    XCTAssertLessThan(surface.foundationOpacity, appearance == .dark ? 0.75 : 0.65, context)
                    XCTAssertEqual(treatment(theme, appearance, .solid, depth: false).foundationOpacity, 1)
                }
            }
        }
    }

    func testOriginalLightSolidWithoutDepthOrTintIsPureWhite() {
        let white = AtticThemeColor(red: 1, green: 1, blue: 1)
        for contrast in [ColorSchemeContrast.standard, .increased] {
            for reduce in [false, true] {
                for surface in PanelSurfaceStyle.allCases where reduce || surface == .solid {
                    let t = AtticPanelTheme.original.surfaceTreatment(
                        appearance: .light, contrast: contrast, surface: surface,
                        depth: false, tint: .off, reduceTransparency: reduce)
                    XCTAssertEqual(t.kind, .solid)
                    XCTAssertEqual(t.materialTintOpacity, 0)
                    for backdrop in [AtticThemeColor(red: 0, green: 0, blue: 0),
                                     AtticThemeColor(red: 0.5, green: 0.2, blue: 0.8)] {
                        XCTAssertEqual(t.compositedSurface(over: backdrop, location: 0), white)
                        XCTAssertEqual(t.compositedSurface(over: backdrop, location: 1), white)
                    }
                }
            }
        }
        for theme in AtticPanelTheme.allCases where theme != .original {
            XCTAssertNotEqual(theme.palette(for: AtticPanelThemeAppearance.light).opaqueSurface, white)
        }
    }

    func testSolidSurfacesTransmitNoDesktop() {
        let black = AtticThemeColor(red: 0, green: 0, blue: 0)
        let white = AtticThemeColor(red: 1, green: 1, blue: 1)
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for depth in [false, true] {
                    for tint in PanelTintLevel.allCases {
                        let surface = treatment(theme, appearance, .solid, depth: depth, tint: tint)
                        for location in [0.0, 0.3, 0.6, 1.0] {
                            let fromBlack = surface.compositedSurface(over: black, location: location)
                            let fromWhite = surface.compositedSurface(over: white, location: location)
                            XCTAssertEqual(fromBlack.red, fromWhite.red, accuracy: 0.000_000_001)
                            XCTAssertEqual(fromBlack.green, fromWhite.green, accuracy: 0.000_000_001)
                            XCTAssertEqual(fromBlack.blue, fromWhite.blue, accuracy: 0.000_000_001)
                        }
                    }
                }
            }
        }
    }
}
