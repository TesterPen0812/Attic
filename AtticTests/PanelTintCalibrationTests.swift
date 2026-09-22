import Foundation
import SwiftUI
import XCTest
@testable import Attic

/// Recomputes every cell of the shipped tint table with an independent Lab
/// implementation and checks both the credited native-surface model and the
/// pre-macOS-26 uncredited fallback. Set `ATTIC_PRINT_TINT_TABLE=1` to print
/// regenerated Swift source after a palette or model change.
final class PanelTintCalibrationTests: XCTestCase {
    private typealias Kind = AtticPanelSurfaceTreatment.Kind

    private func independentDeltaE(_ a: AtticThemeColor, _ b: AtticThemeColor) -> Double {
        func lab(_ c: AtticThemeColor) -> (Double, Double, Double) {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = lin(c.red), g = lin(c.green), bl = lin(c.blue)
            let x = (r * 0.4124 + g * 0.3576 + bl * 0.1805) / 0.95047
            let y = (r * 0.2126 + g * 0.7152 + bl * 0.0722)
            let z = (r * 0.0193 + g * 0.1192 + bl * 0.9505) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (l1, a1, b1) = lab(a)
        let (l2, a2, b2) = lab(b)
        return sqrt(pow(l1 - l2, 2) + pow(a1 - a2, 2) + pow(b1 - b2, 2))
    }

    private func treatment(
        _ theme: AtticPanelTheme,
        _ appearance: AtticPanelThemeAppearance,
        _ kind: Kind,
        tint: PanelTintLevel = .off,
        tintLength: Double = PanelTintLength.defaultValue,
        contrast: ColorSchemeContrast = .standard,
        creditsNativeSurface: Bool = true
    ) -> AtticPanelSurfaceTreatment {
        let palette = theme.palette(for: appearance, contrast: contrast)
        return AtticPanelSurfaceTreatment(
            theme: theme,
            kind: kind,
            palette: palette,
            appearance: appearance,
            usesSystemOpaqueSurface: theme == .original,
            tint: tint,
            tintLength: tintLength,
            creditsNativeSurface: creditsNativeSurface
        )
    }

    private func measuredUnderlay(
        kind: Kind,
        appearance: AtticPanelThemeAppearance,
        desktop: AtticThemeColor
    ) -> AtticThemeColor {
        guard kind != .solid else { return desktop }
        let blackByte: Double
        let whiteByte: Double
        switch (kind, appearance) {
        case (.glass, .dark): blackByte = 20; whiteByte = 143
        case (.glass, .light): blackByte = 104; whiteByte = 236
        case (.frosted, .dark): blackByte = 24; whiteByte = 166
        case (.frosted, .light): blackByte = 89; whiteByte = 241
        case (.solid, _): return desktop
        }
        // The prototype supplied black/white endpoints. For arbitrary desktop
        // colours the validation model linearly interpolates each channel by
        // that channel's source intensity.
        func channel(_ source: Double) -> Double {
            (blackByte + (whiteByte - blackByte) * source) / 255
        }
        return AtticThemeColor(red: channel(desktop.red), green: channel(desktop.green), blue: channel(desktop.blue))
    }

    func testMeasuredWorstCaseUnderlaysArePinned() {
        XCTAssertEqual(AtticPanelSurfaceTreatment.worstCaseUnderlay(kind: .glass, appearance: .dark, creditsNativeSurface: true), .init(red: 143.0 / 255, green: 143.0 / 255, blue: 143.0 / 255))
        XCTAssertEqual(AtticPanelSurfaceTreatment.worstCaseUnderlay(kind: .glass, appearance: .light, creditsNativeSurface: true), .init(red: 104.0 / 255, green: 104.0 / 255, blue: 104.0 / 255))
        XCTAssertEqual(AtticPanelSurfaceTreatment.worstCaseUnderlay(kind: .frosted, appearance: .dark, creditsNativeSurface: true), .init(red: 166.0 / 255, green: 166.0 / 255, blue: 166.0 / 255))
        XCTAssertEqual(AtticPanelSurfaceTreatment.worstCaseUnderlay(kind: .frosted, appearance: .light, creditsNativeSurface: true), .init(red: 89.0 / 255, green: 89.0 / 255, blue: 89.0 / 255))
        XCTAssertEqual(AtticPanelSurfaceTreatment.worstCaseUnderlay(kind: .glass, appearance: .dark, creditsNativeSurface: false), .init(red: 1, green: 1, blue: 1))
        XCTAssertEqual(AtticPanelSurfaceTreatment.worstCaseUnderlay(kind: .glass, appearance: .light, creditsNativeSurface: false), .init(red: 0, green: 0, blue: 0))
    }

    func testTableHasEveryCellAndNoClamps() {
        var count = 0
        XCTAssertEqual(PanelTintCalibration.colouredThemes, AtticPanelTheme.allCases.filter { $0 != .original })
        for theme in PanelTintCalibration.colouredThemes {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in Kind.allCases {
                    for level in [PanelTintLevel.subtle, .vivid, .bold] {
                        count += 1
                        let context = "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue) \(level.rawValue)"
                        guard let cell = PanelTintCalibration.cell(theme: theme, appearance: appearance, kind: kind, level: level) else {
                            XCTFail(context); continue
                        }
                        XCTAssertFalse(cell.isClamped, context)
                    }
                    XCTAssertNil(PanelTintCalibration.cell(theme: theme, appearance: appearance, kind: kind, level: .off))
                }
            }
        }
        XCTAssertEqual(count, 6 * 2 * 3 * 3)
        XCTAssertEqual(PanelTintCalibration.table.count, 6 * 2 * 3)
        // Original's Tint is the neutral shade, never a table cell.
        for appearance in AtticPanelThemeAppearance.allCases {
            for kind in Kind.allCases {
                for level in PanelTintLevel.allCases {
                    XCTAssertNil(PanelTintCalibration.cell(theme: .original, appearance: appearance, kind: kind, level: level))
                }
            }
        }
        XCTAssertTrue(PanelTintCalibration.clampedCellDescriptions.isEmpty)
    }

    func testEveryCellHitsTargetAndKeepsTextReadableAcrossMeasuredDesktopExtremes() {
        for theme in PanelTintCalibration.colouredThemes {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in Kind.allCases {
                    for level in [PanelTintLevel.subtle, .vivid, .bold] {
                        let tinted = treatment(theme, appearance, kind, tint: level)
                        let context = "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue) \(level.rawValue)"
                        guard let cell = PanelTintCalibration.cell(theme: theme, appearance: appearance, kind: kind, level: level) else {
                            XCTFail(context); continue
                        }
                        XCTAssertEqual(tinted.foundationOpacity, cell.foundationOpacity, context)
                        XCTAssertEqual(tinted.tintTopOpacity, cell.topOpacity, context)
                        let worst = AtticPanelSurfaceTreatment.worstCaseUnderlay(kind: kind, appearance: appearance, creditsNativeSurface: true)
                        let base = PanelTintCalibration.baseComposite(palette: tinted.palette, foundationOpacity: tinted.foundationOpacity, backdrop: worst)
                        let top = PanelTintCalibration.tintedComposite(base: base, wash: tinted.washColor, topOpacity: tinted.tintTopOpacity)
                        XCTAssertEqual(independentDeltaE(base, top), level.targetColorDifference ?? 0, accuracy: 0.25, context)
                        let floor = AtticPanelSurfaceTreatment.readableContrastTarget(kind: kind, creditsNativeSurface: true)
                        XCTAssertGreaterThanOrEqual(PanelTintCalibration.minimumForegroundContrast(palette: tinted.palette, over: top), floor - 0.0001, context)

                        // Every Tint length: the wash only falls from the top
                        // edge, so a longer Tint must not cost readability.
                        for length in [PanelTintLength.range.lowerBound, 0.6, PanelTintLength.defaultValue] {
                            let long = treatment(theme, appearance, kind, tint: level, tintLength: length)
                            XCTAssertEqual(long.foundationOpacity, tinted.foundationOpacity, context)
                            XCTAssertEqual(long.tintTopOpacity, tinted.tintTopOpacity, context)
                            for red in [0.0, 1.0] { for green in [0.0, 1.0] { for blue in [0.0, 1.0] {
                                let desktop = AtticThemeColor(red: red, green: green, blue: blue)
                                let underlay = kind == .solid ? desktop : measuredUnderlay(kind: kind, appearance: appearance, desktop: desktop)
                                for location in [0.0, 0.2, 0.3, 0.42, 0.6, 0.74, 0.9, 1.0] {
                                    let color = long.compositedSurface(over: underlay, location: location)
                                    XCTAssertGreaterThanOrEqual(
                                        PanelTintCalibration.minimumForegroundContrast(palette: long.palette, over: color),
                                        floor - 0.0001,
                                        "\(context) length=\(length) desktop=\(desktop.hexString) location=\(location)"
                                    )
                                }
                            } } }
                        }
                    }
                }
            }
        }
    }

    func testTableMatchesTheSolver() {
        let solved = PanelTintCalibration.solveTable()
        XCTAssertEqual(solved.count, PanelTintCalibration.table.count)
        for (key, cells) in solved {
            for (level, cell) in cells {
                guard let shipped = PanelTintCalibration.table[key]?[level] else {
                    XCTFail("\(key) \(level.rawValue)"); continue
                }
                XCTAssertEqual(shipped.foundationOpacity, cell.foundationOpacity, "\(key) \(level.rawValue)")
                XCTAssertEqual(shipped.topOpacity, cell.topOpacity, "\(key) \(level.rawValue)")
                XCTAssertEqual(shipped.isClamped, cell.isClamped, "\(key) \(level.rawValue)")
                XCTAssertEqual(shipped.colorDifference, cell.colorDifference, accuracy: 0.011, "\(key) \(level.rawValue)")
            }
        }
        if ProcessInfo.processInfo.environment["ATTIC_PRINT_TINT_TABLE"] == "1" {
            print("=== PanelTintCalibration.table ===")
            print(PanelTintCalibration.swiftSource(for: solved))
            print("=== end ===")
        }
    }

    func testTintAwareFoundationIsMonotoneAndSolidPrototypeValuesStayPinned() throws {
        let prototype: [String: [String: (String, Double)]] = [
            "amethyst-light": ["subtle": ("6D26FF", 0.024), "vivid": ("6D26FF", 0.055), "bold": ("6D26FF", 0.094)],
            "smokedUmber-dark": ["subtle": ("F2A624", 0.023), "vivid": ("F2A624", 0.054), "bold": ("F2A624", 0.093)]
        ]
        for theme in PanelTintCalibration.colouredThemes {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in Kind.allCases {
                    let cells = [PanelTintLevel.subtle, .vivid, .bold].compactMap {
                        PanelTintCalibration.cell(theme: theme, appearance: appearance, kind: kind, level: $0)
                    }
                    XCTAssertEqual(cells.count, 3)
                    XCTAssertLessThanOrEqual(cells[0].foundationOpacity, cells[1].foundationOpacity)
                    XCTAssertLessThanOrEqual(cells[1].foundationOpacity, cells[2].foundationOpacity)
                    XCTAssertLessThan(cells[0].topOpacity, cells[1].topOpacity)
                    XCTAssertLessThan(cells[1].topOpacity, cells[2].topOpacity)
                    if kind == .solid, let expected = prototype["\(theme.rawValue)-\(appearance.rawValue)"] {
                        let wash = PanelTintCalibration.washColor(for: theme.palette(for: appearance), appearance: appearance)
                        XCTAssertEqual(wash.hexString, expected["subtle"]?.0)
                        XCTAssertEqual(cells[0].foundationOpacity, 1)
                        XCTAssertEqual(cells[0].topOpacity, try XCTUnwrap(expected["subtle"]?.1), accuracy: 0.002)
                        XCTAssertEqual(cells[1].topOpacity, try XCTUnwrap(expected["vivid"]?.1), accuracy: 0.002)
                        XCTAssertEqual(cells[2].topOpacity, try XCTUnwrap(expected["bold"]?.1), accuracy: 0.002)
                    }
                }
            }
        }
    }

    func testCreditedFoundationsAreLowerThanHistoricalUncreditedForEveryPaletteAndAppearance() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in [Kind.glass, .frosted] {
                    let credited = treatment(theme, appearance, kind, creditsNativeSurface: true)
                    let uncredited = treatment(theme, appearance, kind, creditsNativeSurface: false)
                    XCTAssertLessThan(credited.foundationOpacity, uncredited.foundationOpacity, "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue)")
                }
            }
        }
    }

    func testUncreditedPathReproducesHistoricalFoundationNumbersExactly() {
        let expected: [AtticPanelTheme: [AtticPanelThemeAppearance: Double]] = [
            .original: [.light: 0.54, .dark: 0.66],
            .midnightCobalt: [.light: 0.57, .dark: 0.66],
            .porcelainVapor: [.light: 0.56, .dark: 0.69],
            .smokedUmber: [.light: 0.58, .dark: 0.67],
            .electricBlue: [.light: 0.55, .dark: 0.66],
            .seaGlass: [.light: 0.57, .dark: 0.68],
            .amethyst: [.light: 0.57, .dark: 0.67]
        ]
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in [Kind.glass, .frosted] {
                    XCTAssertEqual(treatment(theme, appearance, kind, creditsNativeSurface: false).foundationOpacity, expected[theme]?[appearance], "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue)")
                }
            }
        }
    }

    func testReadableFoundationIsTheLowestWholePercentMeetingContrastTarget() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for kind in [Kind.glass, .frosted] {
                    let surface = treatment(theme, appearance, kind)
                    let underlay = AtticPanelSurfaceTreatment.worstCaseUnderlay(kind: kind, appearance: appearance, creditsNativeSurface: true)
                    func contrastAt(_ opacity: Double) -> Double {
                        PanelTintCalibration.minimumForegroundContrast(
                            palette: surface.palette,
                            over: underlay.mixed(with: surface.palette.opaqueSurface, amount: opacity)
                        )
                    }
                    let context = "\(theme.rawValue) \(appearance.rawValue) \(kind.rawValue)"
                    let floor = AtticPanelSurfaceTreatment.readableContrastTarget(kind: kind, creditsNativeSurface: true)
                    XCTAssertGreaterThanOrEqual(contrastAt(surface.foundationOpacity), floor, context)
                    if surface.foundationOpacity > 0.01 {
                        XCTAssertLessThan(contrastAt(surface.foundationOpacity - 0.01), floor, context)
                    }
                }
            }
        }
    }

    func testIncreasedContrastChangesNothingCalibrationDependsOn() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                let standard = theme.palette(for: appearance, contrast: .standard)
                let increased = theme.palette(for: appearance, contrast: .increased)
                XCTAssertEqual(standard.opaqueSurface, increased.opaqueSurface)
                XCTAssertEqual(standard.accent, increased.accent)
                XCTAssertEqual(standard.primaryForeground, increased.primaryForeground)
                XCTAssertEqual(standard.secondaryForeground, increased.secondaryForeground)
                for kind in Kind.allCases {
                    for level in PanelTintLevel.allCases {
                        let a = treatment(theme, appearance, kind, tint: level)
                        let b = treatment(theme, appearance, kind, tint: level, contrast: .increased)
                        XCTAssertEqual(a.foundationOpacity, b.foundationOpacity)
                        XCTAssertEqual(a.tintTopOpacity, b.tintTopOpacity)
                        XCTAssertEqual(a.washColor, b.washColor)
                    }
                }
            }
        }
    }

    func testReduceTransparencyRendersSolidButKeepsTint() {
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for surface in PanelSurfaceStyle.allCases {
                    let reduced = theme.surfaceTreatment(appearance: appearance, surface: surface, tint: .bold, reduceTransparency: true)
                    XCTAssertEqual(reduced.kind, .solid)
                    XCTAssertEqual(reduced.foundationOpacity, 1)
                    XCTAssertEqual(reduced.tint, .bold)
                    XCTAssertGreaterThan(reduced.tintTopOpacity, 0)
                    let solid = theme.surfaceTreatment(appearance: appearance, surface: .solid, tint: .bold, reduceTransparency: false)
                    XCTAssertEqual(reduced, solid)
                }
            }
        }
    }

    func testOriginalLightSolidWithoutTintIsPureWhite() {
        let white = AtticThemeColor(red: 1, green: 1, blue: 1)
        for contrast in [ColorSchemeContrast.standard, .increased] {
            for reduce in [false, true] {
                for surface in PanelSurfaceStyle.allCases where reduce || surface == .solid {
                    let t = AtticPanelTheme.original.surfaceTreatment(
                        appearance: .light, contrast: contrast, surface: surface,
                        tint: .off, reduceTransparency: reduce
                    )
                    XCTAssertEqual(t.kind, .solid)
                    XCTAssertEqual(t.materialTintOpacity, 0)
                    for backdrop in [AtticThemeColor(red: 0, green: 0, blue: 0), AtticThemeColor(red: 0.5, green: 0.2, blue: 0.8)] {
                        XCTAssertEqual(t.compositedSurface(over: backdrop, location: 0), white)
                        XCTAssertEqual(t.compositedSurface(over: backdrop, location: 1), white)
                    }
                }
            }
        }
    }

    func testSolidSurfacesTransmitNoDesktop() {
        let black = AtticThemeColor(red: 0, green: 0, blue: 0)
        let white = AtticThemeColor(red: 1, green: 1, blue: 1)
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                for tint in PanelTintLevel.allCases {
                    let surface = treatment(theme, appearance, .solid, tint: tint)
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

    // MARK: Original's neutral shade

    private func brightMeasuredUnderlay(kind: Kind, desktop: AtticThemeColor) -> AtticThemeColor {
        // The bright (Light-appearance) native surface, per channel between
        // its measured black and white endpoints, in either panel mode.
        let black = AtticPanelSurfaceTreatment.brightUnderlay(kind: kind, appearance: .light).red
        let white = AtticPanelSurfaceTreatment.brightUnderlay(kind: kind, appearance: .dark).red
        func channel(_ source: Double) -> Double { black + (white - black) * source }
        return AtticThemeColor(red: channel(desktop.red), green: channel(desktop.green), blue: channel(desktop.blue))
    }

    func testNeutralShadeProfileFloorsAndStepsArePinned() {
        XCTAssertEqual(PanelNeutralShade.profile.map(\.opacity), [0.98, 0.80, 0.57, 0.38, 0.25])
        XCTAssertEqual(PanelNeutralShade.profile.map(\.location), [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(PanelTintLevel.allCases.map(PanelNeutralShade.strength(for:)), [0, 0.35, 0.65, 1])
        XCTAssertEqual(PanelNeutralShade.color(for: .dark), .init(red: 0, green: 0, blue: 0))
        XCTAssertEqual(PanelNeutralShade.color(for: .light), .init(red: 1, green: 1, blue: 1))
        XCTAssertTrue(PanelNeutralShade.stops(level: .off, length: 1).isEmpty)
        XCTAssertEqual(PanelNeutralShade.stops(level: .vivid, length: 0.5).map(\.location), [0, 0.125, 0.25, 0.375, 0.5])
        XCTAssertEqual(PanelNeutralShade.rampOpacity(level: .bold, length: 0.5, at: 0.9), 0.25, accuracy: 1e-12)
        XCTAssertEqual(PanelNeutralShade.rampOpacity(level: .bold, length: 1, at: 0.125), 0.89, accuracy: 1e-12)
        XCTAssertEqual(PanelNeutralShade.readableFloor(kind: .glass, at: 0), 4.75)
        XCTAssertEqual(PanelNeutralShade.readableFloor(kind: .glass, at: 1), 2.0)
        XCTAssertEqual(PanelNeutralShade.readableFloor(kind: .glass, at: 0.5), 3.375, accuracy: 1e-12)
        XCTAssertEqual(PanelNeutralShade.readableFloor(kind: .frosted, at: 1), 2.5)
        XCTAssertEqual(PanelNeutralShade.sampleCount, 21)
        XCTAssertEqual(AtticPanelSurfaceTreatment.brightUnderlay(kind: .glass, appearance: .dark), .init(red: 254.0 / 255, green: 254.0 / 255, blue: 254.0 / 255))
        XCTAssertEqual(AtticPanelSurfaceTreatment.brightUnderlay(kind: .frosted, appearance: .light), .init(red: 89.0 / 255, green: 89.0 / 255, blue: 89.0 / 255))
    }

    /// Original with a Tint on native Glass or Frosted: bright surface, no
    /// flat foundation, and at every sampled height the shade is the darker
    /// of the step's ramp and the least shade that meets the relaxing floor
    /// over the worst-case bright surface.
    func testShadeCarriesReadabilityOnNativeTranslucentSurfaces() {
        for appearance in AtticPanelThemeAppearance.allCases {
            for kind in [Kind.glass, .frosted] {
                XCTAssertFalse(treatment(.original, appearance, kind).usesShadeAsFoundation, "Tint Off keeps the flat foundation")
                var previous: [PanelTintStop]?
                for level in [PanelTintLevel.subtle, .vivid, .bold] {
                    for length in [0.3, 0.6, 1.0] {
                        let shaded = treatment(.original, appearance, kind, tint: level, tintLength: length)
                        let context = "\(appearance.rawValue) \(kind.rawValue) \(level.rawValue) \(length)"
                        XCTAssertTrue(shaded.usesShadeAsFoundation, context)
                        XCTAssertEqual(shaded.foundationOpacity, 0, context)
                        XCTAssertFalse(shaded.isTintClamped, context)
                        XCTAssertEqual(shaded.worstCaseBackdrop(), AtticPanelSurfaceTreatment.brightUnderlay(kind: kind, appearance: appearance), context)
                        let stops = shaded.tintStops
                        XCTAssertEqual(stops.count, 21, context)
                        let worst = AtticPanelSurfaceTreatment.brightUnderlay(kind: kind, appearance: appearance)
                        for stop in stops {
                            let floor = PanelNeutralShade.readableFloor(kind: kind, at: stop.location)
                            let ramp = PanelNeutralShade.rampOpacity(level: level, length: length, at: stop.location)
                            let color = shaded.compositedSurface(over: worst, location: stop.location)
                            XCTAssertGreaterThanOrEqual(
                                PanelTintCalibration.minimumForegroundContrast(palette: shaded.palette, over: color),
                                floor - 1e-9, "\(context) @\(stop.location)")
                            XCTAssertGreaterThanOrEqual(stop.opacity, ramp - 1e-12, "\(context) @\(stop.location)")
                            // Never more shade than the ramp or the floor asks for.
                            let lighter = worst.mixed(with: shaded.washColor, amount: stop.opacity - 0.002)
                            XCTAssertTrue(
                                stop.opacity - 0.002 < ramp
                                    || PanelTintCalibration.minimumForegroundContrast(palette: shaded.palette, over: lighter) < floor,
                                "\(context) @\(stop.location) is darker than needed")
                        }
                        if length == 1 {
                            if let previous {
                                for (weaker, stronger) in zip(previous, stops) {
                                    XCTAssertLessThanOrEqual(weaker.opacity, stronger.opacity, "\(context) @\(stronger.location)")
                                }
                            }
                            previous = stops
                        }
                    }
                }
            }
        }
    }

    func testShadeKeepsItsFloorOverEveryDesktopExtreme() {
        for appearance in AtticPanelThemeAppearance.allCases {
            for kind in [Kind.glass, .frosted] {
                for level in [PanelTintLevel.subtle, .vivid, .bold] {
                    let shaded = treatment(.original, appearance, kind, tint: level)
                    for red in [0.0, 1.0] { for green in [0.0, 1.0] { for blue in [0.0, 1.0] {
                        let desktop = AtticThemeColor(red: red, green: green, blue: blue)
                        let underlay = brightMeasuredUnderlay(kind: kind, desktop: desktop)
                        for location in stride(from: 0.0, through: 1.0, by: 0.05) {
                            let contrast = PanelTintCalibration.minimumForegroundContrast(
                                palette: shaded.palette, over: shaded.compositedSurface(over: underlay, location: location))
                            XCTAssertGreaterThanOrEqual(contrast, PanelNeutralShade.readableFloor(kind: kind, at: location) - 1e-9,
                                "\(appearance.rawValue) \(kind.rawValue) \(level.rawValue) \(desktop.hexString) @\(location)")
                        }
                    } } }
                }
            }
        }
    }

    /// Bold on Glass over a white page is the Siri ramp (about 5, 50, 100,
    /// 145 and 175 at the top, quarter, middle, three-quarter and bottom),
    /// except that the 2:1 floor keeps the lower edge a little darker; and it
    /// is lighter than today's flat Glass at the bottom.
    func testBoldGlassFollowsTheSiriRamp() {
        let bold = treatment(.original, .dark, .glass, tint: .bold)
        let worst = AtticPanelSurfaceTreatment.brightUnderlay(kind: .glass, appearance: .dark)
        func brightness(_ location: Double) -> Double { bold.compositedSurface(over: worst, location: location).red * 255 }
        XCTAssertLessThan(brightness(0), 10)
        XCTAssertEqual(brightness(0.25), 50, accuracy: 6)
        XCTAssertEqual(brightness(0.5), 100, accuracy: 10)
        XCTAssertEqual(brightness(0.75), 145, accuracy: 8)
        XCTAssertEqual(brightness(1), 163, accuracy: 6)
        let flat = treatment(.original, .dark, .glass)
        let flatBrightness = flat.compositedSurface(over: AtticPanelSurfaceTreatment.worstCaseUnderlay(kind: .glass, appearance: .dark, creditsNativeSurface: true)).red * 255
        XCTAssertGreaterThan(brightness(1), flatBrightness + 20, "the lower edge is more see-through than flat Glass")
    }

    /// On Solid and below macOS 26 the shade is drawn over the usual surface
    /// and only moves it away from the text colour.
    func testShadeOverTheUsualSurfaceNeverLowersContrast() {
        for appearance in AtticPanelThemeAppearance.allCases {
            for (kind, credits) in [(Kind.solid, true), (.solid, false), (.glass, false), (.frosted, false)] {
                let plain = treatment(.original, appearance, kind, creditsNativeSurface: credits)
                for level in [PanelTintLevel.subtle, .vivid, .bold] {
                    for length in [0.3, 0.6, 1.0] {
                        let shaded = treatment(.original, appearance, kind, tint: level, tintLength: length, creditsNativeSurface: credits)
                        let context = "\(appearance.rawValue) \(kind.rawValue) credits=\(credits) \(level.rawValue) \(length)"
                        XCTAssertFalse(shaded.usesShadeAsFoundation, context)
                        XCTAssertEqual(shaded.foundationOpacity, plain.foundationOpacity, context)
                        XCTAssertEqual(shaded.tintStops, PanelNeutralShade.stops(level: level, length: length), context)
                        for red in [0.0, 1.0] { for green in [0.0, 1.0] { for blue in [0.0, 1.0] {
                            let desktop = AtticThemeColor(red: red, green: green, blue: blue)
                            for location in stride(from: 0.0, through: 1.0, by: 0.05) {
                                let before = PanelTintCalibration.minimumForegroundContrast(
                                    palette: plain.palette, over: plain.compositedSurface(over: desktop, location: location))
                                let after = PanelTintCalibration.minimumForegroundContrast(
                                    palette: shaded.palette, over: shaded.compositedSurface(over: desktop, location: location))
                                XCTAssertGreaterThanOrEqual(after, before - 1e-9, "\(context) \(desktop.hexString) @\(location)")
                            }
                        } } }
                    }
                }
            }
        }
        XCTAssertFalse(treatment(.amethyst, .dark, .glass, tint: .bold).usesNeutralTint)
        XCTAssertFalse(treatment(.amethyst, .dark, .glass, tint: .bold).usesShadeAsFoundation)
    }

    // MARK: Tint length

    func testTintLengthClampsAndShapesTheColouredWash() {
        XCTAssertEqual(PanelTintLength.range, 0.3...1.0)
        XCTAssertEqual(PanelTintLength.defaultValue, 1)
        XCTAssertEqual(PanelTintLength.clamped(0.1), 0.3)
        XCTAssertEqual(PanelTintLength.clamped(2), 1)
        XCTAssertEqual(PanelTintLength.clamped(.nan), PanelTintLength.defaultValue)
        let short = treatment(.seaGlass, .dark, .glass, tint: .vivid, tintLength: 0.4)
        XCTAssertEqual(short.tintLength, 0.4)
        XCTAssertEqual(short.tintStops, [
            PanelTintStop(opacity: short.tintTopOpacity, location: 0),
            PanelTintStop(opacity: 0, location: 0.4)
        ])
        XCTAssertEqual(short.tintOpacity(at: 0.2), short.tintTopOpacity / 2, accuracy: 1e-12)
        XCTAssertEqual(short.tintOpacity(at: 0.4), 0)
        XCTAssertEqual(short.tintOpacity(at: 0.9), 0)
        let full = treatment(.seaGlass, .dark, .glass, tint: .vivid)
        XCTAssertEqual(full.tintOpacity(at: 0.5), full.tintTopOpacity / 2, accuracy: 1e-12)
        XCTAssertEqual(treatment(.seaGlass, .dark, .glass, tint: .vivid, tintLength: -3).tintLength, 0.3)
    }

    func testDrawnGradientStopsAreTheModelledStops() {
        for theme in [AtticPanelTheme.original, .electricBlue] {
            let surface = treatment(theme, .dark, .glass, tint: .bold, tintLength: 0.7)
            let drawn = surface.tintGradientStops
            let drawnLocations: [Double] = drawn.map { Double($0.location) }
            let modelledLocations: [Double] = surface.tintStops.map(\.location)
            XCTAssertEqual(drawnLocations, modelledLocations, theme.rawValue)
            XCTAssertFalse(drawn.isEmpty)
        }
        XCTAssertTrue(treatment(.original, .dark, .glass).tintGradientStops.isEmpty)
    }

    func testSurfaceFloorsArePinned() {
        typealias T = AtticPanelSurfaceTreatment
        XCTAssertEqual(T.readableContrastTarget, 4.75)
        XCTAssertEqual(T.readableContrastTarget(kind: .glass, creditsNativeSurface: true), 3.0)
        XCTAssertEqual(T.readableContrastTarget(kind: .frosted, creditsNativeSurface: true), 3.5)
        XCTAssertEqual(T.readableContrastTarget(kind: .solid, creditsNativeSurface: true), 4.75)
        for kind in Kind.allCases {
            XCTAssertEqual(T.readableContrastTarget(kind: kind, creditsNativeSurface: false), 4.75, kind.rawValue)
        }
        // Frosted is never the more transparent of the two.
        for theme in AtticPanelTheme.allCases {
            for appearance in AtticPanelThemeAppearance.allCases {
                XCTAssertLessThan(treatment(theme, appearance, .glass).foundationOpacity,
                                  treatment(theme, appearance, .frosted).foundationOpacity,
                                  "\(theme.rawValue) \(appearance.rawValue)")
            }
        }
    }
}
