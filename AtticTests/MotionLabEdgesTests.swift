import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The Motion Lab's "Edges" (owner, 2026-09-30: "I thought we decided the
/// scrolling content would be fading behind the controls and be slightly
/// visible"): each option applies its own mask to the task lists and to
/// Notes, Soft fade is the default, Blur and fade adds the edge blur, and
/// Reduce Transparency always gets a solid band.
@MainActor
final class MotionLabEdgesTests: XCTestCase {
    // The Tasks page's geometry as the panel lays it out: tabs at 80 (16
    // tall), rows resting at 110, the add bar and its 12 pt margin (48).
    private let height: CGFloat = 520
    private let tabsTop: CGFloat = 80
    private let listTop: CGFloat = 110

    private func opacity(_ stops: [(location: CGFloat, opacity: Double)], at y: CGFloat, height: CGFloat) -> Double {
        let x = y / height
        for (a, b) in zip(stops, stops.dropFirst()) where x <= b.location {
            let t = Double((x - a.location) / max(b.location - a.location, 0.000001))
            return a.opacity + (b.opacity - a.opacity) * min(max(t, 0), 1)
        }
        return stops.last?.opacity ?? 1
    }

    private func tasksStops(_ style: AtticEdgeStyle, stack: CGFloat = 48) -> [(location: CGFloat, opacity: Double)] {
        TasksViewport.maskStops(height: height, tabsTop: tabsTop, listTop: listTop, bottomStack: stack, style: style)
    }

    // MARK: - Each option's mask

    /// Clean cut is round 13 exactly: nothing under the tabs or the bar.
    func testCleanCutIsRoundThirteen() {
        let round13 = TasksViewport.maskStops(height: height, tabsTop: tabsTop, listTop: listTop, bottomStack: 48)
        let clean = tasksStops(.cleanCut)
        XCTAssertEqual(clean.map(\.location), round13.map(\.location))
        XCTAssertEqual(clean.map(\.opacity), round13.map(\.opacity))
        XCTAssertEqual(opacity(clean, at: tabsTop + 8, height: height), 0, accuracy: 0.001, "nothing under the labels")
        XCTAssertEqual(opacity(clean, at: height - 48 + 6, height: height), 0, accuracy: 0.001, "nothing under the bar")
    }

    /// Soft fade: rows run under both bands, visible in the gap, at most
    /// 15 % where the labels begin, all but gone at their middle, nothing
    /// behind them or under the header, and every resting row whole. The
    /// ramp is eased: it leaves the resting rows flat (no start line).
    func testSoftFadeRunsRowsUnderTheBandsAndNeverUnderTheLabelsLegibly() {
        for stack in [CGFloat(48), 84, 120] {
            let stops = tasksStops(.softFade, stack: stack)
            let o = { self.opacity(stops, at: $0, height: self.height) }
            let tabsBottom = tabsTop + AtticLayout.pageTabsHeight
            let barTop = height - stack
            // Resting rows.
            XCTAssertEqual(o(listTop), 1, accuracy: 0.001, "the first row rests whole")
            XCTAssertEqual(o(barTop - AtticLayout.contentToAddBar - 2), 1, accuracy: 0.001, "the last row rests whole")
            XCTAssertGreaterThan(o(listTop - 1), 0.97, "eased out of the resting rows, no start line")
            // Visible, fading, in the gap to the band.
            XCTAssertTrue((0.3...0.9).contains(o(listTop - 7)), "softly visible under the tabs' band: \(o(listTop - 7))")
            XCTAssertTrue((0.3...0.95).contains(o(barTop - 8)), "softly visible over the bar: \(o(barTop - 8))")
            // Under the labels: never legible.
            let tabs = stride(from: tabsTop, through: tabsBottom, by: 0.5).map(o)
            XCTAssertLessThanOrEqual(tabs.max() ?? 1, AtticEdgeBlur.labelOpacity + 0.01, "under Now Later Done")
            XCTAssertLessThan(o(tabsTop + AtticLayout.pageTabsHeight / 2), 0.06, "the labels' middle")
            let bar = stride(from: barTop + TasksViewport.stackLabelNear, through: barTop + TasksViewport.stackLabelFar, by: 0.5).map(o)
            XCTAssertLessThanOrEqual(bar.max() ?? 1, AtticEdgeBlur.labelOpacity + 0.01, "under the bottom stack's labels")
            // Nothing behind the controls or under the header.
            XCTAssertEqual(o(tabsTop - 1), 0, accuracy: 0.001)
            XCTAssertEqual(o(20), 0, accuracy: 0.001, "the header")
            XCTAssertEqual(o(barTop + TasksViewport.stackLabelFar + 1), 0, accuracy: 0.001)
            XCTAssertEqual(o(height - 1), 0, accuracy: 0.001)
            // Monotonic ramps.
            let rising = stride(from: CGFloat(0), through: listTop, by: 0.5).map(o)
            XCTAssertEqual(rising, rising.sorted(), "the top ramp only rises")
            let falling = stride(from: barTop - 20, through: height, by: 0.5).map(o)
            XCTAssertEqual(falling, falling.sorted(by: >), "the bottom ramp only falls")
        }
    }

    /// Blur and fade: the soft fade's mask, plus the edge blur growing from
    /// where rows rest (none) to just behind the controls (whole).
    func testBlurAndFadeIsTheSoftMaskWithTheEdgeBlur() {
        let soft = tasksStops(.softFade), blur = tasksStops(.blurFade)
        XCTAssertEqual(blur.map(\.location), soft.map(\.location))
        XCTAssertEqual(blur.map(\.opacity), soft.map(\.opacity))
        XCTAssertNotEqual(soft.map(\.opacity), tasksStops(.cleanCut).map(\.opacity), "Soft fade is its own mask")
        XCTAssertTrue(AtticEdgeStyle.blurFade.blurs)
        XCTAssertFalse(AtticEdgeStyle.softFade.blurs)
        XCTAssertFalse(AtticEdgeStyle.cleanCut.blurs)
        let bands = TasksViewport.edgeBands(tabsTop: tabsTop, listTop: listTop, bottomStack: 48)
        XCTAssertEqual(bands.top.blurDepth(atDistance: listTop), 0)
        XCTAssertEqual(bands.top.blurDepth(atDistance: tabsTop), 1)
        XCTAssertGreaterThan(bands.top.blurDepth(atDistance: tabsTop + 8), 0.5, "well blurred under the labels")
        XCTAssertEqual(bands.bottom.blurDepth(atDistance: 48 + AtticLayout.contentToAddBar), 0)
        XCTAssertEqual(bands.bottom.blurDepth(atDistance: 48 - TasksViewport.stackLabelFar), 1)
    }

    /// The mask view reads the style from the design context: rendered
    /// over a solid column, it shows each option's opacity, and Reduce
    /// Transparency (and Increase Contrast) draw a solid band.
    func testTheEdgeMaskAppliesEachOptionAndReduceTransparencyIsSolid() throws {
        let band = AtticEdgeBand(labelFar: 20, labelNear: 40, controls: 40, rest: 60)
        func alpha(_ style: AtticEdgeStyle, at y: Int, reduceTransparency: Bool = false, increaseContrast: Bool = false) throws -> Double {
            var context = AtticDesignContext(mode: .light)
            context.edges = style
            context.reduceTransparency = reduceTransparency
            context.increaseContrast = increaseContrast
            let view = Color.black.frame(width: 4, height: 100)
                .mask(AtticEdgeMask(top: band))
                .atticDesign(context)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            return Double(try XCTUnwrap(rep.colorAt(x: 2, y: y)).alphaComponent)
        }
        for style in AtticEdgeStyle.allCases {
            XCTAssertEqual(try alpha(style, at: 80), 1, accuracy: 0.02, "\(style): resting content whole")
            XCTAssertEqual(try alpha(style, at: 10), 0, accuracy: 0.02, "\(style): nothing behind the controls")
        }
        XCTAssertEqual(try alpha(.cleanCut, at: 38), 0, accuracy: 0.02, "Clean cut: nothing under the labels")
        XCTAssertEqual(try alpha(.cleanCut, at: 50), 1, accuracy: 0.02)
        for style in [AtticEdgeStyle.softFade, .blurFade] {
            XCTAssertTrue((0.3...0.9).contains(try alpha(style, at: 50)), "\(style): softly visible in the band")
            XCTAssertLessThanOrEqual(try alpha(style, at: 40), 0.2, "\(style): faint where the labels begin")
            XCTAssertEqual(try alpha(style, at: 50, reduceTransparency: true), 1, accuracy: 0.02, "\(style): Reduce Transparency cuts")
            XCTAssertEqual(try alpha(style, at: 38, reduceTransparency: true), 0, accuracy: 0.02, "\(style): a solid band")
            XCTAssertEqual(try alpha(style, at: 38, increaseContrast: true), 0, accuracy: 0.02, "\(style): Increase Contrast too")
        }
    }

    /// Reduce Transparency resolves every option to the solid band.
    func testReduceTransparencyResolvesToASolidBand() {
        for style in AtticEdgeStyle.allCases {
            var context = AtticDesignContext()
            context.edges = style
            XCTAssertEqual(context.effectiveEdges, style)
            context.reduceTransparency = true
            XCTAssertEqual(context.effectiveEdges, .cleanCut)
            XCTAssertFalse(context.effectiveEdges.blurs, "no blur on a solid band")
        }
        XCTAssertEqual(AtticDesignContext().edges, .softFade, "Soft fade is the default")
        XCTAssertEqual(AtticEdgeStyle.recommended, .softFade)
    }

    // MARK: - Notes

    /// Notes' header and composer buttons take the same soft fade, and
    /// the saved-notes drawer's buttons too.
    func testNotesFadeUnderTheHeaderAndTheButtons() {
        let height: CGFloat = 560
        let header = NotesEdgeLayout.header(headerTop: 12, headerBottom: 48, rest: 76)
        let composer = NotesEdgeLayout.composer(bottomInset: 12, controlHeight: AtticStyle.composerControlHeight)
        let stops = AtticEdgeBand.maskStops(height: height, top: header, bottom: composer, style: .softFade)
        let o = { self.opacity(stops, at: $0, height: height) }
        XCTAssertEqual(o(76), 1, accuracy: 0.001)
        XCTAssertLessThanOrEqual(o(48), AtticEdgeBlur.labelOpacity + 0.01)
        XCTAssertEqual(o(11), 0, accuracy: 0.001)
        XCTAssertTrue((0.3...0.95).contains(o(62)), "visible under the header's band: \(o(62))")
        XCTAssertEqual(o(height - composer.rest), 1, accuracy: 0.001)
        XCTAssertLessThanOrEqual(o(height - composer.labelNear), AtticEdgeBlur.labelOpacity + 0.01)
        XCTAssertEqual(o(height - 12), 0, accuracy: 0.001)
        let clean = AtticEdgeBand.maskStops(height: height, top: header, bottom: composer, style: .cleanCut)
        XCTAssertEqual(opacity(clean, at: 47, height: height), 0, accuracy: 0.001, "Clean cut: nothing under the header")
        XCTAssertEqual(opacity(clean, at: 76, height: height), 1, accuracy: 0.001)
        let drawer = SavedNotesDrawerLayout.edgeBand
        XCTAssertLessThan(drawer.labelFar, drawer.labelNear)
        XCTAssertLessThanOrEqual(drawer.labelNear, drawer.controls)
        XCTAssertLessThanOrEqual(drawer.controls, drawer.rest)
        XCTAssertLessThanOrEqual(drawer.softOpacity(atDistance: drawer.labelNear), AtticEdgeBlur.labelOpacity + 0.001)
    }

    // MARK: - The lab

    /// The choice persists in a preview; outside the lab it is never read
    /// or written, and the app runs Soft fade.
    func testTheEdgesPersistOnlyInTheLab() throws {
        let suite = "MotionLabEdgesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lab = AppSettings(defaults: defaults, motionLabAvailable: true)
        XCTAssertEqual(lab.edgeStyle, .softFade)
        lab.edgeStyle = .blurFade
        XCTAssertEqual(AppSettings(defaults: defaults, motionLabAvailable: true).edgeStyle, .blurFade, "the preview keeps it")
        let release = AppSettings(defaults: defaults, motionLabAvailable: false)
        XCTAssertEqual(release.edgeStyle, .softFade)
        release.edgeStyle = .cleanCut
        XCTAssertEqual(defaults.string(forKey: "motionLabEdges"), AtticEdgeStyle.blurFade.rawValue, "nothing written outside the lab")
    }
}
