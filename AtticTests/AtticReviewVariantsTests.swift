import SwiftUI
import XCTest
@testable import Attic

/// The temporary review switches (`AtticReviewVariants`) and the Glass and
/// Frosted text roles (owner item 7, Astra 11, 25, 26, 27): each switch in
/// both states, off being exactly the decided design.
@MainActor
final class AtticReviewVariantsTests: XCTestCase {
    // MARK: Registry and persistence

    func testEverySwitchDefaultsToTheSuggestionAndOffIsTheDecidedDesign() {
        for variant in AtticReviewVariant.allCases {
            XCTAssertTrue(AtticReviewVariants.defaults.isOn(variant), variant.rawValue)
            XCTAssertFalse(AtticReviewVariants.decided.isOn(variant), variant.rawValue)
            XCTAssertTrue(variant.summary.hasPrefix("On: "), variant.rawValue)
            XCTAssertTrue(variant.summary.contains(" Off: "), variant.rawValue)
        }
        XCTAssertEqual(AtticDesignContext().variants, .defaults)
        XCTAssertEqual(AtticReviewVariant.allCases.map(\.title),
                       ["Readable Glass", "Quiet Inactive Controls", "Compact Appearance", "Explicit Phase 1 Labels", "Defined Dark Edge"])
    }

    func testSwitchesPersistOnlyWhereTheyDifferFromTheirDefault() throws {
        let suite = "AtticReviewVariantsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.reviewVariants, .defaults)
        XCTAssertNil(defaults.object(forKey: "reviewVariants"))
        settings.reviewVariants.set(.readableGlass, false)
        XCTAssertEqual(defaults.dictionary(forKey: "reviewVariants") as? [String: Bool], ["readableGlass": false])
        XCTAssertFalse(AppSettings(defaults: defaults).reviewVariants.isOn(.readableGlass), "kept across launches")
        XCTAssertTrue(AppSettings(defaults: defaults).reviewVariants.isOn(.compactAppearance))
        settings.reviewVariants.set(.readableGlass, true)
        XCTAssertNil(defaults.object(forKey: "reviewVariants"), "back at every default: nothing stored")
        // Unknown and malformed entries are ignored.
        defaults.set(["gone": false, "quietInactiveControls": "no"], forKey: "reviewVariants")
        XCTAssertEqual(AppSettings(defaults: defaults).reviewVariants, .defaults)
    }

    func testCompareIsTheLastSettingsPage() {
        XCTAssertEqual(SettingsSection.allCases.last, .compare)
        XCTAssertEqual(SettingsSection.compare.title, "Compare (temporary)")
        XCTAssertNil(SettingsSection.compare.group, "apart from the groups, under About")
    }

    // MARK: Readable Glass (Astra 11)

    /// On, Glass and Frosted keep enough of their own colour that Phase 0's
    /// primary text keeps 4.5 : 1 and its secondary text 3 : 1 (4.5 under
    /// Increase Contrast) over every desktop, and only as much as that
    /// needs; off, the surface is Phase 0's exactly.
    func testReadableGlassAddsOnlyTheBackingTheTextNeeds() {
        var checked = 0
        for context in AtticAppearanceCheck.allContexts() where context.isTranslucent && context.colourKey.readableGlass {
            var off = context
            off.variants = context.variants.with(.readableGlass, false)
            let panel = context.tokens.panel
            let decided = off.tokens.panel
            XCTAssertEqual(panel.withFoundation(decided.foundationOpacity), decided, "only the foundation changes: \(context.caption)")
            XCTAssertGreaterThanOrEqual(panel.foundationOpacity, decided.foundationOpacity, context.caption)
            let tokens = context.tokens
            let pairs = [
                AtticSurfaceModel.Pair(ink: .heading, foreground: tokens.ink(.heading), overlays: []),
                AtticSurfaceModel.Pair(ink: context.increaseContrast ? .heading : .helper, foreground: tokens.ink(.helper), overlays: [])
            ]
            XCTAssertGreaterThanOrEqual(panel.worstMargin(pairs), 1, context.caption)
            if panel.foundationOpacity > decided.foundationOpacity + 0.001 {
                XCTAssertLessThan(panel.withFoundation(panel.foundationOpacity - 0.01).worstMargin(pairs), AtticSurfaceModel.solverMargin,
                                  "the least backing that passes: \(context.caption)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 100)
        // Solid is never touched.
        XCTAssertEqual(AtticDesignContext(mode: .dark).tokens.panel, AtticDesignContext(mode: .dark, variants: .decided).tokens.panel)
        // Original's backing, off → on (Light Glass, Light Frosted, Dark
        // Glass, Dark Frosted): still see-through, far below the rule's
        // 67 / 80 / 66 / 82 %.
        let opacities = [(AtticDesignContext.Mode.light, PanelSurfaceStyle.glass), (.light, .frosted), (.dark, .glass), (.dark, .frosted)].map { mode, surface in
            Int((AtticDesignContext(mode: mode, surface: surface).tokens.panel.foundationOpacity * 100).rounded())
        }
        XCTAssertEqual(opacities.count, 4)
        for (opacity, rule) in zip(opacities, [67, 80, 66, 82]) {
            XCTAssertLessThan(opacity, rule)
        }
    }

    // MARK: Glass and Frosted text roles (owner item 7, Astra 11)

    /// Every secondary text role on Glass and Frosted reads as Phase 0's
    /// secondary grey, whatever the switch: tags, the quietest grey, dates,
    /// "Completed today", inactive tabs. A Dark palette's tags keep their hue
    /// at the secondary grey's lightness; Light palettes keep Phase 0's accent.
    func testGlassAndFrostedSecondaryTextIsPhase0sSecondaryGrey() {
        for variants in [AtticReviewVariants.decided, .defaults] {
            for mode in AtticDesignContext.Mode.allCases {
                let appearance: AtticPanelThemeAppearance = mode == .dark ? .dark : .light
                for palette in AtticPanelTheme.allCases {
                    let p0 = palette.palette(for: appearance)
                    let secondary = AtticRGBA(p0.secondaryForeground)
                    for surface in [PanelSurfaceStyle.glass, .frosted] {
                        let tokens = AtticDesignContext(mode: mode, palette: palette, surface: surface, variants: variants).tokens
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
    /// with and without Readable Glass and Increase Contrast. Attached to
    /// the test run and printed for the report.
    func testGlassContrastReport() {
        var lines = ["mode|surface|palette|IC|readable|foundation|role|ink|black|midGrey|white"]
        for mode in AtticDesignContext.Mode.allCases {
            for surface in [PanelSurfaceStyle.glass, .frosted] {
                for palette in [AtticPanelTheme.original, .midnightCobalt] {
                    for ic in [false, true] {
                        for variants in [AtticReviewVariants.decided, .defaults] {
                            let context = AtticDesignContext(mode: mode, palette: palette, surface: surface, increaseContrast: ic, variants: variants)
                            let tokens = context.tokens
                            for (role, ink) in [("title", AtticInk.body), ("secondary", .helper), ("tag", .accentText), ("overdue", .dueText)] {
                                let ratios = AtticSurfaceModel.Desktop.allCases.map { desktop in
                                    String(format: "%.2f", tokens.ink(ink).contrast(on: tokens.panel.composite(desktop, at: AtticSurfaceModel.contentTop)))
                                }
                                lines.append(([mode.title, PanelSurfaceStyle(context.effectiveSurface).title, palette.title, ic ? "IC" : "-",
                                               variants.isOn(.readableGlass) ? "on" : "off",
                                               "\(Int((tokens.panel.foundationOpacity * 100).rounded())) %", role, tokens.ink(ink).hexString] + ratios)
                                    .joined(separator: "|"))
                            }
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

    // MARK: Quiet Inactive Controls (Astra 27)

    func testQuietInactiveControlsKeepOneEdgeAndThePinnedChip() {
        for mode in AtticDesignContext.Mode.allCases {
            let quiet = AtticDesignContext(mode: mode).tokens
            let decided = AtticDesignContext(mode: mode, variants: .decided).tokens
            for (q, d) in [(quiet.raised, decided.raised), (quiet.raisedHover, decided.raisedHover),
                           (quiet.raisedPressed, decided.raisedPressed), (quiet.raisedDisabled, decided.raisedDisabled)] {
                XCTAssertEqual(q.edgeTop, d.edgeMiddle, "\(mode): one even edge at the side's strength")
                XCTAssertEqual(q.edgeBottom, d.edgeMiddle, "\(mode)")
                XCTAssertEqual(q.innerRimTop.alpha, 0, "\(mode): no nested rim")
                XCTAssertEqual(q.innerRimBottom.alpha, 0, "\(mode)")
                XCTAssertEqual(q.shadow.alpha, 0, "\(mode): no lower-edge shadow")
                XCTAssertEqual(q.fill, d.fill, "\(mode): the face is unchanged")
                XCTAssertEqual(q.base, d.base, "\(mode)")
            }
            XCTAssertEqual(quiet.chipSelected, decided.chipSelected, "\(mode): the pinned pin's chip is unchanged")
            XCTAssertEqual(quiet.controlFace, decided.controlFace, "\(mode)")
            // Off is exactly today's drawn controls (a Light rim and shadow).
            if mode == .light {
                XCTAssertGreaterThan(decided.raised.innerRimTop.alpha, 0)
                XCTAssertGreaterThan(decided.raised.shadow.alpha, 0)
            }
            // Increase Contrast keeps its stronger edge.
            let icQuiet = AtticDesignContext(mode: mode, increaseContrast: true).tokens.raised
            let icDecided = AtticDesignContext(mode: mode, increaseContrast: true, variants: .decided).tokens.raised
            XCTAssertEqual(icQuiet, icDecided, "\(mode)")
        }
    }

    // MARK: Defined Dark Edge (CU review, visual 4)

    func testDefinedDarkEdgeIsAClearerPaletteEdgeOnDarkGlassOnly() throws {
        for palette in AtticPanelTheme.allCases {
            for surface in [PanelSurfaceStyle.glass, .frosted] {
                let on = AtticDesignContext(mode: .dark, palette: palette, surface: surface).tokens.panel
                let off = AtticDesignContext(mode: .dark, palette: palette, surface: surface, variants: AtticReviewVariants.defaults.with(.definedDarkEdge, false)).tokens.panel
                let edgeOn = try XCTUnwrap(on.edge), edgeOff = try XCTUnwrap(off.edge)
                XCTAssertGreaterThan(edgeOn.color.alpha, edgeOff.color.alpha, "\(palette) \(surface)")
                XCTAssertEqual(edgeOn.color.withAlpha(1), edgeOff.color.withAlpha(1), "the palette's own edge colour")
                XCTAssertNotNil(edgeOn.innerHighlight)
                XCTAssertNil(edgeOff.innerHighlight)
                var copy = on; copy.edge = off.edge
                XCTAssertEqual(copy, off, "only the edge changes")
            }
            // Light, and Dark Solid, are untouched.
            XCTAssertEqual(AtticDesignContext(mode: .light, palette: palette, surface: .frosted).tokens.panel.edge,
                           AtticDesignContext(mode: .light, palette: palette, surface: .frosted, variants: AtticReviewVariants.defaults.with(.definedDarkEdge, false)).tokens.panel.edge)
        }
    }

    // MARK: Compact Appearance (Astra 26)

    func testCompactAppearanceStartsTwentyFourPointsUnderTheHeader() {
        XCTAssertEqual(AtticSettingsPageMetrics.contentTop + AtticSpacing.s12, 52)
        XCTAssertEqual(AtticSettingsPageMetrics.compactContentTop + AtticSpacing.s12, 24)
    }

    // MARK: Explicit Phase 1 Labels (Astra 25)

    func testExplicitPhase1LabelsNameWhatTheCommandsOpenToday() {
        let on = AtticReviewVariants.defaults
        let off = AtticReviewVariants.decided
        XCTAssertEqual(AtticPhase1Labels.search(on), "Search Done Tasks…")
        XCTAssertEqual(AtticPhase1Labels.search(off), "Search")
        XCTAssertEqual(AtticPhase1Labels.openLiveTask(on), "Open Files…")
        XCTAssertEqual(AtticPhase1Labels.openLiveTask(off), "Open Page")
        XCTAssertEqual(AtticPhase1Labels.openLiveTaskAction(on), "Open files")
        XCTAssertEqual(AtticPhase1Labels.openLiveTaskAction(off), "Open page")
        XCTAssertEqual(AtticPhase1Labels.showArchivedDetails(on), "Show Details")
        XCTAssertEqual(AtticPhase1Labels.showArchivedDetails(off), "Open Page")
        XCTAssertEqual(AtticPhase1Labels.showArchivedDetailsAction(on), "Show details")

        func menu(_ variants: AtticReviewVariants) -> [AtticMenuCommand] {
            MenuBarCommands.commands(advertisedNewTaskShortcut: nil, variants: variants,
                                     showPanel: {}, newTask: {}, newNote: {}, search: {}, openSettings: {}, quit: {})
        }
        XCTAssertEqual(menu(on).map(\.title), ["Show Attic", "New task", "New note", "Search Done Tasks…", "Settings…", "Quit Attic"])
        XCTAssertEqual(menu(off)[3].title, "Search")
        XCTAssertEqual(menu(on).map(\.shortcut), menu(off).map(\.shortcut), "shortcuts unchanged")
        XCTAssertEqual(menu(on).map(\.systemImage), menu(off).map(\.systemImage))
    }
}
