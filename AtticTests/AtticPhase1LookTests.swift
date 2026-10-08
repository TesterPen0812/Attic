import SwiftUI
import XCTest
@testable import Attic

/// The Phase 1 look the owner kept in round 6 (the review switches became
/// the design): Readable Glass, quiet inactive controls, the compact
/// Appearance page, the explicit Phase 1 command names and the defined
/// dark edge; and the Glass and Frosted text roles (owner item 7).
@MainActor
final class AtticPhase1LookTests: XCTestCase {
    // MARK: Readable Glass (Astra 11)

    /// Glass and Frosted keep enough of their own colour that Phase 0's
    /// primary text keeps 4.5 : 1 and its secondary text 3 : 1 (4.5 under
    /// Increase Contrast) over every desktop, and only as much as that
    /// needs: only the foundation grows from Phase 0's.
    func testReadableGlassAddsOnlyTheBackingTheTextNeeds() {
        var checked = 0
        for context in AtticAppearanceCheck.allContexts() where context.isTranslucent {
            let phase0 = AtticSurfaceModel.phase0(AtticDesignSystemTests.phase0Treatment(context), increaseContrast: context.increaseContrast)
                .definedDarkEdge()
            let panel = context.tokens.panel
            XCTAssertEqual(panel.withFoundation(phase0.foundationOpacity).withDarkTint(0), phase0,
                           "only the foundation (and Dark's dark tint, A37) changes: \(context.caption)")
            XCTAssertGreaterThanOrEqual(panel.foundationOpacity, phase0.foundationOpacity, context.caption)
            let tokens = context.tokens
            let pairs = [
                AtticSurfaceModel.Pair(ink: .heading, foreground: tokens.ink(.heading), overlays: []),
                AtticSurfaceModel.Pair(ink: context.increaseContrast ? .heading : .helper, foreground: tokens.ink(.helper), overlays: [])
            ]
            XCTAssertGreaterThanOrEqual(panel.worstMargin(pairs), 1, context.caption)
            if panel.foundationOpacity > phase0.foundationOpacity + 0.001 {
                XCTAssertLessThan(panel.withDarkTint(0).withFoundation(panel.foundationOpacity - 0.01).worstMargin(pairs), AtticSurfaceModel.solverMargin,
                                  "the least backing that passes: \(context.caption)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 50)
        // Original's backing (Light Glass, Light Frosted, Dark Glass, Dark
        // Frosted): still see-through, far below the rule's 67 / 80 / 66 / 82 %.
        let opacities = [(AtticDesignContext.Mode.light, PanelSurfaceStyle.glass), (.light, .frosted), (.dark, .glass), (.dark, .frosted)].map { mode, surface in
            Int((AtticDesignContext(mode: mode, surface: surface).tokens.panel.foundationOpacity * 100).rounded())
        }
        XCTAssertEqual(opacities.count, 4)
        for (opacity, rule) in zip(opacities, [67, 80, 66, 82]) {
            XCTAssertLessThan(opacity, rule)
        }
    }

    // MARK: Dark's dark tint (A37)

    /// A37 (owner, 2026-10-08, "Dark-mode glass keeps light text
    /// readable"): in Dark, Glass and Frosted lay the least black over the
    /// readable foundation at which Phase 0's primary text keeps 4.5 : 1 and
    /// its secondary text 3 : 1 (4.5 under Increase Contrast) even over a
    /// white window the glass passes straight through. Light, Solid and
    /// Reduce Transparency draw no dark tint, and Light's surface is exactly
    /// what it was.
    func testDarkGlassAndFrostedGetTheLeastDarkTintThatKeepsTextReadable() {
        var dark = 0
        for context in AtticAppearanceCheck.allContexts() {
            let panel = context.tokens.panel
            guard context.mode == .dark, context.isTranslucent else {
                XCTAssertEqual(panel.darkTint, 0, "no dark tint: \(context.caption)")
                if panel.kind != .solid {
                    XCTAssertEqual(panel.backing, panel.base.withAlpha(panel.foundationOpacity),
                                   "the backing is the foundation, unchanged: \(context.caption)")
                }
                continue
            }
            let tokens = context.tokens
            let pairs = [
                AtticSurfaceModel.Pair(ink: .heading, foreground: tokens.ink(.heading), overlays: []),
                AtticSurfaceModel.Pair(ink: context.increaseContrast ? .heading : .helper, foreground: tokens.ink(.helper), overlays: [])
            ]
            XCTAssertGreaterThanOrEqual(panel.passedThroughMargin(pairs), AtticSurfaceModel.solverMargin, context.caption)
            for height in [AtticSurfaceModel.contentTop, 1] {
                let background = panel.compositeOverPassedThroughWindow(at: height)
                XCTAssertGreaterThanOrEqual(tokens.ink(.heading).contrast(on: background), 4.5, "body text AA: \(context.caption)")
                XCTAssertGreaterThanOrEqual(tokens.ink(.helper).contrast(on: background), context.increaseContrast ? 4.5 : 3, context.caption)
            }
            if panel.darkTint > 0 {
                XCTAssertLessThan(panel.withDarkTint(panel.darkTint - 0.005).passedThroughMargin(pairs), AtticSurfaceModel.solverMargin,
                                  "the lightest tint that passes: \(context.caption)")
            }
            // Still glass: some of the window shows through.
            XCTAssertLessThan(panel.backing.alpha, 1, context.caption)
            // Over every modelled desktop the text is never harder to read.
            XCTAssertGreaterThanOrEqual(panel.worstMargin(pairs), panel.withDarkTint(0).worstMargin(pairs) - 1e-9, context.caption)
            dark += 1
        }
        XCTAssertGreaterThan(dark, 20)
        // Reduce Transparency draws Solid: no tint over it, nothing doubles up.
        let reduced = AtticDesignContext(mode: .dark, surface: .glass, reduceTransparency: true).tokens.panel
        XCTAssertEqual(reduced.kind, .solid)
        XCTAssertEqual(reduced.darkTint, 0)
        XCTAssertEqual(reduced.composite(.white), reduced.base)
    }

    /// The default (Original, Glass, Tint Off) and Frosted in Dark, pinned:
    /// the tint each needs, white text over a white window before (the
    /// readable foundation alone) and after, and Light untouched.
    func testDarkTintPinnedForOriginal() {
        func numbers(_ context: AtticDesignContext) -> (tint: Double, before: Double, after: Double) {
            let panel = context.tokens.panel
            let ink = context.tokens.ink(.heading)
            let height = AtticSurfaceModel.contentTop
            return (panel.darkTint,
                    ink.contrast(on: panel.withDarkTint(0).compositeOverPassedThroughWindow(at: height)),
                    ink.contrast(on: panel.compositeOverPassedThroughWindow(at: height)))
        }
        for surface in [PanelSurfaceStyle.glass, .frosted] {
            let dark = numbers(AtticDesignContext(mode: .dark, surface: surface))
            let light = AtticDesignContext(mode: .light, surface: surface).tokens.panel
            print(String(format: "A37 Dark %@: tint %.3f, foundation %.3f, before %.2f : 1, after %.2f : 1",
                         surface.title, dark.tint, AtticDesignContext(mode: .dark, surface: surface).tokens.panel.foundationOpacity,
                         dark.before, dark.after))
            XCTAssertLessThan(dark.before, 4.5, "\(surface): the problem the owner saw")
            XCTAssertGreaterThanOrEqual(dark.after, 4.5, "\(surface)")
            XCTAssertLessThan(dark.after, 4.5 * AtticSurfaceModel.solverMargin * 1.06, "\(surface): no darker than it needs")
            XCTAssertEqual(light.darkTint, 0)
        }
    }

    // MARK: Glass and Frosted text roles (owner item 7, Astra 11)

    /// Every secondary text role on Glass and Frosted reads as Phase 0's
    /// secondary grey: tags, the quietest grey, dates,
    /// "Completed today", inactive tabs. A Dark palette's tags keep their hue
    /// at the secondary grey's lightness; Light palettes keep Phase 0's accent.
    func testGlassAndFrostedSecondaryTextIsPhase0sSecondaryGrey() {
        for mode in AtticDesignContext.Mode.allCases {
            let appearance: AtticPanelThemeAppearance = mode == .dark ? .dark : .light
            for palette in AtticPanelTheme.allCases {
                let p0 = palette.palette(for: appearance)
                let secondary = AtticRGBA(p0.secondaryForeground)
                for surface in [PanelSurfaceStyle.glass, .frosted] {
                    let tokens = AtticDesignContext(mode: mode, palette: palette, surface: surface).tokens
                    let label = "\(mode) \(palette) \(surface)"
                    for ink in [AtticInk.helper, .placeholder, .muted] {
                        XCTAssertEqual(tokens.ink(ink), secondary, "\(label) \(ink)")
                    }
                    if palette == .original {
                        XCTAssertEqual(tokens.ink(.accentText), secondary, label)
                    } else if mode == .light {
                        XCTAssertEqual(tokens.ink(.accentText), AtticRGBA(p0.accent), label)
                    } else {
                        let base = AtticRGBA(p0.opaqueSurface)
                        XCTAssertGreaterThanOrEqual(tokens.ink(.accentText).contrast(on: base), secondary.contrast(on: base) - 0.01, label)
                        XCTAssertNotEqual(tokens.ink(.accentText), secondary, "\(label): the tag keeps its hue")
                    }
                    // A step below the primary.
                    let base = AtticRGBA(p0.opaqueSurface)
                    XCTAssertLessThan(tokens.ink(.helper).contrast(on: base), tokens.ink(.heading).contrast(on: base), label)
                }
            }
        }
    }

    /// The colours of meaning (overdue, the High mark, warnings) keep their
    /// floors on Glass and Frosted over a mid-grey desktop, and keep their
    /// hue (black and white desktops stay in the named exception).
    func testColoursOfMeaningKeepTheirFloorsOnGlass() {
        for context in AtticAppearanceCheck.allContexts() where context.isTranslucent {
            let tokens = context.tokens
            XCTAssertGreaterThan(tokens.ink(.dueText).hsl.saturation, 0.3, "overdue stays red · \(context.caption)")
            let desktops: [AtticSurfaceModel.Desktop] = [.midGrey]
            // Under Increase Contrast High's orange mark stays orange, inside
            // the named translucency exception (`Phase0TranslucentException`).
            for ink in [AtticInk.dueText, .priorityMark, .warningText] where !(ink == .priorityMark && context.increaseContrast) {
                let floor = AtticSurfaceModel.floor(for: ink, kind: context.effectiveSurface, increaseContrast: context.increaseContrast)
                for desktop in desktops {
                    for height in [AtticSurfaceModel.contentTop, 1] {
                        let ratio = tokens.ink(ink).contrast(on: tokens.panel.composite(desktop, at: height))
                        XCTAssertGreaterThanOrEqual(ratio, floor * 0.999, "\(context.caption) \(ink) over \(desktop)")
                    }
                }
            }
        }
    }

    /// The composited contrast the report quotes (owner item 7): the text
    /// roles over black, mid-grey and white desktops, Glass and Frosted,
    /// with and without Increase Contrast. Attached to
    /// the test run and printed for the report.
    func testGlassContrastReport() {
        var lines = ["mode|surface|palette|IC|foundation|role|ink|black|midGrey|white"]
        for mode in AtticDesignContext.Mode.allCases {
            for surface in [PanelSurfaceStyle.glass, .frosted] {
                for palette in [AtticPanelTheme.original, .midnightCobalt] {
                    for ic in [false, true] {
                        let context = AtticDesignContext(mode: mode, palette: palette, surface: surface, increaseContrast: ic)
                        let tokens = context.tokens
                        for (role, ink) in [("title", AtticInk.body), ("secondary", .helper), ("tag", .accentText), ("overdue", .dueText)] {
                            let ratios = AtticSurfaceModel.Desktop.allCases.map { desktop in
                                String(format: "%.2f", tokens.ink(ink).contrast(on: tokens.panel.composite(desktop, at: AtticSurfaceModel.contentTop)))
                            }
                            lines.append(([mode.title, PanelSurfaceStyle(context.effectiveSurface).title, palette.title, ic ? "IC" : "-",
                                           "\(Int((tokens.panel.foundationOpacity * 100).rounded())) %", role, tokens.ink(ink).hexString] + ratios)
                                .joined(separator: "|"))
                        }
                    }
                }
            }
        }
        let text = lines.joined(separator: "\n")
        print("GLASS-CONTRAST-REPORT-BEGIN\n\(text)\nGLASS-CONTRAST-REPORT-END")
        let attachment = XCTAttachment(string: text)
        attachment.name = "glass-contrast-report"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Quiet inactive controls (Astra 27)

    /// The drawn (out-of-focus) controls keep one even edge at the side's
    /// strength: no nested rim and no lower-edge shadow. Increase Contrast
    /// keeps its full, stronger edge.
    func testQuietInactiveControlsKeepOneEdge() {
        for mode in AtticDesignContext.Mode.allCases {
            let tokens = AtticDesignContext(mode: mode).tokens
            for recipe in [tokens.raised, tokens.raisedHover, tokens.raisedPressed, tokens.raisedDisabled] {
                XCTAssertEqual(recipe.edgeTop, recipe.edgeMiddle, "\(mode): one even edge")
                XCTAssertEqual(recipe.edgeBottom, recipe.edgeMiddle, "\(mode)")
                XCTAssertEqual(recipe.innerRimTop.alpha, 0, "\(mode): no nested rim")
                XCTAssertEqual(recipe.innerRimMiddle.alpha, 0, "\(mode)")
                XCTAssertEqual(recipe.innerRimBottom.alpha, 0, "\(mode)")
                XCTAssertEqual(recipe.shadow.alpha, 0, "\(mode): no lower-edge shadow")
            }
            let ic = AtticDesignContext(mode: mode, increaseContrast: true).tokens.raised
            XCTAssertNotEqual(ic.edgeBottom, ic.edgeMiddle, "\(mode): Increase Contrast keeps its heavier lower edge")
        }
    }

    // MARK: Defined dark edge (CU review, visual 4)

    func testTheDarkGlassEdgeIsAClearerPaletteEdge() throws {
        for palette in AtticPanelTheme.allCases {
            for surface in [PanelSurfaceStyle.glass, .frosted] {
                let context = AtticDesignContext(mode: .dark, palette: palette, surface: surface)
                let phase0 = AtticSurfaceModel.phase0(AtticDesignSystemTests.phase0Treatment(context), increaseContrast: false)
                let edge = try XCTUnwrap(context.tokens.panel.edge), hairline = try XCTUnwrap(phase0.edge)
                XCTAssertGreaterThan(edge.color.alpha, hairline.color.alpha, "\(palette) \(surface)")
                XCTAssertEqual(edge.color.withAlpha(1), hairline.color.withAlpha(1), "the palette's own edge colour")
                XCTAssertEqual(edge.width, 1)
                XCTAssertNotNil(edge.innerHighlight)
            }
            // Light keeps Phase 0's hairline.
            let light = AtticDesignContext(mode: .light, palette: palette, surface: .frosted)
            XCTAssertEqual(light.tokens.panel.edge,
                           AtticSurfaceModel.phase0(AtticDesignSystemTests.phase0Treatment(light), increaseContrast: false).edge)
        }
    }

    // MARK: Compact Appearance page (Astra 26)

    func testAppearanceStartsTwentyFourPointsUnderTheHeader() {
        XCTAssertEqual(AtticSettingsPageMetrics.contentTop + AtticSpacing.s12, 52, "other pages keep the spec's 52")
        XCTAssertEqual(AtticSettingsPageMetrics.compactContentTop + AtticSpacing.s12, 24)
    }

    // MARK: Explicit Phase 1 command names (Astra 25)

    func testTheMenuBarSaysWhatSearchOpens() {
        let menu = MenuBarCommands.commands(advertisedNewTaskShortcut: nil, showPanel: {}, newTask: {}, newNote: {},
                                            search: {}, openSettings: {}, quit: {})
        XCTAssertEqual(menu.map(\.title), ["Show Attic", "New task", "New note", "Search Done Tasks…", "Open", "Settings…", "Quit Attic"])
    }

    /// One design: every combination once (the full matrix's own guard).
    func testTheAppearanceMatrixChecksOneDesign() {
        let all = AtticAppearanceCheck.allContexts()
        XCTAssertEqual(Set(all.map(\.caption)).count, all.count)
        XCTAssertGreaterThan(all.count, 400)
        print("APPEARANCE-CONTEXTS \(all.count)")
    }

    func testSettingsHasNoComparePage() {
        XCTAssertEqual(SettingsSection.allCases.last, .about)
        XCTAssertEqual(SettingsSection.restored(from: "compare"), .general, "a remembered Compare page opens General")
    }
}
