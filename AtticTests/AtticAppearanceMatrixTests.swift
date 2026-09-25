import SwiftUI
import XCTest
@testable import Attic

/// The full appearance matrix and the owner's contact sheets.
///
/// Every family in every combination (Light and Dark × Solid, Glass and
/// Frosted × every palette × every Tint step, each with Increase Contrast,
/// Reduce Transparency and both), rendered at 2× and checked by code, plus
/// one curated contact sheet per family. It takes minutes, so it is not
/// part of the ordinary unit-test run: it runs only when
/// `ATTIC_APPEARANCE_FULL=1` reaches the test host, which
/// `Scripts/run_appearance_matrix.zsh` (and the CI appearance job) arrange.
@MainActor
final class AtticAppearanceMatrixTests: XCTestCase {
    func testFullAppearanceMatrixAndContactSheets() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ATTIC_APPEARANCE_FULL"] == "1",
            "The full matrix runs separately: Scripts/run_appearance_matrix.zsh"
        )
        let started = Date()
        let report = AtticAppearanceCheck.run(scale: 2)
        let elapsed = Date().timeIntervalSince(started)

        // Application Support inside the test host's container: temporary
        // folders are purged after the run, and the host is sandboxed.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("AtticAppearance", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sheets = AtticAppearanceCheck.writeContactSheets(to: directory)
        // The panel alone, Light and Dark, at 2× (for the side-by-side with v4).
        AtticAppearanceCheck.writePanelRenders(to: directory)
        let summary = report.summary
            + String(format: "\n\nChecked in %.0f s.\nContact sheets:\n", elapsed)
            + sheets.map(\.lastPathComponent).joined(separator: "\n")
        try summary.write(to: directory.appendingPathComponent("appearance-check.txt"), atomically: true, encoding: .utf8)
        print("ATTIC_APPEARANCE_OUTPUT=\(directory.path)")
        print(summary)

        let attachment = XCTAttachment(string: summary)
        attachment.name = "appearance-check.txt"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThan(report.combinations, 400)
        XCTAssertEqual(sheets.count, AtticGalleryFamily.allCases.count, "Every family gets a contact sheet")
        XCTAssertGreaterThan(report.glyphsMeasured, 0)
        XCTAssertEqual(report.contrastPairsChecked, report.eligibleProbes, "Every eligible probe's background was measured")
        XCTAssertEqual(report.glyphsMeasured, report.eligibleGlyphs, "Every eligible probe's glyph was measured")
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }
}
