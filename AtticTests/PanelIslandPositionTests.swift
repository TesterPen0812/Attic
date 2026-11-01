import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Island position (Planning.md, Accepted 2026-11-01 "Island position: seven
/// spots around the panel"): a setting puts the island at one of seven spots
/// named by the screen corner (screen side or open side, at the corner end,
/// middle or far end; or flat across the open end). The spots mirror with
/// the corner. The island is 8 pt from the panel; on the screen side 8 pt
/// from the edge with the panel's side edge 43 pt in, anywhere else the
/// panel goes back to 12 pt. The panel and the island hide into the corner
/// of the two together nearest the screen corner.
@MainActor
final class PanelIslandPositionTests: XCTestCase {
    private typealias L = PanelIslandLayout
    private let size = CGSize(width: 340, height: 560)

    // MARK: Frame math: 4 corners × 7 spots

    private func placed(in visible: CGRect, corner: ScreenCorner, spot: PanelIslandSpot)
        -> (panel: CGRect, island: CGRect) {
        let area = L.panelArea(in: visible, corner: corner, spot: spot)
        let panel = PanelGeometry.panelFrame(in: area, size: size, corner: corner)
        return (panel, L.islandFrame(panelFrame: panel, corner: corner, spot: spot))
    }

    func testEverySpotInEveryCornerPlacesTheIslandThePanelAndTheLabel() {
        for visible in [CGRect(x: 0, y: 0, width: 1440, height: 875), CGRect(x: -1920, y: -200, width: 1920, height: 1055)] {
            for corner in ScreenCorner.allCases {
                for spot in PanelIslandSpot.allCases {
                    assertSpot(spot, corner: corner, visible: visible)
                }
            }
        }
    }

    private func assertSpot(_ spot: PanelIslandSpot, corner: ScreenCorner, visible: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        let (panel, island) = placed(in: visible, corner: corner, spot: spot)
        let what = "\(corner) \(spot)"
        let right = L.isOnRight(corner), top = L.isTop(corner)
        func eq(_ a: CGFloat, _ b: CGFloat, _ note: String) {
            XCTAssertEqual(a, b, accuracy: 0.01, "\(what): \(note)", file: file, line: line)
        }
        // The panel: 43 pt in on the screen side, else 12; 12 from the top or bottom.
        let sideInset = right ? visible.maxX - panel.maxX : panel.minX - visible.minX
        eq(sideInset, spot.side == .screen ? 43 : PanelGeometry.screenInset, "the panel's side edge")
        eq(top ? visible.maxY - panel.maxY : panel.minY - visible.minY, PanelGeometry.screenInset, "the panel's end")
        eq(panel.width, size.width, "the panel keeps its size")
        // The island: 27 × 99, or 99 × 27 lying flat.
        eq(island.width, spot.isFlat ? 99 : 27, "width")
        eq(island.height, spot.isFlat ? 27 : 99, "height")
        switch spot.side {
        case .screen:
            eq(right ? island.minX - panel.maxX : panel.minX - island.maxX, 8, "8 pt from the panel")
            eq(right ? visible.maxX - island.maxX : island.minX - visible.minX, 8, "8 pt from the edge")
        case .open:
            eq(right ? panel.minX - island.maxX : island.minX - panel.maxX, 8, "8 pt from the panel, on its open side")
        case .across:
            eq(island.midX, panel.midX, "centred")
            if top { eq(panel.minY - island.maxY, 8, "8 pt below the panel") } else { eq(island.minY - panel.maxY, 8, "8 pt above") }
        }
        if !spot.isFlat {
            switch spot.position {
            case .cornerEnd: top ? eq(island.maxY, panel.maxY, "at the top") : eq(island.minY, panel.minY, "at the bottom")
            case .middle: eq(island.midY, panel.midY, "at the middle")
            case .farEnd: top ? eq(island.minY, panel.minY, "at the bottom") : eq(island.maxY, panel.maxY, "at the top")
            }
        }
        XCTAssertTrue(visible.contains(island), "\(what): on screen", file: file, line: line)
        XCTAssertFalse(island.intersects(panel), "\(what): never on the panel", file: file, line: line)
        // The docked window's margin holds it, on whichever side it sits.
        XCTAssertTrue(panel.insetBy(dx: -AtticStyle.dockedPanelMargin, dy: -AtticStyle.dockedPanelMargin).contains(island),
                      "\(what): inside the panel window's margin", file: file, line: line)
        // The gap between them counts as the panel's.
        let gap = L.gapFrame(panelFrame: panel, corner: corner, spot: spot)
        XCTAssertFalse(gap.intersects(panel) || gap.intersects(island), "\(what): the gap is between", file: file, line: line)
        XCTAssertTrue(gap.insetBy(dx: -0.5, dy: -0.5).intersects(panel) && gap.insetBy(dx: -0.5, dy: -0.5).intersects(island),
                      "\(what): the gap touches both", file: file, line: line)
        // Items: the pages' order, top to bottom, or left to right lying flat.
        let items = L.pages.indices.map { L.itemFrame($0, in: island) }
        for (index, item) in items.enumerated() {
            XCTAssertTrue(island.contains(item), "\(what): item \(index) in the capsule", file: file, line: line)
            eq(item.width, 21, "item size")
            if index > 0 {
                if spot.isFlat { eq(item.minX - items[index - 1].maxX, 3, "left to right") }
                else { eq(items[index - 1].minY - item.maxY, 3, "top to bottom") }
            }
        }
        // The label shows on the panel's side; lying flat, over the panel.
        let side = L.labelSide(corner: corner, spot: spot)
        let label = L.labelWindowFrame(island: island, corner: corner, spot: spot)
        switch side {
        case .left:
            XCTAssertLessThan(panel.midX, island.midX, "\(what): the panel is left", file: file, line: line)
            eq(island.minX - label.maxX, 6, "the label, left")
        case .right:
            XCTAssertGreaterThan(panel.midX, island.midX, "\(what): the panel is right", file: file, line: line)
            eq(label.minX - island.maxX, 6, "the label, right")
        case .above:
            XCTAssertTrue(spot.isFlat && top, "\(what)", file: file, line: line)
            eq(label.minY - island.maxY, 6, "the label, above")
            eq(label.midX, island.midX, "the labels over their items")
            XCTAssertTrue(label.intersects(panel), "\(what): over the panel", file: file, line: line)
        case .below:
            XCTAssertTrue(spot.isFlat && !top, "\(what)", file: file, line: line)
            eq(island.minY - label.maxY, 6, "the label, below")
            eq(label.midX, island.midX, "the labels over their items")
            XCTAssertTrue(label.intersects(panel), "\(what): over the panel", file: file, line: line)
        }
        // They hide into the corner of the two together nearest the screen corner.
        let anchor = L.collapseAnchor(panelFrame: panel, corner: corner, spot: spot)
        let union = panel.union(island)
        eq(anchor.x, right ? union.maxX : union.minX, "the anchor's x")
        eq(anchor.y, top ? union.maxY : union.minY, "the anchor's y")
    }

    /// The spots are named by the screen corner: the screen side is always
    /// the side by the screen's edge, and the across spot flips in the
    /// bottom corners.
    func testTheSpotsMirrorWithTheCorner() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        for spot in PanelIslandSpot.allCases {
            let tr = placed(in: visible, corner: .topRight, spot: spot)
            for corner in ScreenCorner.allCases {
                let other = placed(in: visible, corner: corner, spot: spot)
                // Mirror the top-right placement into `corner`.
                func mirror(_ rect: CGRect) -> CGRect {
                    var rect = rect
                    if !L.isOnRight(corner) { rect.origin.x = visible.maxX - rect.maxX + visible.minX }
                    if !L.isTop(corner) { rect.origin.y = visible.maxY - rect.maxY + visible.minY }
                    return rect
                }
                XCTAssertEqual(other.panel, mirror(tr.panel), "\(spot) \(corner): the panel mirrors")
                XCTAssertEqual(other.island, mirror(tr.island), "\(spot) \(corner): the island mirrors")
            }
        }
    }

    // MARK: The setting

    func testTheSpotPersistsDefaultsToTodaysPlaceAndHasNames() throws {
        let suite = "PanelIslandPosition.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppSettings(defaults: defaults).islandSpot, .screenSideCornerEnd, "today's place")
        let settings = AppSettings(defaults: defaults)
        settings.islandSpot = .openSideMiddle
        XCTAssertEqual(AppSettings(defaults: defaults).islandSpot, .openSideMiddle, "kept")
        settings.corner = .bottomLeft
        XCTAssertEqual(AppSettings(defaults: defaults).islandSpot, .openSideMiddle, "a corner change keeps the spot")
        defaults.set("leftish", forKey: "panelIslandSpot")
        XCTAssertEqual(AppSettings(defaults: defaults).islandSpot, .screenSideCornerEnd, "an unknown value is today's place")
        XCTAssertEqual(PanelIslandSpot.openSideMiddle.title, "Open side, middle")
        XCTAssertEqual(Set(PanelIslandSpot.allCases.map(\.title)).count, 7)
    }

    // MARK: In the app

    /// A new spot moves the island there at once (Reduce Motion or not),
    /// and the panel's side edge goes to 12 pt or back to 43 pt. Moving the
    /// panel to another corner keeps the spot, mirrored.
    func testChoosingASpotMovesTheIslandAndThePanelAtOnceAndACornerChangeMirrorsIt() throws {
        for reduceMotion in [false, true] {
            try withController { controller, state, panel, settings in
                AtticMotionPreference.systemReduceMotionOverride = reduceMotion
                let windows = controller.islandWindowsForTesting
                let screen = try XCTUnwrap(controller.currentScreen)
                let visible = TestPresentationPolicy.placementFrame(screen.visibleFrame)
                for (spot, corner) in [(PanelIslandSpot.acrossOpenEnd, ScreenCorner.topRight), (.openSideFarEnd, .topRight),
                                       (.openSideFarEnd, .bottomLeft), (.screenSideMiddle, .bottomLeft),
                                       (.acrossOpenEnd, .bottomLeft), (.screenSideCornerEnd, .topRight)] {
                    let note = "\(spot) \(corner) reduce motion \(reduceMotion)"
                    if settings.islandSpot != spot {
                        settings.islandSpot = spot
                        spin(0.05)
                    }
                    if controller.currentCorner != corner {
                        var hidden = false
                        _ = controller.requestHide { hidden = $0 == .hidden }
                        spin(until: { hidden })
                        XCTAssertTrue(controller.show(on: screen, corner: corner))
                        spin(1)
                    }
                    let surface = panel.visibleContentFrame
                    XCTAssertEqual(windows.spot, spot, note)
                    XCTAssertEqual(settings.islandSpot, spot, "\(note): stored as chosen")
                    XCTAssertEqual(windows.islandFrame, L.islandFrame(panelFrame: surface, corner: corner, spot: spot), note)
                    XCTAssertEqual(windows.island.frame, windows.islandFrame.insetBy(dx: -L.windowMargin, dy: -L.windowMargin), note)
                    XCTAssertEqual(windows.label.frame, L.labelWindowFrame(island: windows.islandFrame, corner: corner, spot: spot), note)
                    XCTAssertEqual(state.island.isFlat, spot.isFlat, note)
                    XCTAssertEqual(state.island.labelSide, L.labelSide(corner: corner, spot: spot), note)
                    let right = L.isOnRight(corner)
                    let inset = right ? visible.maxX - surface.maxX : surface.minX - visible.minX
                    XCTAssertEqual(inset, spot.side == .screen ? 43 : 12, accuracy: 0.5, "\(note): the panel's side edge")
                    // The stand-in waits over the island, transparent.
                    let container = try content(panel)
                    XCTAssertFalse(container.isIslandStandInShown, note)
                    XCTAssertEqual(windows.standIn.frame, local(windows.island.frame, in: panel), "\(note): the stand-in waits over it")
                }
            }
        }
    }

    /// Lying flat, the island draws its items in a row and VoiceOver still
    /// presses them; its capsule takes the pointer and its clear margin and
    /// the space around it pass clicks through.
    func testLyingFlatTheItemsSitInARowAndTheClearSpacePassesClicks() throws {
        try withController(configure: { $0.islandSpot = .acrossOpenEnd }) { controller, state, panel, _ in
            let windows = controller.islandWindowsForTesting
            let capsule = windows.islandFrame
            XCTAssertGreaterThan(capsule.width, capsule.height, "flat")
            let host = try XCTUnwrap(windows.island.contentView)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, capsule.width + 2 * L.windowMargin, accuracy: 0.5, "the capsule lies flat")
            XCTAssertEqual(host.fittingSize.height, capsule.height + 2 * L.windowMargin, accuracy: 0.5)
            let notes = L.itemFrame(L.pages.firstIndex(of: .notes)!, in: capsule)
            XCTAssertEqual(PanelIslandPullTracker.page(at: CGPoint(x: notes.midX, y: notes.midY), in: capsule), .notes)
            XCTAssertTrue(controller.containsScreenPoint(CGPoint(x: notes.midX, y: notes.midY)), "pointing at it is pointing at the panel")
            // The 8 pt gap above it stays on the panel; beside it is outside.
            let gap = CGPoint(x: capsule.midX, y: capsule.maxY + L.panelGap / 2)
            XCTAssertFalse(panel.visibleContentFrame.contains(gap))
            XCTAssertTrue(controller.containsScreenPoint(gap), "the gap to the island")
            let beside = CGPoint(x: capsule.maxX + 20, y: capsule.midY)
            XCTAssertTrue(panel.frame.contains(beside), "in the panel window's margin")
            XCTAssertFalse(controller.containsScreenPoint(beside), "beside the island is outside the panel")
            controller.updateMousePassthrough(at: beside)
            XCTAssertTrue(panel.ignoresMouseEvents, "the margin passes clicks through")
            let inMargin = CGPoint(x: capsule.midX, y: capsule.minY - L.windowMargin / 2)
            controller.updateMousePassthrough(at: inMargin)
            XCTAssertTrue(windows.island.ignoresMouseEvents, "the island's clear margin passes clicks through")
            controller.updateMousePassthrough(at: CGPoint(x: notes.midX, y: notes.midY))
            XCTAssertFalse(windows.island.ignoresMouseEvents, "the capsule takes the pointer")
            XCTAssertFalse(panel.ignoresMouseEvents)
            // VoiceOver presses an item.
            let item = try XCTUnwrap(elements(host).first { ($0.accessibilityIdentifier?() ?? "") == PanelPage.notes.accessibilityIdentifier })
            XCTAssertTrue(item.accessibilityPerformPress?() ?? false)
            spin(0.6)
            XCTAssertEqual(state.selectedSection, .notes)
        }
    }

    /// The motion's anchor is the corner of the panel and the island
    /// together nearest the screen corner. At sampled fractions of Slide
    /// and Swoop the stand-in is over the island, the island stays inside
    /// the panel's window, and Slide scales both about that point.
    func testSlideAndSwoopHideBothIntoTheCornerOfTheTwoTogether() throws {
        for mode in [PanelHideAnimation.slide, .swoop] {
            for spot in [PanelIslandSpot.openSideFarEnd, .acrossOpenEnd, .screenSideFarEnd] {
                try withController(configure: { $0.hideAnimation = mode; $0.islandSpot = spot }) { controller, _, panel, _ in
                    let screen = try XCTUnwrap(controller.currentScreen)
                    for corner in [ScreenCorner.topRight, .bottomLeft] {
                        if corner != .topRight {
                            var hidden = false
                            _ = controller.requestHide { hidden = $0 == .hidden }
                            spin(until: { hidden })
                            XCTAssertTrue(controller.show(on: screen, corner: corner))
                            spin(1)
                        }
                        let note = "\(mode) \(spot) \(corner)"
                        let container = try content(panel)
                        let windows = controller.islandWindowsForTesting
                        assertAt(spot, island: windows.islandFrame, panel: panel.visibleContentFrame, corner: corner, note)
                        let union = panel.visibleContentFrame.union(windows.islandFrame)
                        let unionCorner = local(point: PanelCollapseGeometry.cornerPoint(of: union, corner: corner), in: panel)
                        let anchor = local(point: L.collapseAnchor(panelFrame: panel.visibleContentFrame, corner: corner, spot: spot),
                                           in: panel)
                        let reported = try XCTUnwrap(container.collapseAnchor(corner: corner), note)
                        XCTAssertEqual(reported.x, unionCorner.x, accuracy: 0.01, "\(note): the anchor")
                        XCTAssertEqual(reported.y, unionCorner.y, accuracy: 0.01, "\(note): the anchor")
                        XCTAssertEqual(anchor, reported, note)
                        var hidden = false
                        var checked: [Double] = []
                        _ = controller.requestHide { hidden = $0 == .hidden }
                        let start = Date()
                        while !hidden, Date().timeIntervalSince(start) < 3 {
                            RunLoop.current.run(until: Date().addingTimeInterval(0.003))
                            let p = controller.displayedProgressForProbe
                            for fraction in [0.3, 0.7] where !checked.contains(fraction) && p >= fraction && p < 0.97 && !hidden {
                                try assertMidFlight(controller, panel, mode: mode, corner: corner, spot: spot, anchor: anchor,
                                                    "\(note) at \(p)")
                                checked.append(fraction)
                            }
                        }
                        XCTAssertTrue(hidden, note)
                        XCTAssertEqual(checked.sorted(), [0.3, 0.7], "\(note): sampled")
                        XCTAssertTrue(controller.show(on: screen, corner: corner))
                        spin(1)
                    }
                }
            }
        }
    }

    private func assertMidFlight(_ controller: AtticPanelController, _ panel: AtticPanel, mode: PanelHideAnimation,
                                 corner: ScreenCorner, spot: PanelIslandSpot, anchor: CGPoint, _ note: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let container = try content(panel)
        let windows = controller.islandWindowsForTesting
        XCTAssertTrue(container.isIslandStandInShown, "\(note): the stand-in draws the island", file: file, line: line)
        let capsule = local(L.islandFrame(panelFrame: panel.visibleContentFrame, corner: corner, spot: spot), in: panel)
        XCTAssertEqual(windows.standIn.frame, capsule.insetBy(dx: -L.windowMargin, dy: -L.windowMargin),
                       "\(note): over the island", file: file, line: line)
        let bounds = container.bounds
        for point in corners(capsule) {
            let drawn = container.drawnPoint(point)
            XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(drawn),
                          "\(note): the island's corner \(point) is drawn at \(drawn), inside the window", file: file, line: line)
        }
        if mode == .slide {
            let fixed = container.drawnPoint(anchor)
            XCTAssertLessThan(hypot(fixed.x - anchor.x, fixed.y - anchor.y), 0.75,
                              "\(note): the corner of the two stays put", file: file, line: line)
            let surface = local(panel.visibleContentFrame, in: panel)
            let a = container.drawnPoint(CGPoint(x: surface.minX, y: surface.minY))
            let b = container.drawnPoint(CGPoint(x: surface.maxX, y: surface.minY))
            let scale = (b.x - a.x) / surface.width
            XCTAssertLessThan(scale, 0.97, "\(note): collapsing", file: file, line: line)
            for point in corners(capsule) + corners(surface) {
                let drawn = container.drawnPoint(point)
                let expected = CGPoint(x: anchor.x + scale * (point.x - anchor.x), y: anchor.y + scale * (point.y - anchor.y))
                XCTAssertLessThan(hypot(drawn.x - expected.x, drawn.y - expected.y), 0.75,
                                  "\(note): \(point) scaled about the corner of the two", file: file, line: line)
            }
        }
    }

    /// Genie: the funnel's mouth ends at the corner of the two together.
    func testGeniesMouthEndsAtTheCornerOfTheTwoTogether() throws {
        for spot in [PanelIslandSpot.openSideCornerEnd, .acrossOpenEnd] {
            try withController(configure: { $0.hideAnimation = .genieLiveGlass; $0.islandSpot = spot }) { controller, _, panel, _ in
                let container = try content(panel)
                spin(until: { !container.isIslandStandInShown })
                spin(0.2)
                let genie = container.genieForTesting
                var hidden = false
                _ = controller.requestHide { hidden = $0 == .hidden }
                spin(0.03)
                XCTAssertTrue(container.isIslandStandInShown, "\(spot)")
                let island = controller.islandWindowsForTesting.islandFrame
                assertAt(spot, island: island, panel: panel.visibleContentFrame, corner: .topRight, "\(spot)")
                let union = panel.visibleContentFrame.union(island)
                let anchor = local(point: CGPoint(x: union.maxX, y: union.maxY), in: panel)
                let box = container.bounds
                XCTAssertEqual(CGFloat(genie.anchorInset.x), (box.maxX - anchor.x) / box.width, accuracy: 0.001, "\(spot)")
                XCTAssertEqual(CGFloat(genie.anchorInset.y), (box.maxY - anchor.y) / box.height, accuracy: 0.001, "\(spot)")
                spin(until: { hidden })
                XCTAssertTrue(hidden, "\(spot)")
            }
        }
    }

    /// The dismissing swipe moves both under the fingers, about the corner
    /// of the two, and springs both back.
    func testTheSwipeMovesBothAndSpringsBack() throws {
        try withController(configure: { $0.hideAnimation = .slide; $0.islandSpot = .openSideMiddle }) { controller, _, panel, _ in
            let windows = controller.islandWindowsForTesting
            let container = try content(panel)
            assertAt(.openSideMiddle, island: windows.islandFrame, panel: panel.visibleContentFrame, corner: .topRight, "swipe")
            let union = panel.visibleContentFrame.union(windows.islandFrame)
            let anchor = local(point: CGPoint(x: union.maxX, y: union.maxY), in: panel)
            panel.onTrackpadDismissProgress?(120)
            spin(0.05)
            XCTAssertGreaterThan(controller.displayedProgressForProbe, 0.05, "the fingers collapse it")
            XCTAssertTrue(container.isIslandStandInShown)
            XCTAssertEqual(windows.island.contentView?.layer?.opacity ?? 1, 0, "the window is empty")
            let fixed = container.drawnPoint(anchor, presented: false)
            XCTAssertLessThan(hypot(fixed.x - anchor.x, fixed.y - anchor.y), 0.75, "about the corner of the two")
            let capsule = local(windows.islandFrame, in: panel)
            let drawn = container.drawnPoint(CGPoint(x: capsule.minX, y: capsule.midY), presented: false)
            XCTAssertGreaterThan(drawn.x - capsule.minX, 1, "the island moves with the panel")
            panel.onTrackpadDismissCancelled?()
            spin(until: { !container.isIslandStandInShown })
            spin(0.05)
            XCTAssertEqual(windows.presentedOpacity, 1, accuracy: 0.01, "back with the panel")
            XCTAssertTrue(container.motionIsAtRest)
        }
    }

    /// Pulling a page off the island and snapping it back work wherever
    /// the island sits.
    func testPullOutAndSnapBackFollowTheIslandAtAnotherSpot() throws {
        try withController(configure: { $0.islandSpot = .acrossOpenEnd }) { controller, state, panel, _ in
            let windows = controller.islandWindowsForTesting
            let pullOut = controller.pullOut
            let screen = try XCTUnwrap(controller.currentScreen)
            let work = TestPresentationPolicy.placementFrame(screen.visibleFrame)
            let capsule = windows.islandFrame
            assertAt(.acrossOpenEnd, island: capsule, panel: panel.visibleContentFrame, corner: .topRight, "pull-out")
            let tasks = L.itemFrame(0, in: capsule)
            let start = CGPoint(x: tasks.midX, y: tasks.midY)
            let drop = CGPoint(x: work.midX - 200, y: work.maxY - PanelPullOutLayout.screenInset - 21 - 20)
            windows.handlePointer(.down(start))
            windows.handlePointer(.dragged(CGPoint(x: start.x - 10, y: start.y)))
            windows.handlePointer(.dragged(drop))
            windows.handlePointer(.up(drop))
            spin(0.6)
            XCTAssertNotNil(pullOut.panel(for: .tasks), "Tasks came off the flat island")
            // Back onto the island where it is now (below the panel).
            let near = CGPoint(x: capsule.midX, y: capsule.minY - 30)
            XCTAssertFalse(panel.visibleContentFrame.contains(near))
            XCTAssertTrue(pullOut.beginPull(.tasks, at: drop))
            pullOut.movePull(to: near)
            XCTAssertTrue(state.island.isSnapTarget, "the island's blue ring, below the panel")
            pullOut.endPull(at: near)
            spin(0.6)
            XCTAssertNil(pullOut.panel(for: .tasks), "snapped back")
            XCTAssertEqual(state.selectedSection, .tasks)
            // The pull-out asks for the island where it is now, and near the
            // panel's old place still snaps home (the panel 12 pt in).
            XCTAssertEqual(pullOut.islandFrame(), windows.islandFrame)
            let home = panel.visibleContentFrame
            XCTAssertEqual(PanelPullOutLayout.snap(pointer: CGPoint(x: home.midX, y: home.maxY - 40),
                                                   frame: home.offsetBy(dx: -20, dy: -20),
                                                   island: windows.islandFrame, home: home), .home)
        }
    }

    // MARK: The Settings diagram

    func testTheDiagramDrawsTheSpotsAroundThePanelInEveryCorner() {
        typealias D = PanelIslandSpotDiagram
        let bounds = CGRect(origin: .zero, size: D.size)
        for corner in ScreenCorner.allCases {
            let panel = D.panelFrame(corner: corner)
            XCTAssertTrue(bounds.contains(panel), "\(corner)")
            // The panel sits in the diagram's own corner.
            let right = L.isOnRight(corner), top = L.isTop(corner)
            XCTAssertEqual(right ? panel.maxX > bounds.midX : panel.minX < bounds.midX, true, "\(corner)")
            XCTAssertEqual(top ? panel.minY < bounds.midY : panel.maxY > bounds.midY, true, "\(corner): top-left origin")
            let hits = PanelIslandSpot.allCases.map { D.hitFrame($0, corner: corner) }
            for (index, spot) in PanelIslandSpot.allCases.enumerated() {
                let frame = D.spotFrame(spot, corner: corner)
                XCTAssertTrue(bounds.contains(hits[index]), "\(corner) \(spot): in the diagram")
                XCTAssertFalse(frame.intersects(panel), "\(corner) \(spot): beside the panel")
                for other in hits.indices where other != index {
                    XCTAssertFalse(hits[index].intersects(hits[other]), "\(corner) \(spot): one spot per click")
                }
                // Mirrored like the island itself.
                switch spot.side {
                case .screen: XCTAssertEqual(right ? frame.minX > panel.maxX : frame.maxX < panel.minX, true, "\(corner) \(spot)")
                case .open: XCTAssertEqual(right ? frame.maxX < panel.minX : frame.minX > panel.maxX, true, "\(corner) \(spot)")
                case .across:
                    XCTAssertEqual(frame.midX, panel.midX, accuracy: 0.01)
                    XCTAssertEqual(top ? frame.minY > panel.maxY : frame.maxY < panel.minY, true, "\(corner) \(spot)")
                }
            }
        }
    }

    /// The arrow keys move the choice to the nearest spot that way, in the
    /// diagram as drawn for the corner.
    func testTheArrowKeysMoveBetweenSpots() {
        typealias D = PanelIslandSpotDiagram
        XCTAssertEqual(D.spot(from: .screenSideCornerEnd, toward: .down, corner: .topRight), .screenSideMiddle)
        XCTAssertEqual(D.spot(from: .screenSideMiddle, toward: .down, corner: .topRight), .screenSideFarEnd)
        XCTAssertEqual(D.spot(from: .screenSideCornerEnd, toward: .left, corner: .topRight), .openSideCornerEnd)
        XCTAssertEqual(D.spot(from: .openSideMiddle, toward: .right, corner: .topRight), .screenSideMiddle)
        XCTAssertNil(D.spot(from: .screenSideCornerEnd, toward: .up, corner: .topRight))
        XCTAssertNil(D.spot(from: .screenSideCornerEnd, toward: .right, corner: .topRight))
        XCTAssertEqual(D.spot(from: .openSideFarEnd, toward: .down, corner: .topRight), .acrossOpenEnd)
        // Mirrored: in the bottom left the screen side is on the left and
        // the corner end at the bottom.
        XCTAssertEqual(D.spot(from: .screenSideCornerEnd, toward: .up, corner: .bottomLeft), .screenSideMiddle)
        XCTAssertEqual(D.spot(from: .screenSideCornerEnd, toward: .right, corner: .bottomLeft), .openSideCornerEnd)
        XCTAssertEqual(D.spot(from: .openSideFarEnd, toward: .up, corner: .bottomLeft), .acrossOpenEnd)
        // Every spot reaches every other.
        for corner in ScreenCorner.allCases {
            var reached: Set<PanelIslandSpot> = [.screenSideCornerEnd]
            var frontier: [PanelIslandSpot] = [.screenSideCornerEnd]
            while let spot = frontier.popLast() {
                for direction in [D.Direction.up, .down, .left, .right] {
                    if let next = D.spot(from: spot, toward: direction, corner: corner), reached.insert(next).inserted {
                        frontier.append(next)
                    }
                }
            }
            XCTAssertEqual(reached.count, 7, "\(corner)")
        }
    }

    /// Settings › Panel: seven named buttons in a group, the chosen one
    /// selected; pressing one chooses and keeps it. Under the key-window
    /// lane the arrow keys move the choice too.
    func testTheSettingsDiagramChoosesPersistsAndTakesTheKeyboard() throws {
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        let suite = "PanelIslandPosition.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.corner = .bottomLeft
        let host = NSHostingView(rootView: PanelSettingsView(settings: settings).atticDesignFromSystem())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        spin(0.3)
        @MainActor func button(_ spot: PanelIslandSpot) throws -> AnyObject {
            try XCTUnwrap(elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "setting-island-spot-\(spot.rawValue)" },
                          "\(spot) is a button")
        }
        let group = try XCTUnwrap(elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "setting-island-spot" })
        XCTAssertEqual(group.accessibilityLabel?(), "Island position")
        for spot in PanelIslandSpot.allCases {
            let element = try button(spot)
            XCTAssertEqual(element.accessibilityLabel?(), spot.title)
            XCTAssertEqual(element.accessibilityRole?(), .button)
        }
        XCTAssertEqual(try button(.screenSideCornerEnd).isAccessibilitySelected?(), true, "today's place is chosen")
        XCTAssertTrue(try button(.openSideMiddle).accessibilityPerformPress?() ?? false)
        spin(0.2)
        XCTAssertEqual(settings.islandSpot, .openSideMiddle)
        XCTAssertEqual(AppSettings(defaults: defaults).islandSpot, .openSideMiddle, "kept")
        XCTAssertEqual(try button(.openSideMiddle).isAccessibilitySelected?(), true)
        XCTAssertEqual(try button(.screenSideCornerEnd).isAccessibilitySelected?(), false)

        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else { return }
        window.makeKeyAndOrderFront(nil)
        spin(0.2)
        // Tab to the diagram, then ↑ (bottom left: across sits above the panel).
        let start = settings.islandSpot
        for _ in 0..<12 where settings.islandSpot == start {
            window.makeFirstResponder(window.firstResponder)
            sendKey(window, code: 48, characters: "\t")
            spin(0.05)
            sendKey(window, code: 126, characters: String(UnicodeScalar(NSUpArrowFunctionKey)!))
            spin(0.1)
        }
        XCTAssertEqual(settings.islandSpot, PanelIslandSpotDiagram.spot(from: start, toward: .up, corner: .bottomLeft),
                       "↑ moved the choice")
    }

    private func sendKey(_ window: NSWindow, code: UInt16, characters: String) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { continue }
            window.sendEvent(event)
        }
    }

    // MARK: Helpers

    /// The island sits at `spot` beside `panel` (checked from first
    /// principles, not through the layout).
    private func assertAt(_ spot: PanelIslandSpot, island: CGRect, panel: CGRect, corner: ScreenCorner, _ note: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        let right = L.isOnRight(corner), top = L.isTop(corner)
        switch spot.side {
        case .screen: XCTAssertEqual(right ? island.minX >= panel.maxX : island.maxX <= panel.minX, true,
                                     "\(note): on the screen side", file: file, line: line)
        case .open: XCTAssertEqual(right ? island.maxX <= panel.minX : island.minX >= panel.maxX, true,
                                   "\(note): on the open side", file: file, line: line)
        case .across:
            XCTAssertGreaterThan(island.width, island.height, "\(note): flat", file: file, line: line)
            XCTAssertEqual(top ? island.maxY <= panel.minY : island.minY >= panel.maxY, true,
                           "\(note): across the open end", file: file, line: line)
        }
        if !spot.isFlat, spot.position == .farEnd {
            XCTAssertEqual(top ? abs(island.minY - panel.minY) < 0.5 : abs(island.maxY - panel.maxY) < 0.5, true,
                           "\(note): at the far end", file: file, line: line)
        }
    }

    private func content(_ panel: AtticPanel) throws -> AtticPanelContentContainer {
        try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
    }

    private func local(_ rect: CGRect, in panel: AtticPanel) -> CGRect {
        rect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
    }

    private func local(point: CGPoint, in panel: AtticPanel) -> CGPoint {
        CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
    }

    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    private func withController(configure: (AppSettings) -> Void = { _ in },
                                _ body: @MainActor (AtticPanelController, PanelUIState, AtticPanel, AppSettings) throws -> Void) throws {
        // GitHub's runners turn both on; these tests state them.
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        let suite = "PanelIslandPosition.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let state = PanelUIState()
        let settings = AppSettings(defaults: defaults)
        configure(settings)
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes, canvasSession: CanvasSession(store: CanvasStore(container: container)),
            noteDraft: NoteDraftController(noteStore: notes), settings: settings, uiState: state
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let screen = try XCTUnwrap(controller.currentScreen ?? NSScreen.main)
        XCTAssertTrue(controller.show(on: screen, corner: .topRight))
        spin(0.8)
        defer {
            for floating in controller.pullOut.floatingPanels { floating.close() }
            var hidden = false
            _ = controller.requestHide { hidden = $0 == .hidden }
            spin(until: { hidden })
            panel.orderOut(nil)
        }
        try body(controller, state, panel, settings)
    }

    private func elements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject) }
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
}
