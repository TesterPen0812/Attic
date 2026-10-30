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

    /// The tags use the highlighter's clear hues (N-2, owner 2026-10-11):
    /// each starts from that hue as text and is tuned only in lightness, so
    /// it keeps its hue on every look.
    func testTagHuesAreTheClearSetOnTheDefaultLook() {
        let contexts = [AtticDesignContext(mode: .light), AtticDesignContext(mode: .dark),
                        AtticDesignContext(mode: .light, increaseContrast: true),
                        AtticDesignContext(mode: .dark, increaseContrast: true)]
        // Yellow, green, blue, pink and purple, as the highlighter's set.
        let hues: [Double] = [45, 135, 215, 330, 268]
        for context in contexts {
            let tokens = context.tokens
            for (hue, expected) in zip(AtticTagHue.palette, hues) {
                let built = tokens.tagInk(hue)
                print("ATTIC_TAG_HUE \(context.caption) \(hue) built \(built.hexString)")
                let delta = abs(built.hsl.hue * 360 - expected)
                XCTAssertLessThan(min(delta, 360 - delta), 14, "\(context.caption) \(hue): \(built.hexString)")
            }
            // Grey is about the secondary grey on the default look (#737373 / #A4A4A4, T-16 B).
            if !context.increaseContrast {
                let grey = AtticRGBA(context.mode == .dark ? 0xA4A4A4 : 0x737373)
                XCTAssertLessThanOrEqual(tokens.tagInk(.grey).distance(to: grey), 12, context.caption)
            }
        }
    }

    /// The colour pass's stored keys still work: each shows as its nearest
    /// clear hue, nothing stored is rewritten, and the menu offers only the
    /// clear set and Grey.
    func testLegacyTagKeysShowAsTheirClearHue() {
        XCTAssertEqual(AtticTagHue(rawValue: "indigo")?.canonical, .blue)
        XCTAssertEqual(AtticTagHue(rawValue: "violet")?.canonical, .purple)
        XCTAssertEqual(AtticTagHue(rawValue: "teal")?.canonical, .green)
        XCTAssertEqual(AtticTagHue(rawValue: "olive")?.canonical, .green)
        XCTAssertEqual(AtticTagHue(rawValue: "ochre")?.canonical, .yellow)
        for raw in ["blue", "pink", "grey"] { XCTAssertEqual(AtticTagHue(rawValue: raw)?.canonical.rawValue, raw) }
        let tokens = AtticDesignContext(mode: .light).tokens
        XCTAssertEqual(tokens.tagInk(.teal), tokens.tagInk(.green))
        XCTAssertEqual(tokens.tagInk(.indigo), tokens.tagInk(.blue))
        XCTAssertEqual(AtticTagHue.violet.title, AtticTagHue.purple.title)
        var colouring = AtticTagColouring(palette: AtticTagPalette(hues: ["launch": .teal]))
        colouring.setHue = { _, _ in }
        // Dropdown content: answers (owner, 2026-10-24), sheet 2: the chip's
        // menu is a "Colour" header and the colours, not a one-row Colour ›.
        XCTAssertEqual(colouring.colourCommands(for: "launch").map(\.title),
                       ["Colour", "Yellow", "Green", "Blue", "Pink", "Purple", "Grey"])
        XCTAssertEqual(colouring.colourCommands(for: "launch").first?.isHeader, true)
        XCTAssertEqual(colouring.colourCommands(for: "launch").first { $0.state == .on }?.title, "Green")
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

    /// Full CI found teal below its floor on the drawn Solid tint, which
    /// differs from the panel's untinted foundation colour.
    func testTagFloorsIncludeTheDrawnSolidTint() {
        for mode in Self.modes {
            for palette in AtticPanelTheme.allCases {
                for tint in PanelTintLevel.allCases {
                    for ic in [false, true] {
                        let context = AtticDesignContext(mode: mode, palette: palette, surface: .solid,
                                                         tint: tint, increaseContrast: ic)
                        let tokens = context.tokens
                        for height in [AtticSurfaceModel.contentTop, 1] {
                            let surface = tokens.panel.composite(.midGrey, at: height)
                            for hue in AtticTagHue.allCases {
                                let fill = tokens.tagFill(hue)
                                let backgrounds = [surface, fill.over(surface), tokens.tagFillSelected(hue).over(surface),
                                                   tokens.hover.over(fill.over(surface)), fill.over(tokens.hover.over(surface)),
                                                   fill.over(tokens.selected.over(surface))]
                                let worst = backgrounds.map { tokens.tagInk(hue).contrast(on: $0) }.min() ?? 0
                                XCTAssertGreaterThanOrEqual(worst, ic ? 4.5 : 3,
                                                            "\(context.caption) \(hue) height=\(height): \(worst)")
                            }
                        }
                    }
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
                for hue in AtticTagHue.palette {
                    let delta = abs(tokens.tagInk(hue).hsl.hue - original.tagInk(hue).hsl.hue) * 360
                    XCTAssertLessThan(min(delta, 360 - delta), 4, "\(mode) \(palette) \(hue)")
                }
            }
        }
        // Sea Glass Light moves the hues' lightness by 3 % or less.
        let seaGlass = AtticDesignContext(mode: .light, palette: .seaGlass).tokens
        let original = AtticDesignContext(mode: .light).tokens
        for hue in AtticTagHue.palette {
            XCTAssertLessThan(abs(seaGlass.tagInk(hue).hsl.lightness - original.tagInk(hue).hsl.lightness), 0.03, "\(hue)")
        }
    }

    func testTheHashIsExplicitFNV1aOfTheFoldedName() {
        // The colour pass's examples, unchanged in family: launch and
        // pricing hashed to teal, which shows as green; design to blue.
        XCTAssertEqual(AtticTagHue.hashed("launch"), .green)
        XCTAssertEqual(AtticTagHue.hashed("pricing"), .green)
        XCTAssertEqual(AtticTagHue.hashed("design"), .blue)
        // Folded: case, surrounding space and Unicode normalisation.
        XCTAssertEqual(AtticTagHue.hashed("  Launch "), AtticTagHue.hashed("launch"))
        XCTAssertEqual(AtticTagHue.hashed("cafe\u{301}"), AtticTagHue.hashed("caf\u{E9}"))
        // Never grey, and the same on every call (not `hashValue`).
        for index in 0..<200 {
            let name = "tag-\(index)"
            XCTAssertNotEqual(AtticTagHue.hashed(name), .grey)
            XCTAssertTrue(AtticTagHue.palette.contains(AtticTagHue.hashed(name)), name)
            XCTAssertEqual(AtticTagHue.hashed(name), AtticTagHue.hashed(String(name)))
        }
    }

    func testANewTagTakesTheNextFreeHueOnACollision() {
        // launch green, design blue, pricing (green) steps past blue to pink.
        let palette = AtticTagPalette.resolve(inUse: ["launch", "design", "pricing"], stored: [:])
        XCTAssertEqual(palette.hues, ["launch": .green, "design": .blue, "pricing": .pink])
        // Wrapping round: purple's next free hue is yellow.
        XCTAssertEqual(AtticTagHue.assigned(to: "x", avoiding: []), AtticTagHue.hashed("x"))
        let purpleName = (0..<500).map { "o\($0)" }.first { AtticTagHue.hashed($0) == .purple }!
        XCTAssertEqual(AtticTagHue.assigned(to: purpleName, avoiding: [.purple]), .yellow)
        // A legacy key in use counts as the hue it shows.
        XCTAssertEqual(AtticTagHue.assigned(to: purpleName, avoiding: [.violet]), .yellow)
        // All five in use: the hash hue stays.
        XCTAssertEqual(AtticTagHue.assigned(to: "pricing", avoiding: Set(AtticTagHue.palette)), .green)
        // A stored hue is never taken from its tag, even by an older tag.
        let stored = AtticTagPalette.resolve(inUse: ["launch", "pricing"], stored: ["pricing": .teal])
        XCTAssertEqual(stored.hues, ["pricing": .teal, "launch": .blue])
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

    // MARK: Segmented ring

    /// The owner's changelog (27 Oct, option 1c), rendered: 1 of 3 inks the
    /// first segment from 12 o'clock, the rest stays the light track, the
    /// gaps stay open; above eight it is one arc. No pie, no centre dot.
    func testTheRingSplitsPerSubtaskAndInksFinishedSegmentsClockwise() throws {
        let context = AtticDesignContext(mode: .light)
        let base = context.tokens.panel.base
        let radius = 6.4
        func at(_ degrees: Double) -> (Double, Double) {
            let a = degrees * .pi / 180
            return (8 + radius * sin(a), 8 - radius * cos(a))
        }
        for state in [AtticTaskState.todo, .inProgress] {
            let ring = try render(AnyView(AtticStatusCircle(state: state, subtasks: (done: 1, total: 3))), context: context)
            let (gx, gy) = at(0), (ix, iy) = at(60), (tx, ty) = at(180)
            XCTAssertLessThanOrEqual(try pixel(ring, x: gx, y: gy).distance(to: base), 3, "the gap at 12 o'clock is open · \(state)")
            XCTAssertGreaterThan(try pixel(ring, x: ix, y: iy).distance(to: base), 100, "the finished segment is ink · \(state)")
            let track = try pixel(ring, x: tx, y: ty).distance(to: base)
            XCTAssertGreaterThan(track, 8, "the open segments are drawn · \(state)")
            XCTAssertLessThan(track, 80, "the open segments are a light grey · \(state)")
            XCTAssertLessThanOrEqual(try pixel(ring, x: 8, y: 8).distance(to: base), 3, "no centre dot or pie · \(state)")
        }
        let nine = try render(AnyView(AtticStatusCircle(state: .todo, subtasks: (done: 3, total: 9))), context: context)
        let (ax, ay) = at(60), (bx, by) = at(200)
        XCTAssertGreaterThan(try pixel(nine, x: ax, y: ay).distance(to: base), 100, "3 of 9: the arc's first third is ink")
        XCTAssertLessThan(try pixel(nine, x: bx, y: by).distance(to: base), 80)
        let dotless = try render(AnyView(AtticStatusCircle(state: .inProgress)), context: context)
        XCTAssertLessThanOrEqual(try pixel(dotless, x: 8, y: 8).distance(to: base), 3, "in progress has no centre dot")
    }

    /// Hovering the ring previews the click: a grey check inside it.
    func testHoverPreviewsTheCheckInsideTheRing() throws {
        let context = AtticDesignContext(mode: .light)
        let base = context.tokens.panel.base
        let point = (x: 7.2, y: 10.2)
        let rest = try render(AnyView(AtticStatusCircle(state: .todo)), context: context)
        XCTAssertLessThanOrEqual(try pixel(rest, x: point.x, y: point.y).distance(to: base), 3, "no check at rest")
        for subtasks in [nil, (done: 1, total: 4)] as [(done: Int, total: Int)?] {
            let hover = try render(AnyView(AtticStatusCircle(state: .todo, subtasks: subtasks, showsCheckPreview: true)), context: context)
            let mark = try pixel(hover, x: point.x, y: point.y).distance(to: base)
            XCTAssertGreaterThan(mark, 30, "a check previews the click")
            XCTAssertLessThan(mark, 200, "in grey, not the done disc's ink")
        }
    }

    // MARK: Notes

    /// Owner 2026-10-16: plain highlights are yellow. Explicit grey keeps
    /// its wash; both keep readable text and differ from inline code.
    func testYellowAndExplicitGreyHighlightsKeepBodyTextReadableAndDifferFromCode() {
        for context in Self.matrix {
            let tokens = context.tokens
            XCTAssertLessThan(tokens.highlightMarker(.grey).hsl.saturation, 0.02, "\(context.caption) is neutral grey")
            XCTAssertEqual(tokens.highlightMarker(.grey).alpha, context.mode == .dark ? 0.22 : 0.16, accuracy: 0.001)
            XCTAssertEqual(tokens.highlightMarker, tokens.highlightMarker(.yellow))
            for colour in [NoteHighlightColour.yellow, .grey] {
                for base in surfaces(tokens, context) {
                    let marked = tokens.highlightMarker(colour).over(base)
                    XCTAssertGreaterThanOrEqual(tokens.ink(.heading).contrast(on: marked), 4.5, context.caption)
                    // The neutral wash keeps its existing upper bound. The owner
                    // chose the existing yellow, which is stronger in Dark.
                    if colour == .grey { XCTAssertLessThan(marked.contrast(on: base), 2.1, context.caption) }
                    XCTAssertGreaterThan(marked.contrast(on: base), 1.1, "\(context.caption) is visible")
                    // Clearly stronger than inline code's chip on the same surface.
                    let code = tokens.tagFill.over(base)
                    XCTAssertGreaterThan(marked.distance(to: base), code.distance(to: base) * 1.3,
                                         "\(context.caption) highlight is a stronger wash than the code chip")
                }
            }
        }
        XCTAssertEqual(AtticDesignContext(mode: .light).tokens.highlightMarker.over(.white(1)).hexString, "#F2DB8C")
        XCTAssertEqual(AtticDesignContext(mode: .light).tokens.highlightMarker(.grey).over(.white(1)).hexString, "#D6D6D6")
        // Code keeps its monospaced font and its own fill; a highlight is
        // proportional text on the yellow wash.
        let style = NoteTextStyle(design: AtticDesignContext(mode: .light))
        let code = style.markedAttributes(marks: [.code: true], baseFont: .systemFont(ofSize: 15))
        let marked = style.markedAttributes(marks: [.highlight: true], baseFont: .systemFont(ofSize: 15))
        // R14: code's fill is its drawn chip (`chipFill`), never a flat run.
        XCTAssertNil(code[.backgroundColor])
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
        XCTAssertTrue(NoteNotice(kind: .notReadable, detail: "An attachment couldn’t be read. Nothing was pasted.").severity == .caution)
        XCTAssertTrue(NoteNotice(kind: .copySaved, severity: .caution, detail: "Copied. 2 image(s) couldn’t be read and are listed in its README.").severity == .caution)
        XCTAssertFalse(NoteNotice(kind: .copySaved, detail: "Recovery copy saved as “Note.md”.").severity == .caution)
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
