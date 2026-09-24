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

    func testDecisionOptionsLeaveTheDefaultsUntouched() {
        // A3 changes only the text: its coverage is A2's.
        var a2 = AtticDesignContext(mode: .light, palette: .amethyst, surface: .glass)
        a2.translucencyPolicy = .transparencyFirst
        var a3 = a2
        a3.variant.strongerTextOnTranslucentOrTint = true
        XCTAssertEqual(a3.tokens.panel.foundationOpacity, a2.tokens.panel.foundationOpacity)
        XCTAssertEqual(a3.tokens.ink(.helper), a2.tokens.ink(.label))
        XCTAssertEqual(a3.tokens.ink(.label), a2.tokens.ink(.body))
        // On an untinted Solid panel the stronger ladder does nothing.
        var solid = AtticDesignContext(mode: .light)
        solid.variant.strongerTextOnTranslucentOrTint = true
        XCTAssertEqual(solid.tokens.ink(.helper), AtticDesignContext(mode: .light).tokens.ink(.helper))
        // B2 draws the designed tint; B1 (the default) holds it back.
        var b2 = AtticDesignContext(mode: .light, palette: .amethyst, tint: .bold)
        b2.variant.designedTintStrength = true
        XCTAssertEqual(b2.tokens.panel.tintScale, 1)
        XCTAssertLessThan(AtticDesignContext(mode: .light, palette: .amethyst, tint: .bold).tokens.panel.tintScale, 1)
    }

    /// Renders the glass-and-tint decision sheet and pins what it shows:
    /// the current rules (A1, B1) keep every text role at 4.5 : 1.
    func testDecisionSheet() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("AtticDecisions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = AtticDecisionSheet.write(to: directory)
        XCTAssertNotNil(result.url)
        print("ATTIC_DECISION_SHEET=\(result.url?.path ?? "")")
        XCTAssertFalse(result.measurements.isEmpty)
        for (key, measured) in result.measurements where key.hasPrefix("A1") || key.hasPrefix("B1") {
            for value in [measured.body, measured.helper].compactMap({ $0 }) {
                XCTAssertGreaterThanOrEqual(value, 4.49, key)
            }
            XCTAssertNotNil(measured.label, "\(key) has no label text to measure")
        }
    }

    // MARK: The appearance check

    /// Renders every family in every combination and checks contrast,
    /// clipping, overlap, sizes and radii; writes the contact sheets.
    /// Set `ATTIC_APPEARANCE_QUICK=1` to check only the curated sheet set.
    func testAppearanceCheckAndContactSheets() throws {
        let quick = ProcessInfo.processInfo.environment["ATTIC_APPEARANCE_QUICK"] == "1"
        let contexts = quick
            ? AtticAppearanceCheck.sheetContexts().map(\.context).filter { $0.translucencyPolicy == .fullContrast }
            : AtticAppearanceCheck.allContexts()
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
