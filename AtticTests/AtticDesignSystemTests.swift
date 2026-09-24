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
                XCTAssertEqual(tokens.contentCard, base.contentCard)
                XCTAssertEqual(tokens.groupCard, base.groupCard)
                for ink in [AtticInk.heading, .body, .label, .helper, .glyph] {
                    XCTAssertEqual(tokens.ink(ink), base.ink(ink), "\(palette) changed \(ink)")
                }
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

    func testGlassAndFrostedStaySeeThrough() {
        for mode in AtticDesignContext.Mode.allCases {
            for surface in [PanelSurfaceStyle.glass, .frosted] {
                let panel = AtticDesignContext(mode: mode, surface: surface).tokens.panel
                XCTAssertLessThan(panel.foundationOpacity, 1, "\(mode) \(surface) became opaque")
            }
        }
        XCTAssertEqual(AtticDesignContext(mode: .light, surface: .glass, reduceTransparency: true).tokens.panel.kind, .solid)
    }

    // MARK: The appearance check

    /// Renders every family in every combination and checks contrast,
    /// clipping, overlap, sizes and radii; writes the contact sheets.
    /// Set `ATTIC_APPEARANCE_QUICK=1` to check only the curated sheet set.
    func testAppearanceCheckAndContactSheets() throws {
        let quick = ProcessInfo.processInfo.environment["ATTIC_APPEARANCE_QUICK"] == "1"
        let contexts = quick ? AtticAppearanceCheck.sheetContexts().map(\.context) : AtticAppearanceCheck.allContexts()
        let started = Date()
        let report = AtticAppearanceCheck.run(contexts: contexts)
        let elapsed = Date().timeIntervalSince(started)

        // Application Support inside the test host's container: temporary
        // folders are purged after the run, and the host is sandboxed.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("AtticAppearance", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sheets = AtticAppearanceCheck.writeContactSheets(to: directory)
        let summary = report.summary + String(format: "\n\nChecked in %.0f s.\nContact sheets:\n", elapsed) + sheets.map(\.path).joined(separator: "\n")
        try summary.write(to: directory.appendingPathComponent("appearance-check.txt"), atomically: true, encoding: .utf8)
        print("ATTIC_APPEARANCE_OUTPUT=\(directory.path)")
        print(summary)

        let attachment = XCTAttachment(string: summary)
        attachment.name = "appearance-check.txt"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(sheets.count, AtticGalleryFamily.allCases.count, "Every family gets a contact sheet")
        XCTAssertGreaterThan(report.contrastPairsChecked, 0)
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }
}
