import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The colour pass (owner, 2026-10-10; `phaseX/colour-final.md` with the
/// owner's three changes): tag hues, the ink done mark, the pie's cap, the
/// note marker and links, and the notice icons.
@MainActor
final class PhaseXColourTokenTests: XCTestCase {
    private static let modes: [AtticDesignContext.Mode] = [.light, .dark]

    /// Every palette, mode, surface and contrast setting.
    private static var matrix: [AtticDesignContext] {
        var contexts: [AtticDesignContext] = []
        for mode in modes {
            for palette in AtticPanelTheme.allCases {
                for surface in [PanelSurfaceStyle.solid, .glass, .frosted] {
                    for ic in [false, true] {
                        contexts.append(AtticDesignContext(mode: mode, palette: palette, surface: surface, increaseContrast: ic))
                    }
                }
            }
        }
        return contexts
    }

    /// The surfaces a tag sits on: Solid's base, or a translucent panel as
    /// drawn over a mid-grey desktop (the design system's own rule).
    private func surfaces(_ tokens: AtticColorTokens, _ context: AtticDesignContext) -> [AtticRGBA] {
        context.surface == .solid
            ? [tokens.panel.base]
            : [AtticSurfaceModel.contentTop, 1].map { tokens.panel.composite(.midGrey, at: $0) }
    }

    // MARK: Tags

    /// The sheet's values are starting points the build tunes only as far
    /// as a surface needs: on the default look each lands within a few
    /// steps of its sheet value, in the same hue.
    func testTagHuesStartFromTheSheetsValuesOnTheDefaultLook() {
        let expected: [(AtticDesignContext, [String])] = [
            (AtticDesignContext(mode: .light), ["#3975D7", "#5A62D6", "#8C55C8", "#C24C8C", "#218384", "#6E7F28", "#9A7023"]),
            (AtticDesignContext(mode: .dark), ["#7CA9F2", "#9EA3F5", "#C29AF0", "#F08FC4", "#5CC9C6", "#B4C766", "#E2B65A"]),
            (AtticDesignContext(mode: .light, increaseContrast: true), ["#2358AD", "#3D47CF", "#753AB5", "#98346A", "#196363", "#53601E", "#74551A"]),
            (AtticDesignContext(mode: .dark, increaseContrast: true), ["#C7DAF9", "#D5D8FB", "#E4D2F8", "#F8CCE4", "#ABE3E1", "#D3DEA5", "#EFD6A2"])
        ]
        for (context, hexes) in expected {
            let tokens = context.tokens
            for (hue, hex) in zip(AtticTagHue.automatic, hexes) {
                let sheet = AtticRGBA(UInt32(hex.dropFirst(), radix: 16)!)
                let built = tokens.tagInk(hue)
                print("ATTIC_TAG_HUE \(context.caption) \(hue) sheet \(hex) built \(built.hexString)")
                // Without Increase Contrast they are the sheet's (Dark blue
                // a step lighter for its filtering fill); Increase
                // Contrast's stronger hover and selection step them further.
                if !context.increaseContrast {
                    XCTAssertLessThanOrEqual(built.distance(to: sheet), 3, "\(context.caption) \(hue): \(built.hexString) vs \(hex)")
                }
                let delta = abs(built.hsl.hue - sheet.hsl.hue) * 360
                XCTAssertLessThan(min(delta, 360 - delta), 3, "\(context.caption) \(hue) keeps its hue")
            }
            // Grey is about the secondary grey on the default look (#7A7A7A / #A4A4A4).
            if !context.increaseContrast {
                let grey = AtticRGBA(context.mode == .dark ? 0xA4A4A4 : 0x7A7A7A)
                XCTAssertLessThanOrEqual(tokens.tagInk(.grey).distance(to: grey), 12, context.caption)
            }
        }
    }

    /// 3 : 1 (4.5 : 1 under Increase Contrast) on the surface, the tag's own
    /// fill at rest, hovered and selected, and that fill over a hovered or
    /// selected row: every hue, palette, mode and surface.
    func testEveryTagHueKeepsItsFloorEverywhere() {
        for context in Self.matrix {
            let tokens = context.tokens
            let floor = context.increaseContrast ? 4.5 : 3
            for hue in AtticTagHue.allCases {
                let ink = tokens.tagInk(hue)
                for surface in surfaces(tokens, context) {
                    let fill = tokens.tagFill(hue)
                    let backgrounds = [surface, fill.over(surface), tokens.tagFillSelected(hue).over(surface),
                                       tokens.hover.over(fill.over(surface)), fill.over(tokens.hover.over(surface)),
                                       fill.over(tokens.selected.over(surface))]
                    let worst = backgrounds.map { ink.contrast(on: $0) }.min() ?? 0
                    XCTAssertGreaterThanOrEqual(worst, floor, "\(context.caption) \(hue): \(worst)")
                }
            }
        }
    }

    /// A tag is learned by its colour: palettes re-tune each hue's
    /// lightness but never move it to another hue.
    func testPalettesKeepTheTagHues() {
        for mode in Self.modes {
            let original = AtticDesignContext(mode: mode).tokens
            for palette in AtticPanelTheme.allCases {
                let tokens = AtticDesignContext(mode: mode, palette: palette).tokens
                for hue in AtticTagHue.automatic {
                    let delta = abs(tokens.tagInk(hue).hsl.hue - original.tagInk(hue).hsl.hue) * 360
                    XCTAssertLessThan(min(delta, 360 - delta), 4, "\(mode) \(palette) \(hue)")
                }
            }
        }
        // The sheet's Sea Glass Light moves four hues by 1 % or less.
        let seaGlass = AtticDesignContext(mode: .light, palette: .seaGlass).tokens
        let original = AtticDesignContext(mode: .light).tokens
        for hue in AtticTagHue.automatic {
            XCTAssertLessThan(abs(seaGlass.tagInk(hue).hsl.lightness - original.tagInk(hue).hsl.lightness), 0.03, "\(hue)")
        }
    }

    func testTheHashIsExplicitFNV1aOfTheFoldedName() {
        // The sheet's examples: launch and pricing both hash to teal.
        XCTAssertEqual(AtticTagHue.hashed("launch"), .teal)
        XCTAssertEqual(AtticTagHue.hashed("pricing"), .teal)
        XCTAssertEqual(AtticTagHue.hashed("design"), .blue)
        // Folded: case, surrounding space and Unicode normalisation.
        XCTAssertEqual(AtticTagHue.hashed("  Launch "), AtticTagHue.hashed("launch"))
        XCTAssertEqual(AtticTagHue.hashed("cafe\u{301}"), AtticTagHue.hashed("caf\u{E9}"))
        // Never grey, and the same on every call (not `hashValue`).
        for index in 0..<200 {
            let name = "tag-\(index)"
            XCTAssertNotEqual(AtticTagHue.hashed(name), .grey)
            XCTAssertEqual(AtticTagHue.hashed(name), AtticTagHue.hashed(String(name)))
        }
    }

    func testANewTagTakesTheNextFreeHueOnACollision() {
        // The sheet: launch teal, design blue, pricing steps to olive.
        let palette = AtticTagPalette.resolve(inUse: ["launch", "design", "pricing"], stored: [:])
        XCTAssertEqual(palette.hues, ["launch": .teal, "design": .blue, "pricing": .olive])
        // Wrapping round: ochre's next free hue is blue.
        XCTAssertEqual(AtticTagHue.assigned(to: "x", avoiding: []), AtticTagHue.hashed("x"))
        let ochreName = (0..<500).map { "o\($0)" }.first { AtticTagHue.hashed($0) == .ochre }!
        XCTAssertEqual(AtticTagHue.assigned(to: ochreName, avoiding: [.ochre]), .blue)
        // All seven in use: the hash hue stays.
        XCTAssertEqual(AtticTagHue.assigned(to: "pricing", avoiding: Set(AtticTagHue.automatic)), .teal)
        // A stored hue is never taken from its tag, even by an older tag.
        let stored = AtticTagPalette.resolve(inUse: ["launch", "pricing"], stored: ["pricing": .teal])
        XCTAssertEqual(stored.hues, ["pricing": .teal, "launch": .olive])
        // An unknown tag shows the colour it is about to be given.
        XCTAssertEqual(palette.hue(for: "health"), AtticTagHue.assigned(to: "health", avoiding: Set(palette.hues.values)))
    }

    // MARK: Done

    /// Done is the title's ink with the inverse tick, on every look; the
    /// tick keeps 3 : 1 on it (4.5 : 1 under Increase Contrast), and the
    /// mark keeps 3 : 1 on a selected row.
    func testDoneMarkIsTheTitleInkWithAReadableTick() {
        for context in Self.matrix {
            let tokens = context.tokens
            XCTAssertEqual(tokens.ink(.doneFill), tokens.ink(AtticStatusCircle.ringInk), context.caption)
            let tick = tokens.ink(.onDone).contrast(on: tokens.ink(.doneFill))
            XCTAssertGreaterThanOrEqual(tick, context.increaseContrast ? 4.5 : 3, "\(context.caption) tick \(tick)")
            XCTAssertGreaterThanOrEqual(tokens.ink(.onDone).contrast(on: tokens.ink(.disabledIcon)), 3, context.caption)
            if context.surface == .solid {
                let base = tokens.panel.base
                for row in [base, tokens.hover.over(base), tokens.selected.over(base)] {
                    XCTAssertGreaterThanOrEqual(tokens.ink(.doneFill).contrast(on: row), 3, context.caption)
                }
            }
        }
        // Dark inverts: a light mark with a dark tick.
        let dark = AtticDesignContext(mode: .dark).tokens
        XCTAssertGreaterThan(dark.ink(.doneFill).relativeLuminance, dark.ink(.onDone).relativeLuminance)
        let light = AtticDesignContext(mode: .light).tokens
        XCTAssertLessThan(light.ink(.doneFill).relativeLuminance, light.ink(.onDone).relativeLuminance)
    }

    /// The pixels: a done task's disc and a done subtask's box are filled
    /// in the done ink, in Light and Dark.
    func testDoneMarksRenderInTheDoneInk() throws {
        for mode in Self.modes {
            let context = AtticDesignContext(mode: mode)
            let tokens = context.tokens
            for view in [AnyView(AtticStatusCircle(state: .done)), AnyView(AtticSubtaskCheckbox(isDone: true))] {
                let bitmap = try render(view, context: context)
                // Inside the fill, clear of the tick (its top edge), against
                // the done ink drawn through the same renderer.
                let reference = try render(AnyView(Rectangle().fill(tokens.color(.doneFill))), context: context)
                let sample = try pixel(bitmap, x: 8, y: 3)
                let expected = try pixel(reference, x: 8, y: 3)
                XCTAssertLessThanOrEqual(sample.distance(to: expected), 3, "\(mode): \(sample.hexString) vs \(expected.hexString)")
            }
        }
    }

    // MARK: Pie

    func testThePieIsCappedSoAFullShareNeverReadsAsDone() throws {
        XCTAssertNil(AtticStatusCircle.pieShare((done: 0, total: 3)))
        XCTAssertEqual(try XCTUnwrap(AtticStatusCircle.pieShare((done: 1, total: 3))), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(AtticStatusCircle.pieShare((done: 4, total: 4)), 0.92)
        XCTAssertEqual(AtticStatusCircle.pieShare((done: 9, total: 4)), 0.92)
        XCTAssertEqual(AtticStatusCircle.pieShare((done: 23, total: 25)), 0.92)
        // Rendered: 4 of 4 leaves the open sliver at 11 o'clock that the
        // done disc fills.
        let context = AtticDesignContext(mode: .light)
        let base = context.tokens.panel.base
        let full = try render(AnyView(AtticStatusCircle(state: .inProgress, subtasks: (done: 4, total: 4))), context: context)
        let done = try render(AnyView(AtticStatusCircle(state: .done)), context: context)
        let angle = 345.0 * .pi / 180, radius = 3.2
        let x = 8 + radius * sin(angle), y = 8 - radius * cos(angle)
        XCTAssertLessThanOrEqual(try pixel(full, x: x, y: y).distance(to: base), 3, "the sliver is open")
        XCTAssertGreaterThan(try pixel(done, x: x, y: y).distance(to: base), 100, "done fills it")
        XCTAssertGreaterThan(try pixel(full, x: 8, y: 8 + radius).distance(to: base), 100, "the pie is drawn")
    }

    // MARK: Notes

    /// F-01 (owner 2026-10-10): the highlight is a plain grey wash again, in
    /// every mode, palette and surface, and never reads as inline code.
    func testHighlightIsAGreyWashThatKeepsBodyTextReadableAndDiffersFromCode() {
        for context in Self.matrix {
            let tokens = context.tokens
            XCTAssertLessThan(tokens.highlightMarker.hsl.saturation, 0.02, "\(context.caption) is neutral grey")
            XCTAssertEqual(tokens.highlightMarker.alpha, context.mode == .dark ? 0.22 : 0.16, accuracy: 0.001)
            for base in surfaces(tokens, context) {
                let marked = tokens.highlightMarker.over(base)
                XCTAssertGreaterThanOrEqual(tokens.ink(.heading).contrast(on: marked), 4.5, context.caption)
                // Decoration, not a signal: a quiet wash against the surface.
                XCTAssertLessThan(marked.contrast(on: base), 2.1, context.caption)
                XCTAssertGreaterThan(marked.contrast(on: base), 1.1, "\(context.caption) is visible")
                // Clearly stronger than inline code's chip on the same surface.
                let code = tokens.tagFill.over(base)
                XCTAssertGreaterThan(marked.distance(to: base), code.distance(to: base) * 1.3,
                                     "\(context.caption) highlight is a stronger wash than the code chip")
            }
        }
        XCTAssertEqual(AtticDesignContext(mode: .light).tokens.highlightMarker.over(.white(1)).hexString, "#D6D6D6")
        // Code keeps its monospaced font and its own fill; a highlight is
        // proportional text on the grey wash.
        let style = NoteTextStyle(design: AtticDesignContext(mode: .light))
        let code = style.markedAttributes(marks: [.code: true], baseFont: .systemFont(ofSize: 15))
        let marked = style.markedAttributes(marks: [.highlight: true], baseFont: .systemFont(ofSize: 15))
        XCTAssertEqual(code[.backgroundColor] as? NSColor, style.codeColor)
        XCTAssertEqual(marked[.backgroundColor] as? NSColor, style.highlightColor)
        XCTAssertNotEqual(style.codeColor, style.highlightColor)
        XCTAssertTrue((code[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        XCTAssertFalse((marked[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    func testLinksAreBlueAtTheTextFloorWithTheirUnderline() {
        for context in Self.matrix where context.surface == .solid {
            let tokens = context.tokens
            let base = tokens.panel.base
            for row in [base, tokens.hover.over(base), tokens.selected.over(base)] {
                XCTAssertGreaterThanOrEqual(tokens.ink(.linkText).contrast(on: row), 4.5, context.caption)
            }
            let hue = tokens.ink(.linkText).hsl.hue * 360
            XCTAssertTrue((200...235).contains(hue), "\(context.caption) link hue \(hue)")
            XCTAssertEqual(tokens.linkUnderline.alpha, 0.55, accuracy: 0.001)
        }
        // The sheet's blues already pass on the default look.
        XCTAssertEqual(AtticDesignContext(mode: .light).tokens.ink(.linkText).hexString, "#2760BF")
        XCTAssertEqual(AtticDesignContext(mode: .dark).tokens.ink(.linkText).hexString, "#93B6F7")
        // The note's text style applies them.
        let style = NoteTextStyle(design: AtticDesignContext(mode: .light))
        let attributes = style.markedAttributes(marks: [.link: "https://example.com"], baseFont: .systemFont(ofSize: 15))
        XCTAssertEqual((attributes[.foregroundColor] as? NSColor), style.linkColor)
        XCTAssertEqual((attributes[.underlineColor] as? NSColor), style.linkUnderlineColor)
        XCTAssertNotNil(attributes[.underlineStyle])
        let marked = style.markedAttributes(marks: [.highlight: true], baseFont: .systemFont(ofSize: 15))
        XCTAssertEqual((marked[.backgroundColor] as? NSColor), style.highlightColor)
    }

    // MARK: Notices

    func testNoticeIconRolesAndTheirContrast() {
        XCTAssertEqual(AtticStatusItem.Tone.error.iconInk, .noticeError)
        XCTAssertEqual(AtticStatusItem.Tone.caution.iconInk, .noticeCaution)
        XCTAssertEqual(AtticStatusItem.Tone.normal.iconInk, .icon)
        XCTAssertEqual(AtticStatusItem.Tone.quiet.iconInk, .icon)
        // The sheet's amber, tuned at most a step on the Craft-style face.
        XCTAssertLessThanOrEqual(AtticDesignContext(mode: .light).tokens.ink(.noticeCaution).distance(to: AtticRGBA(0xB37B09)), 3)
        XCTAssertEqual(AtticDesignContext(mode: .dark).tokens.ink(.noticeCaution).hexString, "#F0AD2E")
        // The error icon is the overdue red.
        for mode in Self.modes {
            let tokens = AtticDesignContext(mode: mode).tokens
            XCTAssertLessThanOrEqual(tokens.ink(.noticeError).distance(to: tokens.ink(.dueText)), 1)
        }
        for context in Self.matrix where context.surface == .solid {
            let tokens = context.tokens
            let faces = [tokens.controlFace, tokens.glassFace.over(tokens.panel.base), tokens.popoverFill]
            for ink in [AtticInk.noticeCaution, .noticeError] {
                let worst = faces.map { tokens.ink(ink).contrast(on: $0) }.min() ?? 0
                XCTAssertGreaterThanOrEqual(worst, 3, "\(context.caption) \(ink) \(worst)")
            }
        }
        // Read failures are cautions; other notices stay grey.
        XCTAssertTrue(NoteStatusPresentation.isCaution(notice: "An attachment couldn’t be read. Nothing was pasted."))
        XCTAssertTrue(NoteStatusPresentation.isCaution(notice: "Copied. 2 image(s) couldn’t be read and are listed in its README."))
        XCTAssertFalse(NoteStatusPresentation.isCaution(notice: "Recovery copy saved as “Note.md”."))
    }

    // MARK: Helpers

    private func render(_ view: AnyView, context: AtticDesignContext) throws -> NSBitmapImageRep {
        let content = view
            .frame(width: 16, height: 16)
            .background(context.tokens.panel.base.color)
            .atticDesign(context)
            .environment(\.colorScheme, context.mode == .dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        return NSBitmapImageRep(cgImage: image)
    }

    private func pixel(_ bitmap: NSBitmapImageRep, x: Double, y: Double) throws -> AtticRGBA {
        let colour = try XCTUnwrap(bitmap.colorAt(x: Int((x * 2).rounded(.down)), y: Int((y * 2).rounded(.down)))?.usingColorSpace(.sRGB))
        return AtticRGBA(red: colour.redComponent, green: colour.greenComponent, blue: colour.blueComponent)
    }
}

private extension AtticRGBA {
    /// The largest channel difference, in 8-bit steps.
    func distance(to other: AtticRGBA) -> Double {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue)) * 255
    }
}
