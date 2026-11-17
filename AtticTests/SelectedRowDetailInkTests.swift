import XCTest
@testable import Attic

/// 1A (owner, 17 Nov, "Faint spots on Solid"): on a selected or pressed task
/// row, the details' greys (the count and its subtask box in the meta grey,
/// the date in the date grey) keep the secondary floor (3 : 1, or 4.5 : 1
/// under Increase Contrast) on both the selected and the pressed fill. Plain
/// rows keep their greys, and see-through Glass and Frosted do not change.
@MainActor
final class SelectedRowDetailInkTests: XCTestCase {
    private static let tones: [AtticPanelTone] = [.meta, .date]

    private func design(_ palette: AtticPanelTheme, _ mode: AtticDesignContext.Mode, surface: PanelSurfaceStyle,
                        increaseContrast: Bool, reduced: Bool = false) -> AtticDesignContext {
        AtticDesignContext(mode: mode, palette: palette, surface: surface,
                           increaseContrast: increaseContrast, reduceTransparency: reduced)
    }

    /// As drawn: 8-bit channels.
    private func byte(_ c: AtticRGBA) -> AtticRGBA {
        func q(_ v: Double) -> Double { (min(1, max(0, v)) * 255).rounded() / 255 }
        return AtticRGBA(red: q(c.red), green: q(c.green), blue: q(c.blue), alpha: c.alpha)
    }

    private func hex(_ c: AtticRGBA) -> String {
        let b = byte(c)
        return String(format: "#%02X%02X%02X", Int((b.red * 255).rounded()), Int((b.green * 255).rounded()), Int((b.blue * 255).rounded()))
    }

    /// Every Solid palette, Light and Dark, with and without Increase
    /// Contrast (and Glass and Frosted made solid by Reduce Transparency,
    /// which draw the same way): the selected-row greys reach the floor on
    /// the selected and the pressed fill, as drawn.
    func testSelectedRowDetailsReachTheFloorOnSelectedAndPressedFills() {
        var checked = 0
        for palette in AtticPanelTheme.allCases {
            for mode in [AtticDesignContext.Mode.light, .dark] {
                for ic in [false, true] {
                    let designs = [design(palette, mode, surface: .solid, increaseContrast: ic)]
                        + [PanelSurfaceStyle.glass, .frosted].map { design(palette, mode, surface: $0, increaseContrast: ic, reduced: true) }
                    for design in designs {
                        let tokens = design.tokens
                        XCTAssertFalse(AtticSurfaceInk.seeThrough(tokens))
                        let floor = tokens.panel.floor(for: .helper)
                        for tone in Self.tones {
                            let ink = byte(AtticSurfaceInk.toneInk(tone, tokens: tokens, onSelectedRow: true))
                            for (name, fill) in [("selected", tokens.selected), ("pressed", tokens.pressed)] {
                                let backgrounds = tokens.panel.backgrounds(for: .init(ink: .helper, foreground: ink, overlays: [fill]))
                                for background in backgrounds.map(byte) {
                                    let contrast = ink.contrast(on: background)
                                    XCTAssertGreaterThanOrEqual(
                                        contrast, floor,
                                        "\(palette) \(mode.title) IC \(ic) \(tokens.context.surface) reduced \(tokens.context.reducedFrom != nil) \(tone) on \(name) \(hex(background)): \(hex(ink)) \(String(format: "%.2f", contrast))")
                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// Plain rows keep the base greys, pinned for Original as drawn at
    /// `ea9d45ac` (Solid, Light/Dark, Increase Contrast).
    func testPlainRowGreysAreUnchanged() {
        let expected: [(AtticDesignContext.Mode, Bool, AtticPanelTone, String)] = [
            (.light, false, .meta, "#848689"), (.light, false, .date, "#737579"),
            (.dark, false, .meta, "#7B7D80"), (.dark, false, .date, "#8B8D91"),
            (.light, true, .meta, "#727477"), (.light, true, .date, "#6A6C70"),
            (.dark, true, .meta, "#96989A"), (.dark, true, .date, "#97989C"),
        ]
        for (mode, ic, tone, value) in expected {
            let tokens = design(.original, mode, surface: .solid, increaseContrast: ic).tokens
            XCTAssertEqual(hex(AtticSurfaceInk.toneInk(tone, tokens: tokens)), value, "\(mode.title) IC \(ic) \(tone)")
            XCTAssertEqual(AtticSurfaceInk.toneInk(tone, tokens: tokens), AtticSurfaceInk.tone(tone, tokens: tokens))
        }
    }

    /// See-through Glass and Frosted already read well on these fills: the
    /// selected-row greys are exactly the plain ones, for every palette.
    func testSeeThroughSurfacesDoNotChange() {
        for palette in AtticPanelTheme.allCases {
            for mode in [AtticDesignContext.Mode.light, .dark] {
                for ic in [false, true] {
                    for surface in [PanelSurfaceStyle.glass, .frosted] {
                        let tokens = design(palette, mode, surface: surface, increaseContrast: ic).tokens
                        XCTAssertTrue(AtticSurfaceInk.seeThrough(tokens))
                        for tone in Self.tones {
                            XCTAssertEqual(AtticSurfaceInk.toneInk(tone, tokens: tokens, onSelectedRow: true),
                                           AtticSurfaceInk.toneInk(tone, tokens: tokens),
                                           "\(palette) \(mode.title) IC \(ic) \(surface) \(tone)")
                        }
                    }
                }
            }
        }
    }

    /// Original's selected-row greys, for the report (always passes).
    func testReportOriginalSelectedRowGreys() {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            for ic in [false, true] {
                let tokens = design(.original, mode, surface: .solid, increaseContrast: ic).tokens
                let line = Self.tones.map { tone in
                    "\(tone) \(hex(AtticSurfaceInk.toneInk(tone, tokens: tokens))) -> \(hex(AtticSurfaceInk.toneInk(tone, tokens: tokens, onSelectedRow: true)))"
                }.joined(separator: ", ")
                print("1A Original \(mode.title) IC \(ic): selected \(hex(tokens.selected.over(tokens.panel.composite(.midGrey, at: AtticSurfaceModel.contentTop)))) pressed \(hex(tokens.pressed.over(tokens.panel.composite(.midGrey, at: AtticSurfaceModel.contentTop)))): \(line)")
            }
        }
    }
}
