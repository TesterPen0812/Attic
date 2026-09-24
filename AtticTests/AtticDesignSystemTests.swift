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

    func testControlCornersFollowThirtyTwoPercentOfHeight() {
        XCTAssertEqual(AtticRadius.control(height: 32), 10)
        XCTAssertEqual(AtticRadius.control(height: 34), 11)
        XCTAssertEqual(AtticRadius.control(height: 36), 11.5)
        XCTAssertEqual(AtticRadius.control(height: 28), 9)
        XCTAssertEqual(AtticRadius.control(height: 18), 6)
        XCTAssertEqual(AtticRadius.nested(outer: 10, gap: 4), 6)
        XCTAssertNil(AtticRadius.nested(outer: 20, gap: 12), "Nesting only applies to gaps of 6 pt or less")
        XCTAssertEqual(AtticRadius.ring(around: 10, offset: 4), 14)
        XCTAssertEqual([AtticRadius.menu, AtticRadius.groupCard, AtticRadius.contentCard, AtticRadius.image, AtticRadius.highlight], [20, 17, 10, 8, 10])
    }

    func testControlSizesAreWiderThanTall() {
        for size in [AtticControlSize.panelButton, AtticControlSize.settingsBackButton] {
            XCTAssertGreaterThan(size.width / size.height, 1.1)
            XCTAssertLessThan(size.width / size.height, 1.2)
        }
        XCTAssertEqual(AtticLayout.rowPitch, AtticLayout.rowHighlightHeight + 2)
        XCTAssertEqual(AtticLayout.textX, AtticLayout.circleX + AtticControlSize.statusCircle + AtticSpacing.gap10)
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

    func testDefaultLadderMatchesTheSpecWhereItCan() {
        let light = AtticDesignContext(mode: .light).tokens
        XCTAssertEqual(light.panel.base.hexString, "#FAFAFA")
        XCTAssertEqual(light.ink(.heading).hexString, "#1E1F1F")
        XCTAssertEqual(light.ink(.body).hexString, "#494B4A")
        XCTAssertEqual(light.contentCard.hexString, "#FBFBFB")
        XCTAssertEqual(light.groupCard.hexString, "#F2F2F2")
        let dark = AtticDesignContext(mode: .dark).tokens
        XCTAssertEqual(dark.panel.base.hexString, "#2C2C2D")
        XCTAssertEqual(dark.ink(.heading).hexString, "#F5F5F5")
        XCTAssertEqual(dark.ink(.body).hexString, "#D5D5D5")
        XCTAssertEqual(dark.contentCard.hexString, "#2E2E2E")
        XCTAssertEqual(dark.groupCard.hexString, "#333333")
        // Original's accent is grey.
        let accent = light.ink(.accent).hsl
        XCTAssertLessThan(accent.saturation, 0.05)
    }

    func testCustomisationChangesOnlyTheBackgroundAndTheAccent() {
        let base = AtticDesignContext(mode: .light).tokens
        for palette in AtticPanelTheme.allCases {
            for surface in PanelSurfaceStyle.allCases {
                let tokens = AtticDesignContext(mode: .light, palette: palette, surface: surface, tint: .bold).tokens
                XCTAssertEqual(tokens.raised, base.raised, "\(palette) changed the controls")
                XCTAssertEqual(tokens.controlBase, base.controlBase, "\(palette) tinted the controls")
                XCTAssertEqual(tokens.contentCard, base.contentCard)
                XCTAssertEqual(tokens.groupCard, base.groupCard)
            }
            // On the plain Solid look a palette changes no text at all.
            let solid = AtticDesignContext(mode: .light, palette: palette).tokens
            for ink in [AtticInk.heading, .body, .label, .helper, .glyph] {
                XCTAssertEqual(solid.ink(ink), base.ink(ink), "\(palette) changed \(ink)")
            }
        }
    }

    func testTranslucentAndTintedPanelsStepTheTextOneShadeStronger() {
        let solid = AtticDesignContext(mode: .light).tokens
        for context in [AtticDesignContext(mode: .light, surface: .glass), AtticDesignContext(mode: .light, tint: .bold)] {
            let tokens = context.tokens
            XCTAssertGreaterThanOrEqual(tokens.ink(.helper).contrast(on: solid.panel.base), solid.ink(.label).contrast(on: solid.panel.base) - 0.01, context.caption)
            XCTAssertGreaterThanOrEqual(tokens.ink(.label).contrast(on: solid.panel.base), solid.ink(.body).contrast(on: solid.panel.base) - 0.01, context.caption)
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
        XCTAssertEqual(AtticRadius.nested(outer: AtticRadius.control(height: AtticControlSize.addBarHeight), gap: AtticControlSize.sendInset), 7.5)
    }

    func testTaskKeysMapToDistinctCommands() {
        func command(_ key: KeyEquivalent, _ characters: String, _ modifiers: EventModifiers, list: Bool = true) -> AtticTaskKeys.Command? {
            AtticTaskKeys.command(key: key, characters: characters, modifiers: modifiers, listCommands: list)
        }
        XCTAssertEqual(command(.space, " ", []), .advance)
        XCTAssertEqual(command(.space, "\u{A0}", .option), .complete)
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
            let view = AtticAddBar(placeholder: "Add a task…", text: .constant(text), onSubmit: {})
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
