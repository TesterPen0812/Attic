import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Floating controls over the approved variable blur (owner, 2026-10-14):
/// content runs on under every page's fixed controls, top and bottom.
@MainActor
final class FloatingControlsTests: XCTestCase {
    func testTheApprovedBlurIsTheDefault() {
        XCTAssertEqual(AtticEdgeBlurMetrics.radius, 1.5, "the owner's strength, 2026-10-12")
        XCTAssertEqual(AtticEdgeBlurMetrics.reach, 28, "the owner's reach, 2026-10-12")
        XCTAssertEqual(AtticEdgeBlurMetrics.fadeShare, 0.55)
        XCTAssertEqual(AtticEdgeBlurMetrics.fadeOpacity, 0.85)
    }

    func testOnlyAPreviewTunesTheBlurAndOnlyThereIsItKept() throws {
        let suite = "AtticEdgeBlurLabTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(9.0, forKey: AtticEdgeBlurLab.radiusKey)
        defaults.set(400.0, forKey: AtticEdgeBlurLab.reachKey)

        let product = AtticEdgeBlurLab(defaults: defaults, isPreview: false, blurAvailable: true)
        XCTAssertFalse(product.offersTuning)
        XCTAssertEqual(product.radius, 1.5, "a product identity ignores a stored value")
        XCTAssertEqual(product.reach, 28)
        product.radius = 4
        XCTAssertEqual(defaults.double(forKey: AtticEdgeBlurLab.radiusKey), 9, "and keeps nothing")

        let preview = AtticEdgeBlurLab(defaults: defaults, isPreview: true, blurAvailable: true)
        XCTAssertTrue(preview.offersTuning)
        XCTAssertEqual(preview.radius, 9)
        XCTAssertEqual(preview.reach, AtticEdgeBlurLab.reachRange.upperBound, "clamped")
        preview.reach = 20
        XCTAssertEqual(defaults.double(forKey: AtticEdgeBlurLab.reachKey), 20)

        XCTAssertFalse(AtticEdgeBlurLab(defaults: defaults, isPreview: true, blurAvailable: false).offersTuning,
                       "no tuning where there is no blur")
    }

    /// Opaque panel: content is whole under glass controls (the blur and
    /// the surface fade cover it).
    func testOnAnOpaquePanelContentRunsOnUnderTheControls() {
        let edges = AtticFloatingEdges(top: 80, bottom: 60)
        let height: CGFloat = 500
        let stops = edges.stops(height: height, translucent: false)
        func opacity(_ y: CGFloat) -> Double { AtticScrollUnderFade.opacity(stops, at: y, height: height) }
        for y: CGFloat in [0, 20, 40, 80, 250, 460, 480, 500] {
            XCTAssertEqual(opacity(y), 1, accuracy: 0.001, "whole at \(y): no cut-off band")
        }
    }

    /// A plain-text line among the top controls is part of them: content
    /// is gone above its lower edge, on every surface, and whole `topRamp`
    /// below it; the blur starts at its lower edge.
    func testAPlainTopLineIsPartOfTheTopControls() {
        let edges = AtticFloatingEdges(top: 82, topPlain: 60...79, topRamp: 8)
        XCTAssertEqual(edges.topBlurStart, 79)
        for translucent in [false, true] {
            let stops = edges.stops(height: 500, translucent: translucent)
            func opacity(_ y: CGFloat) -> Double { AtticScrollUnderFade.opacity(stops, at: y, height: 500) }
            for y in stride(from: CGFloat(0), through: 79 + AtticEdgeBlurMetrics.plainClearance, by: 1) {
                XCTAssertEqual(opacity(y), 0, accuracy: 0.001, "gone at \(y) (translucent \(translucent))")
            }
            XCTAssertEqual(opacity(90), 1, accuracy: 0.001, "whole where the first row rests")
            let ramp = stride(from: CGFloat(79), through: 90, by: 1).map(opacity)
            XCTAssertEqual(ramp, ramp.sorted())
        }
        XCTAssertNil(AtticFloatingEdges(top: 80).topPlain)
        XCTAssertEqual(AtticFloatingEdges(top: 80).topBlurStart, 0, "a glass-only top blurs from the panel's edge")
    }

    /// See-through panel: no colour is painted over the glass; the content
    /// itself is gone by the controls' middle and whole at their inner edge.
    func testOnASeeThroughPanelContentFadesOutBehindTheControls() {
        let edges = AtticFloatingEdges(top: 80, bottom: 60)
        let height: CGFloat = 500
        let stops = edges.stops(height: height, translucent: true)
        func opacity(_ y: CGFloat) -> Double { AtticScrollUnderFade.opacity(stops, at: y, height: height) }
        XCTAssertEqual(opacity(0), 0, accuracy: 0.001)
        XCTAssertEqual(opacity(80 * AtticEdgeBlurMetrics.translucentGoneShare), 0, accuracy: 0.001, "gone by the header's middle")
        XCTAssertEqual(opacity(80), 1, accuracy: 0.001, "whole below the header")
        XCTAssertEqual(opacity(250), 1, accuracy: 0.001)
        XCTAssertEqual(opacity(height - 60), 1, accuracy: 0.001, "whole above the bottom row")
        XCTAssertEqual(opacity(height - 60 * AtticEdgeBlurMetrics.translucentGoneShare), 0, accuracy: 0.001)
        XCTAssertEqual(opacity(height), 0, accuracy: 0.001)
        let ramp = stride(from: CGFloat(40), through: 80, by: 1).map(opacity)
        XCTAssertEqual(ramp, ramp.sorted(), "it eases in, never back")
    }

    func testTheBlurIsStrongestAtThePanelsEdge() throws {
        func alphas(_ edge: VerticalEdge) throws -> [UInt8] {
            let image = try XCTUnwrap(AtticVariableBlurView.maskImage(height: 40, edge: edge))
            let data = try XCTUnwrap(image.dataProvider?.data as Data?)
            return (0..<image.height).map { data[$0 * image.bytesPerRow + 3] }
        }
        let top = try alphas(.top)
        XCTAssertEqual(top.first, 255)
        XCTAssertEqual(top.last, 0)
        XCTAssertEqual(top, top.sorted(by: >))
        XCTAssertEqual(try alphas(.bottom), top.reversed(), "the bottom edge's blur is the top's, mirrored")
    }

    /// Reduce Transparency, or a system without the filter: an opaque fade
    /// in the blur's place.
    func testReduceTransparencyGivesTheBlurWayToAFade() {
        XCTAssertTrue(AtticEdgeBlurBackdrop.blurs(AtticDesignContext(), available: true))
        XCTAssertFalse(AtticEdgeBlurBackdrop.blurs(AtticDesignContext(reduceTransparency: true), available: true))
        XCTAssertFalse(AtticEdgeBlurBackdrop.blurs(AtticDesignContext(), available: false))
    }

    /// Tasks: the tabs' plain line is part of the top controls; the
    /// bottom edge follows the stack, and the composer's plain strip is
    /// a plain line too.
    func testTasksEdgesFollowTheTabsAndTheBottomStack() {
        let tabsTop: CGFloat = 80
        let top = TasksViewport.topEdges(tabsTop: tabsTop)
        XCTAssertEqual(top.top, TasksViewport.controlsBottom(tabsTop: tabsTop))
        XCTAssertEqual(top.topPlain, TasksViewport.plainLine(tabsTop: tabsTop))
        XCTAssertEqual(TasksViewport.plainLine(tabsTop: tabsTop).upperBound,
                       tabsTop + AtticLayout.pageTabsHeight + AtticPageTabsMetrics.underlineHeight + AtticPageTabsMetrics.underlineGap,
                       "the underline is part of the line")
        let stops = TasksViewport.maskStops(height: 520, tabsTop: tabsTop)
        func opacity(_ y: CGFloat) -> Double { AtticScrollUnderFade.opacity(stops, at: y, height: 520) }
        XCTAssertEqual(opacity(tabsTop + AtticLayout.pageTabsHeight / 2), 0, accuracy: 0.001, "never behind the tabs")
        XCTAssertEqual(opacity(tabsTop / 2), 0, accuracy: 0.001, "nor above them, under the header")
        XCTAssertEqual(opacity(TasksViewport.controlsBottom(tabsTop: tabsTop)), 0, accuracy: 0.001,
                       "a row is gone before it touches the tabs (Find's field included)")
        XCTAssertEqual(opacity(TasksViewport.listTop(tabsTop: tabsTop)), 1, accuracy: 0.001, "a resting row is whole")
        let words = TasksViewport.listTop(tabsTop: tabsTop) + AtticTaskRowMetrics.titleTop(twoLine: false)
        XCTAssertEqual(opacity(words), 1, accuracy: 0.001, "the first row's words are whole at rest")

        let inset: CGFloat = 12
        let idle = TasksViewport.bottomEdges(stack: TasksViewport.reservedStack - AtticControlSize.smallHeight, bottomInset: inset)
        XCTAssertEqual(idle.bottom, AtticControlSize.addBarHeight + inset)
        XCTAssertNil(idle.bottomPlain, "the add bar alone is glass")
        let strip = TasksViewport.bottomEdges(stack: TasksViewport.reservedStack, bottomInset: inset)
        XCTAssertEqual(strip.bottom, TasksViewport.reservedStack + inset)
        XCTAssertEqual(strip.bottomPlain, (AtticControlSize.addBarHeight + inset)...(TasksViewport.reservedStack + inset))
    }
}
