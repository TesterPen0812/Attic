import SwiftUI
import XCTest
@testable import Attic

/// The design system's tokens and the automated appearance check.
@MainActor
final class AtticDesignSystemTests: XCTestCase {
    func testA38PageSwitchKeepsContrastWithReducedTransparency() {
        let contexts = [AtticPanelTheme.electricBlue, .seaGlass].flatMap { palette in
            PanelTintLevel.allCases.map { tint in
                AtticDesignContext(mode: .light, palette: palette, surface: .solid, tint: tint, reduceTransparency: true)
            }
        }
        let report = AtticAppearanceCheck.run(families: [.pageSwitch], contexts: contexts, scale: 2)
        if let context = contexts.first {
            let capture = AtticGalleryStage(family: .pageSwitch, demo: AtticGalleryDemo())
                .atticDesign(context)
                .environment(\.atticCapture, AtticCaptureContext(collector: nil, backdrop: .desktop(.midGrey)))
                .coordinateSpace(.named(AtticCaptureContext.coordinateSpace))
            let renderer = ImageRenderer(content: capture)
            renderer.scale = 2
            if let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "A38-page-switch-reduce-transparency"
                attachment.lifetime = .keepAlways
                add(attachment)
                if ProcessInfo.processInfo.environment["ATTIC_A38_PAGE_OUTPUT"] != nil {
                    let folder = ownedTemporaryDirectory(prefix: "A38PageContrast")
                    try? png.write(to: folder.appendingPathComponent("page-switch.png"))
                    print("A38_PAGE_SWITCH_ARTIFACTS=\(folder.path)")
                }
            }
        }
        let remaining = OpenRingException.remaining(Phase0AccentException.remaining(Phase0TranslucentException.remaining(report.failures)))
        XCTAssertTrue(remaining.isEmpty, remaining.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
    }

    // MARK: Tokens

    func testSpacingSitsOnTheFourPointGrid() {
        for value in AtticSpacing.scale {
            XCTAssertEqual(value.truncatingRemainder(dividingBy: 4), 0, "\(value) is off the 4 pt grid")
        }
        // The fine steps and Settings gaps the spec measures, and nothing else.
        let documentedExceptions: Set<CGFloat> = [AtticSpacing.inset14, AtticSpacing.gap10, AtticSpacing.settingsBelowHeader, AtticSpacing.settingsBetweenSections]
        XCTAssertEqual(documentedExceptions, [14, 10, 52, 34])
    }

    /// Owner's decision (2026-09-25): the rounder continuous corner, about
    /// 42 % of the height.
    func testControlCornersFollowFortyTwoPercentOfHeight() {
        XCTAssertEqual(AtticRadius.control(height: 32), 13.5)
        XCTAssertEqual(AtticRadius.control(height: 34), 14.5)
        XCTAssertEqual(AtticRadius.control(height: 36), 15)
        XCTAssertEqual(AtticRadius.control(height: 28), 12)
        XCTAssertEqual(AtticRadius.control(height: 18), 7.5)
        XCTAssertEqual(AtticRadius.nestedChip, 9.5, "Nested chips: outer radius minus the inset (13.5 − 4, visual A)")
        XCTAssertEqual(AtticRadius.nested(outer: 13.5, gap: 4), 9.5)
        XCTAssertNil(AtticRadius.nested(outer: 20, gap: 12), "Nesting only applies to gaps of 6 pt or less")
        XCTAssertEqual(AtticRadius.ring(around: 10, offset: 4), 14)
        XCTAssertEqual([AtticRadius.menu, AtticRadius.groupCard, AtticRadius.contentCard, AtticRadius.image, AtticRadius.highlight], [20, 17, 10, 8, 10])
    }

    /// Phase 0's qualities in Direction A (2026-09-26): the pin and the
    /// page button are equal 36 pt squares (radius 15; the page button opens
    /// to 96); Settings' back button keeps 38 × 34. Rows are 44 / 56 with
    /// highlights 2 shorter, text blocks centred; circles 16 at 28, titles
    /// at 56 (12 apart).
    func testControlSizesFollowPhase0Room() {
        // Chrome B (Notes v2, owner 2026-10-08): 32 pt, radius 13.5.
        XCTAssertEqual(AtticControlSize.panelButton, CGSize(width: 32, height: 32))
        XCTAssertEqual(AtticRadius.control(height: AtticControlSize.headerControl), 13.5)
        XCTAssertEqual(AtticControlSize.settingsBackButton, CGSize(width: 38, height: 34))
        XCTAssertEqual(AtticPageButton<Int>.width(open: false, count: 3), 32)
        XCTAssertEqual(AtticPageButton<Int>.width(open: true, count: 3), 84)
        // Compact round (owner): rows 36 / 50, highlights 30 / 44.
        XCTAssertEqual([AtticLayout.rowPitch, AtticLayout.rowHighlightHeight, AtticLayout.detailRowPitch, AtticLayout.detailRowHighlightHeight], [34, 30, 48, 44])
        XCTAssertEqual(AtticTaskRowMetrics.pitchTopInset, 2)
        XCTAssertEqual(AtticControlSize.statusCircle, 16)
        XCTAssertEqual(AtticLayout.textX - AtticLayout.circleX - AtticControlSize.statusCircle, 12)
        let m = AtticTaskRowMetrics.self
        XCTAssertEqual(m.titleTop(twoLine: false), 8, "18 pt title centred in 34")
        XCTAssertEqual(m.titleTop(twoLine: true), 6, "18 + 2 + 16 centred in 48")
        XCTAssertEqual(m.circleCentreY(twoLine: false), 17)
        XCTAssertEqual(m.circleCentreY(twoLine: true), 15)
    }

    /// Round 9 (owner item 26): springy by default, pages firm (never a
    /// visible overshoot), crossfades and hover never bounce; every preset
    /// keeps its Reduce Motion fallback.
    func testMotionPresetsAreLivelySpringsWithReduceMotionFallbacks() {
        for preset in AtticMotionPreset.allCases {
            XCTAssertLessThanOrEqual(preset.duration, 0.35, "\(preset) drags")
            XCTAssertLessThanOrEqual(preset.bounce, 0.3, "\(preset) wobbles")
            XCTAssertNotNil(preset.animation(reduceMotion: false))
        }
        XCTAssertGreaterThan(AtticMotionPreset.popover.bounce, 0, "things that appear land with a bounce")
        XCTAssertGreaterThan(AtticMotionPreset.settle.bounce, 0, "rows settle with a bounce")
        XCTAssertLessThanOrEqual(AtticMotionPreset.slide.bounce, 0.15, "pages bounce no more than snappy")
        XCTAssertEqual(AtticMotionPreset.pageSwitch.spring(in: .current), AtticMotionPreset.slide.spring(in: .current),
                       "a page switch is navigation: the feel's slide")
        XCTAssertNil(AtticMotionPreset.pageSwitch.animation(reduceMotion: true), "Page switch is instant under Reduce Motion")
        XCTAssertNil(AtticMotionPreset.expand.animation(reduceMotion: true), "Card expand is instant under Reduce Motion")
        XCTAssertNotNil(AtticMotionPreset.slide.animation(reduceMotion: true), "Slides crossfade under Reduce Motion")
    }

    func testTextIsNeverPureBlackOrWhite() {
        for context in [AtticDesignContext(mode: .light), AtticDesignContext(mode: .dark)] {
            for ink in [AtticInk.heading, .body, .label, .helper] {
                let colour = context.tokens.ink(ink)
                XCTAssertFalse(colour.hexString == "#000000" || colour.hexString == "#FFFFFF", "\(ink) is pure \(colour)")
            }
        }
    }

    /// Visual A ("Calm") sets the default look's colours, as neutral greys
    /// of the review's lightness (owner, 2026-09-26: no green cast).
    func testDefaultLadderMatchesVisualA() {
        let light = AtticDesignContext(mode: .light).tokens
        XCTAssertEqual(light.panel.base.hexString, "#FFFFFF")
        XCTAssertEqual(light.ink(.heading).hexString, "#272727")
        XCTAssertEqual(light.ink(.body).hexString, "#4B4B4B")
        XCTAssertEqual(light.ink(.helper).hexString, "#7A7A7A")
        XCTAssertEqual(light.ink(.priorityNone).hexString, "#838383")
        XCTAssertEqual(light.ink(.priorityMark).hexString, "#B35D27")
        XCTAssertEqual(light.doneDisc.hexString, "#E4E4E4")
        XCTAssertEqual(light.ink(.doneCheck).hexString, "#797979")
        XCTAssertEqual(light.hover.over(light.panel.base).hexString, "#F1F1F1")
        XCTAssertEqual(light.selected.over(light.panel.base).hexString, "#E7E7E7")
        // Phase 0's drawn control look (as before visual A) over this surface.
        XCTAssertEqual(light.controlFace.hexString, "#ECECEC")
        XCTAssertEqual(light.contentCard.hexString, "#FBFBFB")
        XCTAssertEqual(light.groupCard.hexString, "#F2F2F2")
        let dark = AtticDesignContext(mode: .dark).tokens
        XCTAssertEqual(dark.panel.base.hexString, "#2E2E2E")
        XCTAssertEqual(dark.ink(.heading).hexString, "#F1F1F1")
        XCTAssertEqual(dark.ink(.body).hexString, "#DFDFDF")
        XCTAssertEqual(dark.ink(.helper).hexString, "#A4A4A4")
        XCTAssertEqual(dark.ink(.priorityNone).hexString, "#959595")
        XCTAssertEqual(dark.ink(.priorityMark).hexString, "#D9A16C")
        XCTAssertEqual(dark.doneDisc.hexString, "#464646")
        XCTAssertEqual(dark.ink(.doneCheck).hexString, "#B8B8B8")
        XCTAssertEqual(dark.hover.over(dark.panel.base).hexString, "#383838")
        XCTAssertEqual(dark.selected.over(dark.panel.base).hexString, "#454545")
        XCTAssertEqual(dark.controlFace.hexString, "#454545")
        XCTAssertEqual(dark.contentCard.hexString, "#2E2E2E")
        XCTAssertEqual(dark.groupCard.hexString, "#333333")
        // Original's accent is grey.
        let accent = light.ink(.accent).hsl
        XCTAssertLessThan(accent.saturation, 0.05)
            // No green cast: every grey the default look draws is neutral.
        for tokens in [light, dark] {
            let base = tokens.panel.base
            let greys = [tokens.ink(.heading), tokens.ink(.body), tokens.ink(.helper), tokens.ink(.priorityNone), tokens.doneDisc,
                         tokens.ink(.doneCheck), tokens.controlFace,
                         tokens.hover.over(base), tokens.selected.over(base)]
            for grey in greys {
                XCTAssertTrue(abs(grey.red - grey.green) < 0.006 && abs(grey.green - grey.blue) < 0.006, "\(grey.hexString) is not neutral")
            }
        }
        XCTAssertEqual(dark.panel.base.hexString, "#2E2E2E")
}

    func testCustomisationChangesOnlyTheBackgroundAndTheAccent() {
        // Visual A tunes the default look (Original on Solid) on its own:
        // the other palettes share the ladder of Original with a Tint.
        let base = AtticDesignContext(mode: .light, palette: .amethyst).tokens
        for palette in AtticPanelTheme.allCases {
            for surface in PanelSurfaceStyle.allCases {
                let tokens = AtticDesignContext(mode: .light, palette: palette, surface: surface, tint: .bold).tokens
                XCTAssertEqual(tokens.raised, base.raised, "\(palette) changed the controls")
                XCTAssertEqual(tokens.controlBase, base.controlBase, "\(palette) tinted the controls")
                XCTAssertEqual(tokens.contentCard, base.contentCard)
                XCTAssertEqual(tokens.groupCard, base.groupCard)
            }
            // On the plain Solid look a palette changes no text at all.
            guard palette != .original else { continue }
            let solid = AtticDesignContext(mode: .light, palette: palette).tokens
            for ink in [AtticInk.heading, .body, .label, .helper, .glyph] {
                XCTAssertEqual(solid.ink(ink), base.ink(ink), "\(palette) changed \(ink)")
            }
        }
    }

    /// Owner direction (2026-09-25): raised controls are real Liquid Glass
    /// in Light and Dark; Reduce Transparency makes them the Craft style.
    func testControlsAreLiquidGlassUnlessTransparencyIsReduced() {
        XCTAssertEqual(AtticDesignContext.default.controls, .liquidGlass)
        XCTAssertEqual(AtticDesignContext.default.effectiveControls, .liquidGlass)
        XCTAssertEqual(AtticDesignContext(mode: .dark, reduceTransparency: true).effectiveControls, .craft)
        XCTAssertEqual(AtticDesignContext(controls: .craft).effectiveControls, .craft)
        // The switch changes no colour: the text is tuned for both materials.
        XCTAssertEqual(AtticDesignContext(controls: .craft).colourKey, AtticDesignContext.default.colourKey)
    }

    /// The glass model is never kinder to a label than real Liquid Glass as
    /// measured with `--glass-lab` (the darkest face in Light, the lightest
    /// in Dark, in relative luminance). A sample of the 206 swatches.
    func testGlassModelIsNoKinderThanMeasuredGlass() {
        let light: [(surface: UInt32, darkestFace: UInt32)] = [
            (0xFFFFFF, 0xF8F8F8), (0xFAFAFA, 0xF6F6F6), (0xE8E8E8, 0xECECEC), (0xC8C8C8, 0xDADBDA),
            (0x969696, 0xBEBEBE), (0xB6BFD2, 0xCED5E9), (0xFCEFDB, 0xFBF0DC), (0xDAFCF4, 0xDCFAF2)
        ]
        for (surface, measured) in light {
            let model = AtticGlassModel.worstFace(dark: false).over(AtticRGBA(surface))
            XCTAssertLessThanOrEqual(model.relativeLuminance, AtticRGBA(measured).relativeLuminance, AtticRGBA(surface).hexString)
        }
        let dark: [(surface: UInt32, lightestFace: UInt32)] = [
            (0x000000, 0x212121), (0x141414, 0x343434), (0x2C2C2D, 0x4A4A4B), (0x505050, 0x676767),
            (0x042D25, 0x2A4D43), (0x0A2C25, 0x2E4C44)
        ]
        for (surface, measured) in dark {
            let model = AtticGlassModel.worstFace(dark: true).over(AtticRGBA(surface))
            XCTAssertGreaterThanOrEqual(model.relativeLuminance, AtticRGBA(measured).relativeLuminance, AtticRGBA(surface).hexString)
        }
    }

    /// Every label a control carries keeps its floor on the Craft-style
    /// face and on the worst glass face over every surface the panel can
    /// draw, in every combination (the model check covers the rest).
    func testControlLabelsKeepTheirFloorsOnGlassAndCraft() {
        for context in AtticAppearanceCheck.allContexts() {
            let tokens = context.tokens
            let pairs = AtticSurfaceModel.readabilityPairs(
                inks: tokens.inks, hover: tokens.hover, selected: tokens.selected, pressed: tokens.pressed,
                controlFace: tokens.controlFace, glassFace: tokens.glassFace, glassDisabled: tokens.glassDisabled, glassPressed: tokens.glassPressed, chipSelected: tokens.chipSelected, chipHover: tokens.chipHover, doneDisc: tokens.doneDisc,
                recessed: tokens.recessed, tagFill: tokens.tagFill, tagFillSelected: tokens.tagFillSelected
            )
            let onControls = pairs.filter { $0.overlays.first == tokens.controlFace || $0.onGlass }
            XCTAssertEqual(onControls.filter(\.onGlass).count, onControls.count / 2, context.caption)
            // Named exception: labels on Liquid Glass over Phase 0's Glass
            // and Frosted surfaces (`Phase0TranslucentException`).
            for pair in onControls where tokens.panel.worstMargin([pair]) < 0.999
                && !(pair.onGlass && Phase0TranslucentException.covers(context)) {
                XCTFail(String(format: "%@: %@ %@ on %@ margin %.3f", context.caption, pair.ink.rawValue, pair.foreground.hexString,
                               pair.onGlass ? "glass" : "Craft", tokens.panel.worstMargin([pair])))
            }
        }
        // The drawn control face at Phase 0's weight: about 19 below
        // the Light surface (the reference's #ECECEC on white), 23 above the Dark one.
        let light = AtticDesignContext(mode: .light).tokens.controlFace
        let dark = AtticDesignContext(mode: .dark).tokens.controlFace
        XCTAssertEqual(light.hexString, "#ECECEC")
        XCTAssertEqual(dark.hexString, "#454545")
    }

    func testScrollEdgeVeilFollowsItsRamp() {
        XCTAssertEqual(AtticEdgeBlur.veil(at: 0), 0)
        XCTAssertEqual(AtticEdgeBlur.veil(at: 1), AtticEdgeBlur.maximumVeil, accuracy: 0.0001)
        XCTAssertEqual(AtticEdgeBlur.veil(at: 0.55), 0.30, accuracy: 0.0001)
        XCTAssertEqual(AtticEdgeBlur.veil(at: 2), AtticEdgeBlur.maximumVeil, accuracy: 0.0001)
        var previous = -1.0
        for step in 0...20 {
            let value = AtticEdgeBlur.veil(at: Double(step) / 20)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    /// Spec rev 175: text that matters keeps 4.5 : 1, secondary text stays
    /// soft at 3 : 1 at least, and Increase Contrast lifts all text to 4.5.
    func testSecondaryTextIsSoftButReadable() {
        for ink in [AtticInk.helper, .muted, .placeholder, .chromeHint, .disabledText, .accentText] {
            XCTAssertTrue(ink.isSecondaryText, "\(ink)")
            XCTAssertEqual(AtticSurfaceModel.floor(for: ink, kind: .solid, increaseContrast: false), 3)
            XCTAssertEqual(AtticSurfaceModel.floor(for: ink, kind: .glass, increaseContrast: false), 3)
            XCTAssertEqual(AtticSurfaceModel.floor(for: ink, kind: .solid, increaseContrast: true), 4.5)
        }
        for ink in [AtticInk.heading, .body, .label, .dueText, .warningText, .onInverse, .chromeBody] {
            XCTAssertFalse(ink.isSecondaryText, "\(ink)")
            XCTAssertEqual(AtticSurfaceModel.floor(for: ink, kind: .frosted, increaseContrast: false), 4.5)
        }
        // Close to v4's greys, not merely at the floor: secondary text on
        // the plain surface reads between 3 and 4.5 : 1, and the quietest
        // grey is lighter than the helper grey.
        for context in [AtticDesignContext(mode: .light), AtticDesignContext(mode: .dark)] {
            let tokens = context.tokens
            let base = tokens.panel.base
            let helper = tokens.ink(.helper).contrast(on: base)
            let muted = tokens.ink(.muted).contrast(on: base)
            XCTAssertGreaterThanOrEqual(muted, 3, context.caption)
            // Visual A's Dark secondary grey is deliberately 5.46 : 1.
            XCTAssertLessThan(helper, context.mode == .dark ? 5.5 : 4.5 * 1.05, "\(context.caption): helper stays soft (\(helper))")
            XCTAssertLessThanOrEqual(muted, helper + 0.001, context.caption)
            XCTAssertGreaterThanOrEqual(tokens.ink(.body).contrast(on: base), 4.5)
        }
        // Increase Contrast: every text 4.5 : 1.
        let increased = AtticDesignContext(mode: .light, increaseContrast: true).tokens
        for ink in AtticInk.allCases where ink.floor == .text && ink != .onInverse {
            XCTAssertGreaterThanOrEqual(increased.ink(ink).contrast(on: increased.panel.base), 4.5, "\(ink)")
        }
    }

    /// Translucent and tinted panels step a role stronger only where it
    /// would miss its floor: a role that passes keeps its Solid colour.
    func testTranslucentPanelsStepStrongerOnlyWhereNeeded() {
        let solid = AtticDesignContext(mode: .light).tokens
        // Tinted panels step a role stronger only where needed. (Glass and
        // Frosted are Phase 0's and keep their text unstepped:
        // `testGlassAndFrostedArePhase0s`.)
        for context in [AtticDesignContext(mode: .light, tint: .bold)] {
            let tokens = context.tokens
            for ink in [AtticInk.helper, .muted, .label, .body] {
                XCTAssertGreaterThanOrEqual(tokens.ink(ink).contrast(on: solid.panel.base), solid.ink(ink).contrast(on: solid.panel.base) - 0.01, "\(context.caption) \(ink)")
            }
            // Visual A sets the plain default's heading exactly; elsewhere
            // the heading is the ladder's, which already passes everywhere
            // (the Light palettes use Phase 0's: `testLightPalettesArePhase0s`).
            XCTAssertEqual(tokens.ink(.heading), AtticColorTokens.Ladder.neutral(dark: false, ic: false)[.heading], "Heading already passes everywhere")
        }
    }

    func testTintsKeepTheirDesignedStrength() {
        for mode in AtticDesignContext.Mode.allCases {
            for palette in AtticPanelTheme.allCases where !palette.usesNeutralTint {
                let plain = AtticDesignContext(mode: mode, palette: palette).tokens.panel.composite(.midGrey)
                let bold = AtticDesignContext(mode: mode, palette: palette, tint: .bold).tokens.panel.composite(.midGrey)
                XCTAssertEqual(ColorDifference.deltaE76(plain.themeColor, bold.themeColor), 12, accuracy: 0.2, "\(mode) \(palette)")
            }
        }
    }

    // MARK: The colour model

    func testEveryCombinationKeepsItsReadabilityFloors() {
        var report = AtticAppearanceCheck.Report()
        let contexts = AtticAppearanceCheck.allContexts()
        AtticAppearanceCheck.checkModel(contexts: contexts, report: &report)
        XCTAssertGreaterThan(contexts.count, 400)
        let remaining = Phase0AccentException.remaining(Phase0TranslucentException.remaining(report.failures))
        XCTAssertTrue(remaining.isEmpty, remaining.map { "\($0.key.specimen): \($0.key.detail) in \($0.value.joined(separator: " | "))" }.joined(separator: "\n"))
        // The exceptions are only ever the panel surface's text: menus and
        // cards keep the rule everywhere.
        for failure in report.failures.keys {
            XCTAssertEqual(failure.specimen, "Panel surface", "\(failure)")
        }
        // The accent exception is only the tags' accent text.
        for context in contexts where Phase0AccentException.covers(caption: context.caption) && !Phase0TranslucentException.covers(context) {
            let tokens = context.tokens
            let pairs = AtticSurfaceModel.readabilityPairs(
                inks: tokens.inks, hover: tokens.hover, selected: tokens.selected, pressed: tokens.pressed,
                controlFace: tokens.controlFace, glassFace: tokens.glassFace, glassDisabled: tokens.glassDisabled, glassPressed: tokens.glassPressed, chipSelected: tokens.chipSelected, chipHover: tokens.chipHover, doneDisc: tokens.doneDisc,
                recessed: tokens.recessed, tagFill: tokens.tagFill, tagFillSelected: tokens.tagFillSelected
            )
            for pair in pairs where tokens.panel.worstMargin([pair]) < 0.999 {
                XCTAssertEqual(pair.ink, .accentText, context.caption)
            }
        }
    }

    /// Phase 0's surface treatment for a context's colours.
    static func phase0Treatment(_ context: AtticDesignContext) -> AtticPanelSurfaceTreatment {
        context.palette.surfaceTreatment(
            appearance: context.mode == .dark ? .dark : .light, contrast: context.increaseContrast ? .increased : .standard,
            surface: PanelSurfaceStyle(context.effectiveSurface), tint: context.tint,
            tintLength: AtticDesignContext.quantisedTintLength(context.tintLength), reduceTransparency: false
        )
    }

    /// Owner, 2026-09-26: Glass and Frosted are Phase 0's surfaces (its
    /// foundation colour, Tint, Frosted wash, bright native material under
    /// Original's shade, and edge), in both modes, plus the two changes the
    /// owner kept in round 6: Readable Glass's backing (only the foundation
    /// opacity grows) and the defined dark edge (Dark only). Reduce
    /// Transparency still makes the surface Solid.
    func testGlassAndFrostedArePhase0sPlusTheReadableBacking() {
        for context in AtticAppearanceCheck.allContexts() where context.effectiveSurface != .solid {
            let treatment = Self.phase0Treatment(context)
            let phase0 = AtticSurfaceModel.phase0(treatment, increaseContrast: context.increaseContrast)
            let panel = context.tokens.panel
            XCTAssertEqual(panel, phase0.readable(primary: AtticRGBA(treatment.palette.primaryForeground),
                                                  secondary: AtticRGBA(treatment.palette.secondaryForeground)).definedDarkEdge(),
                           context.caption)
            XCTAssertEqual(panel.withFoundation(phase0.foundationOpacity), phase0.definedDarkEdge(),
                           "only the backing and the dark edge differ from Phase 0: \(context.caption)")
        }
        XCTAssertEqual(AtticDesignContext(mode: .light, surface: .glass, reduceTransparency: true).tokens.panel.kind, .solid)
        // Phase 0's Original coverage (far more see-through than PR #5's 67 / 80 / 66 / 82).
        let measured = [
            AtticDesignContext(mode: .light, surface: .glass), AtticDesignContext(mode: .light, surface: .frosted),
            AtticDesignContext(mode: .dark, surface: .glass), AtticDesignContext(mode: .dark, surface: .frosted)
        ].map { Int((AtticSurfaceModel.phase0(Self.phase0Treatment($0), increaseContrast: false).foundationOpacity * 100).rounded()) }
        XCTAssertEqual(measured, [1, 16, 10, 32])
        // Text on them is Phase 0's (owner, 2026-09-26): its primary and
        // secondary greys, placeholder included, every palette, both modes.
        for mode in AtticDesignContext.Mode.allCases {
            let appearance: AtticPanelThemeAppearance = mode == .dark ? .dark : .light
            for palette in AtticPanelTheme.allCases {
                let p0 = palette.palette(for: appearance)
                for surface in [PanelSurfaceStyle.glass, .frosted] {
                    let tokens = AtticDesignContext(mode: mode, palette: palette, surface: surface).tokens
                    for ink in [AtticInk.heading, .body, .label] {
                        XCTAssertEqual(tokens.ink(ink), AtticRGBA(p0.primaryForeground), "\(mode) \(palette) \(surface) \(ink)")
                    }
                    XCTAssertEqual(tokens.ink(.helper), AtticRGBA(p0.secondaryForeground), "\(mode) \(palette) \(surface)")
                    XCTAssertEqual(tokens.ink(.placeholder), AtticRGBA(p0.secondaryForeground), "\(mode) \(palette) \(surface)")
                }
            }
        }
        // Solid keeps its text: Original's Light (neutral greys) and Dark.
        XCTAssertEqual(AtticDesignContext(mode: .light).tokens.ink(.helper).hexString, "#7A7A7A")
        XCTAssertNotEqual(AtticDesignContext(mode: .dark).tokens.ink(.helper), AtticRGBA(AtticPanelTheme.original.palette(for: AtticPanelThemeAppearance.dark).secondaryForeground))
    }

    /// Owner, 2026-09-26: the Light palettes are Phase 0's: its surface,
    /// primary and secondary text (also the placeholder) and accent
    /// colours, exactly, on every surface; the page button's current page
    /// in the accent. Original's Light stays pure white with neutral greys.
    func testLightPalettesArePhase0s() {
        for palette in AtticPanelTheme.allCases where palette != .original {
            let p0 = palette.palette(for: AtticPanelThemeAppearance.light)
            for surface in PanelSurfaceStyle.allCases {
                let tokens = AtticDesignContext(mode: .light, palette: palette, surface: surface).tokens
                XCTAssertEqual(tokens.panel.base, AtticRGBA(p0.opaqueSurface), "\(palette) \(surface)")
                XCTAssertEqual(tokens.ink(.heading), AtticRGBA(p0.primaryForeground))
                XCTAssertEqual(tokens.ink(.body), AtticRGBA(p0.primaryForeground))
                XCTAssertEqual(tokens.ink(.helper), AtticRGBA(p0.secondaryForeground))
                XCTAssertEqual(tokens.ink(.placeholder), AtticRGBA(p0.secondaryForeground))
                XCTAssertEqual(tokens.ink(.accent), AtticRGBA(p0.accent))
                XCTAssertEqual(tokens.ink(.accentText), AtticRGBA(p0.accent))
                XCTAssertNotNil(tokens.pageChipAccent)
            }
            // Dark keeps the design system's palettes.
            XCTAssertNil(AtticDesignContext(mode: .dark, palette: palette).tokens.pageChipAccent)
            XCTAssertNotEqual(AtticDesignContext(mode: .dark, palette: palette).tokens.panel.base, AtticRGBA(palette.palette(for: AtticPanelThemeAppearance.dark).opaqueSurface))
        }
        XCTAssertEqual(AtticDesignContext(mode: .light).tokens.panel.base.hexString, "#FFFFFF")
        XCTAssertNil(AtticDesignContext(mode: .light).tokens.pageChipAccent)
    }

    func testDisabledTextAndIconsMeetTheRule() {
        for context in AtticAppearanceCheck.allContexts() {
            let tokens = context.tokens
            let text = tokens.ink(.disabledText)
            let icon = tokens.ink(.disabledIcon)
            let textFloor = AtticSurfaceModel.floor(for: .disabledText, kind: context.effectiveSurface, increaseContrast: context.increaseContrast)
            XCTAssertEqual(AtticInk.disabledText.floor, .text)
            XCTAssertEqual(AtticInk.disabledIcon.floor, .nonText)
            // Menus and cards are base style; the panel is judged over every desktop.
            for background in [tokens.popoverFill, tokens.contentCard, tokens.groupCard] {
                XCTAssertGreaterThanOrEqual(text.contrast(on: background), textFloor, "\(context.caption) disabled text")
                XCTAssertGreaterThanOrEqual(icon.contrast(on: background), 3, "\(context.caption) disabled icon")
            }
            let pairs = [
                AtticSurfaceModel.Pair(ink: .disabledText, foreground: text, overlays: []),
                AtticSurfaceModel.Pair(ink: .disabledIcon, foreground: icon, overlays: [])
            ]
            if !Phase0TranslucentException.covers(context) {
                XCTAssertGreaterThanOrEqual(tokens.panel.worstMargin(pairs), 0.999, context.caption)
            }
        }
        // Still a ghost: never louder than the helper grey.
        for context in [AtticDesignContext(mode: .light), AtticDesignContext(mode: .dark)] {
            let tokens = context.tokens
            XCTAssertLessThanOrEqual(tokens.ink(.disabledText).contrast(on: tokens.panel.base), tokens.ink(.helper).contrast(on: tokens.panel.base) + 0.001)
            XCTAssertLessThan(tokens.ink(.disabledIcon).contrast(on: tokens.panel.base), tokens.ink(.glyph).contrast(on: tokens.panel.base))
        }
    }

    func testTintLengthKeyIsQuantisedAndTheCacheIsBounded() {
        let a = AtticDesignContext(mode: .light, tint: .bold, tintLength: 0.6512).colourKey
        let b = AtticDesignContext(mode: .light, tint: .bold, tintLength: 0.6488).colourKey
        XCTAssertEqual(a, b, "Slider positions within the same percent share a key")
        XCTAssertEqual(a.tintLength, 0.65, accuracy: 0.000_1)
        var keys = Set<AtticDesignContext.ColourKey>()
        for step in 0...10_000 {
            keys.insert(AtticDesignContext(tint: .bold, tintLength: 0.3 + 0.7 * Double(step) / 10_000).colourKey)
        }
        XCTAssertEqual(keys.count, 71, "30 % to 100 % in whole percent")

        let cache = AtticColorTokenCache(capacity: 8)
        for step in 0..<40 {
            _ = cache.tokens(for: AtticDesignContext(tint: .bold, tintLength: 0.3 + Double(step) / 100).colourKey)
        }
        XCTAssertEqual(cache.count, 8, "The cache never holds more than its capacity")
        XCTAssertLessThanOrEqual(AtticColorTokenCache.shared.capacity, 64)
    }

    func testSendButtonNestsInsideTheAddBar() {
        let send = AtticControlSize.sendButton
        XCTAssertEqual(send, CGSize(width: 24, height: 24), "Chrome B: 32 − 2 × 4 inside the bar")
        XCTAssertEqual(send.height, AtticControlSize.addBarHeight - 2 * AtticControlSize.sendInset)
        XCTAssertEqual(AtticRadius.nested(outer: AtticRadius.control(height: AtticControlSize.addBarHeight), gap: AtticControlSize.sendInset), 9.5)
    }

    /// Astra 19: one definition of what a row can do. VoiceOver offers
    /// exactly the commands the row has (a Done log row: complete or
    /// un-complete, Restore to Now, its details; no working, moving or
    /// deleting), live rows add Edit title, and a key for a command the row
    /// lacks does nothing.
    func testTaskActionsOfferOnlyWhatTheRowCanDo() {
        var fired: [String] = []
        let live = AtticTaskActions(
            toggleDone: { fired.append("done") }, toggleWorking: { fired.append("working") },
            openPage: { fired.append("open") }, moveToBacklog: { fired.append("later") }, delete: { fired.append("delete") },
            editTitle: { fired.append("edit") }, names: .init(openPage: "Open files")
        )
        XCTAssertEqual(live.accessibilityActions(for: .todo).map(\.name),
                       ["Complete", "Start working", "Open files", "Edit title", "Move to Later", "Delete"])
        let archived = AtticTaskActions(
            toggleDone: { fired.append("done") }, openPage: { fired.append("details") },
            restoreToNow: { fired.append("restore") }, names: .init(openPage: "Show details")
        )
        XCTAssertEqual(archived.accessibilityActions(for: .done).map(\.name), ["Mark as not done", "Restore to Now", "Show details"])
        for command in [AtticTaskKeys.Command.toggleWorking, .moveToBacklog, .delete, .editTitle] {
            AtticTaskKeys.perform(command, archived)
        }
        XCTAssertEqual(fired, [], "keys for commands a Done log row lacks do nothing")
        AtticTaskKeys.perform(.openPage, archived)
        AtticTaskKeys.perform(.toggleDone, archived)
        XCTAssertEqual(fired, ["details", "done"])
    }

    func testTaskKeysMapToDistinctCommands() {
        func command(_ key: KeyEquivalent, _ characters: String, _ modifiers: EventModifiers, list: Bool = true) -> AtticTaskKeys.Command? {
            AtticTaskKeys.command(key: key, characters: characters, modifiers: modifiers, listCommands: list)
        }
        XCTAssertEqual(command(.space, " ", []), .toggleDone, "Space does what the circle does: complete, or un-complete")
        XCTAssertEqual(command(.space, "\u{A0}", .option), .toggleDone, "⌥Space stays an alias")
        XCTAssertEqual(command(.space, " ", .shift), .toggleWorking, "⇧Space starts or stops working (Direction A)")
        XCTAssertEqual(command(.return, "\r", .command), .openPage)
        XCTAssertEqual(command(.return, "\r", []), .editTitle, "Return edits the title (Phase 1), it never opens the page")
        XCTAssertNil(command(.return, "\r", [], list: false), "Cards in notes leave Return alone")
        XCTAssertEqual(command(KeyEquivalent("b"), "b", .command), .moveToBacklog)
        XCTAssertEqual(command(.delete, "\u{7F}", []), .delete)
        XCTAssertNil(command(.delete, "\u{7F}", [], list: false), "Cards in notes don't take list commands")
        XCTAssertNil(command(.space, " ", .command))
    }

    // MARK: Motion keeps layout still

    func testThePageButtonAndTabsKeepTheirSizeForEverySelection() {
        var buttonSizes: Set<String> = []
        var tabSizes: Set<String> = []
        for page in 0..<AtticGallerySamples.pages.count {
            let button = NSHostingView(rootView: AtticPageButton(items: AtticGallerySamples.pages, selection: .constant(page), pinnedOpen: false)
                .atticDesign(.default))
            buttonSizes.insert("\(button.fittingSize)")
            // The selected tab is semibold; every label reserves that width,
            // so moving the selection never shifts the row.
            let tabs = NSHostingView(rootView: AtticPageTabs(items: AtticGallerySamples.pageTabs, selection: .constant(page))
                .atticDesign(.default))
            tabSizes.insert("\(tabs.fittingSize)")
        }
        XCTAssertEqual(buttonSizes, ["\(CGSize(width: AtticControlSize.headerControl, height: AtticControlSize.headerControl))"])
        XCTAssertEqual(tabSizes.count, 1, "The tabs keep their width whichever page is selected: \(tabSizes)")
        XCTAssertEqual(AtticTextStyle.pageTabSelected.spec.weight, .semibold)
        XCTAssertEqual(AtticTextStyle.pageTab.spec.weight, .medium)
    }

    func testAddBarFieldKeepsItsWidthWhenTheSendButtonAppears() throws {
        func fieldFrame(text: String) throws -> CGRect {
            let collector = AtticProbeCollector()
            let view = AtticAddBar(placeholder: "Add a task", text: .constant(text), onSubmit: {})
                .frame(width: 296)
                .atticDesign(.default)
                .environment(\.atticCapture, AtticCaptureContext(collector: collector, backdrop: .desktop(.midGrey)))
                .coordinateSpace(.named(AtticCaptureContext.coordinateSpace))
            let renderer = ImageRenderer(content: view)
            _ = renderer.cgImage
            let field = collector.all.first { probe in
                if case let .control(name, _, _, _) = probe.kind { return name == "Add bar field" }
                return false
            }
            return try XCTUnwrap(field?.frame)
        }
        let empty = try fieldFrame(text: "")
        let typed = try fieldFrame(text: "Call the printer")
        XCTAssertEqual(empty, typed, "The send button's slot is reserved: the field never changes size")
        XCTAssertGreaterThan(empty.width, 200)
    }

    // MARK: The appearance check (representative subset)

    /// The fast, representative part of the appearance check that runs in
    /// every unit-test run: the model for every combination (above), the
    /// geometry fitted from pixels, and every family rendered at 2× in the
    /// curated combinations (default Light and Dark and the stress cases),
    /// with each glyph's contrast read from its own pixels.
    ///
    /// The full matrix (every combination, every family) and the contact
    /// sheets run separately: `Scripts/run_appearance_matrix.zsh`
    /// (`AtticAppearanceMatrixTests`).
    func testRepresentativeAppearanceSubset() {
        let started = Date()
        let report = AtticAppearanceCheck.run(contexts: AtticAppearanceCheck.sheetContexts().map(\.context), scale: 2)
        let summary = report.summary + String(format: "\n\nChecked in %.0f s.", Date().timeIntervalSince(started))
        let attachment = XCTAttachment(string: summary)
        attachment.name = "appearance-subset.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(summary)
        XCTAssertGreaterThan(report.glyphsMeasured, 1_000)
        XCTAssertEqual(report.contrastPairsChecked, report.eligibleProbes, "Every eligible probe's background was measured")
        // Glyphs too faint to find over Phase 0's Glass and Frosted are
        // reported as unmeasured failures, which the named exception covers.
        let unmeasured = report.failures.filter { $0.key.kind == .unmeasured }
        let unmeasuredInException = unmeasured.flatMap { _, combinations in
            combinations.filter { Phase0TranslucentException.covers(caption: $0) }
        }.count
        XCTAssertEqual(report.glyphsMeasured + unmeasuredInException, report.eligibleGlyphs, "Every eligible probe's glyph was measured")
        XCTAssertEqual(report.eligibleGlyphs, report.eligibleProbes, "At 2× every eligible probe is a glyph check")
        XCTAssertGreaterThanOrEqual(report.geometryMeasured, 15)
        XCTAssertTrue(OpenRingException.remaining(Phase0TranslucentException.remaining(report.failures)).isEmpty, report.summary)
    }

    /// Renders `view` in capture mode at 2× on a flat panel background and
    /// runs the pixel contrast check on whatever it reported.
    private func pixelReport<V: View>(_ view: V, context: AtticDesignContext = .default) throws -> AtticAppearanceCheck.Report {
        let collector = AtticProbeCollector()
        let content = view
            .padding(20)
            .background(context.tokens.panel.base.color)
            .atticDesign(context)
            .environment(\.atticCapture, AtticCaptureContext(collector: collector, backdrop: .desktop(.midGrey)))
            .coordinateSpace(.named(AtticCaptureContext.coordinateSpace))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = try XCTUnwrap(AtticBitmap(image: image))
        let visual = collector.all.filter {
            switch $0.kind {
            case .text, .icon: true
            default: false
            }
        }
        var report = AtticAppearanceCheck.Report()
        AtticAppearanceCheck.checkContrast(visual, bitmap: bitmap, scale: 2, context: context, family: "Test", combination: "test", report: &report)
        return report
    }

    func testAProbeWhoseGlyphDrewNothingFails() throws {
        // A visible run passes and is counted.
        let visible = try pixelReport(AtticText(verbatim: "Book dentist", style: .rowTitle, ink: .body))
        XCTAssertEqual(visible.eligibleGlyphs, 1)
        XCTAssertEqual(visible.glyphsMeasured, 1)
        XCTAssertTrue(visible.failures.isEmpty, visible.summary)

        // The same run, reported but not drawn (faded to nothing), fails:
        // a missing glyph is never a silent pass.
        let missing = try pixelReport(AtticText(verbatim: "Book dentist", style: .rowTitle, ink: .body).opacity(0))
        XCTAssertEqual(missing.eligibleGlyphs, 1)
        XCTAssertEqual(missing.glyphsMeasured, 0)
        XCTAssertTrue(missing.failures.keys.contains { $0.kind == .unmeasured }, missing.summary)

        // An icon that draws nothing fails the same way.
        let blankIcon = try pixelReport(AtticIcon(systemName: "flag", ink: .icon).opacity(0))
        XCTAssertEqual(blankIcon.eligibleGlyphs, 1)
        XCTAssertTrue(blankIcon.failures.keys.contains { $0.kind == .unmeasured }, blankIcon.summary)
    }

    func testCheckMarksAreMeasuredAgainstTheirFill() throws {
        for context in [AtticDesignContext(mode: .light), AtticDesignContext(mode: .dark), AtticDesignContext(mode: .light, surface: .glass, tint: .bold)] {
            // The model: the done check keeps 3 : 1 on the quiet disc (the
            // old filled Done's pairs still hold for the coverage).
            let tokens = context.tokens
            XCTAssertGreaterThanOrEqual(tokens.ink(.onDone).contrast(on: tokens.ink(.doneFill)), 3, context.caption)
            XCTAssertGreaterThanOrEqual(tokens.ink(.onDone).contrast(on: tokens.ink(.disabledIcon)), 3, context.caption)
            XCTAssertGreaterThanOrEqual(tokens.ink(.doneCheck).contrast(on: tokens.doneDisc), 3, context.caption)
            // The pixels: a drawn check is measured and passes. Done's fill
            // (the task's disc, the subtask's square) is decoration: the
            // check is judged.
            let drawn = try pixelReport(HStack { AtticStatusCircle(state: .done); AtticSubtaskCheckbox(isDone: true) }, context: context)
            XCTAssertEqual(drawn.eligibleGlyphs, 2, "Two check marks")
            XCTAssertEqual(drawn.glyphsMeasured, 2)
            XCTAssertTrue(drawn.failures.isEmpty, drawn.summary)
        }
        // A deliberately absent check (not yet drawn) fails: its probe finds
        // no glyph pixels on the fill.
        let absent = try pixelReport(AtticStatusCircle(state: .done, checkProgress: 0))
        XCTAssertTrue(absent.failures.keys.contains { $0.kind == .unmeasured && $0.detail.contains("check mark") }, absent.summary)
    }

    // MARK: Status circle

    /// Direction A with Phase 0's confident circles: every open ring is one
    /// ink (the task title's primary ink) at one weight, 1.6 pt (2 under Increase
    /// Contrast); priority is a mark after the title. High's "!!" is an
    /// orange at least as readable as secondary text, and red is left to
    /// overdue dates.
    func testStatusRingIsOneInkAndPriorityIsAMark() {
        let m = AtticStatusCircleMetrics.self
        XCTAssertEqual(m.ringWidth(increaseContrast: false), 1.6)
        XCTAssertEqual(m.ringWidth(increaseContrast: true), 2)
        // The task title's primary ink (Phase 0's qualities, item 6).
        XCTAssertEqual(AtticStatusCircle.ringInk, .heading)
        XCTAssertEqual(AtticStatusCircle.activeInk, .heading)
        for context in AtticAppearanceCheck.allContexts() {
            let tokens = context.tokens
            let base = tokens.panel.base
            let ring = tokens.ink(AtticStatusCircle.ringInk).contrast(on: base)
            XCTAssertGreaterThanOrEqual(ring, 4.5, "a confident ring · \(context.caption)")
            let mark = tokens.ink(.priorityMark)
            XCTAssertGreaterThanOrEqual(mark.contrast(on: base), context.increaseContrast ? 4.5 : 3, context.caption)
            XCTAssertGreaterThan(mark.saturation, 0.3, "High's mark is orange · \(context.caption)")
            XCTAssertNotEqual(mark, tokens.ink(.dueText), "orange, not the overdue red · \(context.caption)")
        }
        XCTAssertTrue(AtticInk.priorityMark.isSecondaryText)
    }

    /// Phase 0's qualities, item 6: the task list's text is SF Pro Rounded
    /// (a flag on its styles), an in-progress title is medium, and the
    /// header's and Settings' styles stay SF Pro.
    func testTheTaskListIsSFProRounded() {
        for style in [AtticTextStyle.rowTitle, .rowTitleActive, .rowMeta, .rowMetaEmphasis, .count, .priorityMark,
                      .pageTab, .pageTabSelected, .sectionToggle, .listBody] {
            XCTAssertTrue(style.spec.rounded, "\(style)")
            XCTAssertTrue(style.nsFont.fontDescriptor.symbolicTraits.contains(.monoSpace) == false)
        }
        for style in [AtticTextStyle.chipLabel, .controlLabel, .body, .menuRow, .groupLabel, .groupValue, .pageTitle, .sidebarRow] {
            XCTAssertFalse(style.spec.rounded, "\(style) stays SF Pro")
        }
        XCTAssertEqual(AtticTextStyle.rowTitle.spec.size, 13)
        XCTAssertEqual(AtticTextStyle.rowTitleActive.spec.weight, .medium)
        XCTAssertNotEqual(AtticTextStyle.listBody.nsFont.fontName, AtticTextStyle.body.nsFont.fontName, "the rounded face is a different font")
    }

    /// In progress (owner, 2026-09-26): the centre dot until a subtask is
    /// ticked, then a true pie of the share ticked, with no minimum.
    func testInProgressIsADotUntilASubtaskIsTickedThenATruePie() {
        XCTAssertNil(AtticStatusCircle.pieShare(nil))
        XCTAssertNil(AtticStatusCircle.pieShare((0, 3)))
        XCTAssertNil(AtticStatusCircle.pieShare((0, 0)))
        XCTAssertEqual(AtticStatusCircle.pieShare((1, 3))!, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(AtticStatusCircle.pieShare((1, 10))!, 0.1, accuracy: 1e-9, "no minimum")
        XCTAssertEqual(AtticStatusCircle.pieShare((3, 3)), 1)
    }

    /// In progress is a ring with a centre dot, never a share: VoiceOver
    /// still says how many subtasks are ticked.
    func testInProgressIsADotAndCompletionSweepsTheDisc() {
        let m = AtticStatusCircleMetrics.self
        XCTAssertGreaterThan(m.activeDotDiameter, 0)
        XCTAssertLessThan(m.activeDotDiameter, AtticControlSize.statusCircle - 2 * (m.edgeInset + m.ringWidth(increaseContrast: true)) - 2,
                          "the dot keeps clear of the ring")
        XCTAssertEqual(AtticStatusCircle.spokenState(.inProgress, subtasks: (1, 3)), "in progress, 1 of 3 subtasks")
        XCTAssertEqual(AtticStatusCircle.spokenState(.inProgress, subtasks: nil), "in progress")
        XCTAssertEqual(AtticStatusCircle.spokenState(.todo, subtasks: (1, 3)), "to do")
        // The completion sweep keeps clear of the heaviest ring.
        let heaviest = m.ringWidth(increaseContrast: true)
        XCTAssertGreaterThanOrEqual(m.wedgeInset(ringWidth: heaviest), m.edgeInset + heaviest + m.wedgeGap)
        // The wedge's path grows with the sweep and is a full disc at 1.
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        /// The drawn area, in 4× pixels.
        func area(_ sweep: Double) -> CGFloat {
            let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.scaleBy(x: 4, y: 4)
            context.addPath(AtticWedge(sweep: sweep, inset: 3.2).path(in: rect).cgPath)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath()
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<(64 * 64)).reduce(0) { $0 + CGFloat(pixels[$1]) / 255 }
        }
        XCTAssertEqual(area(0.25) / area(1), 0.25, accuracy: 0.01)
        XCTAssertEqual(area(2.0 / 3) / area(1), 2.0 / 3, accuracy: 0.01)
        XCTAssertEqual(area(0.999_999), area(1), accuracy: 2, "No jump as the sweep reaches the full disc")
        // Clockwise from 12 o'clock: a quarter covers the upper right.
        let quarter = AtticWedge(sweep: 0.25, inset: 3.2).path(in: rect)
        XCTAssertTrue(quarter.contains(CGPoint(x: 10, y: 6)))
        XCTAssertFalse(quarter.contains(CGPoint(x: 6, y: 6)))
    }

    func testCapturePassesOnlyWhenEveryGlyphWasMeasured() {
        var report = AtticAppearanceCheck.Report()
        report.eligibleProbes = 10
        report.contrastPairsChecked = 10
        XCTAssertFalse(report.passed, "A 1× run reads no glyph pixels, so it cannot pass")
        report.eligibleGlyphs = 10
        report.glyphsMeasured = 9
        XCTAssertFalse(report.passed)
        report.glyphsMeasured = 10
        XCTAssertTrue(report.passed)
        XCTAssertFalse(AtticAppearanceCheck.Report().passed, "An empty run never passes")
    }

    func testAProbeWithNoBackgroundToSampleFails() throws {
        // The probe's frame lies outside the rendered image: nothing to sample.
        var report = AtticAppearanceCheck.Report()
        let image = try XCTUnwrap(ImageRenderer(content: Color.white.frame(width: 20, height: 20)).cgImage)
        let bitmap = try XCTUnwrap(AtticBitmap(image: image))
        var probe = AtticProbe(id: UUID(), kind: .text(style: .body, string: "Off the canvas"), ink: .body, foreground: AtticRGBA(0x494B4A), specimen: "Test / off")
        probe.frame = CGRect(x: 200, y: 200, width: 60, height: 16)
        AtticAppearanceCheck.checkContrast([probe], bitmap: bitmap, scale: 2, context: .default, family: "Test", combination: "test", report: &report)
        XCTAssertEqual(report.eligibleProbes, 1)
        XCTAssertEqual(report.contrastPairsChecked, 0)
        XCTAssertTrue(report.failures.keys.contains { $0.kind == .unmeasured }, report.summary)
    }

    func testGeometryIsFittedFromPixels() {
        // The fit itself: a plain continuous rectangle of known radius.
        for radius in [6.0, 9.0, 11.5, 17.0] as [CGFloat] {
            let measured = AtticCornerMeasure.measure(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.gray),
                layoutSize: CGSize(width: 120, height: 48), context: .default
            )
            XCTAssertEqual(measured?.radius ?? 0, radius, accuracy: 0.26)
            XCTAssertEqual(measured?.size.width ?? 0, 120, accuracy: 0.26)
        }
        // A deliberately wrong radius is caught.
        let wrong = AtticCornerMeasure.measure(
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.gray),
            layoutSize: CGSize(width: 36, height: 32), context: .default
        )
        XCTAssertGreaterThan(abs((wrong?.radius ?? 10) - 10), 1)
    }
}

private extension AtticRGBA {
    /// HSV saturation: 0 for a grey.
    var saturation: Double {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        return high == 0 ? 0 : (high - low) / high
    }
}

/// The named contrast exception (owner, 2026-09-26; the owner decides):
/// Phase 0's Glass and Frosted surfaces are kept exactly as Phase 0 draws
/// them. Phase 0 solved their foundation to its own floor (its primary and
/// secondary text at 3 : 1 on Glass, 3.5 : 1 on Frosted, over the measured
/// worst desktop), which is far more see-through than the design system's
/// rule allows (4.5 : 1 for text, 3 : 1 for secondary text and icons over
/// the worst desktop): Original's foundation is 1 % (Light Glass), 16 %
/// (Light Frosted), 10 % (Dark Glass) and 32 % (Dark Frosted), against the
/// 67 / 80 / 66 / 82 % the rule needs. So text and icons on the panel
/// surface, and labels on Liquid Glass controls over it, miss the rule over
/// the worst desktops on Glass and Frosted. The rule is unchanged
/// everywhere else, and menus and cards keep it on these surfaces too.
enum Phase0TranslucentException {
    static let name = "Phase 0's Glass and Frosted transparency"

    static func covers(_ context: AtticDesignContext) -> Bool {
        context.effectiveSurface != .solid
    }

    static func covers(caption: String) -> Bool {
        caption.contains(" · Glass") || caption.contains(" · Frosted")
    }

    /// The failures left once the exception's combinations are taken out.
    static func remaining(_ failures: [AtticAppearanceCheck.Failure: [String]]) -> [AtticAppearanceCheck.Failure: [String]] {
        failures.compactMapValues { combinations in
            let rest = combinations.filter { !covers(caption: $0) }
            return rest.isEmpty ? nil : rest
        }
    }
}

/// The third named contrast exception (owner fix 1, 2026-09-27; the owner
/// decides): an open task's ring (to do, and Later's dashed ring) is the
/// primary ink at low opacity, the owner's reference grey (v15 card B,
/// about 1.6 : 1 on white), below the 3 : 1 icon floor on purpose, so the
/// title carries the row. Only that ring, and never under Increase
/// Contrast, where it is the primary ink and keeps 3 : 1. Hover and
/// keyboard focus step it up; a disabled ring keeps the disabled icon's
/// 3 : 1; the subtask checkbox, the working ring and the done check keep
/// the rule.
enum OpenRingException {
    static let name = "Owner fix 1: the quiet open task ring"

    static func covers(_ failure: AtticAppearanceCheck.Failure) -> Bool {
        // Only a ring measured below the icon floor (round 4): a ring that
        // is missing or cannot be measured still fails.
        failure.detail.hasPrefix(AtticStatusCircle.openRingProbeName)
            && (failure.kind == .contrast || failure.kind == .glyphContrast)
    }

    static func remaining(_ failures: [AtticAppearanceCheck.Failure: [String]]) -> [AtticAppearanceCheck.Failure: [String]] {
        var rest = failures
        for (failure, combinations) in failures where covers(failure) {
            let kept = combinations.filter { $0.contains("Increase contrast") }
            rest[failure] = kept.isEmpty ? nil : kept
        }
        return rest
    }
}

/// The second named contrast exception (owner, 2026-09-26; the owner
/// decides): Phase 0's Light palette accents are kept exactly. As tag text
/// on the tag fills they reach 3 : 1 (the secondary-text floor) but not the
/// 4.5 : 1 every text needs under Increase Contrast, in some palettes
/// (Amethyst, Electric Blue, Porcelain Vapor, Sea Glass, Smoked Umber; worst
/// Electric Blue with the Bold Tint, 0.69 of the floor).
enum Phase0AccentException {
    static let name = "Phase 0's Light accents as tag text under Increase Contrast"

    static func covers(caption: String) -> Bool {
        caption.hasPrefix("Light") && !caption.contains("Original") && caption.contains("Increase contrast")
    }

    static func remaining(_ failures: [AtticAppearanceCheck.Failure: [String]]) -> [AtticAppearanceCheck.Failure: [String]] {
        failures.compactMapValues { combinations in
            let rest = combinations.filter { !covers(caption: $0) }
            return rest.isEmpty ? nil : rest
        }
    }
}
