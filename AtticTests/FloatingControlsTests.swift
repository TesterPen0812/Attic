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

    /// The owner's 10-17 decision: content shows under every control,
    /// blurred, with no fade hiding it, on every surface: no surface fade
    /// over the blur on an opaque panel, and no content fade on a
    /// see-through one (T-03 C). The pixels: `RoundO3ControlsTests`.
    func testWithTheBlurNothingButTheBlurIsDrawnUnderTheControls() {
        for surface in PanelSurfaceStyle.allCases {
            for mode in [AtticDesignContext.Mode.light, .dark] {
                let design = AtticDesignContext(mode: mode, surface: surface)
                XCTAssertTrue(AtticEdgeBlurBackdrop.blurs(design, available: true), "\(surface) \(mode)")
                XCTAssertFalse(AtticEdgeBlurBackdrop.drawsSolidSurface(design, available: true), "\(surface) \(mode): no fade")
                let contrast = AtticDesignContext(mode: mode, surface: surface, increaseContrast: true)
                XCTAssertFalse(AtticEdgeBlurBackdrop.drawsSolidSurface(contrast, available: true), "\(surface) \(mode): Increase Contrast too")
            }
        }
    }

    /// A plain-text line among the top controls is part of them: the blur
    /// covers it, from the panel's edge (owner, 2026-10-17: content is no
    /// longer gone above its lower edge).
    func testAPlainTopLineIsPartOfTheTopControls() {
        let tabsTop: CGFloat = 80
        XCTAssertGreaterThanOrEqual(TasksViewport.topEdges(tabsTop: tabsTop).top, TasksViewport.plainLine(tabsTop: tabsTop).upperBound)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 520))
        XCTAssertGreaterThanOrEqual(NoteHistoryPage.edges(layout).top, NoteHistoryPage.versionLine(layout).upperBound)
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
    /// in the blur's place (U-02), the deliberate look with no blur.
    func testReduceTransparencyGivesTheBlurWayToAFade() {
        XCTAssertTrue(AtticEdgeBlurBackdrop.blurs(AtticDesignContext(), available: true))
        XCTAssertFalse(AtticEdgeBlurBackdrop.blurs(AtticDesignContext(reduceTransparency: true), available: true))
        XCTAssertFalse(AtticEdgeBlurBackdrop.blurs(AtticDesignContext(), available: false))
        for surface in PanelSurfaceStyle.allCases {
            XCTAssertTrue(AtticEdgeBlurBackdrop.drawsSolidSurface(AtticDesignContext(surface: surface, reduceTransparency: true), available: true),
                          "\(surface): solid under the controls with Reduce Transparency")
        }
    }

    /// Tasks: the tabs' plain line is part of the top controls; the
    /// bottom edge follows the stack, the composer's strip included.
    func testTasksEdgesFollowTheTabsAndTheBottomStack() {
        let tabsTop: CGFloat = 80
        let top = TasksViewport.topEdges(tabsTop: tabsTop)
        XCTAssertEqual(top.top, TasksViewport.controlsBottom(tabsTop: tabsTop))
        XCTAssertEqual(TasksViewport.plainLine(tabsTop: tabsTop).upperBound,
                       tabsTop + AtticLayout.pageTabsHeight + AtticPageTabsMetrics.underlineHeight + AtticPageTabsMetrics.underlineGap,
                       "the underline is part of the line")
        XCTAssertGreaterThanOrEqual(top.top, TasksViewport.plainLine(tabsTop: tabsTop).upperBound)
        XCTAssertGreaterThan(TasksViewport.listTop(tabsTop: tabsTop), TasksViewport.plainLine(tabsTop: tabsTop).upperBound,
                             "a resting row is clear of the line")

        let inset: CGFloat = 12
        let idle = TasksViewport.bottomEdges(stack: TasksViewport.reservedStack - AtticControlSize.smallHeight, bottomInset: inset)
        XCTAssertEqual(idle.bottom, AtticControlSize.addBarHeight + inset)
        let strip = TasksViewport.bottomEdges(stack: TasksViewport.reservedStack, bottomInset: inset)
        XCTAssertEqual(strip.bottom, TasksViewport.reservedStack + inset, "the strip is part of the bottom controls")
    }

    /// U-02: with no blur (Reduce Transparency) the surface is solid under
    /// the controls, out to their inner edge, and gone 12 pt past it, so no
    /// text shows sharp behind a control and the title's rest (16 below
    /// the header) is untouched.
    func testWithoutTheBlurTheSurfaceIsSolidUnderTheControls() {
        let extent: CGFloat = 52, height = extent + AtticEdgeBlurMetrics.reach
        let stops = AtticEdgeBlurBackdrop.solidStops(height: height, extent: extent)
        XCTAssertEqual(stops.solid * height, extent, accuracy: 0.01)
        XCTAssertEqual(stops.clear * height, extent + AtticEdgeBlurMetrics.solidFade, accuracy: 0.01)
        XCTAssertLessThan(AtticEdgeBlurMetrics.solidFade, AtticNoteMetrics.titleTopGap, "the resting title stays clear")
    }

    /// U-02: under Reduce Transparency a raised control lies on the panel's
    /// solid surface; otherwise its recipe is unchanged.
    func testReduceTransparencyMakesRaisedControlsOpaque() throws {
        var design = AtticDesignContext(mode: .dark)
        let plain = design.tokens.raised
        XCTAssertEqual(plain.opaque(design), plain)
        design.reduceTransparency = true
        let opaque = design.tokens.raised.opaque(design)
        let base = try XCTUnwrap(opaque.base)
        XCTAssertEqual(base.alpha, 1)
        XCTAssertEqual(opaque.fill, design.tokens.raised.fill)
    }
}
