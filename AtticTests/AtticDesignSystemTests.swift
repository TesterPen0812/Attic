import SwiftUI
import XCTest
@testable import Attic

/// The design system's tokens and the automated appearance check.
@MainActor
final class AtticDesignSystemTests: XCTestCase {
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
        XCTAssertEqual(AtticControlSize.panelButton, CGSize(width: 36, height: 36))
        XCTAssertEqual(AtticRadius.control(height: AtticControlSize.headerControl), 15)
        XCTAssertEqual(AtticControlSize.settingsBackButton, CGSize(width: 38, height: 34))
        XCTAssertEqual(AtticPageButton<Int>.width(open: false, count: 3), 36)
        XCTAssertEqual(AtticPageButton<Int>.width(open: true, count: 3), 96)
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

    func testMotionPresetsAreCalmSpringsWithReduceMotionFallbacks() {
        for preset in AtticMotionPreset.allCases {
            XCTAssertLessThanOrEqual(preset.duration, 0.3, "\(preset) is longer than the calm budget")
            XCTAssertEqual(preset.bounce, 0, "\(preset) bounces")
            XCTAssertNotNil(preset.animation(reduceMotion: false))
        }
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
        XCTAssertEqual(light.tabSelected.over(light.panel.base).hexString, "#EDEDED")
        XCTAssertEqual(light.tabHover.over(light.panel.base).hexString, "#F6F6F6")
        // Phase 0's drawn control look (as before visual A) over this surface.
        XCTAssertEqual(light.controlFace.hexString, "#ECECEC")
        XCTAssertEqual(light.addBarFlat.face.hexString, "#F6F6F6")
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
        XCTAssertEqual(dark.tabSelected.over(dark.panel.base).hexString, "#404040")
        XCTAssertEqual(dark.tabHover.over(dark.panel.base).hexString, "#353535")
        XCTAssertEqual(dark.controlFace.hexString, "#454545")
        XCTAssertEqual(dark.addBarFlat.face.hexString, "#343434")
        XCTAssertEqual(dark.contentCard.hexString, "#2E2E2E")
        XCTAssertEqual(dark.groupCard.hexString, "#333333")
        // Original's accent is grey.
        let accent = light.ink(.accent).hsl
        XCTAssertLessThan(accent.saturation, 0.05)
            // No green cast: every grey the default look draws is neutral.
        for tokens in [light, dark] {
            let base = tokens.panel.base
            let greys = [tokens.ink(.heading), tokens.ink(.body), tokens.ink(.helper), tokens.ink(.priorityNone), tokens.doneDisc,
                         tokens.ink(.doneCheck), tokens.controlFace, tokens.addBarFlat.face,
                         tokens.hover.over(base), tokens.selected.over(base), tokens.tabSelected.over(base), tokens.tabHover.over(base)]
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
            for pair in onControls where tokens.panel.worstMargin([pair]) < 0.999 {
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
        for context in [AtticDesignContext(mode: .light, surface: .glass), AtticDesignContext(mode: .light, tint: .bold)] {
            let tokens = context.tokens
            for ink in [AtticInk.helper, .muted, .label, .body] {
                XCTAssertGreaterThanOrEqual(tokens.ink(ink).contrast(on: solid.panel.base), solid.ink(ink).contrast(on: solid.panel.base) - 0.01, "\(context.caption) \(ink)")
            }
            // Visual A sets the plain default's heading exactly; elsewhere
            // the heading is the ladder's, which already passes everywhere.
            XCTAssertEqual(tokens.ink(.heading), AtticDesignContext(mode: .light, palette: .amethyst).tokens.ink(.heading), "Heading already passes everywhere")
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
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }

    func testGlassAndFrostedKeepThePR5Coverage() {
        for mode in AtticDesignContext.Mode.allCases {
            for surface in [PanelSurfaceStyle.glass, .frosted] {
                let panel = AtticDesignContext(mode: mode, surface: surface).tokens.panel
                XCTAssertLessThan(panel.foundationOpacity, 0.9, "\(mode) \(surface) lost its transparency")
                let increased = AtticDesignContext(mode: mode, surface: surface, increaseContrast: true).tokens.panel
                XCTAssertGreaterThanOrEqual(increased.foundationOpacity, panel.foundationOpacity)
            }
        }
        XCTAssertEqual(AtticDesignContext(mode: .light, surface: .glass, reduceTransparency: true).tokens.panel.kind, .solid)
        // The PR #5 coverage, exactly (softening secondary text must not move it).
        let measured = [
            AtticDesignContext(mode: .light, surface: .glass), AtticDesignContext(mode: .light, surface: .frosted),
            AtticDesignContext(mode: .dark, surface: .glass), AtticDesignContext(mode: .dark, surface: .frosted)
        ].map { Int(($0.tokens.panel.foundationOpacity * 100).rounded()) }
        XCTAssertEqual(measured, [67, 80, 66, 82])
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
            XCTAssertGreaterThanOrEqual(tokens.panel.worstMargin(pairs), 0.999, context.caption)
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
        XCTAssertEqual(send, CGSize(width: 28, height: 28), "Owner's decision: 28 × 28 inside the bar")
        XCTAssertEqual(send.height, AtticControlSize.addBarHeight - 2 * AtticControlSize.sendInset)
        XCTAssertEqual(AtticRadius.nested(outer: AtticRadius.control(height: AtticControlSize.addBarHeight), gap: AtticControlSize.sendInset), 11)
    }

    func testTaskKeysMapToDistinctCommands() {
        func command(_ key: KeyEquivalent, _ characters: String, _ modifiers: EventModifiers, list: Bool = true) -> AtticTaskKeys.Command? {
            AtticTaskKeys.command(key: key, characters: characters, modifiers: modifiers, listCommands: list)
        }
        XCTAssertEqual(command(.space, " ", []), .toggleDone, "Space does what the circle does: complete, or un-complete")
        XCTAssertEqual(command(.space, "\u{A0}", .option), .toggleDone, "⌥Space stays an alias")
        XCTAssertEqual(command(.space, " ", .shift), .toggleWorking, "⇧Space starts or stops working (Direction A)")
        XCTAssertEqual(command(.return, "\r", .command), .openPage)
        XCTAssertNil(command(.return, "\r", []), "Return edits the title (Phase 1), it never opens the page")
        XCTAssertEqual(command(KeyEquivalent("b"), "b", .command), .moveToBacklog)
        XCTAssertEqual(command(.delete, "\u{7F}", []), .delete)
        XCTAssertNil(command(.delete, "\u{7F}", [], list: false), "Cards in notes don't take list commands")
        XCTAssertNil(command(.space, " ", .command))
    }

    // MARK: Motion keeps layout still

    func testPageSwitchKeepsItsSizeForEverySelection() {
        let titles = AtticGallerySamples.pages.map(\.title)
        let geometry = AtticPageSwitch<Int>.Geometry(titles: titles)
        var sizes: Set<String> = []
        for page in 0..<titles.count {
            // Every chip's frame and every icon position fits in the same capsule.
            for index in 0..<titles.count {
                XCTAssertLessThanOrEqual(geometry.x(of: index, selected: page) + geometry.width(of: index, selected: page), geometry.innerWidth + 0.001)
            }
            // The label only fades: its place never depends on the selection.
            XCTAssertEqual(geometry.labelX(of: page), geometry.iconX(of: page, selected: page) + AtticPageSwitchMetrics.iconSlot + AtticPageSwitchMetrics.iconLabelGap)
            let host = NSHostingView(rootView: AtticPageSwitch(items: AtticGallerySamples.pages, selection: .constant(page)).atticDesign(.default))
            sizes.insert("\(host.fittingSize)")
        }
        XCTAssertEqual(sizes.count, 1, "The capsule is the same size whichever page is selected: \(sizes)")
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
        XCTAssertEqual(report.glyphsMeasured, report.eligibleGlyphs, "Every eligible probe's glyph was measured")
        XCTAssertEqual(report.eligibleGlyphs, report.eligibleProbes, "At 2× every eligible probe is a glyph check")
        XCTAssertGreaterThanOrEqual(report.geometryMeasured, 15)
        XCTAssertTrue(report.failures.isEmpty, report.summary)
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
