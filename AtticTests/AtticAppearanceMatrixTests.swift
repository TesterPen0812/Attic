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
        // Sharded (round 4): the matrix doubled with the review switches
        // and outgrew one CI job. `ATTIC_APPEARANCE_SHARD=i/n` checks every
        // n-th combination from i; together the shards cover every one.
        // The contact sheets are drawn once, by shard 0.
        let shard = Self.shard(ProcessInfo.processInfo.environment["ATTIC_APPEARANCE_SHARD"])
        let all = AtticAppearanceCheck.allContexts()
        let contexts = all.enumerated().filter { $0.offset % shard.count == shard.index }.map(\.element)
        let started = Date()
        let report = AtticAppearanceCheck.run(contexts: contexts, scale: 2)
        let elapsed = Date().timeIntervalSince(started)

        // Application Support inside the test host's container: temporary
        // folders are purged after the run, and the host is sandboxed.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("AtticAppearance", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let drawsSheets = shard.index == 0
        let sheets = drawsSheets ? AtticAppearanceCheck.writeContactSheets(to: directory) : []
        // The panel alone, Light and Dark, at 2× (for the side-by-side with v4).
        if drawsSheets { AtticAppearanceCheck.writePanelRenders(to: directory) }
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

        XCTAssertGreaterThan(all.count, 400)
        XCTAssertEqual(report.combinations, contexts.count, "shard \(shard.index + 1) of \(shard.count)")
        if drawsSheets {
            XCTAssertEqual(sheets.count, AtticGalleryFamily.allCases.count, "Every family gets a contact sheet")
        }
        XCTAssertGreaterThan(report.glyphsMeasured, 0)
        XCTAssertEqual(report.contrastPairsChecked, report.eligibleProbes, "Every eligible probe's background was measured")
        // A glyph that cannot be read from its pixels is an `unmeasured`
        // failure in its combination, so the check below keeps every one
        // outside the named exceptions (some glyphs over Phase 0's
        // see-through Glass and Frosted are too faint to be read at all).
        XCTAssertLessThanOrEqual(report.glyphsMeasured, report.eligibleGlyphs)
        // The owner's two named contrast exceptions (see
        // `AtticDesignSystemTests`): Phase 0's see-through Glass and Frosted,
        // and Phase 0's Light accents under Increase Contrast. Nothing else
        // may fail.
        // Owner fix 1 adds a third: the quiet open task ring.
        let remaining = OpenRingException.remaining(Phase0AccentException.remaining(Phase0TranslucentException.remaining(report.failures)))
        XCTAssertTrue(remaining.isEmpty, remaining
            .map { "\($0.key.kind) \($0.key.family) › \($0.key.specimen): \($0.key.detail) in \($0.value.joined(separator: " | "))" }
            .sorted().joined(separator: "\n"))
    }

    /// "i/n" → (i, n); anything else is the whole matrix (0/1).
    nonisolated static func shard(_ value: String?) -> (index: Int, count: Int) {
        let parts = (value ?? "").split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2, parts[1] > 0, (0..<parts[1]).contains(parts[0]) else { return (0, 1) }
        return (parts[0], parts[1])
    }

    func testShardsCoverEveryCombinationOnce() {
        XCTAssertTrue(Self.shard(nil) == (0, 1))
        XCTAssertTrue(Self.shard("2/4") == (2, 4))
        XCTAssertTrue(Self.shard("4/4") == (0, 1), "out of range: the whole matrix")
        let count = 37
        let covered = (0..<4).flatMap { index in (0..<count).filter { $0 % 4 == index } }
        XCTAssertEqual(covered.sorted(), Array(0..<count))
    }
}
